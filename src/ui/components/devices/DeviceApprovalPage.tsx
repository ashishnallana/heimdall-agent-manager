// /device/add — the ONE approval surface for new browsers AND new bridges
// (docs/plans/passwordless-vault.md requirement 2, §1 "Pairing").
//
// Hub-blind pairing: the user types, ONCE, the secret pairing code the new browser
// shows (or `ham-bridge enroll` prints). The code never goes to the hub: this page
// derives a lookup from it to find the request, and checks the request's key_mac
// with it — proof the hub did not swap the new device's keys. The approval then
// carries a pair_mac under the same code, which the new device checks before it
// trusts this account's root. Links never carry a code.
//   browser → signed approval statement + keyring wrap + pair_mac;
//   bridge  → signed approval of its identity key via /device/approve, then (once the
//             enrolling process is connected) unseal v2 to an ephemeral key signed by
//             exactly that identity, with the chain proof and the pair_mac.

import React, { useCallback, useState } from 'react';
import { Alert, Button, Icon, Input } from '@ui';
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
import { fetchBridgeEnrollmentStatus, fetchBridgeUnsealTarget, unsealBridge } from '../../api/endpoints/bridges';
import { enrollmentPendingOutcome, ENROLLMENT_PENDING_FALLBACK_SECONDS } from '../enrollment/bridgeEnrollmentCompletion';
import { fingerprintFor } from '../../utils/deviceIdentity';
import { buildBridgeApproval, buildBrowserApproval, checkBridgeCodeInfo, checkBrowserCodeInfo, type PairedBrowser } from '../../utils/vaultDeviceFlows';
import { acceptedPairOrigins, derivePairKeys, isPairHubOrigin, isPairSalt, normalizePairCode, pairApproveMac, type PairKeys } from '../../utils/vaultPairing';
import { deliverKeyringToBridge } from '../../utils/vaultBridgeDelivery';
import { withKeyringBytes } from '../../utils/vaultKeyringSession';
import {
  currentDeviceIdentity,
  deviceSignerContext,
  deviceVaultUserId,
  fetchVerifiedChain,
  refreshDeviceVault,
  verifiedChainForApproval,
} from '../../services/deviceVault';

const POLL_MS = 2000;
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
  | { kind: 'done'; message: string }
  | { kind: 'failed'; message: string };

function errText(err: unknown): string {
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
  const [code, setCode] = useState('');
  const [phase, setPhase] = useState<Phase>({ kind: 'enter' });
  // The code input is locked once a lookup is in flight or succeeded: approve/deny always
  // act on the looked-up request, never on a later edit.
  const codeLocked = phase.kind === 'loading' || phase.kind === 'review' || phase.kind === 'working';
  const [label, setLabel] = useState('');

  const lookUp = useCallback(async (raw: string) => {
    if (!raw.trim()) return;
    setPhase({ kind: 'loading' });
    try {
      const review = await lookUpPairing(raw, deviceVaultUserId());
      setLabel(review.label);
      setPhase({ kind: 'review', ...review });
    } catch (err) {
      setPhase({ kind: 'failed', message: errText(err) });
    }
  }, []);

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
      setPhase({ kind: 'working', message: 'Verifying your device directory…' });
      const chain = await verifiedChainForApproval();
      if (browser) {
        const body = await withKeyringBytes((bytes) => buildBrowserApproval(identity, chain, browser, keys, finalLabel, bytes), chain);
        await postApproveBrowser(browser.device_id, body, signed);
        await refreshDeviceVault('approved-browser');
        setPhase({ kind: 'done', message: `Approved “${finalLabel}”. It checks the approval with its code and installs your keys on its own.` });
        return;
      }
      const bridgeInfo = info as BridgeCodeInfo;
      const { vault_approval, statement } = await buildBridgeApproval(identity, chain, bridgeInfo, finalLabel);
      const res = await postApproveBridge({ pair_lookup: keys.lookup, approve: true, vault_approval, new_bridge_label: finalLabel });
      const bridgeId = String(res?.hub_observed?.bridge_id || '');
      if (!bridgeId) throw new Error('The hub did not report the approved bridge id.');
      const expectedPublicKey = String(bridgeInfo.bridge_public_key || '');
      await waitForEnrollingBridge(bridgeId, (message) => setPhase({ kind: 'working', message }));
      setPhase({ kind: 'working', message: 'Delivering the vault key to the bridge…' });
      // Fresh, verified chain: it now contains this bridge's signed approval. The
      // pair_mac lets the bridge pin this account's root on its first unseal.
      const { chain: after } = await fetchVerifiedChain();
      const pairMac = await pairApproveMac(keys, statement, after.rootSignPub);
      await deliverKeyringToBridge(bridgeId, after, {
        fetchTarget: (id) => fetchBridgeUnsealTarget(id, true),
        dispatch: unsealBridge,
        withKeyringBytes: (fn) => withKeyringBytes(fn, after),
      }, { enrollment: true, expectedPublicKey, extra: { enrollment: true, expected_public_key: expectedPublicKey.trim().toLowerCase(), pair_mac: pairMac } });
      setPhase({ kind: 'done', message: `Bridge “${finalLabel}” approved and given the vault key. It restarts its service and comes online unsealed.` });
    } catch (err) {
      setPhase({ kind: 'failed', message: errText(err) });
    }
  }, [phase, label]);

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

  return (
    <div data-debug-id="device-approval-page" className="mx-auto w-full max-w-xl p-4">
      <h1 className="mb-1 flex items-center gap-2 text-lg font-semibold text-primary"><Icon name="lock" size={18} />Add a device</h1>
      <p className="mb-4 text-sm text-muted">Type the pairing code shown on the new browser or printed by <code>ham-bridge enroll</code>.</p>

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
          <label className="mb-1 block text-xs font-medium text-muted" htmlFor="device-approval-label">Name it (signed into the approval)</label>
          <Input id="device-approval-label" data-debug-id="device-approval-label-input" value={label} onChange={setLabel} className="mb-3" />
          <div className="flex flex-wrap gap-2">
            <Button data-debug-id="device-approval-approve-btn" variant="primary" onClick={() => void approve()}>Approve</Button>
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
            <Button data-debug-id="device-approval-another-btn" variant="ghost" onClick={reset}>Add another device</Button>
          </div>
        </div>
      ) : null}
      {phase.kind === 'failed' ? <div data-debug-id="device-approval-error"><Alert tone="danger">{phase.message}</Alert></div> : null}
    </div>
  );
}
