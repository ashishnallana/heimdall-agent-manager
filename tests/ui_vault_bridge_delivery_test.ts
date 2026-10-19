// Keyring delivery to bridges (utils/vaultBridgeDelivery.ts, services/deviceVault.ts
// automatic delivery; plan §1 "Bridge keyring authentication", "Directory log" M1).
// Keys go only to a bridge identity the VERIFIED log approves and the hub has not
// retired, over an ephemeral key signed by that identity, with a chain proof the
// bridge accepts. Automatic delivery skips everything else and pauses entirely while
// the verified head is stale. Hermetic: fake hub, fake bridge transport, memory store.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_vault_bridge_delivery_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, USER, hubApi, recorder, type FakeBridge } from './helpers/vaultDirectoryFixture.ts';

const dv = await import('../src/ui/services/deviceVault.ts');
const ident = await import('../src/ui/utils/deviceIdentity.ts');
const { deliverKeyringToBridge, BridgeDeliveryRefused } = await import('../src/ui/utils/vaultBridgeDelivery.ts');
const { bridgeUnsealTargetFromRecord } = await import('../src/ui/utils/vaultBridgeUnseal.ts');
const { verifyBridgeChainProof } = await import('../src/ui/utils/vaultDirectoryVerify.ts');

/** Root A with an approved bridge (brg_ok) and an approved-then-hub-retired one (brg_hint). */
async function account(kv = ident.memoryDeviceStore()) {
  const hub = new FakeHub();
  const a = await ident.createDeviceIdentity(kv, USER);
  await hub.genesis(a);
  const ok = await hub.addBridge(a, 'brg_ok');
  const hinted = await hub.addBridge(a, 'brg_hint');
  hub.retiredHints = [hinted.deviceId];
  return { hub, a, kv, bridges: { brg_ok: ok, brg_hint: hinted } as Record<string, FakeBridge> };
}

/** A bridge transport: serves each bridge's signed unseal record, records deliveries. */
function transport(bridges: Record<string, FakeBridge>, serve: (id: string) => Promise<Record<string, unknown>> = (id) => bridges[id].unsealRecord()) {
  const fetched: string[] = [];
  const delivered: Array<{ bridgeId: string; payload: any }> = [];
  return {
    fetched,
    delivered,
    fetchTarget: async (id: string) => { fetched.push(id); return bridgeUnsealTargetFromRecord(id, await serve(id)); },
    dispatch: async (bridgeId: string, payload: any) => { delivered.push({ bridgeId, payload }); return { type: 'bridge_unseal_result', command_id: payload.command_id, ok: true }; },
  };
}

async function deps(hub: FakeHub, a: any, t: ReturnType<typeof transport>) {
  return {
    fetchTarget: (id: string, _enrollment: boolean) => t.fetchTarget(id),
    dispatch: t.dispatch,
    withKeyringBytes: async <T>(fn: (b: Uint8Array) => Promise<T>) => {
      const bytes = await hub.keyringBytes(a);
      try { return await fn(bytes); } finally { bytes.fill(0); }
    },
  };
}

test('delivery to a chain-approved bridge carries a chain proof the bridge accepts', async () => {
  const { hub, a, bridges } = await account();
  const chain = await hub.chain();
  const t = transport(bridges);
  await deliverKeyringToBridge('brg_ok', chain, await deps(hub, a, t));
  assert.equal(t.delivered.length, 1);
  const { payload } = t.delivered[0];
  assert.equal(payload.bridge_identity_public_key, bridges.brg_ok.identityPub, 'the identity the LOG approved');
  const root = await verifyBridgeChainProof(payload.chain_proof, [{ epoch: 1, commit: chain.commits.get(1)! }], {
    ownerUserId: USER, bridgeIdentityPub: bridges.brg_ok.identityPub, pinnedRootSignPub: null,
  });
  assert.equal(root, chain.rootSignPub);
  // The proof names THIS bridge: another bridge identity refuses it.
  await assert.rejects(verifyBridgeChainProof(payload.chain_proof, [{ epoch: 1, commit: chain.commits.get(1)! }], {
    ownerUserId: USER, bridgeIdentityPub: bridges.brg_hint.identityPub, pinnedRootSignPub: null,
  }), /bridge approval/);
});

test('an unapproved or hub-retired bridge gets nothing, not even a key fetch', async () => {
  const { hub, a, bridges } = await account();
  const chain = await hub.chain();
  const t = transport(bridges);
  for (const id of ['brg_unknown', 'brg_hint']) {
    await assert.rejects(deliverKeyringToBridge(id, chain, await deps(hub, a, t)), (err) => err instanceof BridgeDeliveryRefused, id);
  }
  assert.deepEqual(t.fetched, []);
  assert.deepEqual(t.delivered, []);
});

test('a served identity, ephemeral key or signature the log does not back is refused', async () => {
  const { hub, a, bridges } = await account();
  const chain = await hub.chain();
  // (1) The hub serves another bridge's (validly signed) record for brg_ok.
  const swapped = transport(bridges, async () => ({ ...(await bridges.brg_hint.unsealRecord()), bridge_id: 'brg_ok' }));
  await assert.rejects(deliverKeyringToBridge('brg_ok', chain, await deps(hub, a, swapped)), /differs from the approved one/);
  // (2) Enrollment: the process now holds a different key than the operator saw.
  const t = transport(bridges);
  await assert.rejects(deliverKeyringToBridge('brg_ok', chain, await deps(hub, a, t), { enrollment: true, expectedPublicKey: '04' + 'ab'.repeat(64) }), /different unseal key/);
  // (3) An unsigned ephemeral key, or one signed by an identity the log never approved.
  const unsigned = transport(bridges, async () => ({ ...(await bridges.brg_ok.unsealRecord()), unseal_key_signature: '' }));
  await assert.rejects(deliverKeyringToBridge('brg_ok', chain, await deps(hub, a, unsigned)), /unsigned/);
  const otherSig = transport(bridges, async () => {
    const rec = await bridges.brg_ok.unsealRecord();
    const forged = await bridges.brg_hint.unsealRecord();
    return { ...rec, unseal_key_signature: forged.unseal_key_signature };
  });
  await assert.rejects(deliverKeyringToBridge('brg_ok', chain, await deps(hub, a, otherSig)), /does not verify/);
  assert.equal(swapped.delivered.length + t.delivered.length + unsigned.delivered.length + otherSig.delivered.length, 0);
});

// ── automatic delivery (deviceVault) ────────────────────────────────────────

async function bootReady(opts: { staleHead?: boolean } = {}) {
  const { hub, a, kv, bridges } = await account();
  if (opts.staleHead) {
    // This device last saw this exact head 8 days ago and was offline for 2 days: M1.
    const now = Date.now();
    await kv.put(`head-freshness:${USER}`, { head_seq: hub.version, head_hash: hub.headHash, head_changed_at: now - 8 * 86_400_000, last_fetch_at: now - 2 * 86_400_000, stale: false });
  }
  const t = transport(bridges);
  const locked: string[] = [];
  let revokes = 0;
  dv.configureDeviceVault({
    kv, pollIntervalMs: 1e9,
    api: hubApi(hub, { postRevokeDevice: async () => { revokes += 1; throw new Error('no revokes in this test'); } }),
    bridges: {
      fetchTarget: (id: string) => t.fetchTarget(id),
      dispatch: t.dispatch,
      listOnlineBridgeIds: async () => ['brg_ok', 'brg_hint', 'brg_unknown'],
      listOnlineLockedBridgeIds: async () => { locked.push('listed'); return ['brg_ok', 'brg_hint', 'brg_unknown']; },
    },
  });
  const rec = recorder();
  dv.stopDeviceVault();
  await dv.bootDeviceVault(USER, rec.dispatch);
  assert.equal(rec.last('deviceVault/deviceVaultStatusChanged').status, 'ready');
  return { hub, a, rec, t, locked, revokes: () => revokes };
}

test('automatic delivery reaches only the approved bridge; hinted and unknown bridges are skipped', async (t) => {
  t.mock.method(Math, 'random', () => 0); // shortest jitter
  const { rec, t: tr } = await bootReady();
  assert.equal(rec.last('deviceVault/deviceVaultDirectoryVerified').staleHead, false);
  await dv.autoUnsealLockedBridges(['brg_ok', 'brg_hint', 'brg_unknown']);
  assert.deepEqual(tr.delivered.map((d) => d.bridgeId), ['brg_ok']);
  assert.ok(!tr.fetched.includes('brg_hint') && !tr.fetched.includes('brg_unknown'), 'no key is even fetched for them');
  assert.deepEqual(rec.last('deviceVault/bridgeKeyDeliveryReported'), { succeeded: ['brg_ok'], failed: [] });
  dv.stopDeviceVault();
});

test('a stale verified head pauses automatic delivery and hint revokes; manual "Send key" still works', async () => {
  const { rec, t, locked, revokes } = await bootReady({ staleHead: true });
  assert.equal(rec.last('deviceVault/deviceVaultDirectoryVerified').staleHead, true);
  await dv.autoUnsealLockedBridges(['brg_ok']);
  assert.deepEqual(t.delivered, [], 'nothing delivered automatically');
  assert.deepEqual(locked, [], 'it does not even poll the bridges');
  assert.deepEqual(rec.last('deviceVault/bridgeKeyDeliveryReported'), { succeeded: [], failed: [{ bridgeId: 'brg_ok', error: dv.STALE_HEAD_PAUSE_MESSAGE }] });
  assert.deepEqual(await dv.revokeRetiredHint(), { revoked: null });
  assert.equal(revokes(), 0, 'no automatic revoke of the hinted bridge on a stale head');
  // The user explicitly sends the key.
  const manual = await dv.sendKeyToBridge('brg_ok');
  assert.deepEqual(manual.succeeded, ['brg_ok']);
  assert.deepEqual(t.delivered.map((d) => d.bridgeId), ['brg_ok']);
  dv.stopDeviceVault();
});
