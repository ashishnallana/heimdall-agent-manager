import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { JSDOM } from 'jsdom';
import reducer, { liveStreamReady, liveFrameReceived, liveStreamDisconnected } from '../src/ui/store/toolActivitySlice.ts';
import LiveToolActivity from '../src/ui/components/extension/LiveToolActivity.tsx';
import ChatMessageList from '../src/ui/components/chat/ChatMessageList.tsx';

const snapshot = (id: string, revision = 1, active = true) => ({
  type: 'tool_activity_live', instance_id: id, agent_id: 'agt_same', display_name: 'Worker',
  chain_id: 'chain_a', bridge_id: 'brg_a', epoch: '1792670400000000001',
  generation: 1, revision, availability: 'ready',
  active: active ? [{ call_id: id + ':call', source: 'shell', tool_name: 'Shell',
    shell_session_id: 'sh_' + id, started_at_ms: 1000 }] : [],
  last_completion: active ? null : { duration_ms: 1250 },
});

async function withDom(run: (env: any) => Promise<void>) {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.test/', pretendToBeVisual: true });
  const names = ['window', 'document', 'HTMLElement', 'Node', 'IS_REACT_ACT_ENVIRONMENT',
    'IntersectionObserver', 'requestAnimationFrame', 'cancelAnimationFrame'];
  const previous: any = Object.fromEntries(names.map((name) => [name, (globalThis as any)[name]]));
  const previousFetch = globalThis.fetch;
  Object.assign(globalThis, { window: dom.window, document: dom.window.document,
    HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: (fn: any) => { fn(); return 0; }, cancelAnimationFrame: () => {} });
  dom.window.matchMedia = (() => ({ matches: false, addEventListener() {}, removeEventListener() {} })) as any;
  dom.window.HTMLElement.prototype.scrollTo = () => {};
  const store = configureStore({ reducer: { toolActivity: reducer, vault: (s = {}) => s } });
  const root = createRoot(dom.window.document.getElementById('root')!);
  const q = (id: string) => dom.window.document.querySelector('[data-debug-id="' + id + '"]') as HTMLElement | null;
  const render = async (child: React.ReactNode) => {
    await act(async () => { root.render(React.createElement(Provider, { store, children: child })); });
  };
  try { await run({ dom, store, root, q, render }); }
  finally {
    await act(async () => root.unmount());
    globalThis.fetch = previousFetch;
    Object.assign(globalThis, previous);
    dom.window.close();
  }
}

test('composer section/groups collapse independently and pushed final completion cleans running rows while collapsed', async () => {
  await withDom(async ({ dom, store, q, render }) => {
    let requests = 0;
    globalThis.fetch = async () => {
      requests++;
      return new Response(JSON.stringify({ data: { chain_id: 'chain_a', roster_token: 'v1', next_cursor: '',
        members: ['inst_a', 'inst_b'].map((id) => ({ instance_id: id, agent_id: 'agt_same', display_name: 'Worker',
          snapshot: snapshot(id), availability: 'ready' })) } }));
    };
    const opened: string[] = [];
    await render(React.createElement(LiveToolActivity, { instanceId: 'inst_a', chainId: 'chain_a',
      onOpenShell: (id: string) => opened.push(id) }));
    assert.equal(requests, 0, 'wait for subscribed WS before snapshot');
    await act(async () => { store.dispatch(liveStreamReady()); });
    assert.equal(requests, 1);
    assert.match(q('live-tools-toggle')!.textContent!, /2 running/);
    await act(async () => { q('live-tools-shell-sh_inst_b')!.click(); });
    assert.deepEqual(opened, ['sh_inst_b']);
    await act(async () => { q('live-tools-agent-toggle-inst_a')!.click(); });
    assert.equal(q('live-tools-shell-sh_inst_a'), null);
    assert.ok(q('live-tools-shell-sh_inst_b'), 'other group remains expanded');
    await act(async () => { store.dispatch(liveFrameReceived(snapshot('inst_a', 2, false) as any)); });
    assert.match(q('live-tools-toggle')!.textContent!, /1 running/);
    await act(async () => { q('live-tools-agent-toggle-inst_a')!.click(); });
    assert.equal(q('live-tools-shell-sh_inst_a'), null);
    assert.equal(q('live-tools-last-duration-inst_a')!.textContent!.trim(), 'Last call · 1.3 s');
    await act(async () => { q('live-tools-toggle')!.click(); });
    assert.equal(q('live-tools-agent-toggle-inst_b'), null);
    await act(async () => { store.dispatch(liveFrameReceived(snapshot('inst_b', 2, false) as any)); });
    assert.match(q('live-tools-toggle')!.textContent!, /0 running/);
    await act(async () => { q('live-tools-toggle')!.click(); });
    assert.equal(dom.window.document.querySelectorAll('[data-debug-id^="live-tools-shell-"]').length, 0);
    assert.equal(dom.window.document.querySelectorAll('[data-debug-id^="live-tools-last-duration-"]').length, 2);
    assert.equal(requests, 1, 'completion/collapse must never fetch');
    await act(async () => { store.dispatch(liveStreamDisconnected()); });
    assert.equal(q('live-tool-activity'), null, 'disconnect clears all live claims immediately');
  });
});

test('hidden-only pages advance raw pagination even before first visible message, with manual fallback', async () => {
  await withDom(async ({ dom, q, render }) => {
    let loads = 0;
    (globalThis as any).IntersectionObserver = class {
      callback: any;
      constructor(callback: any) { this.callback = callback; }
      observe() { this.callback([{ isIntersecting: true }]); }
      disconnect() {}
    };
    const base = { conversationKey: 'chat_a', debugPrefix: 'test-thread', hasMore: true,
      messages: [], onLoadOlder: () => { loads++; } };
    await render(React.createElement(ChatMessageList, { ...base, paginationCursor: 'raw3' }));
    assert.equal(loads, 1, 'empty rendered page must not trip initial-scroll guard');
    assert.ok(q('test-thread-load-older'));
    await act(async () => { q('test-thread-load-older')!.click(); });
    assert.equal(loads, 2, 'manual loading remains available');
    await render(React.createElement(ChatMessageList, { ...base, paginationCursor: 'raw2' }));
    assert.equal(loads, 3, 'cursor progress works without visible count progress');
    const text: any = { key: 'm1', messageId: 'm1', body: 'real message', isUser: false,
      createdUnixMs: 1000, deliveredUnixMs: 0, readUnixMs: 1000, deliveryFailedUnixMs: 0,
      deliveryError: '', sending: false, authorLabel: 'Worker', messageType: 'text', metadata: {} };
    await render(React.createElement(ChatMessageList, { ...base, hasMore: false, paginationCursor: '',
      messages: [text], renderMessageBody: ({ message }: any) => message.body }));
    assert.match(dom.window.document.body.textContent!, /real message/);
    assert.equal(q('test-thread-load-older'), null);
    assert.equal(loads, 3);
  });
});
