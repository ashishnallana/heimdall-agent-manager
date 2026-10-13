// REQ-SHELL-6 predicate truth tables, run as REAL CODE imported from the shipping
// modules (shellModel.ts + the API endpoint module), not as regexes over source.
//
// Covers the acceptance criteria that are decisions rather than layout:
//   AC1   no user path starts a run — the picker AND the verb menu
//   AC2b  the chain panel's active-server set, including the SCOPING NEGATIVES
//   AC4   the background toggle's offer/withdraw rule
//   AC6   the three output states, keyed on the hub's error CODE
//   §2    the pin / unpin sequencing for run indicators
//   §5    the live-preview indicator
//   §8    the bridge-offline session state and the honest kill wording
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  activeServersOf,
  killAffordance,
  pinnedRunSessions,
  statusPresentation,
  supportsLivePreview,
  verbsForSession,
} from './model.mjs';
import { shellLogFailure } from './states.mjs';

const LIVE = ['starting', 'running'];
const TERMINAL = ['exited', 'killed', 'failed'];
const ALL = [...LIVE, ...TERMINAL];

// A session with sane defaults; every test overrides only what it is about.
const S = (over = {}) => ({
  session_id: 'sh_1',
  bridge_id: 'brg_1',
  project_id: '',
  chain_id: '',
  agent_instance_id: '',
  kind: 'server',
  status: 'running',
  label: '',
  cmd: 'npm run dev',
  cwd: '/tmp',
  pid: 10,
  exit_code: null,
  exit_code_set: false,
  server_port: 0,
  preview_enabled: false,
  finished_at: '',
  started_at: '',
  last_activity_at: '',
  background: false,
  conversation_id: '',
  status_unknown: false,
  bridge_online: true,
  ...over,
});

/* ---------------- §5 live-preview indicator ---------------- */

test('§5: only a server WITH a port advertises live preview', () => {
  for (const status of ALL) {
    assert.equal(supportsLivePreview(S({ kind: 'server', status, server_port: 5173 })), true,
      `server with a port must advertise preview (status=${status})`);
    // A portless server is explicitly VALID in the redesign and must show NO indicator:
    // a preview affordance with nothing to serve is a dead control.
    assert.equal(supportsLivePreview(S({ kind: 'server', status, server_port: 0 })), false,
      `portless server must NOT advertise preview (status=${status})`);
  }
});

test('§5 NEGATIVE: run and shell never advertise live preview, port or not', () => {
  for (const kind of ['run', 'shell']) {
    for (const server_port of [0, 5173]) {
      assert.equal(supportsLivePreview(S({ kind, server_port })), false,
        `${kind} must never advertise preview (port=${server_port})`);
    }
  }
});

/* ---------------- AC1 no user path starts a run ---------------- */

// #26's blocking finding on this task: RESTART is a second path by which a USER starts a
// run. Gating the NewShellDialog picker closes the obvious path and leaves this one open —
// the owner-wide /shells listing attaches no kind clause, so run rows reach the list, and
// ShellRow renders whatever verbsForSession returns.
//
// The table below is EXHAUSTIVE over kind x state on purpose. Asserting only the run rows
// would prove the hole is closed but would not notice an over-broad gate that removed
// restart from shell and server too — a real regression, and one a run-only assertion
// cannot see. Both directions are the claim.
const KINDS = ['run', 'shell', 'server'];

test('AC1: restart is offered for shell and server in EVERY state, and NEVER for a run', () => {
  for (const kind of KINDS) {
    for (const status of ALL) {
      const verbs = verbsForSession(S({ kind, status }));
      assert.equal(verbs.includes('restart'), kind !== 'run',
        `kind=${kind} status=${status}: restart must be ${kind === 'run' ? 'withheld' : 'offered'}`);
    }
  }
});

test('AC1: no verb a run offers is start-shaped, in any state', () => {
  // The rule is not "no restart", it is "nothing that starts a process". Naming the banned
  // set explicitly means a NEW start-shaped verb added later is caught by this test rather
  // than slipping through a gate written only against today's vocabulary.
  const STARTS_A_PROCESS = ['restart', 'start', 'rerun', 'run'];
  for (const status of ALL) {
    for (const verb of verbsForSession(S({ kind: 'run', status }))) {
      assert.ok(!STARTS_A_PROCESS.includes(verb),
        `a run (status=${status}) must offer no start-shaped verb, but offers '${verb}'`);
    }
  }
});

test('AC1: a LIVE run still offers kill — stopping a run is not starting one', () => {
  for (const status of LIVE) {
    assert.ok(verbsForSession(S({ kind: 'run', status })).includes('kill'),
      `a ${status} run must still be stoppable — §8 depends on it`);
  }
});

test('AC1: a TERMINAL run offers no verbs at all, and that empty list is intended', () => {
  // Restart was the only verb a dead session could still honour, so withholding it from a
  // run leaves genuinely nothing: kill 409s, a signal reaches no pid, there is nothing to
  // preview. [] is a NEW state no kind produced before, and it is the correct answer — the
  // renderers gate their menu behind verbs.length (ShellRow.tsx, ShellDetail.tsx), so this
  // renders no menu rather than an empty one. Inventing a placeholder verb to avoid the
  // empty case would re-open AC1.
  for (const status of TERMINAL) {
    assert.deepEqual(verbsForSession(S({ kind: 'run', status })), [],
      `a ${status} run has nothing left to offer`);
  }
});

test('AC1 NEGATIVE: a terminal shell/server still offers exactly restart', () => {
  // The counterpart of the row above: proof the empty list is specific to `run` and not a
  // gate that quietly emptied every terminal menu.
  for (const kind of ['shell', 'server']) {
    for (const status of TERMINAL) {
      assert.deepEqual(verbsForSession(S({ kind, status })), ['restart'],
        `a ${status} ${kind} must still be restartable`);
    }
  }
});

/* ---------------- AC2b the active-servers set ---------------- */

test('AC2b: only non-terminal sessions survive; terminal servers drop off the panel', () => {
  const rows = ALL.map((status, i) => S({ session_id: `sh_${i}`, status }));
  const kept = activeServersOf(rows).map((r) => r.status);
  assert.deepEqual(kept, LIVE, 'exactly the live statuses may remain');
});

test('AC2b NEGATIVE: a status_unknown server is ACTIVE, not dropped', () => {
  // The bridge being gone is not evidence the server stopped. Dropping it would assert
  // something we do not know, which §8 forbids.
  const rows = [S({ status: 'running', status_unknown: true, bridge_online: false })];
  assert.equal(activeServersOf(rows).length, 1);
});

test('AC2b NEGATIVE: the panel set is empty when every server is terminal', () => {
  const rows = TERMINAL.map((status, i) => S({ session_id: `sh_${i}`, status }));
  assert.deepEqual(activeServersOf(rows), [], 'a chain whose servers all finished shows none');
});

test('AC2b NEGATIVE: a chain-attached live shell is not listed as a server', () => {
  // A shell may carry chain_id, so a chain-narrowed page can include it; the servers
  // panel must still show servers only.
  const rows = [
    S({ session_id: 'sh_srv', kind: 'server', status: 'running' }),
    S({ session_id: 'sh_sh', kind: 'shell', status: 'running', chain_id: 'chain_1' }),
  ];
  assert.deepEqual(activeServersOf(rows).map((r) => r.session_id), ['sh_srv']);
});

/* ---------------- §2 pin / unpin sequencing ---------------- */

const marker = (sessionId, createdUnixMs) => ({ messageId: `msg_${sessionId}`, sessionId, createdUnixMs });

test('§2: a LIVE run is pinned regardless of later messages', () => {
  const run = S({ session_id: 'sh_live', kind: 'run', status: 'running' });
  const pinned = pinnedRunSessions([run], [marker('sh_live', 1000)], 9999);
  assert.deepEqual(pinned.map((r) => r.session_id), ['sh_live'],
    'a running job stays pinned even though newer messages exist');
});

test('§2: a finished run stays pinned until a message arrives AFTER it finished', () => {
  const run = S({ session_id: 'sh_done', kind: 'run', status: 'exited', finished_at: '2026-09-28T12:00:10Z' });
  const finishedMs = Date.parse('2026-09-28T12:00:10Z');
  const m = [marker('sh_done', Date.parse('2026-09-28T12:00:00Z'))];

  // Nobody has spoken since it finished -> still on screen to be read.
  assert.equal(pinnedRunSessions([run], m, finishedMs - 1).length, 1,
    'a run that finished while nobody was talking must remain visible');
  // A message arrived after it finished -> unpins.
  assert.equal(pinnedRunSessions([run], m, finishedMs + 1).length, 0,
    'the next user/agent message after it finished unpins it');
});

test('§2: a message that arrived WHILE the run was still going does not unpin it', () => {
  // This is the case a naive "compare against the marker timestamp" gets wrong, and it
  // is exactly what the user's "if its not running anymore" clause guards.
  const started = Date.parse('2026-09-28T12:00:00Z');
  const spokeDuring = Date.parse('2026-09-28T12:00:05Z');
  const finished = '2026-09-28T12:00:10Z';
  const run = S({ session_id: 'sh_mid', kind: 'run', status: 'exited', finished_at: finished });
  assert.equal(pinnedRunSessions([run], [marker('sh_mid', started)], spokeDuring).length, 1,
    'a message sent mid-run must not unpin the run when it later finishes');
});

test('§2 NEGATIVE: a run with no marker in this conversation is never pinned', () => {
  // CONVERSATION SCOPE: a run appears ONLY in the conversation that triggered it.
  const run = S({ session_id: 'sh_elsewhere', kind: 'run', status: 'running' });
  assert.deepEqual(pinnedRunSessions([run], [], 0), [],
    'a run whose marker belongs to another thread must not be pinned here');
});

test('§2: a terminal run with no finished_at falls back to its marker time', () => {
  const run = S({ session_id: 'sh_nofin', kind: 'run', status: 'failed', finished_at: '' });
  assert.equal(pinnedRunSessions([run], [marker('sh_nofin', 500)], 400).length, 1);
  assert.equal(pinnedRunSessions([run], [marker('sh_nofin', 500)], 600).length, 0);
});

/* ---------------- §8 bridge-offline state ---------------- */

test('§8: status_unknown renders as its own state, never as running/failed/killed', () => {
  const p = statusPresentation(S({ status: 'running', status_unknown: true, bridge_online: false }));
  assert.equal(p.unknown, true);
  assert.equal(p.label, 'Status unknown');
  // Must not assert it lives...
  assert.ok(!/^Running$/i.test(p.label), 'must not claim Running');
  // ...and must not assert it died.
  assert.equal(p.tone === 'danger', false, 'danger tone would read as a failure we cannot claim');
  assert.match(p.title, /bridge/i, 'the reason must say WHY the status is unknown');
  assert.match(p.title, /running/i, 'and must still report the last known status');
});

test('§8: an ordinary session reports its status verbatim', () => {
  for (const status of ALL) {
    const p = statusPresentation(S({ status }));
    assert.equal(p.unknown, false);
    assert.equal(p.label.toLowerCase(), status);
  }
});

test('§8: a kill against an offline bridge is DURABLE, and says so without promising immediacy', () => {
  const k = killAffordance(S({ status: 'running', bridge_online: false, status_unknown: true }));
  assert.equal(k.offered, true,
    'the control must stay available — the request really is accepted');
  assert.ok(k.queuedNote, 'it must tell the user what actually happened');

  // THIS ASSERTION WAS INVERTED BY REQ-SHELL-23 (its AC6), and the inversion is the point.
  // It previously BANNED the promise words, because delivery was broken: a kill accepted
  // while the bridge was offline was still pending after reconnect, twice, on a live
  // stack. The ban existed to make the re-tightening visible rather than forgotten, and
  // this is that re-tightening. Delivery is now verified across two disconnect/reconnect
  // cycles — process gone, row terminal, intent cleared, exit frame on the user bus — so
  // §8 is restored at full strength and the copy must commit to the OUTCOME.
  const text = `${k.label} ${k.title} ${k.queuedNote}`.toLowerCase();
  assert.match(text, /queued/, 'it must say the kill is queued');
  assert.match(text, /will be carried out|will be delivered|will be applied/,
    'it must commit to the kill actually happening — §8 at full strength');

  // THE OTHER WAY TO LIE, and the one this wording could now drift into. Delivery happens
  // ON RECONNECT and the bridge may be gone a long time, so the copy must locate the kill
  // in the future and tie it to the bridge returning. Over-promising immediacy is as
  // dishonest as the under-promising this replaced.
  assert.match(text, /reconnect/, 'it must tie delivery to the bridge coming back');
  for (const immediate of ['killed now', 'terminated', 'immediately', 'has been killed']) {
    assert.ok(!text.includes(immediate),
      `the offline kill wording must not imply "${immediate}" — delivery waits for reconnect`);
  }
  assert.ok(!text.includes('cannot be carried out'),
    'the softened pre-REQ-SHELL-23 denial must not survive — delivery works now');
});

test('§8: a kill on a live session with an online bridge is plain', () => {
  const k = killAffordance(S({ status: 'running', bridge_online: true }));
  assert.equal(k.offered, true);
  assert.equal(k.queuedNote, undefined, 'nothing is queued when the bridge is connected');
});

test('§8 NEGATIVE: a terminal session offers no kill at all', () => {
  for (const status of TERMINAL) {
    const k = killAffordance(S({ status }));
    assert.equal(k.offered, false, `${status} has no process left to kill`);
  }
});

/* ---------------- AC6 the three output states ---------------- */

test('AC6: the three output states are told apart by CODE, not by emptiness', () => {
  // 1. bridge offline — transient.
  assert.equal(shellLogFailure({ data: { reason: 'bridge_offline', message: 'x' } }).reason, 'bridge_offline');
  // 2. reclaimed — permanent.
  assert.equal(shellLogFailure({ data: { reason: 'gone', message: 'x' } }).reason, 'gone');
  // 3. genuinely empty is a SUCCESS, so there is no failure object at all. This is the
  //    assertion that stops "printed nothing" being rendered as an error.
  assert.equal(shellLogFailure(undefined), undefined);
  assert.equal(shellLogFailure({}), undefined);
  assert.equal(shellLogFailure({ data: { message: 'no reason field' } }), undefined);
});

console.log('REQ-SHELL-6 predicate truth tables: all cases asserted.');
