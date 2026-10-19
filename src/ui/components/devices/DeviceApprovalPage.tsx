// /device/add — the ONE approval surface for new browsers AND new bridges
// (docs/plans/passwordless-vault.md requirement 2, §2 P3 "DeviceApprovalPage").
//
// The approver types (or follows a link with) the code shown on the new device. The
// page shows kind, label and fingerprint; the user compares the fingerprint and
// confirms. Every signature and wrap is made against a freshly fetched and VERIFIED
// directory chain:
//   browser → signed approval statement + keyring wrap to its ECDH key;
//   bridge  → signed approval of its identity key via /device/approve, then (once the
//             enrolling process is connected) unseal v2 to an ephemeral key that must
//             be signed by exactly that approved identity key, with the chain proof.

import React, { useCallback, useEffect, useState } from 'react';
import { Alert, Button, Icon, Input } from '@ui';
import { ApiError } from '../../api/cookieFetch';
import {
  postApproveBridge,
  postApproveBrowser,
  postDenyDevice,
  verifyDeviceCode,
  type BridgeCodeInfo,
  type BrowserCodeInfo,
  type DeviceCodeInfo,
} from '../../api/endpoints/vaultDevices';
import { fetchBridgeEnrollmentStatus, fetchBridgeUnsealTarget, unsealBridge } from '../../api/endpoints/bridges';
import { enrollmentPendingOutcome, ENROLLMENT_PENDING_FALLBACK_SECONDS } from '../enrollment/bridgeEnrollmentCompletion';
import { fingerprintFor } from '../../utils/deviceIdentity';
import { buildBridgeApproval, buildBrowserApproval, checkBrowserCodeInfo } from '../../utils/vaultDeviceFlows';
import { deliverKeyringToBridge } from '../../utils/vaultBridgeDelivery';
import { withKeyringBytes } from '../../utils/vaultKeyringSession';
import {
  currentDeviceIdentity,
  deviceSignerContext,
  fetchVerifiedChain,
  refreshDeviceVault,
  verifiedChainForApproval,
} from '../../services/deviceVault';

const POLL_MS = 2000;

type Phase =
  | { kind: 'enter' }
  | { kind: 'loading' }
  | { kind: 'review'; info: DeviceCodeInfo; fingerprint: string; label: string; userCode: string; fromLink: boolean }
  | { kind: 'working'; message: string }
  | { kind: 'done'; message: string }
  | { kind: 'failed'; message: string };

function codeFromLocation(): string {
  try {
    const hash = window.location.hash || '';
    const q = hash.includes('?') ? hash.slice(hash.indexOf('?') + 1) : window.location.search.replace(/^\?/, '');
    return new URLSearchParams(q).get('code') ?? '';
  } catch {
    return '';
  }
}

function errText(err: unknown): string {
  if (err instanceof ApiError && err.status === 409) return `The directory changed while approving (${err.message}). Look the code up again.`;
  return String((err as Error)?.message || err);
}

/**
 * Canonical device code: strip whitespace and dashes, uppercase, then re-insert the
 * dashes by length — 8 symbols is a bridge code (XXXX-XXXX), 12 a browser code
 * (XXXX-XXXX-XXXX). The hub accepts only that exact form. Throws on anything else.
 */
export function normalizeDeviceCode(raw: string): string {
  const s = String(raw ?? '').replace(/[\s-]+/g, '').toUpperCase();
  if (!/^[A-Z0-9]*$/.test(s)) throw new Error('A device code has only letters and digits.');
  if (s.length === 8) return `${s.slice(0, 4)}-${s.slice(4)}`;
  if (s.length === 12) return `${s.slice(0, 4)}-${s.slice(4, 8)}-${s.slice(8)}`;
  throw new Error(`A device code has 8 symbols (bridge) or 12 symbols (browser); this one has ${s.length}.`);
}

function initialCode(): string {
  const raw = codeFromLocation();
  try { return raw ? normalizeDeviceCode(raw) : ''; } catch { return raw; }
}

/** Fingerprint the approver shows: recomputed locally from the served keys, never just echoed. */
export async function codeInfoFingerprint(info: DeviceCodeInfo): Promise<string> {
  if (info.kind === 'browser') {
    await checkBrowserCodeInfo(info);
    return info.fingerprint;
  }
  const local = await fingerprintFor(String(info.bridge_identity_public_key || ''), '');
  const served = String(info.bridge_identity_fingerprint || '').trim().toLowerCase();
  if (served && served !== local.toLowerCase()) throw new Error('The hub reports a different bridge fingerprint than its identity key; refusing.');
  return local;
}

/**
 * M3: a code that arrived in a link must be confirmed by the user typing the code
 * shown on the new device; one typed by hand is its own confirmation. Compared on
 * the canonical form of the LOOKED-UP code.
 */
export function codeConfirmed(phase: { userCode: string; fromLink: boolean }, typed: string): boolean {
  if (!phase.fromLink) return true;
  try {
    return normalizeDeviceCode(typed) === phase.userCode;
  } catch {
    return false;
  }
}

export function hostLabelOf(info: DeviceCodeInfo): string {
  if (info.kind === 'browser') return info.label || 'Browser';
  const asserted = (info.host_asserted ?? {}) as Record<string, unknown>;
  return String(asserted.device_label ?? info.device_label ?? 'bridge').slice(0, 64);
}

async function waitForEnrollingBridge(bridgeId: string, onTick: (s: string) => void): Promise<void> {
  const fallback = Date.now() + ENROLLMENT_PENDING_FALLBACK_SECONDS * 1000;
  for (;;) {
    let outcome: ReturnType<typeof enrollmentPendingOutcome> = 'waiting';
    let deadline = fallback;
    try {
      const status = await fetchBridgeEnrollmentStatus(bridgeId);
      const until = Date.parse(String(status?.enrollment_pending_until || ''));
      if (Number.isFinite(until)) deadline = until;
      outcome = enrollmentPendingOutcome(status, Date.now());
    } catch {
      // transient; the deadline still applies
    }
    if (outcome === 'ready' || outcome === 'committed') return;
    if (outcome === 'rolled-back' || Date.now() >= deadline) throw new Error('The bridge did not connect to receive the vault key in time; run `ham-bridge enroll` again.');
    onTick(`Waiting for the bridge to connect (${Math.max(0, Math.ceil((deadline - Date.now()) / 1000))} s)…`);
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
}

export default function DeviceApprovalPage() {
  const [linkCode] = useState(initialCode);
  const [code, setCode] = useState(linkCode);
  // M3: a code that arrived in a link is only looked up; the user must still type the
  // code shown on the new device before approving.
  const [typedConfirm, setTypedConfirm] = useState('');
  const [phase, setPhase] = useState<Phase>({ kind: 'enter' });
  // The code input is locked once a lookup is in flight or succeeded: approve/deny always
  // act on the looked-up code, never on a later edit.
  const codeLocked = phase.kind === 'loading' || phase.kind === 'review' || phase.kind === 'working';
  const [confirmed, setConfirmed] = useState(false);
  const [label, setLabel] = useState('');

  const lookUp = useCallback(async (raw: string, fromLink = false) => {
    if (!raw.trim()) return;
    let userCode: string;
    try {
      userCode = normalizeDeviceCode(raw);
    } catch (err) {
      setPhase({ kind: 'failed', message: String((err as Error).message) });
      return;
    }
    // A code from a link is not echoed back: the user must type it from the new device.
    setCode(fromLink ? '' : userCode);
    setPhase({ kind: 'loading' });
    setConfirmed(false);
    setTypedConfirm('');
    try {
      const info = await verifyDeviceCode(userCode);
      const fingerprint = await codeInfoFingerprint(info);
      const host = hostLabelOf(info);
      setLabel(host);
      setPhase({ kind: 'review', info, fingerprint, label: host, userCode, fromLink });
    } catch (err) {
      setPhase({ kind: 'failed', message: errText(err) });
    }
  }, []);

  useEffect(() => {
    if (linkCode) void lookUp(linkCode, true);
    // Only the code from the link is looked up automatically.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const approve = useCallback(async () => {
    if (phase.kind !== 'review' || !confirmed || !codeConfirmed(phase, typedConfirm)) return;
    const identity = currentDeviceIdentity();
    const signed = deviceSignerContext();
    if (!identity || !signed) {
      setPhase({ kind: 'failed', message: 'This device is not ready to approve.' });
      return;
    }
    const info = phase.info;
    const finalLabel = label.trim() || phase.label;
    try {
      // Always the code that was LOOKED UP (the input is locked during review).
      const userCode = phase.userCode;
      setPhase({ kind: 'working', message: 'Verifying your device directory…' });
      const chain = await verifiedChainForApproval();
      if (info.kind === 'browser') {
        const body = await withKeyringBytes((bytes) => buildBrowserApproval(identity, chain, info as BrowserCodeInfo, userCode, finalLabel, bytes), chain);
        await postApproveBrowser(info.device_id, body, signed);
        await refreshDeviceVault('approved-browser');
        setPhase({ kind: 'done', message: `Approved “${finalLabel}”. It will ask its user to confirm the account fingerprint.` });
        return;
      }
      const bridgeInfo = info as BridgeCodeInfo;
      const { vault_approval } = await buildBridgeApproval(identity, chain, bridgeInfo, finalLabel);
      const res = await postApproveBridge({ user_code: userCode, approve: true, vault_approval, new_bridge_label: finalLabel });
      const bridgeId = String(res?.hub_observed?.bridge_id || '');
      if (!bridgeId) throw new Error('The hub did not report the approved bridge id.');
      const expectedPublicKey = String((bridgeInfo.hub_observed as any)?.bridge_public_key_on_record || bridgeInfo.bridge_public_key || '');
      await waitForEnrollingBridge(bridgeId, (message) => setPhase({ kind: 'working', message }));
      setPhase({ kind: 'working', message: 'Delivering the vault key to the bridge…' });
      // Fresh, verified chain: it now contains this bridge's signed approval.
      const { chain: after } = await fetchVerifiedChain();
      await deliverKeyringToBridge(bridgeId, after, {
        fetchTarget: (id) => fetchBridgeUnsealTarget(id, true),
        dispatch: unsealBridge,
        withKeyringBytes: (fn) => withKeyringBytes(fn, after),
      }, { enrollment: true, expectedPublicKey, extra: { enrollment: true, expected_public_key: expectedPublicKey.trim().toLowerCase() } });
      setPhase({ kind: 'done', message: `Bridge “${finalLabel}” approved and given the vault key. It restarts its service and comes online unsealed.` });
    } catch (err) {
      setPhase({ kind: 'failed', message: errText(err) });
    }
  }, [phase, confirmed, typedConfirm, label]);

  const deny = useCallback(async () => {
    if (phase.kind !== 'review') return;
    const signed = deviceSignerContext();
    try {
      setPhase({ kind: 'working', message: 'Denying…' });
      if (phase.info.kind === 'browser') {
        if (!signed) throw new Error('This device cannot sign.');
        const { chain } = await fetchVerifiedChain();
        await postDenyDevice(phase.info.device_id, chain.version, signed);
      } else {
        await postApproveBridge({ user_code: phase.userCode, approve: false });
      }
      setPhase({ kind: 'done', message: 'Denied. The device was not added.' });
    } catch (err) {
      setPhase({ kind: 'failed', message: errText(err) });
    }
  }, [phase]);

  return (
    <div data-debug-id="device-approval-page" className="mx-auto w-full max-w-xl p-4">
      <h1 className="mb-1 flex items-center gap-2 text-lg font-semibold text-primary"><Icon name="lock" size={18} />Add a device</h1>
      <p className="mb-4 text-sm text-muted">Enter the code shown on the new browser or printed by <code>ham-bridge enroll</code>.</p>

      <form
        className="mb-4 flex gap-2"
        onSubmit={(e) => { e.preventDefault(); if (!codeLocked) void lookUp(code); }}
      >
        <Input data-debug-id="device-approval-code-input" value={code} onChange={setCode} placeholder={codeLocked && !code ? '(code from the link)' : 'XXXX-XXXX-XXXX'} className="flex-1" autoFocus={!code} disabled={codeLocked} />
        {codeLocked && phase.kind === 'review' ? (
          <Button data-debug-id="device-approval-change-code-btn" variant="ghost" onClick={() => { setConfirmed(false); setTypedConfirm(''); setPhase({ kind: 'enter' }); }}>Change</Button>
        ) : (
          <Button data-debug-id="device-approval-lookup-btn" type="submit" loading={phase.kind === 'loading'} disabled={!code.trim() || codeLocked}>Look up</Button>
        )}
      </form>

      {phase.kind === 'review' ? (
        <div data-debug-id="device-approval-review" className="rounded-2xl border border-subtle bg-surface p-4">
          <dl className="mb-3 grid grid-cols-[8rem_1fr] gap-y-1 text-sm">
            <dt className="text-muted">Kind</dt>
            <dd data-debug-id="device-approval-kind" className="text-primary">{phase.info.kind === 'browser' ? 'Browser' : 'Bridge'}</dd>
            <dt className="text-muted">Claims to be</dt>
            <dd data-debug-id="device-approval-host-label" className="truncate text-primary">{phase.label}</dd>
            <dt className="text-muted">Fingerprint</dt>
            <dd><code data-debug-id="device-approval-fingerprint" className="font-mono tracking-wider text-primary">{phase.fingerprint}</code></dd>
            {phase.fromLink ? null : (<>
              <dt className="text-muted">Code</dt>
              <dd><code data-debug-id="device-approval-looked-up-code" className="font-mono tracking-wider text-primary">{phase.userCode}</code></dd>
            </>)}
            {phase.info.kind === 'browser' && (phase.info as BrowserCodeInfo).created_at ? (<>
              <dt className="text-muted">Requested</dt>
              <dd data-debug-id="device-approval-requested-at" className="text-primary">{new Date(String((phase.info as BrowserCodeInfo).created_at)).toLocaleString()}</dd>
            </>) : null}
          </dl>
          <label className="mb-1 block text-xs font-medium text-muted" htmlFor="device-approval-label">Name it (signed into the approval)</label>
          <Input id="device-approval-label" data-debug-id="device-approval-label-input" value={label} onChange={setLabel} className="mb-3" />
          {phase.fromLink ? (
            <div className="mb-3">
              <label className="mb-1 block text-xs font-medium text-muted" htmlFor="device-approval-code-confirm">
                This code came from a link. Type the code shown on the {phase.info.kind === 'browser' ? 'new browser' : 'bridge machine'} to confirm it is the same one
              </label>
              <Input id="device-approval-code-confirm" data-debug-id="device-approval-code-confirm-input" value={typedConfirm} onChange={setTypedConfirm} placeholder="XXXX-XXXX-XXXX" autoFocus />
              {typedConfirm && !codeConfirmed(phase, typedConfirm) ? <p data-debug-id="device-approval-code-mismatch" className="mt-1 text-xs text-danger">That is not the code that was looked up.</p> : null}
            </div>
          ) : null}
          <label data-debug-id="device-approval-confirm-label" className="mb-3 flex items-start gap-2 text-sm text-primary">
            <input type="checkbox" data-debug-id="device-approval-confirm-checkbox" checked={confirmed} onChange={(e) => setConfirmed(e.target.checked)} className="mt-1" />
            <span>The fingerprint above matches the one shown on the {phase.info.kind === 'browser' ? 'new browser' : 'bridge machine'}, and I started this request.</span>
          </label>
          <div className="flex flex-wrap gap-2">
            <Button data-debug-id="device-approval-approve-btn" variant="primary" disabled={!confirmed || !codeConfirmed(phase, typedConfirm)} onClick={() => void approve()}>Approve</Button>
            <Button data-debug-id="device-approval-deny-btn" variant="danger" onClick={() => void deny()}>Deny</Button>
          </div>
        </div>
      ) : null}

      {phase.kind === 'working' ? <p data-debug-id="device-approval-progress" className="text-sm text-muted">{phase.message}</p> : null}
      {phase.kind === 'done' ? (
        <div data-debug-id="device-approval-done" className="flex flex-col gap-3">
          <Alert tone="success" title={phase.message.startsWith('Denied') ? 'Request denied' : 'Device approved'}>{phase.message}</Alert>
          <div className="flex flex-wrap gap-2">
            <Button data-debug-id="device-approval-home-btn" variant="primary" onClick={() => { window.location.hash = '#/home'; }}>Back to Home</Button>
            <Button data-debug-id="device-approval-another-btn" variant="ghost" onClick={() => { setCode(''); setConfirmed(false); setTypedConfirm(''); setPhase({ kind: 'enter' }); }}>Add another device</Button>
          </div>
        </div>
      ) : null}
      {phase.kind === 'failed' ? <div data-debug-id="device-approval-error"><Alert tone="danger">{phase.message}</Alert></div> : null}
    </div>
  );
}
