#!/usr/bin/env node
// Seed a sample task chain for an enrolled local bridge, with its coordinator set.
//
//   node scripts/local-runtime/bridge-chain.mjs --api <proxy-url> --hub-dir <hub instance dir> \
//     --bridge-id <brg_...> [--dev-user <name>]
//
// local-bridge.sh runs this on every start, once the bridge is connected, when
// the bridge belongs to a local-hub.sh instance (--hub NAME). Data only: no
// agent is launched and no provider session starts.
//
// 1. The bridge's owner and label come from <hub-dir>/hub.db. The owner's seed
//    record is <hub-dir>/seed.json for the hub's dev user (--dev-user) and
//    <hub-dir>/seed-<owner>.json for a seeded paid account. No record means the
//    hub was started with --no-seed (or the account was never seeded): skip.
// 2. The chain "Sample: <bridge label>" and its tasks are created through the
//    public REST API, signed in as the owner like seed.mjs, without a
//    coordinator. An existing chain with that title is adopted.
// 3. The coordinator's provider and model come from the hub's own view of this
//    bridge: POST /bridges/<id>/providers/discover (the Settings "check again"
//    probe; it looks up binaries, it starts no session), then
//    GET /bridges/<id>/provider-status. The first provider that is present and
//    enabled wins, else the first present one; its model is the first active one
//    in the hub's effective list, and its profile is the reported profile_id.
//    Those are the values the hub's start path validates
//    (validate_provider_model_intersection). With no present provider the
//    coordinator is deferred (nothing recorded) and the next start retries.
// 4. The coordinator is written into hub.db directly, the same way plans.mjs
//    writes billing: the API only adds a coordinator by launching one
//    (create_instance sends launch_agent). In one transaction, as prepare_instance
//    and ensure_instance_conversation write them: one STOPPED, never-launched
//    instance of the seeded sample-coordinator agent bound to this bridge, with
//    that provider/profile/model and run_count 0; its chat_conversations row
//    (bound to the instance, agent and chain); a coordinator row in
//    task_chain_members (the canonical source) and the
//    task_chains.coordinator_agent_instance_id mirror. Start in the UI then
//    launches it like any stopped instance. Like every launch, that needs the
//    provider enabled on the bridge (Settings > Bridges); the seed never changes
//    bridge provider settings.
//
// Idempotent: the record gains `bridge:<bridge-id>` (chain) and
// `bridge:<bridge-id>:coordinator` (instance). A recorded key is never redone,
// so a chain or coordinator the user deleted or changed stays that way, and a
// chain that already has a coordinator is adopted, not rewritten.
// Shared by local-bridge.sh (see CONTRACT.md).
import { existsSync, readFileSync, writeFileSync, renameSync, realpathSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { hubLogin, sessionHeaders } from '../../tests/e2e/hubOidc.mjs';

export const COORDINATOR_AGENT_KEY = 'sample-coordinator';
export const chainKey = (bridgeId) => `bridge:${bridgeId}`;
export const coordinatorKey = (bridgeId) => `bridge:${bridgeId}:coordinator`;

export function chainFixture(label) {
  return {
    title: `Sample: ${label}`,
    description: `Seeded sample chain for bridge ${label}, created when it first connected. Its coordinator is the Sample Coordinator on this bridge, not started yet.`,
    tasks: [
      { title: 'Read the project README', description: 'Summarise the setup steps.' },
      { title: 'Add a hello-world endpoint', description: 'Small change with a test.' },
    ],
  };
}

export function parseArgs(argv) {
  const out = { devUser: '' };
  const names = { '--api': 'api', '--hub-dir': 'hubDir', '--bridge-id': 'bridgeId', '--dev-user': 'devUser' };
  for (let i = 0; i < argv.length; i += 2) {
    const k = names[argv[i]];
    if (!k || argv[i + 1] === undefined) throw new Error(`bad argument ${argv[i]}`);
    out[k] = argv[i + 1];
  }
  if (!out.api || !out.hubDir || !out.bridgeId) throw new Error('usage: bridge-chain.mjs --api <url> --hub-dir <dir> --bridge-id <brg_...> [--dev-user <name>]');
  return out;
}

// The hub's own timestamp shape (RFC 3339, second precision, UTC).
const nowStamp = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');
const newInstanceId = () => `inst_${randomBytes(8).toString('hex')}`;
const newConversationId = () => `chat_${randomBytes(8).toString('hex')}`;

// pickRuntime chooses the coordinator's provider/profile/model from a
// GET /bridges/<id>/provider-status body. null = nothing usable is installed.
export function pickRuntime(status) {
  const usable = (status?.data?.providers || status?.providers || [])
    .filter((p) => p.state === 'present' && (p.catalog_state || 'active') === 'active')
    .map((p) => ({ p, model: (p.models || []).find((m) => m.state === 'active')?.model_id || '' }))
    .filter((c) => c.model);
  const hit = usable.find((c) => c.p.enabled) || usable[0];
  return hit ? { provider: hit.p.provider, profile: hit.p.profile_id || hit.p.provider, model: hit.model, enabled: Boolean(hit.p.enabled) } : null;
}

// apiClient: JSON calls to the hub as the signed-in owner.
function apiClient({ api, fetchImpl, auth }) {
  const base = api.replace(/\/+$/, '');
  const headers = { 'Content-Type': 'application/json', ...auth };
  return async function call(method, path, body) {
    const res = await fetchImpl(base + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const text = await res.text();
    if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${text.slice(0, 300)}`);
    return text ? JSON.parse(text) : {};
  };
}

// bridgeRuntime asks the hub to re-probe the bridge's providers, then reads them.
export async function bridgeRuntime(call, bridgeId, log = console.log) {
  const bridge = `/api/v1/bridges/${encodeURIComponent(bridgeId)}`;
  try { await call('POST', `${bridge}/providers/discover`, {}); } catch (err) { log(`bridge-chain: provider discovery failed (${err.message}); using the last report`); }
  return pickRuntime(await call('GET', `${bridge}/provider-status`));
}

function openDb(file) {
  const conn = new DatabaseSync(file);
  conn.exec('PRAGMA busy_timeout = 5000');
  return conn;
}

// bridgeOwner reads who owns the bridge and what it is called.
export function bridgeOwner(db, bridgeId) {
  const conn = openDb(db);
  try {
    const row = conn.prepare('SELECT owner_user_id, label FROM bridges WHERE bridge_id = ?').get(bridgeId);
    return row ? { owner: row.owner_user_id, label: row.label || bridgeId } : null;
  } finally { conn.close(); }
}

export const recordFor = (hubDir, owner, devUser) =>
  join(hubDir, !devUser || owner === devUser ? 'seed.json' : `seed-${owner}.json`);

function recordStore(record) {
  const state = JSON.parse(readFileSync(record, 'utf8'));
  state.seeded ||= {};
  return {
    state,
    save() {
      const tmp = `${record}.tmp`;
      writeFileSync(tmp, JSON.stringify(state, null, 2) + '\n');
      renameSync(tmp, record);
    },
  };
}

// ensureChain creates (or adopts by title) the bridge's chain through the REST API.
export async function ensureChain({ api, bridgeId, label, store, fetchImpl = fetch, auth = {}, log = console.log, call = apiClient({ api, fetchImpl, auth }) }) {
  const key = chainKey(bridgeId);
  if (store.state.seeded[key]) { log(`bridge-chain: skip ${key} (recorded)`); return { id: store.state.seeded[key], created: false }; }
  const f = chainFixture(label);
  const hit = ((await call('GET', '/api/v1/task-chains?flat=1')).data || []).find((c) => c.title === f.title);
  if (hit) {
    store.state.seeded[key] = hit.chain_id; store.save();
    log(`bridge-chain: skip ${key} (exists ${hit.chain_id})`);
    return { id: hit.chain_id, created: false };
  }
  const id = (await call('POST', '/api/v1/task-chains', { title: f.title, description: f.description })).data.chain_id;
  for (const t of f.tasks) {
    await call('POST', `/api/v1/task-chains/${encodeURIComponent(id)}/tasks`, { title: t.title, description: t.description });
  }
  store.state.seeded[key] = id; store.save();
  log(`bridge-chain: created ${key} ${id}`);
  return { id, created: true };
}

// ensureCoordinator writes the stopped coordinator instance (and its
// conversation) for the bridge's chain. runtime: () => Promise<pickRuntime()>,
// asked only when an instance is really about to be written.
export async function ensureCoordinator({ db, bridgeId, store, runtime, log = console.log, now = nowStamp, newId = newInstanceId, newConvId = newConversationId }) {
  const key = coordinatorKey(bridgeId);
  const seeded = store.state.seeded;
  if (seeded[key]) { log(`bridge-chain: skip ${key} (recorded)`); return { id: seeded[key], created: false }; }
  const chainId = seeded[chainKey(bridgeId)];
  const agentId = seeded[COORDINATOR_AGENT_KEY];
  const conn = openDb(db);
  try {
    const chain = chainId && conn.prepare('SELECT owner_user_id, coordinator_agent_instance_id AS col FROM task_chains WHERE chain_id = ?').get(chainId);
    if (!chain) { log(`bridge-chain: skip ${key} (no chain)`); return { id: '', created: false }; }
    const existing = conn.prepare("SELECT agent_instance_id FROM task_chain_members WHERE chain_id = ? AND role = 'coordinator' LIMIT 1").get(chainId)?.agent_instance_id || chain.col;
    if (existing) {
      seeded[key] = existing; store.save();
      log(`bridge-chain: skip ${key} (has coordinator ${existing})`);
      return { id: existing, created: false };
    }
    const agent = agentId && conn.prepare('SELECT name FROM agents WHERE agent_id = ? AND owner_user_id = ?').get(agentId, chain.owner_user_id);
    if (!agent) { log(`bridge-chain: skip ${key} (sample coordinator agent missing)`); return { id: '', created: false }; }
    const bridge = conn.prepare('SELECT owner_user_id FROM bridges WHERE bridge_id = ?').get(bridgeId);
    if (!bridge || bridge.owner_user_id !== chain.owner_user_id) throw new Error(`bridge ${bridgeId} does not belong to the owner of chain ${chainId}`);
    const rt = await runtime();
    if (!rt) { log(`bridge-chain: defer ${key} (the bridge reports no installed provider; retried on the next start)`); return { id: '', created: false }; }

    const id = newId();
    const convId = newConvId();
    const at = now();
    conn.exec('BEGIN IMMEDIATE');
    try {
      conn.prepare(`INSERT INTO agent_instances
        (agent_instance_id, owner_user_id, agent_id, bridge_id, display_name, chain_id, conversation_id, kind,
         provider, provider_profile, model, run_count,
         runtime_status, startup_status, activity_status, created_at, updated_at, stopped_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'agent', ?, ?, ?, 0, 'stopped', 'stopped', 'idle', ?, ?, ?)`)
        .run(id, chain.owner_user_id, agentId, bridgeId, agent.name, chainId, convId, rt.provider, rt.profile, rt.model, at, at, at);
      conn.prepare(`INSERT INTO chat_conversations
        (conversation_id, owner_user_id, agent_id, agent_instance_id, chain_id, title, title_source, last_activity_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, 'default', ?, ?, ?)`).run(convId, chain.owner_user_id, agentId, id, chainId, agent.name, at, at, at);
      conn.prepare(`INSERT INTO task_chain_members (chain_id, agent_instance_id, agent_id, owner_user_id, role, created_at)
        VALUES (?, ?, ?, ?, 'coordinator', ?)`).run(chainId, id, agentId, chain.owner_user_id, at);
      // The task_chains_work_revision_control trigger bumps work_revision.
      const r = conn.prepare("UPDATE task_chains SET coordinator_agent_instance_id = ?, updated_at = ? WHERE chain_id = ? AND coordinator_agent_instance_id = ''").run(id, at, chainId);
      if (r.changes !== 1) throw new Error(`chain ${chainId} gained a coordinator concurrently`);
      conn.exec('COMMIT');
    } catch (err) {
      conn.exec('ROLLBACK');
      throw err;
    }
    seeded[key] = id; store.save();
    log(`bridge-chain: created ${key} ${id} (${rt.provider}/${rt.model}${rt.enabled ? '' : '; enable the provider on the bridge to start it'})`);
    return { id, created: true };
  } finally { conn.close(); }
}

export async function seedBridgeChain({ api, hubDir, bridgeId, devUser = '', fetchImpl = fetch, log = console.log, login = hubLogin, uiOrigin = '' }) {
  const db = join(hubDir, 'hub.db');
  const bridge = bridgeOwner(db, bridgeId);
  if (!bridge) throw new Error(`bridge ${bridgeId} is not on this hub`);
  const record = recordFor(hubDir, bridge.owner, devUser);
  if (!existsSync(record)) { log(`bridge-chain: skip (no seed record for ${bridge.owner}; hub started with --no-seed?)`); return null; }
  const store = recordStore(record);
  // Signed in only when something is left to do, so a seeded bridge's restart
  // makes no API call at all.
  let client;
  const call = async (...args) => {
    if (!client) client = apiClient({ api, fetchImpl, auth: sessionHeaders(await login(api, bridge.owner), uiOrigin || api) });
    return client(...args);
  };
  let chain = { id: store.state.seeded[chainKey(bridgeId)], created: false };
  if (!chain.id) {
    chain = await ensureChain({ api, bridgeId, label: bridge.label, store, log, call });
  } else {
    log(`bridge-chain: skip ${chainKey(bridgeId)} (recorded)`);
  }
  const coordinator = await ensureCoordinator({ db, bridgeId, store, log, runtime: () => bridgeRuntime(call, bridgeId, log) });
  return { chain: chain.id, coordinator: coordinator.id };
}

// Compared by real path: the checkout is often reached through a symlink
// (/home -> /var/home), and a plain URL comparison then silently skips main.
if (process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1])) {
  seedBridgeChain({ ...parseArgs(process.argv.slice(2)), uiOrigin: process.env.HEIMDALL_LOCAL_UI_ORIGIN || '' })
    .catch((err) => {
      console.error(`bridge-chain: ${err.message}`);
      process.exit(1);
    });
}
