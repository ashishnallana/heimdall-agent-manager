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

test('project list records load detail mappings before filtering on the selected bridge', async () => {
  // GET /projects uses write_project_json: no bridge_paths on list records.
  const list = { projects: [
    { project_id: 'proj_here', name: 'app', default_path: '/home/me/app' },
    { project_id: 'proj_elsewhere', name: 'other', default_path: '/home/me/other' },
  ] };
  const requests: string[] = [];
  const mappings = await sessions.loadProjectBridgeMappings(list.projects, async (id) => {
    requests.push(id);
    // GET /projects/{id} returns project plus top-level bridge_paths.
    return { project: list.projects.find((p) => p.project_id === id), bridge_paths: [
      { bridge_id: id === 'proj_here' ? 'brg_here' : 'brg_other', path: id === 'proj_here' ? '/home/me/app/' : '/home/me/other' },
    ] };
  });
  const found = ['app', 'other'].map((name) => ({ name, path: '/home/me/' + name, sessions: 1, source: 'Codex' as const }));
  assert.deepEqual(requests.sort(), ['proj_elsewhere', 'proj_here']);
  assert.deepEqual(sessions.newProjectsOnly(found, mappings, 'brg_here').map((p) => p.name), ['other']);
  assert.deepEqual(await sessions.loadProjectBridgeMappings([], async () => { throw new Error('unexpected request'); }), []);
});

test('mapping lookup failure prevents unsafe import candidates', async () => {
  const list = [{ project_id: 'proj_1' }];
  await assert.rejects(sessions.loadProjectBridgeMappings(list, async () => { throw new Error('offline'); }), /offline/);
  await assert.rejects(sessions.loadProjectBridgeMappings(list, async () => ({ project: list[0] })), /Could not check/);
  assert.deepEqual(await sessions.loadProjectBridgeMappings(list, async () => ({ project: { ...list[0], bridge_paths: [] } })), [{ bridge_paths: [] }]);
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
  const source = readFileSync(new URL('../src/ui/components/bridge/LocalBridgeFlow.tsx', import.meta.url), 'utf8');
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

test('session metadata: resolve Claude, merge Codex cwd, sort by newest session', async () => {
  const fs = fakeFs(['/home', '/home/me', '/home/me/app', '/home/me/blog']);
  const found = await sessions.discoverSessionProjects({ ok: true, projects: [
    { source: 'Claude Code', path: '-home-me-app', sessions: 2, last_session_at: '2026-10-28T10:00:00Z' },
    { source: 'Codex', path: '/home/me/app', sessions: 3, last_session_at: '2026-10-31T10:00:00Z' },
    { source: 'Codex', path: '/home/me/blog', sessions: 10, last_session_at: '2026-10-30T10:00:00Z' },
    { source: 'Codex', path: '/home/me/gone', sessions: 2, last_session_at: '2026-10-31T11:00:00Z' },
    { source: 'Claude Code', path: 'invalid', sessions: 1, last_session_at: 'bad' },
  ] }, fs);
  assert.deepEqual(found.map((p) => [p.path, p.sessions, p.source, p.lastSessionAt]), [
    ['/home/me/app', 5, 'Claude Code + Codex', '2026-10-31T10:00:00Z'],
    ['/home/me/blog', 10, 'Codex', '2026-10-30T10:00:00Z'],
  ]);
});

test('session metadata: empty, failed, malformed and inaccessible history', async () => {
  const fs = fakeFs(['/home', '/home/me', '/home/me/app']);
  assert.deepEqual(await sessions.discoverSessionProjects({ ok: true, projects: [] }, fs), []);
  await assert.rejects(sessions.discoverSessionProjects({ ok: false, projects: [] }, fs), /Could not read/);
  const rows = await sessions.discoverSessionProjects({ ok: true, projects: [
    { source: 'Codex', path: '/home/me/app', sessions: 1, last_session_at: 'invalid' },
    null as any,
    { source: 'Other' as any, path: '/home/me/app', sessions: 4, last_session_at: '' },
  ] }, fs);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].lastSessionAt, undefined);
  assert.equal(sessions.sessionTimeLabel(rows[0].lastSessionAt), 'Last session unknown');
  assert.match(sessions.sessionTimeLabel('2026-10-31T10:00:00Z'), /^Last session .+2026/);
  assert.deepEqual(await sessions.discoverSessionProjects({ ok: true, projects: [
    { source: 'Codex', path: '/home/me/app', sessions: 1, last_session_at: '' },
  ] }, { ...fs, stat: async () => { throw new Error('unreadable'); } }), []);
});

test('import names reserve existing names and same-basename folders', () => {
  const taken = new Set(['app', 'app (2)', 'blog']);
  assert.equal(sessions.reserveProjectName('app', taken), 'app (3)');
  assert.equal(sessions.reserveProjectName('app', taken), 'app (4)');
  assert.equal(sessions.reserveProjectName('Blog', taken), 'Blog (2)');
});

test('project deduplication is scoped to bridge paths', () => {
  const found = [{ name: 'app', path: '/home/me/app', sessions: 1, source: 'Codex' as const }];
  assert.equal(sessions.newProjectsOnly(found, [{ default_path: '/home/me/app', bridge_paths: [{ bridge_id: 'brg_other', path: '/home/me/app' }] }], 'brg_here').length, 1);
});

test('import retries only attach failed rows and preserve unique names and default paths', async () => {
  const chosen = [
    { name: 'app', path: '/home/me/app', sessions: 1, source: 'Codex' as const },
    { name: 'app', path: '/work/app', sessions: 2, source: 'Codex' as const },
  ];
  const created: import('../src/ui/components/setup/sessionProjects.ts').ImportedSessionProjects = {};
  const creations: [string, string][] = [];
  const attachments: [string, string][] = [];
  let fail = true;
  const api = {
    create: async (name: string, path: string) => { creations.push([name, path]); return 'project-' + creations.length; },
    attach: async (id: string, path: string) => {
      attachments.push([id, path]);
      if (fail && path === '/work/app') throw new Error('bridge disconnected');
    },
    errorText: (err: unknown) => (err as Error).message,
  };
  const first = await sessions.importSessionProjects(chosen, ['app'], created, api);
  assert.deepEqual(creations, [['app (2)', '/home/me/app'], ['app (3)', '/work/app']]);
  assert.deepEqual([...first.imported], ['/home/me/app']);
  assert.deepEqual(first.errors, { '/work/app': 'bridge disconnected' });
  fail = false;
  const retry = await sessions.importSessionProjects(chosen.filter((p) => first.errors[p.path]), ['app'], created, api);
  assert.equal(creations.length, 2, 'retry reuses the created project');
  assert.deepEqual(attachments.at(-1), ['project-2', '/work/app']);
  assert.deepEqual([...retry.imported], ['/work/app']);
  assert.deepEqual(retry.errors, {});
});

test('create failures remain visible per row without preventing other imports', async () => {
  const chosen = [
    { name: 'bad', path: '/bad', sessions: 1, source: 'Codex' as const },
    { name: 'good', path: '/good', sessions: 1, source: 'Codex' as const },
  ];
  const result = await sessions.importSessionProjects(chosen, [], {}, {
    create: async (_name, path) => path === '/bad' ? '' : 'id-good',
    attach: async () => {},
    errorText: (err) => (err as Error).message,
  });
  assert.match(result.errors['/bad'], /did not return.*project id/);
  assert.deepEqual([...result.imported], ['/good']);
});

test('complete inventory excludes a mapped project beyond the first 50 and reserves its name', async () => {
  const { loadAllProjectPages } = await import('../src/ui/api/projectPagination.ts');
  const first = Array.from({ length: 50 }, (_, i) => ({ project_id: 'p' + i, name: 'name' + i }));
  const last = { project_id: 'p50', name: 'app' };
  const requests: string[] = [];
  const inventory = await loadAllProjectPages(async (cursor) => {
    requests.push(cursor);
    return cursor
      ? { data: [last], page: { has_more: false, next_cursor: null } }
      : { data: first, page: { has_more: true, next_cursor: 'page2' } };
  });
  assert.deepEqual(requests, ['', 'page2']);
  assert.equal(inventory.length, 51);
  const mappings = await sessions.loadProjectBridgeMappings(inventory, async (id) => ({
    bridge_paths: id === 'p50' ? [{ bridge_id: 'here', path: '/already/app' }] : [],
  }));
  const found = [{ name: 'app', path: '/already/app', sessions: 1, source: 'Codex' as const }];
  assert.deepEqual(sessions.newProjectsOnly(found, mappings, 'here'), []);
  const names: string[] = [];
  await sessions.importSessionProjects(
    [{ ...found[0], path: '/new/app' }], inventory.map((p) => p.name), {},
    {
      create: async (name) => { names.push(name); return 'new'; },
      attach: async () => {},
      errorText: String,
    },
  );
  assert.deepEqual(names, ['app (2)']);
});

test('complete inventory fails closed on later-page errors and invalid cursors', async () => {
  const { loadAllProjectPages } = await import('../src/ui/api/projectPagination.ts');
  await assert.rejects(loadAllProjectPages(async (cursor) => {
    if (cursor) throw new Error('page two offline');
    return { data: [], page: { has_more: true, next_cursor: 'next' } };
  }), /page two offline/);
  await assert.rejects(loadAllProjectPages(async () => ({
    data: [], page: { has_more: true, next_cursor: 'repeat' },
  })), /invalid pagination/);
  await assert.rejects(loadAllProjectPages(async () => ({ data: [] })), /Could not check/);
  assert.deepEqual(await loadAllProjectPages(async () => ({
    data: [], page: { has_more: false, next_cursor: null },
  })), []);
});

test('listProjects allPages consumes real array envelopes through the endpoint', async () => {
  const { makeVaultStore, installWindowShim } = await import('./helpers/vaultEndpointHarness.ts');
  installWindowShim();
  const { projectsApi } = await import('../src/ui/api/endpoints/projects.ts');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const originalFetch = globalThis.fetch;
  const store = await makeVaultStore();
  const requests: string[] = [];
  let empty = false;
  const first = Array.from({ length: 50 }, (_, i) => ({ project_id: 'p' + i, name: 'name' + i }));
  const last = { project_id: 'p50', name: 'app' };
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input), 'https://hub.test');
    assert.equal(init?.credentials, 'include');
    assert.equal(url.searchParams.get('limit'), '50');
    const cursor = url.searchParams.get('cursor');
    requests.push(cursor || '');
    const body = empty
      ? { data: [], page: { has_more: false, next_cursor: null } }
      : cursor === 'page2'
        ? { data: [last], page: { has_more: false, next_cursor: null } }
        : { data: first, page: { has_more: true, next_cursor: 'page2' } };
    return new Response(JSON.stringify(body), { headers: { 'Content-Type': 'application/json' } });
  };
  try {
    const result = await store.dispatch(projectsApi.endpoints.listProjects.initiate({ allPages: true }, { subscribe: false })).unwrap();
    assert.deepEqual(result.projects, [...first, last]);
    assert.deepEqual(requests, ['', 'page2']);
    empty = true;
    const resultEmpty = await store.dispatch(projectsApi.endpoints.listProjects.initiate({ allPages: true }, { subscribe: false, forceRefetch: true })).unwrap();
    assert.deepEqual(resultEmpty.projects, []);
    assert.deepEqual(requests, ['', 'page2', '']);
  } finally {
    store.dispatch(heimdallApi.util.resetApiState());
    globalThis.fetch = originalFetch;
  }
});

test('mapping inventory rejects malformed identifiers, records and mapping entries', async () => {
  for (const project of [null, {}, { project_id: 3 }, { project_id: ' ' }]) {
    await assert.rejects(sessions.loadProjectBridgeMappings([project] as any, async () => ({ bridge_paths: [] })), /identify/);
  }
  for (const mapping of [null, {}, { bridge_id: 'here' }, { bridge_id: 4, path: '/work/app' }, { bridge_id: 'here', path: '' }, { bridge_id: '', path: '/work/app' }]) {
    await assert.rejects(sessions.loadProjectBridgeMappings([{ project_id: 'p' }], async () => ({ bridge_paths: [mapping] })), /check existing/);
  }
  await assert.rejects(sessions.loadProjectBridgeMappings([{ project_id: 'p' }], async () => ({ project: { project_id: 'other' }, bridge_paths: [] })), /identify/);
});

test('rendered Projects step retries failed and malformed inventory before offering imports', async () => {
  const { JSDOM } = await import('jsdom');
  const React = await import('react');
  const { createRoot } = await import('react-dom/client');
  const { Provider } = await import('react-redux');
  const { makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { ProjectsStep } = await import('../src/ui/components/setup/SetupWizardPage.tsx');
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.test' });
  const oldWindow = globalThis.window;
  const oldDocument = globalThis.document;
  const oldFetch = globalThis.fetch;
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
  const store = await makeVaultStore();
  const root = createRoot(dom.window.document.getElementById('root')!);
  let phase = 'failed';
  let lists = 0;
  let details = 0;
  let scans = 0;
  let completed = 0;
  const creations: any[] = [];
  const attachments: string[] = [];
  const reply = (body: any, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
  globalThis.fetch = async (input, init) => {
    const url = new URL(String(input), 'https://hub.test');
    if (url.pathname === '/api/v1/projects' && init?.method === 'POST') {
      creations.push(JSON.parse(String(init.body)));
      return reply({ data: { project_id: 'new' } });
    }
    if (url.pathname === '/api/v1/projects/new/bridge-paths/here' && init?.method === 'PUT') {
      attachments.push(JSON.parse(String(init.body)).path);
      return reply({ data: { ok: true } });
    }
    if (url.pathname === '/api/v1/projects') {
      lists++;
      if (phase === 'failed') return reply({ error: { message: 'inventory offline' } }, 503);
      return reply({ data: [{ project_id: 'p', name: 'app', description: 'My original description.' }], page: { has_more: false, next_cursor: null } });
    }
    if (url.pathname === '/api/v1/projects/p') {
      details++;
      return reply({ project: { project_id: 'p' }, bridge_paths: phase === 'malformed' ? [{ bridge_id: 'here' }] : [{ bridge_id: 'here', path: '/work/existing' }] });
    }
    if (url.pathname.endsWith('/session-projects')) {
      scans++;
      return reply({ ok: true, projects: [
        { source: 'Codex', path: '/work/app', sessions: 1, last_session_at: '2026-01-01T00:00:00Z', description: 'App is a calendar service.' },
        { source: 'Claude Code', path: '-work-app', canonical_path: '/work/app', sessions: 2, last_session_at: '2026-01-01T00:00:00Z', description: 'App is a calendar service.' },
        { source: 'Codex', path: '/work/existing', sessions: 1, last_session_at: '2026-01-01T00:00:00Z' },
      ] });
    }
    if (url.pathname.endsWith('/fs/stat')) return reply({ ok: true, exists: true, is_dir: true });
    throw new Error('unexpected request: ' + url);
  };
  const find = (id: string) => dom.window.document.querySelector('[data-debug-id="' + id + '"]') as HTMLElement | null;
  const settle = async (predicate: () => boolean) => {
    for (let i = 0; i < 100; i++) {
      await React.act(async () => { await new Promise((resolve) => setTimeout(resolve, 10)); });
      if (predicate()) return;
    }
    assert.fail('render did not settle: ' + dom.window.document.body.textContent);
  };
  try {
    await React.act(async () => { root.render(React.createElement(Provider, { store }, React.createElement(ProjectsStep, { bridgeId: 'here', onDone() { completed++; } }))); });
    await settle(() => Boolean(find('setup-projects-retry-btn')));
    assert.equal(find('setup-projects-import-btn'), null);
    phase = 'malformed';
    await React.act(async () => { find('setup-projects-retry-btn')!.click(); });
    await settle(() => details === 1 && Boolean(find('setup-projects-retry-btn')));
    assert.equal(find('setup-projects-import-btn'), null);
    phase = 'healthy';
    await React.act(async () => { find('setup-projects-retry-btn')!.click(); });
    await settle(() => Boolean(find('setup-projects-import-btn')));
    assert.equal(lists, 3);
    assert.equal(details, 2);
    assert.equal(scans, 2);
    assert.equal(find('setup-projects-retry-btn'), null);
    assert.ok(find('setup-projects-row-%2Fwork%2Fapp'));
    assert.equal(find('setup-projects-row-%2Fwork%2Fexisting'), null);
    assert.match(find('setup-projects-row-%2Fwork%2Fapp')!.textContent!, /App is a calendar service/);
    assert.match(find('setup-projects-row-%2Fwork%2Fapp')!.textContent!, /3 sessions/);
    await React.act(async () => { find('setup-projects-import-btn')!.click(); });
    await settle(() => completed === 1);
    assert.deepEqual(creations, [{ name: 'app (2)', default_path: '/work/app', description: 'App is a calendar service.', slug: 'app-2' }]);
    assert.deepEqual(attachments, ['/work/app']);
  } finally {
    await React.act(async () => { root.unmount(); store.dispatch(heimdallApi.util.resetApiState()); });
    globalThis.fetch = oldFetch;
    globalThis.window = oldWindow;
    globalThis.document = oldDocument;
    delete (globalThis as any).IS_REACT_ACT_ENVIRONMENT;
    dom.window.close();
  }
});

test('canonical paths merge provider aliases, preserve summaries, and omit unresolved bridge rows', async () => {
  const summary = 'App is a calendar service.';
  const stat: import('../src/ui/components/setup/sessionProjects.ts').SessionFs['stat'] = async (path) => ({
    ok: true, exists: true, is_dir: true, path: path === '/alias/app' ? '/real/app' : path,
  });
  const rows = await sessions.discoverSessionProjects({ ok: true, projects: [
    { source: 'Codex', path: '/alias/app', sessions: 2, last_session_at: '', description: summary },
    { source: 'Claude Code', path: '-alias-app', canonical_path: '/real/app', sessions: 3, last_session_at: '', description: summary },
    { source: 'Codex', path: '/other/app', sessions: 1, last_session_at: '', description: 'Another app.' },
    { source: 'Claude Code', path: '-ambiguous', canonical_path: '', sessions: 1, last_session_at: '' },
  ] }, { list: async () => null, stat });
  assert.equal(rows.length, 2);
  const app = rows.find((p) => p.path === '/real/app')!;
  assert.equal(app.sessions, 5);
  assert.equal(app.source, 'Claude Code + Codex');
  assert.equal(app.description, summary);
  const inventory = [{ project_id: 'existing', description: 'My own description.' }];
  const mappings = await sessions.loadProjectBridgeMappings(inventory, async () => ({
    project: inventory[0], bridge_paths: [{ bridge_id: 'here', path: '/alias/app' }],
  }), { bridgeId: 'here', stat });
  assert.deepEqual(sessions.newProjectsOnly(rows, mappings, 'here').map((p) => p.path), ['/other/app']);
  assert.equal(inventory[0].description, 'My own description.');
  const created: any[] = [];
  await sessions.importSessionProjects(rows, ['app'], {}, {
    create: async (name, path, description) => { created.push({ name, path, description }); return name; },
    attach: async () => {},
    errorText: String,
  });
  assert.deepEqual(created, [
    { name: 'app (2)', path: '/real/app', description: summary },
    { name: 'app (3)', path: '/other/app', description: 'Another app.' },
  ]);
});

test('canonical mapping checks fail closed on fs errors, skip other bridges, and normalize Windows identity', async () => {
  const detail = async () => ({ bridge_paths: [{ bridge_id: 'here', path: '/alias/app' }] });
  await assert.rejects(sessions.loadProjectBridgeMappings([{ project_id: 'p' }], detail, {
    bridgeId: 'here', stat: async () => null,
  }), /check existing/);
  const mappings = await sessions.loadProjectBridgeMappings([{ project_id: 'p' }], detail, {
    bridgeId: 'other', stat: async () => { throw new Error('other bridge must not be checked'); },
  });
  assert.equal(mappings[0].bridge_paths[0].path, '/alias/app');
  assert.equal(sessions.projectPathKey('C:\\Work\\App\\'), sessions.projectPathKey('c:/work/app'));
});
