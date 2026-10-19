// Recovery key (src/ui/utils/vaultRecovery.ts; plan §2 P4). Hermetic fake hub built
// with the production builders: create -> restore round trip, wrong words, another
// account's words, a tampered blob, a revoked recovery key, and the last-approver
// guard the recovery key unlocks.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_vault_recovery_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, USER, newBrowser } from './helpers/vaultDirectoryFixture.ts';
import { asApproverIdentity, buildRecoveryKey, openRecoveryKey, RecoveryKeyError } from '../src/ui/utils/vaultRecovery.ts';
import { generate12RecoveryWords, recoveryWordsToEntropy } from '../src/ui/utils/vaultCrypto.ts';
import { buildBrowserApproval, buildPairedRegistration, buildRevocation, FlowRefused } from '../src/ui/utils/vaultDeviceFlows.ts';
import { derivePairKeys, generatePairCode } from '../src/ui/utils/vaultPairing.ts';
import { openVerifiedWrap } from '../src/ui/utils/vaultKeyringWrap.ts';
import { serializeKeyringBytes } from '../src/ui/utils/vaultKeyring.ts';
import type { DeviceIdentity } from '../src/ui/utils/deviceIdentity.ts';

const refused = (re: RegExp) => (err: unknown) => {
  assert.ok(err instanceof RecoveryKeyError, `expected a RecoveryKeyError, got ${String(err)}`);
  assert.match((err as Error).message, re);
  return true;
};

/** Create a recovery key for `words` approved by `approver` (what Settings -> Devices does). */
async function addRecovery(hub: FakeHub, approver: DeviceIdentity, words: string[]): Promise<string> {
  const chain = await hub.chain();
  const kr = await hub.keyringBytes(approver);
  const entropy = recoveryWordsToEntropy(words);
  try {
    const { body, deviceId } = await buildRecoveryKey(approver, chain, kr, entropy);
    await hub.append(body.statement, body.signature);
    const st = body.statement.split('\n');
    const field = (k: string) => st.find((l) => l.startsWith(`${k}=`))!.slice(k.length + 1);
    hub.rows.set(deviceId, {
      device_id: deviceId, kind: 'recovery', label: 'Recovery key', status: 'approved',
      sign_alg: field('subject_sign_alg'), wrap_alg: field('subject_wrap_alg'),
      sign_public_key: field('subject_sign_pub'), ecdh_public_key: field('subject_ecdh_pub'),
      approved_by_device_id: approver.deviceId, recovery_blob: body.recovery_blob,
    });
    hub.wraps.set(deviceId, body.wrap);
    return deviceId;
  } finally {
    kr.fill(0);
    entropy.fill(0);
  }
}

async function setup() {
  const hub = new FakeHub();
  const a = await newBrowser();
  await hub.genesis(a);
  const { words } = generate12RecoveryWords();
  const rid = await addRecovery(hub, a, words);
  return { hub, a, words, rid };
}

test('create -> restore: a new browser is approved AS the recovery key and opens its own wrap', async () => {
  const { hub, words, rid } = await setup();
  const chain = await hub.chain();
  assert.equal(chain.trusted.get(rid)?.kind, 'recovery', 'the recovery credential is chain-trusted');
  // The recovery credential received a wrap like any wrap-capable device.
  const cred = await openRecoveryKey(words, chain);
  assert.equal(cred.deviceId, rid);
  // A fresh browser C (pending, holding its own pairing code) restores.
  const c = await newBrowser();
  const code = generatePairCode();
  const keys = await derivePairKeys(code);
  const reg = await buildPairedRegistration(c, 'New laptop', keys);
  await hub.register(reg.statement, reg.pairLookup, reg.pairKeyMac);
  const parsed = await openVerifiedWrap(hub.wraps.get(rid), { userId: USER, recipientDeviceId: rid, recipientEcdhPrivate: cred.ecdhPrivateKey, chain });
  const kr = serializeKeyringBytes(parsed);
  for (const e of parsed.entries) e.key.fill(0);
  const me = { device_id: c.deviceId, sign_public_key: c.signPub, ecdh_public_key: c.ecdhPub, sign_alg: c.signAlg, wrap_alg: c.wrapAlg, label: 'New laptop', fingerprint: c.fingerprint, register_statement: reg.statement };
  const body = await buildBrowserApproval(asApproverIdentity(cred), chain, me, keys, 'New laptop', kr);
  kr.fill(0);
  await hub.append(body.statement, body.signature);
  Object.assign(hub.row(c.deviceId), { status: 'approved', label: 'New laptop', approved_by_device_id: rid });
  hub.wraps.set(c.deviceId, body.wrap);
  const after = await hub.chain();
  assert.equal(after.trusted.get(c.deviceId)?.approved_by_device_id, rid, 'the log shows C approved by the recovery key');
  const mine = await openVerifiedWrap(hub.wraps.get(c.deviceId), { userId: USER, recipientDeviceId: c.deviceId, recipientEcdhPrivate: c.ecdhPrivateKey, chain: after });
  assert.equal(mine.currentEpoch, after.currentEpoch);
  for (const e of mine.entries) e.key.fill(0);
});

test('wrong words fail cleanly; malformed words too', async () => {
  const { hub } = await setup();
  const chain = await hub.chain();
  await assert.rejects(openRecoveryKey(generate12RecoveryWords().words, chain), refused(/do not open/));
  await assert.rejects(openRecoveryKey(['abandon', 'ability'], chain), refused(/not 12 valid recovery words/));
});

test("another account's words (and its blob moved onto this account's row) fail", async () => {
  const { hub } = await setup();
  const otherHub = new FakeHub('usr_other_account');
  const b = await newBrowser('usr_other_account');
  await otherHub.genesis(b);
  const { words: otherWords } = generate12RecoveryWords();
  const otherRid = await addRecovery(otherHub, b, otherWords);
  await assert.rejects(openRecoveryKey(otherWords, await hub.chain()), refused(/do not open/));
  // The hub copies the other account's blob onto this account's recovery row: the AAD
  // binds user and device id, so even the matching words do not open it here.
  const myRow = [...hub.rows.values()].find((r) => r.kind === 'recovery')!;
  myRow.recovery_blob = otherHub.row(otherRid).recovery_blob;
  await assert.rejects(openRecoveryKey(otherWords, await hub.chain()), refused(/do not open/));
});

test('a tampered blob fails', async () => {
  const { hub, words, rid } = await setup();
  const row = hub.row(rid);
  const blob = JSON.parse(row.recovery_blob!);
  blob.ciphertext = (blob.ciphertext[0] === '0' ? '1' : '0') + blob.ciphertext.slice(1);
  row.recovery_blob = JSON.stringify(blob);
  await assert.rejects(openRecoveryKey(words, await hub.chain()), refused(/do not open/));
});

test('a revoked recovery key opens nothing and cannot approve', async () => {
  const { hub, a, words, rid } = await setup();
  const b = await newBrowser();
  await hub.addBrowser(a, b, 'Phone');
  const cred = await openRecoveryKey(words, await hub.chain());
  await hub.revoke(a, rid); // A revokes it (B remains besides A)
  await assert.rejects(openRecoveryKey(words, await hub.chain()), refused(/no active recovery key/));
  // An approval it signs afterwards makes the whole log refuse.
  const x = await newBrowser();
  const op = await hub.forgeOp(cred, { type: 'approve', ...(await hub.subjectOf(x)), epoch: String(hub.currentEpoch) } as any);
  await hub.append(op.statement, op.signature);
  await assert.rejects(hub.chain());
});

test('last-approver guard: the only other approver cannot be revoked until a recovery key exists', async () => {
  const hub = new FakeHub();
  const a = await newBrowser();
  const b = await newBrowser();
  await hub.genesis(a);
  await hub.addBrowser(a, b, 'Phone');
  const kr = await hub.keyringBytes(a);
  try {
    await assert.rejects(buildRevocation(a, await hub.chain(), b.deviceId, kr), (e: unknown) => e instanceof FlowRefused && /recovery key/.test(String((e as Error).message)));
  } finally {
    kr.fill(0);
  }
  await addRecovery(hub, a, generate12RecoveryWords().words);
  await hub.revoke(a, b.deviceId);
  assert.ok((await hub.chain()).revokedIds.has(b.deviceId));
});
