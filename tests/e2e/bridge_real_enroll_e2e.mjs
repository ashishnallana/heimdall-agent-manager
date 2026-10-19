// Real `ham-bridge enroll` against THROWAWAY hubs (ephemeral ports, temp DBs), with
// the approval done through the UI's own vault modules (the /device/add code path):
// one pairing code read from the bridge's stdout and typed once; key_mac check;
// signed vault approval; unseal v2 with chain proof + pair_mac to the enrolling
// process. Then the multi-bridge isolation rules on the real binary:
//   - the enrolled runtime starts with its config (bound to that hub);
//   - the same bridge started against another hub (--hub) refuses to start;
//   - a second instance on the same config refuses (instance lock);
//   - a second bridge enrolled against ANOTHER hub on the same machine (its own
//     config/token) works, and the first still starts afterwards.
// Hermetic: HOME/USERPROFILE/APPDATA point into a temp dir, every port is
// ephemeral. The Windows Credential Manager is real, but every item this run writes
// is scoped to a random-port 127.0.0.1 hub (keystore scope), and all of them are
// deleted at the end (cmdkey). Never touches a running dev hub/bridge.
//
//   HEIMDALL_E2E_HUB_BIN=<ham-hub> HEIMDALL_E2E_BRIDGE_BIN=<ham-bridge> \
//   node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_real_enroll_e2e.mjs

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { createDeviceIdentity, memoryDeviceStore } from '../../src/ui/utils/deviceIdentity.ts';
import { signedRequestHeaders } from '../../src/ui/utils/vaultRequestSigner.ts';
import { verifyDirectory } from '../../src/ui/utils/vaultDirectoryVerify.ts';
import { openVerifiedWrap } from '../../src/ui/utils/vaultKeyringWrap.ts';
import { serializeKeyringBytes } from '../../src/ui/utils/vaultKeyring.ts';
import { deliverKeyringToBridge } from '../../src/ui/utils/vaultBridgeDelivery.ts';
import { bridgeUnsealTargetFromRecord } from '../../src/ui/utils/vaultBridgeUnseal.ts';
import { buildBridgeApproval, buildGenesis, checkBridgeCodeInfo } from '../../src/ui/utils/vaultDeviceFlows.ts';
import { derivePairKeys, pairApproveMac, pairHubOrigin } from '../../src/ui/utils/vaultPairing.ts';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const USER = 'e2e-real-enroll';
const results = [];
class CheckFailed extends Error {}
const expect = (cond, msg) => { if (!cond) throw new CheckFailed(msg); console.log(`    ok - ${msg}`); };
async function step(name, fn) {
  console.log(`\n== ${name}`);
  try { await fn(); results.push([name, 'PASS']); console.log(`PASS ${name}`); }
  catch (err) { results.push([name, 'FAIL']); console.log(`    not ok - ${err instanceof CheckFailed ? err.message : (err?.stack || err)}`); console.log(`FAIL ${name}`); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen(0, '127.0.0.1', () => { const { port } = srv.address(); srv.close(() => resolve(port)); });
  });
}

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-real-enroll-'));
const HOME = path.join(ROOT, 'home');
fs.mkdirSync(HOME, { recursive: true });
const ENV = { ...process.env, HOME, USERPROFILE: HOME, APPDATA: path.join(HOME, 'AppData'), LOCALAPPDATA: path.join(HOME, 'Local'), XDG_CONFIG_HOME: path.join(HOME, '.config') };
const children = [];
const CREATED = []; // bridge ids whose scoped credentials this run wrote

async function startHub(label) {
  const bin = process.env.HEIMDALL_E2E_HUB_BIN;
  const migrations = path.join(REPO_ROOT, 'src', 'hub', 'repository', 'sqlite', 'migrations');
  const dir = path.join(ROOT, label);
  fs.mkdirSync(dir, { recursive: true });
  const port = await freePort();
  const log = fs.openSync(path.join(dir, 'hub.log'), 'w');
  const child = spawn(bin, ['--listen', `127.0.0.1:${port}`, '--db', path.join(dir, 'hub.db'), '--migrations-dir', migrations, '--trusted-proxy-cidr', '127.0.0.1/32', '--ui-origin', `http://127.0.0.1:${port}`],
    { cwd: dir, env: ENV, stdio: ['ignore', log, log] });
  children.push(child);
  const base = `http://127.0.0.1:${port}`;
  for (const deadline = Date.now() + 30_000; ;) {
    try { if ((await fetch(`${base}/api/v1/health`)).ok) break; } catch { /* starting */ }
    if (Date.now() > deadline) throw new Error(`${label} did not start`);
    await sleep(150);
  }
  return { base, port };
}

async function http(hub, method, p, { body, headers = {} } = {}) {
  const h = { 'X-authentik-username': USER, ...headers };
  const text = body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body));
  if (text !== undefined) h['Content-Type'] = 'application/json';
  const res = await fetch(`${hub.base}${p}`, { method, headers: h, body: text });
  const raw = await res.text();
  let json = null;
  try { json = JSON.parse(raw); } catch { /* not JSON */ }
  return { status: res.status, data: json?.data, raw };
}

// The approving browser of this hub's account (genesis), holding the keyring.
async function approverFor(hub) {
  const me = await http(hub, 'GET', '/api/v1/me');
  const userId = me.data.user_id;
  const identity = await createDeviceIdentity(memoryDeviceStore(), userId);
  const g = await http(hub, 'POST', '/api/v1/vault/directory/genesis', { body: await buildGenesis(identity, 'e2e approver') });
  if (g.status !== 201) throw new Error(`genesis ${g.status} ${g.raw}`);
  const signed = async (method, p, body = '') => signedRequestHeaders({ deviceId: identity.deviceId, signPrivateKey: identity.signPrivateKey }, userId, method, p, body);
  const chain = async () => verifyDirectory((await http(hub, 'GET', '/api/v1/vault/directory')).data, userId, null);
  const self = await http(hub, 'GET', '/api/v1/vault/devices/self', { headers: await signed('GET', '/api/v1/vault/devices/self') });
  const parsed = await openVerifiedWrap(self.data.wrap, { userId, recipientDeviceId: identity.deviceId, recipientEcdhPrivate: identity.ecdhPrivateKey, chain: await chain() });
  const keyringBytes = serializeKeyringBytes(parsed);
  for (const e of parsed.entries) e.key.fill(0);
  return { userId, identity, chain, keyringBytes };
}

function bridgeArgs(cfg) {
  return ['--config', cfg.config, '--bridge-token-file', cfg.token, '--port', String(cfg.port), '--data-dir', cfg.data];
}

async function newBridgeDirs(label) {
  const dir = path.join(ROOT, label);
  fs.mkdirSync(dir, { recursive: true });
  return { dir, config: path.join(dir, 'config.toml'), token: path.join(dir, 'bridge.token'), data: path.join(dir, 'data'), port: await freePort() };
}

// Runs `ham-bridge enroll`, reads the pairing code from its stdout, approves it like
// the /device/add page (typed once) and delivers the first unseal with the pair_mac.
async function enroll(hub, approver, cfg) {
  const bin = process.env.HEIMDALL_E2E_BRIDGE_BIN;
  let out = '';
  const child = spawn(bin, ['enroll', '--hub', hub.base, '--headless', ...bridgeArgs(cfg)], { cwd: cfg.dir, env: ENV, stdio: ['ignore', 'pipe', 'pipe'] });
  children.push(child);
  child.stdout.on('data', (d) => { out += d; });
  child.stderr.on('data', (d) => { out += d; });
  const exited = new Promise((r) => child.once('exit', (code) => r(code)));
  let code = null;
  for (const deadline = Date.now() + 30_000; !code; await sleep(100)) {
    code = (/^\s+([A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{2})\s*$/m.exec(out) || [])[1] ?? null;
    if (Date.now() > deadline) throw new CheckFailed(`no pairing code printed:\n${out}`);
  }
  expect(!/code=/.test(out), `ham-bridge printed a pairing code and a code-free link (${code.slice(0, 4)}-…)`);
  // As the approval page does: fetch the public pair_salts, run the pairing stretch
  // (bound to this hub's origin) per candidate, resolve the matching lookup.
  const salts = await http(hub, 'POST', '/api/v1/device/pair-salts', { body: {} });
  const tried = [];
  for (const c of (salts.data?.candidates ?? []).filter((x) => x.kind === 'bridge')) {
    tried.push({ salt: c.pair_salt, keys: await derivePairKeys(code, { kind: 'bridge', userId: '', hubOrigin: pairHubOrigin(hub.base), pairSalt: c.pair_salt }) });
  }
  const ver = await http(hub, 'POST', '/api/v1/device/verify', { body: { pair_lookups: tried.map((c) => c.keys.lookup) } });
  const keys = tried.find((c) => c.salt === ver.data?.pair_salt)?.keys;
  expect(ver.status === 200 && ver.data.kind === 'bridge' && keys, `the typed code resolves the bridge (${ver.status})`);
  await checkBridgeCodeInfo(ver.data, keys);
  const chain = await approver.chain();
  const { vault_approval, statement } = await buildBridgeApproval(approver.identity, chain, ver.data, cfg.dir.split(/[\\/]/).pop());
  const appr = await http(hub, 'POST', '/api/v1/device/approve', { body: { pair_lookup: keys.lookup, approve: true, vault_approval, new_bridge_label: 'real-enroll' } });
  const bridgeId = appr.data?.hub_observed?.bridge_id;
  expect(appr.status === 200 && bridgeId, `approved -> ${bridgeId}`);
  CREATED.push(bridgeId);
  // Wait for the enrolling process's enroll-only connection (it serves the unseal).
  let target = null;
  for (const deadline = Date.now() + 30_000; ; await sleep(250)) {
    const pk = await http(hub, 'GET', `/api/v1/bridges/${bridgeId}/public-key?enrollment=1`);
    if (pk.status === 200 && pk.data?.unseal_key_signature) { target = bridgeUnsealTargetFromRecord(bridgeId, pk.data); break; }
    if (Date.now() > deadline) throw new CheckFailed(`the enrolling bridge never connected:\n${out}`);
  }
  const after = await approver.chain();
  const pairMac = await pairApproveMac(keys, statement, after.rootSignPub);
  await deliverKeyringToBridge(bridgeId, after, {
    fetchTarget: async () => target,
    dispatch: async (id, payload) => {
      const r = await http(hub, 'POST', `/api/v1/bridges/${id}/unseal`, { body: payload });
      if (r.status !== 200 || r.data?.ok === false) throw new Error(`unseal refused: ${r.status} ${r.raw}`);
      return r.data;
    },
    withKeyringBytes: async (fn) => { const b = Uint8Array.from(approver.keyringBytes); try { return await fn(b); } finally { b.fill(0); } },
  }, { enrollment: true, expectedPublicKey: target.publicKey, extra: { enrollment: true, expected_public_key: target.publicKey, pair_mac: pairMac } });
  const exitCode = await Promise.race([exited, sleep(30_000).then(() => 'timeout')]);
  expect(/bridge enroll SUCCESS/.test(out), `ham-bridge enroll reports SUCCESS (exit ${exitCode}; the Windows service restart is not supported, so 1/3 is expected after success)`);
  expect(fs.existsSync(cfg.config) && fs.readFileSync(cfg.config, 'utf8').includes(hub.base), 'the written config points the runtime at exactly that hub');
  return { bridgeId, out };
}

// Starts the runtime; resolves with { refused, out } once it either exits or connects.
async function runtime(cfg, extra = [], waitConnected = null) {
  const bin = process.env.HEIMDALL_E2E_BRIDGE_BIN;
  let out = '';
  const child = spawn(bin, [...bridgeArgs(cfg), ...extra], { cwd: cfg.dir, env: ENV, stdio: ['ignore', 'pipe', 'pipe'] });
  children.push(child);
  child.stdout.on('data', (d) => { out += d; });
  child.stderr.on('data', (d) => { out += d; });
  let exitCode = null;
  child.once('exit', (c) => { exitCode = c; });
  for (const deadline = Date.now() + 20_000; ; await sleep(200)) {
    if (exitCode !== null) return { refused: true, exitCode, out, child };
    if (waitConnected && await waitConnected()) return { refused: false, out, child };
    if (!waitConnected && /ham-bridge listening/.test(out)) return { refused: false, out, child };
    if (Date.now() > deadline) return { refused: false, timeout: true, out, child };
  }
}

const online = (hub, bridgeId) => async () => {
  const r = await http(hub, 'GET', '/api/v1/bridges');
  const list = Array.isArray(r.data) ? r.data : (r.data?.bridges ?? []);
  return list.some((b) => b.bridge_id === bridgeId && (b.status === 'online' || b.connected === true));
};

async function main() {
  if (!process.env.HEIMDALL_E2E_HUB_BIN || !process.env.HEIMDALL_E2E_BRIDGE_BIN) throw new Error('set HEIMDALL_E2E_HUB_BIN and HEIMDALL_E2E_BRIDGE_BIN');
  const hubA = await startHub('hub-a');
  const hubB = await startHub('hub-b');
  console.log(`throwaway hubs ${hubA.base} ${hubB.base}; temp root ${ROOT}`);
  const S = {};
  await step('1 real enroll against hub A: one pairing code, first unseal with pair_mac', async () => {
    S.apA = await approverFor(hubA);
    S.cfgA = await newBridgeDirs('bridge-a');
    S.a = await enroll(hubA, S.apA, S.cfgA);
  });
  await step('2 the enrolled runtime starts bound to hub A and connects', async () => {
    const r = await runtime(S.cfgA, [], online(hubA, S.a.bridgeId));
    expect(!r.refused && !r.timeout, `runtime A is online on hub A (${r.refused ? 'refused: ' + r.out : 'ok'})`);
    S.runA = r.child;
    const second = await runtime({ ...S.cfgA, port: await freePort() });
    expect(second.refused && /another ham-bridge instance/i.test(second.out), 'a second instance on the same config refuses (instance lock)');
  });
  await step('3 the same bridge pointed at another hub refuses to start', async () => {
    S.runA?.kill();
    await sleep(500);
    const r = await runtime({ ...S.cfgA, port: await freePort() }, ['--hub', hubB.base]);
    expect(r.refused && /REFUSING TO START/.test(r.out) && /bound to\s+exactly one hub|holds no readable enrollment/i.test(r.out), `hub mismatch -> refused (exit ${r.exitCode})`);
  });
  await step('4 a second bridge enrolls against hub B on the same machine; bridge A is untouched', async () => {
    const intoA = spawnSync(process.env.HEIMDALL_E2E_BRIDGE_BIN, ['enroll', '--hub', hubB.base, '--headless', ...bridgeArgs(S.cfgA)], { cwd: S.cfgA.dir, env: ENV, encoding: 'utf8', timeout: 20_000 });
    expect(/REFUSED: config .* belongs to a bridge enrolled with/.test(intoA.stdout + intoA.stderr), 'enrolling hub B into bridge A\'s config is refused');
    S.apB = await approverFor(hubB);
    S.cfgB = await newBridgeDirs('bridge-b');
    S.b = await enroll(hubB, S.apB, S.cfgB);
    const rb = await runtime(S.cfgB, [], online(hubB, S.b.bridgeId));
    expect(!rb.refused && !rb.timeout, 'runtime B is online on hub B');
    const ra = await runtime({ ...S.cfgA, port: await freePort() }, [], online(hubA, S.a.bridgeId));
    expect(!ra.refused && !ra.timeout, 'bridge A still starts and connects to hub A after bridge B enrolled');
  });
}

function cleanupCredentials() {
  if (process.platform !== 'win32') return;
  const ids = CREATED;
  const list = spawnSync('cmdkey', ['/list'], { encoding: 'utf8' }).stdout || '';
  let removed = 0;
  for (const m of list.matchAll(/Target:\s*(?:LegacyGeneric:target=)?(\S+)/g)) {
    const target = m[1];
    if (target.startsWith('works.earendil.heimdall-bridge.') && ids.some((id) => target.includes(`:${id}_`))) {
      spawnSync('cmdkey', [`/delete:${target}`]);
      removed += 1;
    }
  }
  console.log(`removed ${removed} scoped credential(s) this run created`);
}

try {
  await main();
} catch (err) {
  results.push(['setup', 'FAIL']);
  console.log(`FAIL setup: ${err?.stack || err}`);
} finally {
  for (const c of children) { try { c.kill(); } catch { /* gone */ } }
  await sleep(500);
  cleanupCredentials();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch { console.log(`(could not remove ${ROOT})`); }
}
console.log('\n== summary');
for (const [name, r] of results) console.log(`${r} ${name}`);
const failed = results.filter(([, r]) => r !== 'PASS').length;
console.log(failed ? `${failed} step(s) FAILED` : 'all steps PASSED');
process.exitCode = failed ? 1 : 0;

