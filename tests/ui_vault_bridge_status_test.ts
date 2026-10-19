// REQ-BVS-3: per-bridge vault status. (Bridge lock, REQ-BVS-4/5, no longer exists.)
//
// The badge in bridge settings used to be derived from the UI CLIENT's own vault state,
// so it was one global value rendered identically next to every bridge — it reported
// nothing about any bridge at all. These tests pin the per-bridge derivation as an
// exhaustive truth table, so the two ways this can silently regress are both covered:
//   * a cached "unlocked" from a bridge that has since gone offline, and
//   * an unreported ("") vault_status being read as unlocked.
//
// RUN: node --test tests/ui_vault_bridge_status_test.ts
// (matched by the `tests/ui_vault_*.ts` glob in package.json's `test` script, so it
//  also runs under a plain `npm test`.)

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  resolveBridgeVaultStatus,
  canLockBridgeVault,
  canUnlockBridgeVault,
  canConfigureBridgeVault,
  BRIDGE_VAULT_STATUS_TONE,
  BRIDGE_VAULT_STATUSES,
  selectOnlineLockedBridgeIds,
  type BridgeVaultStatus,
} from '../src/ui/utils/bridgeVaultStatus.ts';

// --------------------------------------------------------------------------------
// 1. The full truth table: every {bridge.status} x {vault_status} cell asserted.
// --------------------------------------------------------------------------------

const BRIDGE_STATUSES = ['online', 'offline', 'revoked', 'pending', '', undefined, null] as const;
const VAULT_STATUSES = ['disabled', 'locked', 'unlocked', '', undefined, null, 'garbage'] as const;

function expectedCell(bridgeStatus: unknown, vaultStatus: unknown): BridgeVaultStatus {
  if (String(bridgeStatus ?? '').toLowerCase() !== 'online') return 'NotRunning';
  switch (String(vaultStatus ?? '').toLowerCase()) {
    case 'disabled': return 'NotConfigured';
    case 'locked': return 'Locked';
    case 'unlocked': return 'Unlocked';
    default: return 'Unknown';
  }
}

test('REQ-BVS-3: resolveBridgeVaultStatus covers every {bridge.status} x {vault_status} cell', () => {
  let cells = 0;
  for (const bridgeStatus of BRIDGE_STATUSES) {
    for (const vaultStatus of VAULT_STATUSES) {
      const actual = resolveBridgeVaultStatus({
        bridgeStatus: bridgeStatus as any,
        vaultStatus: vaultStatus as any,
      });
      assert.equal(
        actual,
        expectedCell(bridgeStatus, vaultStatus),
        `cell bridge.status=${JSON.stringify(bridgeStatus)} vault_status=${JSON.stringify(vaultStatus)}`,
      );
      cells++;
    }
  }
  assert.equal(cells, BRIDGE_STATUSES.length * VAULT_STATUSES.length, 'every cell was exercised');
  assert.equal(cells, 49, 'the table is 7x7 — guards against a silently shrunk matrix');
});

test('REQ-BVS-3: the four online states are exactly the documented mapping', () => {
  assert.equal(resolveBridgeVaultStatus({ bridgeStatus: 'online', vaultStatus: 'disabled' }), 'NotConfigured');
  assert.equal(resolveBridgeVaultStatus({ bridgeStatus: 'online', vaultStatus: 'locked' }), 'Locked');
  assert.equal(resolveBridgeVaultStatus({ bridgeStatus: 'online', vaultStatus: 'unlocked' }), 'Unlocked');
  assert.equal(resolveBridgeVaultStatus({ bridgeStatus: 'online', vaultStatus: '' }), 'Unknown');
});

test('REQ-BVS-3: hub liveness OVERRIDES a cached vault_status — an offline bridge is never Unlocked', () => {
  // This is the exact regression the field invites: vault_status is the LAST value the
  // bridge reported and is not cleared when it disappears.
  for (const cached of ['unlocked', 'locked', 'disabled', '']) {
    for (const dead of ['offline', 'revoked', 'pending', 'unknown', '']) {
      const status = resolveBridgeVaultStatus({ bridgeStatus: dead, vaultStatus: cached });
      assert.equal(
        status,
        'NotRunning',
        `bridge.status=${dead} with cached vault_status=${cached} must render Not running`,
      );
      assert.notEqual(status, 'Unlocked');
    }
  }
});

test('REQ-BVS-3: an unreported vault_status is Unknown and is NEVER Unlocked', () => {
  for (const unreported of ['', undefined, null, '   ', 'something-new-from-the-future']) {
    const status = resolveBridgeVaultStatus({ bridgeStatus: 'online', vaultStatus: unreported as any });
    assert.equal(status, 'Unknown', `vault_status=${JSON.stringify(unreported)} must be Unknown`);
    assert.notEqual(status, 'Unlocked', 'an older bridge that reported nothing must not look unlocked');
  }
});

test('REQ-BVS-3: vault_status matching is case- and whitespace-insensitive', () => {
  assert.equal(resolveBridgeVaultStatus({ bridgeStatus: 'ONLINE', vaultStatus: 'UNLOCKED' }), 'Unlocked');
  assert.equal(resolveBridgeVaultStatus({ bridgeStatus: ' online ', vaultStatus: ' Locked ' }), 'Locked');
});

test('REQ-AUX-10: reconciliation selects every and only online reported-locked bridge', () => {
  assert.deepEqual(selectOnlineLockedBridgeIds([
    { bridge_id: 'brg_locked_a', status: 'online', vault_status: 'locked' },
    { bridgeId: 'brg_locked_b', runtime_status: ' ONLINE ', vault_status: ' LOCKED ' },
    { id: 'brg_unlocked', status: 'online', vault_status: 'unlocked' },
    { id: 'brg_unknown', status: 'online', vault_status: '' },
    { id: 'brg_disabled', status: 'online', vault_status: 'disabled' },
    { id: 'brg_offline_cached_locked', status: 'offline', vault_status: 'locked' },
    { id: 'brg_revoked_cached_locked', status: 'revoked', vault_status: 'locked' },
    { id: 'brg_locked_a', status: 'online', vault_status: 'locked' },
    { status: 'online', vault_status: 'locked' },
  ]), ['brg_locked_a', 'brg_locked_b']);
});

// --------------------------------------------------------------------------------
// 2. Tone: Unknown / Not running must read neutral, never as success.
// --------------------------------------------------------------------------------

test('REQ-BVS-3: only Unlocked is painted success; Unknown and Not running are neutral', () => {
  assert.equal(BRIDGE_VAULT_STATUS_TONE.Unlocked, 'success');
  assert.equal(BRIDGE_VAULT_STATUS_TONE.Locked, 'warning');
  assert.equal(BRIDGE_VAULT_STATUS_TONE.Unknown, 'neutral');
  assert.equal(BRIDGE_VAULT_STATUS_TONE.NotRunning, 'neutral');
  assert.equal(BRIDGE_VAULT_STATUS_TONE.NotConfigured, 'neutral');

  const successStates = BRIDGE_VAULT_STATUSES.filter((s) => BRIDGE_VAULT_STATUS_TONE[s] === 'success');
  assert.deepEqual(successStates, ['Unlocked'], 'exactly one state may look green');
  // Every state has a tone — a missing entry would render an undefined tone.
  for (const s of BRIDGE_VAULT_STATUSES) {
    assert.ok(BRIDGE_VAULT_STATUS_TONE[s], `state ${s} has a tone`);
  }
  assert.equal(BRIDGE_VAULT_STATUSES.length, 5, 'there are exactly five states');
});

test('REQ-BVS-3: lock/unlock affordances follow the state', () => {
  assert.equal(canLockBridgeVault('Unlocked'), true, 'only an unsealed bridge can be locked');
  for (const s of ['Locked', 'NotRunning', 'NotConfigured', 'Unknown'] as BridgeVaultStatus[]) {
    assert.equal(canLockBridgeVault(s), false, `${s} offers no lock`);
  }
  assert.equal(canUnlockBridgeVault('Locked'), true);
  assert.equal(canUnlockBridgeVault('Unknown'), true, 'an unreported bridge may still be sent a key');
  for (const s of ['Unlocked', 'NotRunning', 'NotConfigured'] as BridgeVaultStatus[]) {
    assert.equal(canUnlockBridgeVault(s), false, `${s} offers no unseal`);
  }
});

test('REQ-T4-1: canConfigureBridgeVault — all five states x ownerHasVault', () => {
  let cells = 0;
  for (const s of BRIDGE_VAULT_STATUSES) {
    for (const ownerHasVault of [true, false]) {
      assert.equal(
        canConfigureBridgeVault(s, ownerHasVault),
        s === 'NotConfigured' && ownerHasVault,
        `status=${s} ownerHasVault=${ownerHasVault}`,
      );
      cells++;
    }
  }
  assert.equal(cells, 10, 'the table is 5x2 — guards against a silently shrunk matrix');
  // Configure is a third affordance, not a change to the other two.
  assert.equal(canUnlockBridgeVault('NotConfigured'), false, 'NotConfigured still offers no plain Unlock');
  assert.equal(canLockBridgeVault('NotConfigured'), false, 'Lock stays disabled for NotConfigured');
});
