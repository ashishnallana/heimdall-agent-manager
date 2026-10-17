import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  approvedBridgeIsOnline,
  ENROLLMENT_PENDING_FALLBACK_SECONDS,
  enrollmentContinueAvailable,
  enrollmentPendingOutcome,
  enrollmentRestartConfirmation,
  navigateEnrollmentProviderSetup,
  nextAvailableBridgeLabel,
  RESTART_CONFIRMATION_TIMEOUT_SECONDS,
  RESTART_SEALED_CONFIRM_POLLS,
  WRONG_MASTER_PASSWORD_MESSAGE,
} from '../src/ui/components/enrollment/bridgeEnrollmentCompletion.ts';
import {
  getActiveBridgeVaultKeyMaterial,
  setActiveBridgeVaultKeyMaterial,
  setActiveVaultKey,
} from '../src/ui/utils/vaultCrypto.ts';

test('completion requires the exact approved bridge to be online', () => {
  const bridges = [
    { bridge_id: 'other', status: 'online' },
    { bridge_id: 'approved', status: 'offline' },
  ];
  assert.equal(approvedBridgeIsOnline(bridges, 'approved'), false);
  assert.equal(approvedBridgeIsOnline([{ bridge_id: 'approved', status: 'online' }], 'approved'), true);
  assert.equal(approvedBridgeIsOnline([{ id: 'approved', runtime_status: 'connected' }], 'approved'), true);
  assert.equal(approvedBridgeIsOnline(null, 'approved'), false);
  assert.equal(approvedBridgeIsOnline(bridges, ''), false);
});

test('new bridge names start at hostname and use the first free numeric suffix', () => {
  assert.equal(nextAvailableBridgeLabel('dawnstar', []), 'dawnstar');
  assert.equal(nextAvailableBridgeLabel('dawnstar', [{ label: 'dawnstar' }]), 'dawnstar-2');
  assert.equal(
    nextAvailableBridgeLabel('dawnstar', [
      { label: 'DAWNSTAR' },
      { label: 'dawnstar-2' },
      { label: 'dawnstar-4' },
    ]),
    'dawnstar-3',
  );
  assert.equal(nextAvailableBridgeLabel('', []), 'bridge');
});

test('bridge key material is session-only and invalidated whenever the active key changes', () => {
  const raw = 'ab'.repeat(32);
  setActiveVaultKey({} as CryptoKey);
  setActiveBridgeVaultKeyMaterial(raw);
  assert.equal(getActiveBridgeVaultKeyMaterial(), raw);

  setActiveVaultKey({} as CryptoKey);
  assert.equal(getActiveBridgeVaultKeyMaterial(), null);

  setActiveBridgeVaultKeyMaterial(raw);
  setActiveVaultKey(null);
  assert.equal(getActiveBridgeVaultKeyMaterial(), null);
});

test('provider setup route retains the enrolled bridge id', () => {
  const priorWindow = globalThis.window;
  const mockWindow = { location: { hash: '' } } as any;
  Object.defineProperty(globalThis, 'window', { configurable: true, value: mockWindow });
  try {
    navigateEnrollmentProviderSetup('bridge/with spaces');
    assert.equal(mockWindow.location.hash, '#/device/providers/bridge%2Fwith%20spaces');
  } finally {
    Object.defineProperty(globalThis, 'window', { configurable: true, value: priorWindow });
  }
});

// REQ-T2-4: "delivered" only means the enrolling CLI process got the key. The page
// confirms only once the RESTARTED service (a new ECDH key) reports unlocked.
const ENROLL_KEY = '04' + 'ab'.repeat(64);
const RESTARTED_KEY = '04' + 'cd'.repeat(64);

function restartInput(overrides: Record<string, unknown> = {}) {
  return {
    rows: [{ bridge_id: 'brg_1', status: 'online', vault_status: 'unlocked' }],
    bridgeId: 'brg_1',
    enrollmentPublicKey: ENROLL_KEY,
    advertisedPublicKey: RESTARTED_KEY,
    sealedPolls: 0,
    expired: false,
    ...overrides,
  } as any;
}

test('restart confirmation: the restarted service reporting unlocked confirms', () => {
  const decision = enrollmentRestartConfirmation(restartInput());
  assert.equal(decision.outcome, 'confirmed');
  assert.equal(decision.vaultStatus, 'unlocked');
  assert.equal(RESTART_CONFIRMATION_TIMEOUT_SECONDS, 45);
});

test('restart confirmation: unlocked from the enrolling process itself is not believed', () => {
  // Same key as the one the operator confirmed => still the enroll process.
  const sameProcess = enrollmentRestartConfirmation(
    restartInput({ advertisedPublicKey: ENROLL_KEY.toUpperCase() }),
  );
  assert.equal(sameProcess.outcome, 'waiting');
  // No advertised key yet (between processes) is not a restart either.
  assert.equal(enrollmentRestartConfirmation(restartInput({ advertisedPublicKey: '' })).outcome, 'waiting');
});

test('restart confirmation: only the SAME bridge, and only while online, counts', () => {
  const otherBridge = enrollmentRestartConfirmation(
    restartInput({ rows: [{ bridge_id: 'brg_2', status: 'online', vault_status: 'unlocked' }] }),
  );
  assert.equal(otherBridge.outcome, 'waiting');
  const offline = enrollmentRestartConfirmation(
    restartInput({ rows: [{ bridge_id: 'brg_1', status: 'offline', vault_status: 'unlocked' }] }),
  );
  assert.equal(offline.outcome, 'waiting');
  assert.equal(enrollmentRestartConfirmation(restartInput({ rows: null })).outcome, 'waiting');
});

test('restart confirmation: locked/disabled is terminal only after consecutive polls', () => {
  for (const vault of ['locked', 'disabled']) {
    const rows = [{ bridge_id: 'brg_1', status: 'online', vault_status: vault }];
    const first = enrollmentRestartConfirmation(restartInput({ rows }));
    assert.equal(first.outcome, 'waiting', `${vault}: one poll may race the on-connect heartbeat`);
    assert.equal(first.sealedPolls, 1);
    const second = enrollmentRestartConfirmation(restartInput({ rows, sealedPolls: first.sealedPolls }));
    assert.equal(second.sealedPolls, RESTART_SEALED_CONFIRM_POLLS);
    assert.equal(second.outcome, 'sealed');
    assert.equal(second.vaultStatus, vault);
  }
  // A sealed streak resets when the bridge is not (yet) the restarted one.
  const reset = enrollmentRestartConfirmation(
    restartInput({
      rows: [{ bridge_id: 'brg_1', status: 'online', vault_status: 'locked' }],
      advertisedPublicKey: ENROLL_KEY,
      sealedPolls: 1,
    }),
  );
  assert.equal(reset.sealedPolls, 0);
  assert.equal(reset.outcome, 'waiting');
});

test('restart confirmation: the deadline yields timed-out, but a confirmation on the last poll still wins', () => {
  const rows = [{ bridge_id: 'brg_1', status: 'online', vault_status: '' }];
  assert.equal(enrollmentRestartConfirmation(restartInput({ rows, expired: true })).outcome, 'timed-out');
  assert.equal(enrollmentRestartConfirmation(restartInput({ expired: true })).outcome, 'confirmed');
});

test('continue to provider selection stays available in every terminal state', () => {
  // `failed` = approved and online but the key was not delivered (wrong prompt
  // dismissed, bridge refused): the bridge is enrolled, just sealed.
  for (const phase of ['delivered', 'confirming-restart', 'confirmed', 'restart-unconfirmed', 'not-needed', 'failed']) {
    assert.equal(enrollmentContinueAvailable(phase), true, phase);
  }
  // Re-unsealing the restarted service keeps it; the initial delivery does not offer it yet.
  assert.equal(enrollmentContinueAvailable('need-password', 'restarted'), true);
  assert.equal(enrollmentContinueAvailable('delivering', 'restarted'), true);
  assert.equal(enrollmentContinueAvailable('need-password', 'enrollment'), false);
  for (const phase of ['idle', 'waiting-for-bridge', 'timed-out']) {
    assert.equal(enrollmentContinueAvailable(phase), false, phase);
  }
});

test('a wrong master password gets one plain, browser-independent message', () => {
  assert.equal(WRONG_MASTER_PASSWORD_MESSAGE, 'Incorrect master password. Try again.');
});

test('REQ-T4-4: nothing but a restarted bridge reporting `unlocked` is ever confirmed', () => {
  for (const vault of ['disabled', 'locked', '', 'garbage', undefined]) {
    let sealedPolls = 0;
    for (let poll = 0; poll < RESTART_SEALED_CONFIRM_POLLS + 2; poll++) {
      for (const expired of [false, true]) {
        const decision = enrollmentRestartConfirmation(
          restartInput({ rows: [{ bridge_id: 'brg_1', status: 'online', vault_status: vault }], sealedPolls, expired }),
        );
        assert.notEqual(decision.outcome, 'confirmed', `vault_status=${String(vault)} poll=${poll} expired=${expired}`);
      }
      sealedPolls = enrollmentRestartConfirmation(
        restartInput({ rows: [{ bridge_id: 'brg_1', status: 'online', vault_status: vault }], sealedPolls }),
      ).sealedPolls;
    }
  }
});

test('REQ-EA: under atomic enrollment an undelivered key means NOT enrolled, so no provider step', () => {
  // Legacy hub: failed delivery still leaves an enrolled (sealed) bridge.
  assert.equal(enrollmentContinueAvailable('failed', undefined, false), true);
  // Pending enrollment: failed = retry or cancel; rolled-back = start again.
  assert.equal(enrollmentContinueAvailable('failed', undefined, true), false);
  assert.equal(enrollmentContinueAvailable('rolled-back', undefined, true), false);
  assert.equal(enrollmentContinueAvailable('rolled-back'), false);
  // Once the key is delivered the hub has committed: provider selection stays optional but offered.
  for (const phase of ['delivered', 'confirming-restart', 'confirmed', 'restart-unconfirmed']) {
    assert.equal(enrollmentContinueAvailable(phase, undefined, true), true, phase);
  }
  assert.equal(enrollmentContinueAvailable('need-password', 'enrollment', true), false);
});

test('REQ-EA-6: pending outcome reads the hub enrollment status, failing toward rolled back', () => {
  const now = Date.parse('2026-10-16T15:00:00Z');
  const future = '2026-10-16T15:04:00Z';
  const past = '2026-10-16T14:59:59Z';
  // The row is gone: a new bridge's rollback hard-deletes it.
  assert.equal(enrollmentPendingOutcome(null, now), 'rolled-back');
  assert.equal(enrollmentPendingOutcome({ enrollment_state: 'pending', enroll_connected: false, enrollment_pending_until: future }, now), 'waiting');
  assert.equal(enrollmentPendingOutcome({ enrollment_state: 'pending', enroll_connected: true, enrollment_pending_until: future }, now), 'ready');
  // Past the deadline the sweep rolls it back, even if the socket is still up.
  assert.equal(enrollmentPendingOutcome({ enrollment_state: 'pending', enroll_connected: true, enrollment_pending_until: past }, now), 'rolled-back');
  // An attach has no deadline on its row; the hub's family TTL governs it.
  assert.equal(enrollmentPendingOutcome({ enrollment_state: 'pending', enroll_connected: true, enrollment_pending_until: '' }, now), 'ready');
  assert.equal(enrollmentPendingOutcome({ enrollment_state: 'enrolled', enroll_connected: false }, now), 'committed');
  assert.equal(ENROLLMENT_PENDING_FALLBACK_SECONDS, 300);
});
