// Device vault orchestration (docs/plans/passwordless-vault.md §2 P3).
//
// Boots this browser's device identity for the signed-in user and drives it to one
// of the deviceVaultSlice states. Keys are installed ONLY after the directory chain
// verified against this device's pins and its wrap opened with a matching
// epoch_commit; any failure leaves no keys installed (fail closed).
//
// Hub-blind pairing (plan §1 "Pairing"): a new device draws a secret pairing code,
// shows it on the waiting screen and sends the hub only values derived from it. The
// approving device proves, with that code, that the approval (and so the account
// root it chains to) is genuine: this device pins the root only after verifying the
// approver's pair_mac. The code never leaves this device and is wiped once paired.

import * as vaultApi from '../api/endpoints/vaultDevices';
import { ApiError } from '../api/cookieFetch';
import {
  accountFingerprint,
  acknowledgeOtherAccount,
  advancePins,
  archiveDeviceState,
  createDeviceIdentity,
  forgetDeviceIdentity,
  MalformedDeviceStateError,
  loadObservedReset,
  observedResetElapsed,
  recordObservedReset,
  otherPinnedAccounts,
  indexedDbDeviceStore,
  loadDeviceIdentity,
  loadPins,
  type DeviceIdentity,
  type DeviceKeyValueStore,
  type DevicePins,
} from '../utils/deviceIdentity';
import { isVaultSupported } from '../utils/vaultCrypto';
import { pinsFromChain, trustedBridgeById, verifyDirectory, type VaultDirectory, type VerifiedChain } from '../utils/vaultDirectoryVerify';
import { clearKeyringSession, getKeyringSession, installKeyringFromWrap, withKeyringBytes } from '../utils/vaultKeyringSession';
import { buildBrowserApproval, buildGenesis, buildPairedRegistration, revokeWithRetry, rotateWithRetry, type RevokeOutcome, type RotateOutcome } from '../utils/vaultDeviceFlows';
import { derivePairKeys, generatePairCode, generatePairSalt, isPairHubOrigin, isPairSalt, pairCodeSymbols, PAIR_CODE_TTL_MS, verifyPairApproveMac, type PairContext } from '../utils/vaultPairing';
import { asApproverIdentity, buildRecoveryKey, openRecoveryKey, RecoveryKeyError } from '../utils/vaultRecovery';
import { openVerifiedWrap } from '../utils/vaultKeyringWrap';
import { serializeKeyringBytes } from '../utils/vaultKeyring';
import { trustedRecoveryKeys } from '../utils/vaultDirectoryVerify';
import { kindPolicy } from '../utils/vaultStatements';
import { buildConnectorEpochWraps, type ConnectorRecipient, type ConnectorEpochDelivery } from '../utils/mcpEpochDelivery';
import { deliverKeyringToBridges, type BridgeDeliveryDeps, type BridgeFanoutResult } from '../utils/vaultBridgeDelivery';
import {
  deviceVaultBusy,
  deviceVaultDirectoryVerified,
  deviceVaultFailed,
  deviceVaultIdentityKnown,
  deviceVaultStatusChanged,
  type DeviceVaultReset,
  type PendingDeviceSummary,
  bridgeKeyDeliveryReported,
  mcpKeyDeliveryReported,
} from '../store/deviceVaultSlice';
import { keyringCleared, keyringInstalled } from '../store/vaultSlice';

type Dispatch = (action: unknown) => unknown;
type VaultApi = typeof vaultApi;

export interface DeviceVaultDeps {
  connectors: { list: () => Promise<ConnectorRecipient[]>; deliver: (body: ConnectorEpochDelivery) => Promise<unknown>; resource: () => string } | null;
  kv: DeviceKeyValueStore;
  api: VaultApi;
  /** Bridge transport for unseal delivery (null: bridges are not re-unsealed). */
  bridges: Pick<BridgeDeliveryDeps, 'fetchTarget' | 'dispatch'> & {
    listOnlineBridgeIds: () => Promise<string[]>;
    /** Online bridges reporting no vault key (awaiting the key). */
    listOnlineLockedBridgeIds: () => Promise<string[]>;
  } | null;
  pollIntervalMs: number;
  /** Default label for this browser (signed into its approval; editable by the approver). */
  label: (identity: DeviceIdentity) => string;
}

interface Ctx {
  userId: string;
  dispatch: Dispatch;
  identity: DeviceIdentity | null;
  /** The signed log revoked this device (verified): it may re-enroll with a new identity. */
  revokedVerified: boolean;
  pollTimer: ReturnType<typeof setInterval> | null;
  seq: number;
  lastPendingIds: Set<string>;
  /** M1 freshness guard tripped: automatic bridge key delivery and hint revokes pause. */
  staleHead: boolean;
}

let deps: DeviceVaultDeps | null = null;
let ctx: Ctx | null = null;

/** Tests inject a memory store and a fake API; production uses IndexedDB and HTTP. */
export function configureDeviceVault(next: Partial<DeviceVaultDeps>): void {
  deps = { ...defaultDeps(), ...next } as DeviceVaultDeps;
}

function defaultDeps(): DeviceVaultDeps {
  return {
    connectors: null,
    kv: undefined as unknown as DeviceKeyValueStore, // created lazily (IndexedDB may be absent)
    api: vaultApi,
    bridges: null,
    pollIntervalMs: 4000,
    label: defaultBrowserLabel,
  };
}

function d(): DeviceVaultDeps {
  if (!deps) deps = defaultDeps();
  if (!deps.kv) deps.kv = indexedDbDeviceStore();
  return deps;
}

/**
 * "Firefox on Windows · 3fa2 · added 2026-10-19": browser and OS, the first group of
 * the device fingerprint and the date, so two browsers of the same kind (a normal and
 * a private window) are never listed under the same name.
 */
export function defaultBrowserLabel(identity?: Pick<DeviceIdentity, 'fingerprint'>, now: Date = new Date()): string {
  const base = baseBrowserLabel();
  const fp = identity?.fingerprint ? identity.fingerprint.slice(0, 4) : '';
  const day = now.toISOString().slice(0, 10);
  return [base, fp, `added ${day}`].filter(Boolean).join(' · ');
}

function baseBrowserLabel(): string {
  const ua = typeof navigator !== 'undefined' ? navigator.userAgent : '';
  const browser = /Edg\//.test(ua) ? 'Edge' : /Firefox\//.test(ua) ? 'Firefox' : /Chrome\//.test(ua) ? 'Chrome' : /Safari\//.test(ua) ? 'Safari' : 'Browser';
  const osName = /Windows/.test(ua) ? 'Windows' : /Android/.test(ua) ? 'Android' : /iPhone|iPad/.test(ua) ? 'iOS' : /Mac OS X/.test(ua) ? 'macOS' : /Linux/.test(ua) ? 'Linux' : '';
  return osName ? `${browser} on ${osName}` : browser;
}

const isStatus = (err: unknown, ...codes: number[]) => err instanceof ApiError && codes.includes(Number(err.status));
const message = (err: unknown) => String((err as Error)?.message || err);

const listsDevice = (dir: VaultDirectory, deviceId: string) => Array.isArray(dir.devices) && dir.devices.some((row) => row?.device_id === deviceId);

function deviceAuthFailedMessage(err: unknown): string {
  return `The hub refused this device's signed status check (HTTP ${(err as ApiError).status}: ${message(err)}). `
    + 'If you opened Ninjy through a preview or proxy, it must forward the X-Heimdall-Device-* headers to the hub. '
    + 'This device was not registered again: its identity and pairing code were kept. Retry once the connection is fixed.';
}

export function deviceSignerContext(): vaultApi.VaultSignerContext | null {
  if (!ctx?.identity) return null;
  return { userId: ctx.userId, signer: { deviceId: ctx.identity.deviceId, signPrivateKey: ctx.identity.signPrivateKey } };
}

export function currentDeviceIdentity(): DeviceIdentity | null {
  return ctx?.identity ?? null;
}

function stopPolling(): void {
  if (ctx?.pollTimer) clearInterval(ctx.pollTimer);
  if (ctx) ctx.pollTimer = null;
}

function startPolling(): void {
  if (!ctx || ctx.pollTimer) return;
  ctx.pollTimer = setInterval(() => { void refreshDeviceVault('poll'); }, d().pollIntervalMs);
}

function purgeKeys(dispatch: Dispatch): void {
  clearKeyringSession();
  dispatch(keyringCleared());
}

function resetFrom(dir: VaultDirectory | null): DeviceVaultReset | null {
  const r = dir?.reset;
  if (!r || !r.due_at) return null;
  return { requestedAt: String(r.requested_at ?? ''), effectiveAt: String(r.due_at) };
}

function pendingFrom(chain: VerifiedChain): PendingDeviceSummary[] {
  return chain.pending.map((p) => ({ deviceId: p.device_id, kind: p.kind, fingerprint: String(p.fingerprint ?? '') }));
}

/**
 * Fetch the directory and verify it against this device's pins; on success advance
 * the pins (monotonic). Throws on any verification failure.
 */
export async function fetchVerifiedChain(): Promise<{ chain: VerifiedChain; dir: VaultDirectory }> {
  if (!ctx) throw new Error('Device vault not started');
  const signed = deviceSignerContext() ?? undefined;
  const dir = await d().api.fetchVaultDirectory(signed);
  if (!dir) throw new Error('The vault directory is gone');
  const pins = await loadPins(d().kv, ctx.userId);
  const chain = await verifyDirectory(dir, ctx.userId, pins);
  if (pins) await advancePins(d().kv, ctx.userId, pinsFromChain(chain));
  await publishChain(chain, dir);
  return { chain, dir };
}

async function publishChain(chain: VerifiedChain, dir: VaultDirectory): Promise<void> {
  if (!ctx) return;
  // Remember the reset this VERIFIED directory announces (or that none is pending), so a
  // later "no directory" can be told apart from a reset this browser saw coming (M2).
  const reset = dir.reset?.due_at ? dir.reset : null;
  await recordObservedReset(d().kv, ctx.userId, reset ? { requested_at: String(reset.requested_at ?? ''), due_at: String(reset.due_at), head_seq: chain.version } : null);
  const freshness = await noteHeadFreshness(ctx.userId, chain);
  if (!ctx) return;
  ctx.staleHead = freshness.stale;
  ctx.dispatch(deviceVaultDirectoryVerified({
    accountFingerprint: await accountFingerprint(chain.rootSignPub),
    currentEpoch: chain.currentEpoch,
    directoryVersion: chain.version,
    headHash: chain.headHash.slice(0, 12),
    staleHead: freshness.stale,
    reset: resetFrom(dir),
    pendingDevices: pendingFrom(chain),
  }));
  // Hub retirement hints for trusted bridges: an approved device with its keyring
  // installed signs their real revoke (rate-limited, see scheduleHintRevocation).
  if (chain.retiredHints.length > 0 && getKeyringSession() && !ctx.staleHead) scheduleHintRevocation(chain);
}

// ── M1 freshness guard ──────────────────────────────────────────────────────
//
// A device that missed a revocation can be shown the old head by a hostile hub (it
// still extends the pins). Before AUTOMATIC actions (bridge key delivery, hint
// revokes) this device wants evidence it is current: when its verified head has not
// changed for more than STALE_HEAD_MS AND it had no successful directory fetch for
// more than OFFLINE_GAP_MS before this one, it marks the head stale and pauses the
// automatic actions until the head advances or the user confirms (after comparing the
// log head with another approved device). Manual "Send key" stays available.

export const STALE_HEAD_MS = 7 * 24 * 60 * 60 * 1000;
export const OFFLINE_GAP_MS = 24 * 60 * 60 * 1000;

export interface HeadFreshness {
  head_seq: number;
  head_hash: string;
  /** When this device first saw this head (or the user last confirmed it). */
  head_changed_at: number;
  /** Last successful verified directory fetch. */
  last_fetch_at: number;
  stale: boolean;
}

const headFreshnessKey = (userId: string) => `head-freshness:${userId}`;

/** Pure: the freshness record after a verified fetch of `head` at `now`. */
export function evaluateHeadFreshness(prev: HeadFreshness | null, head: { seq: number; hash: string }, now: number): HeadFreshness {
  if (!prev || prev.head_seq !== head.seq || prev.head_hash !== head.hash) {
    return { head_seq: head.seq, head_hash: head.hash, head_changed_at: now, last_fetch_at: now, stale: false };
  }
  const stale = prev.stale || (now - prev.head_changed_at > STALE_HEAD_MS && now - prev.last_fetch_at > OFFLINE_GAP_MS);
  return { ...prev, last_fetch_at: now, stale };
}

async function loadHeadFreshness(userId: string): Promise<HeadFreshness | null> {
  const v = await d().kv.get(headFreshnessKey(userId)) as HeadFreshness | undefined;
  return v && Number.isSafeInteger(v.head_seq) && typeof v.head_hash === 'string' && Number.isFinite(v.head_changed_at) && Number.isFinite(v.last_fetch_at) ? v : null;
}

async function noteHeadFreshness(userId: string, chain: VerifiedChain, now = Date.now()): Promise<HeadFreshness> {
  const next = evaluateHeadFreshness(await loadHeadFreshness(userId), { seq: chain.version, hash: chain.headHash }, now);
  await d().kv.put(headFreshnessKey(userId), next);
  return next;
}

/**
 * The user compared this device's log head with another approved device and they
 * match: re-confirm the head (resumes automatic actions until it goes stale again).
 */
export async function confirmDirectoryHeadCurrent(): Promise<void> {
  const c = ctx;
  if (!c) return;
  const { chain } = await fetchVerifiedChain();
  const now = Date.now();
  const rec: HeadFreshness = { head_seq: chain.version, head_hash: chain.headHash, head_changed_at: now, last_fetch_at: now, stale: false };
  await d().kv.put(headFreshnessKey(c.userId), rec);
  c.staleHead = false;
  await fetchVerifiedChain(); // re-publishes with the confirmed head
}

/** Start (or restart) the device vault for `userId`. Idempotent for the same user while running. */
export async function bootDeviceVault(userId: string, dispatch: Dispatch): Promise<void> {
  if (ctx && ctx.userId === userId && ctx.identity) return refreshDeviceVault('boot');
  stopPolling();
  if (ctx && ctx.userId !== userId) purgeKeys(dispatch);
  ctx = { userId, dispatch, identity: null, revokedVerified: false, pollTimer: null, seq: 0, lastPendingIds: new Set(), staleHead: false };
  dispatch(deviceVaultStatusChanged({ status: 'initializing', userId }));
  if (!isVaultSupported() || (typeof indexedDB === 'undefined' && !deps?.kv)) {
    dispatch(deviceVaultStatusChanged({ status: 'unsupported', userId }));
    return;
  }
  return refreshDeviceVault('boot');
}

/** Stop and purge (sign-out / user switch). */
export function stopDeviceVault(dispatch?: Dispatch): void {
  stopPolling();
  if (dispatch) purgeKeys(dispatch); else clearKeyringSession();
  ctx = null;
}

let refreshing: Promise<void> | null = null;
let followUp: Promise<void> | null = null;

/**
 * Re-evaluate the device state (boot, poll, WS nudge, after a mutation). Serialized
 * AND coalesced: while a refresh runs, any number of further requests (a burst of WS
 * events) share ONE follow-up run that starts after it, so a hub cannot make a
 * browser queue unbounded directory fetches/verifications.
 */
export function refreshDeviceVault(reason = 'refresh'): Promise<void> {
  if (!ctx) return Promise.resolve();
  if (refreshing) {
    if (!followUp) {
      // Runs after the current refresh whatever its outcome, and is cleared on BOTH
      // outcomes: a rejected refresh must not leave a settled follow-up that every
      // later burst would share without ever scheduling another run.
      const next: Promise<void> = refreshing.catch(() => undefined).then(() => {
        if (followUp === next) followUp = null;
        return ctx ? refreshDeviceVault(reason) : undefined;
      });
      followUp = next;
    }
    return followUp;
  }
  refreshing = runRefresh(reason).finally(() => { refreshing = null; });
  return refreshing;
}

async function runRefresh(_reason: string): Promise<void> {
  const c = ctx;
  if (!c) return;
  const seq = ++c.seq;
  const dispatch = c.dispatch;
  const stale = () => ctx !== c || c.seq !== seq;
  try {
    const kv = d().kv;
    if (!c.identity) c.identity = await loadDeviceIdentity(kv, c.userId);
    let dir = await d().api.fetchVaultDirectory(deviceSignerContext() ?? undefined);
    if (stale()) return;

    if (!dir) {
      purgeKeys(dispatch);
      stopPolling();
      if (await refuseUnacknowledgedAccount(c)) return;
      const pins = await loadPins(kv, c.userId);
      if (pins) {
        // M2: a missing directory is a reset ONLY when this browser recorded a verified
        // reset whose due time has passed. Otherwise fail closed: the hub may be lying.
        const observed = await loadObservedReset(kv, c.userId);
        if (observedResetElapsed(observed)) {
          dispatch(deviceVaultFailed({
            code: 'vault_reset',
            message: `This account's vault was reset as scheduled (due ${observed!.due_at}). The old keys are gone; encrypted history is unreadable.`,
          }));
        } else {
          dispatch(deviceVaultFailed({
            code: 'vault_missing',
            message: 'Vault missing — the server may be misbehaving. This browser never saw a reset of this vault come due. Contact your admin before continuing.',
            startOverPhrase: await startOverPhraseFor(pins),
          }));
        }
        return;
      }
      await runGenesis(c);
      return;
    }

    if (!c.identity) c.identity = await createDeviceIdentity(kv, c.userId);
    const identity = c.identity;
    dispatch(deviceVaultIdentityKnown({ userId: c.userId, deviceId: identity.deviceId, fingerprint: identity.fingerprint }));

    let self: vaultApi.VaultSelfStatus | null = null;
    try {
      self = await d().api.fetchVaultSelf(deviceSignerContext()!);
    } catch (err) {
      if (!isStatus(err, 401, 403, 404)) throw err;
      if (stale()) return;
      // The hub answers an unknown signer with 403/404: a legitimate first
      // registration. A 401 (signature missing or refused), or a 403/404 for a device
      // the directory already lists, is an auth failure: registering again would only
      // replace this device's pending code on every poll. Keep it and say why.
      if (isStatus(err, 401) || listsDevice(dir, identity.deviceId)) {
        stopPolling();
        dispatch(deviceVaultFailed({ code: 'device_auth_failed', message: deviceAuthFailedMessage(err) }));
        return;
      }
    }
    if (stale()) return;

    if (!self || self.device_id !== identity.deviceId) {
      purgeKeys(dispatch);
      await register(c, dir);
      return;
    }
    if (self.status === 'revoked') {
      // Keys in memory go at once (fail closed), but the hub's word alone never makes
      // this browser treat itself as revoked: only a revoke of THIS device id in the
      // verified signed log does (it then may discard its identity and re-enroll).
      purgeKeys(dispatch);
      stopPolling();
      const chain = await verifyDirectory(dir, c.userId, await loadPins(kv, c.userId));
      if (stale()) return;
      if (!chain.revokedIds.has(identity.deviceId)) {
        c.revokedVerified = false;
        dispatch(deviceVaultFailed({
          code: 'unverified_revocation',
          message: 'The server says this device was revoked, but the signed device log has no such revocation. Nothing was deleted from this browser. Retry later; if this persists, the server is misbehaving.',
        }));
        return;
      }
      c.revokedVerified = true;
      dispatch(deviceVaultStatusChanged({ status: 'revoked' }));
      return;
    }
    if (self.status === 'pending') {
      const reset = resetFrom(dir);
      const pending = await loadPendingCode(c);
      const live = pending && Date.now() < pending.expiresAt ? pending : null;
      dispatch(deviceVaultStatusChanged({ status: reset ? 'reset-scheduled' : 'pending-approval', reset, userCode: live?.code ?? '', codeExpiresAt: live ? new Date(live.expiresAt).toISOString() : '' }));
      startPolling();
      return;
    }
    if (self.status !== 'approved' || !self.wrap) throw new Error(`unexpected device status ${self.status}`);

    // Approved: verify the chain against the pins BEFORE touching the wrap.
    const pins = await loadPins(kv, c.userId);
    const chain = await verifyDirectory(dir, c.userId, pins);
    if (stale()) return;
    await publishChain(chain, dir);
    const mine = chain.trusted.get(identity.deviceId);
    if (!mine) throw new Error('This device is not approved by a verified chain');
    stopPolling();
    noticePending(c, chain);

    // The device that created the vault IS the root: its own key needs no pairing proof.
    // (A browser restored with the recovery key takes the pairing path below: it made
    // the approval's pair_mac itself, under its own code, after verifying the log.)
    if (!pins && chain.rootDeviceId === identity.deviceId && chain.rootSignPub === identity.signPub) {
      await kv.delete(`pending:${c.userId}`);
      await advancePins(kv, c.userId, pinsFromChain(chain));
      const keyring = await installKeyringFromWrap(identity, self.wrap, chain);
      dispatch(keyringInstalled({ currentEpoch: keyring.currentEpoch }));
      dispatch(deviceVaultStatusChanged({ status: 'ready', currentEpoch: chain.currentEpoch, directoryVersion: chain.version }));
      return;
    }
    if (!pins) {
      // First sight of the account on this device (threat model: hub-injected root).
      // Never automatically when this browser already pinned ANOTHER account (M2).
      if (await refuseUnacknowledgedAccount(c)) return;
      // Hub-blind pairing: the approver MACed this device's approval, the root and
      // the head with the code shown here. The approval's prev_hash chain covers the
      // whole log prefix (genesis included), so a valid pair_mac proves the root is
      // the one the user's other device trusts. No pair_mac, no keys.
      const pending = await loadPendingCode(c);
      if (!pending || Date.now() > pending.expiresAt + PAIR_GRACE_MS) {
        await kv.delete(`pending:${c.userId}`);
        dispatch(deviceVaultFailed({ code: 'pairing_unverified', message: PAIRING_LOST_MESSAGE }));
        return;
      }
      const keys = await derivePairKeys(pending.code, pendingPairContext(c, pending));
      if (stale()) return;
      if (!(await verifyPairApproveMac(keys, mine.approval_statement, chain.rootSignPub, self.pair_mac))) {
        dispatch(deviceVaultFailed({
          code: 'pairing_mismatch',
          message: 'This device was approved, but the approval does not carry proof from the device you typed the pairing code into. No keys were installed. The server may be misbehaving; retry, or pair again.',
        }));
        return;
      }
      if (stale()) return;
      await advancePins(kv, c.userId, pinsFromChain(chain));
      await kv.delete(`pending:${c.userId}`);
      const keyring = await installKeyringFromWrap(identity, self.wrap, chain);
      dispatch(keyringInstalled({ currentEpoch: keyring.currentEpoch }));
      dispatch(deviceVaultStatusChanged({ status: 'ready', currentEpoch: chain.currentEpoch, directoryVersion: chain.version }));
      return;
    }
    await kv.delete(`pending:${c.userId}`);
    await advancePins(kv, c.userId, pinsFromChain(chain));
    const session = getKeyringSession();
    if (!session || session.keyring.currentEpoch !== chain.currentEpoch || session.identity.deviceId !== identity.deviceId) {
      const keyring = await installKeyringFromWrap(identity, self.wrap, chain);
      dispatch(keyringInstalled({ currentEpoch: keyring.currentEpoch }));
    }
    dir = null;
    dispatch(deviceVaultStatusChanged({ status: 'ready', currentEpoch: chain.currentEpoch, directoryVersion: chain.version }));
  } catch (err) {
    if (stale()) return;
    if (err instanceof TypeError || isStatus(err, 502, 503, 504)) {
      // Transport failure: keep any installed keys, report, retry by poll.
      if (!getKeyringSession()) dispatch(deviceVaultFailed({ code: 'hub_unreachable', message: `Cannot reach the hub: ${message(err)}` }));
      return;
    }
    purgeKeys(dispatch);
    stopPolling();
    if (err instanceof MalformedDeviceStateError) {
      dispatch(deviceVaultFailed({
        code: 'device_state_malformed',
        message: `${message(err)}. Nothing was used. You can reset this browser's device data: the old identity and pins are archived (not deleted) and this browser asks to be approved again as a new device.`,
        startOverPhrase: RESET_DEVICE_DATA_PHRASE,
      }));
      return;
    }
    dispatch(deviceVaultFailed({ code: 'verification_failed', message: message(err) }));
  }
}

export const RESET_DEVICE_DATA_PHRASE = 'RESET THIS BROWSER';

/**
 * Recovery for unreadable local device data (malformed / older-format identity or
 * pins): only while it IS unreadable, and only with the typed phrase. Archives (never
 * deletes) identity, pins and the observed reset, then restarts as a fresh device
 * (register -> waiting screen with a new pairing code).
 */
export async function resetBrowserDeviceData(typedPhrase: string): Promise<void> {
  const c = ctx;
  if (!c) return;
  if (normalizePhrase(typedPhrase) !== RESET_DEVICE_DATA_PHRASE) throw new Error(`Type "${RESET_DEVICE_DATA_PHRASE}" exactly to reset this browser's device data.`);
  const kv = d().kv;
  let unreadable = false;
  try {
    await loadDeviceIdentity(kv, c.userId);
    await loadPins(kv, c.userId);
  } catch (err) {
    if (!(err instanceof MalformedDeviceStateError)) throw err;
    unreadable = true;
  }
  if (!unreadable) throw new Error("This browser's device data is readable; nothing was reset. Retry instead.");
  await archiveDeviceState(kv, c.userId);
  await kv.delete(`pending:${c.userId}`);
  c.identity = null;
  c.revokedVerified = false;
  await refreshDeviceVault('device-data-reset');
}

function noticePending(c: Ctx, chain: VerifiedChain): void {
  c.lastPendingIds = new Set(chain.pending.map((p) => p.device_id));
}

async function runGenesis(c: Ctx): Promise<void> {
  const dispatch = c.dispatch;
  const kv = d().kv;
  const identity = c.identity ?? (c.identity = await createDeviceIdentity(kv, c.userId));
  dispatch(deviceVaultIdentityKnown({ userId: c.userId, deviceId: identity.deviceId, fingerprint: identity.fingerprint }));
  dispatch(deviceVaultStatusChanged({ status: 'genesis' }));
  const body = await buildGenesis(identity, d().label(identity));
  try {
    await d().api.postVaultGenesis(body);
  } catch (err) {
    if (!isStatus(err, 409)) throw err;
    // Another device created the vault first: register this one instead.
  }
  if (ctx === c) await runRefresh('after-genesis');
}

/** Pairing code lifetime on this device: the hub's TTL plus a small clock grace. */
const PAIR_GRACE_MS = 60_000;
const PAIRING_LOST_MESSAGE = 'This device was approved, but it no longer holds a live pairing code to verify the approval with (the code expired or this browser\'s data was cleared). No keys were installed. Pair again: this browser gets a new identity and code; revoke the old entry in Settings → Devices on your other device.';

interface PendingPairing {
  /** The secret pairing code S ("XXXX-XXXX-XXXX-XX"); never sent anywhere. */
  code: string;
  /** Public salt of the pairing stretch, sent with the registration. */
  pairSalt: string;
  /** The hub origin the code was bound to. */
  hubOrigin: string;
  issuedAt: number;
  expiresAt: number;
}

async function loadPendingCode(c: Ctx): Promise<PendingPairing | null> {
  const v = await d().kv.get(`pending:${c.userId}`) as Partial<PendingPairing> | undefined;
  if (!v || !pairCodeSymbols(v.code) || !isPairSalt(v.pairSalt) || !isPairHubOrigin(v.hubOrigin) || !Number.isFinite(v.issuedAt) || !Number.isFinite(v.expiresAt)) return null;
  return { code: String(v.code), pairSalt: v.pairSalt, hubOrigin: v.hubOrigin, issuedAt: Number(v.issuedAt), expiresAt: Number(v.expiresAt) };
}

function pendingPairContext(c: Ctx, p: Pick<PendingPairing, 'pairSalt' | 'hubOrigin'>): PairContext {
  return { kind: 'browser', userId: c.userId, hubOrigin: p.hubOrigin, pairSalt: p.pairSalt };
}

async function register(c: Ctx, dir: VaultDirectory): Promise<void> {
  const identity = c.identity!;
  // A fresh secret code and public salt per registration; kept locally (IndexedDB) until paired.
  const code = generatePairCode();
  const issuedAt = Date.now();
  const pending: PendingPairing = { code, pairSalt: generatePairSalt(), hubOrigin: d().api.pairingHubOrigin(), issuedAt, expiresAt: issuedAt + PAIR_CODE_TTL_MS };
  const keys = await derivePairKeys(code, pendingPairContext(c, pending));
  const body = await buildPairedRegistration(identity, d().label(identity), keys, issuedAt);
  const res = await d().api.postVaultRegister(body.statement, body.signature, body.pairLookup, body.pairKeyMac, pending.pairSalt, pending.hubOrigin);
  if (res.device_id !== identity.deviceId || res.fingerprint !== identity.fingerprint) {
    throw new Error('The hub registered a different device id or fingerprint than this device computed');
  }
  // Only a registration the hub accepted for THIS device replaces the stored code: a
  // failed or rate-limited POST leaves no orphan code (and keeps any earlier one).
  await d().kv.put(`pending:${c.userId}`, pending);
  if (ctx !== c) return;
  const reset = resetFrom(dir);
  c.dispatch(deviceVaultStatusChanged({ status: reset ? 'reset-scheduled' : 'pending-approval', reset, userCode: code, codeExpiresAt: new Date(pending.expiresAt).toISOString() }));
  startPolling();
}

/**
 * Draw a new pairing code. The old one is replaced only once the hub accepted the new
 * registration (which supersedes it there); a failed attempt keeps it.
 */
export async function requestNewDeviceCode(): Promise<void> {
  const c = ctx;
  if (!c?.identity) return;
  await c.dispatch(deviceVaultBusy(true));
  try {
    const dir = await d().api.fetchVaultDirectory();
    if (dir) await register(c, dir);
  } finally {
    c.dispatch(deviceVaultBusy(false));
  }
}

/**
 * The approval could not be verified with a live pairing code: discard this browser's
 * identity (its approved entry stays in the log for the user to revoke), keep the
 * pins (there are none yet), and register a fresh identity with a new code.
 */
export async function restartPairing(): Promise<void> {
  const c = ctx;
  if (!c) return;
  if (await loadPins(d().kv, c.userId)) throw new Error('This device already trusts this account; nothing to pair.');
  await forgetDeviceIdentity(d().kv, c.userId);
  await d().kv.delete(`pending:${c.userId}`);
  c.identity = null;
  c.revokedVerified = false;
  await refreshDeviceVault('pair-again');
}
/**
 * M2: this browser already pinned another account and the user has not accepted the
 * current one: show the warning instead of any automatic genesis / confirmation.
 */
async function refuseUnacknowledgedAccount(c: Ctx): Promise<boolean> {
  const others = await otherPinnedAccounts(d().kv, c.userId);
  if (others.length === 0) return false;
  stopPolling();
  c.dispatch(deviceVaultStatusChanged({ status: 'other-account', otherAccounts: others }));
  return true;
}

/** The user explicitly accepted the signed-in account as a separate account here. */
export async function acceptOtherAccount(): Promise<void> {
  const c = ctx;
  if (!c) return;
  await acknowledgeOtherAccount(d().kv, c.userId);
  await refreshDeviceVault('other-account-accepted');
}

/**
 * After a revocation VERIFIED in the signed log: discard this browser's (revoked)
 * identity, keep the pins, create a fresh identity and register it, so the user can
 * approve this browser again from another device.
 */
export async function requestNewApproval(): Promise<void> {
  const c = ctx;
  if (!c || !c.revokedVerified) throw new Error('This device is not verifiably revoked.');
  await forgetDeviceIdentity(d().kv, c.userId);
  await d().kv.delete(`pending:${c.userId}`);
  c.identity = null;
  c.revokedVerified = false;
  await refreshDeviceVault('re-enroll');
}

/** What the user types to start over on a vault that vanished without a recorded reset. */
export async function startOverPhraseFor(pins: DevicePins): Promise<string> {
  return `${(await accountFingerprint(pins.root_sign_pub)).split(' ')[0]} RESET`;
}

const normalizePhrase = (s: string) => String(s ?? '').trim().replace(/\s+/g, ' ').toUpperCase();

/**
 * The directory is gone: archive (never delete) this device's identity, pins and
 * observed reset, then start a new vault. Without a recorded verified reset whose due
 * time has passed, the user must type the confirmation phrase (`startOverPhraseFor`).
 * Refuses when the directory is back.
 */
export async function startOverAfterReset(typedPhrase = ''): Promise<void> {
  const c = ctx;
  if (!c) return;
  const kv = d().kv;
  const pins = await loadPins(kv, c.userId);
  if (pins) {
    if (await d().api.fetchVaultDirectory(deviceSignerContext() ?? undefined)) {
      throw new Error('The vault directory is back; nothing was changed. Retry instead.');
    }
    if (!observedResetElapsed(await loadObservedReset(kv, c.userId))) {
      const want = await startOverPhraseFor(pins);
      if (normalizePhrase(typedPhrase) !== normalizePhrase(want)) throw new Error(`Type "${want}" exactly to start a new vault.`);
    }
  }
  await archiveDeviceState(kv, c.userId);
  await kv.delete(`pending:${c.userId}`);
  c.identity = null;
  await refreshDeviceVault('start-over');
}

export async function requestVaultReset(): Promise<void> {
  if (!ctx) return;
  await d().api.postVaultReset(deviceSignerContext() ?? undefined);
  await refreshDeviceVault('reset-requested');
}

export async function cancelVaultReset(): Promise<void> {
  const signed = deviceSignerContext();
  if (!signed) throw new Error('This device cannot sign');
  await d().api.postVaultResetCancel(signed);
  await refreshDeviceVault('reset-cancelled');
}

export async function denyPendingDevice(deviceId: string): Promise<void> {
  const signed = deviceSignerContext();
  if (!signed) throw new Error('This device cannot sign');
  const { chain } = await fetchVerifiedChain();
  await d().api.postDenyDevice(deviceId, chain.version, signed);
  await refreshDeviceVault('denied');
}

// ── bridges ──────────────────────────────────────────────────────────────────

function bridgeDeps(chain: VerifiedChain): BridgeDeliveryDeps | null {
  const b = d().bridges;
  if (!b) return null;
  return { fetchTarget: b.fetchTarget, dispatch: b.dispatch, withKeyringBytes: (fn) => withKeyringBytes(fn, chain) };
}

/** Re-unseal every online bridge whose identity the chain approves. */
export async function unsealApprovedBridges(only?: readonly string[], opts: { automatic?: boolean } = {}): Promise<BridgeFanoutResult> {
  const b = d().bridges;
  if (!b) return { succeeded: [], failed: [] };
  const { chain } = await fetchVerifiedChain();
  const online = only ? [...only] : await b.listOnlineBridgeIds();
  if (opts.automatic && ctx?.staleHead) return pausedDelivery(online);
  const deps2 = bridgeDeps(chain)!;
  const targets = online.filter((id) => trustedBridgeById(chain, id));
  return deliverKeyringToBridges(targets, chain, deps2);
}

export const STALE_HEAD_PAUSE_MESSAGE = "Automatic key delivery is paused: this device's device log may be out of date (see the banner). Send the key manually or confirm the log head.";

/** M1: automatic delivery skipped; reported as failures so "Send key" is offered. */
function pausedDelivery(ids: readonly string[]): BridgeFanoutResult {
  return { succeeded: [], failed: ids.map((bridgeId) => ({ bridgeId, error: STALE_HEAD_PAUSE_MESSAGE })) };
}

// ── automatic bridge key delivery ───────────────────────────────────────────
//
// Owner decision: an approved browser that sees an approved bridge awaiting the key
// delivers it automatically, after the same checks as the manual path (bridge
// identity chain-approved; ephemeral key signed by that identity; chain_proof). To
// avoid several tabs / devices stampeding one bridge: random jitter, a re-check that
// the bridge is STILL awaiting the key just before sending, a per-bridge cooldown in
// this tab and a short cross-tab lease in localStorage. Failures are reported to the
// slice so Settings → Devices can offer "Send key" with the error.

const AUTO_UNSEAL_COOLDOWN_MS = 30_000;
const AUTO_UNSEAL_LEASE_MS = 20_000;
const lastAutoAttempt = new Map<string, number>();
let autoUnsealRunning: Promise<void> | null = null;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const jitter = (min: number, max: number) => min + Math.random() * (max - min);

function takeLease(bridgeId: string): boolean {
  try {
    const key = `heimdall:bridge-unseal-lease:${bridgeId}`;
    const now = Date.now();
    const held = Number(globalThis.localStorage?.getItem(key) || 0);
    if (held && now - held < AUTO_UNSEAL_LEASE_MS) return false;
    globalThis.localStorage?.setItem(key, String(now));
    return true;
  } catch {
    return true; // no storage: jitter + re-check still apply
  }
}

/** Deliver the keyring to approved bridges that report awaiting the key. Never throws. */
export function autoUnsealLockedBridges(candidateIds: readonly string[]): Promise<void> {
  if (autoUnsealRunning || candidateIds.length === 0 || !getKeyringSession()) return autoUnsealRunning ?? Promise.resolve();
  autoUnsealRunning = (async () => {
    try {
      const b = d().bridges;
      if (!b) return;
      if (ctx?.staleHead) {
        ctx.dispatch(bridgeKeyDeliveryReported(pausedDelivery(candidateIds)));
        return;
      }
      await sleep(jitter(400, 3000));
      const still = new Set(await b.listOnlineLockedBridgeIds());
      const now = Date.now();
      const targets = candidateIds.filter((id) => still.has(id) && now - (lastAutoAttempt.get(id) ?? 0) >= AUTO_UNSEAL_COOLDOWN_MS && takeLease(id));
      if (targets.length === 0) return;
      for (const id of targets) lastAutoAttempt.set(id, now);
      const result = await unsealApprovedBridges(targets, { automatic: true });
      ctx?.dispatch(bridgeKeyDeliveryReported(result));
    } catch (err) {
      console.warn('[vault] automatic bridge key delivery failed:', err);
    } finally {
      autoUnsealRunning = null;
    }
  })();
  return autoUnsealRunning;
}

/** Manual fallback ("Send key"): no cooldown, result reported to the slice. */
export async function sendKeyToBridge(bridgeId: string): Promise<BridgeFanoutResult> {
  const result = await unsealApprovedBridges([bridgeId]);
  ctx?.dispatch(bridgeKeyDeliveryReported(result));
  return result;
}

// ── hub retirement hints → signed revocation ─────────────────────────────────
//
// The hub retires a bridge identity (bridge revoked in settings, replaced by an
// attach, rolled-back enrollment) only as a HINT; it can neither revoke nor rotate.
// An approved browser with its keyring installed turns a hint into a real signed
// `revoke` (new epoch + wraps) — but only for an id the VERIFIED log trusts as a
// bridge (the verifier drops every other hint), at most one automatic revocation per
// AUTO_REVOKE_INTERVAL_MS per account on this browser (cross-tab, in localStorage).
// Each attempt is recorded (count + time) in the device store and an id is retried
// only after an exponential backoff; it counts as handled only once the VERIFIED log
// no longer trusts it (revoked), never merely because a revoke was attempted. So junk
// hints cause nothing, a failed revoke is retried, and a hostile hub cannot drive
// unbounded epoch growth (a successful revoke ends the id's hints for good).

export const AUTO_REVOKE_INTERVAL_MS = 10 * 60 * 1000;
export const HINT_RETRY_MAX_MS = 24 * 60 * 60 * 1000;
let hintTimer: ReturnType<typeof setTimeout> | null = null;
let hintRunning = false;

export interface HintAttempt { attempts: number; lastAt: number }
export type HintAttempts = Record<string, HintAttempt>;

const hintAttemptsKey = (userId: string) => `retired-hint-attempts:${userId}`;

async function loadHintAttempts(userId: string): Promise<HintAttempts> {
  const v = await d().kv.get(hintAttemptsKey(userId));
  const out: HintAttempts = {};
  if (v && typeof v === 'object') {
    for (const [id, a] of Object.entries(v as Record<string, HintAttempt>)) {
      if (a && Number.isSafeInteger(a.attempts) && Number.isFinite(a.lastAt)) out[id] = { attempts: a.attempts, lastAt: a.lastAt };
    }
  }
  return out;
}

/** Wait before retrying an id after `attempts` failed/unconfirmed revokes. */
export function hintBackoffMs(attempts: number): number {
  return Math.min(AUTO_REVOKE_INTERVAL_MS * 2 ** Math.max(0, attempts - 1), HINT_RETRY_MAX_MS);
}

/**
 * Pure: drop attempt records of ids the verified log no longer trusts (handled), and
 * pick the first hinted id that was never attempted or whose backoff has elapsed.
 */
export function planHintRevocation(retiredHints: readonly string[], trusted: { has(id: string): boolean }, attempts: HintAttempts, now: number): { target: string | null; attempts: HintAttempts } {
  const kept: HintAttempts = {};
  for (const [id, a] of Object.entries(attempts)) if (trusted.has(id)) kept[id] = a;
  const target = retiredHints.find((id) => {
    const a = kept[id];
    return !a || now - a.lastAt >= hintBackoffMs(a.attempts);
  }) ?? null;
  return { target, attempts: kept };
}

function takeAutoRevokeSlot(userId: string, now = Date.now()): boolean {
  const key = `heimdall:vault-auto-revoke:${userId}`;
  try {
    const last = Number(globalThis.localStorage?.getItem(key) || 0);
    if (last && now - last < AUTO_REVOKE_INTERVAL_MS) return false;
    globalThis.localStorage?.setItem(key, String(now));
    return true;
  } catch {
    // No storage: fall back to this tab's own clock.
    if (lastAutoRevokeAt && now - lastAutoRevokeAt < AUTO_REVOKE_INTERVAL_MS) return false;
    lastAutoRevokeAt = now;
    return true;
  }
}
let lastAutoRevokeAt = 0;

function scheduleHintRevocation(chain: VerifiedChain): void {
  if (hintTimer || hintRunning) return;
  const me = ctx?.identity ? chain.trusted.get(ctx.identity.deviceId) : undefined;
  if (!me || !kindPolicy(me.kind).canApprove) return;
  hintTimer = setTimeout(() => {
    hintTimer = null;
    if (hintRunning) return;
    hintRunning = true;
    revokeRetiredHint()
      .catch((err) => console.warn('[vault] automatic revocation of a retired bridge identity failed:', err))
      .finally(() => { hintRunning = false; });
  }, jitter(1000, 5000));
}

/** Revoke (signed) ONE hub-retired bridge identity the verified log still trusts. */
export async function revokeRetiredHint(): Promise<{ revoked: string | null }> {
  const c = ctx;
  if (!c?.identity) return { revoked: null };
  const { chain } = await fetchVerifiedChain();
  if (ctx !== c || c.staleHead) return { revoked: null }; // M1: no automatic revokes on a stale head
  const now = Date.now();
  const plan = planHintRevocation(chain.retiredHints, chain.trusted, await loadHintAttempts(c.userId), now);
  const save = () => d().kv.put(hintAttemptsKey(c.userId), plan.attempts);
  if (!plan.target || !takeAutoRevokeSlot(c.userId, now)) {
    await save();
    return { revoked: null };
  }
  const target = plan.target;
  plan.attempts[target] = { attempts: (plan.attempts[target]?.attempts ?? 0) + 1, lastAt: now };
  await save();
  const { outcome } = await revokeDevice(target);
  return { revoked: outcome.kind === 'revoked' ? target : null };
}

/** Explicit user rotation: a signed `rotate` to a new epoch, then re-unseal every approved online bridge. */
export async function rotateKeys(): Promise<{ outcome: RotateOutcome; bridges: BridgeFanoutResult }> {
  const c = ctx;
  if (!c?.identity) throw new Error('This device cannot sign');
  let bridges: BridgeFanoutResult = { succeeded: [], failed: [] };
  const outcome = await rotateWithRetry(c.identity, {
    fetchChain: async () => {
      const { chain } = await fetchVerifiedChain();
      await ensureKeyringCurrent(chain);
      return chain;
    },
    withKeyringBytes: (chain, fn) => withKeyringBytes(fn, chain),
    post: (body) => d().api.postRotateDirectory(body, deviceSignerContext()!),
    isConflict: (err) => isStatus(err, 409),
    afterRotation: async () => {
      await refreshDeviceVault('rotated');
      bridges = await unsealApprovedBridges();
      ctx?.dispatch(bridgeKeyDeliveryReported(bridges));
      await refreshConnectorEpochs();
    },
  });
  return { outcome, bridges };
}

/** Revoke a device (never this one): new epoch, wraps to the rest, re-unseal bridges. */
export async function revokeDevice(targetId: string): Promise<{ outcome: RevokeOutcome; bridges: BridgeFanoutResult }> {
  const c = ctx;
  if (!c?.identity) throw new Error('This device cannot sign');
  if (targetId === c.identity.deviceId) throw new Error('This device cannot revoke itself');
  const identity = c.identity;
  let bridges: BridgeFanoutResult = { succeeded: [], failed: [] };
  const outcome = await revokeWithRetry(identity, targetId, {
    fetchChain: async () => {
      const { chain } = await fetchVerifiedChain();
      await ensureKeyringCurrent(chain);
      return chain;
    },
    withKeyringBytes: (chain, fn) => withKeyringBytes(fn, chain),
    post: (id, body) => d().api.postRevokeDevice(id, body, deviceSignerContext()!),
    isConflict: (err) => isStatus(err, 409) && (err as ApiError).code !== 'self_revoke',
    afterRotation: async () => {
      await refreshDeviceVault('rotated');
      bridges = await unsealApprovedBridges();
      ctx?.dispatch(bridgeKeyDeliveryReported(bridges));
      await refreshConnectorEpochs();
    },
  });
  if (outcome.kind === 'already-revoked') await refreshDeviceVault('already-revoked');
  return { outcome, bridges };
}

/** Delivery follows the signed directory commit. A gap is fail-closed in the
 * hosted reader; retrying this operation needs no connector reconnect. */
export async function refreshConnectorEpochs(): Promise<void> {
  const c = ctx;
  const transport = d().connectors;
  if (!transport || !c?.identity) return;
  try {
    if (c.staleHead) throw new Error('Fresh directory required');
    let rows: ConnectorRecipient[];
    try { rows = await transport.list(); }
    catch (err) { if (isStatus(err, 404)) return; throw err; }
    if (!rows.length) { c.dispatch(mcpKeyDeliveryReported('')); return; }
    const { chain } = await fetchVerifiedChain();
    if (ctx !== c || c.staleHead) return;
    await ensureKeyringCurrent(chain);
    await withKeyringBytes(async (bytes) => {
      const deliveries = await buildConnectorEpochWraps(c.identity!, chain, rows, bytes, transport.resource());
      for (const body of deliveries) {
        if (ctx !== c || !getKeyringSession()) throw new Error('Device session ended');
        await transport.deliver(body);
      }
    }, chain);
    if (ctx === c) c.dispatch(mcpKeyDeliveryReported(''));
  } catch {
    // The rotation may already be committed. Preserve that outcome and surface
    // a repair action instead of implying the directory operation rolled back.
    if (ctx === c) c.dispatch(mcpKeyDeliveryReported('Some AI connections need updated decryption keys. Retry delivery from this approved device.'));
  }
}

/** Make sure the installed keyring matches `chain` (another device may have rotated). */
async function ensureKeyringCurrent(chain: VerifiedChain): Promise<void> {
  const c = ctx;
  if (!c?.identity) throw new Error('Device vault not ready');
  const s = getKeyringSession();
  if (s && s.keyring.currentEpoch === chain.currentEpoch && s.identity.deviceId === c.identity.deviceId) return;
  const self = await d().api.fetchVaultSelf(deviceSignerContext()!);
  if (self.status !== 'approved' || !self.wrap) throw new Error('This device is no longer approved');
  const keyring = await installKeyringFromWrap(c.identity, self.wrap, chain);
  c.dispatch(keyringInstalled({ currentEpoch: keyring.currentEpoch }));
}

export async function verifiedChainForApproval(): Promise<VerifiedChain> {
  const { chain } = await fetchVerifiedChain();
  await ensureKeyringCurrent(chain);
  return chain;
}

export function deviceVaultUserId(): string {
  return ctx?.userId ?? '';
}

// ── recovery key (plan P4) ───────────────────────────────────────────────────

/**
 * Create a recovery key from `entropy` (the 12 words the user wrote down and then
 * re-entered): a `recovery` credential approved by this device, wrapped to like any
 * device, its private keys sealed under the words. Returns the new credential id.
 */
export async function createRecoveryKey(entropy: Uint8Array): Promise<string> {
  const c = ctx;
  if (!c?.identity) throw new Error('This device cannot sign');
  const identity = c.identity;
  const chain = await verifiedChainForApproval();
  const { body, deviceId } = await withKeyringBytes((bytes) => buildRecoveryKey(identity, chain, bytes, entropy), chain);
  await d().api.postRecoveryKey(body, deviceSignerContext()!);
  await refreshDeviceVault('recovery-created');
  return deviceId;
}

/**
 * Replace the recovery key: create the new one FIRST (so the account is never left
 * without one), then revoke every older recovery credential (each a signed revoke
 * with a new epoch; the new recovery key receives the new wraps).
 */
export async function replaceRecoveryKey(entropy: Uint8Array): Promise<string> {
  const before = trustedRecoveryKeys((await fetchVerifiedChain()).chain).map((r) => r.device_id);
  const created = await createRecoveryKey(entropy);
  for (const id of before) {
    if (id === created) continue;
    const { outcome } = await revokeDevice(id);
    if (outcome.kind !== 'revoked' && outcome.kind !== 'already-revoked') throw new Error('The new recovery key was created, but the old one could not be revoked; revoke it in the device list');
  }
  return created;
}

export interface RecoveryRestoreResult {
  /** Approved devices (browsers, bridges) other than this browser: candidates to revoke if lost. */
  otherDevices: { deviceId: string; kind: string; label: string }[];
}

/**
 * Restore on a NEW browser (waiting to be paired) with the 12 recovery words: verify
 * the directory log from genesis, open the recovery credential the words belong to
 * (bound to this account's root and to its own approval op), unwrap the keyring with
 * it, and approve THIS browser as the recovery credential (a signed log op). The
 * approval carries a pair_mac under this browser's own pairing code, so the normal
 * install path then verifies it and pins the root. Fails closed: wrong words, another
 * account's words, a tampered blob or a revoked recovery key install nothing.
 */
export async function restoreWithRecoveryKey(words: string[]): Promise<RecoveryRestoreResult> {
  const c = ctx;
  if (!c?.identity) throw new RecoveryKeyError('This browser has no device identity yet');
  const identity = c.identity;
  const kv = d().kv;
  const self = await d().api.fetchVaultSelf(deviceSignerContext()!);
  if (self.status !== 'pending') throw new RecoveryKeyError('Only a browser waiting to be approved can be restored with a recovery key');
  const pending = await loadPendingCode(c);
  if (!pending || Date.now() > pending.expiresAt) throw new RecoveryKeyError('This browser\'s pairing request expired; pair again, then use the recovery key');
  const dir = await d().api.fetchVaultDirectory(deviceSignerContext() ?? undefined);
  if (!dir) throw new RecoveryKeyError('The vault directory is gone; a recovery key cannot restore it');
  const chain = await verifyDirectory(dir, c.userId, await loadPins(kv, c.userId));
  const cred = await openRecoveryKey(words, chain);
  const credSigner: vaultApi.VaultSignerContext = { userId: c.userId, signer: { deviceId: cred.deviceId, signPrivateKey: cred.signPrivateKey } };
  const credSelf = await d().api.fetchVaultSelf(credSigner);
  if (credSelf.status !== 'approved' || !credSelf.wrap) throw new RecoveryKeyError('The recovery key is not approved any more');
  const parsed = await openVerifiedWrap(credSelf.wrap, { userId: c.userId, recipientDeviceId: cred.deviceId, recipientEcdhPrivate: cred.ecdhPrivateKey, chain });
  let bytes: Uint8Array | null = null;
  try {
    bytes = serializeKeyringBytes(parsed);
    const label = d().label(identity);
    const keys = await derivePairKeys(pending.code, pendingPairContext(c, pending));
    const me = {
      device_id: identity.deviceId, sign_public_key: identity.signPub, ecdh_public_key: identity.ecdhPub,
      sign_alg: identity.signAlg, wrap_alg: identity.wrapAlg, label, fingerprint: identity.fingerprint, register_statement: '',
    };
    const body = await buildBrowserApproval(asApproverIdentity(cred), chain, me, keys, label, bytes);
    await d().api.postApproveBrowser(identity.deviceId, body, credSigner);
  } finally {
    bytes?.fill(0);
    for (const e of parsed.entries) e.key.fill(0);
  }
  await refreshDeviceVault('recovery-restore');
  const otherDevices = [...chain.trusted.values()]
    .filter((t) => t.kind !== 'recovery' && t.device_id !== identity.deviceId)
    .map((t) => ({ deviceId: t.device_id, kind: t.kind, label: t.label || t.device_id }));
  return { otherDevices };
}
