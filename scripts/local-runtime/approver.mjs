// approver.mjs — the seed approver of a local hub: a vault device whose key lives in
// that hub's instance directory, so bridges (and the hub's browser) can be approved
// without a human. Every step goes through the hub's public API and the UI's own
// vault modules, exactly like the /api/v1/device/add page and
// tests/e2e/bridge_real_enroll_e2e.mjs; nothing is written to the database directly.
//
//   node --import <checkout>/tests/helpers/vaultEndpointHarness.ts approver.mjs <verb> \
//     --api <dev-proxy-url> --key <hub-dir>/approver/device.json [--code CODE] [--label NAME] [--user NAME]
//
//   --user  sign in as that dev user instead of the proxy's default
//           user. Each user has its own vault, so each needs its own --key.
//
//   init    create the user's vault genesis with a new approver device and save its
//           key. Idempotent: an existing key that the directory still trusts is kept.
//           Refused (exit 3) when the vault was created by another device first.
//   bridge  approve the bridge pairing code printed by `ham-bridge enroll` and
//           deliver the keyring to it (enrollment unseal).
//   device  approve a browser pairing code shown by the hub UI ("pair this browser").
//
// Why a key on disk: hub-blind pairing means the hub cannot approve a device; only a
// trusted device can sign the approval and unseal the keyring. Browser device keys are
// non-extractable and cannot outlive the page, so the seed approver keeps its
// PKCS#8 keys in a 0600 file instead and imports them non-extractable on each run.
// That file IS the account root of this local hub: it never leaves the instance
// directory, and it is only for local throwaway hubs.

import fs from 'node:fs';
import path from 'node:path';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { loadDeviceIdentity, memoryDeviceStore } from '../../src/ui/utils/deviceIdentity.ts';
import { signedRequestHeaders } from '../../src/ui/utils/vaultRequestSigner.ts';
import { verifyDirectory } from '../../src/ui/utils/vaultDirectoryVerify.ts';
import { openVerifiedWrap } from '../../src/ui/utils/vaultKeyringWrap.ts';
import { serializeKeyringBytes } from '../../src/ui/utils/vaultKeyring.ts';
import { deliverKeyringToBridge } from '../../src/ui/utils/vaultBridgeDelivery.ts';
import { bridgeUnsealTargetFromRecord } from '../../src/ui/utils/vaultBridgeUnseal.ts';
import { buildBridgeApproval, buildBrowserApproval, buildGenesis, checkBridgeCodeInfo, checkBrowserCodeInfo } from '../../src/ui/utils/vaultDeviceFlows.ts';
import { derivePairKeys, pairApproveMac } from '../../src/ui/utils/vaultPairing.ts';
import { hubLogin, sessionHeaders } from '../../tests/e2e/hubOidc.mjs';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export class Refused extends Error {
  constructor(message, code = 1) { super(message); this.code = code; }
}

const hex = (buf) => Buffer.from(buf).toString('hex');
const b64 = (buf) => Buffer.from(buf).toString('base64');

export function parseArgs(argv) {
  const [verb, ...rest] = argv;
  if (!['init', 'bridge', 'device'].includes(verb)) throw new Refused(`unknown verb '${verb ?? ''}' (init | bridge | device)`);
  const out = { verb, label: verb === 'device' ? 'Browser' : 'local-bridge' };
  for (let i = 0; i < rest.length; i += 2) {
    const k = rest[i].replace(/^--/, '');
    if (!['api', 'key', 'code', 'label', 'user'].includes(k) || rest[i + 1] === undefined) throw new Refused(`bad argument ${rest[i]}`);
    out[k] = rest[i + 1];
  }
  if (!out.api || !out.key) throw new Refused('--api and --key are required');
  if (verb !== 'init' && !out.code) throw new Refused(`${verb} needs --code`);
  return out;
}

// The dev-proxy user every request acts as ('' = the proxy's default user). The
// approver signs in like a browser (OIDC against the local mock provider) and
// reuses that session; Origin = $HEIMDALL_LOCAL_UI_ORIGIN satisfies the CSRF check.
let devUser = '';
const sessions = new Map();

async function http(api, method, p, { body, headers = {} } = {}) {
  const text = body === undefined ? undefined : JSON.stringify(body);
  const key = `${api}|${devUser}`;
  if (!sessions.has(key)) sessions.set(key, await hubLogin(api, devUser));
  const auth = sessionHeaders(sessions.get(key), process.env.HEIMDALL_LOCAL_UI_ORIGIN || api);
  const h = { ...auth, ...headers, ...(text === undefined ? {} : { 'Content-Type': 'application/json' }) };
  const res = await fetch(`${api}${p}`, { method, headers: h, body: text });
  const raw = await res.text();
  let json = null;
  try { json = JSON.parse(raw); } catch { /* not JSON */ }
  return { status: res.status, data: json?.data, raw };
}

async function userIdOf(api) {
  const me = await http(api, 'GET', '/api/v1/me');
  const userId = me.data?.user_id;
  if (!userId) throw new Refused(`cannot resolve the hub user (${me.status} ${me.raw})`);
  return userId;
}

// Hydrates a saved key file through the UI's own identity loader (non-extractable).
async function identityFromFile(file, userId) {
  const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (saved.v !== 1 || saved.userId !== userId) throw new Refused(`${file} belongs to another user (${saved.userId}), not ${userId}`);
  const pk = (s) => Buffer.from(s, 'base64');
  const store = memoryDeviceStore();
  await store.put(`identity:${userId}`, {
    v: 1, userId, createdAt: saved.createdAt, signPub: saved.signPub, ecdhPub: saved.ecdhPub,
    signPrivateKey: await crypto.subtle.importKey('pkcs8', pk(saved.signPkcs8), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']),
    ecdhPrivateKey: await crypto.subtle.importKey('pkcs8', pk(saved.ecdhPkcs8), { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']),
  });
  return loadDeviceIdentity(store, userId);
}

// A new identity whose private keys are exported once, to the key file only.
async function newIdentityFile(file, userId) {
  const sign = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const ecdh = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const saved = {
    v: 1, userId, createdAt: Date.now(),
    signPub: hex(await crypto.subtle.exportKey('raw', sign.publicKey)),
    ecdhPub: hex(await crypto.subtle.exportKey('raw', ecdh.publicKey)),
    signPkcs8: b64(await crypto.subtle.exportKey('pkcs8', sign.privateKey)),
    ecdhPkcs8: b64(await crypto.subtle.exportKey('pkcs8', ecdh.privateKey)),
  };
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(saved), { mode: 0o600 });
  return { tmp, saved };
}

async function chainOf(api, userId) {
  return verifyDirectory((await http(api, 'GET', '/api/v1/vault/directory')).data, userId, null);
}

export async function init({ api, key, user = '' }) {
  devUser = user;
  const userId = await userIdOf(api);
  if (fs.existsSync(key)) {
    const identity = await identityFromFile(key, userId);
    const chain = await chainOf(api, userId).catch(() => null);
    if (!chain?.trusted.has(identity.deviceId)) throw new Refused(`the hub's vault no longer trusts the seed approver in ${key}`, 3);
    return 'kept';
  }
  const { tmp, saved } = await newIdentityFile(key, userId);
  try {
    const identity = await identityFromFile(tmp, userId);
    const g = await http(api, 'POST', '/api/v1/vault/directory/genesis', { body: await buildGenesis(identity, 'local seed approver') });
    if (g.status !== 201) throw new Refused(`the hub's vault already has a root device (genesis ${g.status}); approve bridges in the hub UI`, 3);
    fs.renameSync(tmp, key);
    return `created ${identity.deviceId} (${saved.signPub.slice(0, 8)}…)`;
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}

async function approver(api, key) {
  if (!fs.existsSync(key)) throw new Refused(`no seed approver at ${key} (the hub was started with --no-seed, or its vault has another root)`);
  const userId = await userIdOf(api);
  const identity = await identityFromFile(key, userId);
  const signed = async (method, p, body = '') => signedRequestHeaders({ deviceId: identity.deviceId, signPrivateKey: identity.signPrivateKey }, userId, method, p, body);
  const selfPath = '/api/v1/vault/devices/self';
  const self = await http(api, 'GET', selfPath, { headers: await signed('GET', selfPath) });
  if (self.status !== 200) throw new Refused(`the hub does not serve the seed approver its keyring (${self.status} ${self.raw})`);
  const parsed = await openVerifiedWrap(self.data.wrap, { userId, recipientDeviceId: identity.deviceId, recipientEcdhPrivate: identity.ecdhPrivateKey, chain: await chainOf(api, userId) });
  const keyringBytes = serializeKeyringBytes(parsed);
  for (const e of parsed.entries) e.key.fill(0);
  return { userId, identity, signed, keyringBytes, chain: () => chainOf(api, userId) };
}

// Integration tools use the same verified seed-device/keyring path as bridge
// approvals. Local throwaway hubs only; caller must wipe keyringBytes.
export async function openSeedApprover({ api, key, user = '' }) {
  devUser = user;
  return approver(api, key);
}

// As the approval page does: stretch the code against every pending salt of `kind`
// and let the hub resolve the one lookup that matches.
async function lookUp(api, code, kind, userId) {
  const salts = await http(api, 'POST', '/api/v1/device/pair-salts', { body: {} });
  const tried = [];
  for (const c of (salts.data?.candidates ?? []).filter((x) => x.kind === kind)) {
    tried.push({ salt: c.pair_salt, keys: await derivePairKeys(code, { kind, userId: kind === 'browser' ? userId : '', hubOrigin: c.pair_hub_origin, pairSalt: c.pair_salt }) });
  }
  if (!tried.length) throw new Refused(`no pending ${kind} pairing on this hub (${salts.status} ${salts.raw})`);
  const ver = await http(api, 'POST', '/api/v1/device/verify', { body: { pair_lookups: tried.map((c) => c.keys.lookup) } });
  const keys = tried.find((c) => c.salt === ver.data?.pair_salt)?.keys;
  if (ver.status !== 200 || ver.data?.kind !== kind || !keys) throw new Refused(`the pairing code matches no pending ${kind} (${ver.status} ${ver.raw})`);
  return { info: ver.data, keys };
}

export async function approveBridge({ api, key, code, label, user = '' }) {
  devUser = user;
  const ap = await approver(api, key);
  try {
    const { info, keys } = await lookUp(api, code, 'bridge', ap.userId);
    await checkBridgeCodeInfo(info, keys);
    const { vault_approval, statement } = await buildBridgeApproval(ap.identity, await ap.chain(), info, label);
    const appr = await http(api, 'POST', '/api/v1/device/approve', { body: { pair_lookup: keys.lookup, approve: true, vault_approval, new_bridge_label: label } });
    const bridgeId = appr.data?.hub_observed?.bridge_id;
    if (appr.status !== 200 || !bridgeId) throw new Refused(`approve refused (${appr.status} ${appr.raw})`);
    // The enrolling process serves the unseal over its enroll-only connection.
    let target = null;
    for (const deadline = Date.now() + 60_000; !target; await sleep(250)) {
      const pk = await http(api, 'GET', `/api/v1/bridges/${bridgeId}/public-key?enrollment=1`);
      if (pk.status === 200 && pk.data?.unseal_key_signature) target = bridgeUnsealTargetFromRecord(bridgeId, pk.data);
      else if (Date.now() > deadline) throw new Refused(`bridge ${bridgeId} was approved but never connected for its keyring`);
    }
    const after = await ap.chain();
    const pairMac = await pairApproveMac(keys, statement, after.rootSignPub);
    await deliverKeyringToBridge(bridgeId, after, {
      fetchTarget: async () => target,
      dispatch: async (id, payload) => {
        const r = await http(api, 'POST', `/api/v1/bridges/${id}/unseal`, { body: payload });
        if (r.status !== 200 || r.data?.ok === false) throw new Refused(`unseal refused (${r.status} ${r.raw})`);
        return r.data;
      },
      withKeyringBytes: async (fn) => { const b = Uint8Array.from(ap.keyringBytes); try { return await fn(b); } finally { b.fill(0); } },
    }, { enrollment: true, expectedPublicKey: target.publicKey, extra: { enrollment: true, expected_public_key: target.publicKey, pair_mac: pairMac } });
    return `approved and unsealed ${bridgeId}`;
  } finally {
    ap.keyringBytes.fill(0);
  }
}

export async function approveDevice({ api, key, code, label, user = '' }) {
  devUser = user;
  const ap = await approver(api, key);
  try {
    const { info, keys } = await lookUp(api, code, 'browser', ap.userId);
    const browser = await checkBrowserCodeInfo(info, keys, ap.userId);
    const body = await buildBrowserApproval(ap.identity, await ap.chain(), browser, keys, browser.label || label, ap.keyringBytes);
    const p = `/api/v1/vault/devices/${encodeURIComponent(browser.device_id)}/approve`;
    const text = JSON.stringify(body);
    const r = await http(api, 'POST', p, { body, headers: await ap.signed('POST', p, text) });
    if (r.status !== 200) throw new Refused(`browser approval refused (${r.status} ${r.raw})`);
    return `approved browser ${browser.device_id} (${browser.fingerprint})`;
  } finally {
    ap.keyringBytes.fill(0);
  }
}

// Compared by real path: the checkout is often reached through a symlink
// (/home -> /var/home), and a plain URL comparison then silently skips main.
if (process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1])) {
  try {
    const a = parseArgs(process.argv.slice(2));
    const run = { init, bridge: approveBridge, device: approveDevice }[a.verb];
    console.log(`approver ${a.verb}: ${await run(a)}`);
  } catch (err) {
    console.error(`approver: ${err instanceof Refused ? err.message : (err?.stack || err)}`);
    process.exitCode = err instanceof Refused ? err.code : 1;
  }
}
