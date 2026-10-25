// Called by test_account_billing_http.py against its isolated real hub.
// UI vault modules generate genuine enrollment proofs and signed approvals.
import { DatabaseSync } from 'node:sqlite';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { createDeviceIdentity, memoryDeviceStore } from '../../src/ui/utils/deviceIdentity.ts';
import { signP256 } from '../../src/ui/utils/vaultStatements.ts';
import { verifyDirectory } from '../../src/ui/utils/vaultDirectoryVerify.ts';
import { buildBridgeApproval, buildGenesis, checkBridgeCodeInfo } from '../../src/ui/utils/vaultDeviceFlows.ts';
import { derivePairKeys, generatePairCode, generatePairSalt, pairBridgePayload, pairHubOrigin, pairKeyMac } from '../../src/ui/utils/vaultPairing.ts';
import { hubLogin, sessionHeaders } from './hubOidc.mjs';

const base = process.argv[2];
assert.match(base, /^http:\/\/127\.0\.0\.1:\d+$/);
const uiOrigin = process.argv[4] || base;
const user = 'alice';
const utf8 = new TextEncoder();
// The caller's hub is configured against the mock OIDC provider: sign in as a browser.
const session = await hubLogin(base, user);
async function http(method, path, body, extra = {}) {
  const res = await fetch(base + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...sessionHeaders(session, uiOrigin), ...extra },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(5000),
  });
  return { status: res.status, body: await res.json() };
}
function ok(response, status) {
  assert.equal(response.status, status, JSON.stringify(response));
  return response.body.data;
}
const approver = await createDeviceIdentity(memoryDeviceStore(), user);
ok(await http('POST', '/api/v1/vault/directory/genesis', await buildGenesis(approver, 'plan smoke')), 201);
async function chain() {
  return verifyDirectory(ok(await http('GET', '/api/v1/vault/directory'), 200), user, null);
}
async function grant() {
  const identity = await createDeviceIdentity(memoryDeviceStore(), user);
  const ecdh = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
  const publicKey = Buffer.from(await crypto.subtle.exportKey('raw', ecdh.publicKey)).toString('hex');
  const verifier = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url');
  const challenge = Buffer.from(await crypto.subtle.digest('SHA-256', utf8.encode(verifier))).toString('base64url');
  const salt = generatePairSalt();
  const origin = pairHubOrigin(base);
  const keys = await derivePairKeys(generatePairCode(), { kind: 'bridge', userId: '', hubOrigin: origin, pairSalt: salt });
  const proof = JSON.parse(await signP256(identity.signPrivateKey,
    utf8.encode(['heimdall-bridge-enroll/v1', publicKey, challenge].join('\n'))));
  ok(await http('POST', '/api/v1/device/authorize', {
    client: 'ham-bridge', device_label: 'plan-smoke-bridge', os: 'linux', os_user: 'test', app_version: '1.0.0',
    bridge_public_key: publicKey, bridge_identity_public_key: identity.signPub,
    bridge_identity_proof: proof, code_challenge: challenge, code_challenge_method: 'S256',
    pair_lookup: keys.lookup, pair_salt: salt, pair_hub_origin: origin,
    pair_key_mac: await pairKeyMac(keys, 'bridge', pairBridgePayload(identity.signPub, publicKey, challenge)),
  }), 200);
  const info = ok(await http('POST', '/api/v1/device/verify', { pair_lookup: keys.lookup }), 200);
  await checkBridgeCodeInfo(info, keys);
  return { info, keys };
}
async function approve(g, target = '') {
  const { vault_approval } = await buildBridgeApproval(approver, await chain(), g.info, 'plan smoke bridge');
  return http('POST', '/api/v1/device/approve', {
    pair_lookup: g.keys.lookup, approve: true, vault_approval,
    ...(target ? { target_bridge_id: target } : { new_bridge_label: 'plan smoke bridge' }),
  });
}
const first = ok(await approve(await grant()), 200).hub_observed;
assert.equal(first.enrollment_pending, true);
const second = await grant();
const refused = await approve(second);
assert.equal(refused.status, 402, JSON.stringify(refused));
assert.equal(refused.body.error.code, 'plan_limit_reached');
assert.equal(refused.body.error.details.limit, 'max_bridges');
assert.equal(refused.body.error.details.allowed, 1);
assert.equal(refused.body.error.details.current, 1);
assert.equal(refused.body.error.details.plan_label, 'Free');
assert.equal(refused.body.error.details.upgrade_path, '/settings/account');
// No bridge process runs in this fixture. Mark the first durable enrollment
// complete to exercise reuse of an existing enrolled bridge through the real API.
const db = new DatabaseSync(process.argv[3]);
try {
  db.prepare("UPDATE bridges SET enrollment_pending_until = '' WHERE bridge_id = ?").run(first.bridge_id);
} finally { db.close(); }
const reused = ok(await approve(await grant(), first.bridge_id), 200).hub_observed;
assert.equal(reused.bridge_id, first.bridge_id, 'reuse is allowed at the bridge cap');
assert.equal(reused.enrollment_pending, true);

const event = {
  event_id: 'evt_approval_upgrade', event_type: 'subscription.updated', occurred_at: '2026-10-22T01:00:00Z',
  data: {
    id: 'sub_alice', customer_id: 'ctm_alice', status: 'active',
    custom_data: { heimdall_checkout_reference: 'server_reference' }, scheduled_change: null,
    next_billed_at: '2026-11-10T10:00:00Z', items: [{ price: { id: 'pri_approved' } }],
  },
};
const timestamp = String(Math.floor(Date.now() / 1000));
const signature = createHmac('sha256', 'test_only_secret').update(timestamp + ':' + JSON.stringify(event)).digest('hex');
ok(await http('POST', '/api/v1/billing/paddle/webhook', event, { 'Paddle-Signature': 'ts=' + timestamp + ';h1=' + signature }), 200);
const upgraded = ok(await approve(second), 200).hub_observed;
assert.notEqual(upgraded.bridge_id, first.bridge_id, 'upgrade immediately admits the previously refused grant');
assert.equal(upgraded.enrollment_pending, true);
const bridges = ok(await http('GET', '/api/v1/bridges'), 200);
assert.equal(bridges.length, 1, 'the second bridge is still pending and hidden from ordinary lists');
const counts = new DatabaseSync(process.argv[3]);
try {
  assert.equal(counts.prepare("SELECT COUNT(*) AS n FROM bridges WHERE owner_user_id = 'alice'").get().n, 2);
} finally { counts.close(); }
console.log('PASS bridge approval cap, pending count, reuse, upgrade');
