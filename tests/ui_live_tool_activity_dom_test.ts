import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { JSDOM } from 'jsdom';
import reducer from '../src/ui/store/toolActivitySlice.ts';
import LiveToolActivity, { toolNameColor, formatToolDuration } from '../src/ui/components/extension/LiveToolActivity.tsx';
import ChatMessageList from '../src/ui/components/chat/ChatMessageList.tsx';
import { heimdallApi } from '../src/ui/api/heimdallApi.ts';
import { handleUserWsEvent } from '../src/ui/api/wsInvalidation.ts';
import { FakeToolSocket, snapshot } from './helpers/toolStreamHarness.ts';

async function withDom(run: (env: any) => Promise<void>) {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.test/', pretendToBeVisual: true });
  const names = ['window', 'document', 'HTMLElement', 'Node', 'IS_REACT_ACT_ENVIRONMENT',
    'WebSocket', 'IntersectionObserver', 'requestAnimationFrame', 'cancelAnimationFrame'];
  const previous: any = Object.fromEntries(names.map((name) => [name, (globalThis as any)[name]]));
  const previousFetch = globalThis.fetch, previousNow = Date.now;
  let time = 1000, nextTimer = 0, requests = 0;
  const timers = new Map<number, () => void>();
  const sockets: FakeToolSocket[] = [];
  Object.assign(globalThis, { window: dom.window, document: dom.window.document,
    HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: (fn: any) => { fn(); return 0; }, cancelAnimationFrame: () => {},
    WebSocket: class extends FakeToolSocket { constructor(url: string) { super(url); sockets.push(this); } },
  });
  Date.now = () => time;
  dom.window.setInterval = ((fn: () => void) => { timers.set(++nextTimer, fn); return nextTimer; }) as any;
  dom.window.clearInterval = ((id: number) => timers.delete(id)) as any;
  dom.window.matchMedia = (() => ({ matches: false, addEventListener() {}, removeEventListener() {} })) as any;
  dom.window.HTMLElement.prototype.scrollTo = () => {};
  globalThis.fetch = async () => { requests++; throw new Error('Unexpected REST request'); };
  const store = configureStore({
    reducer: { toolActivity: reducer, chat: (s = { session: { userId: 'user1' } }, a: any) =>
      a.type === 'test/user' ? { session: { userId: a.payload } } : s,
      vault: (s = {}) => s, [heimdallApi.reducerPath]: heimdallApi.reducer },
    middleware: (gdm) => gdm().concat(heimdallApi.middleware),
  });
  const root = createRoot(dom.window.document.getElementById('root')!);
  const q = (id: string) => dom.window.document.querySelector('[data-debug-id="' + id + '"]') as HTMLElement | null;
  const render = async (child: React.ReactNode) => {
    await act(async () => { root.render(React.createElement(Provider, { store, children: child })); });
  };
  try {
    await run({ dom, store, root, q, render, sockets, timers,
      get requests() { return requests; },
      tick: async () => { time += 1000; await act(async () => { for (const callback of [...timers.values()]) callback(); }); },
    });
  } finally {
    await act(async () => root.unmount());
    assert.equal(timers.size, 0, 'all stream/display timers cleaned after unmount');
    for (const socket of sockets) assert.equal(socket.readyState, 3, 'every socket closed after unmount');
    store.dispatch(heimdallApi.util.resetApiState());
    globalThis.fetch = previousFetch; Date.now = previousNow;
    Object.assign(globalThis, previous); dom.window.close();
  }
}

test('flat rows render at conversation scroll tail, summaries/colors/badges/durations stay inline and shell rows open', async () => {
  await withDom(async (env) => {
    const { dom, sockets, q, render } = env;
    const opened: string[] = [];
    const message: any = { key: 'm1', messageId: 'm1', body: 'Real conversation message', isUser: false,
      createdUnixMs: 1, deliveredUnixMs: 0, readUnixMs: 1, deliveryFailedUnixMs: 0,
      deliveryError: '', sending: false, authorLabel: 'Worker', messageType: 'text', metadata: {} };
    await render(React.createElement(ChatMessageList, { conversationKey: 'chat_a', debugPrefix: 'test-thread',
      messages: [message], renderMessageBody: ({ message }: any) => message.body,
      children: React.createElement(LiveToolActivity, { instanceId: 'inst_a',
        members: [{ instanceId: 'inst_a', displayName: 'A' }, { instanceId: 'inst_b', displayName: 'B' }],
        onOpenShell: (id: string) => opened.push(id) }),
    }));
    const s = sockets[0]; s.open();
    const call = snapshot().active[0];
    await act(async () => {
      s.state(snapshot('inst_a', 1, { display_name: 'Agent A',
        active: [{ ...call, summary: 'x'.repeat(512), summary_truncated: true }] }));
      s.state(snapshot('inst_b', 1, { display_name: 'Agent B', active: [],
        completed_since_last: [{ call_id: 'done', source: 'provider', tool_name: 'Bash', summary: 'done',
          summary_truncated: false, duration_ms: 1250, completed_at_ms: 1, status: 'completed' }] }));
    });
    const container = q('live-tool-activity')!;
    assert.ok(q('test-thread-scroll')!.contains(container), 'inside scrollable conversation');
    assert.ok(q('test-thread-messages-container')!.lastElementChild === container, 'after conversation messages');
    assert.match(q('test-thread-scroll')!.className, /overflow-y-auto/);
    assert.doesNotMatch(container.className, /border|sticky|fixed|absolute/);
    assert.equal(container.querySelector('header'), null);
    assert.doesNotMatch(container.textContent!, /Running tools|running|Last call/);
    assert.equal(q('live-tools-toggle'), null);
    const shell = q('live-tools-shell-sh_inst_a')!;
    assert.match(shell.className, /flex-nowrap/); assert.match(shell.className, /whitespace-nowrap/);
    assert.equal(shell.lastElementChild!.getAttribute('data-debug-id'), 'live-tools-agent');
    assert.match(shell.lastElementChild!.className, /ml-auto.*max-w-.*shrink-0.*truncate/);
    const summary = shell.querySelector('[data-debug-id="live-tools-summary"]')!;
    assert.match(summary.className, /min-w-0 flex-1 truncate text-muted/);
    assert.equal(summary.getAttribute('title'), 'x'.repeat(512) + '…');
    assert.equal(dom.window.document.querySelectorAll('[data-debug-id="live-tools-duration"]')[1].textContent, '1.3 s');
    const toolLabels = container.querySelectorAll('span.font-medium');
    assert.equal(toolLabels[0].className, toolLabels[1].className, 'same tool same color across agents');
    await act(async () => shell.click());
    assert.deepEqual(opened, ['sh_inst_a']);
    assert.equal(env.requests, 0);
    // Verify actual caller placement too: DOM test above exercises the real scroll slot.
    const source = fs.readFileSync('src/ui/components/workbench/AgentChatPane.tsx', 'utf8');
    const list = source.indexOf('<ChatMessageList');
    assert.ok(source.indexOf('<LiveToolActivity', list) < source.indexOf('</ChatMessageList>', list));
    assert.ok(source.indexOf('</ChatMessageList>', list) < source.indexOf('ref={composerDockRef}', list));
  });
});

test('elapsed time advances locally, never negative; timer stops when active rows finish and batch replaces', async () => {
  await withDom(async (env) => {
    const { sockets, q, render, timers } = env;
    await render(React.createElement(LiveToolActivity, { instanceId: 'inst_a', onOpenShell() {} }));
    const s = sockets[0]; s.open();
    await act(async () => { s.state(snapshot()); });
    assert.equal(q('live-tools-duration')!.textContent, '1.0 s');
    assert.equal(timers.size, 2, 'one shared watchdog and one local display timer');
    await env.tick();
    assert.equal(q('live-tools-duration')!.textContent, '2.0 s');
    await act(async () => { s.state(snapshot('inst_a', 2, { active: [], completed_since_last: [{
      call_id: 'done', source: 'provider', tool_name: 'Read', summary: 'file', summary_truncated: false,
      status: 'completed', duration_ms: 65_000, completed_at_ms: 2000,
    }] }), false); });
    assert.equal(q('live-tools-duration')!.textContent, '1m 5s');
    assert.equal(timers.size, 1, 'local elapsed timer stops once no active calls remain');
    await env.tick();
    assert.equal(q('live-tools-duration')!.textContent, '1m 5s');
    await act(async () => { s.state(snapshot('inst_a', 3, { active: [] }), false); });
    assert.equal(q('live-tool-activity'), null, 'empty batch clears transient completion rows');
    assert.equal(formatToolDuration(-10), '0 ms'); assert.equal(env.requests, 0);
  });
});

test('own/chain mounts share socket; roster changes update it and old general user events do not affect tools', async () => {
  await withDom(async (env) => {
    const { sockets, render, store, q } = env;
    const own = React.createElement(LiveToolActivity, { key: 'own', instanceId: 'inst_a', onOpenShell() {} });
    const chain = (ids: string[]) => React.createElement(LiveToolActivity, { key: 'chain', instanceId: 'inst_a',
      members: ids.map((instanceId) => ({ instanceId, displayName: instanceId })), onOpenShell() {} });
    await render(React.createElement(React.Fragment, null, own, chain(['inst_a', 'inst_b'])));
    assert.equal(sockets.length, 1);
    const s = sockets[0]; s.open();
    assert.deepEqual(s.sent[0].instance_ids, ['inst_a', 'inst_b']);
    await act(async () => { s.state(snapshot()); });
    await render(React.createElement(React.Fragment, null, own, chain(['inst_b', 'inst_c'])));
    assert.equal(sockets.length, 1); assert.deepEqual(s.sent.at(-1).instance_ids, ['inst_a', 'inst_b', 'inst_c']);
    await act(async () => {
      handleUserWsEvent(store.dispatch, { type: 'tool_activity_live_unavailable', instance_id: 'inst_a' });
    });
    assert.ok(q('live-tools-shell-sh_inst_a'));
    await render(own);
    assert.deepEqual(s.sent.at(-1).instance_ids, ['inst_a']);
    assert.equal(env.requests, 0);
  });
});

test('unavailable/socket error clears row claims; visibility/pageshow/resume request immediate new baseline', async () => {
  await withDom(async (env) => {
    const { sockets, render, q, dom } = env;
    await render(React.createElement(LiveToolActivity, { instanceId: 'inst_a', onOpenShell() {} }));
    sockets[0].open();
    await act(async () => { sockets[0].state(snapshot()); });
    await act(async () => { sockets[0].frame({ type: 'unavailable', instance_id: 'inst_a', reason: 'bridge_offline' }); });
    assert.equal(q('live-tools-shell-sh_inst_a'), null);
    assert.match(q('live-tool-activity')!.textContent!, /Tools unavailable/);
    for (const event of ['visibilitychange', 'pageshow', 'resume']) {
      await act(async () => {
        if (event === 'pageshow') dom.window.dispatchEvent(new dom.window.Event(event));
        else dom.window.document.dispatchEvent(new dom.window.Event(event));
      });
      const s = sockets.at(-1)!; s.open();
      await act(async () => { s.state(snapshot()); });
      assert.ok(q('live-tools-shell-sh_inst_a'));
    }
    assert.equal(sockets.length, 4);
    await act(async () => { sockets.at(-1)!.onerror?.(); });
    assert.equal(q('live-tools-shell-sh_inst_a'), null);
    assert.match(q('live-tool-activity')!.textContent!, /Tools unavailable/);
    assert.equal(env.requests, 0);
  });
});

test('user change closes old socket and clears tool rows before new baseline', async () => {
  await withDom(async ({ sockets, render, q, store }) => {
    await render(React.createElement(LiveToolActivity, { instanceId: 'inst_a', onOpenShell() {} }));
    sockets[0].open();
    await act(async () => { sockets[0].state(snapshot()); });
    assert.ok(q('live-tools-shell-sh_inst_a'));
    await act(async () => { store.dispatch({ type: 'test/user', payload: 'user2' }); });
    assert.equal(sockets[0].readyState, 3);
    assert.equal(q('live-tools-shell-sh_inst_a'), null);
    assert.equal(sockets.length, 2);
  });
});

test('common tools have distinct stable colors', () => {
  const names = ['Bash', 'Read', 'Edit', 'Write', 'Grep', 'Glob', 'Agent', 'WebFetch', 'WebSearch', 'exec_command'];
  assert.equal(new Set(names.map(toolNameColor)).size, names.length);
  assert.equal(toolNameColor('custom'), toolNameColor('custom'));
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


test('tail resize follows readers at bottom but preserves a scrolled-up reader', async () => {
  await withDom(async ({ render, q, dom }) => {
    const previous = (globalThis as any).ResizeObserver;
    let resized!: () => void, disconnected = 0, scrolls = 0;
    (globalThis as any).ResizeObserver = class {
      constructor(callback: () => void) { resized = callback; }
      observe() {}
      disconnect() { disconnected++; }
    };
    dom.window.HTMLElement.prototype.scrollTo = () => { scrolls++; };
    try {
      await render(React.createElement(ChatMessageList, { conversationKey: 'chat_resize', debugPrefix: 'resize',
        messages: [], children: React.createElement('div', null, 'Tools tail') }));
      const scroll = q('resize-scroll')!;
      Object.defineProperties(scroll, { scrollHeight: { value: 1000, configurable: true },
        clientHeight: { value: 100, configurable: true } });
      resized();
      assert.equal(scrolls, 1, 'tail growth follows bottom reader even without messages');
      scroll.scrollTop = 0;
      await act(async () => { scroll.dispatchEvent(new dom.window.Event('scroll')); });
      resized();
      assert.equal(scrolls, 1, 'tail growth does not move scrolled-up reader');
      await render(null);
      assert.equal(disconnected, 1);
    } finally { (globalThis as any).ResizeObserver = previous; }
  });
});

test('actual isolated dedicated WS capture renders through mounted production rows', {
  skip: !process.env.LIVE_TOOLS_EVIDENCE,
}, async () => {
  const evidence = JSON.parse(fs.readFileSync(process.env.LIVE_TOOLS_EVIDENCE + '/manifest.json', 'utf8'));
  assert.equal(evidence.status, 'pass');
  assert.equal(evidence.capture_source, 'isolated-backend-websocket');
  const frames = evidence.ui_frames;
  const ids = [...new Set<string>(frames.map((frame: any) => frame.instance_id))];
  await withDom(async (env) => {
    const { render, sockets, q } = env;
    await render(React.createElement(LiveToolActivity, { instanceId: ids[0],
      members: ids.map(instanceId => ({instanceId, displayName: instanceId})), onOpenShell() {} }));
    const socket = sockets[0]; socket.open();
    let active = 0, batch = 0, empty = 0, unavailable = 0, refresh = 0;
    for (const frame of frames) {
      await act(async () => { socket.frame(frame); });
      if (frame.type === 'unavailable') {
        assert.match(q('live-tool-activity')!.textContent!, /Tools unavailable/);
        assert.equal(q('live-tool-activity')!.querySelector('[data-debug-id="live-tools-summary"]'), null);
        unavailable++; continue;
      }
      const rows = [...frame.snapshot.active, ...frame.snapshot.completed_since_last];
      if (!rows.length) {assert.equal(q('live-tool-activity'), null); empty++; continue;}
      const content = q('live-tool-activity')!;
      assert.ok(content, 'actual active/completed snapshot renders');
      for (const row of rows) {
        if (row.summary) assert.ok(content.textContent!.includes(row.summary), 'actual sanitized summary is rendered');
      }
      assert.equal(content.querySelectorAll('[data-debug-id="live-tools-summary"]').length, rows.length);
      if (frame.snapshot.active.length) active++;
      if (frame.snapshot.completed_since_last.length >= 2) batch++;
      if (frame.refresh) refresh++;
    }
    assert.ok(active && batch && empty && unavailable && refresh, 'all actual wire display states exercised');
    assert.equal(env.requests, 0, 'captured display consumption makes no REST requests');
  });
});
