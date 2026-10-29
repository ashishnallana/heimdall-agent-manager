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
//     Windows Credential Manager), no service unit, and no active hub row remain;
//   7-11 (with HEIMDALL_E2E_SERVICE=1) the same lifecycle for a second profile, driven
//     through the desktop app's main-process bridgeManager.runOperation: setup wizard
//     (pairing event) -> re-enroll -> replace other account -> update -> uninstall.
// Hermetic: HOME/USERPROFILE/APPDATA point into a temp dir (with HEIMDALL_E2E_SERVICE=1
// the real home, see HOME below). The OS secret stores are
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

// Nothing of the caller's own bridge may reach the binaries under test. A shell the
// bridge spawned exports HEIMDALL_BRIDGE_SERVICE_NAME, and `ham-bridge enroll` stops and
// restarts that service as its own when the profile has none registered yet
// (bridge_enroll_service_for): with the real home that is the bridge running this test.
// Scrubbed from process.env itself because bridgeManager (steps 7-11) inherits it.
for (const k of Object.keys(process.env)) {
  const u = k.toUpperCase();
  if (u.startsWith('HEIMDALL_') && !u.startsWith('HEIMDALL_E2E_')) delete process.env[k];
}

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-lifecycle-'));
// A service manager (systemd --user, launchd, Task Scheduler) starts the bridge with
// the user's REAL HOME/APPDATA (service_env sets neither), and the runtime finds its
// per-bridge secrets under ~ (bridge_vault_bridge_dir). So with HEIMDALL_E2E_SERVICE=1
// (ephemeral CI runners) the whole run uses the real home; every path, service and
// secret is still named by this run's profile/bridge ids and removed by them only.
// macOS keeps the user's keychains and keychain search list under ~/Library; with
// a temp HOME the Security framework finds no default keychain and
// SecKeychainAddGenericPassword stalls the enroll silently. Point the temp HOME at
// the real ones (items are named by this run's bridge ids and removed by them).
function linkMacKeychains(home) {
  if (process.platform !== 'darwin') return;
  const real = os.homedir();
  fs.mkdirSync(path.join(home, 'Library', 'Preferences'), { recursive: true });
  for (const rel of [['Library', 'Keychains'], ['Library', 'Preferences', 'com.apple.security.plist']]) {
    const src = path.join(real, ...rel);
    const dst = path.join(home, ...rel);
    if (fs.existsSync(src) && !fs.existsSync(dst)) fs.symlinkSync(src, dst);
  }
}
const HOME = WITH_SERVICE ? os.homedir() : path.join(ROOT, 'home');
fs.mkdirSync(HOME, { recursive: true });
if (!WITH_SERVICE) linkMacKeychains(HOME);
const ENV = WITH_SERVICE ? { ...process.env }
  : { ...process.env, HOME, USERPROFILE: HOME, APPDATA: path.join(HOME, 'AppData'), LOCALAPPDATA: path.join(HOME, 'Local'), XDG_CONFIG_HOME: path.join(HOME, '.config') };
if (WITH_SERVICE && WIN && (!ENV.APPDATA || !ENV.LOCALAPPDATA)) throw new Error('APPDATA/LOCALAPPDATA unset');
// enroll's last fallback is the pre-profile fixed-name service; with the real home it
// would stop a real install. Refuse rather than touch it.
const LEGACY_UNIT = !WITH_SERVICE || WIN ? ''
  : MAC ? path.join(HOME, 'Library', 'LaunchAgents', 'works.earendil.heimdall-bridge.plist')
  : path.join(HOME, '.config', 'systemd', 'user', 'heimdall-bridge.service');
if (LEGACY_UNIT && fs.existsSync(LEGACY_UNIT)) throw new Error(`HEIMDALL_E2E_SERVICE=1 refuses to run: ${LEGACY_UNIT} is a real bridge install that \`ham-bridge enroll\` would stop`);
const children = [];
const CREATED = []; // every bridge id this run enrolled

// One bridge profile for the whole run: `--hub <hub> --profile PROFILE_NAME`, the
// profile `ham-bridge setup/update` resolve (bridgesvc.profile_from). Its service name
// depends on the hub's port, so initProfile fills SERVICE/PROFILE once the hub is up.
const PROFILE_NAME = `e2e${crypto.randomBytes(3).toString('hex')}`;
const STATE_ROOT = WIN ? path.join(ENV.APPDATA, 'heimdall', 'bridges') : path.join(HOME, '.config', 'heimdall', 'bridges');
let SERVICE = '';
let PROFILE = null;
let SERVICE_FILE = '';
// The Electron-driven phase (steps 7-11) uses a second profile of the same hub.
const ELECTRON_PROFILE_NAME = `${PROFILE_NAME}-app`;
let EL = null;
const LINUX_SERVICE = !WIN && !MAC && WITH_SERVICE;

// bridgesvc.canonical_hub + service_name: heimdall-bridge-<host with . -> ->-<port>_<profile>.
function profileLayout(hub, name) {
  const u = new URL(hub.base);
  const service = `heimdall-bridge-${u.hostname.replace(/[^a-z0-9-]/g, '-')}-${u.port}_${name}`;
  return {
    name,
    service,
    dir: path.join(STATE_ROOT, service),
    config: path.join(STATE_ROOT, service, 'config.toml'),
    token: path.join(STATE_ROOT, service, 'bridge-token'),
    data: WIN ? path.join(ENV.LOCALAPPDATA, 'heimdall', 'bridges', service) : path.join(HOME, '.local', 'share', 'heimdall', 'bridges', service),
    serviceFile: WIN ? '' : MAC ? path.join(HOME, 'Library', 'LaunchAgents', `${service}.plist`) : path.join(HOME, '.config', 'systemd', 'user', `${service}.service`),
  };
}
function initProfile(hub) {
  PROFILE = profileLayout(hub, PROFILE_NAME);
  SERVICE = PROFILE.service;
  SERVICE_FILE = PROFILE.serviceFile;
  EL = profileLayout(hub, ELECTRON_PROFILE_NAME);
}
const hubProfileArgs = (hub) => ['--hub', hub.base, '--profile', PROFILE_NAME];

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
    const code = () => (/^\s+([A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{2})\s*$/m.exec(out) || [])[1] ?? null;
    return await approveEnrollment(hub, acct, { exited, code, out: () => out, reuse, config: PROFILE.config, label: SERVICE });
  } catch (err) {
    await stop(child);
    throw err;
  }
}

// exited: resolves with the enrolling process's exit code (or {ok} for a bridgeManager
// operation); code(): the pairing code shown so far, or null.
async function approveEnrollment(hub, acct, { exited, code: codeOf, out: output, reuse, config, label }) {
  let code = null;
  let out = output();
  for (const deadline = Date.now() + 60_000; !code; await sleep(100)) {
    out = output();
    code = codeOf();
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
  const { vault_approval, statement } = await buildBridgeApproval(acct.identity, await acct.chain(), ver.data, label);
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
  const exitCode = await Promise.race([exited, sleep(180_000).then(() => 'timeout')]);
  out = output();
  if (typeof exitCode === 'object' && exitCode !== null) {
    expect(exitCode.ok, `the bridgeManager operation completes${exitCode.ok ? '' : ` (${exitCode.error})\n${out}`}`);
  } else {
    expect(/bridge enroll SUCCESS/.test(out) && exitCode === 0, `ham-bridge enroll reports SUCCESS and exits 0 (exit ${exitCode})${exitCode === 0 ? '' : '\n' + out}`);
  }
  expect(fs.readFileSync(config, 'utf8').includes(hub.base), 'the profile config points at that hub');
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
  initProfile(hub);
  console.log(`throwaway hub ${hub.base}; profile ${PROFILE_NAME} (service ${SERVICE}); temp root ${ROOT}`);
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
    // The profile is enrolled as B already: setup must skip the enroll step (no
    // pairing code) and only install + start the service for this same profile.
    const setup = spawnSync(BRIDGE_BIN, ['setup', ...hubProfileArgs(hub), '--headless', '--no-tray', '--json-progress'], { env: ENV, encoding: 'utf8', timeout: 180_000 });
    expect(setup.status === 0, `ham-bridge setup --profile ${PROFILE_NAME} exits 0 (exit ${setup.status})\n${setup.stdout}${setup.stderr}`);
    const events = setup.stdout.split('\n').filter((l) => l.startsWith('{')).map((l) => { try { return JSON.parse(l); } catch { return {}; } });
    expect(events.some((e) => e.step === 'enroll' && (e.state === 'skipped' || e.message === 'skipped')), 'setup skipped enroll for the already enrolled profile');
    if (SERVICE_FILE) expect(fs.existsSync(SERVICE_FILE), `setup wrote the service unit of this profile (${SERVICE_FILE})`);
    if (WIN) expect(spawnSync('schtasks', ['/Query', '/TN', SERVICE], { encoding: 'utf8' }).status === 0, 'setup registered the scheduled task');
    for (const deadline = Date.now() + 60_000; !(await online(B, S.b.bridgeId)()); await sleep(500)) {
      if (Date.now() > deadline) throw new CheckFailed('the installed service never connected');
    }
    const upd = spawnSync(BRIDGE_BIN, ['update', '--bundle', bundle, ...hubProfileArgs(hub), '--json-progress'], { env: ENV, encoding: 'utf8', timeout: 300_000 });
    expect(upd.status === 0, `ham-bridge update --bundle exits 0 (exit ${upd.status})\n${upd.stdout}${upd.stderr}`);
    for (const deadline = Date.now() + 60_000; !(await online(B, S.b.bridgeId)()); await sleep(500)) {
      if (Date.now() > deadline) throw new CheckFailed('the updated service never reconnected');
    }
    const active = (await bridgesOf(B)).filter(isActive);
    expect(active.length === 1 && active[0].bridge_id === S.b.bridgeId, `setup/update kept one active bridge for B (${active.map((b) => b.bridge_id)})`);
  }, { skip: WITH_SERVICE ? '' : 'needs a service manager; set HEIMDALL_E2E_SERVICE=1 (CI runners)' });
  await step('6 uninstall --purge leaves no files, secrets, service or active hub row', async () => {
    const un = spawnSync(BRIDGE_BIN, ['uninstall', '--service', SERVICE, '--purge', '--yes', '--headless', '--json-progress'], { env: ENV, encoding: 'utf8', timeout: 120_000 });
    expect(un.status === 0, `ham-bridge uninstall --purge exits 0 (exit ${un.status})${un.status === 0 ? '' : '\n' + un.stdout + un.stderr}`);
    // The Windows uninstall re-executes from %TEMP% and returns first; let it finish.
    for (const deadline = Date.now() + 60_000; fs.existsSync(PROFILE.dir) || fs.existsSync(PROFILE.data); await sleep(500)) {
      if (Date.now() > deadline) break;
    }
    await assertGone(PROFILE, [A, B]);
  });
  if (WITH_SERVICE) await electronPhase(hub, A, B);
  else for (const n of ['7', '8', '9', '10', '11']) await step(`${n} Electron-driven (bridgeManager) lifecycle`, async () => {}, { skip: 'needs a service manager; set HEIMDALL_E2E_SERVICE=1 (CI runners)' });
}

// After uninstall --purge of profile L: no files, secret dirs, OS secret-store items,
// service registration or active hub row of any bridge this run created remain.
async function assertGone(L, accts) {
  expect(!fs.existsSync(L.dir), `profile state dir removed (${L.dir})`);
  expect(!fs.existsSync(L.data), `profile data dir removed (${L.data})`);
  if (L.serviceFile) expect(!fs.existsSync(L.serviceFile), `service unit removed (${L.serviceFile})`);
  if (WIN) expect(spawnSync('schtasks', ['/Query', '/TN', L.service], { encoding: 'utf8' }).status !== 0, 'no scheduled task remains');
  if (MAC) expect(spawnSync('launchctl', ['print', `gui/${process.getuid()}/${L.service}`]).status !== 0, 'no launchd job remains');
  if (LINUX_SERVICE) {
    expect(spawnSync('systemctl', ['--user', 'is-active', `${L.service}.service`], { encoding: 'utf8' }).stdout.trim() !== 'active', 'the systemd user service is not running');
    expect(!spawnSync('systemctl', ['--user', 'list-unit-files', `${L.service}.service`], { encoding: 'utf8' }).stdout.includes(L.service), 'systemd --user no longer knows the unit');
  }
  for (const id of CREATED) {
    expect(secretItems(id).length === 0, `no OS secret-store item for ${id} (${secretItems(id)})`);
    expect(bridgeSecretFiles(id).length === 0, `no per-bridge secret dir for ${id} (${bridgeSecretFiles(id)})`);
  }
  const active = [];
  for (const a of accts) active.push(...(await bridgesOf(a)).filter(isActive).map((b) => b.bridge_id));
  expect(active.length === 0, `no active hub bridge row for any account (${active})`);
  const ours = (d) => d === L.service || CREATED.some((id) => d === id || d.startsWith(`${id}_`));
  const leftovers = (fs.existsSync(STATE_ROOT) ? fs.readdirSync(STATE_ROOT) : []).filter((d) => !WITH_SERVICE || ours(d));
  expect(leftovers.length === 0, `nothing of this run left under ${STATE_ROOT} (${leftovers})`);
}

// Steps 7-11: the same lifecycle driven the way the desktop app drives it: Electron's
// main process calls bridgeManager.runOperation (src/ui/electron/bridgeManager.cts),
// which runs `ham-bridge setup|enroll|update|uninstall --json-progress`, reads
// `status --json`, and forwards {type:'pairing'} to the wizard, where the user
// approves the code (here: the same /device/add approval as above).
async function electronPhase(hub, A, B) {
  const { default: bridgeManager } = await import('../../src/ui/electron/bridgeManager.cts');
  process.env.HEIMDALL_HAM_BRIDGE = BRIDGE_BIN; // the app's "override" binary source
  const target = { hub: hub.base, profile: ELECTRON_PROFILE_NAME };
  const run = (kind, acct, options = {}, reuse = '') => {
    const events = [];
    let pairing = null;
    let log = '';
    const done = bridgeManager.runOperation(kind, target, (e) => {
      events.push(e);
      if (e.type === 'pairing' && e.code) pairing = e.code;
      if (e.type === 'output' || e.type === 'error') log += `${e.message}\n`;
      if (e.type === 'progress' && e.state === 'failed') log += `[${e.step}] ${e.message}\n`;
    }, options);
    if (!acct) return done.then((r) => ({ r, events, log }));
    return approveEnrollment(hub, acct, { exited: done, code: () => pairing, out: () => log, reuse, config: EL.config, label: EL.service })
      .then((x) => ({ ...x, events }));
  };
  const status = () => bridgeManager.getStatus(target);
  const S = {};
  await step('7 Electron: setup wizard installs, enrolls (pairing event) and starts the service', async () => {
    S.first = await run('setup', A);
    const st = await status();
    expect(st.installed && ['running', 'connected'].includes(st.state), `status --json: installed and running or connected (${st.state} ${st.error || ''})`);
    expect(S.first.events.some((e) => e.type === 'complete'), 'the wizard received complete');
    for (const deadline = Date.now() + 60_000; !(await online(A, S.first.bridgeId)()); await sleep(500)) {
      if (Date.now() > deadline) throw new CheckFailed('the service never connected as account A');
    }
  });
  await step('8 Electron: re-enroll as the same account reuses the bridge', async () => {
    const again = await run('reenroll', A, { bridgeId: S.first.bridgeId }, S.first.bridgeId);
    expect(again.bridgeId === S.first.bridgeId, `reused ${S.first.bridgeId} (got ${again.bridgeId})`);
    const active = (await bridgesOf(A)).filter(isActive);
    expect(active.length === 1 && active[0].bridge_id === S.first.bridgeId, `account A has exactly one active bridge (${active.map((b) => b.bridge_id)})`);
    for (const deadline = Date.now() + 60_000; !(await online(A, S.first.bridgeId)()); await sleep(500)) {
      if (Date.now() > deadline) throw new CheckFailed('the re-enrolled service never reconnected');
    }
  });
  await step('9 Electron: replace with account B (confirmed): A revoked, A secrets wiped', async () => {
    S.b = await run('reenroll', B, { replaceOtherAccount: true });
    expect(S.b.bridgeId !== S.first.bridgeId, `account B got its own bridge ${S.b.bridgeId}`);
    expect((await bridgesOf(A)).filter(isActive).length === 0, 'account A has no active bridge left on the hub');
    expect(secretItems(S.first.bridgeId).length === 0, `no OS secret-store item of A's bridge remains (${secretItems(S.first.bridgeId)})`);
    expect(bridgeSecretFiles(S.first.bridgeId).length === 0, `A's per-bridge secret dir is gone (${bridgeSecretFiles(S.first.bridgeId)})`);
    for (const deadline = Date.now() + 60_000; !(await online(B, S.b.bridgeId)()); await sleep(500)) {
      if (Date.now() > deadline) throw new CheckFailed('the service never connected as account B');
    }
  });
  await step('10 Electron: update re-installs the service and it reconnects', async () => {
    const u = await run('update', null);
    expect(u.r.ok, `update completes${u.r.ok ? '' : ` (${u.r.error})\n${u.log}`}`);
    expect(u.events.some((e) => e.type === 'progress' && e.step), 'progress events streamed from --json-progress');
    for (const deadline = Date.now() + 60_000; !(await online(B, S.b.bridgeId)()); await sleep(500)) {
      if (Date.now() > deadline) throw new CheckFailed('the updated service never reconnected');
    }
  });
  await step('11 Electron: uninstall --purge leaves no files, secrets, service or active hub row', async () => {
    const u = await run('uninstall', null, { purge: true });
    expect(u.r.ok, `uninstall completes and confirmUninstalled passes${u.r.ok ? '' : ` (${u.r.error})\n${u.log}`}`);
    expect((await status()).installed === false, 'status --json: not installed');
    await assertGone(EL, [A, B]);
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
  if (WITH_SERVICE && SERVICE) for (const svc of [SERVICE, EL.service]) spawnSync(BRIDGE_BIN, ['uninstall', '--service', svc, '--purge', '--yes', '--headless'], { env: ENV, timeout: 60_000 });
}
// Real-home runs: remove this run's own profile/secret dirs if a failure left them.
function cleanupRealHome() {
  if (!WITH_SERVICE || !SERVICE) return;
  for (const p of [PROFILE.dir, PROFILE.data, SERVICE_FILE, EL.dir, EL.data, EL.serviceFile].filter(Boolean)) { try { fs.rmSync(p, { recursive: true, force: true }); } catch { /* gone */ } }
  for (const id of CREATED) for (const d of bridgeSecretFiles(id).filter((x) => !x.includes('/'))) { try { fs.rmSync(path.join(STATE_ROOT, d), { recursive: true, force: true }); } catch { /* gone */ } }
  if (LINUX_SERVICE) { spawnSync('systemctl', ['--user', 'daemon-reload']); for (const svc of [SERVICE, EL.service]) spawnSync('systemctl', ['--user', 'reset-failed', `${svc}.service`]); }
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
  if (results.some(([, r]) => r === 'FAIL')) cleanupRealHome();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch { console.log(`(could not remove ${ROOT})`); }
}
console.log('\n== summary');
for (const [name, r] of results) console.log(`${r} ${name}`);
const failed = results.filter(([, r]) => r === 'FAIL').length;
console.log(failed ? `${failed} step(s) FAILED` : 'all steps PASSED (SKIP = not run on this host)');
process.exitCode = failed ? 1 : 0;
