import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { JSDOM } from 'jsdom';
import ChatMessageList from '../src/ui/components/chat/ChatMessageList.tsx';
import { StreamRevealer, revealStagger, STREAM_CHUNK_MS, STREAM_WORD_STAGGER_MS, STREAM_BLOCK_MODE_WORDS,
  STREAM_MAX_TOTAL_MS } from '../src/ui/components/chat/streamReveal.ts';
import { beginReply, forgetScopeReplies, replyPhase, resetReplyMotion, settleReply,
  REPLY_SETTLE_DEADLINE_MS } from '../src/ui/components/chat/replyMotion.ts';

// Incoming reply animation: the word-chunk reveal (streamReveal.ts), live-vs-history
// detection and completion chrome (ChatMessageList + replyMotion.ts). The working
// indicator is not part of this animation and must stay as it is.

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function withDom<T>(run: (dom: JSDOM) => Promise<T> | T) {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.test/', pretendToBeVisual: true });
  const names = ['window', 'document', 'HTMLElement', 'Node', 'IS_REACT_ACT_ENVIRONMENT', 'ResizeObserver',
    'IntersectionObserver', 'requestAnimationFrame', 'cancelAnimationFrame'];
  const previous: any = Object.fromEntries(names.map((name) => [name, (globalThis as any)[name]]));
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true, IntersectionObserver: undefined,
    ResizeObserver: class { observe() {} unobserve() {} disconnect() {} },
    requestAnimationFrame: (fn: FrameRequestCallback) => setTimeout(() => fn(0), 0) as any,
    cancelAnimationFrame: (id: any) => clearTimeout(id) });
  dom.window.HTMLElement.prototype.scrollTo = function () {};
  return Promise.resolve(run(dom)).finally(() => {
    Object.assign(globalThis, previous);
    dom.window.close();
  });
}

const fixture = (dom: JSDOM, html: string) => {
  const root = dom.window.document.createElement('div');
  root.innerHTML = html;
  dom.window.document.body.appendChild(root);
  return root;
};
const tokens = (root: Element) => [...root.querySelectorAll('.stream-chunk')] as HTMLElement[];
const visibleText = (root: Element) => tokens(root).filter((el) => el.getAttribute('data-sr') !== 'h'
  && !el.closest('[data-sr="h"]')).map((el) => el.textContent).join('');

test('reveal timings follow the spec', () => {
  assert.ok(STREAM_CHUNK_MS >= 300 && STREAM_CHUNK_MS <= 400, '350ms per chunk');
  assert.ok(STREAM_WORD_STAGGER_MS >= 15 && STREAM_WORD_STAGGER_MS <= 25, '15-25ms per word');
  assert.equal(STREAM_MAX_TOTAL_MS, 1200, 'the whole reveal is capped at 1.2s');
  assert.equal(revealStagger(10), STREAM_WORD_STAGGER_MS, 'short replies use the length-based stagger');
  for (const words of [10, 60, 399]) {
    assert.ok((words - 1) * revealStagger(words) + STREAM_CHUNK_MS <= STREAM_MAX_TOTAL_MS + 1e-6, `${words} words finish within 1.2s`);
  }
  assert.ok(revealStagger(399) < STREAM_WORD_STAGGER_MS, 'long replies use a faster stagger');
});

test('chunk reveal: the hidden tail keeps its layout, new words fade with a stagger, earlier words never re-animate', () => withDom((dom) => {
  const root = fixture(dom, '<p>Hello <strong>bold</strong> world</p><ul><li>first item</li><li>second</li></ul>');
  const revealer = new StreamRevealer(root);
  revealer.index();
  assert.equal(visibleText(root), '', 'everything starts hidden');
  assert.equal(root.querySelector('ul')!.getAttribute('data-sr'), 'h', 'blocks with no revealed text are hidden too');
  assert.equal(root.textContent, 'Hello bold worldfirst itemsecond', 'tokens keep the rendered text intact');

  revealer.reveal(revealer.wordEnds[1], true); // "Hello bold"
  assert.equal(visibleText(root), 'Hello bold');
  const [hello, bold] = tokens(root);
  assert.equal(hello.getAttribute('data-sr'), 'in');
  assert.equal(hello.style.animationDelay, '0ms');
  assert.equal(bold.style.animationDelay, `${STREAM_WORD_STAGGER_MS}ms`, 'a burst staggers per word');
  assert.equal(root.querySelector('strong')!.getAttribute('data-sr'), null, 'inline wrappers show without a fade');
  assert.equal(root.querySelector('li')!.getAttribute('data-sr'), 'h', 'the bullet waits for its first words');

  revealer.reveal(revealer.wordEnds[3], true); // "world first"
  assert.equal(hello.style.animationDelay, '0ms', 'earlier words are untouched');
  assert.equal(tokens(root)[0], hello, 'earlier spans are never remounted');
  assert.equal(root.querySelector('li')!.getAttribute('data-sr'), 'b', 'the bullet fades in with its first words');
  assert.equal(root.querySelectorAll('li')[1].getAttribute('data-sr'), 'h');

  revealer.reveal(Number.MAX_SAFE_INTEGER, true);
  assert.ok(revealer.done);
  assert.equal(visibleText(root), 'Hello bold worldfirst itemsecond');
  assert.equal(root.querySelectorAll('[data-sr="h"]').length, 0);
}));

test('a rewritten subtree (Shiki) and a longer source re-index without re-animating revealed text', () => withDom((dom) => {
  const code = 'const a = 1;\nconst b = 2;';
  const root = fixture(dom, `<p>Intro text</p><div data-code-block="true"><div class="code-container"><pre><code>${code}</code></pre></div></div>`);
  const revealer = new StreamRevealer(root);
  revealer.index();
  revealer.reveal(revealer.wordEnds[4], true); // "Intro text const a ="
  assert.equal(root.querySelector('[data-code-block]')!.getAttribute('data-sr'), 'c', 'the code container fades in first');
  // Shiki replaces the container's HTML with highlighted spans carrying the same text.
  root.querySelector('.code-container')!.innerHTML = `<pre class="shiki"><code><span>const</span><span> a = 1;</span>\n<span>const b = 2;</span></code></pre>`;
  revealer.index();
  const shown = tokens(root).filter((el) => el.getAttribute('data-sr') !== 'h');
  assert.equal(shown.map((el) => el.textContent).join(''), 'Intro textconst a = ', 'the revealed prefix survives the rewrite');
  assert.ok(shown.slice(2).every((el) => el.getAttribute('data-sr') === null), 'rewritten tokens show without a new fade');

  // A streaming delta: the whole HTML is replaced by a longer one.
  root.innerHTML = '<p>Intro text</p><div data-code-block="true"><div class="code-container"><pre><code>' + code + '</code></pre></div></div><p>More</p>';
  revealer.index();
  assert.equal(visibleText(root), 'Intro textconst a = ');
  assert.equal(root.querySelectorAll('[data-sr="in"]').length, 0, 'nothing already revealed animates again');
  assert.equal(root.querySelector('p:last-child')!.getAttribute('data-sr'), 'h', 'only the new tail waits to reveal');
}));

test('past ~400 words the reply fades in per top-level block', () => withDom((dom) => {
  const para = Array.from({ length: 150 }, (_, i) => 'w' + i).join(' ');
  const root = fixture(dom, `<p>${para}</p><ul><li>${para}</li></ul><p>${para}</p>`);
  assert.ok(150 * 3 > STREAM_BLOCK_MODE_WORDS);
  const revealer = new StreamRevealer(root);
  assert.equal(revealer.mode, 'blocks');
  revealer.index();
  assert.equal(root.querySelectorAll('.stream-chunk').length, 0, 'no per-word spans');
  assert.equal(root.querySelectorAll(':scope > [data-sr="h"]').length, 3);
  revealer.reveal(Number.MAX_SAFE_INTEGER, true, revealStagger(3, 60));
  const delays = [...root.children].map((el) => (el as HTMLElement).style.animationDelay);
  assert.deepEqual(delays, ['0ms', '60ms', '120ms'], 'blocks fade in one after another');
  assert.ok([...root.children].every((el) => el.getAttribute('data-sr') === 'b'));
}));

const msg = (key: string, isUser: boolean, body = key) => ({ key, messageId: key, body, isUser,
  createdUnixMs: 1_700_000_000_000, deliveredUnixMs: 0, readUnixMs: 0, deliveryFailedUnixMs: 0 }) as any;

async function withList(run: (env: any) => Promise<void>) {
  await withDom(async (dom) => {
    resetReplyMotion();
    const mediaListeners = new Set<() => void>();
    const media = { matches: false, addEventListener: (_: string, fn: () => void) => mediaListeners.add(fn),
      removeEventListener: (_: string, fn: () => void) => mediaListeners.delete(fn) };
    dom.window.matchMedia = (() => media) as any;
    const store = configureStore({ reducer: { vault: (s = {}) => s, chat: (s = { session: { userId: 'user1' } }) => s } });
    const root = createRoot(dom.window.document.getElementById('root')!);
    const q = (id: string) => dom.window.document.querySelector('[data-debug-id="' + id + '"]') as HTMLElement | null;
    const render = async (child: React.ReactNode) => {
      await act(async () => { root.render(React.createElement(Provider, { store, children: child })); });
    };
    const list = (messages: any[], extra: Record<string, unknown> = {}) => React.createElement(ChatMessageList, {
      conversationKey: 'chat_reveal', debugPrefix: 'rv', messages,
      formatTimestamp: () => ({ label: '9:00', iso: '2026-11-04T09:00:00Z' }), ...extra });
    const wait = async (ms: number) => { await act(async () => { await sleep(ms); }); };
    try {
      await run({ dom, q, render, list, wait, media,
        reduceMotion: async (value: boolean) => { await act(async () => { media.matches = value; mediaListeners.forEach((fn) => fn()); }); } });
    } finally {
      await act(async () => root.unmount());
      resetReplyMotion();
    }
  });
}

const history = [msg('h1', true, 'Question'), msg('h2', false, 'An **earlier** answer with words')];
const reply = msg('r1', false, 'Live reply:\n\n- one two\n- three');
const revealTime = STREAM_MAX_TOTAL_MS + 150;

test('history renders instantly; only a reply that arrives live reveals, then its chrome fades in', async () => {
  await withList(async ({ q, render, list, wait }) => {
    await render(list(history));
    const earlier = q('rv-message-h2')!;
    assert.equal(earlier.querySelectorAll('[data-sr]').length, 0, 'history has no reveal state');
    assert.equal(earlier.querySelectorAll('.stream-chunk').length, 0, 'history is never tokenised');
    assert.equal(q('rv-message-actions-h2')!.className.includes('reply-chrome'), false);

    await render(list([...history, msg('u2', true, 'Another question'), reply]));
    const row = q('rv-message-r1')!;
    assert.ok(row.querySelectorAll('.stream-chunk').length > 0, 'the live reply is tokenised');
    assert.ok([...row.querySelectorAll('.stream-chunk')].every((el) => ['h', 'in'].includes(el.getAttribute('data-sr') || '')),
      'every word is hidden or fading in, none starts at full opacity');
    assert.ok(q('rv-message-actions-r1')!.className.includes('reply-chrome-held'), 'the action row holds while text reveals');
    assert.equal(earlier.querySelectorAll('[data-sr]').length, 0, 'earlier messages stay untouched');
    assert.ok(row.querySelector('li'), 'the layout is final from the start: blocks exist');
    await wait(40);
    const firstShown = row.querySelector('.stream-chunk[data-sr="in"]') as HTMLElement;
    assert.ok(firstShown, 'the words start fading in');
    assert.equal(firstShown.style.animationDelay, '0ms');
    const li = row.querySelector('li') as HTMLElement;
    const firstLiWord = li.querySelector('.stream-chunk') as HTMLElement;
    assert.equal(li.getAttribute('data-sr'), 'b');
    assert.equal(li.style.animationDelay, firstLiWord.style.animationDelay, 'the bullet fades with its first words');

    // A parent re-render with a fresh (equal) array must not restart or replay anything.
    await render(list([...history, msg('u2', true, 'Another question'), { ...reply }]));
    assert.equal(row.querySelector('.stream-chunk[data-sr="in"]'), firstShown, 'revealed spans keep their identity');

    await wait(revealTime);
    assert.equal(row.querySelectorAll('[data-sr="h"]').length, 0, 'everything is revealed');
    const actions = q('rv-message-actions-r1')!;
    assert.equal(actions.className.includes('reply-chrome-held'), false);
    assert.ok(q('rv-message-copy-btn-r1')!.closest('.reply-chrome-in') || actions.querySelector('.reply-chrome-in'), 'the action row fades in');
    assert.equal(q('rv-message-r1-time')!.className, 'reply-meta-in', 'the meta line follows');
  });
});

test('an older page or a conversation switch never animates', async () => {
  await withList(async ({ q, render, list }) => {
    await render(list(history));
    await render(list([msg('o1', false, 'Older reply'), ...history]));
    assert.equal(q('rv-message-o1')!.querySelectorAll('.stream-chunk').length, 0, 'prepended page renders instantly');
    await render(list([msg('c1', true, 'Hi'), msg('c2', false, 'Other conversation reply')], { conversationKey: 'chat_other' }));
    assert.equal(q('rv-message-c2')!.querySelectorAll('.stream-chunk').length, 0, 'a switched-to conversation is history');
  });
});

test('reduced motion: a live reply shows immediately with its chrome', async () => {
  await withList(async ({ q, render, list, reduceMotion }) => {
    await reduceMotion(true);
    await render(list(history));
    await render(list([...history, reply]));
    const row = q('rv-message-r1')!;
    assert.equal(row.querySelectorAll('[data-sr]').length, 0, 'no hidden or fading text');
    assert.match(row.textContent || '', /Live reply:.*one two.*three/s);
    assert.equal(q('rv-message-actions-r1')!.className.includes('reply-chrome'), false, 'the action row is there at once');
  });
});

test('the working indicator is untouched: no status row is added and the tail stays while a reply reveals', async () => {
  await withList(async ({ q, render, list }) => {
    const tail = React.createElement('div', { 'data-debug-id': 'conversation-activity-bubbles' }, 'Working…');
    await render(list(history, { agentActivity: tail }));
    const before = q('conversation-activity-bubbles')!;
    await render(list([...history, reply], { agentActivity: tail }));
    assert.equal(replyPhase('r1'), 'revealing');
    assert.equal(q('conversation-activity-bubbles'), before, 'the tail indicator renders as given, in place');
    assert.equal(q('rv-message-r1')!.querySelector('[data-debug-id^="rv-reply-status"]'), null, 'no status header above the reply');
  });
});

test('reply motion store: begin and settle', () => {
  resetReplyMotion();
  beginReply('s', 'k1');
  assert.equal(replyPhase('k1'), 'revealing');
  beginReply('s', 'k1');
  assert.equal(replyPhase('k1'), 'revealing', 'a repeat begin is a no-op');
  settleReply('k1');
  assert.equal(replyPhase('k1'), 'settled');
  resetReplyMotion();
});

test('a live reply whose body renders without the reveal (locked vault) settles at once', async () => {
  await withList(async ({ q, render, list }) => {
    await render(list(history));
    // No vault key in this store: the armored body renders as VaultText, never via the reveal.
    await render(list([...history, msg('v1', false, 'vault:v2:sealed')]));
    assert.equal(replyPhase('v1'), 'settled', 'the reply settles without a reveal');
    assert.equal(q('rv-message-actions-v1')!.className.includes('reply-chrome-held'), false, 'its copy button and time are not held');
    assert.ok(q('rv-message-v1-time'), 'the meta line renders');
  });
});

test('a leaving scope forgets its replies: switching away mid-reveal and back renders history', async () => {
  await withList(async ({ q, render, list }) => {
    await render(list(history));
    await render(list([...history, reply]));
    assert.equal(replyPhase('r1'), 'revealing');
    await render(list([msg('c1', true, 'Hi')], { conversationKey: 'chat_other' }));
    assert.equal(replyPhase('r1'), null, 'the switch drops the unfinished reveal');
    await render(list([...history, reply]));
    assert.equal(q('rv-message-r1')!.querySelectorAll('[data-sr]').length, 0, 'on return the reply is history');
    assert.equal(q('rv-message-actions-r1')!.className.includes('reply-chrome'), false, 'its chrome shows at once');
  });
});

test('reply motion store: a reply that never reports back settles at the safety deadline', (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  resetReplyMotion();
  assert.ok(REPLY_SETTLE_DEADLINE_MS > STREAM_MAX_TOTAL_MS, 'never cuts a normal reveal short');
  beginReply('s', 'k1');
  t.mock.timers.tick(REPLY_SETTLE_DEADLINE_MS - 1);
  assert.equal(replyPhase('k1'), 'revealing');
  t.mock.timers.tick(1);
  assert.equal(replyPhase('k1'), 'settled');
  beginReply('s', 'k2');
  beginReply('other', 'k3');
  forgetScopeReplies('s');
  assert.equal(replyPhase('k2'), null);
  assert.equal(replyPhase('k1'), null, 'settled replies are pruned too');
  assert.equal(replyPhase('k3'), 'revealing', 'other scopes are untouched');
  resetReplyMotion();
});
