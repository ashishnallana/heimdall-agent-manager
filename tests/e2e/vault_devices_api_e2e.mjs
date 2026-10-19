// P2.5 — headless API end-to-end test of the passwordless vault device directory
// (docs/plans/passwordless-vault.md §2 "P2.5"), kept green through P3.
//
// Starts a THROWAWAY hub (ephemeral port, temp DB, temp cwd/HOME) and drives it over
// real HTTP with simulated devices built on the UI's OWN vault modules: device
// identity (deviceIdentity.ts), request signing (vaultRequestSigner.ts), directory
// chain verification (vaultDirectoryVerify.ts), keyring wraps (vaultKeyringWrap.ts),
// the signed mutation builders (vaultDeviceFlows.ts), the keyring/envelope code and
// bridge unseal v2 (vaultBridgeUnseal.ts, vaultBridgeDelivery.ts). The simulated
// bridge verifies the unseal chain proof with the reference verifier
// (verifyBridgeChainProof) the Odin bridge mirrors.
// Never touches a running dev hub/bridge or any OS keystore.
//
// Run through scripts/e2e-vault-devices.ps1 / .sh (they build the hub), or directly:
//   HEIMDALL_E2E_HUB_BIN=<ham-hub> HEIMDALL_E2E_MIGRATIONS_DIR=<repo>/src/hub/repository/sqlite/migrations \
//   node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/vault_devices_api_e2e.mjs
// Prints PASS/FAIL per step; exits non-zero on any FAIL.

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';

import { importKeyring, parseKeyringBytes } from '../../src/ui/utils/vaultKeyring.ts';
import {
  SIGN_ALG_ECDSA_P256_SHA256, WRAP_ALG_ECDH_P256_HKDF_AES,
  bridgeUnsealKeyCanonical, ecdhHkdfAesKey, epochCommit, signP256, toLowerHex, lowerHexToBytes,
} from '../../src/ui/utils/vaultStatements.ts';
import { decryptVaultText, encryptVaultText, VAULT_LOCKED_MARKER } from '../../src/ui/utils/vaultCrypto.ts';
import { UNSEAL_V2_FORMAT, UNSEAL_V2_INFO, buildUnsealAad, prepareUnsealPayload } from '../../src/ui/utils/vaultBridgeUnseal.ts';
import { createDeviceIdentity, deviceIdFor, fingerprintFor, memoryDeviceStore, labelB64 } from '../../src/ui/utils/deviceIdentity.ts';
import { signedRequestHeaders, newRequestNonce } from '../../src/ui/utils/vaultRequestSigner.ts';
import { verifyDirectory, wrapRecipients, buildBridgeChainProof, verifyBridgeChainProof } from '../../src/ui/utils/vaultDirectoryVerify.ts';
import { openVerifiedWrap } from '../../src/ui/utils/vaultKeyringWrap.ts';
import { deliverKeyringToBridge } from '../../src/ui/utils/vaultBridgeDelivery.ts';
import { buildBridgeApproval, buildBrowserApproval, buildGenesis, buildRegistration, buildRevocation } from '../../src/ui/utils/vaultDeviceFlows.ts';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const USER_HEADER = 'X-authentik-username';
const enc = new TextEncoder();

// ── tiny assertion/report layer ─────────────────────────────────────────────

const results = [];
class CheckFailed extends Error {}
function expect(cond, msg) {
  if (!cond) throw new CheckFailed(msg);
  console.log(`    ok - ${msg}`);
}
async function step(name, fn) {
  console.log(`\n== ${name}`);
  try {
    await fn();
    results.push([name, 'PASS']);
    console.log(`PASS ${name}`);
  } catch (err) {
    results.push([name, 'FAIL']);
    console.log(`    not ok - ${err instanceof CheckFailed ? err.message : (err?.stack || err)}`);
    console.log(`FAIL ${name}`);
  }
}

// ── hub lifecycle ───────────────────────────────────────────────────────────

async function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen(0, '127.0.0.1', () => { const { port } = srv.address(); srv.close(() => resolve(port)); });
  });
}

async function startHub() {
  const bin = process.env.HEIMDALL_E2E_HUB_BIN;
  const migrations = process.env.HEIMDALL_E2E_MIGRATIONS_DIR || path.join(REPO_ROOT, 'src', 'hub', 'repository', 'sqlite', 'migrations');
  if (!bin || !fs.existsSync(bin)) throw new Error('HEIMDALL_E2E_HUB_BIN must point at a hub binary built from this tree (use scripts/e2e-vault-devices.ps1 or .sh)');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-vault-e2e-'));
  const port = await freePort();
  if (port === 8080 || port === 8081) throw new Error('refusing a dev-hub port');
  const dbPath = path.join(dir, 'hub.db');
  const log = fs.openSync(path.join(dir, 'hub.log'), 'w');
  // Hermetic: cwd and every home/appdata variable point into the temp dir.
  const env = { ...process.env, HOME: dir, USERPROFILE: dir, APPDATA: dir, LOCALAPPDATA: dir, XDG_CONFIG_HOME: dir, XDG_DATA_HOME: dir };
  const child = spawn(bin, [
    '--listen', `127.0.0.1:${port}`, '--db', dbPath, '--migrations-dir', migrations,
    '--trusted-proxy-cidr', '127.0.0.1/32',
  ], { cwd: dir, env, stdio: ['ignore', log, log] });
  let exited = false;
  child.on('exit', () => { exited = true; });
  const base = `http://127.0.0.1:${port}`;
  const deadline = Date.now() + 30_000;
  for (;;) {
    if (exited) throw new Error(`hub exited during startup:\n${fs.readFileSync(path.join(dir, 'hub.log'), 'utf8')}`);
    try { if ((await fetch(`${base}/api/v1/health`)).ok) break; } catch { /* not up yet */ }
    if (Date.now() > deadline) throw new Error('hub did not become healthy within 30 s');
    await new Promise((r) => setTimeout(r, 150));
  }
  const stop = async () => {
    if (!exited) {
      child.kill();
      await new Promise((r) => { if (exited) r(); else child.once('exit', r); setTimeout(r, 5000); });
    }
    fs.closeSync(log);
    for (let i = 0; i < 10; i++) {
      try { fs.rmSync(dir, { recursive: true, force: true }); return; } catch { await new Promise((r) => setTimeout(r, 200)); }
    }
    console.log(`(could not remove ${dir})`);
  };
  return { base, port, dir, dbPath, stop };
}

// ── HTTP ────────────────────────────────────────────────────────────────────

let HUB;
async function http(method, p, { user, body, headers = {}, bearer } = {}) {
  const h = { ...headers };
  if (user) h[USER_HEADER] = user;
  if (bearer) h.Authorization = `Bearer ${bearer}`;
  const text = body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body));
  if (text !== undefined) h['Content-Type'] = 'application/json';
  const res = await fetch(`${HUB.base}${p}`, { method, headers: h, body: text });
  const raw = await res.text();
  let json = null;
  try { json = JSON.parse(raw); } catch { /* not JSON */ }
  return { status: res.status, data: json?.data, error: json?.error, raw };
}


// ── crypto helpers (all protocol code comes from the UI modules) ─────────────

const randHex = (n) => toLowerHex(crypto.getRandomValues(new Uint8Array(n)));
const exportRawHex = async (k) => toLowerHex(new Uint8Array(await crypto.subtle.exportKey('raw', k)));

async function commitHex(bytes, userId, epoch) {
  const parsed = parseKeyringBytes(Uint8Array.from(bytes));
  try {
    const e = parsed.entries.find((x) => x.epoch === epoch);
    return toLowerHex(await epochCommit(e.key, userId, epoch));
  } finally { for (const x of parsed.entries) x.key.fill(0); }
}

const pinsFor = async (rootPub, v = 0, e = 0) => ({ root_device_id: await deviceIdFor(rootPub), root_sign_pub: rootPub, max_directory_version: v, max_epoch: e });

// ── simulated devices ───────────────────────────────────────────────────────

class SimDevice {
  static async create(userId, label, kind = 'browser') {
    const d = new SimDevice();
    d.label = label;
    d.kind = kind;
    d.userId = userId;
    if (kind === 'browser') {
      d.identity = await createDeviceIdentity(memoryDeviceStore(), userId);
      d.signKey = d.identity.signPrivateKey;
      d.signPub = d.identity.signPub;
      d.ecdhPub = d.identity.ecdhPub;
    } else {
      const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify']);
      d.signKey = pair.privateKey;
      d.signPub = await exportRawHex(pair.publicKey);
      d.ecdhPub = '';
    }
    d.id = await deviceIdFor(d.signPub);
    d.fingerprint = await fingerprintFor(d.signPub, d.ecdhPub);
    d.keyringBytes = null; // HKR1 (the simulation keeps it; the UI holds it only transiently)
    d.keyring = null;
    return d;
  }
  get signer() { return { deviceId: this.id, signPrivateKey: this.signKey }; }
  subject() {
    return {
      subject_device_id: this.id, subject_kind: this.kind, subject_sign_pub: this.signPub, subject_ecdh_pub: this.ecdhPub,
      subject_sign_alg: SIGN_ALG_ECDSA_P256_SHA256, subject_wrap_alg: this.kind === 'bridge' ? '' : WRAP_ALG_ECDH_P256_HKDF_AES,
      subject_label_b64: labelB64(this.label),
    };
  }
  async signText(text) { return signP256(this.signKey, enc.encode(text)); }
  async signedHeaders(userId, method, p, body = '', n = newRequestNonce(), ts = Date.now()) {
    return signedRequestHeaders(this.signer, userId, method, p, body, { nonce: n, ts });
  }
  async setKeyring(bytes) {
    this.keyringBytes = Uint8Array.from(bytes);
    this.keyring = await importKeyring(Uint8Array.from(bytes), undefined);
  }
}

// A signed request with a JSON body: the exact bytes signed are the bytes sent.
async function signedCall(dev, user, userId, method, p, bodyObj, opts = {}) {
  const body = bodyObj === undefined ? '' : JSON.stringify(bodyObj);
  const headers = await dev.signedHeaders(userId, method, p, body, opts.nonce, opts.ts);
  return http(method, p, { user, body: body === '' ? undefined : body, headers });
}

// Verify a received wrap under the chain (signer, recipient, epoch_commit), then open it.
async function openWrap(dev, wrapJson, chain) {
  const parsed = await openVerifiedWrap(wrapJson, { userId: chain.userId, recipientDeviceId: dev.id, recipientEcdhPrivate: dev.identity.ecdhPrivateKey, chain });
  try {
    const { serializeKeyringBytes } = await import('../../src/ui/utils/vaultKeyring.ts');
    return serializeKeyringBytes(parsed);
  } finally { for (const e of parsed.entries) e.key.fill(0); }
}

async function fetchVerified(user, userId, pins) {
  const r = await http('GET', '/api/v1/vault/directory', { user });
  if (r.status !== 200) throw new CheckFailed(`GET directory -> ${r.status} ${r.raw}`);
  return { dir: r.data, chain: await verifyDirectory(r.data, userId, pins) };
}

// ── simulated bridge (no real ham-bridge on Windows without the OS keystore) ──

class SimBridge {
  static async create(userId) {
    const b = new SimBridge();
    b.identity = await SimDevice.create(userId, 'e2e-bridge', 'bridge');
    b.ecdh = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
    b.ecdhPub = await exportRawHex(b.ecdh.publicKey);
    b.bootId = randHex(16);
    b.verifier = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url');
    b.challenge = Buffer.from(await crypto.subtle.digest('SHA-256', enc.encode(b.verifier))).toString('base64url');
    b.seenNonces = new Set();
    b.unlocked = false;
    b.pinnedRoot = null; // pinned from the chain proof of the FIRST (enrollment) unseal
    return b;
  }
  // POST /device/authorize body. Kept in one place: P2 fixes add an identity-key proof of possession here.
  authorizeBody() {
    return {
      client: 'ham-bridge', device_label: 'e2e-bridge', os: 'windows', os_user: 'e2e', app_version: 'e2e',
      bridge_public_key: this.ecdhPub, bridge_identity_public_key: this.identity.signPub,
      code_challenge: this.challenge, code_challenge_method: 'S256',
    };
  }
  async signUnsealKey() {
    this.unsealKeySig = await this.identity.signText(bridgeUnsealKeyCanonical(this.bridgeId, this.ecdhPub, this.bootId));
  }
  target(identityPub = this.identity.signPub, sig = this.unsealKeySig) {
    return { bridgeId: this.bridgeId, publicKey: this.ecdhPub, bootId: this.bootId, unsealKeySignature: sig, identityPublicKey: identityPub };
  }
  // Mirror of the bridge's unseal v2 checks plus the chain proof (verifyBridgeChainProof):
  // pinned root, approved non-bridge epoch issuer, epoch_commit, own approval.
  async receiveUnseal(payload, ownerUserId) {
    if (payload.bridge_id !== this.bridgeId || payload.format !== UNSEAL_V2_FORMAT) throw new Error('wrong bridge or format');
    if (Math.abs(Date.now() - payload.timestamp) > 30_000) throw new Error('skew');
    if (this.seenNonces.has(payload.nonce)) throw new Error('replayed unseal nonce');
    if (payload.bridge_identity_public_key !== this.identity.signPub || JSON.stringify(payload.unseal_key_signature) !== this.unsealKeySig) throw new Error('identity / signature echo mismatch');
    const key = await ecdhHkdfAesKey(this.ecdh.privateKey, payload.client_public_key, UNSEAL_V2_INFO, ['decrypt']);
    const plain = new Uint8Array(await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: lowerHexToBytes(payload.iv), additionalData: buildUnsealAad(payload.bridge_id, payload.timestamp, payload.nonce, payload.current_epoch), tagLength: 128 },
      key, Buffer.concat([lowerHexToBytes(payload.ciphertext), lowerHexToBytes(payload.tag)])));
    try {
      const parsed = parseKeyringBytes(plain, ownerUserId);
      for (const e of parsed.entries) e.key.fill(0);
      if (parsed.currentEpoch !== payload.current_epoch) throw new Error('epoch mismatch');
      const root = await verifyBridgeChainProof(payload.chain_proof, parsed.currentEpoch, await commitHex(plain, ownerUserId, parsed.currentEpoch), {
        ownerUserId, bridgeIdentityPub: this.identity.signPub, pinnedRootSignPub: this.pinnedRoot,
      });
      this.seenNonces.add(payload.nonce);
      this.pinnedRoot = root;
      this.keyringBytes = Uint8Array.from(plain);
      this.unlocked = true;
      this.currentEpoch = parsed.currentEpoch;
    } finally { plain.fill(0); }
    return { type: 'bridge_unseal_result', command_id: payload.command_id, ok: true };
  }
  deps(keyringBytes, overrides = {}) {
    return {
      fetchTarget: async () => this.target(),
      dispatch: async (_id, payload) => this.receiveUnseal(payload, this.ownerUserId),
      withKeyringBytes: async (fn) => { const b = Uint8Array.from(keyringBytes); try { return await fn(b); } finally { b.fill(0); } },
      ...overrides,
    };
  }
}

// ── the scenario ────────────────────────────────────────────────────────────

const ALICE = 'e2e-alice';
const BOB = 'e2e-bob';
const S = {}; // shared state across steps

async function genesis(dev, user) {
  const body = await buildGenesis(dev.identity, dev.label);
  return http('POST', '/api/v1/vault/directory/genesis', { user, body });
}

async function register(dev, user) {
  const { statement, signature } = await buildRegistration(dev.identity, dev.label);
  return http('POST', '/api/v1/vault/devices/register', { user, body: { statement, proof_signature: signature } });
}

async function main() {
  HUB = await startHub();
  console.log(`throwaway hub ${HUB.base} (temp dir ${HUB.dir})`);
  try {
    const me = await http('GET', '/api/v1/me', { user: ALICE });
    S.uid = me.data?.user_id;
    const meB = await http('GET', '/api/v1/me', { user: BOB });
    S.bobUid = meB.data?.user_id;
    if (!S.uid || !S.bobUid) throw new Error(`could not resolve users: ${me.raw} ${meB.raw}`);

    await step('1 device A: genesis, self-wrap, client chain verification', async () => {
      const none = await http('GET', '/api/v1/vault/directory', { user: ALICE });
      expect(none.status === 404, 'no directory before genesis (404)');
      S.A = await SimDevice.create(S.uid, 'e2e device A');
      const r = await genesis(S.A, ALICE);
      expect(r.status === 201, `genesis -> 201 (${r.status} ${r.status !== 201 ? r.raw : ''})`);
      const again = await genesis(S.A, ALICE);
      expect(again.status === 409, 'second genesis -> 409');
      const self = await signedCall(S.A, ALICE, S.uid, 'GET', '/api/v1/vault/devices/self');
      expect(self.status === 200 && self.data.status === 'approved' && self.data.wrap, 'A fetches its own wrap via /vault/devices/self');
      const { dir, chain } = await fetchVerified(ALICE, S.uid, null);
      S.root = chain.rootSignPub;
      S.pins = await pinsFor(S.root);
      expect(S.root === S.A.signPub, 'chain verifies; root pinned to A');
      // Negative controls: the verifier is not vacuous.
      const notRoot = await SimDevice.create(S.uid, 'not the root');
      await verifyDirectory(dir, S.uid, await pinsFor(notRoot.signPub)).then(() => expect(false, 'pin mismatch accepted'), () => expect(true, 'verifier refuses a directory whose root differs from the pin'));
      await verifyDirectory(dir, S.uid, { ...S.pins, max_directory_version: dir.version + 1 }).then(() => expect(false, 'rollback accepted'), () => expect(true, 'verifier refuses a directory older than the pinned version'));
      const flip = (s) => s.replace(/epoch_commit=[0-9a-f]/, (m) => m.slice(0, -1) + (m.endsWith('0') ? '1' : '0'));
      const tampered = { ...dir, epochs: dir.epochs.map((e) => ({ ...e, statement: flip(e.statement) })) };
      await verifyDirectory(tampered, S.uid, S.pins).then(() => expect(false, 'tampered epoch accepted'), () => expect(true, 'verifier refuses a tampered epoch statement'));
      const bytes = await openWrap(S.A, self.data.wrap, chain);
      expect(await commitHex(bytes, S.uid, 1) === chain.commits.get(1), 'hub-stored self-wrap opens; epoch_commit(e1) matches the signed epoch statement');
      await S.A.setKeyring(bytes);
    });

    await step('2 device B: register -> pending code; A approves + wraps; B unwraps; cross-decrypt', async () => {
      S.B = await SimDevice.create(S.uid, 'e2e device B');
      const reg = await register(S.B, ALICE);
      expect(reg.status === 201 && reg.data.status === 'pending' && /^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$/.test(reg.data.user_code), `B registered pending with a code (${reg.status})`);
      expect(reg.data.device_id === S.B.id && reg.data.fingerprint === S.B.fingerprint, 'hub device id + fingerprint match B\'s local derivation');
      S.bCode = reg.data.user_code;
      const pending = await signedCall(S.B, ALICE, S.uid, 'GET', '/api/v1/vault/devices/self');
      expect(pending.status === 200 && pending.data.status === 'pending' && !pending.data.wrap, 'B polls self: pending, no wrap');

      const ver = await http('POST', '/api/v1/device/verify', { user: ALICE, body: { user_code: S.bCode } });
      expect(ver.status === 200 && ver.data.kind === 'browser' && ver.data.device_id === S.B.id, '/device/verify resolves the code as kind=browser');
      expect(ver.data.fingerprint === S.B.fingerprint, 'A sees the fingerprint B displays (user comparison)');
      const { chain } = await fetchVerified(ALICE, S.uid, S.pins);
      const body = await buildBrowserApproval(S.A.identity, chain, ver.data, S.bCode, ver.data.label, S.A.keyringBytes);
      const unsigned = await http('POST', `/api/v1/vault/devices/${S.B.id}/approve`, { user: ALICE, body });
      expect(unsigned.status === 401, 'unsigned approval -> 401');
      const ok = await signedCall(S.A, ALICE, S.uid, 'POST', `/api/v1/vault/devices/${S.B.id}/approve`, body);
      expect(ok.status === 200 && ok.data.directory_version === chain.version + 1, `signed approval -> 200, version ${chain.version + 1}`);

      const self = await signedCall(S.B, ALICE, S.uid, 'GET', '/api/v1/vault/devices/self');
      expect(self.status === 200 && self.data.status === 'approved' && self.data.wrap, 'B polls self: approved, wrap present');
      const vb = await fetchVerified(ALICE, S.uid, null);
      expect(vb.chain.trusted.has(S.B.id) && vb.chain.trusted.get(S.B.id).label === 'e2e device B', 'B verifies the chain and finds its own signed approval + label');
      const bytes = await openWrap(S.B, self.data.wrap, vb.chain);
      await openVerifiedWrap(self.data.wrap, { userId: S.uid, recipientDeviceId: S.A.id, recipientEcdhPrivate: S.A.identity.ecdhPrivateKey, chain: vb.chain })
        .then(() => expect(false, 'wrap for B opened as A'), () => expect(true, 'a wrap naming another recipient is refused'));
      expect(await commitHex(bytes, S.uid, vb.chain.currentEpoch) === vb.chain.commits.get(vb.chain.currentEpoch), 'B checks epoch_commit before installing keys');
      await S.B.setKeyring(bytes);
      S.e1FromA = await encryptVaultText('secret from A @e1', S.A.keyring);
      S.e1FromB = await encryptVaultText('secret from B @e1', S.B.keyring);
      expect(S.e1FromA.startsWith('vault:v2:e1:') && S.e1FromB.startsWith('vault:v2:e1:'), 'both seal v2 content under e1');
      expect(await decryptVaultText(S.e1FromA, S.B.keyring) === 'secret from A @e1', 'B decrypts A\'s content');
      expect(await decryptVaultText(S.e1FromB, S.A.keyring) === 'secret from B @e1', 'A decrypts B\'s content');
    });

    await step('3 bridge: device-flow enrollment approved by A with vault_approval; unseal v2 + chain proof (bridge side simulated)', async () => {
      const br = await SimBridge.create(S.uid);
      br.ownerUserId = S.uid;
      S.bridge = br;
      const authz = await http('POST', '/api/v1/device/authorize', { body: br.authorizeBody() });
      expect(authz.status === 200 && authz.data.user_code && authz.data.device_code, `bridge /device/authorize -> 200 (${authz.status} ${authz.status !== 200 ? authz.raw : ''})`);
      const ver = await http('POST', '/api/v1/device/verify', { user: ALICE, body: { user_code: authz.data.user_code } });
      expect(ver.status === 200 && ver.data.kind === 'bridge' && ver.data.bridge_identity_public_key === br.identity.signPub, '/device/verify resolves kind=bridge with its identity key');
      const { chain } = await fetchVerified(ALICE, S.uid, S.pins);
      const { vault_approval } = await buildBridgeApproval(S.A.identity, chain, ver.data, 'e2e-bridge');
      const noVa = await http('POST', '/api/v1/device/approve', { user: ALICE, body: { user_code: authz.data.user_code, approve: true } });
      expect(noVa.status === 400, 'bridge approval without vault_approval -> 400');
      const appr = await http('POST', '/api/v1/device/approve', { user: ALICE, body: { user_code: authz.data.user_code, approve: true, vault_approval } });
      expect(appr.status === 200 && appr.data?.hub_observed?.bridge_id, `/device/approve with vault_approval -> 200 (${appr.status} ${appr.status !== 200 ? appr.raw : ''})`);
      const tok = await http('POST', '/api/v1/device/token', { body: { device_code: authz.data.device_code, code_verifier: br.verifier } });
      expect(tok.status === 200 && tok.data.bridge_id === appr.data.hub_observed.bridge_id && tok.data.access_token, 'bridge collects its credential with the PKCE verifier');
      br.bridgeId = tok.data.bridge_id;
      br.token = tok.data.access_token;
      const asUser = await http('GET', '/api/v1/vault/directory', { bearer: br.token });
      expect(asUser.status === 403 || asUser.status === 401, `bridge token cannot read the vault directory (${asUser.status})`);

      const v = await fetchVerified(ALICE, S.uid, S.pins);
      const row = v.chain.trusted.get(br.identity.id);
      expect(row && row.kind === 'bridge' && row.row.bridge_id === br.bridgeId, 'bridge identity is chain-approved in the directory, bound to its bridge_id');
      expect(!wrapRecipients(v.chain).some((d) => d.kind === 'bridge'), 'no hub-stored wrap targets a bridge');
      await br.signUnsealKey();
      const forged = await SimDevice.create(S.uid, 'forger', 'bridge');
      const forgedSig = await forged.signText(bridgeUnsealKeyCanonical(br.bridgeId, br.ecdhPub, br.bootId));
      await deliverKeyringToBridge(br.bridgeId, v.chain, br.deps(S.A.keyringBytes, { fetchTarget: async () => br.target(br.identity.signPub, forgedSig) }))
        .then(() => expect(false, 'unseal to a key signed by another identity must be refused'), () => expect(true, 'A refuses an unseal key not signed by the chain-approved identity'));
      await deliverKeyringToBridge(br.bridgeId, v.chain, br.deps(S.A.keyringBytes, { fetchTarget: async () => br.target(forged.signPub, forgedSig) }))
        .then(() => expect(false, 'hub-swapped identity key accepted'), () => expect(true, 'A refuses when the hub serves an identity key other than the approved one'));
      expect(!br.unlocked, 'nothing reached the bridge from the refused attempts');
      let captured = null;
      await deliverKeyringToBridge(br.bridgeId, v.chain, br.deps(S.A.keyringBytes, { dispatch: async (_id, payload) => { captured = payload; return br.receiveUnseal(payload, S.uid); } }));
      expect(br.unlocked && br.currentEpoch === 1 && br.pinnedRoot === S.root, 'simulated bridge verifies chain proof + epoch_commit, pins the root, reports unlocked at e1');
      await br.receiveUnseal(captured, S.uid).then(() => expect(false, 'replay accepted'), () => expect(true, 'replayed unseal payload refused'));
      // A hostile hub re-targeting the proof at another root is refused once the root is pinned.
      const mallory = await SimDevice.create(S.uid, 'mallory root');
      const evil = { ...captured, nonce: randHex(16), chain_proof: { ...captured.chain_proof, root_sign_pub: mallory.signPub, root_device_id: mallory.id } };
      await br.receiveUnseal(evil, S.uid).then(() => expect(false, 'swapped root accepted'), () => expect(true, 'bridge refuses a chain proof for a root other than the pinned one'));
    });

    await step('4 A revokes B -> epoch 2; wraps to remaining; B cut off; e2 content; bridge re-unsealed', async () => {
      const { chain } = await fetchVerified(ALICE, S.uid, S.pins);
      const { body, nextKeyring } = await buildRevocation(S.A.identity, chain, S.B.id, S.A.keyringBytes);
      nextKeyring.fill(0);
      expect(body.wraps.length === 1 && body.wraps[0].recipient_device_id === S.A.id, 'remaining wrap recipients = {A} (bridge gets re-unseal, not a wrap)');
      const missing = await signedCall(S.A, ALICE, S.uid, 'POST', `/api/v1/vault/devices/${S.B.id}/revoke`, { ...body, wraps: [] });
      expect(missing.status === 400, `revoke with missing wraps -> 400 (${missing.status})`);
      const r = await signedCall(S.A, ALICE, S.uid, 'POST', `/api/v1/vault/devices/${S.B.id}/revoke`, body);
      expect(r.status === 200 && r.data.directory_version === chain.version + 1, `revoke -> 200, version ${chain.version + 1} (${r.status} ${r.status !== 200 ? r.raw : ''})`);

      const after = await fetchVerified(ALICE, S.uid, S.pins);
      expect(after.chain.currentEpoch === 2 && !after.chain.trusted.has(S.B.id), 'chain verifies: epoch 2, B no longer trusted');
      await verifyDirectory(after.dir, S.uid, { ...S.pins, max_epoch: 3 }).then(() => expect(false, 'epoch rollback accepted'), () => expect(true, 'verifier refuses a directory behind the pinned epoch'));
      const selfA = await signedCall(S.A, ALICE, S.uid, 'GET', '/api/v1/vault/devices/self');
      const bytes = await openWrap(S.A, selfA.data.wrap, after.chain);
      expect(selfA.data.wrap.current_epoch === 2 && await commitHex(bytes, S.uid, 2) === after.chain.commits.get(2), 'A re-fetches its e2 wrap and epoch_commit(e2) checks');
      await S.A.setKeyring(bytes);
      const selfB = await signedCall(S.B, ALICE, S.uid, 'GET', '/api/v1/vault/devices/self');
      expect(selfB.status === 200 && selfB.data.status === 'revoked' && !selfB.data.wrap, 'B polls self: revoked, no wrap');
      const bMut = await signedCall(S.B, ALICE, S.uid, 'POST', `/api/v1/vault/devices/${S.A.id}/revoke`, { expected_version: after.chain.version, wraps: [] });
      expect(bMut.status === 403, `revoked B cannot sign a mutation (${bMut.status})`);
      const e2 = await encryptVaultText('secret from A @e2', S.A.keyring);
      expect(e2.startsWith('vault:v2:e2:'), 'new content is sealed under e2');
      expect(await decryptVaultText(e2, S.A.keyring) === 'secret from A @e2' && await decryptVaultText(S.e1FromB, S.A.keyring) === 'secret from B @e1', 'A reads e1 and e2');
      expect(await decryptVaultText(e2, S.B.keyring) === VAULT_LOCKED_MARKER, 'B (old keyring) sees e2 as locked');
      // Re-unseal the bridge with the e2 keyring (what the P3 revoke flow does).
      const br = S.bridge;
      br.bootId = randHex(16);
      await br.signUnsealKey();
      await deliverKeyringToBridge(br.bridgeId, after.chain, br.deps(S.A.keyringBytes));
      expect(br.currentEpoch === 2, 'simulated bridge re-unsealed at e2 (chain proof: revoke-issued epoch statement)');
      // A stale proof (e1 statement) with the e2 keyring is refused by the bridge.
      const proof = buildBridgeChainProof(after.chain, br.identity.id);
      const staleProof = { ...proof, epoch: { ...buildBridgeChainProof(chain, br.identity.id).epoch } };
      br.bootId = randHex(16);
      await br.signUnsealKey();
      const p2 = await prepareUnsealPayload(br.target(), Uint8Array.from(S.A.keyringBytes), proof);
      await br.receiveUnseal({ ...p2, chain_proof: staleProof }, S.uid).then(() => expect(false, 'stale epoch proof accepted'), () => expect(true, 'bridge refuses an epoch statement that is not for the keyring\'s current epoch'));
    });

    await step('5 attacks over raw HTTP', async () => {
      const { chain } = await fetchVerified(ALICE, S.uid, S.pins);
      // Self-revoke.
      const self = await signedCall(S.A, ALICE, S.uid, 'POST', `/api/v1/vault/devices/${S.A.id}/revoke`, { expected_version: chain.version, wraps: [] });
      expect(self.status === 409 && self.raw.includes('"self_revoke"'), `self-revoke -> 409 self_revoke (${self.status})`);
      await buildRevocation(S.A.identity, chain, S.A.id, S.A.keyringBytes).then(() => expect(false, 'client built a self-revoke'), () => expect(true, 'client refuses to build a self-revoke'));

      // Concurrent approvals of two pending devices at the same version: exactly one wins.
      const C = await SimDevice.create(S.uid, 'e2e device C');
      const D = await SimDevice.create(S.uid, 'e2e device D');
      const rc = await register(C, ALICE);
      const rd = await register(D, ALICE);
      expect(rc.status === 201 && rd.status === 201, 'C and D registered pending');
      const vc = await http('POST', '/api/v1/device/verify', { user: ALICE, body: { user_code: rc.data.user_code } });
      const vdv = await http('POST', '/api/v1/device/verify', { user: ALICE, body: { user_code: rd.data.user_code } });
      const bc = await buildBrowserApproval(S.A.identity, chain, vc.data, rc.data.user_code, vc.data.label, S.A.keyringBytes);
      const bd = await buildBrowserApproval(S.A.identity, chain, vdv.data, rd.data.user_code, vdv.data.label, S.A.keyringBytes);
      const pc = `/api/v1/vault/devices/${C.id}/approve`;
      const pd = `/api/v1/vault/devices/${D.id}/approve`;
      const nC = newRequestNonce();
      const hc = await S.A.signedHeaders(S.uid, 'POST', pc, JSON.stringify(bc), nC);
      const hd = await S.A.signedHeaders(S.uid, 'POST', pd, JSON.stringify(bd));
      const [ac, ad] = await Promise.all([
        http('POST', pc, { user: ALICE, body: JSON.stringify(bc), headers: hc }),
        http('POST', pd, { user: ALICE, body: JSON.stringify(bd), headers: hd }),
      ]);
      const statuses = [ac.status, ad.status].sort();
      expect(statuses[0] === 200 && statuses[1] === 409, `concurrent approvals at version ${chain.version}: exactly one wins (${ac.status}, ${ad.status})`);
      const [loser, loserBody, loserPath] = ac.status === 409 ? [C, bc, pc] : [D, bd, pd];
      // Stale version: the loser re-sent with its old expected_version.
      const stale = await signedCall(S.A, ALICE, S.uid, 'POST', loserPath, loserBody);
      expect(stale.status === 409 && stale.raw.includes('version_conflict'), `stale expected_version -> 409 version_conflict (${stale.status})`);
      // Replayed request nonce (a mutation; byte-identical request incl. signature).
      const replay = await http('POST', pc, { user: ALICE, body: JSON.stringify(bc), headers: hc });
      expect(replay.status === 401, `replayed signed request -> 401 (${replay.status})`);
      // Forged signature: A's device id, signed by another key.
      const E = await SimDevice.create(S.uid, 'forger');
      const fresh = (await fetchVerified(ALICE, S.uid, S.pins)).chain;
      const lv = loser === C ? vc : vdv;
      const fb = await buildBrowserApproval(S.A.identity, fresh, lv.data, (loser === C ? rc : rd).data.user_code, lv.data.label, S.A.keyringBytes);
      const fh = await E.signedHeaders(S.uid, 'POST', loserPath, JSON.stringify(fb));
      fh['X-Heimdall-Device-Id'] = S.A.id;
      const forged = await http('POST', loserPath, { user: ALICE, body: JSON.stringify(fb), headers: fh });
      expect(forged.status === 401, `forged request signature -> 401 (${forged.status})`);
      // Body tampered after signing.
      const th = await S.A.signedHeaders(S.uid, 'POST', loserPath, JSON.stringify(fb));
      const tampered = await http('POST', loserPath, { user: ALICE, body: JSON.stringify({ ...fb, user_code: fb.user_code.toLowerCase() }), headers: th });
      expect(tampered.status === 401, `body tampered after signing -> 401 (${tampered.status})`);
      // Forged statement signature inside a correctly signed request.
      const badStmt = { ...fb, signature: JSON.parse(await E.signText(fb.statement)) };
      const fs1 = await signedCall(S.A, ALICE, S.uid, 'POST', loserPath, badStmt);
      expect(fs1.status === 401, `approval statement signed by a non-device key -> 401 (${fs1.status})`);
      // The loser can still be approved properly afterwards (directory unchanged by the failures).
      const good = await signedCall(S.A, ALICE, S.uid, 'POST', loserPath, fb);
      expect(good.status === 200, `loser approved with the fresh version (${good.status})`);

      // Other user's session.
      S.Bob = await SimDevice.create(S.bobUid, 'bob device');
      const bg = await genesis(S.Bob, BOB);
      expect(bg.status === 201, 'bob creates his own directory');
      const bobDir = await http('GET', '/api/v1/vault/directory', { user: BOB });
      expect(bobDir.status === 200 && bobDir.data.devices.length === 1 && bobDir.data.devices[0].device_id === S.Bob.id && !bobDir.raw.includes(S.A.id), 'bob sees only his own directory');
      const F = await SimDevice.create(S.uid, 'e2e device F');
      const rf = await register(F, ALICE);
      const bv = await http('POST', '/api/v1/device/verify', { user: BOB, body: { user_code: rf.data.user_code } });
      expect(bv.status === 404, `bob cannot resolve alice's pending code (${bv.status})`);
      const before = (await http('GET', '/api/v1/vault/directory', { user: ALICE })).data.version;
      const vf = await http('POST', '/api/v1/device/verify', { user: ALICE, body: { user_code: rf.data.user_code } });
      const cur = (await fetchVerified(ALICE, S.uid, S.pins)).chain;
      const fBody = await buildBrowserApproval(S.A.identity, cur, vf.data, rf.data.user_code, vf.data.label, S.A.keyringBytes);
      const pf = `/api/v1/vault/devices/${F.id}/approve`;
      const asAinBob = await signedCall(S.A, BOB, S.uid, 'POST', pf, fBody);
      expect(asAinBob.status === 403 || asAinBob.status === 401, `alice's device signature in bob's session is refused (${asAinBob.status})`);
      const bobSigned = await signedCall(S.Bob, BOB, S.bobUid, 'POST', pf, { ...fBody, expected_version: 1 });
      expect(bobSigned.status === 404 || bobSigned.status === 403, `bob's own device cannot approve alice's pending device (${bobSigned.status})`);
      const bobSelf = await signedCall(S.A, BOB, S.bobUid, 'GET', '/api/v1/vault/devices/self');
      expect(bobSelf.status === 403, `alice's device cannot read self in bob's session (${bobSelf.status})`);
      const bobRevoke = await signedCall(S.Bob, BOB, S.bobUid, 'POST', `/api/v1/vault/devices/${S.A.id}/revoke`, { expected_version: 1, wraps: [] });
      expect(bobRevoke.status === 404 || bobRevoke.status === 403, `bob cannot revoke alice's device (${bobRevoke.status})`);
      const afterV = (await http('GET', '/api/v1/vault/directory', { user: ALICE })).data.version;
      expect(afterV === before, 'alice\'s directory unchanged by bob\'s attempts');

      // Hub-injected device row: a hostile hub (direct DB write) adds an "approved" browser.
      const M = await SimDevice.create(S.uid, 'injected');
      const { statementCanonical } = await import('../../src/ui/utils/vaultStatements.ts');
      const mst = statementCanonical({ type: 'approve', user_id: S.uid, directory_version: String(afterV - 1), issuer_device_id: S.A.id, issued_at_ms: String(Date.now()), ...M.subject(), epoch: '2', epoch_commit: cur.commits.get(2) });
      const db = new DatabaseSync(HUB.dbPath);
      try {
        db.exec('PRAGMA busy_timeout = 5000');
        db.prepare(`INSERT INTO vault_devices (device_id, user_id, kind, label, sign_alg, wrap_alg, sign_public_key, ecdh_public_key, fingerprint, status,
          approval_statement, approval_signature, approved_by_device_id, created_at, approved_at)
          VALUES (?, ?, 'browser', 'injected', ?, ?, ?, ?, ?, 'approved', ?, ?, ?, ?, ?)`)
          .run(M.id, S.uid, SIGN_ALG_ECDSA_P256_SHA256, WRAP_ALG_ECDH_P256_HKDF_AES, M.signPub, M.ecdhPub, M.fingerprint,
            mst, await M.signText(mst), S.A.id, new Date().toISOString(), new Date().toISOString());
      } finally { db.close(); }
      const inj = await fetchVerified(ALICE, S.uid, S.pins);
      expect(inj.dir.devices.some((d) => d.device_id === M.id && d.status === 'approved'), 'hub now serves the injected row as approved');
      expect(!inj.chain.trusted.has(M.id) && inj.chain.untrusted.some((d) => d.device_id === M.id), 'client chain verification marks it untrusted');
      expect(!wrapRecipients(inj.chain).some((d) => d.device_id === M.id), 'client wrap targets exclude it');
      // A rotation now: the client wraps only to trusted devices; the hub (which counts the
      // injected row) refuses, so the failure is availability, never a wrap to the attacker.
      const { body: rvBody, nextKeyring } = await buildRevocation(S.A.identity, inj.chain, S.bridge.identity.id, S.A.keyringBytes);
      nextKeyring.fill(0);
      expect(rvBody.wraps.every((w) => w.recipient_device_id !== M.id), 'no wrap was made for the injected device');
      const rv = await signedCall(S.A, ALICE, S.uid, 'POST', `/api/v1/vault/devices/${S.bridge.identity.id}/revoke`, rvBody);
      expect(rv.status === 400, `hub refuses the rotation that skips the injected row (fails closed, ${rv.status})`);
    });
  } finally {
    await HUB.stop();
  }
}

try {
  await main();
} catch (err) {
  results.push(['setup', 'FAIL']);
  console.log(`FAIL setup: ${err?.stack || err}`);
}
console.log('\n== summary');
for (const [name, r] of results) console.log(`${r} ${name}`);
const failed = results.filter(([, r]) => r !== 'PASS').length;
console.log(failed ? `${failed} step(s) FAILED` : 'all steps PASSED');
process.exit(failed ? 1 : 0);
