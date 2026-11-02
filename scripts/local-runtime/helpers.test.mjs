// Tests for the shared Node helpers (seed.mjs, bridge-config.mjs).
// Run: node --test scripts/local-runtime/helpers.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, existsSync, lstatSync, mkdtempSync, readFileSync, readlinkSync, rmSync, statSync, symlinkSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { seed, FIXTURES } from './seed.mjs';
import { renderBridgeConfig } from './bridge-config.mjs';
import { seed as seedHome, mergeCodexToml, MANIFEST } from './provider-home.mjs';
import { setPlan, parseArgs as parsePlanArgs } from './plans.mjs';
import { DatabaseSync } from 'node:sqlite';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '../..');

// A tiny in-memory hub with the response envelopes of the real REST handlers.
function fakeHub() {
  const db = { agents: [], chains: [], tasks: [], memories: [] };
  let n = 0;
  const id = (p) => `${p}_${++n}`;
  const reply = (status, data) => ({ ok: status < 300, status, text: async () => JSON.stringify({ data }) });
  async function fetchImpl(url, { method, body }) {
    const path = new URL(url).pathname;
    const b = body ? JSON.parse(body) : {};
    if (method === 'GET' && path === '/api/v1/agents') return reply(200, db.agents);
    if (method === 'GET' && path === '/api/v1/task-chains') return reply(200, db.chains);
    if (method === 'GET' && path === '/api/v1/memories') return reply(200, db.memories);
    if (method === 'POST' && path === '/api/v1/agents') {
      const a = { agent_id: id('agt'), name: b.name, instructions: b.instructions };
      db.agents.push(a); return reply(201, a);
    }
    if (method === 'POST' && path === '/api/v1/task-chains') {
      assert.equal(b.coordinator_agent_id, undefined, 'seed must not launch a coordinator');
      const c = { chain_id: id('chain'), title: b.title }; db.chains.push(c); return reply(201, c);
    }
    let m = path.match(/^\/api\/v1\/task-chains\/([^/]+)\/tasks$/);
    if (method === 'POST' && m) { const t = { task_id: id('task'), chain_id: m[1], title: b.title }; db.tasks.push(t); return reply(201, t); }
    if (method === 'POST' && path === '/api/v1/memories') {
      const mem = { memory_id: id('mem'), title: b.title, type: b.type, status: 'pending' };
      db.memories.push(mem); return reply(201, mem);
    }
    m = path.match(/^\/api\/v1\/memories\/([^/]+)\/approve$/);
    if (method === 'POST' && m) { const mem = db.memories.find((x) => x.memory_id === m[1]); mem.status = 'approved'; return reply(200, mem); }
    return reply(404, { error: `no route ${method} ${path}` });
  }
  return { db, fetchImpl };
}

test('seed creates every fixture once and a rerun creates nothing', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'lr-seed-'));
  try {
    const hub = fakeHub();
    const opts = { api: 'http://hub', record: join(dir, 'seed.json'), fetchImpl: hub.fetchImpl, log: () => {} };
    const first = await seed(opts);
    const total = FIXTURES.agents.length + FIXTURES.chains.length + FIXTURES.memories.length;
    assert.equal(first.created, total);
    assert.equal(hub.db.tasks.length, FIXTURES.chains.reduce((s, c) => s + c.tasks.length, 0));
    assert.ok(hub.db.memories.every((m) => m.status === 'approved'));
    const second = await seed(opts);
    assert.deepEqual(second, { created: 0, skipped: total });
    assert.equal(hub.db.agents.length, FIXTURES.agents.length);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('seed never recreates a fixture the user renamed or deleted', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'lr-seed-'));
  try {
    const hub = fakeHub();
    const opts = { api: 'http://hub', record: join(dir, 'seed.json'), fetchImpl: hub.fetchImpl, log: () => {} };
    await seed(opts);
    hub.db.agents[0].name = 'Renamed by user';
    hub.db.chains.pop();
    const again = await seed(opts);
    assert.equal(again.created, 0);
    assert.equal(hub.db.agents[0].name, 'Renamed by user');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('seed adopts pre-existing items with the same name instead of duplicating', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'lr-seed-'));
  try {
    const hub = fakeHub();
    hub.db.agents.push({ agent_id: 'agt_user', name: FIXTURES.agents[0].name });
    await seed({ api: 'http://hub', record: join(dir, 'seed.json'), fetchImpl: hub.fetchImpl, log: () => {} });
    assert.equal(hub.db.agents.filter((a) => a.name === FIXTURES.agents[0].name).length, 1);
    const rec = JSON.parse(readFileSync(join(dir, 'seed.json'), 'utf8'));
    assert.equal(rec.seeded[FIXTURES.agents[0].key], 'agt_user');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('seed surfaces hub errors instead of reporting success', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'lr-seed-'));
  try {
    const failing = async () => ({ ok: false, status: 403, text: async () => '{"error":{"code":"csrf_rejected"}}' });
    await assert.rejects(seed({ api: 'http://hub', record: join(dir, 's.json'), fetchImpl: failing, log: () => {} }), /403/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('bridge config points every persisted path and endpoint into the instance', () => {
  const template = readFileSync(join(ROOT, 'config.toml'), 'utf8') + '\n[[peer]]\nurl = "https://prod"\ntoken = "x"\n';
  const out = renderBridgeConfig(template, { dir: '/state/bridges/b1', hubUrl: 'http://127.0.0.1:18081', port: 49427, name: 'b1' });
  assert.match(out, /^port = 49427$/m);
  assert.match(out, /^data_dir = "\/state\/bridges\/b1\/data"$/m);
  assert.match(out, /^agent_run_dir = "\/state\/bridges\/b1\/agent-runs"$/m);
  assert.match(out, /^credentials_path = "\/state\/bridges\/b1\/data\/wrapper-credentials.json"$/m);
  assert.match(out, /^daemon_id = "local-b1"$/m);
  assert.doesNotMatch(out, /\[\[peer\]\]|https:\/\/prod/);
  assert.doesNotMatch(out, /49322/);
  assert.match(out, /\[wrapper\][^[]*daemon_url = "http:\/\/127.0.0.1:49427"/);
  assert.match(out, /\[ctl\]\s*daemon_url = "http:\/\/127.0.0.1:18081"/);
  // Only commented examples may still mention the installed data dir.
  for (const line of out.split('\n')) {
    if (line.includes('~/.local/share/heimdall')) assert.match(line, /^\s*#/);
  }
});

test('bridge config keeps the daemon_id that enrollment wrote', () => {
  const template = readFileSync(join(ROOT, 'config.toml'), 'utf8');
  const existing = 'daemon_id = "brg_abc"\n';
  const out = renderBridgeConfig(template, { dir: '/s', hubUrl: 'http://h:1', port: 2000, name: 'x', existing });
  assert.match(out, /^daemon_id = "brg_abc"$/m);
});

test('bridge config pins fs_root only when asked', () => {
  const template = readFileSync(join(ROOT, 'config.toml'), 'utf8');
  const pinned = renderBridgeConfig(template, { dir: '/s', hubUrl: 'http://h:1', port: 2, name: 'x', fsRoot: '/home/dev' });
  assert.match(pinned, /\[bridge\][^[]*^fs_root = "\/home\/dev"$/m);
  const plain = renderBridgeConfig(template, { dir: '/s', hubUrl: 'http://h:1', port: 2, name: 'x' });
  assert.doesNotMatch(plain, /^fs_root/m);
});

// A fake real home: never the developer's.
function fakeRealHome() {
  const root = mkdtempSync(join(tmpdir(), 'lr-home-'));
  const real = join(root, 'real');
  const put = (p, body) => { mkdirSync(dirname(join(real, p)), { recursive: true }); writeFileSync(join(real, p), body); };
  put('.claude/.credentials.json', '{"claudeAiOauth":{"refreshToken":"r1"}}');
  put('.claude.json', JSON.stringify({
    oauthAccount: { emailAddress: 'dev@example.com' }, userID: 'u1', hasCompletedOnboarding: true,
    mcpServers: { secret: {} }, tipsHistory: { a: 1 },
    projects: { '/work/a': { hasTrustDialogAccepted: true, lastCost: 3, mcpServers: { x: {} } }, '/work/b': { hasTrustDialogAccepted: false } },
  }));
  put('.claude/settings.json', JSON.stringify({
    model: 'opus', skipDangerousModePermissionPrompt: true, enabledPlugins: { 'real@m': true },
    hooks: { Stop: [{ command: 'real-hook' }] }, mcpServers: { real: {} }, statusLine: { command: 'real-status' },
  }));
  put('.claude/plugins/installed_plugins.json', '{}');
  put('.claude/history.jsonl', 'secret history');
  put('.codex/auth.json', '{"tokens":{"refresh_token":"r2"}}');
  put('.gemini/hooks.json', '{"real":"hook"}');
  put('.gemini/settings.json', JSON.stringify({ theme: 'dark', mcpServers: { real: {} }, hooks: { a: 1 }, toolDiscoveryCommand: 'real-disc', tools: { discoveryCommand: 'real-d', callCommand: 'real-c', sandbox: true } }));
  put('.gemini/config/config.json', JSON.stringify({ userSettings: { model: 'g', mcpServers: { real: {} }, hooksConfig: { x: 1 } } }));
  put('.gemini/antigravity-cli/settings.json', JSON.stringify({ trustedWorkspaces: ['/work/a'], permissions: { allow: [] }, mcpServers: { real: {} } }));
  put('.pi/agent/settings.json', JSON.stringify({ defaultModel: 'm', packages: ['real-pkg'], extensions: ['/real/ext.ts'] }));
  put('.gitconfig', '[user]\n  name = dev\n');
  put('.codex/config.toml', 'model = "gpt"\nnotify = [\n  "real-notify",\n  ["x"],\n]\nargs = [\n  ["a"],\n]\n\n[hooks]\nx = 1\n\n[mcp_servers.real]\ncommand = "real-mcp"\n\n[projects."/work/a"]\ntrust_level = "trusted"\n\n[marketplaces.real]\nsource = "/real"\n\n[plugins."real@m"]\nenabled = true\n\n[hooks.state."real@m:x"]\nok = 1\n\n[tui]\nx = 1\n');
  put('.pi/agent/auth.json', '{}');
  put('.pi/agent/extensions/watch.ts', 'x');
  // A read-only store file (like /nix/store) and a writable dotfiles checkout, both
  // outside the real home.
  mkdirSync(join(root, 'store'));
  writeFileSync(join(root, 'store', 'AGENTS.md'), 'managed');
  chmodSync(join(root, 'store', 'AGENTS.md'), 0o444);
  symlinkSync(join(root, 'store', 'AGENTS.md'), join(real, '.codex/AGENTS.md'));
  mkdirSync(join(root, 'dotfiles'));
  writeFileSync(join(root, 'dotfiles', 'CLAUDE.md'), 'mine');
  symlinkSync(join(root, 'dotfiles', 'CLAUDE.md'), join(real, '.claude/CLAUDE.md'));
  return { root, real, home: join(root, 'instance', 'home') };
}

function snapshot(dir) {
  const out = spawnSync('sh', ['-c', 'cd "$1" && find . -print0 | sort -z | xargs -0 ls -ld --time-style=+%s; find . -type f -print0 | sort -z | xargs -0 sha256sum', 'sh', dir], { encoding: 'utf8' });
  return out.stdout;
}

test('provider home seeds auth and trust only, and never writes the real home', () => {
  const { root, real, home } = fakeRealHome();
  try {
    const before = snapshot(real);
    const m = seedHome({ realHome: real, home, providers: ['claude', 'codex', 'pi', 'gemini', 'git'], trustRoots: ['/work/c'] });
    assert.equal(snapshot(real), before);
    assert.deepEqual(m.providers.sort(), ['claude', 'codex', 'gemini', 'git', 'pi']);
    assert.equal(readFileSync(join(home, '.claude/.credentials.json'), 'utf8'), '{"claudeAiOauth":{"refreshToken":"r1"}}');
    const cj = JSON.parse(readFileSync(join(home, '.claude.json'), 'utf8'));
    assert.equal(cj.userID, 'u1');
    assert.equal(cj.mcpServers, undefined);
    assert.equal(cj.tipsHistory, undefined);
    assert.deepEqual(cj.projects, { '/work/a': { hasTrustDialogAccepted: true }, '/work/c': { hasTrustDialogAccepted: true } });
    const settings = JSON.parse(readFileSync(join(home, '.claude/settings.json'), 'utf8'));
    assert.equal(settings.skipDangerousModePermissionPrompt, true);
    for (const key of ['enabledPlugins', 'hooks', 'mcpServers', 'statusLine']) assert.equal(settings[key], undefined, key);
    const toml = readFileSync(join(home, '.codex/config.toml'), 'utf8');
    assert.match(toml, /\[projects."\/work\/a"\]\ntrust_level = "trusted"/);
    assert.match(toml, /\[projects."\/work\/c"\]\ntrust_level = "trusted"/);
    assert.doesNotMatch(toml, /marketplaces|plugins|hooks|mcp_servers|real-mcp|real-notify|notify/);
    assert.match(toml, /^model = "gpt"\nargs = \[\n  \["a"\],\n\]$/m);
    assert.equal(existsSync(join(home, '.gemini/hooks.json')), false);
    assert.deepEqual(JSON.parse(readFileSync(join(home, '.gemini/settings.json'), 'utf8')), { theme: 'dark', tools: { sandbox: true } });
    assert.deepEqual(JSON.parse(readFileSync(join(home, '.gemini/config/config.json'), 'utf8')), { userSettings: { model: 'g' } });
    assert.deepEqual(JSON.parse(readFileSync(join(home, '.gemini/antigravity-cli/settings.json'), 'utf8')), { trustedWorkspaces: ['/work/a'], permissions: { allow: [] } });
    assert.deepEqual(JSON.parse(readFileSync(join(home, '.pi/agent/settings.json'), 'utf8')), { defaultModel: 'm' });
    // Writable link target: copied, so the instance cannot write through it.
    assert.equal(lstatSync(join(home, '.claude/CLAUDE.md')).isSymbolicLink(), false);
    assert.equal(readFileSync(join(home, '.claude/CLAUDE.md'), 'utf8'), 'mine');
    for (const p of ['.claude/plugins', '.claude/history.jsonl', '.pi/agent/extensions']) assert.equal(existsSync(join(home, p)), false, p);
    assert.equal(readlinkSync(join(home, '.codex/AGENTS.md')), join(root, 'store', 'AGENTS.md'));
    assert.equal(statSync(join(home, '.codex/auth.json')).mode & 0o777, 0o600);
    const recorded = JSON.parse(readFileSync(join(home, MANIFEST), 'utf8'));
    assert.equal(recorded.real_home, real);
    assert.ok(recorded.files.every((f) => f.source.startsWith(real) && /^[0-9a-f]{64}$/.test(f.source_sha256)));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('reseeding keeps what the instance installed itself', () => {
  const { root, real, home } = fakeRealHome();
  try {
    seedHome({ realHome: real, home, providers: ['claude', 'codex', 'pi'] });
    const piPath = join(home, '.pi/agent/settings.json');
    writeFileSync(piPath, JSON.stringify({ defaultModel: 'm', packages: ['instance-pkg'] }));
    // The instance installs its own extension and trusts its own run dir.
    const settingsPath = join(home, '.claude/settings.json');
    const s = JSON.parse(readFileSync(settingsPath, 'utf8'));
    writeFileSync(settingsPath, JSON.stringify({ ...s, enabledPlugins: { 'heimdall@heimdall': true }, hooks: { Stop: [{ command: 'instance-hook' }] } }));
    const tomlPath = join(home, '.codex/config.toml');
    writeFileSync(tomlPath, `${readFileSync(tomlPath, 'utf8')}\n[plugins."heimdall@heimdall-codex"]\nenabled = true\n\n[mcp_servers.heimdall]\ncommand = "ham-ctl"\n\n[projects."/run/x"]\ntrust_level = "trusted"\n`);
    writeFileSync(join(real, '.codex/auth.json'), '{"tokens":{"refresh_token":"r3"}}');
    seedHome({ realHome: real, home, providers: ['claude', 'codex', 'pi'] });
    assert.deepEqual(JSON.parse(readFileSync(piPath, 'utf8')), { defaultModel: 'm', packages: ['instance-pkg'] });
    const after = JSON.parse(readFileSync(settingsPath, 'utf8'));
    assert.deepEqual(after.enabledPlugins, { 'heimdall@heimdall': true });
    assert.deepEqual(after.hooks, { Stop: [{ command: 'instance-hook' }] });
    const toml = readFileSync(tomlPath, 'utf8');
    assert.match(toml, /\[plugins."heimdall@heimdall-codex"\]/);
    assert.match(toml, /\[mcp_servers.heimdall\]/);
    assert.match(toml, /\[projects."\/run\/x"\]/);
    assert.doesNotMatch(toml, /real@m/);
    assert.equal(readFileSync(join(home, '.codex/auth.json'), 'utf8'), '{"tokens":{"refresh_token":"r3"}}');
    seedHome({ realHome: real, home, providers: ['codex'] });
    assert.deepEqual(JSON.parse(readFileSync(join(home, MANIFEST), 'utf8')).providers.sort(), ['claude', 'codex', 'pi']);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('provider home refuses to seed into the real home', () => {
  const { root, real } = fakeRealHome();
  try {
    assert.throws(() => seedHome({ realHome: real, home: real }), /refusing/);
    assert.throws(() => seedHome({ realHome: real, home: root }), /refusing/);
    assert.throws(() => seedHome({ realHome: real, home: join(root, 'h'), providers: ['nope'] }), /unknown provider/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('codex toml merge is idempotent', () => {
  const real = 'a = 1\n\n[projects."/p"]\ntrust_level = "trusted"\n';
  const once = mergeCodexToml(real, '', ['/q']);
  assert.equal(mergeCodexToml(real, once, ['/q']), once);
});

test('CLI entry points run when the checkout is reached through a symlink', () => {
  // /home -> /var/home on Fedora Atomic hosts: a URL comparison of import.meta.url
  // with argv[1] skipped main there and seeding silently did nothing.
  const dir = mkdtempSync(join(tmpdir(), 'lr-link-'));
  try {
    symlinkSync(join(ROOT, 'scripts'), join(dir, 'scripts'));
    const out = join(dir, 'config.toml');
    const r = spawnSync(process.execPath, [join(dir, 'scripts/local-runtime/bridge-config.mjs'), '--template', join(ROOT, 'config.toml'),
      '--out', out, '--dir', join(dir, 'b'), '--hub-url', 'http://127.0.0.1:1', '--port', '2000', '--name', 'l'], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    assert.match(readFileSync(out, 'utf8'), /^port = 2000$/m);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// The columns plans.mjs touches, as migrations 069/103 define them.
function billingDb(dir) {
  const file = join(dir, 'hub.db');
  const db = new DatabaseSync(file);
  db.exec(`CREATE TABLE billing_plans (plan_id TEXT PRIMARY KEY);
    INSERT INTO billing_plans VALUES ('free'), ('hobbyist');
    CREATE TABLE account_billing (user_id TEXT PRIMARY KEY, plan_id TEXT NOT NULL DEFAULT 'free',
      status TEXT NOT NULL DEFAULT 'free', created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    INSERT INTO account_billing (user_id, created_at, updated_at) VALUES ('paid', 'x', 'x'), ('tanmay', 'x', 'x');`);
  return { file, row: (u) => db.prepare('SELECT plan_id, status FROM account_billing WHERE user_id = ?').get(u), close: () => db.close() };
}

test('plans puts a seeded account on a paid plan, idempotently, and back to free', () => {
  const dir = mkdtempSync(join(tmpdir(), 'lr-plans-'));
  const db = billingDb(dir);
  try {
    assert.equal(setPlan({ db: db.file, user: 'paid', plan: 'hobbyist' }), 'paid -> hobbyist (custom)');
    setPlan({ db: db.file, user: 'paid', plan: 'hobbyist' });
    assert.deepEqual({ ...db.row('paid') }, { plan_id: 'hobbyist', status: 'custom' });
    assert.deepEqual({ ...db.row('tanmay') }, { plan_id: 'free', status: 'free' }, 'other users stay free');
    setPlan({ db: db.file, user: 'paid', plan: 'free' });
    assert.deepEqual({ ...db.row('paid') }, { plan_id: 'free', status: 'free' });
  } finally { db.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('plans refuses an unknown plan or a user without an account', () => {
  const dir = mkdtempSync(join(tmpdir(), 'lr-plans-'));
  const db = billingDb(dir);
  try {
    assert.throws(() => setPlan({ db: db.file, user: 'paid', plan: 'pro' }), /unknown plan 'pro'/);
    assert.throws(() => setPlan({ db: db.file, user: 'ghost', plan: 'hobbyist' }), /no billing account yet/);
    assert.deepEqual({ ...db.row('paid') }, { plan_id: 'free', status: 'free' });
    assert.throws(() => parsePlanArgs(['--db', 'x', '--user', 'paid']), /usage/);
  } finally { db.close(); rmSync(dir, { recursive: true, force: true }); }
});

test('local bridge forwards and records the browser approval base without changing the API URL', () => {
  const dir = mkdtempSync(join(tmpdir(), 'lr-approval-'));
  try {
    const bin = join(dir, 'bin');
    mkdirSync(bin);
    const argsFile = join(dir, 'args');
    // This fixture prints a normal enrollment prompt and writes only the two
    // credentials required by the launcher. It starts no bridge or service.
    writeFileSync(join(bin, 'ham-bridge'), `#!/usr/bin/env bash
printf '%s\\n' "$@" > "$LR_APPROVAL_ARGS"
while [ $# -gt 0 ]; do
  case "$1" in
    --bridge-token-file) token="$2"; shift 2 ;;
    --approval-base-url) browser=$(printf %s "$2" | sed "s:/*$::"); shift 2 ;;
    *) shift ;;
  esac
done
printf '  %s/api/v1/device/add\\n      ABCD-EFGH-IJKL-MN\\n' "$browser"
printf 'fixture' > "$token"
printf 'fixture' > "$token.refresh"
`, { mode: 0o755 });
    for (const name of ['ham-ctl', 'ham-pty-host']) writeFileSync(join(bin, name), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    const env = { ...process.env, HEIMDALL_LOCAL_STATE_ROOT: join(dir, 'state'), LR_APPROVAL_ARGS: argsFile };
    const args = [join(ROOT, 'scripts/local-bridge.sh'), 'enroll', '--name', 'preview-link',
      '--hub-url', 'http://127.0.0.1:18181', '--bin-dir', bin, '--pty-host-bin', join(bin, 'ham-pty-host'),
      '--approval-base-url', 'https://preview.example/p/sh_123/'];
    const r = spawnSync('bash', args, { env, encoding: 'utf8', timeout: 10000 });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const passed = readFileSync(argsFile, 'utf8').trim().split('\n');
    assert.equal(passed[passed.indexOf('--hub') + 1], 'http://127.0.0.1:18181');
    assert.equal(passed[passed.indexOf('--approval-base-url') + 1], 'https://preview.example/p/sh_123/');
    assert.match(r.stdout + r.stderr, /https:\/\/preview.example\/p\/sh_123\/api\/v1\/device\/add/);
    assert.match(readFileSync(join(dir, 'state/bridges/preview-link/instance.env'), 'utf8'),
      /^APPROVAL_BASE_URL=https:\/\/preview.example\/p\/sh_123\/$/m);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
