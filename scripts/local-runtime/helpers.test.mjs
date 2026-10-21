// Tests for the shared Node helpers (seed.mjs, bridge-config.mjs).
// Run: node --test scripts/local-runtime/helpers.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { seed, FIXTURES } from './seed.mjs';
import { renderBridgeConfig } from './bridge-config.mjs';

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
