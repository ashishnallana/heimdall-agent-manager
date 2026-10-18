// Attention deck v1 (UI): view model, undo scheduler, snooze presets, prefs,
// API normalisation, and the deck rendered under jsdom with a real store.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_attention_deck_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { makeVaultStore, unlockVault, lockVaultFully } from './helpers/vaultEndpointHarness.ts';

const model = await import('../src/ui/components/attention/attentionModel.ts');
const { createActionScheduler } = await import('../src/ui/services/attention/actionScheduler.ts');
const { snoozePresets, toHubTimestamp } = await import('../src/ui/services/attention/snoozePresets.ts');
const prefs = await import('../src/ui/services/attention/attentionPrefs.ts');
const api = await import('../src/ui/api/endpoints/attention.ts');

const NOW = Date.parse('2026-10-16T12:00:00Z');

function taskItem(id: string, extra: any = {}): any {
  return {
    card_id: `crd_task_${id}`, kind: 'task', provider: 'task_validation', reason: 'awaiting_review', urgency: 'warn', status: 'pending',
    attention_since: '2026-10-16T10:00:00Z', title: `Review ${id}`, rationale: 'Waiting on your review', primary_op: 'task.vote',
    operations: [{ op: 'task.vote', label: 'Approve' }],
    details: { priority: 'p1', status: 'in_validation', bridge_id: 'brg_x', assignee_name: 'soloist #3', excerpt: { author_name: 'soloist #3', body: 'All tests pass.', at: '2026-10-16T11:00:00Z' } },
    action_refs: { chain_id: 'chain_secret_id', task_id: `task_secret_${id}` },
    context: { chain_title: 'Attention work', agent_name: 'soloist #3', project_name: '' },
    ...extra,
  };
}

function messageItem(id: string, extra: any = {}): any {
  return {
    card_id: `crd_msg_inst_${id}`, kind: 'message', provider: 'message_options', reason: 'question', urgency: 'info', status: 'pending',
    attention_since: '2026-10-16T11:30:00Z', title: 'Which approach?', rationale: 'Waiting on your reply', primary_op: null, operations: [],
    details: { excerpt: { author_name: 'soloist #7', body: 'Which approach should I take?', at: '2026-10-16T11:30:00Z' }, options: ['Keep it', 'Skip it'], other_unread: 2 },
    action_refs: { conversation_id: 'chat_secret_id', agent_instance_id: `inst_secret_${id}`, message_id: 'msg_secret_id' },
    context: { chain_title: 'Attention work', agent_name: 'soloist #7', project_name: '' },
    ...extra,
  };
}

function memoryItem(id: string, extra: any = {}): any {
  return {
    card_id: `crd_mem_mem_secret_${id}`, kind: 'memory', provider: 'memory_proposal', reason: 'memory_proposal', urgency: 'info', status: 'pending',
    attention_since: '2026-10-16T11:00:00Z', title: `Remember ${id}`, rationale: 'Waiting on your approval', primary_op: 'memory.approve',
    operations: [{ op: 'memory.approve', label: 'Approve' }],
    details: { type: 'expertise', title: `Remember ${id}`, description: '', body: '## Rule\n\nUse **CAS** writes.', expires_at: '2026-10-16T16:00:00Z', proposer_name: 'soloist #21', agent_ids: ['agt_secret'], project_ids: [], bridge_ids: [], template_ids: [] },
    action_refs: { memory_id: `mem_secret_${id}`, agent_instance_id: 'inst_secret', chain_id: 'chain_secret_id' },
    context: { chain_title: 'Attention deck rollout', agent_name: 'soloist #21', project_name: '', scope: { agents: ['codex-reviewer', 'soloist'], projects: [], bridges: [], templates: [] } },
    ...extra,
  };
}

// ---------------------------------------------------------------- view model

test('model: visible items, per-tab counts, default tab, stepping, swipe', () => {
  const items = [taskItem('a'), taskItem('b'), messageItem('m')];
  const hidden = new Set(['crd_task_a']);
  assert.deepEqual(model.visibleItems(items, 'task', hidden).map((i: any) => i.card_id), ['crd_task_b']);
  assert.deepEqual(model.tabCounts({ total: 3, older: 0, message: 1, task: 2, memory: 0, snoozed: 0 }, items, hidden), { message: 1, task: 1, memory: 0, snoozed: 0 });
  assert.equal(model.defaultTab({ message: 0, task: 2 }), 'task');
  assert.equal(model.defaultTab({ message: 1, task: 2 }), 'message');
  assert.equal(model.defaultTab({ message: 0, task: 0 }), 'message');
  assert.equal(model.stepIndex(2, 1, 3), 0, 'wraps forward');
  assert.equal(model.stepIndex(0, -1, 3), 2, 'wraps back');
  assert.equal(model.clampIndex(5, 2), 1);
  assert.equal(model.swipeDelta(-120), 1);
  assert.equal(model.swipeDelta(120), -1);
  assert.equal(model.swipeDelta(40), 0, 'short drags snap back');
  assert.equal(model.swipeDelta(-70), 1, 'a 70px drag left moves on');
  assert.equal(model.swipeDelta(-30, 150), 1, 'a quick flick moves on');
  assert.equal(model.swipeDelta(-30, 600), 0, 'a slow short drag snaps back');
  assert.equal(model.swipeDelta(30, 150), -1);
  assert.equal(model.swipeAxis(4, 3), 'pending', 'under the slop nothing is decided');
  assert.equal(model.swipeAxis(-30, 5), 'x', 'clearly horizontal is a swipe');
  assert.equal(model.swipeAxis(2, 30), 'y', 'vertical is a scroll');
  assert.equal(model.swipeAxis(20, 15), 'y', 'a diagonal drag is a scroll: scrolling wins');
});

test('model: human age and reason lines never contain ids', () => {
  assert.equal(model.formatAge('2026-10-16T11:59:40Z', NOW), 'just now');
  assert.equal(model.formatAge('2026-10-16T11:45:00Z', NOW), '15 min');
  assert.equal(model.formatAge('2026-10-16T09:00:00Z', NOW), '3h');
  assert.equal(model.formatAge('2026-10-15T09:00:00Z', NOW), '1 day');
  assert.equal(model.formatAge('2026-10-10T09:00:00Z', NOW), '6 days');
  assert.equal(model.reasonLine(taskItem('a'), NOW), 'Waiting on your review · 2h');
  assert.equal(model.reasonLine(messageItem('m'), NOW), 'Waiting on your reply · 30 min');
});

// ---------------------------------------------------------------- scheduler

function fakeTimers() {
  let now = 0;
  let seq = 0;
  const timers = new Map<number, { at: number; fn: () => void }>();
  return {
    timers: {
      setTimeout: (fn: () => void, ms: number) => { seq += 1; timers.set(seq, { at: now + ms, fn }); return seq; },
      clearTimeout: (h: unknown) => { timers.delete(h as number); },
      now: () => now,
    },
    async advance(ms: number) {
      now += ms;
      for (const [id, t] of [...timers]) if (t.at <= now) { timers.delete(id); t.fn(); }
      await new Promise((r) => setTimeout(r, 0));
    },
  };
}

test('scheduler: holds, hides, undoes, sends, restores on failure, flushes with keepalive', async () => {
  const clock = fakeTimers();
  const s = createActionScheduler({ delayMs: 4000, timers: clock.timers });
  const calls: Array<{ card: string; keepalive: boolean }> = [];
  const ok = (card: string) => async (keepalive: boolean) => { calls.push({ card, keepalive }); };

  const undone = s.schedule({ cardId: 'c1', label: 'Approved', run: ok('c1') });
  assert.ok(s.getSnapshot().hidden.has('c1'), 'hidden optimistically');
  assert.equal(s.undo(undone), true);
  assert.equal(s.getSnapshot().hidden.has('c1'), false, 'undo brings it back');
  await clock.advance(5000);
  assert.equal(calls.length, 0, 'an undone action is never sent');

  s.schedule({ cardId: 'c2', label: 'Discarded', run: ok('c2') });
  await clock.advance(3999);
  assert.equal(calls.length, 0, 'held for the whole window');
  await clock.advance(1);
  assert.deepEqual(calls, [{ card: 'c2', keepalive: false }]);
  assert.ok(s.getSnapshot().hidden.has('c2'), 'stays hidden after success until the server drops it');
  s.prune(['other']);
  assert.equal(s.getSnapshot().hidden.has('c2'), false, 'pruned once the server stops returning it');
  assert.equal(s.undo(1234), false);

  s.schedule({ cardId: 'c3', label: 'Snoozed', run: async () => { throw new Error('hub said no'); } });
  await clock.advance(4000);
  assert.equal(s.getSnapshot().hidden.has('c3'), false, 'failure restores the card');
  assert.match(s.getSnapshot().error, /Snoozed failed: hub said no/);
  s.acknowledgeError();
  assert.equal(s.getSnapshot().error, '');

  s.schedule({ cardId: 'c4', label: 'Approved', run: ok('c4') });
  s.schedule({ cardId: 'c5', label: 'Approved', run: ok('c5') });
  await s.flushAll(true);
  assert.deepEqual(calls.slice(-2), [{ card: 'c4', keepalive: true }, { card: 'c5', keepalive: true }], 'page exit flushes with keepalive');
  await clock.advance(10000);
  assert.equal(calls.length, 3, 'flushed actions are not sent twice');

  s.settle('c6');
  assert.ok(s.getSnapshot().hidden.has('c6'));
  s.unsettle('c6');
  assert.equal(s.getSnapshot().hidden.has('c6'), false);
});

// ---------------------------------------------------------------- presets, prefs, api

test('snooze presets: 1h, tonight (before 19:00 only), tomorrow 9:00, next Monday 9:00', () => {
  const morning = new Date(2026, 9, 16, 10, 30); // Friday
  const p = snoozePresets(morning);
  assert.deepEqual(p.map((x: any) => x.id), ['hour', 'tonight', 'tomorrow', 'next-week']);
  assert.equal(p[1].until.getHours(), 20);
  assert.equal(p[2].until.getDate(), 17);
  assert.equal(p[2].until.getHours(), 9);
  assert.equal(p[3].until.getDay(), 1, 'next week = Monday');
  assert.equal(p[3].until.getDate(), 19);
  assert.deepEqual(snoozePresets(new Date(2026, 9, 16, 21, 0)).map((x: any) => x.id), ['hour', 'tomorrow', 'next-week']);
  assert.equal(snoozePresets(new Date(2026, 9, 19, 8, 0))[3].until.getDate(), 26, 'on a Monday, next week is a week away');
  assert.equal(toHubTimestamp(new Date('2026-10-16T12:00:00.123Z')), '2026-10-16T12:00:00Z');
});

test('prefs: range persists, falls back to 24h on junk or broken storage', () => {
  const store = new Map<string, string>();
  const storage = { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); } };
  assert.equal(prefs.readAttentionRange(storage), '24h');
  prefs.writeAttentionRange('7d', storage);
  assert.equal(store.get('heimdall:attention:range'), '7d');
  assert.equal(prefs.readAttentionRange(storage), '7d');
  store.set('heimdall:attention:range', 'forever');
  assert.equal(prefs.readAttentionRange(storage), '24h');
  assert.equal(prefs.readAttentionRange({ getItem: () => { throw new Error('denied'); } } as any), '24h');
  assert.doesNotThrow(() => prefs.writeAttentionRange('6h', { setItem: () => { throw new Error('quota'); } } as any));
});

test('api: counts and items are normalised defensively', () => {
  assert.deepEqual(api.normalizeAttentionCounts({ total: 3, older: -1, message: '2', task: 1.7 }), { total: 3, older: 0, message: 0, task: 1, memory: 0, snoozed: 0 });
  assert.deepEqual(api.normalizeAttentionCounts(null), { total: 0, older: 0, message: 0, task: 0, memory: 0, snoozed: 0 });
  const items = api.normalizeAttentionItems([taskItem('a'), { card_id: 'x', kind: 'shell', details: {}, action_refs: {} }, null, { kind: 'task' }]);
  assert.deepEqual(items.map((i: any) => i.card_id), ['crd_task_a']);
});

// ---------------------------------------------------------------- deck under jsdom

function jsonResponse(body: any) {
  return { ok: true, status: 200, headers: { get: () => 'application/json' }, text: async () => JSON.stringify(body), json: async () => body } as any;
}

type DeckHarness = { dom: any; store: any; scheduler: any; text: () => string; q: (sel: string) => any; act: any; closed: () => number; hits: string[]; setOpen: (open: boolean) => Promise<void>; serve: (items: any[]) => void; release: () => void; hold: () => void; holdRoutes: () => void; releaseRoutes: () => void };

async function withDeck(initialItems: any[], run: (h: DeckHarness) => Promise<void>, opts: { unlocked?: boolean; routes?: Record<string, any> } = {}) {
  let items = initialItems;
  // hold() makes /attention responses wait until release(), to observe the deck mid-refetch.
  let gate: Promise<void> | null = null;
  let openGate = () => {};
  let routeGate: Promise<void> | null = null;
  let openRouteGate = () => {};
  const { JSDOM } = await import('jsdom');
  const { Provider } = await import('react-redux');
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/', pretendToBeVisual: true });
  const saved: any = {};
  for (const k of ['window', 'document', 'HTMLElement', 'Node', 'KeyboardEvent']) saved[k] = (globalThis as any)[k];
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).Node = dom.window.Node;
  (globalThis as any).KeyboardEvent = dom.window.KeyboardEvent;
  // RTK batches with rAF when a window exists. A timer-based shim (left in place
  // for the rest of this file's process) keeps it independent of the jsdom window,
  // which is closed per test.
  (globalThis as any).requestAnimationFrame = (cb: (t: number) => void) => setTimeout(() => cb(Date.now()), 0);
  (globalThis as any).cancelAnimationFrame = (h: any) => clearTimeout(h);
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  const hits: string[] = [];
  const prevFetch = (globalThis as any).fetch;
  (globalThis as any).fetch = async (input: any, init: any = {}) => {
    const url = new URL(String(input?.url ?? input), 'http://localhost');
    hits.push(`${String(init?.method || 'GET').toUpperCase()} ${url.pathname}${url.search}`);
    if (url.pathname.endsWith('/attention')) {
      if (gate) await gate;
      const live = items.filter((i) => !i.snoozed);
      const counts = { total: live.length, older: 1, message: live.filter((i) => i.kind === 'message').length, task: live.filter((i) => i.kind === 'task').length, memory: live.filter((i) => i.kind === 'memory').length, snoozed: items.length - live.length };
      return jsonResponse({ data: { since: '24h', counts, items } });
    }
    for (const [suffix, body] of Object.entries(opts.routes || {})) {
      if (url.pathname.endsWith(suffix)) {
        if (routeGate) await routeGate;
        return jsonResponse({ data: body });
      }
    }
    return jsonResponse({ data: {} });
  };
  const store = await makeVaultStore();
  if (opts.unlocked) await unlockVault(store, '00'.repeat(32));
  const { AttentionDeck } = await import('../src/ui/components/attention/AttentionDeck.tsx');
  const scheduler = createActionScheduler({ delayMs: 60_000 });
  let closedCount = 0;
  const root = createRoot(dom.window.document.getElementById('root')!);
  const render = (open: boolean) => root.render(React.createElement(Provider, { store }, React.createElement(AttentionDeck, {
    open, onClose: () => { closedCount += 1; }, range: '24h', onRangeChange: () => {}, scheduler, nowMs: NOW,
  })));
  try {
    await act(async () => { render(true); });
    await act(async () => { await new Promise((r) => setTimeout(r, 30)); });
    await run({
      dom, store, scheduler, act, hits,
      setOpen: async (open: boolean) => {
        await act(async () => { render(open); });
        await act(async () => { await new Promise((r) => setTimeout(r, 30)); });
      },
      serve: (next: any[]) => { items = next; },
      hold: () => { gate = new Promise<void>((r) => { openGate = r; }); },
      release: () => { gate = null; openGate(); },
      holdRoutes: () => { routeGate = new Promise<void>((r) => { openRouteGate = r; }); },
      releaseRoutes: () => { routeGate = null; openRouteGate(); },
      text: () => dom.window.document.body.textContent || '',
      q: (sel: string) => dom.window.document.querySelector(sel),
      closed: () => closedCount,
    });
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    if (opts.unlocked) await lockVaultFully(store);
    // Let RTK's batched notifications drain before the window goes away.
    await act(async () => { await new Promise((r) => setTimeout(r, 50)); });
    dom.window.close();
    for (const [k, v] of Object.entries(saved)) (globalThis as any)[k] = v;
    (globalThis as any).fetch = prevFetch;
  }
}

test('deck: message card shows the question, options and unread count -- never an id', async () => {
  await withDeck([messageItem('m'), taskItem('a')], async ({ text, q, hits }) => {
    assert.ok(hits.some((h) => h.startsWith('GET /api/v1/attention?since=24h')), 'fetches the selected range');
    assert.ok(q('[data-debug-id="attention-card-message"]'), 'opens on the Messages tab');
    assert.match(text(), /Which approach should I take\?/);
    assert.match(text(), /Keep it/);
    assert.match(text(), /\+2 more unread messages/);
    assert.match(text(), /Waiting on your reply · 30 min/);
    assert.match(text(), /Messages1/);
    assert.match(text(), /Tasks1/);
    assert.doesNotMatch(text(), /secret|crd_|chat_|inst_|task_|msg_|chain_/, 'no ids rendered');
    assert.match(text(), /\+1 older/);
    assert.equal(q('[data-markdown-copy-all="true"]'), null, 'no copy button on the card (it added an empty line)');
  });
});

test('deck: task card, tab switch, keyboard approve is deferred and undoable', async () => {
  await withDeck([taskItem('a'), taskItem('b')], async ({ text, q, scheduler, act, dom, hits, closed }) => {
    assert.ok(q('[data-debug-id="attention-card-task"]'), 'no messages -> opens on Tasks');
    assert.match(text(), /Review a/);
    assert.match(text(), /High priority/);
    assert.match(text(), /All tests pass\./);
    assert.match(text(), /1 \/ 2/);
    assert.doesNotMatch(text(), /secret|crd_|task_secret/, 'no ids rendered');

    await act(async () => { dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true })); });
    assert.match(text(), /Review b/, 'arrow keys move between cards');
    assert.match(text(), /2 \/ 2/);

    await act(async () => { dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'a', bubbles: true })); });
    const snap = scheduler.getSnapshot();
    assert.equal(snap.pending.length, 1, 'approve is held, not sent');
    assert.equal(snap.pending[0].cardId, 'crd_task_b');
    assert.equal(snap.pending[0].label, 'Approved');
    assert.equal(hits.filter((h) => h.includes('/accept')).length, 0, 'nothing sent during the undo window');
    assert.match(text(), /1 \/ 1/, 'the approved card is hidden at once');

    // Snooze menu, then Escape closes the menu before the deck.
    await act(async () => { (q('[data-debug-id="attention-action-snooze"]') as any).click(); });
    assert.ok(q('[data-debug-id="attention-snooze-menu"]'));
    await act(async () => { dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); });
    assert.equal(q('[data-debug-id="attention-snooze-menu"]'), null);
    assert.equal(closed(), 0);
    await act(async () => { dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); });
    assert.equal(closed(), 1);

    // Flushing (page exit) actually sends the held approve.
    await act(async () => { await scheduler.flushAll(true); });
    assert.equal(hits.filter((h) => h === 'POST /api/v1/cards/crd_task_b/accept').length, 1);
  });
});

test('deck: locked vault shows the lock placeholder instead of ciphertext', async () => {
  const cipherTitle = 'vault:v1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  await withDeck([taskItem('c', { title: cipherTitle })], async ({ text, q }) => {
    assert.doesNotMatch(text(), /vault:v1:/, 'ciphertext is never painted');
    assert.ok(q('[data-debug-id="vault-locked-placeholder"]'), 'lock placeholder shown');
  });
});

test('deck: unlocked vault decrypts the card title and excerpt', async () => {
  const { encryptVaultText, importRawKeyHex } = await import('../src/ui/utils/vaultCrypto.ts');
  const key = await importRawKeyHex('00'.repeat(32));
  const title = await encryptVaultText('Secret review title', key);
  const body = await encryptVaultText('Secret excerpt body', key);
  const item = taskItem('d', { title, details: { ...taskItem('d').details, excerpt: { author_name: 'soloist #3', body, at: '2026-10-16T11:00:00Z' } } });
  await withDeck([item], async ({ text, act }) => {
    await act(async () => { await new Promise((r) => setTimeout(r, 80)); });
    assert.match(text(), /Secret review title/);
    assert.match(text(), /Secret excerpt body/);
    assert.doesNotMatch(text(), /vault:v1:/);
  }, { unlocked: true });
});

test('deck: a quick-reply option is sent at once, then the conversation is marked read', async () => {
  await withDeck([messageItem('m')], async ({ q, act, hits, scheduler, text }) => {
    await act(async () => { (q('[data-debug-id="attention-card-option-0"]') as any).click(); });
    await act(async () => { await new Promise((r) => setTimeout(r, 30)); });
    const send = hits.findIndex((h) => h.startsWith('POST /api/v1/chats/chat_secret_id/messages'));
    const read = hits.findIndex((h) => h === 'POST /api/v1/chats/chat_secret_id/read');
    assert.ok(send >= 0, 'the option text is sent as a reply');
    assert.ok(read > send, 'then the conversation is marked read');
    assert.ok(scheduler.getSnapshot().hidden.has('crd_msg_inst_m'), 'the answered card leaves the deck');
    assert.match(text(), /Reply sent to soloist #7/);
  });
});

// React's change-event plugin can't see jsdom input events here (its feature
// detection ran against another window), so drive the textarea's onChange directly.
function typeInto(el: any, value: string) {
  const key = Object.keys(el).find((k) => k.startsWith('__reactProps$'))!;
  el.value = value;
  el[key].onChange({ target: el, currentTarget: el });
}

test('deck: replying or commenting moves on to the next card', async () => {
  await withDeck([messageItem('m'), messageItem('n', { details: { ...messageItem('n').details, excerpt: { author_name: 'soloist #8', body: 'Second question?', at: '2026-10-16T11:40:00Z' } } })], async ({ q, act, text }) => {
    assert.match(text(), /Which approach should I take\?/);
    await act(async () => { (q('[data-debug-id="attention-action-reply"]') as any).click(); });
    const input = q('[data-debug-id="attention-reply-input"]') as any;
    assert.ok(input, 'reply composer opens');
    await act(async () => { typeInto(input, 'Go with option A'); });
    await act(async () => { (q('[data-debug-id="attention-reply-submit"]') as any).click(); });
    await act(async () => { await new Promise((r) => setTimeout(r, 30)); });
    assert.match(text(), /Second question\?/, 'the next card is shown after the reply');
    assert.equal(q('[data-debug-id="attention-reply"]'), null, 'composer closed');
  });
  await withDeck([taskItem('a'), taskItem('b')], async ({ q, act, text, hits }) => {
    assert.match(text(), /Review a/);
    await act(async () => { (q('[data-debug-id="attention-action-comment"]') as any).click(); });
    const input = q('[data-debug-id="attention-comment-input"]') as any;
    await act(async () => { typeInto(input, 'Looks fine'); });
    await act(async () => { (q('[data-debug-id="attention-comment-submit"]') as any).click(); });
    await act(async () => { await new Promise((r) => setTimeout(r, 30)); });
    assert.ok(hits.some((h) => h.startsWith("POST ") && h.includes("task_secret_a") && h.includes("comment")), 'comment posted');
    assert.match(text(), /Review b/, 'the next card is shown after the comment');
    assert.match(text(), /2 \/ 2/, 'the commented card stays in the deck');
  });
});

test('deck: reopening shows the cached cards at once, revalidates in the background, keeps the current card', async () => {
  await withDeck([taskItem('a'), taskItem('b'), taskItem('c')], async ({ q, act, text, dom, hits, setOpen, serve, hold, release, store }) => {
    // Look at card b, then close.
    await act(async () => { dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true })); });
    assert.match(text(), /Review b/);
    await setOpen(false);
    const fetchesBefore = hits.filter((h) => h.startsWith('GET /api/v1/attention?')).length;

    // Server state changed while closed: a is gone, d and e are new and sort first.
    serve([taskItem('d'), taskItem('e'), taskItem('b'), taskItem('c')]);
    hold();
    await setOpen(true);
    assert.equal(hits.filter((h) => h.startsWith('GET /api/v1/attention?')).length, fetchesBefore + 1, 'opening forces exactly one refetch');
    assert.equal(q('[data-debug-id="attention-deck-loading"]'), null, 'no loading screen: cached cards show');
    assert.match(text(), /Review b/, 'the last card is still on screen');
    assert.ok(q('[data-debug-id="attention-deck-checking"]'), 'a subtle checking hint while the refetch runs');

    release();
    await act(async () => { await new Promise((r) => setTimeout(r, 40)); });
    assert.equal(q('[data-debug-id="attention-deck-checking"]'), null);
    assert.match(text(), /Review b/, 'still on the same card after the merge');
    assert.match(text(), /3 \/ 4/, 'b keeps its identity at its new position');
    await act(async () => { dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true })); });
    assert.match(text(), /Review e/, 'the new cards were merged in');
    const { attentionApi } = await import('../src/ui/api/endpoints/attention.ts');
    assert.equal(attentionApi.endpoints.getAttentionSummary.select({ since: '24h' })(store.getState()).data?.counts.total, 4, 'deck counts upserted into the bar summary cache');
  });
});

test('deck: an action does not refetch the deck by itself (the hub hint does)', async () => {
  await withDeck([taskItem('a'), taskItem('b')], async ({ act, dom, hits, scheduler }) => {
    const before = hits.filter((h) => h.startsWith('GET /api/v1/attention')).length;
    await act(async () => { dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'a', bubbles: true })); });
    await act(async () => { await scheduler.flushAll(true); });
    await act(async () => { await new Promise((r) => setTimeout(r, 40)); });
    assert.ok(hits.includes('POST /api/v1/cards/crd_task_a/accept'));
    assert.equal(hits.filter((h) => h.startsWith('GET /api/v1/attention')).length, before, 'no self-refetch after the action');
  });
});

test('ws: a burst of attention_changed hints becomes one invalidation', async () => {
  const { handleUserWsEvent, ATTENTION_REFETCH_COALESCE_MS } = await import('../src/ui/api/wsInvalidation.ts');
  const actions: any[] = [];
  const dispatch = (a: any) => { if (typeof a !== 'function') actions.push(a); return a; };
  for (let i = 0; i < 4; i += 1) handleUserWsEvent(dispatch, { type: 'attention_changed', kinds: ['task'] });
  const invalidations = () => actions.filter((a) => String(a?.type || '').endsWith('invalidateTags'));
  assert.equal(invalidations().length, 0, 'nothing until the burst settles');
  await new Promise((r) => setTimeout(r, ATTENTION_REFETCH_COALESCE_MS + 30));
  assert.equal(invalidations().length, 1, 'one invalidation for the whole burst');
  assert.deepEqual(invalidations()[0].payload, [{ type: 'Attention', id: 'ALL' }]);
  handleUserWsEvent(dispatch, { type: 'attention_changed', kinds: ['message'] });
  await new Promise((r) => setTimeout(r, ATTENTION_REFETCH_COALESCE_MS + 30));
  assert.equal(invalidations().length, 2, 'a later hint gets its own invalidation');
});

test('model: reviewer candidates come from the chain fleet, else the reviewer template', () => {
  const agents = [
    { agent_id: 'agt_w', name: 'worker', template_id: 'tmpl_worker', state: 'active' },
    { agent_id: 'agt_r', name: 'codex-reviewer', template_id: 'tmpl_reviewer', state: 'active' },
    { agent_id: 'agt_r2', name: 'arch-reviewer', template_id: 'tmpl_reviewer', state: 'archived' },
    { agent_id: 'agt_s', name: 'soloist', template_id: 'tmpl_soloist', state: 'active' },
  ];
  assert.deepEqual(model.reviewerCandidates([{ agent_id: 'agt_s' }, { agent_id: 'agt_w' }, { agent_id: 'agt_gone' }], agents),
    [{ agentId: 'agt_s', name: 'soloist', source: 'fleet' }, { agentId: 'agt_w', name: 'worker', source: 'fleet' }]);
  assert.deepEqual(model.reviewerCandidates([], agents), [{ agentId: 'agt_r', name: 'codex-reviewer', source: 'reviewer_template' }], 'empty fleet -> active reviewer-template agents');
  assert.deepEqual(model.reviewerCandidates([{ agent_id: 'agt_r2' }], agents), [{ agentId: 'agt_r', name: 'codex-reviewer', source: 'reviewer_template' }], 'archived fleet agents do not count');
  assert.deepEqual(model.reviewerCandidates([], [{ agent_id: 'agt_w', name: 'worker', template_id: 'tmpl_worker' }]), []);
});

test('deck: reviewer menu loads the fleet on demand with a loader, then hands the review over', async () => {
  const routes = {
    '/task-chains/chain_secret_id/fleets': [{ agent_id: 'agt_rev' }],
    '/agents': [
      { agent_id: 'agt_rev', name: 'codex-reviewer', template_id: 'tmpl_reviewer', state: 'active' },
      { agent_id: 'agt_other', name: 'worker', template_id: 'tmpl_worker', state: 'active' },
    ],
  };
  await withDeck([taskItem('a')], async ({ q, act, text, hits, holdRoutes, releaseRoutes, scheduler }) => {
    assert.equal(hits.filter((h) => h.includes('/fleets') || h.includes('/agents')).length, 0, 'nothing fetched until the menu opens');
    holdRoutes();
    await act(async () => { (q('[data-debug-id="attention-action-reviewer"]') as any).click(); });
    await act(async () => { await new Promise((r) => setTimeout(r, 20)); });
    assert.ok(q('[data-debug-id="attention-reviewer-loading"]'), 'loader while the fleet loads');
    assert.ok(hits.some((h) => h === 'GET /api/v1/task-chains/chain_secret_id/fleets'));
    assert.ok(hits.some((h) => h.startsWith('GET /api/v1/agents?limit=200')));
    releaseRoutes();
    await act(async () => { await new Promise((r) => setTimeout(r, 40)); });
    assert.equal(q('[data-debug-id="attention-reviewer-loading"]'), null);
    const options = Array.from(document.querySelectorAll('[data-debug-id="attention-reviewer-option"]')) as any[];
    assert.deepEqual(options.map((o) => o.textContent), ['codex-reviewer'], 'fleet agents only');
    assert.match(text(), /this chain's fleet/);
    assert.doesNotMatch(text(), /agt_/, 'no ids rendered');
    await act(async () => { options[0].click(); });
    const pending = scheduler.getSnapshot().pending;
    assert.equal(pending.length, 1);
    assert.equal(pending[0].label, 'Handed to codex-reviewer');
    await act(async () => { await scheduler.flushAll(true); });
    const patch = hits.indexOf('PATCH /api/v1/task-chains/chain_secret_id/tasks/task_secret_a');
    assert.ok(patch >= 0, 'reviewer set on the task');
    // Task System v2 re-gates the task on the reviewer edit itself (stale review
    // leases replaced, the new reviewer matched), so there is no separate reconcile.
    assert.equal(hits.indexOf('POST /api/v1/task-chains/chain_secret_id/reconcile'), -1, 'no reconcile call');
  }, { routes });
});

test('model: snoozed tab, hide keys, next live tab, wake time', () => {
  const live = taskItem('a');
  const snz = taskItem('z', { snoozed: true, snooze_until: '2026-10-17T09:00:00Z', status: 'snoozed' });
  const items = [live, snz, messageItem('m')];
  assert.deepEqual(model.visibleItems(items, 'snoozed', new Set()).map((i: any) => i.card_id), ['crd_task_z']);
  assert.deepEqual(model.visibleItems(items, 'task', new Set()).map((i: any) => i.card_id), ['crd_task_a'], 'snoozed cards stay out of live tabs');
  assert.equal(model.hideKey(snz), 'crd_task_z#snoozed@2026-10-17T09:00:00Z');
  assert.equal(model.hideKey(live), 'crd_task_a');
  assert.deepEqual(model.tabCounts({ total: 2, older: 0, message: 1, task: 1, memory: 0, snoozed: 1 }, items, new Set(['crd_task_z#snoozed@2026-10-17T09:00:00Z'])), { message: 1, task: 1, memory: 0, snoozed: 0 });
  assert.equal(model.nextLiveTab('message', { message: 0, task: 2, snoozed: 3 }), 'task');
  assert.equal(model.nextLiveTab('task', { message: 0, task: 0, snoozed: 3 }), null, 'never into Snoozed');
  assert.equal(model.nextLiveTab('snoozed', { message: 0, task: 1, snoozed: 0 }), 'task');
  assert.equal(model.defaultTab({ message: 0, task: 0, snoozed: 4 }), 'message');
  assert.match(model.reasonLine(snz, NOW), /^Snoozed until tomorrow \d\d:\d\d$/);
  assert.equal(model.formatWake('', NOW), '');
});

test('deck: finishing the last card of a tab moves to the other live tab, never Snoozed', async () => {
  await withDeck([messageItem('m'), taskItem('a'), taskItem('z', { snoozed: true, snooze_until: '2099-01-01T09:00:00Z', status: 'snoozed' })], async ({ q, act, dom, text }) => {
    assert.ok(q('[data-debug-id="attention-card-message"]'), 'starts on Messages');
    assert.match(text(), /Snoozed1/);
    await act(async () => { dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'm', bubbles: true })); });
    await act(async () => { await new Promise((r) => setTimeout(r, 10)); });
    assert.equal(q('[data-debug-id="attention-deck-tab-task"]').getAttribute('aria-selected'), 'true', 'moved on to Tasks');
    assert.match(text(), /Review a/);
    await act(async () => { dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'a', bubbles: true })); });
    await act(async () => { await new Promise((r) => setTimeout(r, 10)); });
    assert.equal(q('[data-debug-id="attention-deck-tab-task"]').getAttribute('aria-selected'), 'true', 'nothing live left: stays, does not jump into Snoozed');
    // Clicking an empty tab yourself does not bounce you away.
    await act(async () => { q('[data-debug-id="attention-deck-tab-message"]').click(); });
    await act(async () => { await new Promise((r) => setTimeout(r, 10)); });
    assert.equal(q('[data-debug-id="attention-deck-tab-message"]').getAttribute('aria-selected'), 'true');
  });
});

test('deck: Snoozed tab keeps the original actions; approving a snoozed card works in place', async () => {
  const snz = taskItem('z', { snoozed: true, snooze_until: '2026-10-17T09:00:00Z', status: 'snoozed' });
  await withDeck([taskItem('a'), snz], async ({ q, act, dom, text, scheduler, hits }) => {
    await act(async () => { q('[data-debug-id="attention-deck-tab-snoozed"]').click(); });
    assert.match(text(), /Review z/);
    assert.match(text(), /Snoozed until tomorrow/);
    assert.equal(q('[data-debug-id="attention-action-wake"]'), null, 'no separate wake step');
    assert.match(text(), /Cancel task/, 'says what it does: cancels the task');
    assert.doesNotMatch(text(), /Discard/);
    for (const a of ['approve', 'comment', 'reviewer', 'snooze', 'cancel-task', 'open']) assert.ok(q(`[data-debug-id="attention-action-${a}"]`), `${a} offered`);
    await act(async () => { dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'a', bubbles: true })); });
    const pending = scheduler.getSnapshot().pending;
    assert.equal(pending.length, 1);
    assert.equal(pending[0].cardId, 'crd_task_z#snoozed@2026-10-17T09:00:00Z');
    assert.equal(pending[0].label, 'Approved');
    await act(async () => { await new Promise((r) => setTimeout(r, 10)); });
    assert.equal(q('[data-debug-id="attention-deck-tab-task"]').getAttribute('aria-selected'), 'true', 'last snoozed card done: back to a live tab');
    await act(async () => { await scheduler.flushAll(true); });
    assert.ok(hits.includes('POST /api/v1/cards/crd_task_z/accept'));
  });
});

test('deck: next/previous buttons and a swipe move between cards without acting', async () => {
  await withDeck([taskItem('a'), taskItem('b'), taskItem('c')], async ({ q, act, text, dom, hits, scheduler }) => {
    assert.match(text(), /Review a/);
    await act(async () => { q('[data-debug-id="attention-deck-next"]').click(); });
    assert.match(text(), /Review b/);
    assert.match(text(), /2 \/ 3/);
    await act(async () => { q('[data-debug-id="attention-deck-prev"]').click(); });
    await act(async () => { q('[data-debug-id="attention-deck-prev"]').click(); });
    assert.match(text(), /Review c/, 'wraps around');
    // A left swipe on the card, as touch sends it (jsdom has no PointerEvent, so
    // a MouseEvent typed as one, carrying a pointerId).
    // Re-query each time: the card remounts when it changes.
    const card = () => q('[data-debug-id="attention-deck-card"]');
    const fire = (type: string, x: number, y = 300) => card().dispatchEvent(Object.assign(new dom.window.MouseEvent(type, { bubbles: true, clientX: x, clientY: y }), { pointerId: 7 }));
    await act(async () => { fire('pointerdown', 200); });
    await act(async () => { fire('pointermove', 120); });
    await act(async () => { fire('pointerup', 120); });
    assert.match(text(), /Review a/, 'swiping left from the last card wraps to the first');
    await act(async () => { fire('pointerdown', 100); });
    await act(async () => { fire('pointermove', 110); });
    await act(async () => { fire('pointerup', 110); });
    assert.match(text(), /Review a/, 'a tiny drag snaps back');
    // Scrolling the card's content wins over swiping.
    await act(async () => { fire('pointerdown', 200, 300); });
    await act(async () => { fire('pointermove', 198, 270); });
    await act(async () => { fire('pointermove', 120, 240); });
    assert.equal(card().style.transform, '', 'a gesture that started vertical never moves the card');
    await act(async () => { fire('pointerup', 120, 240); });
    assert.match(text(), /Review a/, 'a vertical-first gesture never switches cards');
    await act(async () => { fire('pointerdown', 200, 300); });
    await act(async () => { fire('pointermove', 130, 250); });
    await act(async () => { fire('pointerup', 130, 250); });
    assert.match(text(), /Review a/, 'a diagonal scroll never switches cards');
    await act(async () => { fire('pointerdown', 200); });
    await act(async () => { fire('pointermove', 120); });
    await act(async () => { fire('pointercancel', 120); });
    assert.match(text(), /Review a/, 'a cancelled gesture (the browser took it to scroll) never switches cards');
    await act(async () => { fire('pointerdown', 200); });
    await act(async () => { fire('pointermove', 280, 305); });
    await act(async () => { fire('pointerup', 280, 305); });
    assert.match(text(), /Review c/, 'a clearly horizontal swipe right still goes back');
    assert.equal(scheduler.getSnapshot().pending.length, 0, 'no action taken');
    assert.equal(hits.filter((h) => h.startsWith('POST')).length, 0, 'nothing sent');
  });
});

test('deck: slides up on open and back down on close before unmounting', async () => {
  const { SHEET_MS } = await import('../src/ui/components/attention/AttentionDeck.tsx');
  await withDeck([taskItem('a')], async ({ q, act, setOpen }) => {
    assert.equal(q('[data-debug-id="attention-deck"]').getAttribute('data-attention-sheet'), 'open', 'opens with the slide-up');
    assert.equal(q('[data-debug-id="attention-deck-backdrop"]').getAttribute('data-attention-backdrop'), 'open');
    await setOpen(false);
    const sheet = q('[data-debug-id="attention-deck"]');
    assert.ok(sheet, 'still mounted while it slides down');
    assert.equal(sheet.getAttribute('data-attention-sheet'), 'closing');
    assert.ok(sheet.hasAttribute('inert'), 'no input while closing');
    await act(async () => { await new Promise((r) => setTimeout(r, SHEET_MS + 40)); });
    assert.equal(q('[data-debug-id="attention-deck"]'), null, 'unmounted after the slide-down');
    await setOpen(true);
    assert.equal(q('[data-debug-id="attention-deck"]').getAttribute('data-attention-sheet'), 'open', 'reopens');
  });
});

test('deck: focus moves into the deck on open; Esc closes it once (menus first)', async () => {
  await withDeck([taskItem('a')], async ({ q, act, dom, closed }) => {
    const deck = q('[data-debug-id="attention-deck"]');
    assert.ok(deck.contains(dom.window.document.activeElement), 'focus is inside the deck');
    await act(async () => { q('[data-debug-id="attention-action-snooze"]').click(); });
    const esc = () => dom.window.document.activeElement.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    await act(async () => { esc(); });
    assert.equal(q('[data-debug-id="attention-snooze-menu"]'), null, 'first Esc closes the menu');
    assert.equal(closed(), 0, 'and not the deck');
    await act(async () => { esc(); });
    assert.equal(closed(), 1, 'second Esc closes the deck, exactly once');
  });
});

test('deck: quick replies sit outside the scrolling card, numbered; number keys send them', async () => {
  const long = 'Line of a long message. '.repeat(200);
  const item = messageItem('m', { details: { ...messageItem('m').details, excerpt: { author_name: 'soloist #7', body: long, at: '2026-10-16T11:30:00Z' } } });
  await withDeck([item], async ({ q, act, dom, hits, scheduler }) => {
    const options = q('[data-debug-id="attention-card-options"]');
    assert.ok(options, 'quick replies rendered');
    assert.equal(q('[data-debug-id="attention-deck-card"]').contains(options), false, 'not inside the scrolling card');
    const counter = q('[data-debug-id="attention-deck-counter"]');
    assert.equal(options.nextElementSibling, counter, 'just above the arrows');
    assert.match(options.textContent, /1Keep it/);
    assert.match(options.textContent, /2Skip it/);
    await act(async () => { dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: '2', bubbles: true })); });
    await act(async () => { await new Promise((r) => setTimeout(r, 30)); });
    const send = hits.find((h) => h.startsWith('POST /api/v1/chats/chat_secret_id/messages'));
    assert.ok(send, 'pressing 2 sends the second option');
    assert.ok(scheduler.getSnapshot().hidden.has('crd_msg_inst_m'));
  });
  await withDeck([messageItem('m')], async ({ act, dom, hits }) => {
    await act(async () => { dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: '5', bubbles: true })); });
    assert.equal(hits.filter((h) => h.startsWith('POST')).length, 0, 'a number with no option does nothing');
  });
});

test('deck: task cards have no Message coordinator action, and m does nothing there', async () => {
  await withDeck([taskItem('a')], async ({ q, act, dom, text, hits }) => {
    assert.ok(q('[data-debug-id="attention-deck-dock"]'), 'dock is rendered');
    assert.equal(q('[data-debug-id="attention-action-message-coordinator"]'), null);
    assert.doesNotMatch(text(), /Message coordinator/);
    await act(async () => { dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'm', bubbles: true })); });
    await act(async () => { await new Promise((r) => setTimeout(r, 20)); });
    assert.equal(q('[data-debug-id="attention-coordinator-input"]'), null, 'no composer opens');
    assert.equal(hits.filter((h) => h.includes('/task-chains/chain_secret_id') && !h.includes('/tasks/')).length, 0, 'no chain fetch');
  });
});

test('model: memory phrasing, expiry, live tab order', () => {
  assert.equal(model.memoryTypePhrase('fact'), 'a fact');
  assert.equal(model.memoryTypePhrase('expertise'), 'an expertise');
  assert.equal(model.memoryTypePhrase('episode'), 'an episode');
  assert.equal(model.memoryTypePhrase('weird'), 'a memory');
  assert.equal(model.expiryLine('2026-10-16T16:00:00Z', NOW), 'Expires in 4h');
  assert.equal(model.expiryLine('2026-10-16T12:30:00Z', NOW), 'Expires in 30 min');
  assert.equal(model.expiryLine('2026-10-20T12:00:00Z', NOW), '', 'far off: not shown');
  assert.equal(model.reasonLine(memoryItem('m'), NOW), 'Waiting on your approval · 1h');
  assert.equal(model.defaultTab({ message: 0, task: 0, memory: 2, snoozed: 1 }), 'memory');
  assert.equal(model.nextLiveTab('task', { message: 0, task: 0, memory: 2, snoozed: 1 }), 'memory');
  assert.equal(model.nextLiveTab('memory', { message: 1, task: 0, memory: 0, snoozed: 1 }), 'message', 'wraps around the live tabs');
  assert.equal(model.nextLiveTab('snoozed', { message: 0, task: 0, memory: 1, snoozed: 0 }), 'memory');
});

test('deck: memory card -- human heading, markdown body, who it applies to, approve / reject / edit', async () => {
  await withDeck([memoryItem('a'), memoryItem('b')], async ({ q, act, dom, text, scheduler, hits }) => {
    assert.ok(q('[data-debug-id="attention-card-memory"]'), 'opens on the Memories tab (only tab with cards)');
    assert.match(text(), /Memories2/);
    assert.match(q('[data-debug-id="attention-card-memory-heading"]').textContent, /soloist #21proposed an expertisewhile working onAttention deck rollout/);
    assert.match(text(), /Remember a/);
    const body = q('[data-debug-id="attention-card-memory-body"]');
    assert.ok(body.querySelector('h2'), 'body rendered as markdown');
    assert.match(body.className, /overflow-y-auto/, 'body scrolls on its own');
    const scope = q('[data-debug-id="attention-card-memory-scope"]').textContent;
    assert.match(scope, /Agentscodex-reviewer, soloist/);
    assert.match(scope, /ProjectsAll projects/);
    assert.match(scope, /MachinesAll machines/);
    assert.match(text(), /Expires in 4h/);
    assert.doesNotMatch(text(), /secret|crd_|mem_|agt_|inst_/, 'no ids rendered');
    for (const a of ['approve', 'reject', 'snooze', 'edit']) assert.ok(q(`[data-debug-id="attention-action-${a}"]`), `${a} offered`);

    await act(async () => { dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'x', bubbles: true })); });
    assert.equal(scheduler.getSnapshot().pending[0].label, 'Memory rejected');
    assert.match(text(), /Remember b/, 'moves on');
    await act(async () => { dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'a', bubbles: true })); });
    assert.equal(scheduler.getSnapshot().pending[1].label, 'Memory approved');
    await act(async () => { await scheduler.flushAll(true); });
    assert.ok(hits.includes('POST /api/v1/cards/crd_mem_mem_secret_a/reject'));
    assert.ok(hits.includes('POST /api/v1/cards/crd_mem_mem_secret_b/accept'));
  });
  await withDeck([memoryItem('c')], async ({ q, act, dom, closed }) => {
    await act(async () => { q('[data-debug-id="attention-action-edit"]').click(); });
    assert.match(dom.window.location.hash, /\/memory\/mem_secret_c\/edit/, 'Edit opens the memory editor');
    assert.equal(closed(), 1, 'and closes the deck');
  });
});

test('status bar: attention pill takes the left slot, rings for unseen items, reads as one number', async () => {
  const { attentionModule } = await import('../src/ui/components/shell/statusBar/modules.tsx');
  const { renderToStaticMarkup } = await import('react-dom/server');
  assert.equal(attentionModule.slot, 'left');
  const base: any = { runningInstances: 0, shells: { shells: 0, previews: 0, capped: false }, shortcutMode: 'normal', renderVaultToggle: () => null };
  assert.equal(attentionModule.render({ compact: false, data: base }), null);
  let opened = 0;
  const render = (attention: any, compact = false) => attentionModule.render({ compact, data: { ...base, attention } }) as any;
  const fresh = render({ total: 3, unseen: true, onOpen: () => { opened += 1; } });
  assert.equal(fresh.props['data-state'], 'waiting');
  assert.equal(fresh.props['data-ring'], 'spinning');
  const freshHtml = renderToStaticMarkup(fresh);
  assert.match(freshHtml, />3 need you</);
  assert.match(freshHtml, /animate-\[spin_2\.5s_linear_infinite\]/, 'the ring spins');
  assert.match(freshHtml, /motion-safe:/, 'only when motion is allowed');
  assert.match(freshHtml, /conic-gradient/);
  fresh.props.onClick();
  assert.equal(opened, 1);
  const seen = render({ total: 3, unseen: false, onOpen: () => {} });
  assert.equal(seen.props['data-ring'], 'static');
  assert.doesNotMatch(renderToStaticMarkup(seen), /animate-/, 'seen: a still ring');
  const clear = render({ total: 0, unseen: false, onOpen: () => {} });
  assert.equal(clear.props['data-state'], 'clear');
  assert.equal(clear.props['data-ring'], 'none');
  assert.match(renderToStaticMarkup(clear), />All clear</);
  assert.match(renderToStaticMarkup(render({ total: 12, unseen: true, onOpen: () => {} }, true)), />12</);
  assert.equal(render({ total: null, unseen: false, onOpen: () => {} }).props['data-state'], 'loading');
});
