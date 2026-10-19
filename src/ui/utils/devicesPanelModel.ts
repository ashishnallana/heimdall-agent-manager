// View model for Settings → Devices (docs/plans/passwordless-vault.md requirement 3).
// Pure: built only from a VERIFIED chain, so labels and approvers are the signed ones.

import { fingerprintFor } from './deviceIdentity.ts';
import { kindPolicy } from './vaultStatements.ts';
import { remainingApprovers, type DirectoryDevice, type VerifiedChain } from './vaultDirectoryVerify.ts';

export type DeviceRowStatus = 'approved' | 'pending' | 'revoked' | 'untrusted';

export interface DeviceRow {
  deviceId: string;
  kind: string;
  label: string;
  fingerprint: string;
  status: DeviceRowStatus;
  approvedByLabel: string;
  lastSeenAt: string;
  bridgeId: string;
  isCurrent: boolean;
  /** Revoke offered: approved, not this device, not the last approver. */
  canRevoke: boolean;
  revokeBlockedReason: string;
  /** Deny offered for pending devices. */
  canDeny: boolean;
  /** Re-unseal offered for approved bridges. */
  canSendKey: boolean;
}

async function rowFingerprint(d: { sign_public_key: string; ecdh_public_key?: string; fingerprint?: string }): Promise<string> {
  try {
    return await fingerprintFor(d.sign_public_key, d.ecdh_public_key ?? '');
  } catch {
    return String(d.fingerprint ?? '');
  }
}

export async function buildDeviceRows(chain: VerifiedChain, currentDeviceId: string): Promise<DeviceRow[]> {
  const rows: DeviceRow[] = [];
  const labelOf = (id: string) => chain.everApproved.get(id)?.label || id;
  for (const d of chain.trusted.values()) {
    const isCurrent = d.device_id === currentDeviceId;
    const lastApprover = kindPolicy(d.kind).countsAsApprover && remainingApprovers(chain, d.device_id).length === 0;
    rows.push({
      deviceId: d.device_id,
      kind: d.kind,
      label: d.label || d.device_id,
      fingerprint: await rowFingerprint(d),
      status: 'approved',
      approvedByLabel: d.approved_by_device_id === d.device_id ? '(account root)' : labelOf(d.approved_by_device_id),
      lastSeenAt: String(d.row.last_seen_at ?? ''),
      bridgeId: String(d.row.bridge_id ?? ''),
      isCurrent,
      canRevoke: !isCurrent && !lastApprover,
      revokeBlockedReason: isCurrent ? 'This device' : lastApprover ? 'Last approver (add another device or a recovery key first)' : '',
      canDeny: false,
      canSendKey: d.kind === 'bridge' && Boolean(d.row.bridge_id),
    });
  }
  const other = (d: DirectoryDevice, status: DeviceRowStatus) => ({
    deviceId: d.device_id,
    kind: d.kind,
    label: status === 'revoked' ? (chain.everApproved.get(d.device_id)?.label || d.device_id) : '(unverified)',
    status,
    approvedByLabel: status === 'revoked' && chain.everApproved.get(d.device_id) ? labelOf(chain.everApproved.get(d.device_id)!.approved_by_device_id) : '',
    lastSeenAt: String(d.last_seen_at ?? ''),
    bridgeId: String(d.bridge_id ?? ''),
    isCurrent: d.device_id === currentDeviceId,
    canRevoke: false,
    revokeBlockedReason: '',
    canDeny: status === 'pending' && d.device_id !== currentDeviceId,
    canSendKey: false,
  });
  for (const d of chain.pending) rows.push({ ...other(d, 'pending'), fingerprint: await rowFingerprint(d) });
  for (const d of chain.untrusted) rows.push({ ...other(d, 'untrusted'), fingerprint: await rowFingerprint(d) });
  for (const d of chain.revoked) rows.push({ ...other(d, 'revoked'), fingerprint: await rowFingerprint(d) });
  return rows;
}
