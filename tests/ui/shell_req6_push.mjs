// REQ-SHELL-6 AC3 — the UI half of "a status change lands with all pollers removed",
// proved by running the REAL handler over the hub's REAL frame shapes.
//
// Why this test exists rather than a source grep: AC3 is a claim about a CHAIN of three
// links — the hub emits an event, the UI handles that exact type, and handling it
// invalidates the tags the shell views read. Before REQ-SHELL-6 link two was broken (the
// UI listened for a `shell_status` type nothing on the user bus produces), and with the
// pollers gone that break means a run indicator frozen forever. A regex can see that a
// case label exists; only executing the handler shows the invalidation actually happens.
//
// The frames below are transcribed from the hub's own serialisers, not invented:
//   _shell_exited_event_json         src/hub/service/shell_session/shell_session_service.odin:1993
//   _publish_inventory_change        src/hub/service/shell_session/shell_session_inventory.odin:420-429
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { flushQueuedInvalidations, handleUserWsEvent as handleFrame } from './ws.mjs';

// Shell invalidations ride the burst window (INVALIDATION_COALESCE_MS); flush it so
// each test reads what the frame dispatched.
function handleUserWsEvent(dispatch, frame) {
  handleFrame(dispatch, frame);
  flushQueuedInvalidations();
}

/** Collect every RTK `invalidateTags` payload a handler dispatches. */
function record() {
  const tags = [];
  const actions = [];
  const dispatch = (action) => {
    // A thunk (the notification funnel) — run it with stubs so it cannot throw here.
    if (typeof action === 'function') {
      try { action(dispatch, () => ({})); } catch { /* notifications must not break invalidation */ }
      return action;
    }
    actions.push(action);
    const payload = action?.payload;
    if (Array.isArray(payload) && action?.type?.includes('invalidateTags')) {
      for (const t of payload) tags.push(`${t.type}:${t.id}`);
    }
    return action;
  };
  return { dispatch, tags, actions };
}

// Exactly what _shell_exited_event_json writes.
const EXITED_FRAME = {
  type: 'shell_session_exited',
  session_id: 'sh_abc123',
  status: 'exited',
  exit_code: 0,
  ts: 1759072000000,
};

// Exactly what _publish_inventory_change writes: the generic resource_changed envelope
// used by the convergence adopt/correct path, whose payload is {"status":"..."}.
const CONVERGENCE_FRAME = {
  type: 'resource_changed',
  resource: 'shell_session',
  resource_id: 'sh_abc123',
  change: 'status_changed',
  status: 'killed',
};

test('AC3: shell_session_exited invalidates every tag the shell views read', () => {
  const { dispatch, tags } = record();
  handleUserWsEvent(dispatch, EXITED_FRAME);

  // The three consumers, each with no poller left to cover a miss:
  //   ShellSession:<id>  the detail view, the run indicator, the log viewer
  //   ShellSessions:LIST the owner-wide list and the chain-scoped lists
  assert.ok(tags.includes('ShellSession:sh_abc123'),
    `the exited session's own tag must be invalidated; got ${JSON.stringify(tags)}`);
  assert.ok(tags.includes('ShellSessions:LIST'),
    `the session LIST tag must be invalidated; got ${JSON.stringify(tags)}`);
});

test('AC3: the convergence resource_changed frame also invalidates', () => {
  // This is the frame that used to fall through handleResourceChanged's `default: return`.
  // It carries hub-side CORRECTIONS of stale rows (iss_18d9822647aee3b2's dead servers
  // still reporting `running`), so dropping it left the UI showing sessions that do not
  // exist with nothing to fix it.
  const { dispatch, tags } = record();
  handleUserWsEvent(dispatch, CONVERGENCE_FRAME);

  assert.ok(tags.includes('ShellSession:sh_abc123'),
    `convergence must invalidate the session tag; got ${JSON.stringify(tags)}`);
  assert.ok(tags.includes('ShellSessions:LIST'),
    `convergence must invalidate the LIST tag; got ${JSON.stringify(tags)}`);
});

test('AC3: the non-RTK consumers are ticked too, so the list page is push-driven', () => {
  // ShellListPage pages through useInfiniteList with its own fetch promise, so NO tag
  // can reach it. Without this tick its only remaining refresh would be window focus,
  // which is not push — see shellSlice.ts.
  const { dispatch, actions } = record();
  handleUserWsEvent(dispatch, EXITED_FRAME);
  assert.ok(actions.some((a) => a?.type === 'shells/shellSessionEventReceived'),
    `the push tick must be dispatched; got ${JSON.stringify(actions.map((a) => a?.type))}`);
});

test('AC3 NEGATIVE: an unrelated resource_changed does not invalidate shell tags', () => {
  const { dispatch, tags } = record();
  handleUserWsEvent(dispatch, {
    type: 'resource_changed', resource: 'project', resource_id: 'proj_1', change: 'updated',
  });
  assert.ok(!tags.some((t) => t.startsWith('ShellSession')),
    `a project change must not invalidate shell caches; got ${JSON.stringify(tags)}`);
});

test('AC3: a frame with no session_id still refreshes the lists and never throws', () => {
  const { dispatch, tags } = record();
  handleUserWsEvent(dispatch, { type: 'shell_session_exited', status: 'failed' });
  assert.ok(tags.includes('ShellSessions:LIST'), 'the lists must still be refreshed');
  assert.ok(!tags.some((t) => t === 'ShellSession:'),
    'an empty session id must not produce a bogus per-session tag');
});

console.log('REQ-SHELL-6 AC3 push path: real handler, real hub frame shapes.');
