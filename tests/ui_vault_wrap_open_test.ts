// Opening a keyring wrap addressed to this device (src/ui/utils/vaultKeyringWrap.ts
// openVerifiedWrap; plan §1 "Keyring wrap", §2 P3 negatives). A wrap is accepted only
// when it names this device, verifies under a chain-trusted approver, lies in the
// current epoch's segment of the verified log, decrypts under its AAD, and carries
// the keyring whose epoch_commit the signed log names. Hermetic fake hub.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_vault_wrap_open_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, USER, newBrowser } from './helpers/vaultDirectoryFixture.ts';
import { openVerifiedWrap, sealKeyringWrap, WrapRejectedError } from '../src/ui/utils/vaultKeyringWrap.ts';
import { genesisKeyringBytes } from '../src/ui/utils/vaultKeyringSession.ts';
import type { DeviceIdentity } from '../src/ui/utils/deviceIdentity.ts';
import type { VerifiedChain } from '../src/ui/utils/vaultDirectoryVerify.ts';

const rejected = (re: RegExp) => (err: unknown) => {
  assert.ok(err instanceof WrapRejectedError, `expected a WrapRejectedError, got ${String(err)}`);
  assert.match((err as Error).message, re);
  return true;
};

function open(wrap: unknown, me: DeviceIdentity, chain: VerifiedChain) {
  return openVerifiedWrap(wrap, { userId: USER, recipientDeviceId: me.deviceId, recipientEcdhPrivate: me.ecdhPrivateKey, chain });
}

/** Root A, browser B (approved by A at seq 2, its wrap made at version 2). */
async function setup() {
  const hub = new FakeHub();
  const a = await newBrowser();
  const b = await newBrowser();
  await hub.genesis(a);
  await hub.addBrowser(a, b, 'Phone');
  return { hub, a, b, chain: await hub.chain() };
}

test('baseline: B opens its own wrap', async () => {
  const { hub, b, chain } = await setup();
  const parsed = await open(hub.wraps.get(b.deviceId), b, chain);
  assert.equal(parsed.currentEpoch, 1);
  for (const e of parsed.entries) e.key.fill(0);
});

test('a wrap for another recipient is refused, also when the hub relabels it', async () => {
  const { hub, a, b, chain } = await setup();
  await assert.rejects(open(hub.wraps.get(a.deviceId), b, chain), rejected(/different recipient/));
  // Relabelled to B: the maker's signature covers the recipient, so it no longer verifies.
  const relabelled = { ...hub.wraps.get(a.deviceId)!, recipient_device_id: b.deviceId };
  await assert.rejects(open(relabelled, b, chain), rejected(/signature does not verify/));
});

test('an AAD mismatch is refused even when a trusted approver signed the altered wrap', async () => {
  const { hub, a, b, chain } = await setup();
  // A seals the real keyring to B at version 2, then the version field is changed
  // to 1 (still inside epoch 1's window) and RE-SIGNED by A: only the AEAD's AAD
  // (which binds user, recipient, version and epoch) can catch it.
  const kr = await hub.keyringBytes(a);
  const sealed = await sealKeyringWrap(a, USER, { device_id: b.deviceId, ecdh_public_key: b.ecdhPub, wrap_alg: b.wrapAlg }, 2, kr);
  const resigned = (await sealKeyringWrap(a, USER, { device_id: b.deviceId, ecdh_public_key: b.ecdhPub, wrap_alg: b.wrapAlg }, 1, kr)).json;
  kr.fill(0);
  const swapped = { ...sealed.json, directory_version: 1, signature: undefined as unknown };
  // Re-sign the altered body with A's key (the wrap statement the opener rebuilds).
  const { wrapSha256, statementCanonical, signP256 } = await import('../src/ui/utils/vaultStatements.ts');
  const { v: _v, signature: _s, ...body } = swapped as any;
  const sha = await wrapSha256(body);
  const stmt = statementCanonical({ type: 'wrap', user_id: USER, seq: '1', issuer_device_id: a.deviceId, subject_device_id: b.deviceId, epoch: '1', wrap_sha256: sha });
  swapped.signature = JSON.parse(await signP256(a.signPrivateKey, new TextEncoder().encode(stmt)));
  await assert.rejects(open(swapped, b, chain), rejected(/cannot open/));
  // Control: the honestly sealed version-1 wrap opens.
  const ok = await open(resigned, b, chain);
  for (const e of ok.entries) e.key.fill(0);
});

test('a wrap of a keyring whose epoch_commit differs from the signed log is refused', async () => {
  const { a, b, chain } = await setup();
  // A trusted approver wraps a DIFFERENT epoch-1 keyring (a hub-chosen key) to B.
  const fake = genesisKeyringBytes(USER, chain.vaultId);
  const w = await sealKeyringWrap(a, USER, { device_id: b.deviceId, ecdh_public_key: b.ecdhPub, wrap_alg: b.wrapAlg }, 2, fake);
  fake.fill(0);
  await assert.rejects(open(w.json, b, chain), rejected(/epoch_commit does not match/));
});

test('a wrap whose version lies outside the current epoch window is refused', async () => {
  const { hub, a, b } = await setup();
  const c = await newBrowser();
  await hub.addBrowser(a, c, 'Tablet'); // seq 3
  await hub.revoke(a, c.deviceId); // seq 4 introduces epoch 2
  const chain = await hub.chain();
  assert.equal(chain.currentEpoch, 2);
  const kr = await hub.keyringBytes(a); // epoch-2 keyring
  try {
    const before = await sealKeyringWrap(a, USER, { device_id: b.deviceId, ecdh_public_key: b.ecdhPub, wrap_alg: b.wrapAlg }, 3, kr);
    await assert.rejects(open(before.json, b, chain), rejected(/outside the current epoch/), 'version 3 precedes the epoch-2 op at seq 4');
    const ahead = await sealKeyringWrap(a, USER, { device_id: b.deviceId, ecdh_public_key: b.ecdhPub, wrap_alg: b.wrapAlg }, 5, kr);
    await assert.rejects(open(ahead.json, b, chain), rejected(/outside the current epoch/), 'version 5 is past the verified head');
    const ok = await open(hub.wraps.get(b.deviceId), b, chain); // the revoke's own wrap at version 4
    assert.equal(ok.currentEpoch, 2);
    for (const e of ok.entries) e.key.fill(0);
  } finally {
    kr.fill(0);
  }
});

test('a wrap at a non-current epoch is refused', async () => {
  const { hub, a, b } = await setup();
  const oldWrap = hub.wraps.get(b.deviceId);
  const c = await newBrowser();
  await hub.addBrowser(a, c, 'Tablet');
  await hub.revoke(a, c.deviceId);
  await assert.rejects(open(oldWrap, b, await hub.chain()), rejected(/not the signed current epoch/));
});

test('a wrap made by a device that is not a chain-trusted approver is refused', async () => {
  const { hub, a, b, chain } = await setup();
  const outsider = await newBrowser();
  const kr = await hub.keyringBytes(a);
  const w = await sealKeyringWrap(outsider, USER, { device_id: b.deviceId, ecdh_public_key: b.ecdhPub, wrap_alg: b.wrapAlg }, 2, kr);
  kr.fill(0);
  await assert.rejects(open(w.json, b, chain), rejected(/not a chain-trusted approver/));
});
