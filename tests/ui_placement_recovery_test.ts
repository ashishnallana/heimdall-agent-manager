import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';
import attentionReducer, { setPlacementDraft } from '../src/ui/store/attentionSlice.ts';
import { placementIdentityCandidates, placementRecoveryInput, placementTargetKey } from '../src/ui/components/attention/attentionModel.ts';
import type { PlacementTarget } from '../src/ui/api/endpoints/attention.ts';

function target(agent = 'agt_failed', phase: 'work' | 'review' = 'review', role = 'named'): PlacementTarget {
  return {
    failure: { phase, agent_id: agent, role, bridge_id: 'brg_mac', directory_id: 'dir_mac', source: 'fleet', reason: 'bridge_offline', message: 'Placement bridge is offline', provider: 'codex', provider_profile: 'codex', model: 'gpt-test', configuration: 'configuration-1', fingerprint: 'failure-1' },
    guard: { expected_attempt: 0, phase, agent_id: agent, role, fingerprint: 'failure-1', configuration: 'configuration-1', expected_assignment: phase === 'work' ? '' : agent },
    bridge_action: 'change_bridge', bridge_action_label: 'Change bridge', bridge_scope_label: phase === 'work' ? 'This ticket' : 'All tickets using this fleet',
    identity_action: phase === 'work' ? 'change_assignee' : role === 'named' ? 'change_reviewer' : 'configure_fleet',
    identity_action_label: phase === 'work' ? 'Change assignee' : 'Change reviewer', identity_scope: role === 'named' || phase === 'work' ? 'ticket' : 'chain_fleet',
    fleet_configuration: role !== 'named' && phase !== 'work', affected_task_ids: ['task_recovery', 'task_other'],
  };
}
function placement(targets = [target()]): any {
  return {
    card_id: 'crd_placement_task_recovery_0', kind: 'task', provider: 'task_placement', reason: 'placement', urgency: 'warn', status: 'pending',
    attention_since: '2026-11-02T12:00:00Z', title: 'Recover placement', rationale: 'Placement needs repair', primary_op: null, operations: [],
    details: { attention: 'placement', attempt_no: 0, targets }, action_refs: { chain_id: 'chain_recovery', task_id: 'task_recovery' },
    context: { chain_title: 'Recovery chain', agent_name: '', project_name: '' },
  };
}
const agents = [
  { agent_id: 'agt_failed', name: 'Failed reviewer', state: 'active' },
  { agent_id: 'agt_second', name: 'Second reviewer', state: 'active' },
  { agent_id: 'agt_replacement', name: 'Replacement', state: 'active' },
  { agent_id: 'agt_worker', name: 'Worker', state: 'active' },
  { agent_id: 'agt_paused', name: 'Paused', state: 'active' },
  { agent_id: 'agt_archived', name: 'Archived', state: 'archived' },
  { agent_id: 'inst_fake', name: 'Instance', state: 'active' },
];
const fleets = agents.map((a) => ({
  agent_id: a.agent_id, capacity: 1, roles: a.agent_id === 'agt_worker' ? ['worker'] : ['reviewer', 'security'],
  paused_roles: a.agent_id === 'agt_paused' ? ['reviewer', 'security'] : [],
  provider: 'codex', provider_profile: 'codex', model: 'gpt-test', bridge_id: 'brg_mac',
}));
const bridges = [
  { bridge_id: 'brg_mac', label: 'MacBook', status: 'offline' },
  { bridge_id: 'brg_river', label: 'Riverwood', status: 'online' },
  { bridge_id: 'brg_revoked', label: 'Revoked', status: 'online', revoked_at: 'yesterday' },
  { bridge_id: 'brg_pending', label: 'Pending', status: 'online', enrollment_pending_until: 'tomorrow' },
];
const task = { task_id: 'task_recovery', chain_id: 'chain_recovery', state: 'in_review', brief: { assignee: 'agt_worker', reviewers: ['agt_failed', 'agt_second'], review_roles: ['security'] }, requires_user_approval: true, leases: [] };

test('recovery model: guards preserve zero/empty values and explicit action scope', () => {
  const worker = target('agt_worker', 'work', 'worker');
  assert.deepEqual(placementRecoveryInput(worker, 'bridge', 'brg_river'), { ...worker.guard, action: 'change_bridge', scope: 'ticket', bridge_id: 'brg_river' });
  const reviewer = target();
  assert.equal(placementRecoveryInput(reviewer, 'bridge', 'brg_river').scope, 'chain_fleet');
  assert.equal(placementRecoveryInput(reviewer, 'identity', 'agt_replacement').scope, 'ticket');
  assert.throws(() => placementRecoveryInput(target('agt_failed', 'review', 'security'), 'identity', 'agt_replacement'), /native fleet/);
  const input: any = placementRecoveryInput(reviewer, 'identity', 'agt_replacement');
  assert.ok(!('reviewers' in input));
  assert.ok(!('requires_user_approval' in input));
});

test('recovery model: native roles/pauses and active durable identities; drafts are independent', () => {
  assert.deepEqual(placementIdentityCandidates(target(), fleets, agents, ['agt_second']).map((c) => c.agentId), ['agt_replacement']);
  assert.deepEqual(placementIdentityCandidates(target('agt_failed', 'review', 'security'), fleets, agents).map((c) => c.agentId), ['agt_replacement', 'agt_second']);
  assert.deepEqual(placementIdentityCandidates(target('agt_failed', 'work', 'worker'), fleets, agents).map((c) => c.agentId), ['agt_worker']);
  const a = placementTargetKey('card', target());
  const b = placementTargetKey('card', target('agt_second'));
  let state = attentionReducer(undefined, { type: 'init' });
  state = attentionReducer(state, setPlacementDraft({ key: a, draft: { action: 'bridge', bridgeId: 'brg_river', agentId: '' } }));
  state = attentionReducer(state, setPlacementDraft({ key: b, draft: { action: 'identity', bridgeId: '', agentId: 'agt_replacement' } }));
  assert.equal(state.placementDrafts[a].bridgeId, 'brg_river');
  assert.equal(state.placementDrafts[b].agentId, 'agt_replacement');
});

const json = (data: any, status = 200) => new Response(JSON.stringify({ data }), { status, headers: { 'Content-Type': 'application/json' } });
type Options = { items?: any[]; task?: any; fleets?: any[]; failures?: Array<{ status: number; message: string }>; onRecover?: (body: any) => void; providerModels?: string[] };
async function withRecovery(opts: Options, run: (h: any) => Promise<void>) {
  const { JSDOM } = await import('jsdom');
  const { Provider } = await import('react-redux');
  const { createRoot } = await import('react-dom/client');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { AttentionDeck } = await import('../src/ui/components/attention/AttentionDeck.tsx');
  const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true });
  const saved: any = {};
  for (const k of ['window', 'document', 'HTMLElement', 'Node', 'KeyboardEvent', 'fetch']) saved[k] = (globalThis as any)[k];
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, KeyboardEvent: dom.window.KeyboardEvent, IS_REACT_ACT_ENVIRONMENT: true });
  (globalThis as any).requestAnimationFrame = (cb: any) => setTimeout(() => cb(Date.now()), 0);
  (globalThis as any).cancelAnimationFrame = clearTimeout;
  (dom.window.HTMLElement.prototype as any).attachEvent = () => {};
  (dom.window.HTMLElement.prototype as any).detachEvent = () => {};
  let items = opts.items || [placement()];
  let currentTask = opts.task || task;
  let attentionUnavailable = false;
  const hits: Array<{ method: string; path: string; body?: any }> = [];
  (globalThis as any).fetch = async (input: any, init: any = {}) => {
    const url = new URL(String(input?.url || input), 'http://localhost');
    const method = init.method || 'GET';
    const body = init.body ? JSON.parse(init.body) : undefined;
    hits.push({ method, path: url.pathname, body });
    if (url.pathname.endsWith('/placement-recovery')) {
      const failure = opts.failures?.shift();
      if (failure) return new Response(JSON.stringify({ error: { code: failure.status === 409 ? 'conflict' : 'validation_failed', message: failure.message } }), { status: failure.status });
      opts.onRecover?.(body);
      return json({ task: currentTask, repaired: true });
    }
    if (url.pathname.endsWith('/attention')) {
      if (attentionUnavailable) return new Response(JSON.stringify({ error: { message: 'Attention temporarily unavailable' } }), { status: 503 });
      return json({ since: 'all', counts: { total: items.length, task: items.length }, items });
    }
    if (url.pathname.endsWith('/agents')) return json({ agents });
    if (url.pathname.endsWith('/agent-instances')) return json([{ agent_instance_id: 'inst_second', agent_id: 'agt_second' }]);
    if (url.pathname.endsWith('/bridges')) return json({ bridges });
    if (url.pathname.endsWith('/provider-status')) return json({ providers: [{ provider: 'codex', enabled: true, state: 'present', catalog_state: 'active', models: (opts.providerModels || ['gpt-test']).map((model_id) => ({ model_id, state: 'active' })) }] });
    if (url.pathname.endsWith('/bridge-support')) return json({ entries: [] });
    if (url.pathname.endsWith('/fleets')) return json(opts.fleets || fleets);
    if (url.pathname.endsWith('/task-chains/chain_recovery')) return json({ task_chain_id: 'chain_recovery', tasks: [currentTask, { ...currentTask, task_id: 'task_other', title: 'Other queued ticket' }] });
    if (url.pathname.endsWith('/tasks/task_recovery')) return json(currentTask);
    return json({});
  };
  const store = await makeVaultStore({ extraReducers: { attention: attentionReducer } });
  const root = createRoot(dom.window.document.getElementById('root')!);
  let closedCount = 0;
  const drain = async () => { await act(async () => { await new Promise((r) => setTimeout(r, 50)); }); };
  const render = (open: boolean) => root.render(React.createElement(Provider, { store }, React.createElement(AttentionDeck, { open, onClose: () => { closedCount += 1; }, range: 'all', onRangeChange: () => {}, nowMs: Date.parse('2026-11-02T15:00:00Z') })));
  const q = (id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`) as any;
  const click = async (id: string) => { assert.ok(q(id), id); await act(async () => q(id).click()); await drain(); };
  const select = async (id: string, value: string) => {
    assert.ok(q(id), id);
    await act(async () => { q(id).value = value; q(id).dispatchEvent(new dom.window.Event('change', { bubbles: true })); });
    await drain();
  };
  try {
    await act(async () => render(true)); await drain(); await drain();
    await run({ q, click, select, store, hits, dom, drain, text: () => dom.window.document.body.textContent || '',
      failAttention: (failed: boolean) => { attentionUnavailable = failed; },
      closed: () => closedCount,
      serve: async (next: any[], nextTask = currentTask) => {
        items = next; currentTask = nextTask;
        await act(async () => store.dispatch(heimdallApi.util.invalidateTags(['Attention', 'Task'])));
        await drain(); await drain();
      },
      reopen: async () => { await act(async () => render(false)); await drain(); await act(async () => render(true)); await drain(); },
    });
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    await drain(); dom.window.close();
    Object.assign(globalThis, saved);
  }
}
const p = 'attention-placement-review-agt_failed-named';

test('deck: effective reviewer bridge, fleet scope confirmation, targeted repair and independent attention retirement', async () => {
  const review = { ...placement(), card_id: 'crd_task_review', provider: 'task_validation', reason: 'awaiting_review', details: { priority: 'p2', attention: 'review', excerpt: null } };
  const question = { ...review, card_id: 'crd_task_question', details: { priority: 'p2', attention: 'blocked', badge: 'question', excerpt: null } };
  let payload: any;
  await withRecovery({ items: [placement(), review, question], onRecover: (body) => { payload = body; } }, async (h) => {
    assert.match(h.q(`${p}-effective`).textContent, /MacBook.*Chain fleet/);
    assert.equal(h.q('attention-approve'), null, 'placement cannot be approved');
    await h.select(`${p}-select`, 'brg_river');
    assert.equal(h.q(`${p}-select`).options.length, 2, 'offline/revoked/pending bridges excluded');
    assert.match(h.q(`${p}-scope`).textContent, /All tickets.*future grants.*Existing leases/);
    assert.match(h.q(`${p}-affected`).textContent, /2/);
    assert.equal(payload, undefined);
    await h.click(`${p}-review`);
    assert.match(h.q(`${p}-affected-list`).textContent, /Other queued ticket/);
    assert.match(h.q(`${p}-confirmation`).textContent, /Riverwood.*Failed reviewer.*chain fleet/);
    await h.click(`${p}-apply`);
    assert.deepEqual(payload, placementRecoveryInput(target(), 'bridge', 'brg_river'));
    assert.equal(h.hits.filter((r: any) => r.method === 'PATCH').length, 0);
    await h.serve([review, question]);
    assert.equal(h.q('attention-placement'), null);
    const cached = Object.values((h.store.getState() as any)[(await import('../src/ui/api/heimdallApi.ts')).heimdallApi.reducerPath].queries).find((v: any) => v.endpointName === 'getAttention' && v.originalArgs.since === 'all') as any;
    assert.deepEqual(cached.data.items.map((i: any) => i.card_id), ['crd_task_review', 'crd_task_question']);
  });
});

test('deck: multiple reviewer selections survive workspace errors and remount; replacement is ticket scoped', async () => {
  await withRecovery({ items: [placement([target(), target('agt_second')])], failures: [{ status: 422, message: 'No chain workspace is mapped on the placement bridge' }] }, async (h) => {
    const second = 'attention-placement-review-agt_second-named';
    await h.select(`${p}-select`, 'brg_river');
    await h.click(`${second}-identity`);
    await h.select(`${second}-select`, 'agt_replacement');
    await h.click(`${p}-review`); await h.click(`${p}-apply`);
    assert.match(h.q(`${p}-error`).textContent, /workspace/);
    assert.equal(h.q(`${p}-select`).value, 'brg_river');
    assert.equal(h.q(`${second}-select`).value, 'agt_replacement');
    assert.match(h.q(`${second}-scope`).textContent, /only this failed named reviewer.*user approval/);
    await h.reopen();
    assert.equal(h.q(`${p}-select`).value, 'brg_river');
    assert.equal(h.q(`${second}-select`).value, 'agt_replacement');
    await h.click(`${second}-review`); await h.click(`${second}-apply`);
    const posts = h.hits.filter((r: any) => r.path.endsWith('/placement-recovery'));
    assert.deepEqual(posts[1].body, placementRecoveryInput(target('agt_second'), 'identity', 'agt_replacement'));
  });
});

test('deck: conflict refresh retains destination and requires confirmation with fresh guards', async () => {
  await withRecovery({ failures: [{ status: 409, message: 'Placement failure changed; refresh the card' }] }, async (h) => {
    await h.select(`${p}-select`, 'brg_river'); await h.click(`${p}-review`); await h.click(`${p}-apply`);
    assert.equal(h.q(`${p}-review`).disabled, true);
    await h.reopen();
    assert.equal(h.q(`${p}-review`).disabled, true, 'rejected observation stays rejected after remount');
    const fresh = target(); fresh.guard.configuration = 'configuration-2'; fresh.guard.fingerprint = 'failure-2';
    await h.serve([placement([fresh])]);
    assert.equal(h.q(`${p}-select`).value, 'brg_river');
    assert.equal(h.q(`${p}-apply`), null);
    await h.click(`${p}-review`); await h.click(`${p}-apply`);
    const posts = h.hits.filter((r: any) => r.path.endsWith('/placement-recovery'));
    assert.equal(posts[1].body.fingerprint, 'failure-2');
    assert.equal(posts[1].body.configuration, 'configuration-2');
  });
});

test('deck: workflow, live target lease and unavailable provider remain visible and prevent apply', async () => {
  await withRecovery({ task: { ...task, workflow_run_id: 'run_native' } }, async (h) => {
    assert.match(h.text(), /workflow-managed.*workflow configuration/);
    assert.equal(h.q(`${p}-select`), null);
  });
  const worker = target('agt_worker', 'work', 'worker');
  await withRecovery({ items: [placement([worker])], task: { ...task, leases: [{ kind: 'work', holder_instance_id: 'inst_worker' }] } }, async (h) => {
    assert.match(h.text(), /live lease.*checkpoint\/hold/);
    assert.equal(h.q('attention-placement-work-agt_worker-worker-select').disabled, true);
    assert.match(h.q('attention-placement-work-agt_worker-worker-scope').textContent, /only its worker bridge pin/);
  });
  await withRecovery({ providerModels: ['different-model'] }, async (h) => {
    await h.select(`${p}-select`, 'brg_river');
    assert.match(h.text(), /provider\/profile\/model is unavailable/);
    assert.equal(h.q(`${p}-review`).disabled, true);
  });
});

test('deck: role review routes to native fleet configuration without task assignment', async () => {
  await withRecovery({ items: [placement([target('agt_failed', 'review', 'security')])] }, async (h) => {
    const rolePrefix = 'attention-placement-review-agt_failed-security';
    assert.equal(h.q(`${rolePrefix}-identity`), null);
    assert.match(h.text(), /cannot assign a single replacement.*Other role requirements/);
    await h.click(`${rolePrefix}-fleet`);
    assert.match(h.q('fleet-drawer-recovery-role').textContent, /security.*whole chain/);
    assert.equal(h.hits.filter((r: any) => r.path.endsWith('/placement-recovery')).length, 0);
  });
});

test('deck: worker assignee replacement keeps attempt zero, empty assignment and ticket scope', async () => {
  const worker = target('agt_worker', 'work', 'worker');
  let payload: any;
  await withRecovery({
    items: [placement([worker])], task: { ...task, state: 'ready', brief: { ...task.brief, assignee: '' } },
    fleets: fleets.map((f) => f.agent_id === 'agt_replacement' ? { ...f, roles: ['worker'] } : f),
    onRecover: (body) => { payload = body; },
  }, async (h) => {
    const prefix = 'attention-placement-work-agt_worker-worker';
    await h.click(`${prefix}-identity`);
    await h.select(`${prefix}-select`, 'agt_replacement');
    assert.match(h.q(`${prefix}-scope`).textContent, /only its durable assignee/);
    await h.click(`${prefix}-review`); await h.click(`${prefix}-apply`);
    assert.deepEqual(payload, placementRecoveryInput(worker, 'identity', 'agt_replacement'));
    assert.equal(payload.expected_attempt, 0);
    assert.equal(payload.expected_assignment, '');
  });
});

test('deck: unrelated live reviewer does not prevent repair; target live reviewer does', async () => {
  const liveTask = { ...task, leases: [{ kind: 'review', holder_instance_id: 'inst_second', review_role: 'named' }] };
  await withRecovery({ items: [placement([target(), target('agt_second')])], task: liveTask }, async (h) => {
    await h.select(`${p}-select`, 'brg_river');
    assert.equal(h.q(`${p}-review`).disabled, false);
    const second = 'attention-placement-review-agt_second-named';
    assert.equal(h.q(`${second}-select`).disabled, true);
    assert.match(h.q(second).textContent, /This target has a live lease/);
  });
});

test('deck: failed stale refresh keeps selection and disables replay until a successful current read', async () => {
  await withRecovery({ failures: [{ status: 409, message: 'Placement changed; refresh' }] }, async (h) => {
    await h.select(`${p}-select`, 'brg_river'); await h.click(`${p}-review`); await h.click(`${p}-apply`);
    h.failAttention(true);
    await h.click(`${p}-refresh`);
    assert.equal(h.q(`${p}-select`).value, 'brg_river');
    assert.equal(h.q(`${p}-review`).disabled, true);
    assert.match(h.q(`${p}-error`).textContent, /temporarily unavailable/);
    h.failAttention(false);
    await h.click(`${p}-refresh`);
    assert.equal(h.q(`${p}-review`).disabled, false, 'fresh read permits a new confirmation');
    assert.equal(h.q(`${p}-error`), null, 'successful refresh clears the prior request error');
    assert.equal(h.q(`${p}-apply`), null, 'fresh read never applies automatically');
    assert.equal(h.hits.filter((r: any) => r.path.endsWith('/placement-recovery')).length, 1);
  });
});

test('deck: native dropdown and portaled fleet editor own their keyboard events', async () => {
  await withRecovery({ items: [placement([target('agt_failed', 'review', 'security')])] }, async (h) => {
    const prefix = 'attention-placement-review-agt_failed-security';
    const select = h.q(`${prefix}-select`);
    await act(async () => {
      select.focus();
      select.dispatchEvent(new h.dom.window.KeyboardEvent('keydown', { key: 's', bubbles: true }));
      select.dispatchEvent(new h.dom.window.KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
    });
    assert.equal(h.q('attention-snooze-menu'), null);
    assert.ok(h.q(prefix));
    await h.click(`${prefix}-fleet`);
    const drawer = h.q('fleet-management-drawer');
    assert.ok(drawer);
    await act(async () => {
      drawer.focus();
      drawer.dispatchEvent(new h.dom.window.KeyboardEvent('keydown', { key: 's', bubbles: true }));
    });
    assert.equal(h.q('attention-snooze-menu'), null);
    await act(async () => drawer.dispatchEvent(new h.dom.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })));
    await h.drain();
    assert.equal(h.closed(), 0, 'Escape closes the fleet editor without closing the deck');
    assert.ok(h.q(prefix));
  });
});
