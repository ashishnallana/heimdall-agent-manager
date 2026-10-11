import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  approvedBridgeIsOnline,
  enrollmentContinueAvailable,
  enrollmentRestartConfirmation,
  navigateEnrollmentProviderSetup,
  nextAvailableBridgeLabel,
  RESTART_CONFIRMATION_TIMEOUT_SECONDS,
  RESTART_SEALED_CONFIRM_POLLS,
} from '../src/ui/components/enrollment/bridgeEnrollmentCompletion.ts';
import {
  getActiveBridgeVaultKeyMaterial,
  setActiveBridgeVaultKeyMaterial,
  setActiveVaultKey,
} from '../src/ui/utils/vaultCrypto.ts';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

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

test('successful enrollment waits for an explicit provider-selection continuation', () => {
  const source = fs.readFileSync(
    path.join(repoRoot, 'src/ui/components/enrollment/BridgeEnrollmentApprovalPage.tsx'),
    'utf8',
  );

  assert.match(source, /className="animate-spin"/);
  assert.match(source, /cookieJsonFetch\('\/bridges'\)/);
  assert.match(source, /approvedBridgeIsOnline\(list, targetBridgeId\)/);
  assert.match(source, /bridgeConnected\s*&&/);
  assert.match(source, /delivery\.phase === 'delivered'/);
  assert.match(source, /delivery\.phase === 'not-needed'/);
  assert.match(source, /enrollment-continue-provider-selection-btn/);
  assert.match(source, /onClick=\{\(\) => navigateEnrollmentProviderSetup\(bridgeId\)\}/);
  assert.match(source, /Continue to provider selection/);
  assert.doesNotMatch(source, /BRIDGE_HOME_REDIRECT_DELAY_MS|Opening provider setup in 3 seconds/);
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

test('approval is a standalone minimal consent page', () => {
  const page = fs.readFileSync(
    path.join(repoRoot, 'src/ui/components/enrollment/BridgeEnrollmentApprovalPage.tsx'),
    'utf8',
  );
  const shell = fs.readFileSync(
    path.join(repoRoot, 'src/ui/components/shell/AppShell.tsx'),
    'utf8',
  );

  assert.match(shell, /if \(path === '\/device\/add'\)[\s\S]*enrollment-standalone-page/);
  assert.match(page, /enrollment-device-hostname/);
  assert.match(page, /enrollment-device-os/);
  assert.match(page, /enrollment-new-bridge-name-input/);
  assert.match(page, /new_bridge_label:/);
  assert.doesNotMatch(page, /Verified by Heimdall/);
  assert.doesNotMatch(page, /Claimed by the machine/);
  assert.doesNotMatch(page, /Request came from/);
  assert.doesNotMatch(page, /Fingerprint method/);
  assert.doesNotMatch(page, /Public key \(from link\)/);
  assert.doesNotMatch(page, /Callback port/);
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
  for (const phase of ['delivered', 'confirming-restart', 'confirmed', 'restart-unconfirmed', 'not-needed']) {
    assert.equal(enrollmentContinueAvailable(phase), true, phase);
  }
  // Re-unsealing the restarted service keeps it; the initial delivery does not offer it yet.
  assert.equal(enrollmentContinueAvailable('need-password', 'restarted'), true);
  assert.equal(enrollmentContinueAvailable('delivering', 'restarted'), true);
  assert.equal(enrollmentContinueAvailable('need-password', 'enrollment'), false);
  for (const phase of ['idle', 'waiting-for-bridge', 'failed', 'timed-out']) {
    assert.equal(enrollmentContinueAvailable(phase), false, phase);
  }
});

test('approval page wires the restart confirmation and the inline Unseal now', () => {
  const source = fs.readFileSync(
    path.join(repoRoot, 'src/ui/components/enrollment/BridgeEnrollmentApprovalPage.tsx'),
    'utf8',
  );
  assert.match(source, /Vault key delivered, waiting for the bridge to restart and confirm…/);
  assert.match(source, /Bridge restarted and confirmed unsealed/);
  assert.match(source, /enrollment-unseal-now-btn/);
  assert.match(source, /enrollmentRestartConfirmation\(/);
  // The restarted service has a NEW ephemeral key: re-unsealing must use the one it advertises.
  assert.match(source, /publicKey = await fetchBridgePublicKey\(targetBridgeId\)/);
  assert.doesNotMatch(source, /The bridge is enrolled and unsealed\./);
});
