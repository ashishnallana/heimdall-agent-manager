// A hub-asserted "revoked" never deletes this browser's keys (services/deviceVault.ts;
// plan §1 "Directory log": "a hub-only 'revoked' never deletes keys"). Keys in memory
// are dropped at once (fail closed), but the stored identity and pins stay, and the
// device treats itself as revoked — and may discard its identity — only when the
// VERIFIED signed log revokes its id. Hermetic: fake hub, memory store.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_vault_revoked_status_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, USER, hubApi, newBrowser, recorder } from './helpers/vaultDirectoryFixture.ts';

const dv = await import('../src/ui/services/deviceVault.ts');
const ident = await import('../src/ui/utils/deviceIdentity.ts');
const { getActiveVaultKey } = await import('../src/ui/utils/vaultCrypto.ts');

type Lie = { revoked: boolean };

/** Boot browser `me` (a non-root device, paired through deviceVault) to ready. */
async function readyBrowser(lie: Lie) {
  const hub = new FakeHub();
  const root = await newBrowser();
  await hub.genesis(root, 'Laptop');
  const kv = ident.memoryDeviceStore();
  const base = hubApi(hub);
  dv.configureDeviceVault({
    kv, bridges: null, pollIntervalMs: 1e9,
    api: hubApi(hub, {
      fetchVaultSelf: async (signed: any) => {
        const self = await base.fetchVaultSelf(signed);
        return self && lie.revoked ? { ...self, status: 'revoked', wrap: null } : self;
      },
    }),
  });
  const rec = recorder();
  dv.stopDeviceVault();
  await dv.bootDeviceVault(USER, rec.dispatch);
  const { deviceId } = await hub.approveByCode(root, rec.last('deviceVault/deviceVaultStatusChanged').userCode, 'Phone');
  await dv.refreshDeviceVault('approved');
  assert.equal(rec.last('deviceVault/deviceVaultStatusChanged').status, 'ready');
  assert.ok(getActiveVaultKey());
  return { hub, root, kv, rec, deviceId, pins: await ident.loadPins(kv, USER) };
}

test('the hub alone saying "revoked" drops in-memory keys but keeps the identity and pins', async () => {
  const lie: Lie = { revoked: false };
  const { kv, rec, deviceId, pins } = await readyBrowser(lie);
  lie.revoked = true;
  await dv.refreshDeviceVault('hub-says-revoked');
  assert.equal(rec.last('deviceVault/deviceVaultFailed').code, 'unverified_revocation');
  assert.notEqual(rec.last('deviceVault/deviceVaultStatusChanged').status, 'revoked');
  assert.equal(getActiveVaultKey(), null, 'fail closed: nothing decrypts meanwhile');
  assert.equal((await ident.loadDeviceIdentity(kv, USER))?.deviceId, deviceId, 'identity kept');
  assert.deepEqual(await ident.loadPins(kv, USER), pins, 'pins kept');
  // Re-enrolling (which discards the identity) is not offered on the hub's word.
  await assert.rejects(dv.requestNewApproval(), /not verifiably revoked/);
  assert.equal((await ident.loadDeviceIdentity(kv, USER))?.deviceId, deviceId);
  // The hub stops lying: the same identity is ready again.
  lie.revoked = false;
  await dv.refreshDeviceVault('hub-recovered');
  assert.equal(rec.last('deviceVault/deviceVaultStatusChanged').status, 'ready');
  assert.ok(getActiveVaultKey());
  dv.stopDeviceVault();
});

test('a revocation in the verified log marks the device revoked; only then may it re-enroll', async () => {
  const { hub, root, kv, rec, deviceId, pins } = await readyBrowser({ revoked: false });
  // The last-approver guard refuses to leave the root as the only approver.
  await hub.addBrowser(root, await newBrowser(), 'Tablet');
  await hub.revoke(root, deviceId);
  await dv.refreshDeviceVault('revoked');
  assert.equal(rec.last('deviceVault/deviceVaultStatusChanged').status, 'revoked');
  assert.equal(getActiveVaultKey(), null);
  assert.equal((await ident.loadDeviceIdentity(kv, USER))?.deviceId, deviceId, 'nothing deleted until the user asks');
  await dv.requestNewApproval();
  const fresh = await ident.loadDeviceIdentity(kv, USER);
  assert.ok(fresh && fresh.deviceId !== deviceId, 'a new identity was created');
  assert.equal((await ident.loadPins(kv, USER))?.root_sign_pub, pins!.root_sign_pub, 'the pinned root is kept across re-enrollment');
  assert.equal(rec.last('deviceVault/deviceVaultStatusChanged').status, 'pending-approval');
  dv.stopDeviceVault();
});
