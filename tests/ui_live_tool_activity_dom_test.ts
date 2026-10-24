import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider, useSelector } from 'react-redux';
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
  const timeouts = new Map<number, { at: number; callback: () => void }>();
  const frames = new Map<number, FrameRequestCallback>();
  const mediaListeners = new Set<() => void>();
  const media = { matches: false, addEventListener: (_: string, fn: () => void) => mediaListeners.add(fn),
    removeEventListener: (_: string, fn: () => void) => mediaListeners.delete(fn) };
  const sockets: FakeToolSocket[] = [];
  Object.assign(globalThis, { window: dom.window, document: dom.window.document,
    HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: (fn: FrameRequestCallback) => { frames.set(++nextTimer, fn); return nextTimer; },
    cancelAnimationFrame: (id: number) => frames.delete(id),
    WebSocket: class extends FakeToolSocket { constructor(url: string) { super(url); sockets.push(this); } },
  });
  Date.now = () => time;
  dom.window.setInterval = ((fn: () => void) => { timers.set(++nextTimer, fn); return nextTimer; }) as any;
  dom.window.clearInterval = ((id: number) => timers.delete(id)) as any;
  dom.window.setTimeout = ((callback: () => void, ms = 0) => {
    timeouts.set(++nextTimer, { at: time + ms, callback }); return nextTimer;
  }) as any;
  dom.window.clearTimeout = ((id: number) => timeouts.delete(id)) as any;
  dom.window.matchMedia = (() => media) as any;
  dom.window.HTMLElement.prototype.getBoundingClientRect = function () {
    const height = this.hasAttribute('data-tool-key') ? parseFloat(this.style.height) || 0
      : this.parentElement?.hasAttribute('data-tool-key') ? 26 : 0;
    return { height, width: 600, x: 0, y: 0, top: 0, bottom: height, left: 0, right: 600, toJSON() {} };
  };
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
  const flushFrames = async () => { await act(async () => {
    const queued = [...frames.values()]; frames.clear(); queued.forEach((fn) => fn(time));
  }); };
  const advanceMotion = async (ms = 240) => {
    await flushFrames();
    time += ms;
    await act(async () => {
      for (const [id, timer] of [...timeouts]) if (timer.at <= time) { timeouts.delete(id); timer.callback(); }
    });
  };
  try {
    await run({ dom, store, root, q, render, sockets, timers, frames, timeouts, flushFrames, advanceMotion,
      reduceMotion: async (value: boolean) => { await act(async () => {
        media.matches = value; mediaListeners.forEach((fn) => fn());
      }); },
      get requests() { return requests; },
      tick: async () => { time += 1000; await act(async () => { for (const callback of [...timers.values()]) callback(); }); },
    });
  } finally {
    await act(async () => root.unmount());
    assert.equal(timers.size, 0, 'all stream/display timers cleaned after unmount');
    assert.equal(timeouts.size, 0, 'all exit fallback timers cleaned after unmount');
    assert.equal(frames.size, 0, 'all scheduled animation frames cleaned after unmount');
    assert.equal(mediaListeners.size, 0, 'all media change listeners cleaned after unmount');
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
      s.state(snapshot('inst_b', 1, { display_name: 'Agent B',
        active: [{ ...call, call_id: 'b', source: 'provider', started_at_ms: 500 }] }));
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
    assert.equal(dom.window.document.querySelectorAll('[data-debug-id="live-tools-duration"]')[1].textContent, '500 ms');
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

test('final completion exits once with its outcome and duration, even while completed batch persists', async () => {
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
      ...snapshot().active[0],
      status: 'completed', duration_ms: 65_000, completed_at_ms: 2000,
    }] }), false); });
    assert.equal(q('live-tools-duration')!.textContent, '1m 5s');
    assert.equal(q('live-tools-shell-sh_inst_a'), null, 'exits are not actionable');
    assert.match(q('live-tools-row')!.querySelector('[aria-label="Succeeded"]')!.className, /bg-green-500/);
    assert.equal(timers.size, 1, 'local elapsed timer stops once no active calls remain');
    await env.advanceMotion();
    assert.equal(q('live-tool-activity'), null, 'final completion leaves after exit without a new snapshot');
    await env.tick();
    assert.equal(q('live-tool-activity'), null);
    await act(async () => { s.state(snapshot('inst_a', 3, { active: [] }), false); });
    assert.equal(q('live-tool-activity'), null, 'empty batch cannot recreate exit copies');
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
    assert.doesNotMatch(dom.window.document.body.textContent!, /Tools unavailable/);
    assert.equal(q('live-tool-activity')!.querySelector('[aria-label="Running"]'), null);
    await env.advanceMotion();
    assert.equal(q('live-tool-activity'), null);
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
    assert.doesNotMatch(dom.window.document.body.textContent!, /Tools unavailable/);
    await env.advanceMotion();
    assert.equal(q('live-tool-activity'), null);
    assert.equal(env.requests, 0);
  });
});

test('user change closes old socket and clears tool rows before new baseline', async () => {
  await withDom(async ({ sockets, render, q, store }) => {
    const observed: { user: string; summary: string | null }[] = [];
    function IdentityProbe() {
      const user = useSelector((state: any) => state.chat.session.userId);
      React.useLayoutEffect(() => { observed.push({ user, summary: q('live-tools-summary')?.textContent || null }); }, [user]);
      return null;
    }
    await render(React.createElement(React.Fragment, null,
      React.createElement(LiveToolActivity, { instanceId: 'inst_a', onOpenShell() {} }), React.createElement(IdentityProbe)));
    sockets[0].open();
    await act(async () => { sockets[0].state(snapshot()); });
    assert.ok(q('live-tools-shell-sh_inst_a'));
    await act(async () => { store.dispatch({ type: 'test/user', payload: 'user2' }); });
    assert.equal(sockets[0].readyState, 3);
    assert.equal(q('live-tools-shell-sh_inst_a'), null);
    assert.equal(sockets.length, 2);
    assert.equal(observed.find((entry) => entry.user === 'user2')?.summary, null,
      'new user never commits old summaries, even before passive subscription effects');
  });
});

test('common tools have distinct stable colors', () => {
  const names = ['Bash', 'Read', 'Edit', 'Write', 'Grep', 'Glob', 'Agent', 'WebFetch', 'WebSearch', 'exec_command'];
  assert.equal(new Set(names.map(toolNameColor)).size, names.length);
  assert.equal(toolNameColor('custom'), toolNameColor('custom'));
});

test('completion-only baselines never create rows; individual success/failure exits preserve remaining identities', async () => {
  await withDom(async (env) => {
    const { render, sockets, q, dom } = env;
    await render(React.createElement(LiveToolActivity, { instanceId: 'inst_a', onOpenShell() {} }));
    const socket = sockets[0]; socket.open();
    const a = snapshot().active[0], b = { ...a, call_id: 'second', source: 'provider', summary: 'second' };
    const done = (call: any, status: string) => ({ ...call, status, duration_ms: 123, completed_at_ms: 1000 });
    await act(async () => socket.state(snapshot('inst_a', 1, { active: [], completed_since_last: [done(a, 'completed')] })));
    assert.equal(q('live-tool-activity'), null);
    await act(async () => socket.state(snapshot('inst_a', 2, { active: [a, b] }), false));
    await env.advanceMotion();
    const wrappers = [...dom.window.document.querySelectorAll('[data-tool-key]')];
    await act(async () => socket.state(snapshot('inst_a', 3, { active: [a], completed_since_last: [done(b, 'failed')] }), false));
    assert.equal(dom.window.document.querySelectorAll('[data-tool-key]')[0], wrappers[0], 'running sibling identity is stable');
    assert.equal(dom.window.document.querySelectorAll('[data-tool-key]')[1], wrappers[1], 'exit retains its wrapper');
    assert.match(q('live-tool-activity')!.querySelector('[aria-label="Failed"]')!.className, /bg-red-500/);
    await env.advanceMotion();
    assert.equal(dom.window.document.querySelectorAll('[data-tool-key]').length, 1);
    assert.ok(q('live-tools-shell-sh_inst_a'));
    await act(async () => socket.state(snapshot('inst_a', 4, { active: [], completed_since_last: [done(a, 'exited')] }), false));
    assert.match(q('live-tool-activity')!.querySelector('[aria-label="Succeeded"]')!.className, /bg-green-500/);
    await env.advanceMotion();
    assert.equal(q('live-tool-activity'), null);
    await act(async () => socket.state(snapshot('inst_a', 5, { active: [], completed_since_last: [done(a, 'exited')] }), false));
    assert.equal(q('live-tool-activity'), null, 'persistent completion batch cannot resurrect a row');
  });
});

test('queued entry, rapid exit/reentry, reset and reduced-motion changes cancel stale animation work', async () => {
  await withDom(async (env) => {
    const { render, sockets, q, dom, frames, timeouts } = env;
    await render(React.createElement(LiveToolActivity, { instanceId: 'inst_a', onOpenShell() {} }));
    const socket = sockets[0]; socket.open();
    await act(async () => socket.state(snapshot()));
    const row = dom.window.document.querySelector('[data-tool-key]') as HTMLElement;
    assert.equal(row.style.height, '0px', 'entry has an initial collapsed frame');
    assert.ok(frames.size > 0);
    await env.flushFrames();
    assert.equal(row.style.height, '26px', 'queued frame measures inner content');
    await act(async () => socket.state(snapshot('inst_a', 2, { active: [] }), false));
    assert.equal(q('live-tools-shell-sh_inst_a'), null);
    assert.equal(q('live-tool-activity')!.querySelector('[aria-label="Running"]'), null);
    assert.equal(q('live-tool-activity')!.querySelector('[aria-label="Succeeded"]'), null, 'silence is not success');
    await env.flushFrames();
    await act(async () => socket.state(snapshot('inst_a', 3), false));
    assert.equal(dom.window.document.querySelector('[data-tool-key]'), row, 'reentry cancels exit without a duplicate');
    await env.advanceMotion();
    assert.ok(q('live-tools-shell-sh_inst_a'), 'old exit timeout cannot remove reentered row');
    assert.equal(row.style.height, 'auto');
    await act(async () => socket.state(snapshot('inst_a', 4, { generation: 2 }), true));
    assert.notEqual(dom.window.document.querySelector('[data-tool-key]'), row, 'new generation discards previous visuals immediately');
    assert.equal(dom.window.document.querySelectorAll('[data-tool-key]').length, 1);
    await env.reduceMotion(true);
    assert.equal(timeouts.size, 0); assert.equal(frames.size, 0);
    assert.doesNotMatch(q('live-tool-activity')!.querySelector('[aria-label="Running"]')!.className, /(?:^| )animate-pulse/);
    await act(async () => socket.state(snapshot('inst_a', 5, { generation: 2, active: [] }), false));
    assert.equal(q('live-tool-activity'), null, 'reduced motion completes exit synchronously');
    await act(async () => socket.state(snapshot('inst_a', 6, { generation: 2 }), false));
    await env.reduceMotion(false);
    await act(async () => socket.state(snapshot('inst_a', 7, { generation: 2, active: [] }), false));
    await env.reduceMotion(true);
    assert.equal(q('live-tool-activity'), null, 'enabling reduction while exiting removes immediately');
    assert.equal(timeouts.size, 0); assert.equal(frames.size, 0);
  });
});

test('capacity is silent and instance switches and unmount discard retained summaries and scheduled work', async () => {
  await withDom(async (env) => {
    const { render, sockets, q, store, dom } = env;
    await render(React.createElement(LiveToolActivity, { instanceId: 'inst_a', onOpenShell() {} }));
    sockets[0].open();
    await act(async () => sockets[0].state(snapshot()));
    await act(async () => store.dispatch({ type: 'toolActivity/toolCapacityExceeded' }));
    assert.equal(q('live-tools-shell-sh_inst_a'), null);
    assert.doesNotMatch(dom.window.document.body.textContent!, /Tools unavailable/);
    await env.advanceMotion();
    assert.equal(q('live-tool-activity'), null);
    await act(async () => store.dispatch({ type: 'toolActivity/toolMembersSelected', payload: ['inst_a'] }));
    await act(async () => store.dispatch({ type: 'toolActivity/toolStateReceived', payload: snapshot() }));
    await env.flushFrames();
    await render(React.createElement(LiveToolActivity, { instanceId: 'inst_b', onOpenShell() {} }));
    assert.equal(q('live-tool-activity'), null, 'new identity clears previous summary without decorative exit');
    await render(null);
    assert.equal(env.frames.size, 0); assert.equal(env.timeouts.size, 0);
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
      scroll.scrollTop = 900; // the mocked scrollTo above has no native geometry
      const tail = q('resize-messages-container')!.lastElementChild as HTMLElement;
      tail.setAttribute('data-tool-motion', 'true');
      resized(); resized();
      assert.equal(scrolls, 1, 'motion does not force a JS scroll write each frame');
      assert.equal(q('resize-bottom-anchor')!.style.overflowAnchor, 'auto');
      await act(async () => scroll.dispatchEvent(new dom.window.WheelEvent('wheel', { deltaY: -30, bubbles: true })));
      assert.equal(q('resize-bottom-anchor')!.style.overflowAnchor, 'none', 'manual upward scroll disables anchor before geometry changes');
      tail.removeAttribute('data-tool-motion');
      resized();
      assert.equal(scrolls, 1, 'manual interruption cancels pending follow');
      scroll.scrollTop = 0;
      await act(async () => { scroll.dispatchEvent(new dom.window.Event('scroll')); });
      resized();
      assert.equal(scrolls, 1, 'tail growth does not move scrolled-up reader');
      await render(null);
      assert.equal(disconnected, 1);
    } finally { (globalThis as any).ResizeObserver = previous; }
  });
});

test('short-thread first overflow bootstraps native anchoring once and respects user cancellation', async () => {
  await withDom(async ({ render, q, dom }) => {
    const previous = (globalThis as any).ResizeObserver;
    let resized!: () => void, scrolls = 0, height = 100;
    (globalThis as any).ResizeObserver = class {
      constructor(callback: () => void) { resized = callback; }
      observe() {}
      disconnect() {}
    };
    dom.window.HTMLElement.prototype.scrollTo = function () { scrolls++; this.scrollTop = height - 100; };
    try {
      await render(React.createElement(ChatMessageList, { conversationKey: 'short', debugPrefix: 'short', messages: [],
        children: React.createElement('div', { 'data-tool-motion': 'true' }, 'Moving tools') }));
      const scroll = q('short-scroll')!;
      Object.defineProperties(scroll, { scrollHeight: { get: () => height }, clientHeight: { value: 100 } });
      resized();
      assert.equal(scrolls, 0, 'fitting content needs no bootstrap');
      height = 150; resized();
      assert.equal(scrolls, 1, 'first actual overflow seeds the bottom anchor');
      height = 180; scroll.scrollTop = 80; resized(); resized();
      assert.equal(scrolls, 1, 'remaining animation frames do not write scroll position');
      await act(async () => scroll.dispatchEvent(new dom.window.WheelEvent('wheel', { deltaY: -30, bubbles: true })));
      height = 220; resized();
      assert.equal(scrolls, 1, 'user interruption cancels any following');
      assert.equal(q('short-bottom-anchor')!.style.overflowAnchor, 'none');
    } finally { (globalThis as any).ResizeObserver = previous; }
  });
});

test('actual isolated dedicated WS capture renders active-only production rows', {
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
        assert.doesNotMatch(env.dom.window.document.body.textContent!, /Tools unavailable/);
        await env.advanceMotion();
        assert.equal(q('live-tool-activity'), null);
        unavailable++; continue;
      }
      await env.advanceMotion();
      const rows = frame.snapshot.active;
      if (frame.snapshot.completed_since_last.length >= 2) batch++;
      if (frame.refresh) refresh++;
      if (!rows.length) {assert.equal(q('live-tool-activity'), null); empty++; continue;}
      const content = q('live-tool-activity')!;
      assert.ok(content, 'actual active snapshot renders');
      for (const row of rows) {
        if (row.summary) assert.ok(content.textContent!.includes(row.summary), 'actual sanitized summary is rendered');
      }
      assert.equal(content.querySelectorAll('[data-debug-id="live-tools-summary"]').length, rows.length);
      if (frame.snapshot.active.length) active++;
    }
    assert.ok(active && batch && empty && unavailable && refresh, 'all actual wire display states exercised');
    assert.equal(env.requests, 0, 'captured display consumption makes no REST requests');
  });
});
