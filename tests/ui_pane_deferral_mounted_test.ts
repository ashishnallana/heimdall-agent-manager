// Hidden-pane deferral, mounted: a probe component wires the REAL
// useFetchConversationMessagesQuery + usePaneDeferredRefresh exactly as AgentChatPane
// does, under a real PaneVisibilityProvider and store, while the real user-WS consumer
// receives message events. Asserts what reaches the wire as the pane is hidden/shown.
// The second test covers the companion change in this pass: the legacy PTY capture
// poll (AgentPaneComposerPanel) pausing while its tab is hidden by the layout.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_pane_deferral_mounted_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';

const CONV = 'chat_1';
const tick = (ms = 20) => new Promise((r) => setTimeout(r, ms));

function messageCreated(id: string) {
  return {
    type: 'chat_event', event: 'message_created', conversation_id: CONV, agent_instance_id: 'inst_1', message_id: id,
    direction: 'agent_to_user', message_type: 'text', created_at: '2026-10-21T10:05:00Z', last_message_at: '2026-10-21T10:05:00Z',
    unread_count: 1, fetch_required: true, fetch_kind: 'chat_message', fetch_id: id,
  };
}

test('mounted pane: events while hidden send no messages fetch; showing refetches once', async () => {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/' });
  const prev = { window: (globalThis as any).window, document: (globalThis as any).document, fetch: (globalThis as any).fetch };
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  const hits: string[] = [];
  (globalThis as any).fetch = async (input: any) => {
    const url = new URL(String(input?.url ?? input), 'http://localhost');
    hits.push(url.pathname);
    const body = url.pathname.endsWith('/messages') ? { data: [], page: { has_more: false } } : { data: [] };
    return { ok: true, status: 200, headers: { get: () => 'application/json' }, text: async () => JSON.stringify(body), json: async () => body } as any;
  };
  const store = await makeVaultStore();
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { Provider } = await import('react-redux');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { useFetchConversationMessagesQuery } = await import('../src/ui/api/endpoints/chats.ts');
  const { PaneVisibilityProvider, usePaneDeferredRefresh, usePaneVisible } = await import('../src/ui/components/workbench/paneVisibility.tsx');
  const { handleUserWsEvent, INVALIDATION_COALESCE_MS, resetQueuedInvalidations } = await import('../src/ui/api/wsInvalidation.ts');
  const { resetPaneDeferral } = await import('../src/ui/api/paneDeferral.ts');
  resetPaneDeferral();

  function Probe() {
    const paneVisible = usePaneVisible();
    const messagesQuery = useFetchConversationMessagesQuery({ conversationId: CONV });
    usePaneDeferredRefresh(CONV, paneVisible, messagesQuery.refetch, messagesQuery);
    return null;
  }
  const root = createRoot(dom.window.document.getElementById('root')!);
  const render = (visible: boolean) => act(async () => {
    root.render(React.createElement(Provider as any, { store }, React.createElement(PaneVisibilityProvider, { visible }, React.createElement(Probe))));
  });
  const messageFetches = () => hits.filter((h) => h.endsWith(`/chats/${CONV}/messages`)).length;
  try {
    await render(true);
    await act(async () => { await tick(50); });
    assert.equal(messageFetches(), 1, 'initial mount fetch');

    await render(false);
    for (const id of ['a', 'b', 'c']) {
      await act(async () => { handleUserWsEvent(store.dispatch, messageCreated(id)); await tick(INVALIDATION_COALESCE_MS + 60); });
    }
    assert.equal(messageFetches(), 1, `no fetch while hidden; saw ${hits.join(', ')}`);

    await render(true);
    await act(async () => { await tick(50); });
    assert.equal(messageFetches(), 2, 'one deferred refetch on show');

    // Hide/show again without new events: nothing more.
    await render(false);
    await render(true);
    await act(async () => { await tick(50); });
    assert.equal(messageFetches(), 2);

    // Visible pane: an event refetches right away.
    await act(async () => { handleUserWsEvent(store.dispatch, messageCreated('d')); await tick(INVALIDATION_COALESCE_MS + 60); });
    assert.equal(messageFetches(), 3);

    // Hidden, an event defers, then the pane unmounts (tab closed) while the page stays
    // cached. Reopening the conversation must pick up the missed message.
    await render(false);
    await act(async () => { handleUserWsEvent(store.dispatch, messageCreated('e')); await tick(INVALIDATION_COALESCE_MS + 60); });
    assert.equal(messageFetches(), 3, 'deferred while hidden');
    await act(async () => { root.render(React.createElement(Provider as any, { store }, null)); });
    await render(true);
    await act(async () => { await tick(50); });
    assert.equal(messageFetches(), 4, 'remount refetches the stale cached page once');
  } finally {
    await act(async () => root.unmount());
    resetQueuedInvalidations();
    resetPaneDeferral();
    store.dispatch(heimdallApi.util.resetApiState());
    dom.window.close();
    (globalThis as any).window = prev.window;
    (globalThis as any).document = prev.document;
    (globalThis as any).fetch = prev.fetch;
  }
});

test('mounted PTY capture: a layout-hidden expanded tab sends no 500 ms captures; showing refetches', async () => {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/' });
  // jsdom reports document.hidden=true unless pretending to render; the hook pauses then.
  Object.defineProperty(dom.window.document, 'hidden', { value: false, configurable: true });
  const prev = { window: (globalThis as any).window, document: (globalThis as any).document, fetch: (globalThis as any).fetch };
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  const prevRaf = { r: (globalThis as any).requestAnimationFrame, c: (globalThis as any).cancelAnimationFrame };
  (globalThis as any).requestAnimationFrame = (cb: (t: number) => void) => setTimeout(() => cb(Date.now()), 16);
  (globalThis as any).cancelAnimationFrame = (id: any) => clearTimeout(id);
  const hits: string[] = [];
  (globalThis as any).fetch = async (input: any) => {
    const url = new URL(String(input?.url ?? input), 'http://localhost');
    hits.push(url.pathname);
    const body = { data: { output: 'x', hash: 'h1', changed: true } };
    return { ok: true, status: 200, headers: { get: () => 'application/json' }, text: async () => JSON.stringify(body), json: async () => body } as any;
  };
  const store = await makeVaultStore();
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { Provider } = await import('react-redux');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { useAgentPaneSubscription } = await import('../src/ui/hooks/useAgentPaneSubscription.ts');
  const { PaneVisibilityProvider, usePaneVisible } = await import('../src/ui/components/workbench/paneVisibility.tsx');

  // Same wiring as AgentPaneComposerPanel's legacy polling path.
  function Probe() {
    const paneVisible = usePaneVisible();
    useAgentPaneSubscription({ agentInstanceId: 'inst_pty', isExpanded: true, isActiveTab: true && paneVisible, runtimeStatus: 'running' });
    return null;
  }
  const root = createRoot(dom.window.document.getElementById('root')!);
  const render = (visible: boolean) => act(async () => {
    root.render(React.createElement(Provider as any, { store }, React.createElement(PaneVisibilityProvider, { visible }, React.createElement(Probe))));
  });
  const captures = () => hits.filter((h) => h.endsWith('/agent-instances/inst_pty/pane')).length;
  try {
    await render(false);
    await act(async () => { await tick(1600); });
    assert.equal(captures(), 0, 'hidden: no captures in 1.6 s (was ~3 at 500 ms)');
    await render(true);
    await act(async () => { await tick(1100); });
    const shown = captures();
    assert.ok(shown >= 2, `visible: immediate fetch + 500 ms polling resumes; saw ${shown}`);
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    dom.window.close();
    (globalThis as any).window = prev.window;
    (globalThis as any).document = prev.document;
    (globalThis as any).fetch = prev.fetch;
    (globalThis as any).requestAnimationFrame = prevRaf.r;
    (globalThis as any).cancelAnimationFrame = prevRaf.c;
  }
});

// ---- Catch-up after an older in-flight request ---------------------------------------
// The newest page was being fetched when the message event arrived while the pane was
// hidden: that request's snapshot predates the message. Showing the pane while it is
// still pending used to consume the dirty mark and call refetch, which RTK drops for a
// pending query, so the old snapshot won and nothing refreshed until another event.

type Gate = { release: () => void };

async function mountHarness() {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/' });
  const prev = { window: (globalThis as any).window, document: (globalThis as any).document, fetch: (globalThis as any).fetch };
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  // Fake hub: a GET answers with the messages that existed when it STARTED. holdNext
  // keeps the next GET pending until released; failNext answers it with a 500.
  const server = { messages: [] as Array<{ message_id: string }>, holdNext: false, failNext: false };
  const gates: Gate[] = [];
  const hits: string[] = [];
  (globalThis as any).fetch = async (input: any) => {
    const url = new URL(String(input?.url ?? input), 'http://localhost');
    hits.push(url.pathname);
    const isMessages = url.pathname.endsWith('/messages');
    const snapshot = server.messages.slice();
    const fail = isMessages && server.failNext;
    if (isMessages && server.holdNext) {
      server.holdNext = false;
      await new Promise<void>((resolve) => gates.push({ release: resolve }));
    }
    if (fail) server.failNext = false;
    const status = fail ? 500 : 200;
    const body = fail ? { error: 'boom' } : isMessages ? { data: snapshot, page: { has_more: false } } : { data: [] };
    return { ok: !fail, status, headers: { get: () => 'application/json' }, text: async () => JSON.stringify(body), json: async () => body } as any;
  };
  const { paneDeferralResetMiddleware } = await import('../src/ui/api/wsInvalidation.ts');
  const store = await makeVaultStore({ extraMiddleware: paneDeferralResetMiddleware ? [paneDeferralResetMiddleware] : [] });
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { Provider } = await import('react-redux');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { useFetchConversationMessagesQuery } = await import('../src/ui/api/endpoints/chats.ts');
  const { PaneVisibilityProvider, usePaneDeferredRefresh, usePaneVisible } = await import('../src/ui/components/workbench/paneVisibility.tsx');
  const ws = await import('../src/ui/api/wsInvalidation.ts');
  const deferral = await import('../src/ui/api/paneDeferral.ts');
  deferral.resetPaneDeferral();

  const shown: Record<string, string[]> = {};
  function Probe({ name }: { name: string }) {
    const paneVisible = usePaneVisible();
    const messagesQuery = useFetchConversationMessagesQuery({ conversationId: CONV });
    // Exactly AgentChatPane's wiring.
    usePaneDeferredRefresh(CONV, paneVisible, messagesQuery.refetch, messagesQuery);
    shown[name] = (messagesQuery.data?.messages || []).map((m: any) => m.message_id);
    return null;
  }
  const root = createRoot(dom.window.document.getElementById('root')!);
  // panes: name -> visible; omitted panes are unmounted.
  const render = (panes: Record<string, boolean>) => act(async () => {
    const children = Object.entries(panes).map(([name, visible]) =>
      React.createElement(PaneVisibilityProvider, { key: name, visible }, React.createElement(Probe, { name })));
    root.render(React.createElement(Provider as any, { store }, ...children));
  });
  const settle = (ms = 60) => act(async () => { await tick(ms); });
  const event = (id: string) => act(async () => {
    server.messages.push({ message_id: id });
    ws.handleUserWsEvent(store.dispatch, messageCreated(id));
    await tick(ws.INVALIDATION_COALESCE_MS + 60);
  });
  const releaseOldest = () => act(async () => { gates.shift()!.release(); await tick(60); });
  const messageFetches = () => hits.filter((h) => h.endsWith(`/chats/${CONV}/messages`)).length;
  const teardown = async () => {
    await act(async () => root.unmount());
    for (const gate of gates.splice(0)) gate.release();
    ws.resetQueuedInvalidations();
    deferral.resetPaneDeferral();
    store.dispatch(heimdallApi.util.resetApiState());
    dom.window.close();
    (globalThis as any).window = prev.window;
    (globalThis as any).document = prev.document;
    (globalThis as any).fetch = prev.fetch;
  };
  return { act, server, store, heimdallApi, ws, deferral, shown, render, settle, event, releaseOldest, messageFetches, teardown, gates };
}

test('catch-up: show while a pre-event GET is pending -> exactly one fresh GET after it settles', async () => {
  const h = await mountHarness();
  try {
    h.server.messages.push({ message_id: 'm0' });
    h.server.holdNext = true;
    await h.render({ a: true });
    await h.settle();
    assert.equal(h.messageFetches(), 1, 'initial GET started and is held (snapshot [m0])');

    await h.render({ a: false });
    await h.event('m1');
    assert.equal(h.messageFetches(), 1, 'hidden: deferred, no request');

    await h.render({ a: true });
    await h.settle();
    assert.equal(h.messageFetches(), 1, 'shown while the old GET is pending: no duplicate request');

    await h.releaseOldest();
    await h.settle(100);
    assert.deepEqual(h.shown.a, ['m0', 'm1'], `the missed message renders without another event; fetches=${h.messageFetches()}`);
    assert.equal(h.messageFetches(), 2, 'exactly one catch-up GET');
    assert.equal(h.deferral.isDirty(CONV), false, 'mark cleared by the fresh response');

    await h.settle(300);
    await h.render({ a: false });
    await h.render({ a: true });
    await h.settle();
    assert.equal(h.messageFetches(), 2, 'no loop and no refetch on later hide/show');
  } finally {
    await h.teardown();
  }
});

test('catch-up: the pending GET is a refetch of an already-cached page (tags provided)', async () => {
  const h = await mountHarness();
  try {
    h.server.messages.push({ message_id: 'm0' });
    await h.render({ a: true });
    await h.settle();
    assert.deepEqual(h.shown.a, ['m0']);
    // A visible event starts GET #2 (snapshot [m0, m1]) and it stays pending.
    h.server.holdNext = true;
    await h.event('m1');
    assert.equal(h.messageFetches(), 2);
    await h.render({ a: false });
    await h.event('m2');
    await h.render({ a: true });
    await h.settle();
    assert.equal(h.messageFetches(), 2, 'waits for the pending refetch');
    await h.releaseOldest();
    await h.settle(150);
    assert.equal(h.messageFetches(), 3, 'exactly one catch-up');
    assert.deepEqual(h.shown.a, ['m0', 'm1', 'm2']);
  } finally {
    await h.teardown();
  }
});

test('catch-up: hide/show churn and two panes on one conversation still send one catch-up', async () => {
  const h = await mountHarness();
  try {
    h.server.holdNext = true;
    await h.render({ a: true, b: true });
    await h.settle();
    assert.equal(h.messageFetches(), 1, 'two panes share one cached page and one GET');

    await h.render({ a: false, b: false });
    await h.event('m1');
    for (let i = 0; i < 3; i += 1) {
      await h.render({ a: true, b: true });
      await h.render({ a: false, b: true });
      await h.render({ a: true, b: false });
    }
    await h.render({ a: true, b: true });
    await h.settle();
    assert.equal(h.messageFetches(), 1, 'churn while pending sends nothing');

    await h.releaseOldest();
    await h.settle(150);
    assert.equal(h.messageFetches(), 2, 'one catch-up for both panes');
    assert.deepEqual(h.shown.a, ['m1']);
    assert.deepEqual(h.shown.b, ['m1']);
  } finally {
    await h.teardown();
  }
});

test('catch-up: request errors neither lose the mark nor loop', async () => {
  const h = await mountHarness();
  try {
    // The OLD request fails: its (absent) snapshot is still pre-event, so the catch-up runs.
    h.server.holdNext = true;
    h.server.failNext = true;
    await h.render({ a: true });
    await h.settle();
    await h.render({ a: false });
    await h.event('m1');
    await h.render({ a: true });
    await h.settle();
    await h.releaseOldest();
    await h.settle(150);
    assert.equal(h.messageFetches(), 2, 'one catch-up after the failed old GET');
    assert.deepEqual(h.shown.a, ['m1']);

    // The CATCH-UP fails: the attempt was made after the event, so the mark is spent and
    // ordinary error handling applies; no retry storm.
    await h.render({ a: false });
    h.server.failNext = true;
    await h.event('m2');
    assert.equal(h.messageFetches(), 2);
    await h.render({ a: true });
    await h.settle(400);
    assert.equal(h.messageFetches(), 3, 'one catch-up attempt, failed, not repeated');
    assert.equal(h.deferral.isDirty(CONV), false);

    // A later visible event still refreshes normally.
    await h.event('m3');
    await h.settle(100);
    assert.equal(h.messageFetches(), 4);
    assert.deepEqual(h.shown.a, ['m1', 'm2', 'm3']);
  } finally {
    await h.teardown();
  }
});

test('catch-up: unmount after show while the old GET is pending; remount catches up once', async () => {
  const h = await mountHarness();
  try {
    h.server.holdNext = true;
    await h.render({ a: true });
    await h.settle();
    await h.render({ a: false });
    await h.event('m1');
    await h.render({ a: true });
    await h.settle();
    // Tab closed before the old GET answered; the page stays cached (keepUnusedDataFor).
    await h.render({});
    await h.releaseOldest();
    await h.settle();
    assert.equal(h.messageFetches(), 1, 'nothing fetched while unmounted');

    await h.render({ a: true });
    await h.settle(150);
    assert.equal(h.messageFetches(), 2, 'remount: exactly one catch-up');
    assert.deepEqual(h.shown.a, ['m1']);
    await h.settle(200);
    assert.equal(h.messageFetches(), 2);
  } finally {
    await h.teardown();
  }
});

test('catch-up: API reset (logout / user switch / vault lock) clears deferral state', async () => {
  const h = await mountHarness();
  try {
    await h.render({ a: true });
    await h.settle();
    await h.render({ a: false });
    await h.event('m1');
    assert.equal(h.deferral.isDirty(CONV), true, 'owner A: deferred');
    // A queued (not yet flushed) invalidation belongs to the same owner.
    await h.act(async () => { h.ws.handleUserWsEvent(h.store.dispatch, messageCreated('m2')); });
    await h.render({});

    h.store.dispatch(h.heimdallApi.util.resetApiState());
    assert.equal(h.deferral.isDirty(CONV), false, 'reset drops the dirty mark');
    assert.equal(h.ws.hasQueuedInvalidations(), false, 'reset drops queued tags and their timer');

    // The next owner's pane fetches its own page once and nothing more.
    const before = h.messageFetches();
    await h.render({ a: true });
    await h.settle(250);
    assert.equal(h.messageFetches(), before + 1);
  } finally {
    await h.teardown();
  }
});
