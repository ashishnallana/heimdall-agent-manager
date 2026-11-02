// The bridge half of a /device/add approval, shared by DeviceApprovalPage and the
// first-run setup wizard (components/setup). Both surfaces must run exactly the same
// signed sequence, so it lives here once:
//
//   1. sign a vault approval of the bridge's identity key with this device;
//   2. POST /device/approve as a NEW bridge (optionally sunsetting one of the user's
//      bridges in the same hub transaction) or as a reuse of `target`;
//   3. wait for the enrolling process to connect;
//   4. deliver the keyring (unseal v2) bound to the pair_mac under the same code.
//
// Nothing here decides new-vs-reuse: the caller passes the target the user picked
// (bridgeReuseChoice.ts) and this module re-checks that the hub approved that one.

import { postApproveBridge, type BridgeCodeInfo, type ReusableBridge } from '../../api/endpoints/vaultDevices';
import { fetchBridgeEnrollmentStatus, fetchBridgeUnsealTarget, unsealBridge } from '../../api/endpoints/bridges';
import { enrollmentPendingOutcome, ENROLLMENT_PENDING_FALLBACK_SECONDS } from '../enrollment/bridgeEnrollmentCompletion';
import { approvalLabel, bridgeApproveBody, bridgeApprovedMessage } from './bridgeReuseChoice';
import { buildBridgeApproval } from '../../utils/vaultDeviceFlows';
import { pairApproveMac, type PairKeys } from '../../utils/vaultPairing';
import { deliverKeyringToBridge } from '../../utils/vaultBridgeDelivery';
import { withKeyringBytes } from '../../utils/vaultKeyringSession';
import { currentDeviceIdentity, deviceSignerContext, fetchVerifiedChain, verifiedChainForApproval } from '../../services/deviceVault';

const POLL_MS = 2000;

export interface BridgeApprovalOutcome {
  bridgeId: string;
  /** The label signed into the approval (a reused bridge keeps its own name). */
  label: string;
  /** bridgeApprovedMessage: what happened, for the user. */
  approved: string;
}

/**
 * Polls the enrollment status until the approved bridge has connected. `signal`
 * aborts the wait (DeviceApprovalPage's "Cancel enrollment", after the hub confirmed
 * the rollback).
 */
export async function waitForEnrollingBridge(bridgeId: string, onTick: (s: string) => void, signal?: AbortSignal): Promise<void> {
  const fallback = Date.now() + ENROLLMENT_PENDING_FALLBACK_SECONDS * 1000;
  for (;;) {
    signal?.throwIfAborted();
    let outcome: ReturnType<typeof enrollmentPendingOutcome> = 'waiting';
    let deadline = fallback;
    try {
      const status = await fetchBridgeEnrollmentStatus(bridgeId, signal);
      const until = Date.parse(String(status?.enrollment_pending_until || ''));
      if (Number.isFinite(until)) deadline = until;
      outcome = enrollmentPendingOutcome(status, Date.now());
    } catch {
      signal?.throwIfAborted();
      // transient; the deadline still applies
    }
    signal?.throwIfAborted();
    if (outcome === 'ready' || outcome === 'committed') return;
    if (outcome === 'rolled-back' || Date.now() >= deadline) throw new Error('The bridge did not connect to receive the vault key in time; run `ham-bridge enroll` again.');
    onTick(`Waiting for the bridge to connect (${Math.max(0, Math.ceil((deadline - Date.now()) / 1000))} s)…`);
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

/**
 * Approve the bridge pairing request `info` (already looked up and key_mac-checked
 * with `keys`, see lookUpPairing) as `target` (reuse) or as a new bridge named
 * `newLabel`, then deliver the vault key. Throws on any refusal; on success the
 * bridge restarts and comes online unsealed.
 */
export async function approveBridgeEnrollment(args: {
  info: BridgeCodeInfo;
  keys: PairKeys;
  target: ReusableBridge | null;
  newLabel: string;
  /**
   * New bridge only: the bridge to retire to make room on a full plan. The hub
   * revokes it atomically with this approval (sunset_bridge_id), so it is never
   * revoked up front and a refused approval leaves it working.
   */
  sunset?: { bridge_id: string; label: string } | null;
  onProgress: (message: string) => void;
  /** Aborts the wait for the enrolling bridge to connect (step 3). */
  waitSignal?: AbortSignal;
  /** Called with the approved bridge id while step 3 waits, and with '' after it. */
  onWaiting?: (bridgeId: string) => void;
}): Promise<BridgeApprovalOutcome> {
  const { info, keys, target, newLabel, sunset, onProgress, waitSignal, onWaiting } = args;
  // Checked before anything is signed; bridgeApproveBody enforces it again.
  if (target && sunset?.bridge_id) throw new Error('A reused bridge identity cannot also sunset a bridge.');
  const identity = currentDeviceIdentity();
  if (!identity || !deviceSignerContext()) throw new Error('This device is not ready to approve.');
  onProgress('Verifying your device directory…');
  const chain = await verifiedChainForApproval();
  const label = approvalLabel(target, newLabel);
  const { vault_approval, statement } = await buildBridgeApproval(identity, chain, info, label);
  const res = await postApproveBridge(bridgeApproveBody(keys.lookup, vault_approval, target, newLabel, sunset?.bridge_id || ''));
  const bridgeId = String(res?.hub_observed?.bridge_id || '');
  if (!bridgeId) throw new Error('The hub did not report the approved bridge id.');
  if (target && bridgeId !== target.bridge_id) throw new Error(`The hub approved ${bridgeId}, not the bridge you chose to reuse (${target.bridge_id}). The vault key was not delivered.`);
  const expectedPublicKey = String(info.bridge_public_key || '');
  onWaiting?.(bridgeId);
  try {
    await waitForEnrollingBridge(bridgeId, onProgress, waitSignal);
  } finally {
    onWaiting?.('');
  }
  onProgress('Delivering the vault key to the bridge…');
  // Fresh, verified chain: it now contains this bridge's signed approval. The
  // pair_mac lets the bridge pin this account's root on its first unseal.
  const { chain: after } = await fetchVerifiedChain();
  const pairMac = await pairApproveMac(keys, statement, after.rootSignPub);
  await deliverKeyringToBridge(bridgeId, after, {
    fetchTarget: (id) => fetchBridgeUnsealTarget(id, true),
    dispatch: unsealBridge,
    withKeyringBytes: (fn) => withKeyringBytes(fn, after),
  }, { enrollment: true, identityPublicKey: info.bridge_identity_public_key, expectedPublicKey, extra: { enrollment: true, expected_public_key: expectedPublicKey.trim().toLowerCase(), pair_mac: pairMac } });
  return { bridgeId, label, approved: bridgeApprovedMessage(target, label, bridgeId, sunset?.label || '') };
}
