// Chat-pane action tray (REQ-AT-1/6/7): which task items a conversation shows,
// and the tray <-> composer toggle state.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_action_tray_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

const tray = await import('../src/ui/components/attention/actionTrayModel.ts');
const { hideKey } = await import('../src/ui/components/attention/attentionModel.ts');

function taskItem(id: string, details: any = {}, extra: any = {}): any {
  return {
    card_id: `crd_${id}`, kind: 'task', provider: 'task_validation', reason: '', urgency: 'warn', status: 'pending',
    snoozed: false, snooze_until: '', attention_since: '2026-10-20T06:00:00Z', title: `Task ${id}`, rationale: '',
    primary_op: null, operations: [],
    details: { priority: 'p2', status: 'in_review', bridge_id: '', assignee_name: 'worker #2', excerpt: null, attention: 'review', ...details },
    action_refs: { chain_id: 'chain_a', task_id: `task_${id}` },
    context: { chain_title: 'Chain A', agent_name: 'worker #2', project_name: '' },
    ...extra,
  };
}

const SCOPE = { chainId: 'chain_a', agentInstanceId: 'inst_me' };

test('review tray warns about skipped verify from card metadata or the attempt handoff', async () => {
  const React = await import('react');
  const { Provider } = await import('react-redux');
  const { renderToStaticMarkup } = await import('react-dom/server');
  const { makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
  const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
  const { ActionTaskCard } = await import('../src/ui/components/attention/ActionTaskCard.tsx');
  for (const source of ['card', 'handoff']) {
    const store = await makeVaultStore();
    const reason = 'Runner unavailable; manual review needed.';
    const item = taskItem('skip', source === 'card' ? { skip_verify_reason: reason } : {});
    if (source === 'handoff') {
      const args = { chainId: 'chain_a', taskId: 'task_skip', attemptNo: 1 };
      await store.dispatch(tasksApi.util.upsertQueryData('fetchTaskFacet', { ...args, kind: 'handoff' }, { facet: { skip_verify_reason: reason } }));
      await store.dispatch(tasksApi.util.upsertQueryData('fetchTaskFacet', { ...args, kind: 'verify' }, { facet: { exit_code: 0 } }));
    }
    const html = renderToStaticMarkup(React.createElement(Provider, { store, children: React.createElement(ActionTaskCard, {
      item, mobile: true, active: source === 'handoff', now: Date.now(), footer: null,
    }) }));
    assert.match(html, /Verify skipped: .*Runner unavailable; manual review needed\./);
    assert.match(html, /data-debug-id="action-tray-review-verify-skipped" class="[^"]*text-warning/);
    assert.doesNotMatch(html, /Verify passed/);
    store.dispatch(tasksApi.util.resetApiState());
  }
});

test('trayItems keeps blocked and review task items of this chain, in server order', () => {
  const items = [
    taskItem('review'),
    taskItem('blocked', { attention: 'blocked', badge: 'question' }),
    taskItem('other-chain', {}, { action_refs: { chain_id: 'chain_b', task_id: 'task_x' } }),
    taskItem('no-attention', { attention: undefined }),
    { ...taskItem('msg'), kind: 'message' },
    { ...taskItem('mem'), kind: 'memory' },
  ];
  assert.deepEqual(tray.trayItems(items, SCOPE).map((i: any) => i.card_id), ['crd_review', 'crd_blocked']);
});

test('trayItems drops snoozed cards and cards hidden by a pending/settled action', () => {
  const live = taskItem('live');
  const snoozed = taskItem('snoozed', {}, { snoozed: true, snooze_until: '2026-10-21T09:00:00Z' });
  const settled = taskItem('settled');
  const hidden = new Set([hideKey(settled)]);
  assert.deepEqual(tray.trayItems([live, snoozed, settled], SCOPE, hidden).map((i: any) => i.card_id), ['crd_live']);
});

test('trayItems without a chain matches the task holder instance instead', () => {
  const mine = taskItem('mine', { holder_instance_id: 'inst_me' }, { action_refs: { chain_id: 'chain_z', task_id: 't1' } });
  const theirs = taskItem('theirs', { holder_instance_id: 'inst_other' });
  const scope = { chainId: '', agentInstanceId: 'inst_me' };
  assert.deepEqual(tray.trayItems([mine, theirs], scope).map((i: any) => i.card_id), ['crd_mine']);
  // With a chain, the holder does not matter: the chain decides.
  assert.deepEqual(tray.trayItems([mine, theirs], SCOPE).map((i: any) => i.card_id), ['crd_theirs']);
  assert.deepEqual(tray.trayItems([mine], { chainId: '', agentInstanceId: '' }), []);
});

test('needLabel and needYouLabel', () => {
  assert.equal(tray.needLabel(taskItem('a', { attention: 'blocked' })), 'Needs your answer');
  assert.equal(tray.needLabel(taskItem('b')), 'Needs your approval');
  assert.equal(tray.needLabel(taskItem('c', { attention: 'blocked', badge: 'agent_not_running' })), 'Needs you to start the agent');
  assert.equal(tray.needYouLabel(3), '3 need you');
});

test('toggle: items show the tray; Composer switches to the composer; the pill switches back', () => {
  let s = tray.trayReducer(tray.INITIAL_TRAY_STATE, { type: 'items', ids: ['a', 'b'], draftEmpty: true });
  assert.equal(tray.trayVisible(s, 2), true);
  assert.equal(tray.needYouPillVisible(s, 2), false);
  s = tray.trayReducer(s, { type: 'show_composer' });
  assert.equal(tray.trayVisible(s, 2), false);
  assert.equal(tray.needYouPillVisible(s, 2), true);
  s = tray.trayReducer(s, { type: 'show_items' });
  assert.equal(tray.trayVisible(s, 2), true);
});

test('toggle: no items means no tray and no pill, whatever the view', () => {
  const s = tray.trayReducer(tray.INITIAL_TRAY_STATE, { type: 'items', ids: [], draftEmpty: true });
  assert.equal(tray.trayVisible(s, 0), false);
  assert.equal(tray.needYouPillVisible(s, 0), false);
});

test('toggle: a mode borrows the composer (no tray, no pill); sending or cancelling returns to the items', () => {
  let s = tray.trayReducer(tray.INITIAL_TRAY_STATE, { type: 'items', ids: ['a', 'b'], draftEmpty: true });
  s = tray.trayReducer(s, { type: 'start_mode', kind: 'answer', cardId: 'a' });
  assert.deepEqual(s.mode, { kind: 'answer', cardId: 'a' });
  assert.equal(tray.trayVisible(s, 2), false);
  assert.equal(tray.needYouPillVisible(s, 2), false);
  const sent = tray.trayReducer(s, { type: 'mode_sent' });
  assert.equal(sent.mode, null);
  assert.equal(tray.trayVisible(sent, 1), true);
  const cancelled = tray.trayReducer(s, { type: 'cancel_mode' });
  assert.equal(cancelled.mode, null);
  assert.equal(tray.trayVisible(cancelled, 2), true);
});

test('toggle: the moded card leaving (answered elsewhere) drops the mode', () => {
  let s = tray.trayReducer(tray.INITIAL_TRAY_STATE, { type: 'items', ids: ['a', 'b'], draftEmpty: true });
  s = tray.trayReducer(s, { type: 'start_mode', kind: 'changes', cardId: 'a' });
  s = tray.trayReducer(s, { type: 'items', ids: ['b'], draftEmpty: true });
  assert.equal(s.mode, null);
  assert.equal(tray.trayVisible(s, 1), true);
});

test('toggle: a NEW item takes the dock back unless the user is typing; known items do not', () => {
  let s = tray.trayReducer(tray.INITIAL_TRAY_STATE, { type: 'items', ids: ['a'], draftEmpty: true });
  s = tray.trayReducer(s, { type: 'show_composer' });
  // Same ids again (a refetch): the user's choice stands.
  s = tray.trayReducer(s, { type: 'items', ids: ['a'], draftEmpty: true });
  assert.equal(s.view, 'composer');
  // A new one while typing: the composer stays.
  const typing = tray.trayReducer(s, { type: 'items', ids: ['a', 'b'], draftEmpty: false });
  assert.equal(typing.view, 'composer');
  // The same new one when not typing: the tray.
  const idle = tray.trayReducer(s, { type: 'items', ids: ['a', 'b'], draftEmpty: true });
  assert.equal(idle.view, 'items');
  // A mode is never interrupted by a new item.
  let m = tray.trayReducer(s, { type: 'start_mode', kind: 'answer', cardId: 'a' });
  m = tray.trayReducer(m, { type: 'items', ids: ['a', 'c'], draftEmpty: true });
  assert.deepEqual(m.mode, { kind: 'answer', cardId: 'a' });
});

test('trayReducer returns the same state when nothing changed (no re-render loop)', () => {
  const s = tray.trayReducer(tray.INITIAL_TRAY_STATE, { type: 'items', ids: ['a'], draftEmpty: true });
  assert.equal(tray.trayReducer(s, { type: 'items', ids: ['a'], draftEmpty: true }), s);
  assert.equal(tray.trayReducer(s, { type: 'show_items' }), s);
});

test('artifactIdsFrom: facet refs/paths/urls then ids named in the summary, deduplicated', () => {
  const facet = { items: [
    { kind: 'url', url: 'https://hub.example/#/library/artifacts/art_18e01e2af0815535' },
    { kind: 'file', path: '/tmp/shot.png' },
    { kind: 'file', ref: 'art_18e01e2afb169bfd' },
  ] };
  assert.deepEqual(
    tray.artifactIdsFrom(facet, 'Screenshots art_18e01e2af0815535 and art_18e01e2b08eced50.'),
    ['art_18e01e2af0815535', 'art_18e01e2afb169bfd', 'art_18e01e2b08eced50'],
  );
  assert.deepEqual(tray.artifactIdsFrom(null, ''), []);
  assert.deepEqual(tray.artifactIdsFrom([{ kind: 'file', ref: 'art_0123456789abcdef' }]), ['art_0123456789abcdef']);
});

test('artifactLinksFrom keeps plain http links only', () => {
  const facet = { items: [
    { kind: 'url', url: 'https://preview.example/p/sh_1/', label: 'Gallery' },
    { kind: 'url', url: 'https://hub.example/#/library/artifacts/art_18e01e2af0815535' },
    { kind: 'preview_port', port: 5173 },
    { kind: 'link', uri: 'javascript:alert(1)' },
  ] };
  assert.deepEqual(tray.artifactLinksFrom(facet), [{ label: 'Gallery', href: 'https://preview.example/p/sh_1/' }]);
});

test('handoffDecisions accepts strings and objects', () => {
  assert.deepEqual(tray.handoffDecisions({ decisions: ['use rejectCard', { decision: 'no Delegate on blocked' }, { text: '' }, 7] }), ['use rejectCard', 'no Delegate on blocked']);
  assert.deepEqual(tray.handoffDecisions(null), []);
});

test('chat tray Start agent stays visible with an inline failure and retry', async () => {
  const React = await import('react');
  const { act } = React;
  const { JSDOM } = await import('jsdom');
  const { createRoot } = await import('react-dom/client');
  const { Provider } = await import('react-redux');
  const { makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
  const { ActionTray } = await import('../src/ui/components/attention/ActionTray.tsx');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true });
  const saved: any = {};
  for (const key of ['window', 'document', 'HTMLElement', 'Node', 'IS_REACT_ACT_ENVIRONMENT']) saved[key] = (globalThis as any)[key];
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true });
  const previousFetch = globalThis.fetch;
  let requests = 0;
  globalThis.fetch = (async () => {
    requests += 1;
    return requests === 1
      ? { ok: false, status: 409, text: async () => JSON.stringify({ error: { message: 'Launch refused: bridge offline' } }) }
      : { ok: true };
  }) as any;
  const store = await makeVaultStore();
  const root = createRoot(dom.window.document.getElementById('root')!);
  const item = taskItem('start', { attention: 'blocked', badge: 'agent_not_running', block_id: 'b1' }, {
    primary_op: 'agent.start', operations: [{ op: 'agent.start', label: 'Start agent' }], rationale: 'worker on bridge b is stopped',
  });
  const q = (id: string) => dom.window.document.querySelector('[data-debug-id="' + id + '"]') as HTMLElement | null;
  try {
    await act(async () => { root.render(React.createElement(Provider, { store, children: React.createElement(ActionTray, {
      items: [item], mobile: true, onShowComposer: () => {}, onStartMode: () => { throw new Error('Start must not borrow composer'); },
    }) })); });
    assert.ok(q('action-tray-start-agent'));
    assert.equal(q('action-tray-answer'), null);
    assert.match(dom.window.document.body.textContent || '', /worker on bridge b is stopped/);
    await act(async () => { q('action-tray-start-agent')!.click(); });
    assert.match(q('action-tray-start-agent-error')!.textContent || '', /bridge offline/);
    assert.ok(q('action-tray-card-blocked'));
    await act(async () => { q('action-tray-start-agent')!.click(); });
    assert.equal(q('action-tray-start-agent-error'), null);
    assert.equal(requests, 2);
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    globalThis.fetch = previousFetch;
    for (const key of Object.keys(saved)) (globalThis as any)[key] = saved[key];
    dom.window.close();
  }
});
