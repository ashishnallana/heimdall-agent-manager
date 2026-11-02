import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';

const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
const { useThisMachineBridge } = await import('../src/ui/bridge/useThisMachineBridge.ts');
const identity = await import('../src/ui/bridge/useBridgeIdentityState.ts');
const session = await import('../src/ui/bridge/desktopBridgeSession.ts');
const hub = 'https://hub.example.test';
const own = { supported: true, installed: true, enrolled: true, hub, profile: 'personal', bridge_id: 'brg_owned', state: 'connected', busy: false, operation: '', error: '' };
function createManager(overrides: any = {}) {
  const targets: any[] = []; const runs: any[] = []; const listeners: any[] = [];
  const manager: any = {
    getConfig: async () => ({ ok: true, supported: true, hubUrl: hub }),
    list: async () => ({ ok: true, profiles: [{ ...own, profile: '', bridge_id: 'brg_other' }, own] }),
    getStatus: async (target: any) => { targets.push(target); return own; },
    run: async (kind: string, target: any, options: any) => { runs.push({ kind, target, options }); return { ok: true }; },
    cancel: async () => ({ ok: true }), openLog: async () => ({ ok: true }),
    onEvent: (listener: any) => { listeners.push(listener); return () => {}; }, ...overrides,
  };
  return { manager, targets, runs, listeners };
}
async function ui(run: (h: any) => Promise<void>, failAccount = false) {
  session.resetDesktopBridgeSessionForTests();
  const dom = new JSDOM('<div id="root"></div>', { url: hub, pretendToBeVisual: true });
  const saved = new Map<string, PropertyDescriptor | undefined>();
  for (const [key, value] of Object.entries({ window: dom.window, document: dom.window.document,
    HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true })) {
    saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
  }
  const previousFetch = globalThis.fetch;
  globalThis.fetch = (async () => failAccount ? Response.json({ error: { message: 'Hub unavailable' } }, { status: 503 })
    : Response.json({ data: { bridges: [{ bridge_id: 'brg_owned' }] } })) as typeof fetch;
  const store = configureStore({ reducer: { [heimdallApi.reducerPath]: heimdallApi.reducer },
    middleware: (g) => g().concat(heimdallApi.middleware), enhancers: (g) => g({ autoBatch: false }) });
  const root = createRoot(dom.window.document.getElementById('root')!);
  const render = async (element: React.ReactNode) => {
    await act(async () => root.render(React.createElement(Provider, { store, children: element })));
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });
  };
  try { await run({ dom, root, render, store }); } finally {
    await act(async () => root.unmount()); store.dispatch(heimdallApi.util.resetApiState());
    globalThis.fetch = previousFetch; session.resetDesktopBridgeSessionForTests(); dom.window.close();
    for (const [key, value] of saved) { if (value) Object.defineProperty(globalThis, key, value); else delete (globalThis as any)[key]; }
  }
}

for (const scenario of [
  { name: 'exact owned profile after another account', phase: 'present', id: 'brg_owned', overrides: {} },
  { name: 'another account is not this machine identity', phase: 'absent', overrides: { list: async () => ({ ok: true, profiles: [{ ...own, bridge_id: 'brg_other' }] }) } },
  { name: 'another Hub is not this machine identity', phase: 'absent', overrides: { list: async () => ({ ok: true, profiles: [{ ...own, hub: 'https://other.test' }] }) } },
  { name: 'profile mismatch', phase: 'error', overrides: { getStatus: async () => ({ ...own, profile: '' }) } },
  { name: 'Hub mismatch', phase: 'error', overrides: { getStatus: async () => ({ ...own, hub: 'https://other.test' }) } },
  { name: 'bridge ID mismatch', phase: 'error', overrides: { getStatus: async () => ({ ...own, bridge_id: 'brg_other' }) } },
  { name: 'not enrolled is not a committed identity', phase: 'error', overrides: { getStatus: async () => ({ ...own, state: 'not_enrolled', enrolled: false }) } },
  { name: 'missing status is unknown', phase: 'error', overrides: { getStatus: async () => ({ ...own, state: undefined }) } },
  { name: 'invalid Hub protocol', phase: 'error', overrides: { getConfig: async () => ({ ok: true, supported: true, hubUrl: 'file:///tmp/hub' }) } },
  { name: 'unknown installed status', phase: 'error', overrides: { getStatus: async () => ({ ...own, state: 'unknown' }) } },
  { name: 'failed status never means absence', phase: 'error', overrides: { getStatus: async () => ({ ...own, installed: false, error: 'service query failed', state: 'unknown' }) } },
  { name: 'unknown inventory never means absence', phase: 'error', overrides: { list: async () => ({ ok: true, profiles: [{ ...own, installed: false, bridge_id: '', state: 'unknown' }] }) } },
  { name: 'list error never means absence', phase: 'error', overrides: { list: async () => ({ ok: false, error: 'list failed' }) } },
  { name: 'unsupported platform', phase: 'unsupported', overrides: { getConfig: async () => ({ ok: true, supported: false }) } },
  { name: 'invalid Hub', phase: 'error', overrides: { getConfig: async () => ({ ok: true, supported: true, hubUrl: '' }) } },
  { name: 'Hub failure cannot reuse stale ownership', phase: 'error', accountError: true, overrides: {} },
]) {
  test('shared detector: ' + scenario.name, async () => ui(async ({ render, dom }: any) => {
    const { manager, targets } = createManager(scenario.overrides);
    let latest: any;
    function Probe() { latest = useThisMachineBridge(manager); return React.createElement('output', null, latest.phase); }
    await render(React.createElement(Probe));
    assert.equal(latest.phase, scenario.phase);
    assert.equal(latest.bridgeId, (scenario as any).id || '');
    if (scenario.phase === 'present') assert.deepEqual(targets, [{ hub, profile: 'personal' }]);
    if (scenario.phase === 'absent') assert.deepEqual(targets, [], 'never query another account/Hub profile');
    assert.deepEqual(Object.keys(dom.window.localStorage), []);
  }, scenario.accountError));
}

test('local operation guard preserves active run; refused start remains distinct from streamed failure', async () => {
  session.resetDesktopBridgeSessionForTests();
  const { manager, runs, listeners } = createManager();
  const target = { hub, profile: 'personal' };
  assert.equal(await session.runDesktopBridgeOperation(manager, 'update', target, { purge: false }), '');
  const first = session.desktopBridgeSession();
  assert.match(await session.runDesktopBridgeOperation(manager, 'uninstall', { hub, profile: '' }, { purge: true }), /already running/);
  assert.equal(session.desktopBridgeSession(), first);
  assert.equal(runs.length, 1);
  listeners[0]({ type: 'error', step: 'download', message: 'network failed', rolledBack: true });
  const failed = session.desktopBridgeSession();
  assert.equal(failed.operation, '');
  assert.equal(failed.wizard.rolledBack, true);
  assert.deepEqual(failed.lastRun?.target, target);
  assert.deepEqual(failed.lastRun?.options, { purge: false });
  manager.run = async () => ({ ok: false, error: 'busy outside this window' });
  assert.equal(await session.runDesktopBridgeOperation(manager, 'update', target), 'busy outside this window');
  assert.equal(session.desktopBridgeSession().operation, '');
  assert.equal(session.desktopBridgeSession().wizard.completed, false);
  assert.equal(session.desktopBridgeSession().wizard.failedStep, '');
  assert.equal(session.desktopBridgeSession().finished, failed.finished, 'refusal is not a terminal event');
  session.resetDesktopBridgeSessionForTests();
});

test('identity controller preserves choice, pending attempt and approval wait across host unmount, resetting per run', async () => ui(async ({ render, dom }: any) => {
  const { manager } = createManager();
  await session.runDesktopBridgeOperation(manager, 'setup', { hub, profile: 'personal' }, { separateAccount: true });
  let setChoice: any; let attempt: any; let wait: any; let value: any;
  function Probe() {
    [value, setChoice] = identity.useBridgeIdentityState('choice', '');
    attempt = identity.useBridgeIdentityRef('pendingAttempt', '');
    wait = identity.useBridgeIdentityRef<AbortController | null>('enrollmentWait', null);
    return React.createElement('output', null, value);
  }
  await render(React.createElement(Probe));
  const controller = new AbortController();
  await act(async () => { setChoice('reuse:brg_owned'); attempt.current = 'pending-123'; wait.current = controller; });
  await render(null); await render(React.createElement(Probe));
  assert.equal(value, 'reuse:brg_owned'); assert.equal(attempt.current, 'pending-123'); assert.equal(wait.current, controller);
  assert.equal(controller.signal.aborted, false, 'navigation never cancels an enrollment');
  assert.deepEqual(Object.keys(dom.window.localStorage), [], 'identity state is memory only');
  session.resetDesktopBridgeSessionForTests();
  await session.runDesktopBridgeOperation(manager, 'setup', { hub, profile: 'another' });
  await render(React.createElement(Probe));
  assert.equal(value, ''); assert.equal(attempt.current, ''); assert.equal(wait.current, null);
}));


test('Settings waits for Hub and local discovery before opening the installation wizard', async () => ui(async ({ render, dom, store }: any) => {
  const { default: ThisMachineCard } = await import('../src/ui/components/settings/ThisMachineCard.tsx');
  let finishHub: any; let finishLocal: any;
  globalThis.fetch = (() => new Promise((resolve) => { finishHub = resolve; })) as typeof fetch;
  const { manager, runs } = createManager({ list: () => new Promise((resolve) => { finishLocal = resolve; }) });
  const find = (id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`) as HTMLButtonElement;
  await render(React.createElement(ThisMachineCard, { manager }));
  assert.ok(find('settings-this-machine-loading'));
  assert.equal(find('settings-this-machine-open-setup-btn').disabled, true);
  assert.equal(find('settings-this-machine-setup-btn'), null);
  await act(async () => { finishHub(Response.json({ data: { bridges: [] } })); });
  await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)); });
  assert.ok(find('settings-this-machine-loading'), 'local discovery is still pending');
  assert.equal(find('settings-this-machine-setup-btn'), null);
  await act(async () => { finishLocal({ ok: true, profiles: [] }); });
  assert.equal(find('settings-this-machine-loading'), null);
  const install = find('settings-this-machine-setup-btn');
  assert.ok(install && !install.disabled);
  await act(async () => { install.click(); });
  assert.match(dom.window.location.hash, /setup/);
  assert.equal(find('settings-local-bridge-flow'), null, 'installation opens the full first-time wizard');
  assert.deepEqual(runs, [], 'navigation never starts installation directly');
  // A background Hub refresh must gate even previously confirmed absence.
  await act(async () => { store.dispatch(heimdallApi.util.invalidateTags([{ type: 'Bridges', id: 'LIST' }])); });
  assert.ok(find('settings-this-machine-loading'));
  assert.equal(find('settings-this-machine-setup-btn'), null);
  assert.equal(find('settings-this-machine-open-setup-btn').disabled, true);
  await act(async () => { finishHub(Response.json({ data: { bridges: [] } })); });
  await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)); });
  await act(async () => { finishLocal({ ok: true, profiles: [] }); });
}));

test('Settings lifecycle controls follow detected profiles and failed discovery offers no install', async () => ui(async ({ render, dom }: any) => {
  const { default: ThisMachineCard } = await import('../src/ui/components/settings/ThisMachineCard.tsx');
  const { manager } = createManager();
  await render(React.createElement(ThisMachineCard, { manager }));
  const inventory = dom.window.document.querySelector('[data-debug-id="settings-detected-profiles"]')!;
  for (const id of ['open-setup', 'update', 'reenroll', 'uninstall']) {
    const button = dom.window.document.querySelector(`[data-debug-id="settings-this-machine-${id}-btn"]`)!;
    assert.ok(inventory.compareDocumentPosition(button) & dom.window.Node.DOCUMENT_POSITION_FOLLOWING, id);
  }
  await render(null);
  const failed = createManager({ list: async () => ({ ok: false, error: 'Discovery unavailable' }) });
  await render(React.createElement(ThisMachineCard, { manager: failed.manager }));
  assert.equal(dom.window.document.querySelector('[data-debug-id="settings-this-machine-setup-btn"]'), null);
  assert.equal((dom.window.document.querySelector('[data-debug-id="settings-this-machine-open-setup-btn"]') as HTMLButtonElement).disabled, true);
  assert.match(dom.window.document.body.textContent || '', /Discovery unavailable/);
}));


test('Settings keeps setup disabled until the discovered profile status resolves', async () => ui(async ({ render, dom }: any) => {
  const { default: ThisMachineCard } = await import('../src/ui/components/settings/ThisMachineCard.tsx');
  let finishStatus: any;
  const { manager } = createManager({ getStatus: () => new Promise((resolve) => { finishStatus = resolve; }) });
  await render(React.createElement(ThisMachineCard, { manager }));
  assert.ok(dom.window.document.querySelector('[data-debug-id="settings-this-machine-loading"]'));
  assert.equal(dom.window.document.querySelector('[data-debug-id="settings-this-machine-setup-btn"]'), null);
  assert.equal((dom.window.document.querySelector('[data-debug-id="settings-this-machine-open-setup-btn"]') as HTMLButtonElement).disabled, true);
  await act(async () => { finishStatus(own); });
  assert.equal(dom.window.document.querySelector('[data-debug-id="settings-this-machine-loading"]'), null);
  assert.ok(dom.window.document.querySelector('[data-debug-id="settings-this-machine-update-btn"]'));
}));
