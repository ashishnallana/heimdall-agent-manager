import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act, useRef } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { JSDOM } from 'jsdom';
import ChatMessageList, { PIN_TAIL_PX, PIN_TAIL_MAX_PX, pinOffsetFor, pinTailFor, pinSpacerFor, pinFadeFor, PIN_FADE_RANGE_PX, PIN_TRAVEL_MS, PIN_SETTLE_MS, PIN_ACTIVITY_DELAY_MS, PIN_EASE, PIN_EASE_X, PIN_SCROLL_IDLE_MS, JUMP_THRESHOLD_PX, cubicBezierAt, restingInsetFor, TOP_FADE_PX, topFadeFor } from '../src/ui/components/chat/ChatMessageList.tsx';
import { useComposerDockInset } from '../src/ui/components/chat/MessageComposer.tsx';
import { PaneVisibilityProvider } from '../src/ui/components/workbench/paneVisibility.tsx';

// REQ-PIN-1..6: send pin-to-top. JSDOM has no layout, so the fixture models one: a 600px
// viewport, the first sent row (index 3) at y=1900 in content coordinates and each later
// row 200px further down, every row 40px tall. The exchange (sent row to the end of the
// last row, plus `env.tail.extra`), the turn spacer, the composer inset spacer and a 1px
// anchor make up scrollHeight, and scrollTop clamps to the real range like a browser.

const VIEWPORT = 600;
const ROW_Y = 1900;
const ROW_H = 40;
const rowTop = (index: number) => (index < 3 ? -1000 : ROW_Y + 200 * (index - 3));

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
  dom.window.HTMLElement.prototype.scrollTo = function (this: HTMLElement, options?: ScrollToOptions) {
    scrollToCalls++;
    if (typeof options?.top === 'number') this.scrollTop = options.top;
  };
  const scrollerOf = (el: Element | null) => el?.closest('[data-debug-id$="-scroll"]') as HTMLElement | null;
  const tail = { extra: 0 };
  const px = (el: HTMLElement | null) => parseFloat(el?.style.height ?? '') || 0;
  const indexOf = (el: Element | null) => Number(el?.closest('[data-chat-pin-index]')?.getAttribute('data-chat-pin-index') ?? -1);
  const lastIndex = () => dom.window.document.querySelectorAll('[data-chat-pin-index]').length - 1;
  // The last row is ROW_H + tail.extra tall (a long reply), the others ROW_H.
  dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
    const scroller = scrollerOf(this);
    const index = indexOf(this);
    const top = index >= 0 && scroller ? rowTop(index) - scroller.scrollTop : 0;
    const height = index >= 0 && index === lastIndex() ? ROW_H + tail.extra : ROW_H;
    return { top, bottom: top + height, height, width: 600, x: 0, y: top, left: 0, right: 600, toJSON() {} } as DOMRect;
  };
  const lastRowBottom = () => rowTop(lastIndex()) + ROW_H + tail.extra;
  Object.defineProperties(dom.window.HTMLElement.prototype, {
    offsetTop: { configurable: true, get(this: HTMLElement) {
      if (this.dataset.debugId === 'pin-pin-turn-spacer') return lastRowBottom();
      const index = this.hasAttribute('data-chat-pin-index') ? indexOf(this) : -1;
      return index >= 0 ? rowTop(index) : 0;
    } },
    offsetHeight: { configurable: true, get(this: HTMLElement) {
      if (this.dataset.debugId === 'pin-bottom-anchor') return 1;
      if (this.dataset.debugId === 'pin-bottom-inset' || this.dataset.debugId === 'pin-pin-turn-spacer') return px(this);
      return 0;
    } },
  });
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
    const height = () => lastRowBottom() + px(q('pin-pin-turn-spacer')) + px(q('pin-bottom-inset')) + 1;
    let top = VIEWPORT * 2;
    let client = VIEWPORT;
    // Programmatic scrollTop writes, for the "never during a gesture" checks.
    const writes: number[] = [];
    Object.defineProperties(scroll, { scrollHeight: { configurable: true, get: height },
      clientHeight: { configurable: true, get: () => client },
      scrollTop: { configurable: true, get: () => top,
        set: (value: number) => { writes.push(value); top = Math.max(0, Math.min(value, height() - client)); } },
      writes: { configurable: true, value: writes },
      setClientHeight: { configurable: true, value: (value: number) => { client = value; } } });
    return scroll;
  };
  const frame = async (ms: number) => { now += ms; await act(async () => {
    const queued = [...frames.values()]; frames.clear(); queued.forEach((fn) => fn(now));
  }); };
  const settle = async () => { for (let t = 0; t <= PIN_SETTLE_MS + 32; t += 16) await frame(16); };
  try {
    await run({ dom, q, render, list, geometry, frame, settle, observers, tail,
      scrollToCalls: () => scrollToCalls,
      reduceMotion: async (value: boolean) => { await act(async () => { media.matches = value; mediaListeners.forEach((fn) => fn()); }); } });
  } finally {
    await act(async () => root.unmount());
    assert.equal(frames.size, 0, 'no animation frame survives unmount');
    delete (dom.window.HTMLElement.prototype as any).offsetTop;
    delete (dom.window.HTMLElement.prototype as any).offsetHeight;
    assert.equal(mediaListeners.size, 0, 'reduced-motion listener removed on unmount');
    Object.assign(globalThis, previous);
    dom.window.close();
  }
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
// The fixture's previous message ends far above the new row, so the tail is the maximum.
const OFFSET = PIN_TAIL_MAX_PX;
const target = ROW_Y - OFFSET; // row top lands OFFSET under the top
const INSET = 80;
// Exchange spacer for a short reply: viewport - slot - (row + inset + anchor).
const SPACER = VIEWPORT - OFFSET - (ROW_H + INSET + 1);
// REQ-PIN-3 rev3: the fade lives on fixed overlays outside the scroller (blur, then colour).
const fade = (scroll: HTMLElement) => {
  const overlay = scroll.ownerDocument.querySelector('[data-debug-id="pin-pin-tail-fade"]') as HTMLElement;
  assert.equal(overlay.style.opacity, (scroll.ownerDocument.querySelector('[data-debug-id="pin-pin-tail-blur"]') as HTMLElement).style.opacity, 'blur and fade move together');
  return overlay.style.opacity;
};
// Nothing on the scroller itself follows the scroll (no mask, no custom property).
const scrollerUntouched = (scroll: HTMLElement) => {
  assert.equal(scroll.dataset.chatPinTail, undefined, 'no mask toggled on the scroller');
  assert.equal(scroll.style.getPropertyValue('--chat-pin-fade'), '', 'no per-scroll custom property on the scroller');
};
const scrollTo = async (scroll: HTMLElement, top: number) => {
  scroll.scrollTop = top;
  await act(async () => { scroll.dispatchEvent(new (scroll.ownerDocument.defaultView as any).Event('scroll')); });
};

test('pin timing (REQ-PIN-1 rev4): curved ~550ms, no overshoot', () => {
  assert.ok(PIN_TRAVEL_MS >= 500 && PIN_TRAVEL_MS <= 600, 'curved travel ~550ms');
  assert.equal(PIN_SETTLE_MS, PIN_TRAVEL_MS, 'bubble and list settle together');
  assert.ok(PIN_ACTIVITY_DELAY_MS >= 150 && PIN_ACTIVITY_DELAY_MS <= 250);
  assert.deepEqual(PIN_EASE, [0.4, 0, 0.2, 1]);
  assert.deepEqual(PIN_EASE_X, [0.45, 0, 0.25, 1]);
  for (const ease of [PIN_EASE, PIN_EASE_X]) {
    let last = 0;
    for (let x = 0; x <= 1.0001; x += 0.05) {
      const y = cubicBezierAt(ease, x);
      assert.ok(y >= last - 1e-6 && y <= 1 + 1e-6, 'monotonic, never past 1');
      last = y;
    }
  }
  // User direction 2026-11-04 13:04: the travel starts slow, so a late first frame on a
  // phone covers almost none of the distance (the old ease-out covered ~12% in 16ms).
  for (const ease of [PIN_EASE, PIN_EASE_X]) assert.ok(cubicBezierAt(ease, 16 / PIN_TRAVEL_MS) < 0.01, 'slow start');
  for (const x of [0.25, 0.5]) assert.ok(cubicBezierAt(PIN_EASE_X, x) < cubicBezierAt(PIN_EASE, x) - 0.03, 'X lags Y, so the path curves');
});

test('the tail keeps the previous last line and action row, below any floating header', () => {
  assert.equal(pinTailFor(12 + 48, 26), 86, 'phone: gap + action row + one line');
  assert.equal(pinTailFor(0, 0), PIN_TAIL_PX, 'never less than PIN_TAIL_PX');
  assert.equal(pinTailFor(900, 26), PIN_TAIL_MAX_PX, 'never more than PIN_TAIL_MAX_PX');
  assert.ok(PIN_TAIL_PX >= 40 && PIN_TAIL_PX <= 60);
  assert.equal(pinOffsetFor(0), PIN_TAIL_PX);
  assert.equal(pinOffsetFor(64, 56), 120, 'pt-16 under a floating header: the slot starts below it');
});

test('REQ-PIN-2 rev2: the exchange spacer fills the view below the slot, counting the composer inset', () => {
  assert.equal(pinSpacerFor(600, 96, 40 + 80 + 1), 383, 'short reply: the rest of the view');
  assert.equal(pinSpacerFor(600, 96, 900), 0, 'a reply taller than the view needs no spacer');
  assert.equal(pinFadeFor(0), 1, 'fully on at the end of the range');
  assert.equal(pinFadeFor(1), 1, 'sub-pixel rubber band still counts as the end');
  assert.equal(pinFadeFor(PIN_FADE_RANGE_PX / 2), 0.5, 'interpolated as the reader scrolls up');
  assert.equal(pinFadeFor(PIN_FADE_RANGE_PX), 0);
  assert.equal(pinFadeFor(500), 0);
  assert.ok(PIN_FADE_RANGE_PX >= 40 && PIN_FADE_RANGE_PX <= 80);
});

test('own send pins the bubble at max scroll: transform-only travel with the tail on throughout, then delayed activity', async () => {
  await withList(async ({ q, render, list, geometry, frame, settle, ...env }) => {
    await render(list(history));
    const scroll = geometry();
    const before = env.scrollToCalls();
    await render(list([...history, msg('local_a', true, 'New question')]));
    const row = q('pin-message-local_a')!;
    assert.equal(row.getAttribute('data-chat-pin-row'), 'true');
    assert.equal(scroll.dataset.chatPinned, 'true');
    assert.equal(q('pin-pin-turn-spacer')!.style.height, SPACER + 'px', 'exchange sized to the view');
    assert.equal(scroll.scrollTop, target, 'scroll jumps to the pin position before paint');
    assert.equal(scroll.scrollHeight - scroll.clientHeight, target, 'which is the end of the scroll range');
    assert.equal(env.scrollToCalls(), before, 'no scroll-to-bottom on a pinned send');
    const content = q('pin-messages-container')!;
    const historyStart = content.style.transform;
    assert.match(historyStart, /^translate3d\(0, -?\d+(\.\d+)?px, 0\)$/, 'history starts where it was, via transform only');
    assert.match(row.style.transform, /^translate3d\(-?0(px)?, -?\d+(\.\d+)?px, 0(px)?\)$/, 'bubble starts under the dock (no origin given: list left), via transform only');
    assert.equal(row.style.opacity, '', 'no fade-in');
    assert.equal(fade(scroll), '1', 'tail fade on during the travel (REQ-PIN-3 rev2)');
    scrollerUntouched(scroll);
    assert.equal(q('pin-pin-tail-blur')!.style.opacity, '1', 'tail blur on during the travel');
    await frame(16);
    await frame(60);
    assert.notEqual(content.style.transform, historyStart, 'history moves from the first frame, with the bubble');
    await settle();
    assert.equal(row.style.transform, '', 'bubble at rest');
    assert.equal(content.style.transform, '', 'history at rest');
    assert.equal(scroll.scrollTop, target);
    assert.equal(fade(scroll), '1', 'tail fade at rest');
    assert.equal(q('pin-pin-tail-blur')!.style.height, OFFSET + 'px', 'blur covers the tail strip only');
    assert.equal(q('pin-pin-tail-blur')!.style.top, '0px', 'unpadded: the strip starts at the top');
    assert.equal(q('pin-pin-activity-slot')!.style.opacity, '0', 'activity line waits after settle');
    await sleep(PIN_ACTIVITY_DELAY_MS + 40);
    assert.equal(q('pin-pin-activity-slot')!.style.opacity, '', 'activity line appears after the delay');
  });
});

{
  test('REQ-PIN-1 rev4: the bubble starts at the composer text (read before the insert); Y and the list share one curve', async () => {
    await withList(async ({ dom, q, render, list, geometry, frame, settle }) => {
      const input = dom.window.document.createElement('textarea');
      input.style.padding = '0';
      input.style.border = '0';
      let inputTop = 560;
      input.getBoundingClientRect = () => ({ left: -240, top: inputTop, right: 0, bottom: inputTop + 24, width: 240, height: 24, x: -240, y: inputTop, toJSON() {} }) as DOMRect;
      const origin = { current: input };
      // The composer moves in the commit that inserts the row (draft cleared, collapse):
      // the start must be the position read before that commit.
      function Host({ messages, moveInput }: { messages: any[]; moveInput: boolean }) {
        React.useLayoutEffect(() => { if (moveInput) inputTop = 700; });
        return list(messages, { pinOriginRef: origin });
      }
      await render(React.createElement(Host, { messages: history, moveInput: false }));
      const scroll = geometry();
      await render(React.createElement(Host, { messages: [...history, msg('local_a', true, 'New question')], moveInput: true }));
      const row = q('pin-message-local_a')!;
      const content = q('pin-messages-container')!;
      const nums = (value: string) => (value.match(/-?\d+(\.\d+)?(?=px)/g) ?? []).map(Number);
      const inner = row.firstElementChild as HTMLElement;
      const axes = (value: string) => (value.match(/translate3d\(([^,]+),\s*([^,]+),/)?.slice(1) ?? ['0', '0']).map((v) => parseFloat(v) || 0);
      const at = () => {
        const y = axes(row.style.transform)[1];
        const x = axes(inner.style.transform)[0];
        const history = nums(content.style.transform)[0] ?? 0;
        return { x, y: y + history, history, rowY: y }; // the bubble's offset from its slot, on screen
      };
      const start = at();
      assert.equal(start.x, -240, 'starts at the composer text\'s left edge');
      assert.equal(start.y, 560 - OFFSET, 'starts at the composer text\'s top, as read before the insert');
      for (let t = 0; t < 160; t += 16) await frame(16);
      const mid = at();
      const yLeft = mid.history / start.history;
      assert.ok(yLeft > 0.05 && yLeft < 0.95, 'mid-travel');
      assert.ok(Math.abs(mid.rowY / (start.rowY || 1) - yLeft) < 1e-6 || start.rowY === 0, 'bubble Y on the list\'s curve');
      const xLeft = mid.x / start.x;
      assert.ok(xLeft - yLeft > 0.05, 'X lags Y, so the path bends');
      await settle();
      assert.equal(row.style.transform, '', 'bubble at rest in its slot');
      assert.equal(inner.style.transform, '', 'no X offset left');
      assert.equal(content.style.transform, '', 'list at rest');
      assert.equal(scroll.scrollTop, target);
    });
  });
}

test('with WAAPI the list and the bubble (Y and X on their own curves) run on the compositor and settle on finish', async () => {
  await withList(async ({ dom, q, render, list, geometry }) => {
    const calls: Array<{ el: HTMLElement; frames: Keyframe[]; timing: KeyframeAnimationOptions; anim: any }> = [];
    (dom.window.HTMLElement.prototype as any).animate = function (this: HTMLElement, frames: Keyframe[], timing: KeyframeAnimationOptions) {
      const anim: any = { currentTime: 0, onfinish: null, cancelled: false, cancel() { this.cancelled = true; } };
      calls.push({ el: this, frames, timing, anim });
      return anim;
    };
    await render(list(history));
    const scroll = geometry();
    await render(list([...history, msg('local_a', true, 'New question')]));
    const row = q('pin-message-local_a')!;
    assert.equal(calls.length, 3, 'the list, the bubble\'s Y and the bubble\'s X');
    assert.deepEqual(calls.map((c) => c.el), [q('pin-messages-container'), row, row.firstElementChild], 'Y on the row, X on its column');
    assert.deepEqual(calls.map((c) => c.timing.duration), [PIN_TRAVEL_MS, PIN_TRAVEL_MS, PIN_TRAVEL_MS]);
    assert.deepEqual(calls.map((c) => c.timing.easing), ['cubic-bezier(0.4, 0, 0.2, 1)', 'cubic-bezier(0.4, 0, 0.2, 1)', 'cubic-bezier(0.45, 0, 0.25, 1)']);
    assert.equal(calls[1].frames[1].transform, 'translate3d(0, 0, 0)');
    assert.match(String(calls[2].frames[0].transform), /^translate3d\(-?\d+(\.\d+)?px, 0, 0\)$/, 'X is a transform too (composited), not the translate property');
    assert.equal(calls[2].frames[1].transform, 'translate3d(0, 0, 0)');
    assert.equal(row.style.zIndex, '1', 'the bubble draws above the list while it moves');
    assert.equal(fade(scroll), '1', 'tail on while travelling');
    // Mid-travel key swap: the re-mounted row picks up both animations in step.
    calls[0].anim.currentTime = 120;
    await render(list([...history, msg('srv_a', true, 'New question')]));
    assert.equal(calls.length, 5);
    assert.deepEqual([calls[3].el, calls[4].el], [q('pin-message-srv_a'), q('pin-message-srv_a')!.firstElementChild]);
    assert.deepEqual([calls[3].anim.currentTime, calls[4].anim.currentTime], [120, 120], 'in step with the list');
    assert.ok(calls[1].anim.cancelled && calls[2].anim.cancelled, 'the old row\'s animations are dropped');
    await act(async () => { calls[0].anim.onfinish(); });
    assert.equal(fade(scroll), '1', 'resting at the pin position');
    assert.equal(q('pin-message-srv_a')!.style.zIndex, '', 'stacking reset at rest');
    delete (dom.window.HTMLElement.prototype as any).animate;
  });
});

test('nothing pulls the view to the bottom: inbound rows and tail growth leave scrollTop alone', async () => {
  await withList(async ({ q, render, list, geometry, settle, observers, tail, ...env }) => {
    await render(list(history));
    const scroll = geometry();
    await render(list([...history, msg('local_a', true)]));
    await settle();
    const calls = env.scrollToCalls();
    tail.extra = 60; // activity / tool rows grow under the bubble
    await act(async () => { observers.forEach((cb: (entries: any[]) => void) => cb([])); });
    assert.equal(q('pin-pin-turn-spacer')!.style.height, SPACER - 60 + 'px', 'the spacer absorbs exchange growth');
    tail.extra = 0;
    await render(list([...history, msg('local_a', true), msg('reply', false, 'Answer')]));
    await act(async () => { scroll.dispatchEvent(new (scroll.ownerDocument.defaultView as any).Event('scroll')); });
    assert.equal(env.scrollToCalls(), calls, 'no scroll-to-bottom');
    assert.equal(scroll.scrollTop, target, 'bubble stays at the pin position');
    assert.equal(scroll.scrollHeight - scroll.clientHeight, target, 'and that is still the end of the range');
    assert.equal(q('pin-jump-latest-btn'), null);
  });
});

test('REQ-PIN-2 rev3 (decouple): the composer and the keyboard overlay the list; no spacer or scrollTop change', async () => {
  await withList(async ({ dom, q, render, list, geometry, settle }) => {
    const viewport = new dom.window.EventTarget();
    Object.defineProperty(dom.window, 'visualViewport', { configurable: true, value: viewport });
    await render(list(history));
    const scroll = geometry();
    await render(list([...history, msg('local_a', true)]));
    await settle();
    const spacer = q('pin-pin-turn-spacer')!;
    const inset = q('pin-bottom-inset')!;
    assert.equal(spacer.style.height, SPACER + 'px');
    assert.equal(scroll.scrollHeight - scroll.clientHeight, target, 'resting composer: max scroll = the pin position');
    const writes = (scroll as any).writes.length;
    // The composer expands (focus, multi-line draft, attachments): it only overlays.
    await render(list([...history, msg('local_a', true)], { bottomInset: 194 }));
    assert.equal(spacer.style.height, SPACER + 'px', 'the exchange spacer ignores the live inset');
    assert.equal(inset.style.height, INSET + 'px', 'the inset stays at the resting composer height');
    assert.equal(inset.style.getPropertyValue('--chat-live-inset'), '194px', 'it only learns the live height');
    assert.equal(inset.style.getPropertyValue('--chat-turn-spacer'), SPACER + 'px', 'which reaches past the spacer only for a long reply');
    assert.match(inset.style.minHeight, /calc\(var\(--chat-live-inset.*--chat-turn-spacer/);
    assert.equal(scroll.scrollTop, target, 'content does not move');
    assert.equal(scroll.scrollHeight - scroll.clientHeight, target);
    // The keyboard pans or resizes the visual viewport: nothing listens to it.
    (scroll as any).setClientHeight(VIEWPORT - 300);
    await act(async () => { viewport.dispatchEvent(new dom.window.Event('resize')); });
    assert.equal(spacer.style.height, SPACER + 'px', 'no visualViewport-driven re-size');
    (scroll as any).setClientHeight(VIEWPORT);
    await render(list([...history, msg('local_a', true)], { bottomInset: INSET }));
    assert.equal(spacer.style.height, SPACER + 'px', 'collapsing back changes nothing either');
    assert.equal((scroll as any).writes.length, writes, 'no scrollTop write for any composer or keyboard change');
    delete (dom.window as any).visualViewport;
  });
});

test('the resting reference is the smallest settled inset (the collapsed pill), learnt once', () => {
  assert.equal(restingInsetFor(0, 0), 0, 'no dock yet');
  assert.equal(restingInsetFor(0, 194), 194, 'opened while expanded: provisional');
  assert.equal(restingInsetFor(194, 78), 78, 'the first collapse sets it');
  assert.equal(restingInsetFor(78, 194), 78, 'expanding never raises it');
  assert.equal(restingInsetFor(78, 0), 78, 'a missing measurement keeps it');
});

test('user QA 13:24: jump-latest shows only while the last content is below the composer top', async () => {
  await withList(async ({ q, render, list, geometry, settle, observers, tail }) => {
    await render(list(history));
    const scroll = geometry();
    await render(list([...history, msg('local_a', true)]));
    await settle();
    assert.equal(q('pin-jump-latest-btn'), null, 'at rest after a send: only the bubble, above the composer');
    await render(list([...history, msg('local_a', true), msg('reply', false, 'Short answer')]));
    tail.extra = 30;
    await act(async () => { observers.forEach((cb: (entries: any[]) => void) => cb([])); });
    const spacer = q('pin-pin-turn-spacer')!;
    const spacerHeight = spacer.style.height;
    await scrollTo(scroll, target);
    assert.equal(q('pin-jump-latest-btn'), null, 'at rest after a short reply: the spacer is not unread content');
    // The reply (index 4) ends at 2100 + ROW_H + 30 in content coordinates; the composer's
    // top edge is VIEWPORT - INSET on screen.
    const hiddenUntil = 2100 + ROW_H + 30 - (VIEWPORT - INSET);
    await scrollTo(scroll, hiddenUntil + 5);
    assert.ok(target - scroll.scrollTop > JUMP_THRESHOLD_PX, 'well above max scroll (the old rule fired here)');
    assert.equal(q('pin-jump-latest-btn'), null, 'the spacer scrolled under the composer: last content still visible');
    await scrollTo(scroll, hiddenUntil - 20);
    const jump = q('pin-jump-latest-btn');
    assert.ok(jump, 'the last content is below the composer top: offered');
    await act(async () => jump!.click());
    assert.equal(scroll.scrollTop, target, 'tapping it returns to the pin position');
    assert.equal(q('pin-jump-latest-btn'), null, 'and hides it');
    // The composer's live top counts (an expanded draft covers the reply), but only for
    // this check: the spacer and scrollTop do not move.
    await scrollTo(scroll, hiddenUntil + 5);
    const writes = (scroll as any).writes.length;
    await render(list([...history, msg('local_a', true), msg('reply', false, 'Short answer')], { bottomInset: INSET + 120 }));
    assert.ok(q('pin-jump-latest-btn'), 'an expanded composer covers the reply: offered');
    assert.equal(spacer.style.height, spacerHeight, 'no spacer re-size from the composer');
    assert.equal((scroll as any).writes.length, writes, 'no scrollTop write from the composer');
    await render(list([...history, msg('local_a', true), msg('reply', false, 'Short answer')]));
    assert.equal(q('pin-jump-latest-btn'), null, 'collapsed again: hidden');
    // The reply grows past the composer with no scroll event: re-checked on the resize.
    await scrollTo(scroll, target);
    tail.extra = 400;
    await act(async () => { observers.forEach((cb: (entries: any[]) => void) => cb([])); });
    assert.ok(q('pin-jump-latest-btn'), 'a growing reply that runs under the composer is offered');
    tail.extra = 0;
  });
});

test('QA round 5: no spacer shrink and no scrollTop write while the reader scrolls; the re-size lands when idle', async () => {
  await withList(async ({ dom, q, render, list, geometry, settle, observers, tail }) => {
    await render(list(history));
    const scroll = geometry();
    await render(list([...history, msg('local_a', true)]));
    await settle();
    const spacer = q('pin-pin-turn-spacer')!;
    const writes = (scroll as any).writes.length;
    const Touch = (dom.window as any).TouchEvent ?? dom.window.Event;
    await act(async () => { scroll.dispatchEvent(new Touch('touchstart', { bubbles: true })); });
    await scrollTo(scroll, target - 20);
    const writesInGesture = (scroll as any).writes.length;
    // Mid-gesture the exchange grows (activity / tool rows) and the scroller shrinks.
    tail.extra = 60;
    (scroll as any).setClientHeight(VIEWPORT - 100);
    await act(async () => { observers.forEach((cb: (entries: any[]) => void) => cb([])); });
    await render(list([...history, msg('local_a', true)], { bottomInset: 194 }));
    assert.equal(spacer.style.height, SPACER + 'px', 'no shrink during the gesture');
    assert.equal((scroll as any).writes.length, writesInGesture, 'no programmatic scrollTop write during the gesture');
    await act(async () => { scroll.dispatchEvent(new Touch('touchend', { bubbles: true })); });
    await sleep(PIN_SCROLL_IDLE_MS / 2);
    assert.equal(spacer.style.height, SPACER + 'px', 'momentum may still be running');
    await act(async () => { await sleep(PIN_SCROLL_IDLE_MS + 40); });
    assert.equal(spacer.style.height, SPACER - 60 - 100 + 'px', 'the deferred re-size lands once idle');
    assert.equal((scroll as any).writes.length - writes, 1, 'the only write was the reader\'s own scroll');
    tail.extra = 0;
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
    // REQ-PIN-2 rev3: a decoupled (pinOnSend) list keeps its resting inset and is never scrolled.
    const inset = dom.window.document.querySelector('[data-debug-id="h-bottom-inset"]') as HTMLElement;
    inset.dataset.chatBottomInset = 'fixed';
    top = 1100 - 600;
    await act(async () => fire([{ borderBoxSize: [{ blockSize: 194 }] }]));
    assert.equal(inset.style.height, '90px', 'height untouched');
    assert.equal(inset.style.getPropertyValue('--chat-live-inset'), '194px', 'only the live height is published');
    assert.equal(top, 500, 'no scrollTop write');
    await act(async () => root.unmount());
  } finally { Object.assign(globalThis, previous); dom.window.close(); }
});

test('round 3: scroll up, then back down to the end, lands the bubble at the pin position with the spacer unchanged', async () => {
  await withList(async ({ q, render, list, geometry, settle }) => {
    await render(list(history));
    const scroll = geometry();
    await render(list([...history, msg('local_a', true)]));
    await settle();
    const spacer = q('pin-pin-turn-spacer')!;
    assert.equal(spacer.style.height, SPACER + 'px');
    await scrollTo(scroll, target - 300);
    assert.equal(spacer.style.height, SPACER + 'px', 'scrolling never changes the layout');
    assert.equal(scroll.dataset.chatPinned, 'true', 'there is no unpinned mode to fall into');
    assert.equal(q('pin-message-local_a')!.getAttribute('data-chat-pin-row'), 'true');
    await scrollTo(scroll, target + 3);
    assert.equal(scroll.scrollTop, target, 'a small downward drift is clamped by the layout, not by a mode');
    await scrollTo(scroll, 1e6);
    assert.equal(scroll.scrollTop, target, 'scrolling down stops with the bubble at the pin position');
    assert.equal(q('pin-message-local_a')!.getBoundingClientRect().top, OFFSET);
    assert.equal(spacer.style.height, SPACER + 'px');
  });
});

test('the tail mask and blur follow the scroll distance from the end', async () => {
  await withList(async ({ q, render, list, geometry, settle }) => {
    await render(list(history));
    const scroll = geometry();
    await render(list([...history, msg('local_a', true)]));
    await settle();
    const blur = q('pin-pin-tail-blur')!;
    assert.equal(fade(scroll), '1');
    await scrollTo(scroll, target - PIN_FADE_RANGE_PX / 2);
    assert.equal(fade(scroll), '0.5', 'half way through the fade range');
    assert.equal(blur.style.opacity, '0.5');
    scrollerUntouched(scroll);
    await scrollTo(scroll, target - 400);
    assert.equal(fade(scroll), '0', 'history looks normal once scrolled up');
    assert.equal(blur.style.opacity, '0');
    scrollerUntouched(scroll);
    await scrollTo(scroll, target);
    assert.equal(fade(scroll), '1', 'back on at the pin position');
  });
});

test('a reply taller than the view needs no spacer and is not followed; jump-latest goes to its end', async () => {
  await withList(async ({ q, render, list, geometry, settle, observers, tail, ...env }) => {
    await render(list(history));
    const scroll = geometry();
    await render(list([...history, msg('local_a', true)]));
    await settle();
    tail.extra = 900;
    await render(list([...history, msg('local_a', true), msg('reply', false, 'A very long answer')]));
    await act(async () => { observers.forEach((cb: (entries: any[]) => void) => cb([])); });
    const spacer = q('pin-pin-turn-spacer')!;
    assert.equal(spacer.style.height, '0px', 'the exchange fills the view on its own');
    assert.equal(scroll.scrollTop, target, 'not auto-followed while the reply renders');
    await scrollTo(scroll, target);
    const jump = q('pin-jump-latest-btn');
    assert.ok(jump, 'jump-latest offered while the reply continues below');
    const calls = env.scrollToCalls();
    await act(async () => jump!.click());
    assert.equal(env.scrollToCalls(), calls + 1, 'jump-latest scrolls to the end of the range');
    await scrollTo(scroll, 1e6);
    assert.equal(scroll.scrollTop, scroll.scrollHeight - VIEWPORT, 'the reply\'s end is reachable');
    assert.ok(scroll.scrollTop > target);
    assert.equal(fade(scroll), '0', 'the end of a long reply is not masked');
    await scrollTo(scroll, target);
    assert.equal(fade(scroll), '1', 'the tail is back at the pin position');
    assert.equal(spacer.style.height, '0px');
  });
});

test('a new send moves the space to the new exchange in the same pass', async () => {
  await withList(async ({ q, render, list, geometry, settle }) => {
    await render(list(history));
    const scroll = geometry();
    await render(list([...history, msg('local_a', true)]));
    await settle();
    await render(list([...history, msg('local_a', true), msg('reply', false, 'Answer')]));
    await render(list([...history, msg('local_a', true), msg('reply', false, 'Answer'), msg('local_b', true)]));
    assert.equal(q('pin-message-local_a')!.getAttribute('data-chat-pin-row'), null, 'the previous exchange gives up its space');
    assert.equal(q('pin-message-local_b')!.getAttribute('data-chat-pin-row'), 'true');
    assert.equal(q('pin-pin-turn-spacer')!.style.height, SPACER + 'px', 'the new exchange is sized');
    assert.equal(scroll.scrollTop, rowTop(5) - OFFSET, 'travels to the new pin position');
    assert.equal(scroll.scrollHeight - scroll.clientHeight, rowTop(5) - OFFSET);
    await settle();
  });
});

test('a scroll-up gesture during the travel lands it at once', async () => {
  await withList(async ({ dom, q, render, list, geometry, frame }) => {
    await render(list(history));
    const scroll = geometry();
    await render(list([...history, msg('local_a', true)]));
    await frame(16);
    await act(async () => scroll.dispatchEvent(new dom.window.WheelEvent('wheel', { deltaY: -40, bubbles: true })));
    assert.equal(q('pin-message-local_a')!.style.transform, '', 'bubble at rest');
    assert.equal(q('pin-messages-container')!.style.transform, '', 'history at rest');
    assert.equal(scroll.dataset.chatPinned, 'true', 'the exchange keeps its space');
  });
});

test('reduced motion jumps straight to the pin position and keeps the static fade', async () => {
  await withList(async ({ q, render, list, geometry, reduceMotion }) => {
    await render(list(history));
    const scroll = geometry();
    await reduceMotion(true);
    await render(list([...history, msg('local_a', true)]));
    assert.equal(scroll.scrollTop, target);
    assert.equal(q('pin-message-local_a')!.style.transform, '', 'no travel');
    assert.equal(q('pin-messages-container')!.style.transform, '');
    assert.equal(fade(scroll), '1', 'static fade kept');
    assert.equal(q('pin-pin-tail-blur')!.style.opacity, '1');
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
    assert.match(swapped.style.transform, /^translate3d\(/, 'travel continues on the re-mounted row');
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

test('older-page prepend keeps the pinned row', async () => {
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

// A pin-enabled list whose rule never matches, so the fixture keeps its row indices.
const never = () => false;

test('user QA round 3: an incoming message never moves the list, at rest at the bottom or scrolled up', async () => {
  await withList(async ({ render, list, geometry, frame, ...env }) => {
    await render(list(history, { pinOnSend: never }));
    const scroll = geometry();
    const calls = env.scrollToCalls();
    const atRest = scroll.scrollTop;
    await render(list([...history, msg('in_a', false, 'Inbound')], { pinOnSend: never }));
    await frame(16);
    assert.equal(scroll.scrollTop, atRest, 'at the bottom: not followed');
    await scrollTo(scroll, 300);
    await render(list([...history, msg('in_a', false, 'Inbound'), msg('in_b', false, 'More')], { pinOnSend: never }));
    await frame(16);
    assert.equal(scroll.scrollTop, 300, 'scrolled up: not yanked');
    assert.equal(env.scrollToCalls(), calls, 'no scroll-to-bottom for inbound rows');
  });
});

// REQ-PIN-4: the 30-row newest page slide. A send in a conversation of 30+ messages is
// followed by a refetch whose page no longer holds the oldest row.
const longHistory = Array.from({ length: 31 }, (_, i) => msg(`h${i}`, i % 2 === 1, `Row ${i}`));
// The pane keeps the optimistic row's key across the ack (REQ-PIN-2).
const acked = (id: string, key: string, body: string) => ({ ...msg(id, true, body), key });
const pinnedRow = (env: any) => env.dom.window.document.querySelector('[data-chat-pin-row="true"]') as HTMLElement | null;

test('REQ-PIN-4a: 30+ rows, send, id swap, then a refetch without the oldest row keeps the pin, the spacer and the view', async () => {
  await withList(async (env) => {
    const { q, render, list, geometry, settle } = env;
    await render(list(longHistory));
    const scroll = geometry();
    await render(list([...longHistory, msg('local_a', true, 'New question')]));
    await settle();
    const spacer = q('pin-pin-turn-spacer')!.style.height;
    const top = pinnedRow(env)!.getBoundingClientRect().top;
    const calls = env.scrollToCalls();
    await render(list([...longHistory, acked('srv_a', 'local_a', 'New question')]));
    assert.equal(pinnedRow(env), q('pin-message-srv_a'), 'the ack keeps the pin on the same row');
    // The newest page slid: the oldest row is gone (31 -> 30 history rows).
    await render(list([...longHistory.slice(1), acked('srv_a', 'local_a', 'New question')]));
    assert.equal(pinnedRow(env), q('pin-message-srv_a'), 'the trim never unpins');
    assert.equal(scroll.dataset.chatPinned, 'true');
    assert.equal(q('pin-pin-turn-spacer')!.style.height, spacer, 'the exchange spacer is unchanged');
    assert.equal(pinnedRow(env)!.getBoundingClientRect().top, top, 'the bubble stays where it was pinned');
    assert.equal(env.scrollToCalls(), calls, 'nothing scrolls to the bottom');
  });
});

test('REQ-PIN-4b: with older rows loaded, a refetch that trims the top and appends the reply keeps the pin on the sent row', async () => {
  await withList(async (env) => {
    const { q, render, list, geometry, settle } = env;
    const older = [msg('o1', false, 'Older one'), msg('o2', true, 'Older two')];
    await render(list(longHistory));
    geometry();
    await render(list([...older, ...longHistory]));
    await render(list([...older, ...longHistory, msg('local_a', true, 'New question')]));
    await settle();
    const top = pinnedRow(env)!.getBoundingClientRect().top;
    const calls = env.scrollToCalls();
    // Same row count, every index shifted: the old index now points at the reply.
    await render(list([...older.slice(1), ...longHistory, acked('srv_a', 'local_a', 'New question'), msg('r1', false, 'Reply')]));
    assert.equal(pinnedRow(env), q('pin-message-srv_a'), 'the pin follows the row, not the index');
    assert.equal(q('pin-message-r1')!.getAttribute('data-chat-pin-row'), null);
    assert.equal(pinnedRow(env)!.getBoundingClientRect().top, top, 'no scroll-back');
    assert.equal(env.scrollToCalls(), calls);
  });
});

test('REQ-PIN-4c: the server echo arriving before the POST resolves neither re-pins nor scrolls back', async () => {
  await withList(async (env) => {
    const { q, render, list, geometry, settle } = env;
    await render(list(longHistory));
    const scroll = geometry();
    await render(list([...longHistory, msg('local_a', true, 'New question')]));
    await settle();
    const top = pinnedRow(env)!.getBoundingClientRect().top;
    const calls = env.scrollToCalls();
    // A caller that has not folded the echo yet shows both rows for a moment.
    await render(list([...longHistory, msg('local_a', true, 'New question'), msg('srv_a', true, 'New question')]));
    await env.frame(16);
    assert.equal(env.dom.window.document.querySelectorAll('[data-chat-pin-row="true"]').length, 1, 'no double pin');
    assert.equal(pinnedRow(env), q('pin-message-local_a'));
    assert.equal(env.scrollToCalls(), calls, 'the echo never scrolls to the bottom');
    // The ack folds them into one row with the pinned key.
    await render(list([...longHistory.slice(1), acked('srv_a', 'local_a', 'New question')]));
    await env.frame(16);
    assert.equal(pinnedRow(env), q('pin-message-srv_a'));
    assert.equal(scroll.dataset.chatPinned, 'true');
    assert.equal(pinnedRow(env)!.getBoundingClientRect().top, top, 'no scroll-back');
    assert.equal(env.scrollToCalls(), calls);
  });
});

test('REQ-FADE-1..3: the top edge strip is on whenever the list is scrolled off its top, and hands over to the pin tail', async () => {
  assert.equal(topFadeFor(0, 0), 0, 'nothing to dissolve at the very top');
  assert.equal(topFadeFor(TOP_FADE_PX / 2, 0), 0.5);
  assert.equal(topFadeFor(5000, 0), 1);
  assert.equal(topFadeFor(5000, 1), 0, 'the pin tail replaces it, no double band');
  await withList(async (env) => {
    const { q, render, list, geometry, settle } = env;
    await render(list(longHistory));
    const scroll = geometry();
    const edge = () => {
      assert.equal(q('pin-top-edge-fade')!.style.opacity, q('pin-top-edge-blur')!.style.opacity, 'blur and fade move together');
      return q('pin-top-edge-fade')!.style.opacity;
    };
    assert.equal(q('pin-top-edge-fade')!.style.top, '', 'flush with the header: the strip starts at the wrapper top');
    assert.equal(q('pin-top-edge-fade')!.style.height, `${TOP_FADE_PX}px`);
    await scrollTo(scroll, 400);
    assert.equal(scroll.dataset.chatPinned, undefined);
    assert.equal(edge(), '1', 'on while not pinned');
    await scrollTo(scroll, 0);
    assert.equal(edge(), '0', 'off at the very top');
    await render(list([...longHistory, msg('local_a', true, 'New question')]));
    await settle();
    assert.equal(fade(scroll), '1');
    assert.equal(edge(), '0', 'the pin tail is the only strip at the pin position');
    assert.equal(q('pin-pin-tail-fade')!.style.top, '0px', 'the tail starts flush under the header too');
    await scrollTo(scroll, scroll.scrollTop - 200);
    assert.equal(fade(scroll), '0');
    assert.equal(edge(), '1', 'scrolled away from the pin, the edge strip is back');
    scrollerUntouched(scroll);
  });
});

// Opening or returning to a conversation lands on the latest message. There is no saved
// per-conversation position: the first scroll runs before the composer inset and late
// row heights exist, so until the reader scrolls, sends or the rows change, layout
// growth keeps the list at the bottom.
const atBottom = (scroll: HTMLElement) => scroll.scrollHeight - scroll.clientHeight;

test('open lands at the bottom even when the composer inset and row heights arrive late', async () => {
  await withList(async ({ render, list, geometry, observers, tail }) => {
    // Cached messages render on the first pass, before the composer dock measured.
    await render(list(longHistory, { bottomInset: 0 }));
    const scroll = geometry();
    scroll.scrollTop = 0; // the first scroll ran against the short, uninset content
    await render(list(longHistory, { bottomInset: 80 }));
    assert.equal(scroll.scrollTop, atBottom(scroll), 'the inset arriving keeps the list at the bottom');
    tail.extra = 300; // decrypt / highlighting grows the last row
    await act(async () => { observers.forEach((cb: (entries: any[]) => void) => cb([])); });
    assert.equal(scroll.scrollTop, atBottom(scroll), 'late row growth keeps the list at the bottom');
  });
});

test('the open settle ends at the reader\'s first scroll: later layout changes leave them where they are', async () => {
  await withList(async ({ render, list, geometry, observers, tail }) => {
    await render(list(longHistory, { bottomInset: 0 }));
    const scroll = geometry();
    await sleep(60); // past the open's own programmatic scroll
    await scrollTo(scroll, 200);
    await sleep(PIN_SCROLL_IDLE_MS + 20);
    await render(list(longHistory, { bottomInset: 80 }));
    tail.extra = 300;
    await act(async () => { observers.forEach((cb: (entries: any[]) => void) => cb([])); });
    assert.equal(scroll.scrollTop, 200, 'a reader in history is never pulled down');
  });
});

test('switching back to a conversation lands at the bottom, not where it was left', async () => {
  await withList(async ({ render, list, geometry }) => {
    await render(list(longHistory));
    const scroll = geometry();
    await scrollTo(scroll, 150);
    await render(list([msg('o1', false, 'Other chat')], { conversationKey: 'chat_other' }));
    await render(list(longHistory));
    assert.equal(scroll.scrollTop, atBottom(scroll), 'returning starts at the latest message');
  });
});

test('a mounted pane the layout hid lands at the bottom when it is shown again', async () => {
  await withList(async ({ render, list, geometry }) => {
    const shown = (visible: boolean) => React.createElement(PaneVisibilityProvider, { visible, children: list(longHistory) });
    await render(shown(true));
    const scroll = geometry();
    await scrollTo(scroll, 150);
    await render(shown(false));
    assert.equal(scroll.scrollTop, 150, 'hiding does not move it');
    await render(shown(true));
    assert.equal(scroll.scrollTop, atBottom(scroll), 'showing it again starts at the latest message');
  });
});
