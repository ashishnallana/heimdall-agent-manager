// Hub-blind pairing end to end (plan §1 "Hub-blind pairing"; vaultDeviceFlows +
// services/deviceVault). The approver refuses a request whose key_mac does not verify
// under the code it typed (wrong code, or the hub swapped the device's keys); the new
// device installs keys and pins the root ONLY with a pair_mac that verifies under its
// own live code. Hermetic: fake hub, memory device store, fake clock.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_vault_pairing_flow_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, USER, browserPairCtx, hubApi, newBrowser, recorder } from './helpers/vaultDirectoryFixture.ts';

const dv = await import('../src/ui/services/deviceVault.ts');
const ident = await import('../src/ui/utils/deviceIdentity.ts');
const { checkBrowserCodeInfo, checkBridgeCodeInfo, buildPairedRegistration, FlowRefused } = await import('../src/ui/utils/vaultDeviceFlows.ts');
const { derivePairKeys, generatePairCode, generatePairSalt, pairKeyMac, pairBridgePayload, pairApproveMac, PAIR_CODE_TTL_MS } = await import('../src/ui/utils/vaultPairing.ts');
const { getActiveVaultKey } = await import('../src/ui/utils/vaultCrypto.ts');

const flowRefused = (re: RegExp) => (err: unknown) => {
  assert.ok(err instanceof FlowRefused, `expected FlowRefused, got ${String(err)}`);
  assert.match((err as Error).message, re);
  return true;
};

// ── approver side ────────────────────────────────────────────────────────────

async function pendingBrowser() {
  const hub = new FakeHub();
  const a = await newBrowser();
  await hub.genesis(a);
  const b = await newBrowser();
  const code = generatePairCode();
  const salt = generatePairSalt();
  const keys = await derivePairKeys(code, browserPairCtx(salt));
  const reg = await buildPairedRegistration(b, 'Phone', keys);
  await hub.register(reg.statement, reg.pairLookup, reg.pairKeyMac, salt);
  return { hub, a, b, code, keys };
}

test('approver: the right code verifies the request (control)', async () => {
  const { hub, b, keys } = await pendingBrowser();
  const paired = await checkBrowserCodeInfo(hub.codeInfo(keys.lookup), keys, USER);
  assert.equal(paired.device_id, b.deviceId);
  assert.equal(paired.fingerprint, b.fingerprint);
});

test('approver: a wrong code is refused even if the hub serves the real request for it', async () => {
  const { hub, keys } = await pendingBrowser();
  const wrong = await derivePairKeys(generatePairCode(), browserPairCtx(generatePairSalt()));
  await assert.rejects(checkBrowserCodeInfo(hub.codeInfo(keys.lookup), wrong, USER), flowRefused(/pairing check failed/));
});

test('approver: a hub that swaps the device keys is refused', async () => {
  const { hub, keys } = await pendingBrowser();
  const info = hub.codeInfo(keys.lookup);
  // (1) Its own device's register statement under the victim's key_mac.
  const evil = await newBrowser();
  const evilReg = await buildPairedRegistration(evil, 'Phone', await derivePairKeys(generatePairCode(), browserPairCtx(generatePairSalt())));
  await assert.rejects(
    checkBrowserCodeInfo({ ...info, register_statement: evilReg.statement, device_id: evil.deviceId, sign_public_key: evil.signPub, ecdh_public_key: evil.ecdhPub }, keys, USER),
    flowRefused(/pairing check failed/),
  );
  // (2) The MACed statement kept, but the row's wrap key swapped: what would be wrapped to.
  await assert.rejects(checkBrowserCodeInfo({ ...info, ecdh_public_key: evil.ecdhPub }, keys, USER), flowRefused(/different device/));
});

test('approver: a bridge request whose identity key the hub swapped is refused', async () => {
  const keys = await derivePairKeys(generatePairCode(), { kind: 'bridge', userId: '', hubOrigin: 'https://hub.example.test:443', pairSalt: generatePairSalt() });
  const hexKey = async (name: 'ECDSA' | 'ECDH') => {
    const kp = await crypto.subtle.generateKey({ name, namedCurve: 'P-256' }, true, name === 'ECDSA' ? ['sign', 'verify'] : ['deriveBits']) as CryptoKeyPair;
    return Buffer.from(await crypto.subtle.exportKey('raw', kp.publicKey)).toString('hex');
  };
  const identity = await hexKey('ECDSA');
  const ecdh = await hexKey('ECDH');
  const challenge = 'pkce-challenge_1';
  const info: any = {
    kind: 'bridge', is_bridge_enrollment: true, bridge_identity_public_key: identity, bridge_public_key: ecdh,
    hub_observed: { bridge_public_key_on_record: ecdh }, code_challenge: challenge,
    pair_key_mac: await pairKeyMac(keys, 'bridge', pairBridgePayload(identity, ecdh, challenge)),
  };
  await checkBridgeCodeInfo(info, keys); // control
  await assert.rejects(checkBridgeCodeInfo({ ...info, bridge_identity_public_key: await hexKey('ECDSA') }, keys), flowRefused(/pairing check failed/));
  const other = await hexKey('ECDH');
  await assert.rejects(checkBridgeCodeInfo({ ...info, bridge_public_key: other, hub_observed: { bridge_public_key_on_record: other } }, keys), flowRefused(/pairing check failed/));
  await assert.rejects(checkBridgeCodeInfo({ ...info, hub_observed: { bridge_public_key_on_record: other } }, keys), flowRefused(/two different bridge keys/));
});

// ── new device side (deviceVault) ────────────────────────────────────────────

/**
 * Boot a NEW browser B against a hub whose root A exists: B registers and shows its
 * code; A types it and approves. `selfOverride` lets the hub lie in /devices/self.
 */
async function pairNewDevice(selfOverride?: (self: any) => any) {
  const hub = new FakeHub();
  const a = await newBrowser();
  await hub.genesis(a);
  const kv = ident.memoryDeviceStore();
  const base = hubApi(hub);
  dv.configureDeviceVault({
    kv, bridges: null, pollIntervalMs: 1e9,
    api: hubApi(hub, {
      fetchVaultSelf: async (signed: any) => {
        const self = await base.fetchVaultSelf(signed);
        return self && selfOverride ? selfOverride(self) : self;
      },
    }),
  });
  const rec = recorder();
  dv.stopDeviceVault();
  await dv.bootDeviceVault(USER, rec.dispatch);
  const pending = rec.last('deviceVault/deviceVaultStatusChanged');
  assert.equal(pending.status, 'pending-approval');
  const code = pending.userCode as string;
  assert.match(code, /^[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{2}$/);
  const { deviceId } = await hub.approveByCode(a, code);
  return { hub, a, kv, rec, code, deviceId };
}

async function assertNothingInstalled(kv: any, rec: ReturnType<typeof recorder>) {
  assert.equal(getActiveVaultKey(), null, 'no keyring installed');
  assert.equal(await ident.loadPins(kv, USER), null, 'no root pinned');
  assert.ok(!rec.actions.some((x) => x.type === 'vault/keyringInstalled'));
}

test('new device: a valid pair_mac installs the keyring and pins the root (control)', async () => {
  const { hub, kv, rec, deviceId } = await pairNewDevice();
  await dv.refreshDeviceVault('approved');
  assert.equal(rec.last('deviceVault/deviceVaultStatusChanged').status, 'ready');
  assert.ok(getActiveVaultKey(), 'keyring installed');
  assert.equal((await ident.loadPins(kv, USER))!.root_device_id, hub.rootDeviceId);
  assert.equal(await kv.get(`pending:${USER}`), undefined, 'the secret code is wiped once paired');
  assert.equal((await ident.loadDeviceIdentity(kv, USER))!.deviceId, deviceId);
  dv.stopDeviceVault();
});

for (const [name, mutate] of [
  ['missing', (self: any) => ({ ...self, pair_mac: '' })],
  ['malformed', (self: any) => ({ ...self, pair_mac: 'not-hex' })],
] as const) {
  test(`new device: a ${name} pair_mac is refused; nothing installed`, async () => {
    const { kv, rec } = await pairNewDevice(mutate);
    await dv.refreshDeviceVault('approved');
    assert.equal(rec.last('deviceVault/deviceVaultFailed').code, 'pairing_mismatch');
    await assertNothingInstalled(kv, rec);
    dv.stopDeviceVault();
  });
}

test('new device: a pair_mac forged under another code (or for another root) is refused', async () => {
  let forged = '';
  const { hub, kv, rec, deviceId } = await pairNewDevice((self) => ({ ...self, pair_mac: forged }));
  const approval = (await hub.chain()).trusted.get(deviceId)!.approval_statement;
  // A hub without the code can only MAC under a code it chose.
  forged = await pairApproveMac(await derivePairKeys(generatePairCode(), browserPairCtx(generatePairSalt())), approval, (await hub.chain()).rootSignPub);
  await dv.refreshDeviceVault('approved');
  assert.equal(rec.last('deviceVault/deviceVaultFailed').code, 'pairing_mismatch');
  await assertNothingInstalled(kv, rec);
  dv.stopDeviceVault();
});

test('new device: an expired pairing code is never used, even with a valid pair_mac', async (t) => {
  const { kv, rec } = await pairNewDevice();
  // Fake clock: past the code TTL plus the 60 s clock grace.
  t.mock.timers.enable({ apis: ['Date'], now: Date.now() + PAIR_CODE_TTL_MS + 61_000 });
  await dv.refreshDeviceVault('approved-late');
  assert.equal(rec.last('deviceVault/deviceVaultFailed').code, 'pairing_unverified');
  await assertNothingInstalled(kv, rec);
  assert.equal(await kv.get(`pending:${USER}`), undefined, 'the expired code is discarded');
  dv.stopDeviceVault();
});
