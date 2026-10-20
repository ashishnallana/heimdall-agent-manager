// Directory log verifier negatives (src/ui/utils/vaultDirectoryVerify.ts; plan §1
// "Directory log", §2 P3 required negatives). The hub is hostile: every way it can
// rewrite, extend, truncate or decorate the signed log must refuse the WHOLE
// directory, or (for rows the log does not vouch for) never make them wrap targets.
// Hermetic: an in-memory fake hub built with the production builders.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_vault_directory_verify_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, USER, browserRow, newBrowser, strangerSigner } from './helpers/vaultDirectoryFixture.ts';
import { DirectoryVerificationError, verifyDirectory, wrapRecipients } from '../src/ui/utils/vaultDirectoryVerify.ts';
import { PinViolationError } from '../src/ui/utils/deviceIdentity.ts';
import { buildRevocation } from '../src/ui/utils/vaultDeviceFlows.ts';

const refused = (re: RegExp) => (err: unknown) => {
  assert.ok(err instanceof DirectoryVerificationError, `expected a DirectoryVerificationError, got ${String(err)}`);
  assert.match((err as Error).message, re);
  return true;
};
const pinRefused = (re: RegExp) => (err: unknown) => {
  assert.ok(err instanceof PinViolationError, `expected a PinViolationError, got ${String(err)}`);
  assert.match((err as Error).message, re);
  return true;
};

/** root A (genesis) -> approves browser B -> approves bridge. Version 3, epoch 1. */
async function baseHub() {
  const hub = new FakeHub();
  const a = await newBrowser();
  const b = await newBrowser();
  await hub.genesis(a, 'Laptop');
  await hub.addBrowser(a, b, 'Phone');
  const bridge = await hub.addBridge(a, 'brg_1', 'build-box');
  return { hub, a, b, bridge };
}

test('baseline: the honest log verifies and names exactly its devices', async () => {
  const { hub, a, b, bridge } = await baseHub();
  const chain = await hub.chain();
  assert.equal(chain.version, 3);
  assert.equal(chain.currentEpoch, 1);
  assert.deepEqual([...chain.trusted.keys()].sort(), [a.deviceId, b.deviceId, bridge.deviceId].sort());
  assert.deepEqual(wrapRecipients(chain).map((d) => d.device_id).sort(), [a.deviceId, b.deviceId].sort(), 'bridges never get hub-stored wraps');
});

test('a hub-injected approved device row is untrusted and never a wrap target', async () => {
  const { hub, a } = await baseHub();
  const injected = await newBrowser();
  hub.rows.set(injected.deviceId, browserRow(injected, 'approved', 'Totally my laptop'));
  const chain = await hub.chain();
  assert.ok(!chain.trusted.has(injected.deviceId));
  assert.deepEqual(chain.untrusted.map((d) => d.device_id), [injected.deviceId]);
  assert.ok(!wrapRecipients(chain).some((d) => d.device_id === injected.deviceId));
  // A rotation (here: revoking the bridge) wraps to the log's devices only.
  const kr = await hub.keyringBytes(a);
  const bridgeId = [...chain.trusted.values()].find((d) => d.kind === 'bridge')!.device_id;
  const { body, nextKeyring } = await buildRevocation(a, chain, bridgeId, kr);
  nextKeyring.fill(0);
  kr.fill(0);
  assert.ok(!body.wraps.some((w) => w.recipient_device_id === injected.deviceId), 'no wrap for the injected device');
});

test('an approval signed by a device the log never approved is refused', async () => {
  const { hub } = await baseHub();
  const stranger = await strangerSigner();
  const victim = await newBrowser();
  const op = await hub.forgeOp(stranger, await hub.subjectOf(victim));
  await hub.append(op.statement, op.signature);
  hub.rows.set(victim.deviceId, browserRow(victim, 'approved'));
  await assert.rejects(hub.chain(), refused(/not a trusted approver/));
});

test('an approval naming the root as issuer but signed by another key is refused', async () => {
  const { hub, a } = await baseHub();
  const stranger = await strangerSigner();
  const victim = await newBrowser();
  const op = await hub.forgeOp({ deviceId: a.deviceId, signPrivateKey: stranger.signPrivateKey }, await hub.subjectOf(victim));
  await hub.append(op.statement, op.signature);
  hub.rows.set(victim.deviceId, browserRow(victim, 'approved'));
  await assert.rejects(hub.chain(), refused(/log op 4 signature/));
});

test('a revoked issuer cannot approve, even with an approval backdated before its revocation', async () => {
  const { hub, a, b } = await baseHub();
  const issuedBeforeRevoke = Date.now() - 60_000;
  await hub.addBrowser(a, await newBrowser(), 'Desk'); // seq 4: keeps a second approver besides A
  await hub.revoke(a, b.deviceId); // seq 5, epoch 2
  const victim = await newBrowser();
  // B signs at the next slot, claiming an issue time before it was revoked.
  const op = await hub.forgeOp(b, { ...(await hub.subjectOf(victim)), issued_at_ms: String(issuedBeforeRevoke) });
  await hub.append(op.statement, op.signature);
  hub.rows.set(victim.deviceId, browserRow(victim, 'approved'));
  await assert.rejects(hub.chain(), refused(/log op 6 is signed by a device that was not a trusted approver/));
});

test('a bridge identity can never sign log ops', async () => {
  const { hub, bridge } = await baseHub();
  const victim = await newBrowser();
  const op = await hub.forgeOp({ deviceId: bridge.deviceId, signPrivateKey: bridge.identity.privateKey }, await hub.subjectOf(victim));
  await hub.append(op.statement, op.signature);
  await assert.rejects(hub.chain(), refused(/not a trusted approver/));
});

test('a swapped root is refused against the pins', async () => {
  const { hub } = await baseHub();
  const pins = await hub.pins();
  const other = new FakeHub();
  await other.genesis(await newBrowser(), 'Laptop');
  await assert.rejects(other.chain(pins), pinRefused(/root differs/));
});

test('rollback: a shorter log than the pinned head is refused', async () => {
  const { hub } = await baseHub();
  const pins = await hub.pins();
  const dir = hub.dir();
  dir.log.pop();
  dir.version -= 1;
  dir.head_hash = (await hub.chain()).logHashes[1];
  dir.devices = dir.devices.filter((d) => d.kind !== 'bridge');
  await verifyDirectory(dir, USER); // a consistent shorter log on its own...
  await assert.rejects(verifyDirectory(dir, USER, pins), pinRefused(/rolled back/)); // ...is a rollback for a pinned device
});

test('fork: a different op at the pinned seq is refused', async () => {
  const { hub, a } = await baseHub();
  const pins = await hub.pins(); // head at seq 3 (the bridge approval)
  // The hub replaces op 3 with another validly signed op by the root.
  hub.log.pop();
  hub.rows.delete([...hub.rows.values()].find((r) => r.kind === 'bridge')!.device_id);
  await hub.rehash();
  await hub.addBridge(a, 'brg_other', 'other-box');
  await hub.chain(); // verifies on its own
  await assert.rejects(hub.chain(pins), pinRefused(/forked/));
});

test('deleting a revocation from the middle of the log breaks it', async () => {
  const { hub, a, b } = await baseHub();
  await hub.addBrowser(a, await newBrowser(), 'Desk'); // seq 4: keeps a second approver besides A
  await hub.revoke(a, b.deviceId); // seq 5
  await hub.addBrowser(a, await newBrowser(), 'Tablet'); // seq 6
  const dir = hub.dir();
  dir.log.splice(4, 1);
  dir.version -= 1;
  await assert.rejects(verifyDirectory(dir, USER), refused(/missing or out of order/));
  // Renumbering does not help: the signed seq / prev_hash no longer match.
  dir.log.forEach((op, i) => { op.seq = i + 1; });
  await assert.rejects(verifyDirectory(dir, USER), refused(/not linked/));
});

test('deleting the latest revocation is a rollback for a pinned device, and the hub row contradicts it', async () => {
  const { hub, a, b } = await baseHub();
  await hub.addBrowser(a, await newBrowser(), 'Desk'); // keeps a second approver besides A
  await hub.revoke(a, b.deviceId);
  const pins = await hub.pins();
  hub.log.pop();
  await hub.rehash();
  await assert.rejects(hub.chain(pins), pinRefused(/rolled back/));
  // Unpinned, the truncated log trusts B again — but the hub's own row says revoked.
  await assert.rejects(hub.chain(), refused(/trusted by the log but not approved on the hub/));
});

test('a gap in seq is refused', async () => {
  const { hub } = await baseHub();
  const dir = hub.dir();
  dir.log[2].seq = 4;
  await assert.rejects(verifyDirectory(dir, USER), refused(/missing or out of order/));
  const short = hub.dir();
  short.log.splice(1, 1); // version still says 3
  await assert.rejects(verifyDirectory(short, USER), refused(/2 ops for version 3/));
});

test('a broken prev_hash link is refused, even when the op is validly signed', async () => {
  const { hub, a } = await baseHub();
  const victim = await newBrowser();
  const op = await hub.forgeOp(a, { ...(await hub.subjectOf(victim)), prev_hash: 'ab'.repeat(32) });
  await hub.append(op.statement, op.signature);
  hub.rows.set(victim.deviceId, browserRow(victim, 'approved'));
  await assert.rejects(hub.chain(), refused(/log op 4 is not linked/));
  // And a served head_hash that is not the last op's hash is refused too.
  const honest = (await baseHub()).hub.dir();
  honest.head_hash = 'cd'.repeat(32);
  await assert.rejects(verifyDirectory(honest, USER), refused(/head_hash/));
});
