// Settings → Devices (/settings/devices). Requirement 3 of the passwordless vault:
// every browser, bridge and recovery device with label, kind, fingerprint,
// approved-by and last seen. Revoke is never offered for the current device (the hub
// refuses it too) nor for the last approver. Revoke rotates to a new epoch, wraps
// the keyring to the remaining devices and re-unseals the connected bridges.

import React, { useCallback, useEffect, useState } from 'react';
import { useSelector } from 'react-redux';
import { Alert, Button, StatusPill } from '@ui';
import { selectDeviceVault } from '../../store/deviceVaultSlice';
import { buildDeviceRows, type DeviceRow } from '../../utils/devicesPanelModel';
import {
  cancelVaultReset,
  denyPendingDevice,
  fetchVerifiedChain,
  revokeDevice,
  sendKeyToBridge,
} from '../../services/deviceVault';
import { buildRouteHash } from '../../utils/appLocation';
import { listUnpairedBridgeIds } from '../../api/endpoints/bridges';
import { RecoveryKeySection } from './RecoveryKeySection';
import { McpConnections } from './McpConnections';

const KIND_LABEL: Record<string, string> = { browser: 'Browser', bridge: 'Bridge', recovery: 'Recovery key' };
const STATUS_TONE = { approved: 'success', pending: 'warning', revoked: 'neutral', untrusted: 'danger' } as const;

function when(iso: string): string {
  const t = Date.parse(iso);
  return Number.isFinite(t) ? new Date(t).toLocaleString() : '—';
}

export interface DevicesListProps {
  rows: DeviceRow[];
  busyId?: string;
  /** Bridge id -> error of the last failed automatic/manual key delivery. "Send key" shows only then. */
  keyFailures?: Record<string, string>;
  /** Bridges reporting `unpaired` (never received keys, cannot any more): revoke and re-enroll. */
  unpairedBridgeIds?: readonly string[];
  confirmRevokeId?: string;
  onRevoke?: (id: string) => void;
  onConfirmRevoke?: (id: string) => void;
  onCancelRevoke?: () => void;
  onDeny?: (id: string) => void;
  onSendKey?: (bridgeId: string) => void;
}

/** Presentational list. The current device never gets a revoke button. */
export function DevicesList({ rows, busyId, keyFailures = {}, unpairedBridgeIds = [], confirmRevokeId, onRevoke, onConfirmRevoke, onCancelRevoke, onDeny, onSendKey }: DevicesListProps) {
  if (rows.length === 0) return <p data-debug-id="settings-devices-empty" className="text-sm text-muted">No devices.</p>;
  return (
    <ul data-debug-id="settings-devices-list" className="divide-y divide-subtle rounded-2xl border border-subtle bg-surface">
      {rows.map((r) => (
        <li key={r.deviceId} data-debug-id={`settings-device-row-${r.deviceId}`} className={`flex flex-wrap items-start gap-3 p-3 ${r.isCurrent ? 'border-l-4 border-accent bg-accent-soft' : ''}`}>
          <div className="min-w-0 flex-1">
            <div className="flex flex-wrap items-center gap-2">
              <span className="truncate font-medium text-primary">{r.label}</span>
              <StatusPill tone="neutral">{KIND_LABEL[r.kind] ?? r.kind}</StatusPill>
              <StatusPill tone={STATUS_TONE[r.status]}>{r.status === 'untrusted' ? 'unverified — never given keys' : r.status}</StatusPill>
              {r.isCurrent ? <StatusPill tone="info" data-debug-id="settings-device-current-badge">This device (the one you are using)</StatusPill> : null}
              {r.retiredHint ? <StatusPill tone="warning" data-debug-id={`settings-device-retired-hint-${r.deviceId}`}>retired — being revoked</StatusPill> : null}
              {r.bridgeId && unpairedBridgeIds.includes(r.bridgeId) ? <StatusPill tone="danger" data-debug-id={`settings-device-unpaired-hint-${r.deviceId}`}>never received keys — revoke and re-enroll</StatusPill> : null}
            </div>
            <div className="mt-1 grid gap-x-4 text-xs text-muted sm:grid-cols-2">
              <span>Fingerprint <code className="font-mono text-primary">{r.fingerprint}</code></span>
              <span>Approved by {r.approvedByLabel || '—'}</span>
              <span>Added {when(r.addedAt)}</span>
              <span>Last seen {when(r.lastSeenAt)}</span>
              {r.bridgeId ? <span>Bridge {r.bridgeId}</span> : null}
            </div>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            {r.canSendKey && onSendKey && keyFailures[r.bridgeId] ? (
              <span data-debug-id={`settings-device-key-error-${r.deviceId}`} className="text-xs text-danger">Key delivery failed: {keyFailures[r.bridgeId]}</span>
            ) : null}
            {r.canSendKey && onSendKey && keyFailures[r.bridgeId] ? (
              <Button size="sm" data-debug-id={`settings-device-send-key-btn-${r.deviceId}`} loading={busyId === r.deviceId} onClick={() => onSendKey(r.bridgeId)}>Send key</Button>
            ) : null}
            {r.canDeny && onDeny ? (
              <>
                <a data-debug-id={`settings-device-approve-link-${r.deviceId}`} className="text-sm font-medium text-accent hover:underline" href={buildRouteHash('/device/add', '')}>Approve with its code</a>
                <Button size="sm" variant="danger" data-debug-id={`settings-device-deny-btn-${r.deviceId}`} loading={busyId === r.deviceId} onClick={() => onDeny(r.deviceId)}>Deny</Button>
              </>
            ) : null}
            {r.status === 'approved' && !r.isCurrent ? (
              confirmRevokeId === r.deviceId ? (
                <div data-debug-id={`settings-device-revoke-confirm-${r.deviceId}`} className="flex w-full flex-col gap-2 rounded-lg border border-danger p-2 text-xs text-primary">
                  <span>Revoke <strong>{r.label}</strong> — fingerprint <code className="font-mono">{r.fingerprint}</code>, added {when(r.addedAt)}, last seen {when(r.lastSeenAt)}. Check this is NOT the device you are using.</span>
                  {r.approvedDeviceLabels.length > 0 ? (
                    <span data-debug-id={`settings-device-revoke-approved-${r.deviceId}`}>
                      It approved: <strong>{r.approvedDeviceLabels.join(', ')}</strong>. Revoking it does NOT revoke them; if this device may be compromised, review and revoke those too.
                    </span>
                  ) : null}
                  {r.leavesSingleApprover ? <span data-debug-id={`settings-device-revoke-single-approver-${r.deviceId}`} className="font-medium text-danger">This is your only other device that can approve. After revoking it, this device is the only one left that can add devices.</span> : null}
                  <div className="flex flex-wrap gap-2">
                  <Button size="sm" variant="danger" data-debug-id={`settings-device-revoke-confirm-btn-${r.deviceId}`} loading={busyId === r.deviceId} onClick={() => onConfirmRevoke?.(r.deviceId)}>Revoke and rotate keys</Button>
                  <Button size="sm" variant="ghost" data-debug-id={`settings-device-revoke-cancel-btn-${r.deviceId}`} onClick={() => onCancelRevoke?.()}>Cancel</Button>
                  </div>
                </div>
              ) : (
                <Button size="sm" variant="danger" data-debug-id={`settings-device-revoke-btn-${r.deviceId}`} disabled={!r.canRevoke} title={r.revokeBlockedReason || undefined} onClick={() => onRevoke?.(r.deviceId)}>Revoke</Button>
              )
            ) : null}
          </div>
        </li>
      ))}
    </ul>
  );
}

export default function DevicesPanel() {
  const state = useSelector(selectDeviceVault);
  const [rows, setRows] = useState<DeviceRow[]>([]);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [busyId, setBusyId] = useState('');
  const [confirmRevokeId, setConfirmRevokeId] = useState('');
  const [unpaired, setUnpaired] = useState<string[]>([]);

  const reload = useCallback(async () => {
    try {
      const { chain } = await fetchVerifiedChain();
      setRows(await buildDeviceRows(chain, state.deviceId));
      setError('');
      setUnpaired(await listUnpairedBridgeIds().catch(() => []));
    } catch (err) {
      setRows([]);
      setError(`The device directory does not verify: ${String((err as Error)?.message || err)}`);
    }
  }, [state.deviceId]);

  useEffect(() => { void reload(); }, [reload, state.directoryVersion, state.currentEpoch]);

  const act = async (id: string, fn: () => Promise<string>) => {
    setBusyId(id);
    setNotice('');
    setError('');
    try {
      setNotice(await fn());
    } catch (err) {
      setError(String((err as Error)?.message || err));
    } finally {
      setBusyId('');
      setConfirmRevokeId('');
      await reload();
    }
  };

  return (
    <div data-debug-id="settings-devices-panel" className="flex flex-col gap-4">
      <section>
        <h2 className="text-base font-semibold text-primary">Account fingerprint</h2>
        <p className="text-xs text-muted">A new device shows this before it receives keys. Compare them.</p>
        <code data-debug-id="settings-devices-account-fingerprint" className="mt-1 inline-block rounded bg-neutral-soft px-2 py-1 font-mono tracking-wider text-primary">{state.accountFingerprint || '…'}</code>
        <p data-debug-id="settings-devices-log-head" className="mt-1 text-xs text-muted">Device log head #{state.directoryVersion} · <code className="font-mono text-primary">{state.headHash || '…'}</code></p>
      </section>
      {state.reset ? (
        <div data-debug-id="settings-devices-reset-alert">
          <Alert tone="warning" title="Vault reset scheduled">
            The vault will be reset on {when(state.reset.effectiveAt)}.{' '}
            <Button size="sm" variant="primary" data-debug-id="settings-devices-reset-cancel-btn" loading={busyId === 'reset'} onClick={() => void act('reset', async () => { await cancelVaultReset(); return 'Reset cancelled.'; })}>Cancel the reset</Button>
          </Alert>
        </div>
      ) : null}
      <section>
        <div className="mb-2 flex items-center justify-between">
          <h2 className="text-base font-semibold text-primary">Devices</h2>
          <a data-debug-id="settings-devices-add-link" className="text-sm font-medium text-accent hover:underline" href={buildRouteHash('/device/add', '')}>Add a device</a>
        </div>
        <DevicesList
          rows={rows}
          keyFailures={state.bridgeKeyFailures}
          unpairedBridgeIds={unpaired}
          busyId={busyId}
          confirmRevokeId={confirmRevokeId}
          onRevoke={(id) => setConfirmRevokeId(id)}
          onCancelRevoke={() => setConfirmRevokeId('')}
          onConfirmRevoke={(id) => void act(id, async () => {
            const { outcome, bridges } = await revokeDevice(id);
            if (outcome.kind === 'already-revoked') return 'That device was already revoked.';
            const failed = bridges.failed.length ? ` ${bridges.failed.length} bridge(s) could not be re-unsealed: ${bridges.failed.map((f) => `${f.bridgeId} (${f.error})`).join('; ')}` : '';
            return `Revoked. Keys rotated; ${bridges.succeeded.length} bridge(s) re-unsealed.${failed}`;
          })}
          onDeny={(id) => void act(id, async () => { await denyPendingDevice(id); return 'Denied.'; })}
          onSendKey={(bridgeId) => {
            const row = rows.find((r) => r.bridgeId === bridgeId);
            void act(row?.deviceId ?? bridgeId, async () => {
              const res = await sendKeyToBridge(bridgeId);
              if (res.failed.length) throw new Error(res.failed[0].error);
              return res.succeeded.length ? 'Key delivered to the bridge.' : 'That bridge is not chain-approved.';
            });
          }}
        />
      </section>
      <RecoveryKeySection hasRecoveryKey={rows.some((r) => r.kind === 'recovery' && r.status === 'approved')} onChanged={() => void reload()} />
      <McpConnections />
      {notice ? <div data-debug-id="settings-devices-notice"><Alert tone="success">{notice}</Alert></div> : null}
      {error ? <div data-debug-id="settings-devices-error"><Alert tone="danger">{error}</Alert></div> : null}
    </div>
  );
}
