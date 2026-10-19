// Gate screens for the passwordless vault (docs/plans/passwordless-vault.md §2 P3).
// No password anywhere: a device either created the vault (genesis), waits for an
// approved device to enter its code, confirms the account fingerprint, or is ready.

import React, { useState } from 'react';
import { useSelector } from 'react-redux';
import { Alert, Button, Icon, Input } from '@ui';
import { selectDeviceVault, type DeviceVaultState } from '../../store/deviceVaultSlice';
import {
  CONFIRM_FINGERPRINT_GROUPS,
  acceptOtherAccount,
  confirmAccountFingerprint,
  fingerprintPrefix,
  requestNewApproval,
  refreshDeviceVault,
  rejectAccountFingerprint,
  requestNewDeviceCode,
  requestVaultReset,
  resetBrowserDeviceData,
  startOverAfterReset,
} from '../../services/deviceVault';

function Shell({ debugId, title, children }: { debugId: string; title: string; children: React.ReactNode }) {
  return (
    <div data-debug-id={debugId} className="flex min-h-[var(--app-viewport-height,100vh)] items-center justify-center bg-canvas p-4">
      <div className="w-full max-w-md rounded-2xl border border-subtle bg-surface p-6 shadow-sm">
        <h1 className="mb-3 flex items-center gap-2 text-lg font-semibold text-primary"><Icon name="lock" size={18} />{title}</h1>
        {children}
      </div>
    </div>
  );
}

function Fingerprint({ value, debugId }: { value: string; debugId: string }) {
  return (
    <code data-debug-id={debugId} className="block rounded-lg bg-neutral-soft px-3 py-2 text-center font-mono text-base tracking-wider text-primary">
      {value || '…'}
    </code>
  );
}

function formatWhen(iso: string): string {
  const t = Date.parse(iso);
  return Number.isFinite(t) ? new Date(t).toLocaleString() : iso;
}

function useAsyncAction(): [boolean, string, (fn: () => Promise<void>) => void] {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const run = (fn: () => Promise<void>) => {
    setBusy(true);
    setError('');
    fn().catch((err) => setError(String(err?.message || err))).finally(() => setBusy(false));
  };
  return [busy, error, run];
}

export function DeviceGenesisScreen() {
  return (
    <Shell debugId="device-genesis-screen" title="Setting up your vault">
      <p className="text-sm text-muted">
        This is the first device on your account. Heimdall is creating your encryption keys on this device now.
        They never leave it unencrypted, and there is no password to remember.
      </p>
    </Shell>
  );
}

/** Shown on a new device until an approved device enters its code. Blocks the app. */
export function DeviceWaitingScreen({ state }: { state: DeviceVaultState }) {
  const [busy, error, run] = useAsyncAction();
  const [confirmReset, setConfirmReset] = useState(false);
  const scheduled = state.status === 'reset-scheduled' && state.reset;
  return (
    <Shell debugId="device-waiting-screen" title="Approve this device">
      <p className="mb-3 text-sm text-muted">
        On a device that already uses Heimdall, open <strong>/device/add</strong> (or the notification there) and enter this code.
        Check that the fingerprint shown there matches this one.
      </p>
      <div className="mb-3">
        <div className="mb-1 text-xs font-medium text-muted">Code</div>
        {state.userCode ? (
          <Fingerprint debugId="device-waiting-code" value={state.userCode} />
        ) : (
          <div className="flex items-center gap-2 text-sm text-muted">
            <span data-debug-id="device-waiting-no-code">This code is no longer shown.</span>
            <Button data-debug-id="device-waiting-new-code-btn" size="sm" loading={busy} onClick={() => run(requestNewDeviceCode)}>Get a new code</Button>
          </div>
        )}
        {state.codeExpiresAt ? <div className="mt-1 text-xs text-faint">Expires {formatWhen(state.codeExpiresAt)}</div> : null}
      </div>
      <div className="mb-4">
        <div className="mb-1 text-xs font-medium text-muted">This device's fingerprint</div>
        <Fingerprint debugId="device-waiting-fingerprint" value={state.fingerprint} />
      </div>
      {scheduled ? (
        <div data-debug-id="device-waiting-reset-scheduled"><Alert tone="warning" title="Vault reset scheduled">
          The vault will be reset on {formatWhen(state.reset!.effectiveAt)} unless an approved device cancels it. A reset deletes all keys; existing encrypted history becomes unreadable.
        </Alert></div>
      ) : (
        <div className="border-t border-subtle pt-3 text-xs text-muted">
          Lost every device and have no recovery key?{' '}
          {confirmReset ? (
            <span className="inline-flex flex-wrap items-center gap-2">
              A reset runs after 72 hours, every device is notified and any approved device can cancel it. All encrypted history becomes unreadable.
              <Button data-debug-id="device-waiting-reset-confirm-btn" size="sm" variant="danger" loading={busy} onClick={() => run(requestVaultReset)}>Request reset</Button>
              <Button data-debug-id="device-waiting-reset-cancel-btn" size="sm" variant="ghost" onClick={() => setConfirmReset(false)}>Cancel</Button>
            </span>
          ) : (
            <button type="button" data-debug-id="device-waiting-reset-btn" className="font-medium text-accent hover:underline" onClick={() => setConfirmReset(true)}>Request a vault reset</button>
          )}
        </div>
      )}
      {error ? <p data-debug-id="device-waiting-error" className="mt-2 text-xs text-danger">{error}</p> : null}
    </Shell>
  );
}

/**
 * The new device shows the ACCOUNT fingerprint; keys install only after the user types
 * its first groups as shown on a device they already use. The confirmation is bound to
 * the exact fingerprint rendered here (snapshot + token): if the pending account changes
 * meanwhile, nothing is installed.
 */
export function AccountFingerprintConfirm({ state }: { state: DeviceVaultState }) {
  const [busy, error, run] = useAsyncAction();
  const [typed, setTyped] = useState('');
  const rendered = state.confirmFingerprint;
  const token = state.confirmToken;
  return (
    <Shell debugId="account-fingerprint-confirm" title="Confirm your account">
      <p className="mb-3 text-sm text-muted">
        This device was approved. Before it receives your keys, open <strong>Settings → Devices</strong> on a device you
        already use and compare its account fingerprint with this one:
      </p>
      <Fingerprint debugId="account-fingerprint-value" value={rendered} />
      <label className="mb-1 mt-4 block text-xs font-medium text-muted" htmlFor="account-fingerprint-typed">
        Type the first {CONFIRM_FINGERPRINT_GROUPS} groups as your OTHER device shows them
      </label>
      <Input
        id="account-fingerprint-typed"
        data-debug-id="account-fingerprint-typed-input"
        value={typed}
        onChange={setTyped}
        placeholder="xxxx xxxx"
        autoFocus
      />
      <div className="mt-4 flex flex-wrap gap-2">
        <Button
          data-debug-id="account-fingerprint-match-btn"
          variant="primary"
          loading={busy}
          disabled={!rendered || typed.replace(/[\s-]+/g, '').length !== fingerprintPrefix(rendered).length}
          onClick={() => run(() => confirmAccountFingerprint(typed, rendered, token))}
        >
          Confirm and install keys
        </Button>
        <Button data-debug-id="account-fingerprint-mismatch-btn" variant="danger" onClick={() => rejectAccountFingerprint()}>They differ</Button>
      </div>
      {error ? <p data-debug-id="account-fingerprint-error" className="mt-2 text-xs text-danger">{error}</p> : null}
    </Shell>
  );
}

/** M2: this browser already holds keys/pins for another account. Never automatic. */
export function OtherAccountWarning({ state }: { state: DeviceVaultState }) {
  const [busy, error, run] = useAsyncAction();
  const [ack, setAck] = useState(false);
  return (
    <Shell debugId="device-other-account-warning" title="A different account">
      <div data-debug-id="device-other-account-alert"><Alert tone="warning" title="This browser already belongs to another Heimdall account">
        This browser holds keys for {state.otherAccounts.length === 1 ? 'another account' : `${state.otherAccounts.length} other accounts`}, but the
        server now says you are signed in as <code>{state.userId}</code>. If you did not just switch accounts on purpose, the server may be
        trying to make this browser trust keys that are not yours. Sign out and do not continue.
      </Alert></div>
      <label className="mt-4 flex items-start gap-2 text-sm text-primary">
        <input type="checkbox" data-debug-id="device-other-account-ack-checkbox" checked={ack} onChange={(e) => setAck(e.target.checked)} className="mt-1" />
        <span>I deliberately signed in to a second account ({state.userId}) on this browser.</span>
      </label>
      <div className="mt-4 flex flex-wrap gap-2">
        <Button data-debug-id="device-other-account-continue-btn" variant="danger" disabled={!ack} loading={busy} onClick={() => run(acceptOtherAccount)}>Continue with this account</Button>
      </div>
      {error ? <p data-debug-id="device-other-account-error" className="mt-2 text-xs text-danger">{error}</p> : null}
    </Shell>
  );
}

export function DeviceVaultProblemScreen({ state }: { state: DeviceVaultState }) {
  const [busy, error, run] = useAsyncAction();
  const [phrase, setPhrase] = useState('');
  if (state.status === 'unsupported') {
    return (
      <Shell debugId="device-vault-unsupported" title="This browser cannot hold your keys">
        <p className="text-sm text-muted">Heimdall needs Web Crypto and IndexedDB in a secure context (HTTPS or localhost). Open Heimdall over HTTPS in a regular browser window.</p>
      </Shell>
    );
  }
  if (state.status === 'revoked') {
    return (
      <Shell debugId="device-vault-revoked" title="This device was removed">
        <p className="text-sm text-muted">Another device revoked this one (verified in the signed device log). Its keys were deleted from this browser.</p>
        <p className="mt-2 text-sm text-muted">To use this browser again, request a new approval: it gets a new identity and a new code to enter on a device you still use.</p>
        <div className="mt-4 flex flex-wrap gap-2">
          <Button data-debug-id="device-vault-reapprove-btn" variant="primary" loading={busy} onClick={() => run(requestNewApproval)}>Request new approval</Button>
        </div>
        {error ? <p data-debug-id="device-vault-reapprove-error" className="mt-2 text-xs text-danger">{error}</p> : null}
      </Shell>
    );
  }
  if (state.status === 'initializing') {
    return (
      <Shell debugId="device-vault-initializing" title="Checking this device">
        <p className="text-sm text-muted">Verifying your account's device directory…</p>
      </Shell>
    );
  }
  return (
    <Shell debugId="device-vault-error" title={state.errorCode === 'vault_missing' ? 'Vault missing' : state.errorCode === 'vault_reset' ? 'Vault was reset' : state.errorCode === 'device_state_malformed' ? "This browser's device data is unreadable" : 'Vault check failed'}>
      <div data-debug-id="device-vault-error-message"><Alert tone="danger">{state.errorMessage || "Unknown error"}</Alert></div>
      <p className="mt-2 text-xs text-muted">Nothing was decrypted and no key was installed on this device.</p>
      {state.errorCode === 'vault_missing' && state.startOverPhrase ? (
        <div className="mt-3 text-xs text-muted">
          <label htmlFor="device-vault-start-over-phrase" className="mb-1 block">
            Only if your admin confirms the vault is really gone: type <code className="font-mono text-primary">{state.startOverPhrase}</code> to start a new vault.
            This browser's old identity and pins are archived, not deleted.
          </label>
          <Input id="device-vault-start-over-phrase" data-debug-id="device-vault-start-over-phrase-input" value={phrase} onChange={setPhrase} placeholder={state.startOverPhrase} />
        </div>
      ) : null}
      {state.errorCode === 'device_state_malformed' && state.startOverPhrase ? (
        <div className="mt-3 text-xs text-muted">
          <label htmlFor="device-vault-reset-device-data-phrase" className="mb-1 block">
            Type <code className="font-mono text-primary">{state.startOverPhrase}</code> to reset this browser's device data. Its old identity and pins are archived, not deleted;
            afterwards approve this browser again from a device you already use.
          </label>
          <Input id="device-vault-reset-device-data-phrase" data-debug-id="device-vault-reset-device-data-phrase-input" value={phrase} onChange={setPhrase} placeholder={state.startOverPhrase} />
        </div>
      ) : null}
      <div className="mt-4 flex flex-wrap gap-2">
        <Button data-debug-id="device-vault-retry-btn" loading={busy} onClick={() => run(() => refreshDeviceVault('retry'))}>Retry</Button>
        {state.errorCode === 'vault_reset' ? (
          <Button data-debug-id="device-vault-start-over-btn" variant="danger" loading={busy} onClick={() => run(() => startOverAfterReset())}>Start a new vault on this device</Button>
        ) : null}
        {state.errorCode === 'device_state_malformed' && state.startOverPhrase ? (
          <Button
            data-debug-id="device-vault-reset-device-data-btn"
            variant="danger"
            loading={busy}
            disabled={phrase.trim().replace(/\s+/g, ' ').toUpperCase() !== state.startOverPhrase.toUpperCase()}
            onClick={() => run(() => resetBrowserDeviceData(phrase))}
          >
            Reset this browser's device data
          </Button>
        ) : null}
        {state.errorCode === 'vault_missing' && state.startOverPhrase ? (
          <Button
            data-debug-id="device-vault-start-over-btn"
            variant="danger"
            loading={busy}
            disabled={phrase.trim().replace(/\s+/g, ' ').toUpperCase() !== state.startOverPhrase.toUpperCase()}
            onClick={() => run(() => startOverAfterReset(phrase))}
          >
            Start a new vault anyway
          </Button>
        ) : null}
      </div>
      {error ? <p data-debug-id="device-vault-error-detail" className="mt-2 text-xs text-danger">{error}</p> : null}
    </Shell>
  );
}

/**
 * Renders `children` only when this device's keyring is installed. Every other
 * state renders its gate screen INSTEAD of the app, so a pending, revoked or
 * unverified device never reaches decrypted UI.
 */
export function DeviceVaultGate({ children }: { children: React.ReactNode }) {
  const state = useSelector(selectDeviceVault);
  syncGateRoute(state.status);
  return <>{renderDeviceVaultGate(state, children)}</>;
}

/** The route an untrusted device is parked on (it shows the code; no app route renders). */
export const DEVICE_ENROLL_ROUTE = '/device/enroll';
const PARKED_STATUSES = new Set(['pending-approval', 'reset-scheduled', 'confirm-account', 'other-account', 'revoked']);

function currentHashPath(): string {
  const hash = typeof window !== 'undefined' ? window.location.hash || '' : '';
  const path = hash.replace(/^#/, '').split('?')[0];
  return path || '/';
}

/**
 * Deep links never bypass the gate: an untrusted device is redirected to the enroll
 * route (which shows its code), whatever URL it opened. Once the device is ready, a
 * device still on the enroll route is sent Home. Uses replaceState so the parked URL
 * does not pile up in history; the app's router is not mounted while gated.
 */
export function syncGateRoute(status: string): void {
  if (typeof window === 'undefined' || !window.history?.replaceState) return;
  const path = currentHashPath();
  if (PARKED_STATUSES.has(status) && path !== DEVICE_ENROLL_ROUTE) {
    window.history.replaceState(window.history.state, '', `#${DEVICE_ENROLL_ROUTE}`);
  } else if (status === 'ready' && path === DEVICE_ENROLL_ROUTE) {
    window.history.replaceState(window.history.state, '', '#/home');
  }
}

export function renderDeviceVaultGate(state: DeviceVaultState, children: React.ReactNode): React.ReactNode {
  switch (state.status) {
    case 'ready':
      return children;
    case 'genesis':
      return <DeviceGenesisScreen />;
    case 'pending-approval':
    case 'reset-scheduled':
      return <DeviceWaitingScreen state={state} />;
    case 'confirm-account':
      return <AccountFingerprintConfirm state={state} />;
    case 'other-account':
      return <OtherAccountWarning state={state} />;
    default:
      return <DeviceVaultProblemScreen state={state} />;
  }
}
