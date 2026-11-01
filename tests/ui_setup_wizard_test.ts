// First-run setup wizard (/setup, desktop app): the pure model
// (components/setup/setupWizardModel.ts) and past-session project discovery
// (components/setup/sessionProjects.ts).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_setup_wizard_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

const model = await import('../src/ui/components/setup/setupWizardModel.ts');
const sessions = await import('../src/ui/components/setup/sessionProjects.ts');
const { initialWizard, reduceWizard, startWizard } = await import('../src/ui/bridge/desktopBridge.ts');
const { cancelSetupEnrollment } = await import('../src/ui/components/setup/setupEnrollment.ts');

test('wizard recovery cancels the Hub attempt before stopping local setup', async () => {
  const realFetch = globalThis.fetch;
  const events: string[] = [];
  const wait = new AbortController();
  wait.signal.addEventListener('abort', () => events.push('abort-wait'));
  globalThis.fetch = (async (url: any, init: any) => {
    assert.equal(String(url), '/api/v1/bridges/brg_old/enrollment/cancel');
    assert.equal(init.method, 'POST');
    events.push('cancel-hub');
    return Response.json({ data: { rolled_back: true } });
  }) as any;
  try {
    assert.equal(await cancelSetupEnrollment({ bridgeId: 'brg_old', wait,
      cancelLocal: async () => { events.push('stop-local'); return { ok: true }; } }), true);
    assert.deepEqual(events, ['cancel-hub', 'abort-wait', 'stop-local']);
  } finally { globalThis.fetch = realFetch; }
});

test('wizard recovery preserves a committed enrollment and does not guess on Hub failure', async () => {
  const realFetch = globalThis.fetch;
  const wait = new AbortController();
  const cancelLocal = async () => { assert.fail('must not stop a committed or unknown enrollment'); return { ok: true }; };
  try {
    globalThis.fetch = (async () => Response.json({ data: { rolled_back: false } })) as any;
    assert.equal(await cancelSetupEnrollment({ bridgeId: 'brg_old', wait, cancelLocal }), false);
    assert.equal(wait.signal.aborted, false);
    globalThis.fetch = (async () => Response.json({ error: { message: 'Hub unavailable' } }, { status: 503 })) as any;
    await assert.rejects(cancelSetupEnrollment({ bridgeId: 'brg_old', wait, cancelLocal }), /Hub unavailable/);
    assert.equal(wait.signal.aborted, false);
  } finally { globalThis.fetch = realFetch; }
});

test('an expired unapproved pairing code does not block retrying local setup', async () => {
  const realFetch = globalThis.fetch;
  let stopped = false;
  globalThis.fetch = (async () => Response.json({ error: { message: 'expired code' } }, { status: 404 })) as any;
  try {
    assert.equal(await cancelSetupEnrollment({ bridgeId: '', pairLookup: 'expired', wait: null,
      cancelLocal: async () => { stopped = true; return { ok: true }; } }), true);
    assert.equal(stopped, true);
  } finally { globalThis.fetch = realFetch; }
});

const reusable = [
  { bridge_id: 'brg_riverwood', label: 'riverwood', machine_hostname: 'mac.local', status: 'online', last_seen: '' },
  { bridge_id: 'brg_dawnstar', label: 'dawnstar', machine_hostname: 'dawnstar', status: 'online', last_seen: '' },
];
const bridges = [
  { bridge_id: 'brg_riverwood', label: 'riverwood', machine_hostname: 'mac.local', status: 'online' },
  { bridge_id: 'brg_dawnstar', label: 'dawnstar', machine_hostname: 'dawnstar', status: 'offline' },
  { bridge_id: 'brg_old', label: 'old', status: 'revoked', revoked_at: '2026-01-01T00:00:00Z' },
];

test('rail: connected machines show install and identity as done', () => {
  const fresh = model.setupRail('install', false);
  assert.deepEqual(fresh.map((r) => r.state), ['done', 'current', 'todo', 'todo', 'todo']);
  const connected = model.setupRail('agents', true);
  assert.deepEqual(connected.map((r) => r.state), ['done', 'done', 'done', 'current', 'todo']);
  assert.equal(connected[1].hint, 'Already done');
  assert.equal(model.setupRail('machine', true)[1].state, 'done');
});

test('install rows fold ham-bridge steps into Download, Install, Pair', () => {
  let w = startWizard();
  w = reduceWizard(w, { type: 'progress', step: 'download', state: 'ok', message: 'downloaded' });
  w = reduceWizard(w, { type: 'progress', step: 'ports', state: 'start', message: 'bridge 49325' });
  let rows = model.installRows(w);
  assert.deepEqual(rows.map((r) => [r.id, r.state]), [['download', 'ok'], ['install', 'running'], ['pair', 'pending']]);
  w = reduceWizard(w, { type: 'progress', step: 'service', state: 'ok' });
  w = reduceWizard(w, { type: 'progress', step: 'enroll', state: 'start' });
  w = reduceWizard(w, { type: 'pairing', url: 'https://hub/device/add', code: 'ABCD-EFGH-JKLM-NP' });
  rows = model.installRows(w);
  assert.equal(rows[1].state, 'ok');
  assert.equal(rows[2].state, 'running');
  assert.match(rows[2].message, /bridge identity/);
  assert.equal(model.installRows(initialWizard())[0].state, 'pending');
  assert.equal(model.installRowStatus('failed'), 'Failed');
});

test('sunset candidates exclude revoked bridges', () => {
  assert.deepEqual(model.sunsetCandidates(bridges).map((b) => b.bridge_id), ['brg_riverwood', 'brg_dawnstar']);
  assert.deepEqual(model.sunsetCandidates([{ bridge_id: 'not-a-bridge' }]), []);
});

test('identity plan: reuse needs a listed bridge', () => {
  const candidates = model.sunsetCandidates(bridges);
  const none = model.identityPlan(model.EMPTY_IDENTITY_CHOICE, reusable, candidates, true);
  assert.equal(none.ok, false);
  const reuse = model.identityPlan({ mode: 'reuse', reuseId: 'brg_riverwood', sunsetId: '' }, reusable, candidates, true);
  assert.equal(reuse.ok, true);
  assert.equal(reuse.reuse?.bridge_id, 'brg_riverwood');
  assert.equal(reuse.sunset, null);
  assert.equal(reuse.action, 'Use riverwood and finish');
  const unlisted = model.identityPlan({ mode: 'reuse', reuseId: 'brg_other', sunsetId: '' }, reusable, candidates, true);
  assert.equal(unlisted.ok, false);
});

test('identity plan: a new bridge at capacity needs a bridge to sunset', () => {
  const candidates = model.sunsetCandidates(bridges);
  const roomy = model.identityPlan({ mode: 'new', reuseId: '', sunsetId: '' }, reusable, candidates, false);
  assert.equal(roomy.ok, true);
  assert.equal(roomy.sunset, null);
  const full = model.identityPlan({ mode: 'new', reuseId: '', sunsetId: '' }, reusable, candidates, true);
  assert.equal(full.ok, false);
  assert.equal(full.action, 'Choose a bridge to sunset');
  const sunset = model.identityPlan({ mode: 'new', reuseId: '', sunsetId: 'brg_dawnstar' }, reusable, candidates, true);
  assert.equal(sunset.ok, true);
  assert.equal(sunset.reuse, null);
  assert.equal(sunset.sunset?.bridge_id, 'brg_dawnstar');
  assert.equal(sunset.action, 'Register and sunset dawnstar');
  const revoked = model.identityPlan({ mode: 'new', reuseId: '', sunsetId: 'brg_old' }, reusable, candidates, true);
  assert.equal(revoked.ok, false);
});

test('update badge needs an installable artifact', () => {
  assert.equal(model.bridgeHasUpdate({ update_available: true }), true);
  assert.equal(model.bridgeHasUpdate({ update_available: true, update_artifact_available: false }), false);
  assert.equal(model.bridgeHasUpdate(null), false);
});

test('setup is remembered per account', () => {
  const store = new Map<string, string>();
  const storage = { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); } };
  assert.equal(model.setupSeen('usr_a', storage), false);
  model.markSetupSeen('usr_a', storage);
  assert.equal(model.setupSeen('usr_a', storage), true);
  assert.equal(model.setupSeen('usr_b', storage), false);
  assert.equal(model.setupSeen('', storage), true, 'no account: never redirect');
});

// --- past-session projects -------------------------------------------------

function fakeFs(dirs: string[], listings: Record<string, { name: string; is_dir: boolean }[]> = {}) {
  const set = new Set(dirs);
  let stats = 0;
  return {
    get stats() { return stats; },
    stat: async (path: string) => { stats += 1; return { ok: true, exists: set.has(path), is_dir: set.has(path) }; },
    list: async (path: string) => (listings[path] ? { ok: true, path: path.replace('~', '/home/me'), entries: listings[path] } : null),
  };
}

test('parse Claude project folder names', () => {
  assert.deepEqual(sessions.parseClaudeProjectDir('-home-me-app'), { root: '/', sep: '/', tokens: ['home', 'me', 'app'] });
  assert.deepEqual(sessions.parseClaudeProjectDir('C--Users-me-app'), { root: 'C:\\', sep: '\\', tokens: ['Users', 'me', 'app'] });
  assert.equal(sessions.parseClaudeProjectDir('memory'), null);
});

test('resolve an ambiguous name against folders that exist', async () => {
  const fs = fakeFs(['/home', '/home/me', '/home/me/code', '/home/me/code/heimdall-agent-manager', '/home/me/code/heimdall']);
  assert.equal(await sessions.resolveClaudeProjectDir('-home-me-code-heimdall-agent-manager', fs.stat), '/home/me/code/heimdall-agent-manager');
  const dotted = fakeFs(['/home', '/home/me', '/home/me/.config', '/home/me/.config/nvim', '/home/me/site.io']);
  assert.equal(await sessions.resolveClaudeProjectDir('-home-me--config-nvim', dotted.stat), '/home/me/.config/nvim');
  assert.equal(await sessions.resolveClaudeProjectDir('-home-me-site-io', dotted.stat), '/home/me/site.io');
  const win = fakeFs(['C:\\Users', 'C:\\Users\\me', 'C:\\Users\\me\\my_app']);
  assert.equal(await sessions.resolveClaudeProjectDir('C--Users-me-my-app', win.stat), 'C:\\Users\\me\\my_app');
  assert.equal(await sessions.resolveClaudeProjectDir('-home-me-gone', fs.stat), '');
});

test('resolution gives up after a bounded number of stats', async () => {
  const fs = fakeFs([]);
  const name = '-' + Array.from({ length: 30 }, (_, i) => `p${i}`).join('-');
  assert.equal(await sessions.resolveClaudeProjectDir(name, fs.stat), '');
  assert.ok(fs.stats <= 48, `stats: ${fs.stats}`);
});

test('discover projects with sessions, skip ones already in Ninjy', async () => {
  const root = '/home/me/.claude/projects';
  const fs = fakeFs(['/home', '/home/me', '/home/me/app', '/home/me/blog', '/home/me/empty'], {
    '~/.claude/projects': [
      { name: '-home-me-app', is_dir: true },
      { name: '-home-me-blog', is_dir: true },
      { name: '-home-me-empty', is_dir: true },
      { name: '-home-me-gone', is_dir: true },
      { name: 'notes.txt', is_dir: false },
    ],
    [`${root}/-home-me-app`]: [{ name: 'a.jsonl', is_dir: false }, { name: 'b.jsonl', is_dir: false }],
    [`${root}/-home-me-blog`]: [{ name: 'c.jsonl', is_dir: false }],
    [`${root}/-home-me-empty`]: [],
    [`${root}/-home-me-gone`]: [{ name: 'd.jsonl', is_dir: false }],
  });
  const found = await sessions.discoverClaudeProjects(fs);
  assert.deepEqual(found.map((p) => [p.name, p.path, p.sessions]), [['app', '/home/me/app', 2], ['blog', '/home/me/blog', 1]]);
  const fresh = sessions.newProjectsOnly(found, [{ bridge_paths: [{ bridge_id: 'brg_1', path: '/home/me/app/' }] }], 'brg_1');
  assert.deepEqual(fresh.map((p) => p.name), ['blog']);
  assert.equal(sessions.newProjectsOnly(found, [{ bridge_paths: [{ bridge_id: 'brg_2', path: '/home/me/app' }] }], 'brg_1').length, 2);
  assert.deepEqual(await sessions.discoverClaudeProjects(fakeFs([])), []);
});

test('identity step: a sunset rides on the approval, never a revoke up front (REQ-3)', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(new URL('../src/ui/components/setup/SetupWizardPage.tsx', import.meta.url), 'utf8');
  // No UI-side revoke: the hub retires the bridge atomically with the approval.
  assert.doesNotMatch(source, /useRevokeBridgeMutation|revokeBridge\(/);
  assert.match(source, /await approveBridgeEnrollment\(\{[\s\S]*?target: plan\.reuse,[\s\S]*?sunset: sunset \? \{ bridge_id: sunset\.bridge_id, label: sunset\.label \} : null,/);
  // The failure copy is decided from the bridge list refetched after the failure,
  // never from how far the client got (a POST can commit and still throw).
  assert.doesNotMatch(source, /Nothing was changed/);
  assert.doesNotMatch(source, /approvedId/);
  assert.match(source, /const refreshed = await refetchBridges\(\)\.unwrap\(\)[\s\S]*?prefix = sunsetFailureNote\(sunset, refreshed\);/);
  // The warning matches the hub: restored on any rollback of the pending enrollment,
  // final only once this machine is enrolled.
  assert.match(source, /data-debug-id="setup-identity-sunset-warning"/);
  assert.match(source, /It is paused in the same step that approves this machine, never before\. If the approval is refused or this machine does not finish enrolling, its credentials are restored unless its plan slot is used meanwhile\. It reconnects on its next retry after restoration; an unfinished enrollment expires after 5 minutes\. Once this machine is enrolled, retirement is permanent/);
  assert.doesNotMatch(source, /if the approval is refused or fails, it keeps working/);
});

test('sunset failure note reads the refetched bridge list (REQ-3)', () => {
  const sunset = { bridge_id: 'brg_dawnstar', label: 'dawnstar' };
  // Approval refused, or rolled back and restored by the hub: still listed as active.
  assert.equal(model.sunsetFailureNote(sunset, bridges), 'dawnstar is still active. ');
  // The POST threw on the client but committed on the hub (lost response, proxy 5xx
  // after commit, or no bridge id in the answer): the list shows it revoked, so the
  // note must NOT claim nothing changed.
  const committed = bridges.map((b) => (b.bridge_id === 'brg_dawnstar' ? { ...b, status: 'revoked', revoked_at: '2026-10-31T12:00:00Z' } : b));
  const pending = model.sunsetFailureNote(sunset, committed);
  assert.match(pending, /^dawnstar is retired while this approval is pending\./);
  assert.match(pending, /comes back on its next retry after the enrollment is cancelled or expires/);
  assert.match(pending, /Pending enrollments expire after 5 minutes/);
  assert.doesNotMatch(pending, /within 5 minutes|still active|Nothing was changed/);
  // Gone from the list entirely reads the same as revoked.
  assert.match(model.sunsetFailureNote(sunset, bridges.filter((b) => b.bridge_id !== 'brg_dawnstar')), /^dawnstar is retired/);
  // The refetch itself failed: the outcome is unknown, and the note says so.
  const unknown = model.sunsetFailureNote(sunset, null);
  assert.match(unknown, /^Could not check whether dawnstar is still active; see Bridges\./);
  assert.doesNotMatch(unknown, /is still active\. $/);
});


test('profile choices distinguish no profiles from occupied slots and keep accounts separate', () => {
  assert.deepEqual(model.setupProfileChoices([]), ['']);
  const profiles: any[] = [{ profile: '', enrolled: true }, { profile: 'p1', enrolled: true }];
  assert.deepEqual(model.setupProfileChoices(profiles), ['account-2']);
  assert.deepEqual(model.setupProfileChoices([...profiles, { profile: 'personal', enrolled: false }]), ['personal']);
  assert.deepEqual(model.setupProfileChoices([{ profile: 'p1', enrolled: true }] as any), ['']);
});

test('profile names and discovery keep the unnamed default and reject invalid input', async () => {
  const { bridgeProfileError, bridgeProfileLabel, installedHubProfiles } = await import('../src/ui/bridge/desktopBridge.ts');
  assert.equal(bridgeProfileLabel(''), 'Default (unnamed)');
  assert.equal(bridgeProfileLabel('p1'), 'p1');
  for (const name of ['', 'personal', 'a', 'a'.repeat(31)]) assert.equal(bridgeProfileError(name), '');
  for (const name of ['Work', '-work', 'two words', '../p1', 'a'.repeat(32)]) assert.ok(bridgeProfileError(name));
  const profiles: any[] = [{ installed: true, hub: 'https://hub.example', profile: 'p1' },
    { installed: false, hub: 'https://hub.example', profile: 'gone' },
    { installed: true, hub: 'https://other.example', profile: 'other' }];
  assert.deepEqual(installedHubProfiles(profiles, 'https://hub.example/').map((p) => p.profile), ['p1']);
});
