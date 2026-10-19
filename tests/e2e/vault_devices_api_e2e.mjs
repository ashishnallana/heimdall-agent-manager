// P2.5 — headless API end-to-end test of the passwordless vault device directory
// (docs/plans/passwordless-vault.md §2 "P2.5").
//
// Starts a THROWAWAY hub (ephemeral port, temp DB, temp cwd/HOME) and drives it over
// real HTTP with simulated devices built on the UI's own crypto modules
// (vaultKeyring.ts, vaultStatements.ts, vaultCrypto.ts, vaultBridgeUnseal.ts).
// Never touches a running dev hub/bridge or any OS keystore.
//
// Run through scripts/e2e-vault-devices.ps1 / .sh (they build the hub), or directly:
//   HEIMDALL_E2E_HUB_BIN=<ham-hub> HEIMDALL_E2E_MIGRATIONS_DIR=<repo>/src/hub/repository/sqlite/migrations \
//   node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/vault_devices_api_e2e.mjs
// Prints PASS/FAIL per step; exits non-zero on any FAIL.

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';

import { importKeyring, parseKeyringBytes, serializeKeyringBytes } from '../../src/ui/utils/vaultKeyring.ts';
import {
  STATEMENT_FIELDS, STATEMENT_HEADER, WRAP_ALG_ECDH_P256_HKDF_AES, WRAP_INFO, SIGN_ALG_ECDSA_P256_SHA256,
  bridgeUnsealKeyCanonical, ecdhHkdfAesKey, epochCommit, kindPolicy, openKeyringWrap, signP256,
  statementCanonical, toLowerHex, lowerHexToBytes, verifySignature, wrapAad, wrapSha256,
} from '../../src/ui/utils/vaultStatements.ts';
import { decryptVaultText, encryptVaultText, VAULT_LOCKED_MARKER } from '../../src/ui/utils/vaultCrypto.ts';
import { UNSEAL_V2_FORMAT, UNSEAL_V2_INFO, buildUnsealAad, prepareUnsealPayload } from '../../src/ui/utils/vaultBridgeUnseal.ts';

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
  // `ham-hub tokens issue` against the same temp DB: a user API token (hut_…).
  const issueUserToken = (userId) => {
    const r = spawnSync(bin, ['tokens', 'issue', '--user', userId, '--label', 'e2e', '--db', dbPath, '--migrations-dir', migrations], { cwd: dir, env, encoding: 'utf8' });
    const m = /token=\s*(hut_\S+)/.exec(r.stdout || '');
    if (!m) throw new Error(`tokens issue failed: ${r.stdout} ${r.stderr}`);
    return m[1];
  };
  return { base, port, dir, dbPath, stop, issueUserToken };
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

// ── crypto helpers ──────────────────────────────────────────────────────────

const sha256Hex = async (bytes) => toLowerHex(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)));
const b64url = (s) => Buffer.from(s, 'utf8').toString('base64url');
const randHex = (n) => toLowerHex(crypto.getRandomValues(new Uint8Array(n)));
const nonce = () => `n${randHex(16)}`;
const exportRawHex = async (k) => toLowerHex(new Uint8Array(await crypto.subtle.exportKey('raw', k)));
const deviceIdFor = async (signPubHex) => `dev_${(await sha256Hex(lowerHexToBytes(signPubHex))).slice(0, 32)}`;
async function fingerprintFor(signPubHex, ecdhPubHex) {
  const parts = [lowerHexToBytes(signPubHex)];
  if (ecdhPubHex) parts.push(lowerHexToBytes(ecdhPubHex));
  const h = (await sha256Hex(Buffer.concat(parts))).slice(0, 16);
  return `${h.slice(0, 4)} ${h.slice(4, 8)} ${h.slice(8, 12)} ${h.slice(12, 16)}`;
}

function parseStatement(text) {
  if (typeof text !== 'string') return null;
  const lines = text.split('\n');
  if (lines[0] !== STATEMENT_HEADER || lines.length !== STATEMENT_FIELDS.length + 1) return null;
  const st = {};
  for (let i = 0; i < STATEMENT_FIELDS.length; i++) {
    const line = lines[i + 1];
    const eq = line.indexOf('=');
    if (eq < 0 || line.slice(0, eq) !== STATEMENT_FIELDS[i]) return null;
    st[STATEMENT_FIELDS[i]] = line.slice(eq + 1);
  }
  try { return statementCanonical(st) === text ? st : null; } catch { return null; }
}

// ── simulated browser device ────────────────────────────────────────────────

class SimDevice {
  static async create(label, kind = 'browser') {
    const d = new SimDevice();
    d.label = label;
    d.kind = kind;
    d.sign = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify']);
    d.signPub = await exportRawHex(d.sign.publicKey);
    if (kind !== 'bridge') {
      d.ecdh = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
      d.ecdhPub = await exportRawHex(d.ecdh.publicKey);
    } else d.ecdhPub = '';
    d.id = await deviceIdFor(d.signPub);
    d.fingerprint = await fingerprintFor(d.signPub, d.ecdhPub);
    d.keyringBytes = null; // HKR1 (simulation keeps it; the UI only holds it transiently)
    d.keyring = null;
    return d;
  }
  subject() {
    return {
      subject_device_id: this.id, subject_kind: this.kind, subject_sign_pub: this.signPub, subject_ecdh_pub: this.ecdhPub,
      subject_sign_alg: SIGN_ALG_ECDSA_P256_SHA256, subject_wrap_alg: this.kind === 'bridge' ? '' : WRAP_ALG_ECDH_P256_HKDF_AES,
      subject_label_b64: b64url(this.label),
    };
  }
  async signText(text) { return signP256(this.sign.privateKey, enc.encode(text)); }
  async signedHeaders(userId, method, p, body = '', n = nonce(), ts = Date.now()) {
    const canonical = ['heimdall-device-request/v1', method, p, userId, String(ts), n, await sha256Hex(enc.encode(body))].join('\n');
    return {
      'X-Heimdall-Device-Id': this.id, 'X-Heimdall-Device-Ts': String(ts), 'X-Heimdall-Device-Nonce': n,
      'X-Heimdall-Device-Sig': await this.signText(canonical),
    };
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

function rawKeyFor(bytes, epoch) {
  const parsed = parseKeyringBytes(bytes);
  const e = parsed.entries.find((x) => x.epoch === epoch);
  const key = e ? Uint8Array.from(e.key) : null;
  for (const x of parsed.entries) x.key.fill(0);
  return key;
}
async function commitHex(bytes, userId, epoch) {
  const k = rawKeyFor(bytes, epoch);
  try { return toLowerHex(await epochCommit(k, userId, epoch)); } finally { k.fill(0); }
}

// Keyring wrap (plan §1 "Keyring wrap"): ephemeral ECDH → HKDF → AES-GCM, signed wrap statement.
async function sealWrap(signer, userId, recipient, version, keyringBytes) {
  const epoch = parseKeyringBytes(Uint8Array.from(keyringBytes)).currentEpoch;
  const eph = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
  const key = await ecdhHkdfAesKey(eph.privateKey, recipient.ecdh_public_key ?? recipient.ecdhPub, WRAP_INFO, ['encrypt']);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const rid = recipient.device_id ?? recipient.id;
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: enc.encode(wrapAad(userId, rid, version, epoch)), tagLength: 128 }, key, keyringBytes));
  const w = {
    alg: WRAP_ALG_ECDH_P256_HKDF_AES, recipient_device_id: rid, directory_version: version, current_epoch: epoch,
    ephemeral_public_key: await exportRawHex(eph.publicKey), iv: toLowerHex(iv), ciphertext: toLowerHex(ct), wrapped_by_device_id: signer.id,
  };
  const sha = await wrapSha256(w);
  const stmt = statementCanonical({ type: 'wrap', user_id: userId, directory_version: String(version), issuer_device_id: signer.id, subject_device_id: rid, epoch: String(epoch), wrap_sha256: sha });
  const sig = await signer.signText(stmt);
  return { sha, json: { v: 1, ...w, signature: JSON.parse(sig) } };
}

// Verify a received wrap's signature under its (chain-trusted) wrapper, then open it.
async function openWrap(dev, userId, wrapJson, trusted) {
  const { v, signature, ...w } = wrapJson;
  if (v !== 1) throw new Error('wrap version');
  const wrapper = trusted.get(w.wrapped_by_device_id);
  if (!wrapper || !kindPolicy(wrapper.kind).canApprove) throw new Error('wrap made by an untrusted device');
  const stmt = statementCanonical({ type: 'wrap', user_id: userId, directory_version: String(w.directory_version), issuer_device_id: w.wrapped_by_device_id, subject_device_id: w.recipient_device_id, epoch: String(w.current_epoch), wrap_sha256: await wrapSha256(w) });
  if (!(await verifySignature(wrapper.sign_alg, wrapper.sign_public_key, enc.encode(stmt), signature))) throw new Error('wrap signature does not verify');
  const parsed = await openKeyringWrap(w, userId, dev.ecdh.privateKey);
  try { return serializeKeyringBytes(parsed); } finally { for (const e of parsed.entries) e.key.fill(0); }
}

// ── client-side directory chain verification (fail closed) ──────────────────
// Walks genesis → approvals → revocations → epochs in directory_version order.
// Returns the chain-trusted approved devices and the signed epoch commits. A device
// row whose approval does not verify is reported in `untrusted` and never wrapped to;
// a bad genesis/revoke/epoch refuses the whole directory.
async function verifyDirectory(dir, userId, pinnedRootPub) {
  const g = parseStatement(dir.genesis?.statement);
  if (!g || g.type !== 'genesis' || g.user_id !== userId || g.directory_version !== '0' || g.epoch !== '1') throw new Error('genesis malformed');
  if (g.issuer_device_id !== g.subject_device_id || g.subject_device_id !== dir.root_device_id) throw new Error('genesis not self-issued by the root');
  if (pinnedRootPub && g.subject_sign_pub !== pinnedRootPub) throw new Error('root key differs from the pinned root');
  if (g.subject_device_id !== await deviceIdFor(g.subject_sign_pub)) throw new Error('root id/key mismatch');
  if (!(await verifySignature(g.subject_sign_alg, g.subject_sign_pub, enc.encode(dir.genesis.statement), dir.genesis.signature))) throw new Error('genesis signature');

  const rowMatches = (st, d) => st.subject_device_id === d.device_id && st.subject_kind === d.kind && st.subject_sign_pub === d.sign_public_key
    && st.subject_ecdh_pub === d.ecdh_public_key && st.subject_sign_alg === d.sign_alg && st.subject_wrap_alg === d.wrap_alg;
  const rootRow = dir.devices.find((d) => d.device_id === g.subject_device_id);
  if (!rootRow || !rowMatches(g, rootRow)) throw new Error('root device row does not match genesis');

  const trusted = new Map([[rootRow.device_id, rootRow]]);
  const commits = new Map();
  const e1 = dir.epochs.find((e) => e.epoch === 1);
  const e1st = parseStatement(e1?.statement);
  if (!e1st || e1st.type !== 'epoch' || e1st.epoch !== '1' || e1st.directory_version !== '0' || e1st.issuer_device_id !== rootRow.device_id || e1st.user_id !== userId) throw new Error('epoch 1 statement');
  if (!(await verifySignature(rootRow.sign_alg, rootRow.sign_public_key, enc.encode(e1.statement), e1.signature))) throw new Error('epoch 1 signature');
  commits.set(1, e1st.epoch_commit);

  const ops = [];
  const rank = { approve: 0, revoke: 1, epoch: 2 };
  for (const d of dir.devices) {
    if (d.status === 'pending' || d.device_id === rootRow.device_id) continue;
    const st = parseStatement(d.approval_statement);
    ops.push({ op: 'approve', st, text: d.approval_statement, sig: d.approval_signature, row: d, v: Number(st?.directory_version ?? -1) });
    if (d.status === 'revoked') {
      const rs = parseStatement(d.revocation_statement);
      ops.push({ op: 'revoke', st: rs, text: d.revocation_statement, sig: d.revocation_signature, row: d, v: Number(rs?.directory_version ?? -1) });
    }
  }
  for (const e of dir.epochs) {
    if (e.epoch === 1) continue;
    const st = parseStatement(e.statement);
    ops.push({ op: 'epoch', st, text: e.statement, sig: e.signature, v: Number(st?.directory_version ?? -1) });
  }
  ops.sort((a, b) => a.v - b.v || rank[a.op] - rank[b.op]);

  const untrusted = [];
  let epoch = 1;
  let lastRevoke = null;
  const usedVersions = new Set();
  for (const o of ops) {
    const st = o.st;
    const issuer = st && trusted.get(st.issuer_device_id);
    const sigOk = Boolean(st && issuer && kindPolicy(issuer.kind).canApprove && st.user_id === userId
      && await verifySignature(issuer.sign_alg, issuer.sign_public_key, enc.encode(o.text), o.sig));
    if (o.op === 'approve') {
      const ok = sigOk && st.type === 'approve' && rowMatches(st, o.row) && st.epoch === String(epoch)
        && o.v >= 1 && o.v < dir.version && !usedVersions.has(o.v) && o.row.device_id === await deviceIdFor(o.row.sign_public_key);
      if (!ok) { untrusted.push(o.row); continue; }
      usedVersions.add(o.v);
      trusted.set(o.row.device_id, o.row);
    } else if (o.op === 'revoke') {
      if (!sigOk || st.type !== 'revoke' || !rowMatches(st, o.row) || !trusted.has(o.row.device_id) || st.issuer_device_id === o.row.device_id || st.epoch !== String(epoch + 1) || usedVersions.has(o.v)) throw new Error(`revocation of ${o.row.device_id} does not verify`);
      usedVersions.add(o.v);
      trusted.delete(o.row.device_id);
      lastRevoke = { v: o.v, issuer: st.issuer_device_id };
    } else {
      if (!sigOk || st.type !== 'epoch' || st.epoch !== String(epoch + 1) || !/^[0-9a-f]{64}$/.test(st.epoch_commit) || !lastRevoke || lastRevoke.v !== o.v || lastRevoke.issuer !== st.issuer_device_id) throw new Error(`epoch statement ${st?.epoch} does not verify`);
      epoch += 1;
      commits.set(epoch, st.epoch_commit);
      lastRevoke = null;
    }
  }
  if (lastRevoke) throw new Error('revocation without a new epoch');
  if (epoch !== dir.current_epoch) throw new Error('current_epoch does not match the signed epochs');
  for (const d of dir.devices) if (d.status === 'approved' && !trusted.has(d.device_id) && !untrusted.includes(d)) untrusted.push(d);
  // Devices the hub marks revoked but the chain still trusts would be a hub lie the other way; refuse.
  for (const [id, d] of trusted) if (d.status !== 'approved') throw new Error(`device ${id} trusted by the chain but not approved on the hub`);
  return { trusted, untrusted, commits, currentEpoch: epoch, version: dir.version, rootSignPub: g.subject_sign_pub };
}

async function fetchVerified(dev, user, userId, pinnedRoot) {
  const r = await http('GET', '/api/v1/vault/directory', { user });
  if (r.status !== 200) throw new CheckFailed(`GET directory -> ${r.status} ${r.raw}`);
  return { dir: r.data, chain: await verifyDirectory(r.data, userId, pinnedRoot) };
}

const wrapTargets = (chain) => [...chain.trusted.values()].filter((d) => kindPolicy(d.kind).receivesWrap);

// ── simulated bridge (see the report: no real ham-bridge on Windows without the OS keystore) ──

class SimBridge {
  static async create() {
    const b = new SimBridge();
    b.identity = await SimDevice.create('e2e-bridge', 'bridge');
    b.ecdh = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
    b.ecdhPub = await exportRawHex(b.ecdh.publicKey);
    b.bootId = randHex(16);
    b.verifier = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url');
    b.challenge = Buffer.from(await crypto.subtle.digest('SHA-256', enc.encode(b.verifier))).toString('base64url');
    b.seenNonces = new Set();
    b.unlocked = false;
    return b;
  }
  // POST /device/authorize body, with the identity key's proof of possession over
  // "heimdall-bridge-enroll/v1\n<bridge_public_key>\n<code_challenge>".
  async authorizeBody(proofKey = this.identity) {
    const proof = await proofKey.signText(`heimdall-bridge-enroll/v1\n${this.ecdhPub}\n${this.challenge}`);
    return {
      client: 'ham-bridge', device_label: 'e2e-bridge', os: 'windows', os_user: 'e2e', app_version: 'e2e',
      bridge_public_key: this.ecdhPub, bridge_identity_public_key: this.identity.signPub,
      bridge_identity_proof: JSON.parse(proof),
      code_challenge: this.challenge, code_challenge_method: 'S256',
    };
  }
  async signUnsealKey() {
    this.unsealKeySig = await this.identity.signText(bridgeUnsealKeyCanonical(this.bridgeId, this.ecdhPub, this.bootId));
  }
  // Mirror of the bridge's unseal v2 checks, plus the P2/P3 chain proof (pinned root,
  // approved non-bridge issuer, epoch_commit) before anything is "installed".
  async receiveUnseal(payload, ownerUserId, chainDir) {
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
      const chain = await verifyDirectory(chainDir, ownerUserId, this.pinnedRoot);
      if (!chain.trusted.has(this.identity.id)) throw new Error('bridge is not chain-approved');
      if (chain.currentEpoch !== parsed.currentEpoch) throw new Error('keyring epoch is not the signed current epoch');
      if (await commitHex(plain, ownerUserId, parsed.currentEpoch) !== chain.commits.get(parsed.currentEpoch)) throw new Error('epoch_commit mismatch');
      this.seenNonces.add(payload.nonce);
      this.keyringBytes = Uint8Array.from(plain);
      this.unlocked = true;
      this.currentEpoch = parsed.currentEpoch;
    } finally { plain.fill(0); }
  }
}

// ── the scenario ────────────────────────────────────────────────────────────

const ALICE = 'e2e-alice';
const BOB = 'e2e-bob';
const S = {}; // shared state across steps

async function newKeyring(userId, entries) {
  // entries: [{epoch, key: Uint8Array}] ascending
  return serializeKeyringBytes({ userId, currentEpoch: entries[entries.length - 1].epoch, entries });
}

async function genesis(dev, user, userId, auth = { user }) {
  const kr = await newKeyring(userId, [{ epoch: 1, key: crypto.getRandomValues(new Uint8Array(32)) }]);
  const commit = await commitHex(kr, userId, 1);
  const wrap = await sealWrap(dev, userId, dev, 0, kr);
  const now = String(Date.now());
  const gst = statementCanonical({ type: 'genesis', user_id: userId, directory_version: '0', issuer_device_id: dev.id, issued_at_ms: now, ...dev.subject(), epoch: '1', epoch_commit: commit, wrap_sha256: wrap.sha });
  const est = statementCanonical({ type: 'epoch', user_id: userId, directory_version: '0', issuer_device_id: dev.id, issued_at_ms: now, epoch: '1', epoch_commit: commit });
  const r = await http('POST', '/api/v1/vault/directory/genesis', { ...auth, body: {
    genesis_statement: gst, signature: JSON.parse(await dev.signText(gst)),
    epoch_statement: est, epoch_signature: JSON.parse(await dev.signText(est)), wrap: wrap.json,
  } });
  return { r, kr };
}

async function register(dev, user, userId, auth = { user }) {
  const st = statementCanonical({ type: 'register', user_id: userId, issuer_device_id: dev.id, issued_at_ms: String(Date.now()), ...dev.subject() });
  return http('POST', '/api/v1/vault/devices/register', { ...auth, body: { statement: st, proof_signature: JSON.parse(await dev.signText(st)) } });
}

// Approver `a` approves the pending browser device described by /device/verify output `info`.
async function buildApproval(a, userId, chain, info, code) {
  const wrap = await sealWrap(a, userId, info, chain.version, a.keyringBytes);
  const st = statementCanonical({
    type: 'approve', user_id: userId, directory_version: String(chain.version), issuer_device_id: a.id, issued_at_ms: String(Date.now()),
    subject_device_id: info.device_id, subject_kind: info.device_kind, subject_sign_pub: info.sign_public_key, subject_ecdh_pub: info.ecdh_public_key,
    subject_sign_alg: info.sign_alg, subject_wrap_alg: info.wrap_alg, subject_label_b64: b64url(info.label || 'device'),
    epoch: String(chain.currentEpoch), epoch_commit: chain.commits.get(chain.currentEpoch), wrap_sha256: wrap.sha,
  });
  return { user_code: code, expected_version: chain.version, statement: st, signature: JSON.parse(await a.signText(st)), wrap: wrap.json };
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

    await step('1 device A: register + genesis, self-wrap, client chain verification', async () => {
      const none = await http('GET', '/api/v1/vault/directory', { user: ALICE });
      expect(none.status === 404, 'no directory before genesis (404)');
      S.A = await SimDevice.create('e2e device A');
      S.aliceToken = HUB.issueUserToken(S.uid);
      const viaToken = await genesis(S.A, ALICE, S.uid, { bearer: S.aliceToken });
      expect(viaToken.r.status === 403, `a user API token cannot genesis (${viaToken.r.status})`);
      const stillNone = await http('GET', '/api/v1/vault/directory', { user: ALICE });
      expect(stillNone.status === 404, 'still no directory after the refused token genesis');
      const { r, kr } = await genesis(S.A, ALICE, S.uid);
      expect(r.status === 201, `genesis -> 201 (${r.status})`);
      const again = await genesis(S.A, ALICE, S.uid);
      expect(again.r.status === 409, 'second genesis -> 409');
      const self = await signedCall(S.A, ALICE, S.uid, 'GET', '/api/v1/vault/devices/self');
      expect(self.status === 200 && self.data.status === 'approved' && self.data.wrap, 'A fetches its own wrap via /vault/devices/self');
      const { chain } = await fetchVerified(S.A, ALICE, S.uid, null);
      S.root = chain.rootSignPub;
      expect(S.root === S.A.signPub, 'chain verifies; root pinned to A');
      // Negative controls: the verifier is not vacuous.
      const { dir } = await fetchVerified(S.A, ALICE, S.uid, S.root);
      const notRoot = await SimDevice.create('not the root');
      await verifyDirectory(dir, S.uid, notRoot.signPub).then(() => expect(false, 'pin mismatch accepted'), () => expect(true, 'verifier refuses a directory whose root differs from the pin'));
      const flip = (s) => s.replace(/epoch_commit=[0-9a-f]/, (m) => m.slice(0, -1) + (m.endsWith('0') ? '1' : '0'));
      const tampered = { ...dir, epochs: dir.epochs.map((e) => ({ ...e, statement: flip(e.statement) })) };
      await verifyDirectory(tampered, S.uid, S.root).then(() => expect(false, 'tampered epoch accepted'), () => expect(true, 'verifier refuses a tampered epoch statement'));
      const bytes = await openWrap(S.A, S.uid, self.data.wrap, chain.trusted);
      expect(Buffer.compare(Buffer.from(bytes), Buffer.from(kr)) === 0, 'hub-stored self-wrap unwraps to the genesis keyring');
      expect(await commitHex(bytes, S.uid, 1) === chain.commits.get(1), 'epoch_commit(e1) matches the signed epoch statement');
      await S.A.setKeyring(bytes);
    });

    await step('2 device B: register -> pending code; A approves + wraps; B unwraps; cross-decrypt', async () => {
      S.B = await SimDevice.create('e2e device B');
      const reg = await register(S.B, ALICE, S.uid);
      expect(reg.status === 201 && reg.data.status === 'pending' && /^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$/.test(reg.data.user_code), `B registered pending with a code (${reg.status})`);
      expect(reg.data.device_id === S.B.id && reg.data.fingerprint === S.B.fingerprint, 'hub device id + fingerprint match B\'s local derivation');
      S.bCode = reg.data.user_code;
      const again = await register(S.B, ALICE, S.uid);
      expect(again.status === 200 && again.data.device_id === S.B.id && again.data.user_code === undefined, `repeat register -> ${again.status}, same device, no user_code`);
      const viaToken = await register(await SimDevice.create('token device'), ALICE, S.uid, { bearer: S.aliceToken });
      expect(viaToken.status === 403, `a user API token cannot register a device (${viaToken.status})`);      const pending = await signedCall(S.B, ALICE, S.uid, 'GET', '/api/v1/vault/devices/self');
      expect(pending.status === 200 && pending.data.status === 'pending' && !pending.data.wrap, 'B polls self: pending, no wrap');

      const ver = await http('POST', '/api/v1/device/verify', { user: ALICE, body: { user_code: S.bCode } });
      expect(ver.status === 200 && ver.data.kind === 'browser' && ver.data.device_id === S.B.id, '/device/verify resolves the code as kind=browser');
      expect(ver.data.fingerprint === S.B.fingerprint, 'A sees the fingerprint B displays (user comparison)');
      expect(await deviceIdFor(ver.data.sign_public_key) === S.B.id && await fingerprintFor(ver.data.sign_public_key, ver.data.ecdh_public_key) === S.B.fingerprint, 'A recomputes id + fingerprint from the served keys');
      const { chain } = await fetchVerified(S.A, ALICE, S.uid, S.root);
      const body = await buildApproval(S.A, S.uid, chain, ver.data, S.bCode);
      const unsigned = await http('POST', `/api/v1/vault/devices/${S.B.id}/approve`, { user: ALICE, body });
      expect(unsigned.status === 401, 'unsigned approval -> 401');
      const ok = await signedCall(S.A, ALICE, S.uid, 'POST', `/api/v1/vault/devices/${S.B.id}/approve`, body);
      expect(ok.status === 200 && ok.data.directory_version === chain.version + 1, `signed approval -> 200, version ${chain.version + 1}`);

      const self = await signedCall(S.B, ALICE, S.uid, 'GET', '/api/v1/vault/devices/self');
      expect(self.status === 200 && self.data.status === 'approved' && self.data.wrap, 'B polls self: approved, wrap present');
      const vb = await fetchVerified(S.B, ALICE, S.uid, null);
      expect(vb.chain.trusted.has(S.B.id), 'B verifies the chain and finds its own approval');
      S.rootB = vb.chain.rootSignPub;
      const bytes = await openWrap(S.B, S.uid, self.data.wrap, vb.chain.trusted);
      expect(await commitHex(bytes, S.uid, vb.chain.currentEpoch) === vb.chain.commits.get(vb.chain.currentEpoch), 'B checks epoch_commit before installing keys');
      await S.B.setKeyring(bytes);
      S.e1FromA = await encryptVaultText('secret from A @e1', S.A.keyring);
      S.e1FromB = await encryptVaultText('secret from B @e1', S.B.keyring);
      expect(S.e1FromA.startsWith('vault:v2:e1:') && S.e1FromB.startsWith('vault:v2:e1:'), 'both seal v2 content under e1');
      expect(await decryptVaultText(S.e1FromA, S.B.keyring) === 'secret from A @e1', 'B decrypts A\'s content');
      expect(await decryptVaultText(S.e1FromB, S.A.keyring) === 'secret from B @e1', 'A decrypts B\'s content');
    });

    await step('3 bridge: device-flow enrollment approved by A with vault_approval; unseal v2 (bridge side simulated)', async () => {
      const br = await SimBridge.create();
      S.bridge = br;
      const stranger = await SimDevice.create('not the identity', 'bridge');
      const noPop = await http('POST', '/api/v1/device/authorize', { body: await br.authorizeBody(stranger) });
      expect(noPop.status === 400, `authorize with an identity proof by another key -> 400 (${noPop.status})`);
      const authz = await http('POST', '/api/v1/device/authorize', { body: await br.authorizeBody() });
      expect(authz.status === 200 && authz.data.user_code && authz.data.device_code, `bridge /device/authorize -> 200 (${authz.status} ${authz.status !== 200 ? authz.raw : ''})`);
      const ver = await http('POST', '/api/v1/device/verify', { user: ALICE, body: { user_code: authz.data.user_code } });
      expect(ver.status === 200 && ver.data.kind === 'bridge' && ver.data.bridge_identity_public_key === br.identity.signPub, '/device/verify resolves kind=bridge with its identity key');
      const { chain } = await fetchVerified(S.A, ALICE, S.uid, S.root);
      const st = statementCanonical({
        type: 'approve', user_id: S.uid, directory_version: String(chain.version), issuer_device_id: S.A.id, issued_at_ms: String(Date.now()),
        ...br.identity.subject(), epoch: String(chain.currentEpoch), epoch_commit: chain.commits.get(chain.currentEpoch),
      });
      const noVa = await http('POST', '/api/v1/device/approve', { user: ALICE, body: { user_code: authz.data.user_code, approve: true } });
      expect(noVa.status === 400, 'bridge approval without vault_approval -> 400');
      const appr = await http('POST', '/api/v1/device/approve', { user: ALICE, body: {
        user_code: authz.data.user_code, approve: true,
        vault_approval: { expected_version: chain.version, statement: st, signature: JSON.parse(await S.A.signText(st)) },
      } });
      expect(appr.status === 200 && appr.data?.hub_observed?.bridge_id, `/device/approve with vault_approval -> 200 (${appr.status} ${appr.status !== 200 ? appr.raw : ''})`);
      const tok = await http('POST', '/api/v1/device/token', { body: { device_code: authz.data.device_code, code_verifier: br.verifier } });
      expect(tok.status === 200 && tok.data.bridge_id === appr.data.hub_observed.bridge_id && tok.data.access_token, 'bridge collects its credential with the PKCE verifier');
      br.bridgeId = tok.data.bridge_id;
      br.token = tok.data.access_token;
      br.pinnedRoot = S.root; // handed over by the approver at enrollment (plan §1 "Bridge keyring authentication")
      const asUser = await http('GET', '/api/v1/vault/directory', { bearer: br.token });
      expect(asUser.status === 403 || asUser.status === 401, `bridge token cannot read the vault directory (${asUser.status})`);

      const v = await fetchVerified(S.A, ALICE, S.uid, S.root);
      const row = v.chain.trusted.get(br.identity.id);
      expect(row && row.kind === 'bridge' && row.bridge_id === br.bridgeId, 'bridge identity is chain-approved in the directory, bound to its bridge_id');
      expect(!wrapTargets(v.chain).some((d) => d.kind === 'bridge'), 'no hub-stored wrap targets a bridge');
      await br.signUnsealKey();
      const target = { bridgeId: br.bridgeId, publicKey: br.ecdhPub, bootId: br.bootId, unsealKeySignature: br.unsealKeySig, identityPublicKey: row.sign_public_key };
      const forged = await SimDevice.create('forger', 'bridge');
      await prepareUnsealPayload({ ...target, unsealKeySignature: await forged.signText(bridgeUnsealKeyCanonical(br.bridgeId, br.ecdhPub, br.bootId)) }, Uint8Array.from(S.A.keyringBytes))
        .then(() => expect(false, 'unseal to a key signed by another identity must be refused'), () => expect(true, 'A refuses an unseal key not signed by the chain-approved identity'));
      const payload = await prepareUnsealPayload(target, Uint8Array.from(S.A.keyringBytes));
      await br.receiveUnseal(payload, S.uid, v.dir);
      expect(br.unlocked && br.currentEpoch === 1, 'simulated bridge verifies chain + epoch_commit and reports unlocked at e1');
      await br.receiveUnseal(payload, S.uid, v.dir).then(() => expect(false, 'replay accepted'), () => expect(true, 'replayed unseal payload refused'));
    });

    await step('4 A revokes B -> epoch 2; wraps to remaining; B cut off; e2 content', async () => {
      const { chain } = await fetchVerified(S.A, ALICE, S.uid, S.root);
      const old = parseKeyringBytes(Uint8Array.from(S.A.keyringBytes));
      const next = await newKeyring(S.uid, [...old.entries, { epoch: 2, key: crypto.getRandomValues(new Uint8Array(32)) }]);
      for (const e of old.entries) e.key.fill(0);
      const commit2 = await commitHex(next, S.uid, 2);
      const bRow = chain.trusted.get(S.B.id);
      const now = String(Date.now());
      const rst = statementCanonical({ type: 'revoke', user_id: S.uid, directory_version: String(chain.version), issuer_device_id: S.A.id, issued_at_ms: now,
        subject_device_id: bRow.device_id, subject_kind: bRow.kind, subject_sign_pub: bRow.sign_public_key, subject_ecdh_pub: bRow.ecdh_public_key,
        subject_sign_alg: bRow.sign_alg, subject_wrap_alg: bRow.wrap_alg, subject_label_b64: b64url(bRow.label), epoch: '2', epoch_commit: commit2 });
      const est = statementCanonical({ type: 'epoch', user_id: S.uid, directory_version: String(chain.version), issuer_device_id: S.A.id, issued_at_ms: now, epoch: '2', epoch_commit: commit2 });
      const remaining = wrapTargets(chain).filter((d) => d.device_id !== S.B.id);
      expect(remaining.length === 1 && remaining[0].device_id === S.A.id, 'remaining wrap recipients = {A} (bridge gets re-unseal, not a wrap)');
      const wraps = [];
      for (const d of remaining) wraps.push((await sealWrap(S.A, S.uid, d, chain.version, next)).json);
      const body = { expected_version: chain.version, revoke_statement: rst, signature: JSON.parse(await S.A.signText(rst)), epoch_statement: est, epoch_signature: JSON.parse(await S.A.signText(est)), wraps };
      const missing = await signedCall(S.A, ALICE, S.uid, 'POST', `/api/v1/vault/devices/${S.B.id}/revoke`, { ...body, wraps: [] });
      expect(missing.status === 400, `revoke with missing wraps -> 400 (${missing.status})`);
      const r = await signedCall(S.A, ALICE, S.uid, 'POST', `/api/v1/vault/devices/${S.B.id}/revoke`, body);
      expect(r.status === 200 && r.data.directory_version === chain.version + 1, `revoke -> 200, version ${chain.version + 1} (${r.status} ${r.status !== 200 ? r.raw : ''})`);

      const after = await fetchVerified(S.A, ALICE, S.uid, S.root);
      expect(after.chain.currentEpoch === 2 && !after.chain.trusted.has(S.B.id), 'chain verifies: epoch 2, B no longer trusted');
      const selfA = await signedCall(S.A, ALICE, S.uid, 'GET', '/api/v1/vault/devices/self');
      const bytes = await openWrap(S.A, S.uid, selfA.data.wrap, after.chain.trusted);
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
      const row = after.chain.trusted.get(br.identity.id);
      const payload = await prepareUnsealPayload({ bridgeId: br.bridgeId, publicKey: br.ecdhPub, bootId: br.bootId, unsealKeySignature: br.unsealKeySig, identityPublicKey: row.sign_public_key }, Uint8Array.from(S.A.keyringBytes));
      await br.receiveUnseal(payload, S.uid, after.dir);
      expect(br.currentEpoch === 2, 'simulated bridge re-unsealed at e2');
    });

    await step('5 attacks over raw HTTP', async () => {
      let { chain } = await fetchVerified(S.A, ALICE, S.uid, S.root);
      // Self-revoke.
      const self = await signedCall(S.A, ALICE, S.uid, 'POST', `/api/v1/vault/devices/${S.A.id}/revoke`, { expected_version: chain.version, wraps: [] });
      expect(self.status === 409 && self.raw.includes('"self_revoke"'),`self-revoke -> 409 self_revoke (${self.status})`);

      // Concurrent approvals of two pending devices at the same version: exactly one wins.
      const C = await SimDevice.create('e2e device C');
      const D = await SimDevice.create('e2e device D');
      const rc = await register(C, ALICE, S.uid);
      const rd = await register(D, ALICE, S.uid);
      expect(rc.status === 201 && rd.status === 201, 'C and D registered pending');
      const vc = await http('POST', '/api/v1/device/verify', { user: ALICE, body: { user_code: rc.data.user_code } });
      const vdv = await http('POST', '/api/v1/device/verify', { user: ALICE, body: { user_code: rd.data.user_code } });
      const bc = await buildApproval(S.A, S.uid, chain, vc.data, rc.data.user_code);
      const bd = await buildApproval(S.A, S.uid, chain, vdv.data, rd.data.user_code);
      const pc = `/api/v1/vault/devices/${C.id}/approve`;
      const pd = `/api/v1/vault/devices/${D.id}/approve`;
      const nC = nonce();
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
      const E = await SimDevice.create('forger');
      const fresh = (await fetchVerified(S.A, ALICE, S.uid, S.root)).chain;
      const fb = await buildApproval(S.A, S.uid, fresh, (loser === C ? vc : vdv).data, (loser === C ? rc : rd).data.user_code);
      const fh = await E.signedHeaders(S.uid, 'POST', loserPath, JSON.stringify(fb));
      fh['X-Heimdall-Device-Id'] = S.A.id;
      const forged = await http('POST', loserPath, { user: ALICE, body: JSON.stringify(fb), headers: fh });
      expect(forged.status === 401, `forged request signature -> 401 (${forged.status})`);
      // Body tampered after signing.
      const th = await S.A.signedHeaders(S.uid, 'POST', loserPath, JSON.stringify(fb));
      const tampered = await http('POST', loserPath, { user: ALICE, body: JSON.stringify({ ...fb, expected_version: fb.expected_version + 0, user_code: fb.user_code.toLowerCase() }), headers: th });
      expect(tampered.status === 401, `body tampered after signing -> 401 (${tampered.status})`);
      // Forged statement signature inside a correctly signed request.
      const badStmt = { ...fb, signature: JSON.parse(await E.signText(fb.statement)) };
      const fs1 = await signedCall(S.A, ALICE, S.uid, 'POST', loserPath, badStmt);
      expect(fs1.status === 401, `approval statement signed by a non-device key -> 401 (${fs1.status})`);
      // The loser can still be approved properly afterwards (directory unchanged by the failures).
      const good = await signedCall(S.A, ALICE, S.uid, 'POST', loserPath, fb);
      expect(good.status === 200, `loser approved with the fresh version (${good.status})`);

      // Other user's session.
      S.Bob = await SimDevice.create('bob device');
      const bg = await genesis(S.Bob, BOB, S.bobUid);
      expect(bg.r.status === 201, 'bob creates his own directory');
      const bobDir = await http('GET', '/api/v1/vault/directory', { user: BOB });
      expect(bobDir.status === 200 && bobDir.data.devices.length === 1 && bobDir.data.devices[0].device_id === S.Bob.id && !bobDir.raw.includes(S.A.id), 'bob sees only his own directory');
      const F = await SimDevice.create('e2e device F');
      const rf = await register(F, ALICE, S.uid);
      const bv = await http('POST', '/api/v1/device/verify', { user: BOB, body: { user_code: rf.data.user_code } });
      expect(bv.status === 404, `bob cannot resolve alice's pending code (${bv.status})`);
      const before = (await http('GET', '/api/v1/vault/directory', { user: ALICE })).data.version;
      const vf = await http('POST', '/api/v1/device/verify', { user: ALICE, body: { user_code: rf.data.user_code } });
      const cur = (await fetchVerified(S.A, ALICE, S.uid, S.root)).chain;
      const fBody = await buildApproval(S.A, S.uid, cur, vf.data, rf.data.user_code);
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
      const M = await SimDevice.create('injected');
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
      const inj = await fetchVerified(S.A, ALICE, S.uid, S.root);
      expect(inj.dir.devices.some((d) => d.device_id === M.id && d.status === 'approved'), 'hub now serves the injected row as approved');
      expect(!inj.chain.trusted.has(M.id) && inj.chain.untrusted.some((d) => d.device_id === M.id), 'client chain verification marks it untrusted');
      expect(!wrapTargets(inj.chain).some((d) => d.device_id === M.id), 'client wrap targets exclude it');
      // A rotation now: the client wraps only to trusted devices; the hub (which counts the
      // injected row) refuses, so the failure is availability, never a wrap to the attacker.
      const kr = parseKeyringBytes(Uint8Array.from(S.A.keyringBytes));
      const kr3 = await newKeyring(S.uid, [...kr.entries, { epoch: 3, key: crypto.getRandomValues(new Uint8Array(32)) }]);
      for (const e of kr.entries) e.key.fill(0);
      const c3 = await commitHex(kr3, S.uid, 3);
      const tgt = inj.chain.trusted.get(S.bridge.identity.id);
      const now = String(Date.now());
      const rst = statementCanonical({ type: 'revoke', user_id: S.uid, directory_version: String(inj.chain.version), issuer_device_id: S.A.id, issued_at_ms: now,
        subject_device_id: tgt.device_id, subject_kind: tgt.kind, subject_sign_pub: tgt.sign_public_key, subject_ecdh_pub: '', subject_sign_alg: tgt.sign_alg, subject_wrap_alg: '', subject_label_b64: b64url(tgt.label), epoch: '3', epoch_commit: c3 });
      const est = statementCanonical({ type: 'epoch', user_id: S.uid, directory_version: String(inj.chain.version), issuer_device_id: S.A.id, issued_at_ms: now, epoch: '3', epoch_commit: c3 });
      const wraps = [];
      for (const d of wrapTargets(inj.chain)) wraps.push((await sealWrap(S.A, S.uid, d, inj.chain.version, kr3)).json);
      kr3.fill(0);
      expect(wraps.every((w) => w.recipient_device_id !== M.id), 'no wrap was made for the injected device');
      const rv = await signedCall(S.A, ALICE, S.uid, 'POST', `/api/v1/vault/devices/${tgt.device_id}/revoke`, { expected_version: inj.chain.version, revoke_statement: rst, signature: JSON.parse(await S.A.signText(rst)), epoch_statement: est, epoch_signature: JSON.parse(await S.A.signText(est)), wraps });
      expect(rv.status === 400, `hub refuses the rotation that skips the injected row (fails closed, ${rv.status})`);
    });

    await step('6 deny a pending device; owner reset schedule + cancel', async () => {
      // Deny: an approver removes a pending device; it cannot then use or be approved.
      const G = await SimDevice.create('e2e device G');
      const rg = await register(G, ALICE, S.uid);
      expect(rg.status === 201 && rg.data.user_code, 'G registered pending');
      const brVerify = await http('POST', '/api/v1/device/verify', { bearer: S.bridge.token, body: { user_code: rg.data.user_code } });
      expect(brVerify.status === 403, `a bridge credential cannot resolve a browser code (${brVerify.status})`);
      const pg = `/api/v1/vault/devices/${G.id}/deny`;
      const unsigned = await http('POST', pg, { user: ALICE, body: '{}' });
      expect(unsigned.status === 401, `unsigned deny -> 401 (${unsigned.status})`);
      const bobDeny = await signedCall(S.Bob, BOB, S.bobUid, 'POST', pg, {});
      expect(bobDeny.status === 404, `bob cannot deny alice's pending device (${bobDeny.status})`);
      const denied = await signedCall(S.A, ALICE, S.uid, 'POST', pg, {});
      expect(denied.status === 200, `approver-signed deny -> 200 (${denied.status})`);
      const dir = await http('GET', '/api/v1/vault/directory', { user: ALICE });
      expect(!dir.raw.includes(G.id), 'denied device is gone from the directory');
      const gv = await http('POST', '/api/v1/device/verify', { user: ALICE, body: { user_code: rg.data.user_code } });
      expect(gv.status === 404, `denied device's code no longer resolves (${gv.status})`);
      const gSelf = await signedCall(G, ALICE, S.uid, 'GET', '/api/v1/vault/devices/self');
      expect(gSelf.status === 403, `denied device cannot poll self (${gSelf.status})`);
      const again = await signedCall(S.A, ALICE, S.uid, 'POST', pg, {});
      expect(again.status === 404, `deny of a non-pending device -> 404 (${again.status})`);
      const denyApproved = await signedCall(S.A, ALICE, S.uid, 'POST', `/api/v1/vault/devices/${S.A.id}/deny`, {});
      expect(denyApproved.status === 404, `deny cannot remove an approved device (${denyApproved.status})`);

      // Reset: the browser session schedules it (delayed); any approver cancels it.
      const tokReset = await http('POST', '/api/v1/vault/directory/reset', { bearer: S.aliceToken, body: '{}' });
      expect(tokReset.status === 403, `a user API token cannot schedule a reset (${tokReset.status})`);
      const r1 = await http('POST', '/api/v1/vault/directory/reset', { user: ALICE, body: '{}' });
      expect(r1.status === 201 && r1.data.reset?.requested_at && r1.data.reset?.due_at > r1.data.reset.requested_at, `reset scheduled -> 201 with a future due_at (${r1.status})`);
      const r2 = await http('POST', '/api/v1/vault/directory/reset', { user: ALICE, body: '{}' });
      expect(r2.status === 200 && r2.data.reset.due_at === r1.data.reset.due_at, 'repeat schedule -> 200, same due_at');
      const withReset = await http('GET', '/api/v1/vault/directory', { user: ALICE });
      expect(withReset.data.reset?.due_at === r1.data.reset.due_at, 'GET directory shows the scheduled reset');
      const bobView = await http('GET', '/api/v1/vault/directory', { user: BOB });
      expect(bobView.status === 200 && !bobView.data.reset, 'bob\'s directory has no reset');
      const unsignedCancel = await http('POST', '/api/v1/vault/directory/reset/cancel', { user: ALICE, body: '{}' });
      expect(unsignedCancel.status === 401, `unsigned cancel -> 401 (${unsignedCancel.status})`);
      const revokedCancel = await signedCall(S.B, ALICE, S.uid, 'POST', '/api/v1/vault/directory/reset/cancel', {});
      expect(revokedCancel.status === 403, `revoked B cannot cancel (${revokedCancel.status})`);
      const c1 = await signedCall(S.A, ALICE, S.uid, 'POST', '/api/v1/vault/directory/reset/cancel', {});
      expect(c1.status === 200 && c1.data.cancelled === true, 'approver-signed cancel -> cancelled:true');
      const c2 = await signedCall(S.A, ALICE, S.uid, 'POST', '/api/v1/vault/directory/reset/cancel', {});
      expect(c2.status === 200 && c2.data.cancelled === false, 'second cancel -> cancelled:false');
      const after = await http('GET', '/api/v1/vault/directory', { user: ALICE });
      expect(after.status === 200 && !after.data.reset, 'directory intact, reset null');
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
