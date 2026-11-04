import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act, useRef } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { JSDOM } from 'jsdom';
import ChatMessageList, { PIN_OFFSET_PX, PIN_TRAVEL_MS, PIN_HISTORY_LAG_MS, PIN_ACTIVITY_DELAY_MS, cubicBezierAt } from '../src/ui/components/chat/ChatMessageList.tsx';
import { useComposerDockInset } from '../src/ui/components/chat/MessageComposer.tsx';

// REQ-PIN-1..6: send pin-to-top. JSDOM has no layout, so the fixture gives the scroller a
// fixed viewport (600px tall, 2000px of content) and puts the newest row at y=1900 in
// content coordinates; getBoundingClientRect follows the scroller's scrollTop.

const VIEWPORT = 600;
const ROW_Y = 1900;

const msg = (key: string, isUser: boolean, body = key) => ({ key, messageId: key, body, isUser,
  createdUnixMs: 1, deliveredUnixMs: 0, readUnixMs: 0, deliveryFailedUnixMs: 0 }) as any;
const history = [msg('m1', false, 'First reply'), msg('m2', true, 'Question'), msg('m3', false, 'Previous answer')];
const isLocal = (message: { messageId: string }) => message.messageId.startsWith('local_');

async function withList(run: (env: any) => Promise<void>) {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.test/', pretendToBeVisual: true });
  const names = ['window', 'document', 'HTMLElement', 'Node', 'IS_REACT_ACT_ENVIRONMENT', 'ResizeObserver',
    'IntersectionObserver', 'requestAnimationFrame', 'cancelAnimationFrame'];
  const previous: any = Object.fromEntries(names.map((name) => [name, (globalThis as any)[name]]));
  let nextFrame = 0, scrollToCalls = 0, now = 0;
  const frames = new Map<number, FrameRequestCallback>();
  const observers: Array<(entries: any[]) => void> = [];
  const mediaListeners = new Set<() => void>();
  const media = { matches: false, addEventListener: (_: string, fn: () => void) => mediaListeners.add(fn),
    removeEventListener: (_: string, fn: () => void) => mediaListeners.delete(fn) };
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true, IntersectionObserver: undefined,
    ResizeObserver: class { constructor(cb: (entries: any[]) => void) { observers.push(cb); } observe() {} unobserve() {} disconnect() {} },
    requestAnimationFrame: (fn: FrameRequestCallback) => { frames.set(++nextFrame, fn); return nextFrame; },
    cancelAnimationFrame: (id: number) => frames.delete(id) });
  dom.window.matchMedia = (() => media) as any;
  dom.window.HTMLElement.prototype.scrollTo = function (this: HTMLElement) { scrollToCalls++; };
  const scrollerOf = (el: Element | null) => el?.closest('[data-debug-id$="-scroll"]') as HTMLElement | null;
  dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
    const scroller = scrollerOf(this);
    const top = this.hasAttribute('data-chat-pin-row') && scroller ? ROW_Y - scroller.scrollTop : 0;
    return { top, bottom: top + 40, height: 40, width: 600, x: 0, y: top, left: 0, right: 600, toJSON() {} } as DOMRect;
  };
  const store = configureStore({ reducer: { vault: (s = {}) => s, chat: (s = { session: { userId: 'user1' } }) => s } });
  const root = createRoot(dom.window.document.getElementById('root')!);
  const q = (id: string) => dom.window.document.querySelector('[data-debug-id="' + id + '"]') as HTMLElement | null;
  const render = async (child: React.ReactNode) => {
    await act(async () => { root.render(React.createElement(Provider, { store, children: child })); });
  };
  const list = (messages: any[], extra: Record<string, unknown> = {}) => React.createElement(ChatMessageList, {
    conversationKey: 'chat_pin', debugPrefix: 'pin', messages, pinOnSend: isLocal, bottomInset: 80,
    agentActivity: React.createElement('div', { 'data-debug-id': 'pin-activity' }, 'Working…'), ...extra });
  const geometry = () => {
    const scroll = q('pin-scroll')!;
    let top = VIEWPORT * 2;
    Object.defineProperties(scroll, { scrollHeight: { configurable: true, value: 2000 },
      clientHeight: { configurable: true, value: VIEWPORT },
      scrollTop: { configurable: true, get: () => top, set: (value: number) => { top = value; } } });
    return scroll;
  };
  const frame = async (ms: number) => { now += ms; await act(async () => {
    const queued = [...frames.values()]; frames.clear(); queued.forEach((fn) => fn(now));
  }); };
  const settle = async () => { for (let t = 0; t <= PIN_TRAVEL_MS + PIN_HISTORY_LAG_MS + 32; t += 16) await frame(16); };
  try {
    await run({ dom, q, render, list, geometry, frame, settle, observers,
      scrollToCalls: () => scrollToCalls,
      reduceMotion: async (value: boolean) => { await act(async () => { media.matches = value; mediaListeners.forEach((fn) => fn()); }); } });
  } finally {
    await act(async () => root.unmount());
    assert.equal(frames.size, 0, 'no animation frame survives unmount');
    assert.equal(mediaListeners.size, 0, 'reduced-motion listener removed on unmount');
    Object.assign(globalThis, previous);
    dom.window.close();
  }
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const target = VIEWPORT * 2 + (ROW_Y - VIEWPORT * 2) - PIN_OFFSET_PX; // row top lands PIN_OFFSET_PX under the top

test('pin timing mirrors the motion tokens: 300ms strong ease-out without overshoot', () => {
  assert.equal(PIN_TRAVEL_MS, 300);
  assert.ok(PIN_HISTORY_LAG_MS >= 80 && PIN_HISTORY_LAG_MS <= 120);
  assert.ok(PIN_ACTIVITY_DELAY_MS >= 150 && PIN_ACTIVITY_DELAY_MS <= 250);
  assert.ok(PIN_OFFSET_PX >= 40 && PIN_OFFSET_PX <= 60, 'tail strip is 40-60px');
  let last = 0;
  for (let x = 0; x <= 1.0001; x += 0.05) {
    const y = cubicBezierAt([0.2, 0.8, 0.2, 1], x);
    assert.ok(y >= last - 1e-6 && y <= 1 + 1e-6, 'monotonic, never past 1');
    last = y;
  }
  assert.ok(cubicBezierAt([0.2, 0.8, 0.2, 1], 0.25) > 0.6, 'fast start');
});

test('own send pins the bubble under the header: translateY-only travel, bubble leads history, then fade + delayed activity', async () => {
  await withList(async ({ q, render, list, geometry, frame, settle, ...env }) => {
    await render(list(history));
    const scroll = geometry();
    const before = env.scrollToCalls();
    await render(list([...history, msg('local_a', true, 'New question')]));
    const row = q('pin-message-local_a')!;
    assert.equal(row.getAttribute('data-chat-pin-row'), 'true');
    assert.equal(scroll.dataset.chatPinned, 'true');
    assert.equal(scroll.scrollTop, target, 'scroll jumps to the pinned target before paint');
    assert.equal(env.scrollToCalls(), before, 'no scroll-to-bottom on a pinned send');
    const content = q('pin-messages-container')!;
    const historyStart = content.style.transform;
    assert.match(historyStart, /^translate3d\(0, -?\d+(\.\d+)?px, 0\)$/, 'history starts where it was, via transform only');
    assert.match(row.style.transform, /^translate3d\(0, /, 'bubble starts at the composer, via transform only');
    assert.equal(row.style.opacity, '', 'no fade-in');
    assert.ok(!scroll.className.includes('ui-chat-pin-tail-mask'), 'no tail fade while travelling');
    await frame(16);
    await frame(60);
    assert.equal(content.style.transform, historyStart, 'history holds still while the bubble leads');
    assert.notEqual(row.style.transform, 'translate3d(0, 0px, 0)');
    await settle();
    assert.equal(row.style.transform, '', 'bubble at rest');
    assert.equal(content.style.transform, '', 'history at rest');
    assert.equal(scroll.scrollTop, target);
    assert.ok(scroll.className.includes('ui-chat-pin-tail-mask'), 'tail fade in the pinned resting state');
    assert.ok(!q('pin-pin-tail-blur')!.className.includes('hidden'), 'tail blur strip shown');
    assert.equal(q('pin-pin-tail-blur')!.style.height, PIN_OFFSET_PX + 'px', 'blur covers the tail strip only');
    assert.equal(q('pin-pin-activity-slot')!.style.opacity, '0', 'activity line waits after settle');
    await sleep(PIN_ACTIVITY_DELAY_MS + 40);
    assert.equal(q('pin-pin-activity-slot')!.style.opacity, '', 'activity line appears after the delay');
  });
});

test('while pinned nothing pulls the view to the bottom: inbound rows, tail growth, inset changes', async () => {
  await withList(async ({ q, render, list, geometry, settle, observers, ...env }) => {
    await render(list(history));
    const scroll = geometry();
    await render(list([...history, msg('local_a', true)]));
    await settle();
    const calls = env.scrollToCalls();
    await render(list([...history, msg('local_a', true), msg('reply', false, 'Answer')]));
    await act(async () => { observers.forEach((cb: (entries: any[]) => void) => cb([])); });
    await render(list([...history, msg('local_a', true), msg('reply', false, 'Answer')], { bottomInset: 40 }));
    await act(async () => { scroll.dispatchEvent(new (scroll.ownerDocument.defaultView as any).Event('scroll')); });
    assert.equal(env.scrollToCalls(), calls, 'no scroll-to-bottom while pinned');
    assert.equal(scroll.scrollTop, target, 'bubble stays pinned');
    assert.equal(q('pin-jump-latest-btn'), null);
    assert.equal(scroll.dataset.chatPinned, 'true');
  });
});

test('the composer dock inset never re-pins a send-pinned list to the bottom', async () => {
  const dom = new JSDOM('<div id="root"></div>', { pretendToBeVisual: true });
  const previous: any = { window: globalThis.window, document: globalThis.document, ResizeObserver: (globalThis as any).ResizeObserver, IS_REACT_ACT_ENVIRONMENT: (globalThis as any).IS_REACT_ACT_ENVIRONMENT };
  let fire!: (entries: any[]) => void;
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true,
    ResizeObserver: class { constructor(cb: (entries: any[]) => void) { fire = cb; } observe() {} disconnect() {} } });
  const root = createRoot(dom.window.document.getElementById('root')!);
  function Harness() {
    const dock = useRef<HTMLDivElement | null>(null);
    useComposerDockInset(dock, { insetDebugId: 'h-bottom-inset', resetKey: 'x' });
    return React.createElement('div', null,
      React.createElement('div', { 'data-debug-id': 'h-scroll', 'data-chat-pinned': 'true' },
        React.createElement('div', { 'data-debug-id': 'h-bottom-inset', style: { height: 80 } })),
      React.createElement('div', { ref: dock }));
  }
  try {
    await act(async () => root.render(React.createElement(Harness)));
    const scroll = dom.window.document.querySelector('[data-debug-id="h-scroll"]') as HTMLElement;
    let top = 500;
    Object.defineProperties(scroll, { scrollHeight: { value: 1100 }, clientHeight: { value: 600 },
      scrollTop: { get: () => top, set: (v: number) => { top = v; } } });
    await act(async () => fire([{ borderBoxSize: [{ blockSize: 56 }] }]));
    assert.equal(top, 500, 'pinned list keeps its position');
    assert.equal((dom.window.document.querySelector('[data-debug-id="h-bottom-inset"]') as HTMLElement).style.height, '56px');
    delete scroll.dataset.chatPinned;
    await act(async () => fire([{ borderBoxSize: [{ blockSize: 90 }] }]));
    assert.equal(top, 1100, 'an unpinned bottom reader is still followed');
    await act(async () => root.unmount());
  } finally { Object.assign(globalThis, previous); dom.window.close(); }
});

test('manual scroll-up or jump-latest leaves the pin and removes fade and blur', async () => {
  await withList(async ({ dom, q, render, list, geometry, settle, ...env }) => {
    await render(list(history));
    const scroll = geometry();
    await render(list([...history, msg('local_a', true)]));
    await settle();
    await act(async () => scroll.dispatchEvent(new dom.window.WheelEvent('wheel', { deltaY: -40, bubbles: true })));
    assert.equal(scroll.dataset.chatPinned, undefined);
    assert.ok(!scroll.className.includes('ui-chat-pin-tail-mask'), 'fade removed');
    assert.ok(q('pin-pin-tail-blur')!.className.includes('hidden'), 'blur removed');
    assert.equal(q('pin-message-local_a')!.getAttribute('data-chat-pin-row'), null);
    // Pin again, then jump to latest.
    await render(list([...history, msg('local_a', true), msg('local_b', true)]));
    await settle();
    assert.equal(scroll.dataset.chatPinned, 'true');
    scroll.scrollTop = 100;
    await act(async () => scroll.dispatchEvent(new dom.window.WheelEvent('wheel', { deltaY: -40, bubbles: true })));
    await act(async () => { scroll.dispatchEvent(new dom.window.Event('scroll')); });
    const jump = q('pin-jump-latest-btn');
    assert.ok(jump, 'jump-latest offered once back in history');
    const calls = env.scrollToCalls();
    await act(async () => jump!.click());
    assert.equal(env.scrollToCalls(), calls + 1, 'jump-latest scrolls to the bottom');
    assert.equal(q('pin-pin-turn-spacer')!.style.height, '0px', 'turn spacer released');
  });
});

test('reduced motion jumps straight to the pinned state and keeps the static fade', async () => {
  await withList(async ({ q, render, list, geometry, reduceMotion }) => {
    await render(list(history));
    const scroll = geometry();
    await reduceMotion(true);
    await render(list([...history, msg('local_a', true)]));
    assert.equal(scroll.scrollTop, target);
    assert.equal(q('pin-message-local_a')!.style.transform, '', 'no travel');
    assert.equal(q('pin-messages-container')!.style.transform, '');
    assert.ok(scroll.className.includes('ui-chat-pin-tail-mask'), 'static fade kept');
    assert.ok(!q('pin-pin-tail-blur')!.className.includes('hidden'));
  });
});

test('pin survives the optimistic local_ to server-id key swap and a server copy never re-pins', async () => {
  await withList(async ({ q, render, list, geometry, frame, settle, ...env }) => {
    await render(list(history));
    const scroll = geometry();
    await render(list([...history, msg('local_a', true, 'Hi')]));
    await frame(16);
    await frame(80);
    const calls = env.scrollToCalls();
    // Mid-travel the server id replaces the optimistic row (same index, new key).
    await render(list([...history, msg('srv_a', true, 'Hi')]));
    const swapped = q('pin-message-srv_a')!;
    assert.equal(swapped.getAttribute('data-chat-pin-row'), 'true', 'the server row inherits the pin');
    assert.equal(scroll.scrollTop, target, 'no jump on the swap');
    await frame(16);
    assert.match(swapped.style.transform, /^translate3d\(0, /, 'travel continues on the re-mounted row');
    await settle();
    assert.equal(swapped.style.transform, '');
    assert.equal(scroll.dataset.chatPinned, 'true');
    // A poll delivering a server-side user row (not a local send) appends without re-pinning.
    await render(list([...history, msg('srv_a', true, 'Hi'), msg('srv_b', true, 'From another device')]));
    assert.equal(q('pin-message-srv_b')!.getAttribute('data-chat-pin-row'), null);
    assert.equal(scroll.scrollTop, target);
    assert.equal(env.scrollToCalls(), calls);
  });
});

test('older-page prepend keeps the pinned row and the reader position', async () => {
  await withList(async ({ q, render, list, geometry, settle }) => {
    await render(list(history));
    const scroll = geometry();
    await render(list([...history, msg('local_a', true)]));
    await settle();
    await render(list([msg('m0', false, 'Oldest'), ...history, msg('local_a', true)]));
    assert.equal(q('pin-message-local_a')!.getAttribute('data-chat-pin-row'), 'true');
    assert.equal(q('pin-message-m3')!.getAttribute('data-chat-pin-row'), null);
    assert.equal(scroll.dataset.chatPinned, 'true');
  });
});
