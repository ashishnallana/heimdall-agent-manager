import { useEntitlements } from '../../hooks/useEntitlements';
import { subscribePendingApprovalCode, takePendingApprovalCode } from '../../bridge/desktopBridgeSession';
import UpgradePrompt from '../billing/UpgradePrompt';
import { isPlanLimitError, planLimitMessage, planLimitDetails, type PlanLimitDetails } from '../../utils/planLimit';
import { atPlanLimit } from '../../utils/accountEntitlements';
// /device/add — the ONE approval surface for new browsers AND new bridges
// (docs/plans/passwordless-vault.md requirement 2, §1 "Pairing").
//
// Hub-blind pairing: the user types, ONCE, the secret pairing code the new browser
// shows (or `ham-bridge enroll` prints). The code never goes to the hub: this page
// derives a lookup from it to find the request, and checks the request's key_mac
// with it — proof the hub did not swap the new device's keys. The approval then
// carries a pair_mac under the same code, which the new device checks before it
// trusts this account's root. Links never carry a code. The one exception to typing
// it: the desktop app's own bridge enrollment hands its code over in memory
// (desktopBridgeSession, REQ-ENR-INAPP-1); the user still reviews and approves.
//   browser → signed approval statement + keyring wrap + pair_mac;
//   bridge  → signed approval of its identity key via /device/approve, then (once the
//             enrolling process is connected) unseal v2 to an ephemeral key signed by
//             exactly that identity, with the chain proof and the pair_mac. The approver
//             picks whether it registers as a NEW bridge or reuses one of their existing
//             bridge identities (bridgeReuseChoice.ts); then wait for the bridge to restart
//             and reconnect, detect its providers and let the user pick which to enable
//             (REQ-ENR-2..4).

import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Alert, Button, Icon, Input, Radio, Spinner } from '@ui';
import { ApiError } from '../../api/cookieFetch';
import {
  fetchPairCandidates,
  pairingHubOrigin,
  postApproveBridge,
  postApproveBrowser,
  postDenyDevice,
  verifyPairLookups,
  type BridgeCodeInfo,
  type BrowserCodeInfo,
  type DeviceCodeInfo,
} from '../../api/endpoints/vaultDevices';
import { cancelBridgeEnrollment, fetchPendingBridgeEnrollments, fetchBridgeRow } from '../../api/endpoints/bridges';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import ProviderSetupSurface from '../providers/ProviderSetupSurface';
import { bridgeReconnectReady, reconnectSecondsLeft, reconnectStage, startReconnectWait } from '../providers/providerSummaryModel';
import { approveBridgeEnrollment } from './bridgeApproval';
// Re-exported: the cancellable wait lives in bridgeApproval.ts with the rest of the sequence.
export { waitForEnrollingBridge } from './bridgeApproval';
import {
  bridgeChoiceAtLimit,
  initialBridgeChoice,
  REUSE_WARNING,
  reusableBridgesOf,
  reusableBridgeStatusText,
  reuseTarget,
  type BridgeChoice,
} from './bridgeReuseChoice';
import { sanitizeForDisplay } from '../../utils/deviceApprovalSafety';
import { fingerprintFor } from '../../utils/deviceIdentity';
import { buildBrowserApproval, checkBridgeCodeInfo, checkBrowserCodeInfo, type PairedBrowser } from '../../utils/vaultDeviceFlows';
import { acceptedPairOrigins, derivePairKeys, isPairHubOrigin, isPairSalt, normalizePairCode, type PairKeys } from '../../utils/vaultPairing';
import { withKeyringBytes } from '../../utils/vaultKeyringSession';
import {
  currentDeviceIdentity,
  deviceSignerContext,
  deviceVaultUserId,
  fetchVerifiedChain,
  refreshDeviceVault,
  verifiedChainForApproval,
} from '../../services/deviceVault';

/** At most this many pending requests are tried per typed code (one stretch each). */
const MAX_PAIR_CANDIDATES = 8;
const NO_MATCH_MESSAGE = 'No device is waiting with that code. Check the code on the new device (it expires after a few minutes), and that it was started against this hub address.';

interface Review {
  info: DeviceCodeInfo;
  keys: PairKeys;
  /** Browsers: the device as its own MAC-verified register statement describes it. */
  browser: PairedBrowser | null;
  fingerprint: string;
  label: string;
  /** The hub origin the device declared (and bound into its pairing code). */
  hubOrigin: string;
  /** True when that origin is a configured alias, not this page's own API origin. */
  foreignOrigin: boolean;
}

type Phase =
  | { kind: 'enter' }
  | { kind: 'loading' }
  | ({ kind: 'review' } & Review)
  | { kind: 'working'; message: string }
  // Bridge only (REQ-ENR-2..4): after the unseal, wait for the restart, then providers.
  // `approved` is the new-vs-reuse outcome (bridgeApprovedMessage), shown until done.
  | { kind: 'reconnecting'; bridgeId: string; label: string; approved: string }
  | { kind: 'providers'; bridgeId: string; label: string; approved: string }
  | { kind: 'done'; message: string }
  | { kind: 'failed'; message: string };

function errText(err: unknown): string {
  if (isPlanLimitError(err)) return planLimitMessage(planLimitDetails(err));
  if (err instanceof ApiError && err.status === 409) return `The directory changed while approving (${err.message}). Type the code again.`;
  if (err instanceof ApiError && err.status === 404) return NO_MATCH_MESSAGE;
  return String((err as Error)?.message || err);
}

export function hostLabelOf(info: DeviceCodeInfo): string {
  if (info.kind === 'browser') return info.label || 'Browser';
  const asserted = (info.host_asserted ?? {}) as Record<string, unknown>;
  return String(asserted.device_label ?? info.device_label ?? 'bridge').slice(0, 64);
}

/**
 * Resolve and authenticate a pairing request from the code the user typed. Throws
 * (nothing is approved) unless the request's key_mac verifies under that code.
 *
 * Pairing stretch: the lookup depends on the code AND the request's public pair_salt
 * (plus this account for a browser, and the hub origin), so each candidate the hub
 * lists is stretched with the code and all lookups go to /device/verify at once; the
 * answer's pair_salt (and declared origin) names the matching candidate.
 *
 * The hub origin is the one each candidate DECLARES it bound into its own stretch
 * (pair_hub_origin): a bridge enrolled with `-Hub https://hub.example` pairs while
 * this page is served from, and calls its API on, another origin. A declared origin
 * is ACCEPTED only if it is this page's own API origin or one of the hub's configured
 * aliases (--pairing-hub-origins); other candidates are never derived. That keeps
 * relay protection: a device tricked into `ham-bridge enroll -Hub https://evil.example`
 * (a transparent relay to this hub) declares evil's origin and is refused here, so the
 * relay never gets an approved PKCE exchange. The alias list comes from the hub; a
 * hostile hub gains nothing by lying in it (it could mint bridge tokens itself), and
 * one that alters a declared origin only makes the lookup / key_mac miss (refusal).
 * The secret code is always required; key_mac / pair_mac bind the origin through K.
 */
export async function lookUpPairing(rawCode: string, userId: string, ownOrigin: string | null = ownPairingOrigin()): Promise<Review> {
  const code = normalizePairCode(rawCode);
  const listed = await fetchPairCandidates();
  const accepted = acceptedPairOrigins(ownOrigin, listed.pairingHubOrigins);
  const refusedOrigins = new Set<string>();
  const tried: Array<{ kind: 'browser' | 'bridge'; salt: string; origin: string; keys: PairKeys }> = [];
  for (const cand of listed.candidates.slice(0, MAX_PAIR_CANDIDATES)) {
    if ((cand?.kind !== 'browser' && cand?.kind !== 'bridge') || !isPairSalt(cand.pair_salt) || !isPairHubOrigin(cand.pair_hub_origin)) continue;
    if (!accepted.has(cand.pair_hub_origin)) {
      refusedOrigins.add(cand.pair_hub_origin);
      continue;
    }
    const keys = await derivePairKeys(code, { kind: cand.kind, userId: cand.kind === 'browser' ? userId : '', hubOrigin: cand.pair_hub_origin, pairSalt: cand.pair_salt });
    tried.push({ kind: cand.kind, salt: cand.pair_salt, origin: cand.pair_hub_origin, keys });
  }
  const noMatch = () => new Error(refusedOrigins.size > 0 ? notAcceptedMessage([...refusedOrigins], [...accepted]) : NO_MATCH_MESSAGE);
  if (tried.length === 0) throw noMatch();
  let info: DeviceCodeInfo;
  try {
    info = await verifyPairLookups(tried.map((c) => c.keys.lookup));
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) throw noMatch();
    throw err;
  }
  const match = tried.find((c) => c.kind === info.kind && c.salt === info.pair_salt && c.origin === info.pair_hub_origin);
  if (!match) throw new Error('The server answered for a different pairing request. Nothing was approved.');
  const { keys } = match;
  const origin = { hubOrigin: match.origin, foreignOrigin: match.origin !== ownOrigin };
  if (info.kind === 'browser') {
    const browser = await checkBrowserCodeInfo(info as BrowserCodeInfo, keys, userId);
    return { info, keys, browser, fingerprint: browser.fingerprint, label: browser.label || 'Browser', ...origin };
  }
  await checkBridgeCodeInfo(info as BridgeCodeInfo, keys);
  const fingerprint = await fingerprintFor(String((info as BridgeCodeInfo).bridge_identity_public_key || ''), '');
  return { info, keys, browser: null, fingerprint, label: hostLabelOf(info), ...origin };
}

/** This page's own API origin, or null outside an http(s) page. */
function ownPairingOrigin(): string | null {
  try {
    return pairingHubOrigin();
  } catch {
    return null;
  }
}

function notAcceptedMessage(refused: string[], accepted: string[]): string {
  return `No device this hub accepts is waiting with that code. A pending request was started against ${refused.join(', ')}, which is not one of this hub's pairing addresses (${accepted.join(', ') || 'none'}). Restart it with this hub's address (ham-bridge enroll -Hub <address>); if that address really is this hub, its operator must add it to --pairing-hub-origins.`;
}

/**
 * REQ-ENR-2: waits until the approved bridge is online and enrolled. The bridge list
 * is patched live by the hub's bridge status_changed event; a GET /bridges/{id} poll
 * covers a dropped event. Gives up after RECONNECT_TIMEOUT_MS with Retry and Skip.
 * Also used by the first-run setup wizard.
 */
export function BridgeReconnectWait({ bridgeId, label, onReady, onSkip, skipLabel = 'Skip — configure later in Settings → Providers' }: { bridgeId: string; label: string; onReady: () => void; onSkip: () => void; skipLabel?: string }) {
  const [startedAt, setStartedAt] = useState(() => Date.now());
  const [now, setNow] = useState(() => Date.now());
  const [polledReady, setPolledReady] = useState(false);
  const { data: bridgeList } = useListBridgesQuery();
  const listedRow = (Array.isArray(bridgeList?.bridges) ? bridgeList.bridges : [])
    .find((row: any) => String(row?.bridge_id || row?.id || '') === bridgeId);
  const stage = reconnectStage(polledReady || bridgeReconnectReady(listedRow), startedAt, now);

  useEffect(() => {
    if (stage !== 'waiting') return;
    // The countdown runs on its own clock, so a stalled GET cannot hide Retry/Skip.
    return startReconnectWait({
      poll: async (signal) => bridgeReconnectReady(await fetchBridgeRow(bridgeId, signal)),
      onReady: () => setPolledReady(true),
      onTick: setNow,
    });
  }, [bridgeId, startedAt, stage]);

  useEffect(() => { if (stage === 'ready') onReady(); }, [stage, onReady]);

  if (stage === 'timed-out') {
    return (
      <div data-debug-id="device-approval-reconnect-timeout" className="flex flex-col gap-3">
        <Alert tone="warning" title="The bridge has not reconnected yet">
          “{label}” was approved and given the vault key, but it has not come back online. Check that its service restarted.
        </Alert>
        <div className="flex flex-wrap gap-2">
          <Button data-debug-id="device-approval-reconnect-retry-btn" variant="primary" onClick={() => { setPolledReady(false); setStartedAt(Date.now()); setNow(Date.now()); }}>Retry</Button>
          <Button data-debug-id="device-approval-reconnect-skip-btn" variant="ghost" onClick={onSkip}>{skipLabel}</Button>
        </div>
      </div>
    );
  }
  return (
    <p data-debug-id="device-approval-reconnecting" className="flex items-center gap-2 text-sm text-muted">
      <Spinner size="sm" /> Waiting for the bridge to restart and reconnect… ({reconnectSecondsLeft(startedAt, now)} s)
    </p>
  );
}

export default function DeviceApprovalPage() {
  const entitlements = useEntitlements();
  const { data: bridgesData } = useListBridgesQuery();
  const [pendingCount, setPendingCount] = useState(0);
  const [waitingBridgeId, setWaitingBridgeId] = useState('');
  const [cancellingEnrollment, setCancellingEnrollment] = useState(false);
  const [cancelError, setCancelError] = useState('');
  const enrollmentWait = useRef<AbortController | null>(null);
  const [planError, setPlanError] = useState<PlanLimitDetails | null>(null);
  const [code, setCode] = useState('');
  const [phase, setPhase] = useState<Phase>({ kind: 'enter' });
  // The code input is locked once a lookup is in flight or succeeded: approve/deny always
  // act on the looked-up request, never on a later edit.
  const codeLocked = phase.kind === 'loading' || phase.kind === 'review' || phase.kind === 'working' || phase.kind === 'reconnecting' || phase.kind === 'providers';
  const [label, setLabel] = useState('');
  const [bridgeChoice, setBridgeChoice] = useState<BridgeChoice>({ mode: 'new', targetBridgeId: '' });

  useEffect(() => {
    if (phase.kind !== 'review' || phase.browser) return;
    let cancelled = false;
    void fetchPendingBridgeEnrollments().then((rows) => {
      if (!cancelled) setPendingCount(rows.filter((row) => !row.replacing).length);
    }).catch(() => {});
    return () => { cancelled = true; };
  }, [phase.kind]);
  const bridgeCount = (bridgesData?.bridges || []).filter((b: any) => !b.revoked_at && b.status !== 'revoked').length + pendingCount;
  const atCapacity = atPlanLimit(entitlements.max_bridges, bridgeCount);
  const effectiveBridgeChoice = phase.kind === 'review' && !phase.browser
    ? bridgeChoiceAtLimit(phase.info as BridgeCodeInfo, bridgeChoice, atCapacity)
    : bridgeChoice;

  const lookUp = useCallback(async (raw: string) => {
    if (!raw.trim()) return;
    setPlanError(null);
    setPhase({ kind: 'loading' });
    try {
      const review = await lookUpPairing(raw, deviceVaultUserId());
      setLabel(review.label);
      setBridgeChoice(initialBridgeChoice(review.browser ? null : (review.info as BridgeCodeInfo)));
      setPhase({ kind: 'review', ...review });
    } catch (err) {
      setPhase({ kind: 'failed', message: errText(err) });
    }
  }, []);

  // REQ-ENR-INAPP-1: a code this desktop app's own enrollment printed is looked up
  // at once (taken once, so a reload or revisit asks for it again).
  const [fromApp, setFromApp] = useState(false);
  useEffect(() => {
    const take = () => {
      const handed = takePendingApprovalCode();
      if (!handed) return;
      setFromApp(true);
      setCode(handed);
      void lookUp(handed);
    };
    take();
    return subscribePendingApprovalCode(take);
  }, [lookUp]);

  const approve = useCallback(async () => {
    if (phase.kind !== 'review') return;
    const identity = currentDeviceIdentity();
    const signed = deviceSignerContext();
    if (!identity || !signed) {
      setPhase({ kind: 'failed', message: 'This device is not ready to approve.' });
      return;
    }
    const { info, keys, browser } = phase;
    const finalLabel = label.trim() || phase.label;
    try {
      if (browser) {
        setPhase({ kind: 'working', message: 'Verifying your device directory…' });
        const chain = await verifiedChainForApproval();
        const body = await withKeyringBytes((bytes) => buildBrowserApproval(identity, chain, browser, keys, finalLabel, bytes), chain);
        await postApproveBrowser(browser.device_id, body, signed);
        await refreshDeviceVault('approved-browser');
        setPhase({ kind: 'done', message: `Approved “${finalLabel}”. It checks the approval with its code and installs your keys on its own.` });
        return;
      }
      const bridgeInfo = info as BridgeCodeInfo;
      const target = reuseTarget(reusableBridgesOf(bridgeInfo), effectiveBridgeChoice);
      if (effectiveBridgeChoice.mode === 'reuse' && !target) throw new Error('Pick the bridge identity to reuse.');
      // The signed approval, the hub's re-check of the reuse target and the vault-key
      // delivery are shared with the setup wizard (bridgeApproval.ts). The wait for
      // the enrolling bridge stays cancellable from this page.
      const wait = new AbortController();
      enrollmentWait.current = wait;
      setCancelError('');
      try {
        const outcome = await approveBridgeEnrollment({
          info: bridgeInfo,
          keys,
          target,
          newLabel: finalLabel,
          onProgress: (message) => setPhase({ kind: 'working', message }),
          waitSignal: wait.signal,
          onWaiting: setWaitingBridgeId,
        });
        setPhase({ kind: 'reconnecting', bridgeId: outcome.bridgeId, label: outcome.label, approved: outcome.approved });
      } finally {
        setWaitingBridgeId('');
        enrollmentWait.current = null;
      }
    } catch (err) {
      if (isPlanLimitError(err)) setPlanError(planLimitDetails(err));
      setPhase({ kind: 'failed', message: errText(err) });
    }
  }, [phase, label, effectiveBridgeChoice]);

  const cancelEnrollment = async () => {
    const wait = enrollmentWait.current;
    if (!waitingBridgeId || !wait) return;
    setCancellingEnrollment(true);
    setCancelError('');
    try {
      const result = await cancelBridgeEnrollment(waitingBridgeId);
      // A commit may have won the race. Only the Hub's rollback verdict cancels
      // this wait; never tell a committed bridge to discard its new credential.
      if (result.rolledBack) wait.abort(new Error('Bridge enrollment cancelled.'));
    } catch (err) {
      setCancelError(errText(err));
    } finally {
      setCancellingEnrollment(false);
    }
  };

  const deny = useCallback(async () => {
    if (phase.kind !== 'review') return;
    const signed = deviceSignerContext();
    try {
      setPhase({ kind: 'working', message: 'Denying…' });
      if (phase.browser) {
        if (!signed) throw new Error('This device cannot sign.');
        const { chain } = await fetchVerifiedChain();
        await postDenyDevice(phase.browser.device_id, chain.version, signed);
      } else {
        await postApproveBridge({ pair_lookup: phase.keys.lookup, approve: false });
      }
      setPhase({ kind: 'done', message: 'Denied. The device was not added.' });
    } catch (err) {
      setPhase({ kind: 'failed', message: errText(err) });
    }
  }, [phase]);

  const reset = () => { setCode(''); setPhase({ kind: 'enter' }); };
  const onBridgeReconnected = useCallback(() => {
    setPhase((p) => p.kind === 'reconnecting' ? { kind: 'providers', bridgeId: p.bridgeId, label: p.label, approved: p.approved } : p);
  }, []);

  return (
    <div data-debug-id="device-approval-page" className="mx-auto w-full max-w-xl p-4">
      <h1 className="mb-1 flex items-center gap-2 text-lg font-semibold text-primary"><Icon name="lock" size={18} />Add a device</h1>
      {fromApp ? (
        <p data-debug-id="device-approval-from-app" className="mb-4 text-sm text-muted">This app is setting up its Bridge; its pairing code was filled in for you. Check the details, then approve.</p>
      ) : (
        <p className="mb-4 text-sm text-muted">Type the pairing code shown on the new browser or printed by <code>ham-bridge enroll</code>.</p>
      )}

      <form
        className="mb-4 flex gap-2"
        onSubmit={(e) => { e.preventDefault(); if (!codeLocked) void lookUp(code); }}
      >
        <Input data-debug-id="device-approval-code-input" value={code} onChange={setCode} placeholder="XXXX-XXXX-XXXX-XX" className="flex-1" autoFocus autoComplete="off" disabled={codeLocked} />
        {codeLocked && phase.kind === 'review' ? (
          <Button data-debug-id="device-approval-change-code-btn" variant="ghost" onClick={reset}>Change</Button>
        ) : (
          <Button data-debug-id="device-approval-lookup-btn" type="submit" loading={phase.kind === 'loading'} disabled={!code.trim() || codeLocked}>Look up</Button>
        )}
      </form>

      {phase.kind === 'review' ? (
        <div data-debug-id="device-approval-review" className="rounded-2xl border border-subtle bg-surface p-4">
          <p className="mb-3 text-xs text-muted">The code matched this request and its keys were checked with it.</p>
          <dl className="mb-3 grid grid-cols-[8rem_1fr] gap-y-1 text-sm">
            <dt className="text-muted">Kind</dt>
            <dd data-debug-id="device-approval-kind" className="text-primary">{phase.browser ? 'Browser' : 'Bridge'}</dd>
            <dt className="text-muted">Claims to be</dt>
            <dd data-debug-id="device-approval-host-label" className="truncate text-primary">{phase.label}</dd>
            <dt className="text-muted">Fingerprint</dt>
            <dd><code data-debug-id="device-approval-fingerprint" className="font-mono tracking-wider text-primary">{phase.fingerprint}</code></dd>
            <dt className="text-muted">Hub address</dt>
            <dd data-debug-id="device-approval-hub-origin" className={phase.foreignOrigin ? 'font-medium text-warning' : 'text-primary'}>
              <code className="font-mono">{phase.hubOrigin}</code>
              {phase.foreignOrigin ? <span data-debug-id="device-approval-hub-origin-alias" className="ml-2 text-xs">differs from this page; accepted as a configured alias of this hub</span> : null}
            </dd>
            {phase.browser && (phase.info as BrowserCodeInfo).created_at ? (<>
              <dt className="text-muted">Requested</dt>
              <dd data-debug-id="device-approval-requested-at" className="text-primary">{new Date(String((phase.info as BrowserCodeInfo).created_at)).toLocaleString()}</dd>
            </>) : null}
          </dl>
          {phase.browser ? null : <BridgeIdentityChoice info={phase.info as BridgeCodeInfo} choice={effectiveBridgeChoice} onChange={setBridgeChoice} atCapacity={atCapacity} />}
          {phase.browser || effectiveBridgeChoice.mode === 'new' ? (<>
            <label className="mb-1 block text-xs font-medium text-muted" htmlFor="device-approval-label">Name it (signed into the approval)</label>
            <Input id="device-approval-label" data-debug-id="device-approval-label-input" value={label} onChange={setLabel} className="mb-3" />
          </>) : null}
          <div className="flex flex-wrap gap-2">
            <Button data-debug-id="device-approval-approve-btn" variant="primary" disabled={!phase.browser && atCapacity && !effectiveBridgeChoice.targetBridgeId} onClick={() => void approve()}>Approve</Button>
            <Button data-debug-id="device-approval-deny-btn" variant="danger" onClick={() => void deny()}>Deny</Button>
          </div>
        </div>
      ) : null}

      {planError ? <UpgradePrompt details={planError} debugId="device-approval-plan-error" /> : null}
      {phase.kind === 'working' ? <p data-debug-id="device-approval-progress" className="text-sm text-muted">{phase.message}</p> : null}
      {waitingBridgeId ? <Button data-debug-id="device-approval-cancel-enrollment-btn" variant="ghost" disabled={cancellingEnrollment} onClick={() => void cancelEnrollment()}>{cancellingEnrollment ? 'Cancelling…' : 'Cancel enrollment'}</Button> : null}
      {cancelError ? <p data-debug-id="device-approval-cancel-enrollment-error" role="alert" className="text-sm text-danger">{cancelError}</p> : null}
      {phase.kind === 'reconnecting' || phase.kind === 'providers' ? (
        <p data-debug-id="device-approval-bridge-outcome" className="mb-3 text-sm">{phase.approved}</p>
      ) : null}
      {phase.kind === 'reconnecting' ? (
        <BridgeReconnectWait
          bridgeId={phase.bridgeId}
          label={phase.label}
          onReady={onBridgeReconnected}
          onSkip={() => setPhase({ kind: 'done', message: `${phase.approved} Choose its providers later in Settings → Providers once it is online.` })}
        />
      ) : null}
      {phase.kind === 'providers' ? (
        <div data-debug-id="device-approval-providers" className="rounded-2xl border border-subtle bg-surface p-4">
          <ProviderSetupSurface
            bridgeId={phase.bridgeId}
            mode="enrollment"
            variant="compact"
            onApply={() => setPhase({ kind: 'done', message: `${phase.approved} Bridge “${phase.label}” is online and its providers are set up.` })}
          />
        </div>
      ) : null}
      {phase.kind === 'done' ? (
        <div data-debug-id="device-approval-done" className="flex flex-col gap-3">
          <Alert tone="success" title={phase.message.startsWith('Denied') ? 'Request denied' : 'Device approved'}>{phase.message}</Alert>
          <div className="flex flex-wrap gap-2">
            {fromApp ? <Button data-debug-id="device-approval-bridges-btn" variant="primary" onClick={() => { window.location.hash = '#/settings/bridges'; }}>Back to Bridges</Button> : null}
            <Button data-debug-id="device-approval-home-btn" variant={fromApp ? 'ghost' : 'primary'} onClick={() => { window.location.hash = '#/home'; }}>Go to home</Button>
            <Button data-debug-id="device-approval-another-btn" variant="ghost" onClick={reset}>Add another device</Button>
          </div>
        </div>
      ) : null}
      {phase.kind === 'failed' ? <div data-debug-id="device-approval-error"><Alert tone="danger">{phase.message}</Alert></div> : null}
    </div>
  );
}

/** New vs Reuse for a bridge grant; Reuse is hidden when the approver has no reusable bridge. */
export function BridgeIdentityChoice({ info, choice, onChange, atCapacity = false }: { info: BridgeCodeInfo; choice: BridgeChoice; onChange: (c: BridgeChoice) => void; atCapacity?: boolean }) {
  const list = reusableBridgesOf(info);
  if (list.length === 0) return atCapacity ? <UpgradePrompt details={{ limit: 'max_bridges' }} debugId="device-approval-bridge-cap" /> : null;
  const hinted = typeof info.previous_bridge_id === 'string' ? info.previous_bridge_id : '';
  const targetId = choice.targetBridgeId || list[0].bridge_id;
  return (
    <fieldset data-debug-id="device-approval-bridge-mode" className="mb-3 flex flex-col gap-2">
      <legend className="mb-1 text-xs font-medium text-muted">Bridge identity</legend>
      {atCapacity ? <UpgradePrompt details={{ limit: 'max_bridges' }} debugId="device-approval-bridge-cap" /> : null}
      <Radio name="device-approval-bridge-mode" value="new" disabled={atCapacity} data-debug-id="device-approval-mode-new" checked={choice.mode === 'new'} onChange={() => onChange({ mode: 'new', targetBridgeId: targetId })} label="Register as a new bridge" />
      <Radio name="device-approval-bridge-mode" value="reuse" data-debug-id="device-approval-mode-reuse" checked={choice.mode === 'reuse'} onChange={() => onChange({ mode: 'reuse', targetBridgeId: targetId })} label="Reuse an existing bridge identity" />
      {choice.mode === 'reuse' ? (<>
        <div data-debug-id="device-approval-reuse-list" role="radiogroup" aria-label="Bridge to reuse" className="ml-6 flex flex-col gap-1">
          {list.map((b) => {
            const name = sanitizeForDisplay(b.label || b.bridge_id).text;
            const host = sanitizeForDisplay(b.machine_hostname).text;
            return (
              <Radio
                key={b.bridge_id}
                name="device-approval-reuse-target"
                value={b.bridge_id}
                data-debug-id={`device-approval-reuse-${b.bridge_id}`}
                checked={choice.targetBridgeId === b.bridge_id}
                onChange={() => onChange({ mode: 'reuse', targetBridgeId: b.bridge_id })}
                label={(
                  <span className="text-sm">
                    <span className="text-primary">{name}</span>
                    {host ? <span className="text-muted"> · {host}</span> : null}
                    <span className={b.status === 'online' ? 'text-success' : 'text-muted'}> · {reusableBridgeStatusText(b)}</span>
                    {b.bridge_id === hinted ? <span className="text-muted"> · this machine says it was this bridge</span> : null}
                  </span>
                )}
              />
            );
          })}
        </div>
        <div data-debug-id="device-approval-reuse-warning"><Alert tone="warning">{REUSE_WARNING}</Alert></div>
      </>) : null}
    </fieldset>
  );
}
