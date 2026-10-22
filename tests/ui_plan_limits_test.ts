import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { renderToStaticMarkup } from 'react-dom/server';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { JSDOM } from 'jsdom';
import { heimdallApi } from '../src/ui/api/heimdallApi.ts';
import { accountBillingApi } from '../src/ui/api/endpoints/accountBilling.ts';
import { ApiError, customQueryError, errorFromResponse } from '../src/ui/api/cookieFetch.ts';
import { selectEntitlements, useEntitlements } from '../src/ui/hooks/useEntitlements.ts';
import { useAgentPaneSubscription } from '../src/ui/hooks/useAgentPaneSubscription.ts';
import { useShellPaneSubscription } from '../src/ui/hooks/useShellPaneSubscription.ts';
import { useAgentStream } from '../src/ui/components/chat/useAgentStream.ts';
import { useShellStream } from '../src/ui/components/shells/useShellStream.ts';
import UpgradePrompt from '../src/ui/components/billing/UpgradePrompt.tsx';
import { bridgeChoiceAtLimit } from '../src/ui/components/devices/bridgeReuseChoice.ts';
import { BridgeIdentityChoice } from '../src/ui/components/devices/DeviceApprovalPage.tsx';
import { ShellWorkbenchPane } from '../src/ui/components/workbench/ShellWorkbenchPane.tsx';
import { AgentPaneComposerPanel } from '../src/ui/components/chat/AgentPaneComposerPanel.tsx';
import { atPlanLimit, PERMISSIVE_ENTITLEMENTS } from '../src/ui/utils/accountEntitlements.ts';
import { isPlanLimitError, planLimitDetails, PLAN_LIMIT_EVENT } from '../src/ui/utils/planLimit.ts';
import { PTY_WIRE_KIND_OUTPUT, encodePtyViewerFrame } from '../src/ui/components/shells/ptyWire.ts';

const FREE = { max_bridges: 1, terminal_streaming_enabled: true, terminal_input_enabled: false, max_concurrent_streams: 2, shells_enabled: false };
const DETAILS = { limit: 'max_concurrent_streams', allowed: 2, current: 2, plan_label: 'Free', upgrade_path: '/settings/account' };
const account = (entitlements = FREE) => ({ user_id: 'user-a', plan_label: 'Free', entitlements, offers: [], checkout_pending: false });
const response = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const pause = (ms = 20) => new Promise((resolve) => setTimeout(resolve, ms));

function makeStore(userId = 'user-a') {
  return configureStore({
    reducer: { [heimdallApi.reducerPath]: heimdallApi.reducer, deviceVault: () => ({ userId }), chat: () => ({ session: { userId: 'legacy-unrelated' } }) },
    middleware: (getDefault) => getDefault().concat(heimdallApi.middleware),
    enhancers: (getDefault) => getDefault({ autoBatch: { type: 'tick' } }),
  });
}

async function harness() {
  const dom = new JSDOM('<!doctype html><html><body><div id="root"></div></body></html>', { url: 'https://hub.test/', pretendToBeVisual: true });
  const saved = new Map<string, PropertyDescriptor | undefined>();
  for (const [key, value] of Object.entries({ window: dom.window, document: dom.window.document, navigator: dom.window.navigator, HTMLElement: dom.window.HTMLElement, requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window), cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window), IS_REACT_ACT_ENVIRONMENT: true })) {
    saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { value, configurable: true, writable: true });
  }
  const oldFetch = globalThis.fetch;
  const oldSocket = globalThis.WebSocket;
  const store = makeStore();
  const root = createRoot(dom.window.document.getElementById('root')!);
  return {
    dom, store,
    async render(element: React.ReactNode) {
      await act(async () => { root.render(React.createElement(Provider, { store, children: element })); await pause(); });
      await act(async () => { await pause(); });
    },
    async close() {
      await act(async () => { root.unmount(); });
      await act(async () => { store.dispatch(heimdallApi.util.resetApiState()); await pause(50); });
      dom.window.close();
      globalThis.fetch = oldFetch;
      globalThis.WebSocket = oldSocket;
      for (const [key, descriptor] of saved) {
        if (descriptor) Object.defineProperty(globalThis, key, descriptor);
        else Reflect.deleteProperty(globalThis, key);
      }
    },
  };
}

test('zero is restrictive, -1 is unlimited, and unavailable entitlements are permissive', () => {
  assert.equal(atPlanLimit(0, 0), true);
  assert.equal(atPlanLimit(1, 0), false);
  assert.equal(atPlanLimit(1, 1), true);
  assert.equal(atPlanLimit(-1, 999), false);
  const store = makeStore();
  assert.equal(selectEntitlements(store.getState()), PERMISSIVE_ENTITLEMENTS);
  store.dispatch(heimdallApi.util.resetApiState());
});

test('HTTP 402 retains details through RTK and announces a cache refresh event', async () => {
  const h = await harness();
  let detail: unknown;
  h.dom.window.addEventListener(PLAN_LIMIT_EVENT, (event: Event) => { detail = (event as CustomEvent).detail; });
  try {
    const error = await errorFromResponse(response({ error: { code: 'plan_limit_reached', message: 'At capacity', details: DETAILS } }, 402));
    assert.ok(error instanceof ApiError);
    assert.ok(isPlanLimitError(error));
    assert.ok(isPlanLimitError(customQueryError(error)));
    assert.deepEqual(planLimitDetails(customQueryError(error)), DETAILS);
    assert.deepEqual(detail, DETAILS);
    assert.equal(isPlanLimitError(new ApiError('offline', 503, 'bridge_offline')), false);
  } finally { await h.close(); }
});

test('multiple entitlement readers share the persistent user cache; checkout invalidates it', async () => {
  const h = await harness();
  let gets = 0;
  globalThis.fetch = async (_url, init) => {
    if (init?.method === 'POST') return response({ data: { transaction_id: 'txn_test', checkout_url: 'https://pay.test/?_ptxn=txn_test' } });
    gets += 1;
    return response({ data: account() });
  };
  function Reader() { const e = useEntitlements(); return React.createElement('span', null, String(e.max_bridges)); }
  let loader: any;
  try {
    await act(async () => { loader = h.store.dispatch(accountBillingApi.endpoints.getAccountBilling.initiate('user-a')); await loader; });
    await h.render(React.createElement(React.Fragment, null, React.createElement(Reader), React.createElement(Reader)));
    assert.equal(gets, 1);
    assert.equal(h.dom.window.document.getElementById('root')!.textContent, '11');
    await act(async () => { loader.unsubscribe(); });
    await h.render(React.createElement(Reader));
    loader = h.store.dispatch(accountBillingApi.endpoints.getAccountBilling.initiate('user-a'));
    await loader;
    assert.equal(gets, 1, 'remounting uses the indefinitely retained cache');
    h.dom.window.dispatchEvent(new h.dom.window.Event('focus'));
    assert.equal(gets, 1, 'ordinary focus does not refetch');
    await act(async () => { await h.store.dispatch(accountBillingApi.endpoints.createAccountCheckout.initiate('hobbyist')); await pause(); });
    assert.equal(gets, 2, 'checkout invalidation refreshes the sole shared query');
    const other = makeStore('user-b');
    assert.equal(selectEntitlements(other.getState()), PERMISSIVE_ENTITLEMENTS, 'another identity never reads this account');
    other.dispatch(heimdallApi.util.resetApiState());
  } finally { loader?.unsubscribe(); await h.close(); }
});

test('view-only status offers a subtle working Upgrade plan link', async () => {
  const h = await harness();
  try {
    await h.render(React.createElement(UpgradePrompt, { subtle: true, details: { limit: 'terminal_input_enabled' }, debugId: 'view-only' }));
    const status = h.dom.window.document.querySelector('[data-debug-id="view-only"]')!;
    assert.match(status.textContent!, /View-only/);
    assert.ok(!status.className.includes('warning'), 'normal view-only access is presented quietly');
    const link = status.querySelector('a')!;
    assert.equal(link.textContent, 'Upgrade plan');
    assert.equal(link.getAttribute('href'), '#/settings/account');
    link.click();
    await pause();
    assert.equal(h.dom.window.location.hash, '#/settings/account');
  } finally { await h.close(); }
});

test('the expanded agent PTY includes its view-only indicator and subtle upgrade link', async () => {
  const h = await harness();
  try {
    await act(async () => { await h.store.dispatch(accountBillingApi.util.upsertQueryData('getAccountBilling', 'user-a', account() as any)); });
    const markup = renderToStaticMarkup(React.createElement(Provider, {
      store: h.store,
      children: React.createElement(AgentPaneComposerPanel, { agentInstanceId: 'inst-a', isExpanded: true, runtimeStatus: 'running' }),
    }));
    const staticDom = new JSDOM(markup);
    const html = staticDom.window.document;
    const indicator = html.querySelector('[data-debug-id="agent-pane-read-only"]')!;
    assert.ok(indicator, 'the agent pane itself must render the view-only state');
    assert.match(indicator.textContent!, /View-only/);
    assert.equal(indicator.querySelector('a')!.textContent, 'Upgrade plan');
    assert.ok(!indicator.className.includes('warning'));
    assert.ok(html.querySelector('[data-debug-id="agent-pane-terminal"]'));
    staticDom.window.close();
  } finally { await h.close(); }
});

for (const kind of ['agent', 'shell'] as const) {
  test(`${kind} polling 402 shows UpgradePrompt and latches polling off, including manual/focus retries`, async () => {
    const h = await harness();
    let requests = 0;
    let controls: any;
    globalThis.fetch = async () => {
      requests += 1;
      return response({ error: { code: 'plan_limit_reached', message: 'At stream capacity', details: DETAILS } }, 402);
    };
    function Probe() {
      const [error, setError] = useState<unknown>(null);
      controls = kind === 'agent'
        ? useAgentPaneSubscription({ agentInstanceId: 'inst-a', isExpanded: true, onPlanLimit: setError })
        : useShellPaneSubscription({ sessionId: 'sh-a', isExpanded: true, onPlanLimit: setError });
      return error ? React.createElement(UpgradePrompt, { details: planLimitDetails(error) }) : null;
    }
    try {
      await h.render(React.createElement(Probe));
      assert.equal(requests, 1);
      assert.match(h.dom.window.document.body.textContent!, /2 concurrent terminal streams/);
      assert.ok(h.dom.window.document.querySelector('[data-debug-id="upgrade-prompt-upgrade"]'));
      await act(async () => {
        controls.refetch();
        h.dom.window.document.dispatchEvent(new h.dom.window.Event('visibilitychange'));
        h.dom.window.dispatchEvent(new h.dom.window.Event('focus'));
        await pause(1100);
      });
      assert.equal(requests, 1, 'the polling timer and manual refetch cannot bypass a plan refusal');
      assert.ok(controls.planLimitError);
      if (kind === 'shell') assert.equal(controls.polling, false);
    } finally { await h.close(); }
  });
}

class FakeSocket {
  static OPEN = 1;
  static sockets: FakeSocket[] = [];
  readyState = 0;
  sent: unknown[] = [];
  onopen: any;
  onmessage: any;
  onclose: any;
  onerror: any;
  binaryType = '';
  url: string;
  constructor(url: string) { this.url = url; FakeSocket.sockets.push(this); }
  send(data: unknown) { this.sent.push(data); }
  close() { this.readyState = 3; }
  open() { this.readyState = 1; this.onopen?.({}); }
  message(data: unknown) { this.onmessage?.({ data: typeof data === 'string' ? data : JSON.stringify(data) }); }
  remoteClose(code: number) { this.readyState = 3; this.onclose?.({ code, reason: '', wasClean: true }); }
}

for (const kind of ['agent', 'shell'] as const) {
  for (const refusal of ['close', 'error-frame'] as const) {
    test(`${kind} WS ${refusal === 'close' ? '4402' : 'plan error frame'} shows UpgradePrompt without reconnect or polling fallback`, async () => {
      const h = await harness();
      FakeSocket.sockets = [];
      globalThis.WebSocket = FakeSocket as any;
      let fallback = 0;
      let polls = 0;
      globalThis.fetch = async () => { polls += 1; return response({ data: {} }); };
      function Probe() {
        const [error, setError] = useState<unknown>(null);
        const options = { onPlanLimit: setError, onError: () => { fallback += 1; }, onClose: () => { fallback += 1; } };
        if (kind === 'agent') useAgentStream({ agentInstanceId: 'inst-a', ...options });
        else useShellStream({ sessionId: 'sh-a', ...options });
        return error ? React.createElement(UpgradePrompt, { details: planLimitDetails(error) }) : null;
      }
      try {
        await h.render(React.createElement(Probe));
        assert.equal(FakeSocket.sockets.length, 1);
        const socket = FakeSocket.sockets[0];
        await act(async () => {
          socket.open();
          if (refusal === 'error-frame') socket.message({ type: 'error', code: 'plan_limit_reached', message: 'At capacity', details: DETAILS });
          else socket.remoteClose(4402);
          await pause();
        });
        assert.ok(h.dom.window.document.querySelector('[data-debug-id="upgrade-prompt-upgrade"]'));
        await act(async () => {
          h.dom.window.document.dispatchEvent(new h.dom.window.Event('visibilitychange'));
          await pause(1200);
        });
        assert.equal(fallback, 0, 'plan refusals must not invoke callbacks that activate polling fallback');
        assert.equal(polls, 0);
        assert.equal(FakeSocket.sockets.length, 1, 'no automatic reconnect after a plan refusal');
      } finally { await h.close(); }
    });
  }

  for (const readOnlySource of ['cache', 'ready'] as const) {
    test(`${kind} read-only from ${readOnlySource} keeps output and the initial snapshot request but suppresses input and subsequent resizes`, async () => {
      const h = await harness();
      FakeSocket.sockets = [];
      globalThis.WebSocket = FakeSocket as any;
      let controls: any;
      let output = '';
      function Probe() {
        const options = { onOutput: (text: string) => { output += text; } };
        controls = kind === 'agent'
          ? useAgentStream({ agentInstanceId: 'inst-a', rows: 24, cols: 80, ...options })
          : useShellStream({ sessionId: 'sh-a', getGeometry: () => ({ rows: 24, cols: 80 }), ...options });
        return null;
      }
      try {
        if (readOnlySource === 'cache') {
          await act(async () => { await h.store.dispatch(accountBillingApi.util.upsertQueryData('getAccountBilling', 'user-a', account() as any)); });
        }
        await h.render(React.createElement(Probe));
        const socket = FakeSocket.sockets[0];
        await act(async () => {
          socket.open();
          socket.message({ type: 'ready', read_only: readOnlySource === 'ready' });
          socket.message({ type: 'stream_ready' });
          controls.sendInput('echo blocked\r');
          controls.sendResize(35, 110);
          const bytes = encodePtyViewerFrame(PTY_WIRE_KIND_OUTPUT, 0, new TextEncoder().encode('live output'));
          socket.onmessage?.({ data: bytes.buffer });
          await pause(60);
        });
        assert.equal(controls.readOnly, true);
        assert.equal(output, 'live output', 'view-only keeps the live output path');
        assert.equal(socket.sent.length, 1, 'only the initial snapshot geometry is sent');
        assert.deepEqual(JSON.parse(socket.sent[0] as string), { type: 'resize', rows: 24, cols: 80 });
      } finally { await h.close(); }
    });
  }
}

test('bridge capacity forces reuse, disables new identity selection, and keeps the chosen target', async () => {
  const h = await harness();
  const info = { reusable_bridges: [{ bridge_id: 'brg_one', label: 'One' }, { bridge_id: 'brg_two', label: 'Two' }] } as any;
  const choice = bridgeChoiceAtLimit(info, { mode: 'new', targetBridgeId: 'brg_two' }, true);
  assert.deepEqual(choice, { mode: 'reuse', targetBridgeId: 'brg_two' });
  assert.deepEqual(bridgeChoiceAtLimit(info, choice, false), choice);
  try {
    await h.render(React.createElement(BridgeIdentityChoice, { info, choice, atCapacity: true, onChange: () => assert.fail('disabled new option must not change the choice') }));
    const radio = h.dom.window.document.querySelector('[data-debug-id="device-approval-mode-new"] input') as HTMLInputElement
      || h.dom.window.document.querySelector('input[value="new"]') as HTMLInputElement;
    assert.ok(radio.disabled);
    radio.click();
    assert.match(h.dom.window.document.body.textContent!, /Reuse an existing bridge/);
    assert.ok(h.dom.window.document.querySelector('[data-debug-id="device-approval-bridge-cap-upgrade"]'));
  } finally { await h.close(); }
});

test('free workbench shell auto-create is blocked locally with an upgrade option', async () => {
  const h = await harness();
  let requests = 0;
  globalThis.fetch = async () => { requests += 1; return response({ data: {} }); };
  try {
    await act(async () => { await h.store.dispatch(accountBillingApi.util.upsertQueryData('getAccountBilling', 'user-a', account() as any)); });
    await h.render(React.createElement(ShellWorkbenchPane, { bridgeId: 'brg_one', autoCreate: true }));
    assert.equal(requests, 0);
    assert.match(h.dom.window.document.body.textContent!, /Interactive shells require an upgrade/);
    assert.ok(h.dom.window.document.querySelector('[data-debug-id="workbench-shell-upgrade-upgrade"]'));
  } finally { await h.close(); }
});
