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
    usePaneDeferredRefresh(CONV, paneVisible, messagesQuery.refetch);
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
