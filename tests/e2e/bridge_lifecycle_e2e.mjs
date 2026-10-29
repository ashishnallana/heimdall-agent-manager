// Bridge lifecycle e2e (T12, REQ-ENR-1/3/6) on the real binaries against a THROWAWAY
// hub (ephemeral port, temp DB, mock OIDC), for one bridge PROFILE (the layout
// `ham-bridge setup` installs: <state_root>/<service>/{config.toml,bridge-token} and
// <data>/bridges/<service>):
//   1 enroll as account A (pairing code -> /device/add approval -> first unseal);
//   2 the runtime connects;
//   3 re-enroll as the SAME account (approver reuses the bridge id);
//   4 replace with account B (--replace-other-account): A's bridge is revoked on the
//     hub and A's local secrets are wiped before B's credential is written;
//   5 update (opt-in, HEIMDALL_E2E_SERVICE=1 on a CI runner with a service manager):
//     `ham-bridge setup` installs the profile service, `ham-bridge update --bundle`
//     re-installs it from a bundle dir and it comes back connected;
//   6 `ham-bridge uninstall --purge`: afterwards no profile files, no per-bridge
//     secret dirs, no OS secret-store items (Linux user keyring, macOS Keychain,
//     Windows Credential Manager), no service unit, and no active hub row remain.
// Hermetic: HOME/USERPROFILE/APPDATA point into a temp dir. The OS secret stores are
// real but every item is named by a bridge id this run created; they are listed
// (and on failure deleted) by that id only. Never touches a running dev hub/bridge.
//
//   HEIMDALL_E2E_HUB_BIN=<ham-hub> HEIMDALL_E2E_BRIDGE_BIN=<ham-bridge> \
//   node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/bridge_lifecycle_e2e.mjs

import { spawn, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { createDeviceIdentity, memoryDeviceStore } from '../../src/ui/utils/deviceIdentity.ts';
import { signedRequestHeaders } from '../../src/ui/utils/vaultRequestSigner.ts';
import { hubLogin, sessionHeaders, startMockOidc } from './hubOidc.mjs';
import { verifyDirectory } from '../../src/ui/utils/vaultDirectoryVerify.ts';
import { openVerifiedWrap } from '../../src/ui/utils/vaultKeyringWrap.ts';
import { serializeKeyringBytes } from '../../src/ui/utils/vaultKeyring.ts';
import { deliverKeyringToBridge } from '../../src/ui/utils/vaultBridgeDelivery.ts';
import { bridgeUnsealTargetFromRecord } from '../../src/ui/utils/vaultBridgeUnseal.ts';
import { buildBridgeApproval, buildGenesis, checkBridgeCodeInfo } from '../../src/ui/utils/vaultDeviceFlows.ts';
import { derivePairKeys, pairApproveMac, pairHubOrigin } from '../../src/ui/utils/vaultPairing.ts';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const BRIDGE_BIN = process.env.HEIMDALL_E2E_BRIDGE_BIN;
const WITH_SERVICE = process.env.HEIMDALL_E2E_SERVICE === '1';
const WIN = process.platform === 'win32';
const MAC = process.platform === 'darwin';
const results = [];
class CheckFailed extends Error {}
const expect = (cond, msg) => { if (!cond) throw new CheckFailed(msg); console.log(`    ok - ${msg}`); };
async function step(name, fn, { skip = '' } = {}) {
  console.log(`\n== ${name}`);
  if (skip) { results.push([name, 'SKIP']); console.log(`SKIP ${name} (${skip})`); return; }
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

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-lifecycle-'));
const HOME = path.join(ROOT, 'home');
fs.mkdirSync(HOME, { recursive: true });
const ENV = { ...process.env, HOME, USERPROFILE: HOME, APPDATA: path.join(HOME, 'AppData'), LOCALAPPDATA: path.join(HOME, 'Local'), XDG_CONFIG_HOME: path.join(HOME, '.config') };
const children = [];
const CREATED = []; // every bridge id this run enrolled

// The profile layout bridgesvc.layout_for gives this service name.
const SERVICE = `heimdall-bridge-e2e${crypto.randomBytes(3).toString('hex')}`;
const STATE_ROOT = WIN ? path.join(ENV.APPDATA, 'heimdall', 'bridges') : path.join(HOME, '.config', 'heimdall', 'bridges');
const PROFILE = {
  dir: path.join(STATE_ROOT, SERVICE),
  config: path.join(STATE_ROOT, SERVICE, 'config.toml'),
  token: path.join(STATE_ROOT, SERVICE, 'bridge-token'),
  data: WIN ? path.join(ENV.LOCALAPPDATA, 'heimdall', 'bridges', SERVICE) : path.join(HOME, '.local', 'share', 'heimdall', 'bridges', SERVICE),
};
const SERVICE_FILE = WIN ? '' : MAC ? path.join(HOME, 'Library', 'LaunchAgents', `${SERVICE}.plist`) : path.join(HOME, '.config', 'systemd', 'user', `${SERVICE}.service`);

async function startHub(label) {
  const bin = process.env.HEIMDALL_E2E_HUB_BIN;
  const migrations = path.join(REPO_ROOT, 'src', 'hub', 'repository', 'sqlite', 'migrations');
  const dir = path.join(ROOT, label);
  fs.mkdirSync(dir, { recursive: true });
  const port = await freePort();
  const log = fs.openSync(path.join(dir, 'hub.log'), 'w');
  const mock = await startMockOidc();
  children.push({ kill: mock.stop });
  const base = `http://127.0.0.1:${port}`;
  const child = spawn(bin, ['--listen', `127.0.0.1:${port}`, '--db', path.join(dir, 'hub.db'), '--migrations-dir', migrations, '--ui-origin', base],
    { cwd: dir, env: { ...ENV, ...mock.hubEnv(base) }, stdio: ['ignore', log, log] });
  children.push(child);
  for (const deadline = Date.now() + 30_000; ;) {
    try { if ((await fetch(`${base}/api/v1/health`)).ok) break; } catch { /* starting */ }
    if (Date.now() > deadline) throw new Error(`${label} did not start`);
    await sleep(150);
  }
  return { base, port };
}

async function http(acct, method, p, { body, headers = {} } = {}) {
  const h = { ...sessionHeaders(acct.session, acct.base), ...headers };
  const text = body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body));
  if (text !== undefined) h['Content-Type'] = 'application/json';
  const res = await fetch(`${acct.base}${p}`, { method, headers: h, body: text });
  const raw = await res.text();
  let json = null;
  try { json = JSON.parse(raw); } catch { /* not JSON */ }
  return { status: res.status, data: json?.data, raw };
}

// One signed-in account of the hub with its approving browser (genesis, keyring).
async function account(hub, user) {
  const acct = { base: hub.base, session: await hubLogin(hub.base, user) };
  const me = await http(acct, 'GET', '/api/v1/me');
  const userId = me.data.user_id;
  const identity = await createDeviceIdentity(memoryDeviceStore(), userId);
  const g = await http(acct, 'POST', '/api/v1/vault/directory/genesis', { body: await buildGenesis(identity, `e2e approver ${user}`) });
  if (g.status !== 201) throw new Error(`genesis ${g.status} ${g.raw}`);
  const signed = async (m, p, b = '') => signedRequestHeaders({ deviceId: identity.deviceId, signPrivateKey: identity.signPrivateKey }, userId, m, p, b);
  const chain = async () => verifyDirectory((await http(acct, 'GET', '/api/v1/vault/directory')).data, userId, null);
  const self = await http(acct, 'GET', '/api/v1/vault/devices/self', { headers: await signed('GET', '/api/v1/vault/devices/self') });
  const parsed = await openVerifiedWrap(self.data.wrap, { userId, recipientDeviceId: identity.deviceId, recipientEcdhPrivate: identity.ecdhPrivateKey, chain: await chain() });
  const keyringBytes = serializeKeyringBytes(parsed);
  for (const e of parsed.entries) e.key.fill(0);
  return { ...acct, userId, identity, chain, keyringBytes };
}

const profileArgs = (port) => ['--config', PROFILE.config, '--bridge-token-file', PROFILE.token, '--port', String(port), '--data-dir', PROFILE.data];

// `ham-bridge enroll` into the profile; the approval runs like /device/add (code typed
// once, signed vault approval, first unseal with pair_mac). reuse: approve onto that id.
async function enroll(hub, acct, { extra = [], reuse = '' } = {}) {
  fs.mkdirSync(PROFILE.dir, { recursive: true });
  let out = '';
  const child = spawn(BRIDGE_BIN, ['enroll', '--hub', hub.base, '--headless', ...extra, ...profileArgs(await freePort())], { cwd: ROOT, env: ENV, stdio: ['ignore', 'pipe', 'pipe'] });
  children.push(child);
  child.stdout.on('data', (d) => { out += d; });
  child.stderr.on('data', (d) => { out += d; });
  const exited = new Promise((r) => child.once('exit', (code) => r(code)));
  try {
    return await approveEnrollment(hub, acct, { child, exited, out: () => out, reuse });
  } catch (err) {
    await stop(child);
    throw err;
  }
}

async function approveEnrollment(hub, acct, { exited, out: output, reuse }) {
  let code = null;
  let out = output();
  for (const deadline = Date.now() + 30_000; !code; await sleep(100)) {
    out = output();
    code = (/^\s+([A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{2})\s*$/m.exec(out) || [])[1] ?? null;
    if (Date.now() > deadline) throw new CheckFailed(`no pairing code printed:\n${out}`);
  }
  const salts = await http(acct, 'POST', '/api/v1/device/pair-salts', { body: {} });
  const tried = [];
  for (const c of (salts.data?.candidates ?? []).filter((x) => x.kind === 'bridge')) {
    tried.push({ salt: c.pair_salt, keys: await derivePairKeys(code, { kind: 'bridge', userId: '', hubOrigin: c.pair_hub_origin, pairSalt: c.pair_salt }) });
  }
  const ver = await http(acct, 'POST', '/api/v1/device/verify', { body: { pair_lookups: tried.map((c) => c.keys.lookup) } });
  const keys = tried.find((c) => c.salt === ver.data?.pair_salt)?.keys;
  expect(ver.status === 200 && ver.data.kind === 'bridge' && keys, `the typed code resolves the bridge (${ver.status})`);
  await checkBridgeCodeInfo(ver.data, keys);
  const { vault_approval, statement } = await buildBridgeApproval(acct.identity, await acct.chain(), ver.data, SERVICE);
  const body = { pair_lookup: keys.lookup, approve: true, vault_approval, ...(reuse ? { target_bridge_id: reuse } : { new_bridge_label: 'lifecycle' }) };
  const appr = await http(acct, 'POST', '/api/v1/device/approve', { body });
  const bridgeId = appr.data?.hub_observed?.bridge_id;
  expect(appr.status === 200 && bridgeId, `approved -> ${bridgeId} (${appr.status} ${appr.status === 200 ? '' : appr.raw})`);
  if (!CREATED.includes(bridgeId)) CREATED.push(bridgeId);
  let target = null;
  for (const deadline = Date.now() + 30_000; ; await sleep(250)) {
    const pk = await http(acct, 'GET', `/api/v1/bridges/${bridgeId}/public-key?enrollment=1`);
    if (pk.status === 200 && pk.data?.unseal_key_signature) { target = bridgeUnsealTargetFromRecord(bridgeId, pk.data); break; }
    if (Date.now() > deadline) throw new CheckFailed(`the enrolling bridge never connected:\n${output()}`);
  }
  const after = await acct.chain();
  const pairMac = await pairApproveMac(keys, statement, after.rootSignPub);
  await deliverKeyringToBridge(bridgeId, after, {
    fetchTarget: async () => target,
    dispatch: async (id, payload) => {
      const r = await http(acct, 'POST', `/api/v1/bridges/${id}/unseal`, { body: payload });
      if (r.status !== 200 || r.data?.ok === false) throw new Error(`unseal refused: ${r.status} ${r.raw}`);
      return r.data;
    },
    withKeyringBytes: async (fn) => { const b = Uint8Array.from(acct.keyringBytes); try { return await fn(b); } finally { b.fill(0); } },
  }, { enrollment: true, identityPublicKey: ver.data.bridge_identity_public_key, expectedPublicKey: target.publicKey, extra: { enrollment: true, expected_public_key: target.publicKey, pair_mac: pairMac } });
  const exitCode = await Promise.race([exited, sleep(30_000).then(() => 'timeout')]);
  out = output();
  expect(/bridge enroll SUCCESS/.test(out) && exitCode === 0, `ham-bridge enroll reports SUCCESS and exits 0 (exit ${exitCode})${exitCode === 0 ? '' : '\n' + out}`);
  expect(fs.readFileSync(PROFILE.config, 'utf8').includes(hub.base), 'the profile config points at that hub');
  return { bridgeId, out };
}

async function runtime(waitConnected) {
  let out = '';
  const child = spawn(BRIDGE_BIN, profileArgs(await freePort()), { cwd: ROOT, env: ENV, stdio: ['ignore', 'pipe', 'pipe'] });
  children.push(child);
  child.stdout.on('data', (d) => { out += d; });
  child.stderr.on('data', (d) => { out += d; });
  let exitCode = null;
  child.once('exit', (c) => { exitCode = c; });
  for (const deadline = Date.now() + 20_000; ; await sleep(200)) {
    if (exitCode !== null) return { ok: false, out, child };
    if (await waitConnected()) return { ok: true, out, child };
    if (Date.now() > deadline) return { ok: false, out, child };
  }
}
async function stop(child) {
  if (!child || child.exitCode !== null) return;
  const gone = new Promise((r) => child.once('exit', r));
  child.kill();
  await Promise.race([gone, sleep(10_000)]);
}

async function bridgesOf(acct) {
  const r = await http(acct, 'GET', '/api/v1/bridges');
  return Array.isArray(r.data) ? r.data : (r.data?.bridges ?? []);
}
const isActive = (b) => !b.revoked_at && b.status !== 'revoked';
const online = (acct, id) => async () => (await bridgesOf(acct)).some((b) => b.bridge_id === id && (b.status === 'online' || b.runtime_connected === true));

// OS secret-store items named by one bridge id (keystore_<os>.odin).
function secretItems(bridgeId) {
  if (WIN) {
    const list = spawnSync('cmdkey', ['/list'], { encoding: 'utf8' }).stdout || '';
    return [...list.matchAll(/Target:\s*(?:LegacyGeneric:target=)?(\S+)/g)].map((m) => m[1])
      .filter((t) => t.startsWith('works.earendil.heimdall-bridge.') && t.includes(bridgeId));
  }
  if (MAC) {
    const found = [];
    for (const svc of ['vault-keyring', 'vault-identity', 'vault-epoch-floor', 'vault-identity-previous', 'vault-epoch-floor-previous']) {
      const r = spawnSync('security', ['find-generic-password', '-s', `works.earendil.heimdall-bridge.${svc}`, '-a', bridgeId], { encoding: 'utf8' });
      if (r.status === 0) found.push(`${svc}:${bridgeId}`);
    }
    return found;
  }
  let keys = '';
  try { keys = fs.readFileSync('/proc/keys', 'utf8'); } catch { /* no procfs */ }
  // /proc/keys lists a revoked (R) or dead (D) key until the keyring GC runs
  // (key_gc_delay); its payload is already gone, so only live keys count.
  return keys.split('\n').filter((l) => l.includes('heimdall:') && l.includes(bridgeId))
    .filter((l) => !/[RD]/.test(l.trim().split(/\s+/)[1] || ''));
}
// Per-bridge secret dirs (bridge_vault_bridge_dir of the keystore scope name
// <bridge_id>_<scope>: identity_key, epoch_floor, default credential), with their files.
const bridgeSecretFiles = (id) => (fs.existsSync(STATE_ROOT) ? fs.readdirSync(STATE_ROOT) : [])
  .filter((d) => d === id || d.startsWith(`${id}_`))
  .flatMap((d) => { const full = path.join(STATE_ROOT, d); return [d, ...fs.readdirSync(full).map((f) => `${d}/${f}`)]; });

async function main() {
  if (!process.env.HEIMDALL_E2E_HUB_BIN || !BRIDGE_BIN) throw new Error('set HEIMDALL_E2E_HUB_BIN and HEIMDALL_E2E_BRIDGE_BIN');
  const hub = await startHub('hub');
  console.log(`throwaway hub ${hub.base}; profile ${SERVICE}; temp root ${ROOT}`);
  const A = await account(hub, 'e2e-lifecycle-a');
  const B = await account(hub, 'e2e-lifecycle-b');
  const S = {};
  await step('1 enroll as account A into the bridge profile', async () => {
    S.first = await enroll(hub, A);
    expect(fs.existsSync(PROFILE.token), 'the credential is written into the profile');
  });
  await step('2 the enrolled runtime connects to the hub', async () => {
    const r = await runtime(online(A, S.first.bridgeId));
    expect(r.ok, `runtime online as ${S.first.bridgeId}${r.ok ? '' : '\n' + r.out}`);
    await stop(r.child);
  });
  await step('3 re-enroll as the same account reuses the bridge', async () => {
    const again = await enroll(hub, A, { reuse: S.first.bridgeId });
    expect(again.bridgeId === S.first.bridgeId, `the approver reused ${S.first.bridgeId} (got ${again.bridgeId})`);
    const active = (await bridgesOf(A)).filter(isActive);
    expect(active.length === 1 && active[0].bridge_id === S.first.bridgeId, `account A has exactly one active bridge (${active.map((b) => b.bridge_id)})`);
    const r = await runtime(online(A, S.first.bridgeId));
    expect(r.ok, 'the re-enrolled runtime connects');
    await stop(r.child);
  });
  await step('4 replace with account B: A revoked on the hub, A secrets wiped', async () => {
    S.b = await enroll(hub, B, { extra: ['--replace-other-account'] });
    expect(S.b.bridgeId !== S.first.bridgeId, `account B got its own bridge ${S.b.bridgeId}`);
    expect((await bridgesOf(A)).filter(isActive).length === 0, 'account A has no active bridge left on the hub');
    expect(secretItems(S.first.bridgeId).length === 0, `no OS secret-store item of A's bridge remains (${secretItems(S.first.bridgeId)})`);
    expect(bridgeSecretFiles(S.first.bridgeId).length === 0, `A's per-bridge secret dir is gone (${bridgeSecretFiles(S.first.bridgeId)})`);
    const r = await runtime(online(B, S.b.bridgeId));
    expect(r.ok, `the runtime connects as account B${r.ok ? '' : '\n' + r.out}`);
    await stop(r.child);
  });
  await step('5 setup installs the profile service; update re-installs it and it reconnects', async () => {
    const bundle = path.dirname(BRIDGE_BIN);
    const setup = spawnSync(BRIDGE_BIN, ['setup', '--hub', hub.base, '--headless', '--no-tray', '--json-progress', '--reuse-bridge', S.b.bridgeId], { env: ENV, encoding: 'utf8', timeout: 180_000 });
    expect(setup.status === 0, `ham-bridge setup exits 0 (exit ${setup.status})\n${setup.stdout}${setup.stderr}`);
    const upd = spawnSync(BRIDGE_BIN, ['update', '--bundle', bundle, '--hub', hub.base, '--json-progress'], { env: ENV, encoding: 'utf8', timeout: 300_000 });
    expect(upd.status === 0, `ham-bridge update --bundle exits 0 (exit ${upd.status})\n${upd.stdout}${upd.stderr}`);
    for (const deadline = Date.now() + 60_000; !(await online(B, S.b.bridgeId)()); await sleep(500)) {
      if (Date.now() > deadline) throw new CheckFailed('the updated service never reconnected');
    }
  }, { skip: WITH_SERVICE ? '' : 'needs a service manager; set HEIMDALL_E2E_SERVICE=1 (CI runners)' });
  await step('6 uninstall --purge leaves no files, secrets, service or active hub row', async () => {
    const un = spawnSync(BRIDGE_BIN, ['uninstall', '--service', SERVICE, '--purge', '--yes', '--headless', '--json-progress'], { env: ENV, encoding: 'utf8', timeout: 120_000 });
    expect(un.status === 0, `ham-bridge uninstall --purge exits 0 (exit ${un.status})${un.status === 0 ? '' : '\n' + un.stdout + un.stderr}`);
    // The Windows uninstall re-executes from %TEMP% and returns first; let it finish.
    for (const deadline = Date.now() + 60_000; fs.existsSync(PROFILE.dir) || fs.existsSync(PROFILE.data); await sleep(500)) {
      if (Date.now() > deadline) break;
    }
    expect(!fs.existsSync(PROFILE.dir), `profile state dir removed (${PROFILE.dir})`);
    expect(!fs.existsSync(PROFILE.data), `profile data dir removed (${PROFILE.data})`);
    if (SERVICE_FILE) expect(!fs.existsSync(SERVICE_FILE), `service unit removed (${SERVICE_FILE})`);
    if (WIN) expect(spawnSync('schtasks', ['/Query', '/TN', SERVICE], { encoding: 'utf8' }).status !== 0, 'no scheduled task remains');
    if (MAC) expect(spawnSync('launchctl', ['print', `gui/${process.getuid()}/${SERVICE}`]).status !== 0, 'no launchd job remains');
    if (!WIN && !MAC && WITH_SERVICE) expect(spawnSync('systemctl', ['--user', 'cat', `${SERVICE}.service`]).status !== 0, 'no systemd user unit remains');
    for (const id of CREATED) {
      expect(secretItems(id).length === 0, `no OS secret-store item for ${id} (${secretItems(id)})`);
      expect(bridgeSecretFiles(id).length === 0, `no per-bridge secret dir for ${id} (${bridgeSecretFiles(id)})`);
    }
    const activeB = (await bridgesOf(B)).filter(isActive);
    const activeA = (await bridgesOf(A)).filter(isActive);
    expect(activeA.length === 0 && activeB.length === 0, `no active hub bridge row for either account (A ${activeA.length}, B ${activeB.length})`);
    const leftovers = fs.existsSync(STATE_ROOT) ? fs.readdirSync(STATE_ROOT) : [];
    expect(leftovers.length === 0, `nothing left under ${STATE_ROOT} (${leftovers})`);
  });
}

// On failure, delete the secret-store items this run's bridge ids own.
function cleanupSecrets() {
  for (const id of CREATED) {
    for (const item of secretItems(id)) {
      if (WIN) spawnSync('cmdkey', [`/delete:${item}`]);
      else if (MAC) { const [svc] = item.split(':'); spawnSync('security', ['delete-generic-password', '-s', `works.earendil.heimdall-bridge.${svc}`, '-a', id]); }
      else { const kid = item.trim().split(/\s+/)[0]; spawnSync('keyctl', ['unlink', `0x${kid}`, '@u']); }
    }
  }
  if (WITH_SERVICE) spawnSync(BRIDGE_BIN, ['uninstall', '--service', SERVICE, '--purge', '--yes', '--headless'], { env: ENV, timeout: 60_000 });
}

try {
  await main();
} catch (err) {
  results.push(['setup', 'FAIL']);
  console.log(`FAIL setup: ${err?.stack || err}`);
} finally {
  for (const c of children) { try { c.kill(); } catch { /* gone */ } }
  await sleep(500);
  if (results.some(([, r]) => r === 'FAIL')) cleanupSecrets();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch { console.log(`(could not remove ${ROOT})`); }
}
console.log('\n== summary');
for (const [name, r] of results) console.log(`${r} ${name}`);
const failed = results.filter(([, r]) => r === 'FAIL').length;
console.log(failed ? `${failed} step(s) FAILED` : 'all steps PASSED (SKIP = not run on this host)');
process.exitCode = failed ? 1 : 0;
