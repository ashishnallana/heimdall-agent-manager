// REQ-BE (t3_ui): bridge approval on /device/add chooses "register as a new bridge" or
// "reuse an existing bridge identity" (DeviceApprovalPage + bridgeReuseChoice.ts).
// Reuse is opt-in; the hub's previous_bridge_id hint only preselects Reuse when it names
// a listed reusable bridge; the approve body carries target_bridge_id XOR new_bridge_label;
// and the vault key reaches the NEWLY approved identity of a reused bridge_id even while
// its old identity is still live (the hub retires it only when the attach commits).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_bridge_enrollment_reuse_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { FakeHub, USER } from './helpers/vaultDirectoryFixture.ts';

const choice = await import('../src/ui/components/devices/bridgeReuseChoice.ts');
const { BridgeIdentityChoice } = await import('../src/ui/components/devices/DeviceApprovalPage.tsx');
const ident = await import('../src/ui/utils/deviceIdentity.ts');
const { deliverKeyringToBridge, BridgeDeliveryRefused } = await import('../src/ui/utils/vaultBridgeDelivery.ts');
const { bridgeUnsealTargetFromRecord } = await import('../src/ui/utils/vaultBridgeUnseal.ts');
const { verifyBridgeChainProof } = await import('../src/ui/utils/vaultDirectoryVerify.ts');

const OLD = { bridge_id: 'brg_old', label: 'Laptop', machine_hostname: 'laptop.local', status: 'offline', last_seen: '2026-10-19T12:00:00Z' };
const LIVE = { bridge_id: 'brg_live', label: 'Desk', machine_hostname: 'desk.local', status: 'online', last_seen: '2026-10-20T17:00:00Z' };
const VAULT_APPROVAL = { expected_version: 3, statement: 'st', signature: { sig: 'x' } };

function info(over: Record<string, unknown> = {}): any {
  return { kind: 'bridge', bridge_identity_public_key: '04aa', reusable_bridges: [LIVE, OLD], previous_bridge_id: '', ...over };
}

test('reusableBridgesOf keeps well-formed, distinct bridge ids in hub order', () => {
  const list = choice.reusableBridgesOf(info({ reusable_bridges: [LIVE, { ...LIVE }, { bridge_id: 'nope' }, null, OLD, { ...OLD, bridge_id: 'brg_' + 'x'.repeat(61) }] }));
  assert.deepEqual(list.map((b) => b.bridge_id), ['brg_live', 'brg_old']);
  assert.deepEqual(choice.reusableBridgesOf(info({ reusable_bridges: undefined })), []);
  assert.deepEqual(choice.reusableBridgesOf(null), []);
});

test('a valid previous_bridge_id hint preselects Reuse with that bridge; no hint defaults to New', () => {
  assert.deepEqual(choice.initialBridgeChoice(info({ previous_bridge_id: 'brg_old' })), { mode: 'reuse', targetBridgeId: 'brg_old' });
  assert.deepEqual(choice.initialBridgeChoice(info()), { mode: 'new', targetBridgeId: 'brg_live' });
  assert.deepEqual(choice.initialBridgeChoice(info({ previous_bridge_id: undefined })), { mode: 'new', targetBridgeId: 'brg_live' });
});

test('a hint the approver cannot reuse (not listed) is ignored, never preselected', () => {
  // The hub blanks such hints; the page re-checks anyway so a spoofed hint is inert.
  assert.deepEqual(choice.initialBridgeChoice(info({ previous_bridge_id: 'brg_foreign' })), { mode: 'new', targetBridgeId: 'brg_live' });
  assert.deepEqual(choice.initialBridgeChoice(info({ previous_bridge_id: 'brg_old', reusable_bridges: [] })), { mode: 'new', targetBridgeId: '' });
});

test('Reuse sends target_bridge_id (no label); New sends new_bridge_label (no target)', () => {
  const list = choice.reusableBridgesOf(info());
  const reuse = choice.reuseTarget(list, { mode: 'reuse', targetBridgeId: 'brg_old' });
  assert.equal(reuse?.bridge_id, 'brg_old');
  assert.deepEqual(choice.bridgeApproveBody('lk', VAULT_APPROVAL, reuse, 'Typed'), { pair_lookup: 'lk', approve: true, vault_approval: VAULT_APPROVAL, target_bridge_id: 'brg_old' });
  const fresh = choice.reuseTarget(list, { mode: 'new', targetBridgeId: 'brg_old' });
  assert.equal(fresh, null, 'New never reuses, even with a remembered target');
  const body = choice.bridgeApproveBody('lk', VAULT_APPROVAL, fresh, 'Typed');
  assert.deepEqual(body, { pair_lookup: 'lk', approve: true, vault_approval: VAULT_APPROVAL, new_bridge_label: 'Typed' });
  assert.ok(!('target_bridge_id' in body));
  // REQ-3: a new bridge can sunset one in the same approval; a reuse never can.
  assert.deepEqual(choice.bridgeApproveBody('lk', VAULT_APPROVAL, null, 'Typed', 'brg_retire'), { pair_lookup: 'lk', approve: true, vault_approval: VAULT_APPROVAL, new_bridge_label: 'Typed', sunset_bridge_id: 'brg_retire' });
  assert.throws(() => choice.bridgeApproveBody('lk', VAULT_APPROVAL, reuse, 'Typed', 'brg_retire'), /cannot also sunset/);
  assert.ok(!('sunset_bridge_id' in body), 'no sunset field unless one was chosen');
  // A reuse target that is no longer listed resolves to nothing (the page refuses to approve).
  assert.equal(choice.reuseTarget(list, { mode: 'reuse', targetBridgeId: 'brg_gone' }), null);
});

test('the reused bridge keeps its name in the signed approval; the done message names mode and bridge', () => {
  const [live] = choice.reusableBridgesOf(info());
  assert.equal(choice.approvalLabel(live, 'Typed'), 'Desk');
  assert.equal(choice.approvalLabel({ ...live, label: '  ' }, 'Typed'), 'Typed');
  assert.equal(choice.approvalLabel(null, 'Typed'), 'Typed');
  assert.match(choice.bridgeApprovedMessage(live, 'Desk', 'brg_live'), /^Reused bridge identity “Desk” \(brg_live\)/);
  assert.match(choice.bridgeApprovedMessage(null, 'New box', 'brg_new'), /^Registered new bridge “New box” \(brg_new\)\. /);
  assert.match(choice.bridgeApprovedMessage(null, 'New box', 'brg_new', 'Old box'), /^Registered new bridge “New box” \(brg_new\) and sunset “Old box”\./);
});

function render(i: any, c: { mode: 'new' | 'reuse'; targetBridgeId: string }): string {
  return renderToStaticMarkup(React.createElement(BridgeIdentityChoice, { info: i, choice: c, onChange: () => {} }));
}

test('the picker offers New and Reuse, lists label/hostname/status, and warns about revocation on Reuse', () => {
  const html = render(info({ previous_bridge_id: 'brg_old' }), { mode: 'reuse', targetBridgeId: 'brg_old' });
  assert.match(html, /Register as a new bridge/);
  assert.match(html, /Reuse an existing bridge identity/);
  for (const s of ['Desk', 'desk.local', 'online', 'Laptop', 'laptop.local', 'offline · last seen']) assert.ok(html.includes(s), s);
  assert.match(html, /device-approval-reuse-warning/);
  assert.match(html, /credentials are revoked/);
  assert.match(html, /disconnected/);
  assert.match(html, /agents, fleet entries and project paths are kept/);
  // The hinted bridge is the checked one.
  assert.match(html, /<input[^>]*value="brg_old"[^>]*checked=""|<input[^>]*checked=""[^>]*value="brg_old"/);
});

test('New shows no warning or list; an empty reusable list hides the Reuse option entirely', () => {
  const html = render(info(), { mode: 'new', targetBridgeId: 'brg_live' });
  assert.match(html, /Reuse an existing bridge identity/);
  assert.doesNotMatch(html, /device-approval-reuse-warning|device-approval-reuse-list/);
  assert.equal(render(info({ reusable_bridges: [] }), { mode: 'new', targetBridgeId: '' }), '');
});

test('the picker shows hostile labels without bidi overrides', () => {
  const html = render(info({ reusable_bridges: [{ ...OLD, label: 'evil‮moc' }] }), { mode: 'reuse', targetBridgeId: 'brg_old' });
  assert.ok(!html.includes('‮'));
  assert.ok(html.includes('evilmoc'));
});

// ── vault key delivery to a reused bridge_id ─────────────────────────────────

/** An account whose bridge brg_reuse has its OLD identity and the newly approved one, both live. */
async function reusedAccount() {
  const hub = new FakeHub();
  const a = await ident.createDeviceIdentity(ident.memoryDeviceStore(), USER);
  await hub.genesis(a);
  const old = await hub.addBridge(a, 'brg_reuse', 'Desk');
  const fresh = await hub.addBridge(a, 'brg_reuse', 'Desk');
  const delivered: any[] = [];
  const deps = {
    // The hub serves the ENROLLING process (the new identity) for an enrollment fetch.
    fetchTarget: async (id: string) => bridgeUnsealTargetFromRecord(id, await fresh.unsealRecord()),
    dispatch: async (_id: string, payload: any) => { delivered.push(payload); return { type: 'bridge_unseal_result', command_id: payload.command_id, ok: true }; },
    withKeyringBytes: async <T>(fn: (b: Uint8Array) => Promise<T>) => {
      const bytes = await hub.keyringBytes(a);
      try { return await fn(bytes); } finally { bytes.fill(0); }
    },
  };
  return { hub, old, fresh, deps, delivered };
}

test('the vault key goes to the newly approved identity of a reused bridge_id', async () => {
  const { hub, fresh, deps, delivered } = await reusedAccount();
  const chain = await hub.chain();
  await deliverKeyringToBridge('brg_reuse', chain, deps, { enrollment: true, identityPublicKey: fresh.identityPub.toUpperCase() });
  assert.equal(delivered.length, 1);
  assert.equal(delivered[0].bridge_identity_public_key, fresh.identityPub);
  const root = await verifyBridgeChainProof(delivered[0].chain_proof, [{ epoch: 1, commit: chain.commits.get(1)! }], {
    ownerUserId: USER, bridgeIdentityPub: fresh.identityPub, pinnedRootSignPub: null, keyringVaultId: chain.vaultId,
  });
  assert.equal(root, chain.rootSignPub);
});

test('without naming the approved identity, a reused bridge_id resolves to the old identity and delivery is refused', async () => {
  const { hub, deps, delivered } = await reusedAccount();
  await assert.rejects(deliverKeyringToBridge('brg_reuse', await hub.chain(), deps, { enrollment: true }), (err) => err instanceof BridgeDeliveryRefused && /differs from the approved one/.test(err.message));
  assert.deepEqual(delivered, []);
});

test('naming an identity the log never approved for that bridge gets nothing', async () => {
  const { hub, deps, delivered } = await reusedAccount();
  await assert.rejects(deliverKeyringToBridge('brg_reuse', await hub.chain(), deps, { enrollment: true, identityPublicKey: '04' + 'b2'.repeat(64) }), /no chain-approved identity/);
  assert.deepEqual(delivered, []);
});
