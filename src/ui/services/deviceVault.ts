// Device vault orchestration (docs/plans/passwordless-vault.md §2 P3).
//
// Boots this browser's device identity for the signed-in user and drives it to one
// of the deviceVaultSlice states. Keys are installed ONLY after the directory chain
// verified against this device's pins and its wrap opened with a matching
// epoch_commit; any failure leaves no keys installed (fail closed).
//
// Never shows or sends the pending code anywhere but the waiting screen.

import * as vaultApi from '../api/endpoints/vaultDevices';
import { ApiError } from '../api/cookieFetch';
import {
  accountFingerprint,
  acknowledgeOtherAccount,
  advancePins,
  archiveDeviceState,
  createDeviceIdentity,
  forgetDeviceIdentity,
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
import { buildGenesis, buildRegistration, revokeWithRetry, rotateWithRetry, type RevokeOutcome, type RotateOutcome } from '../utils/vaultDeviceFlows';
import { kindPolicy } from '../utils/vaultStatements';
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
} from '../store/deviceVaultSlice';
import { keyringCleared, keyringInstalled } from '../store/vaultSlice';

type Dispatch = (action: unknown) => unknown;
type VaultApi = typeof vaultApi;

export interface DeviceVaultDeps {
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
  /** Approved but awaiting the account-fingerprint confirmation (snapshot + token). */
  pendingInstall: { chain: VerifiedChain; wrap: unknown; fingerprint: string; token: number } | null;
  /** The signed log revoked this device (verified): it may re-enroll with a new identity. */
  revokedVerified: boolean;
  pollTimer: ReturnType<typeof setInterval> | null;
  seq: number;
  lastPendingIds: Set<string>;
}

let deps: DeviceVaultDeps | null = null;
let ctx: Ctx | null = null;

/** Tests inject a memory store and a fake API; production uses IndexedDB and HTTP. */
export function configureDeviceVault(next: Partial<DeviceVaultDeps>): void {
  deps = { ...defaultDeps(), ...next } as DeviceVaultDeps;
}

function defaultDeps(): DeviceVaultDeps {
  return {
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
  ctx.dispatch(deviceVaultDirectoryVerified({
    accountFingerprint: await accountFingerprint(chain.rootSignPub),
    currentEpoch: chain.currentEpoch,
    directoryVersion: chain.version,
    reset: resetFrom(dir),
    pendingDevices: pendingFrom(chain),
  }));
  // Hub retirement hints for trusted bridges: an approved device with its keyring
  // installed signs their real revoke (rate-limited, see scheduleHintRevocation).
  if (chain.retiredHints.length > 0 && getKeyringSession()) scheduleHintRevocation(chain);
}

/** Start (or restart) the device vault for `userId`. Idempotent for the same user while running. */
export async function bootDeviceVault(userId: string, dispatch: Dispatch): Promise<void> {
  if (ctx && ctx.userId === userId && ctx.identity) return refreshDeviceVault('boot');
  stopPolling();
  if (ctx && ctx.userId !== userId) purgeKeys(dispatch);
  ctx = { userId, dispatch, identity: null, pendingInstall: null, revokedVerified: false, pollTimer: null, seq: 0, lastPendingIds: new Set() };
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
      const code = await loadPendingCode(c);
      dispatch(deviceVaultStatusChanged({ status: reset ? 'reset-scheduled' : 'pending-approval', reset, userCode: code?.userCode ?? '', codeExpiresAt: code?.codeExpiresAt ?? '' }));
      startPolling();
      return;
    }
    if (self.status !== 'approved' || !self.wrap) throw new Error(`unexpected device status ${self.status}`);

    // Approved: verify the chain against the pins BEFORE touching the wrap.
    const pins = await loadPins(kv, c.userId);
    const chain = await verifyDirectory(dir, c.userId, pins);
    if (stale()) return;
    await publishChain(chain, dir);
    if (!chain.trusted.has(identity.deviceId)) throw new Error('This device is not approved by a verified chain');
    await kv.delete(`pending:${c.userId}`);
    stopPolling();
    noticePending(c, chain);

    // The device that created the vault IS the root: its own key needs no confirmation.
    if (!pins && chain.rootDeviceId === identity.deviceId && chain.rootSignPub === identity.signPub) {
      await advancePins(kv, c.userId, pinsFromChain(chain));
      const keyring = await installKeyringFromWrap(identity, self.wrap, chain);
      dispatch(keyringInstalled({ currentEpoch: keyring.currentEpoch }));
      dispatch(deviceVaultStatusChanged({ status: 'ready', currentEpoch: chain.currentEpoch, directoryVersion: chain.version }));
      return;
    }
    if (!pins) {
      // First sight of the account on this device: the user confirms the account
      // fingerprint before any key is installed (threat model: hub-injected root).
      // Never automatically when this browser already pinned ANOTHER account (M2).
      if (await refuseUnacknowledgedAccount(c)) return;
      const fingerprint = await accountFingerprint(chain.rootSignPub);
      if (stale()) return;
      // A refresh with the same root keeps the token the user is typing against; a
      // different root is a new snapshot (and invalidates any in-flight confirmation).
      const token = c.pendingInstall && c.pendingInstall.fingerprint === fingerprint ? c.pendingInstall.token : ++confirmTokens;
      c.pendingInstall = { chain, wrap: self.wrap, fingerprint, token };
      dispatch(deviceVaultStatusChanged({ status: 'confirm-account', reset: resetFrom(dir), confirmFingerprint: fingerprint, confirmToken: token }));
      return;
    }
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
    dispatch(deviceVaultFailed({ code: 'verification_failed', message: message(err) }));
  }
}

function noticePending(c: Ctx, chain: VerifiedChain): void {
  c.lastPendingIds = new Set(chain.pending.map((p) => p.device_id));
}

/** Pending devices that appeared since the last refresh (for the approval toast). */
export function takeNewPendingDevices(chain: VerifiedChain): string[] {
  if (!ctx) return [];
  const fresh = chain.pending.map((p) => p.device_id).filter((id) => !ctx!.lastPendingIds.has(id));
  noticePending(ctx, chain);
  return fresh;
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

async function loadPendingCode(c: Ctx): Promise<{ userCode: string; codeExpiresAt: string } | null> {
  const v = await d().kv.get(`pending:${c.userId}`) as { userCode?: string; codeExpiresAt?: string } | undefined;
  if (!v?.userCode) return null;
  const exp = Date.parse(String(v.codeExpiresAt ?? ''));
  if (Number.isFinite(exp) && exp <= Date.now()) return null;
  return { userCode: String(v.userCode), codeExpiresAt: String(v.codeExpiresAt ?? '') };
}

async function register(c: Ctx, dir: VaultDirectory): Promise<void> {
  const identity = c.identity!;
  const { statement, signature } = await buildRegistration(identity, d().label(identity));
  const res = await d().api.postVaultRegister(statement, signature);
  if (res.device_id !== identity.deviceId || res.fingerprint !== identity.fingerprint) {
    throw new Error('The hub registered a different device id or fingerprint than this device computed');
  }
  if (res.user_code) await d().kv.put(`pending:${c.userId}`, { userCode: res.user_code, codeExpiresAt: res.code_expires_at ?? '' });
  const code = res.user_code ? { userCode: res.user_code, codeExpiresAt: res.code_expires_at ?? '' } : await loadPendingCode(c);
  const reset = resetFrom(dir);
  c.dispatch(deviceVaultStatusChanged({ status: reset ? 'reset-scheduled' : 'pending-approval', reset, userCode: code?.userCode ?? '', codeExpiresAt: code?.codeExpiresAt ?? '' }));
  startPolling();
}

/** Ask the hub for a fresh code (only issued when the old one expired). */
export async function requestNewDeviceCode(): Promise<void> {
  const c = ctx;
  if (!c?.identity) return;
  await c.dispatch(deviceVaultBusy(true));
  try {
    await d().kv.delete(`pending:${c.userId}`);
    const dir = await d().api.fetchVaultDirectory();
    if (dir) await register(c, dir);
  } finally {
    c.dispatch(deviceVaultBusy(false));
  }
}

let confirmTokens = 0;

/** Digits a user must type to confirm an account fingerprint: its first two groups. */
export const CONFIRM_FINGERPRINT_GROUPS = 2;

export function fingerprintPrefix(fingerprint: string): string {
  return fingerprint.split(' ').slice(0, CONFIRM_FINGERPRINT_GROUPS).join('').toLowerCase();
}

/**
 * The user typed the first groups of the account fingerprint shown in Settings on a
 * device they already use. Binds to the EXACT snapshot rendered (`renderedFingerprint`,
 * `token`): if the pending install changed since, nothing is installed.
 */
export async function confirmAccountFingerprint(typed: string, renderedFingerprint: string, token: number): Promise<void> {
  const c = ctx;
  if (!c?.identity || !c.pendingInstall) throw new Error('Nothing is waiting for confirmation; reload.');
  const p = c.pendingInstall;
  if (p.token !== token || p.fingerprint !== renderedFingerprint || await accountFingerprint(p.chain.rootSignPub) !== renderedFingerprint) {
    throw new Error('The account shown changed while you were confirming. Compare the fingerprint again.');
  }
  const want = fingerprintPrefix(renderedFingerprint);
  if (String(typed ?? '').replace(/[\s-]+/g, '').toLowerCase() !== want) {
    throw new Error('That does not match. Type the first groups exactly as Settings → Devices shows them on your other device.');
  }
  const { chain, wrap } = p;
  c.pendingInstall = null;
  try {
    await advancePins(d().kv, c.userId, pinsFromChain(chain));
    const keyring = await installKeyringFromWrap(c.identity, wrap, chain);
    c.dispatch(keyringInstalled({ currentEpoch: keyring.currentEpoch }));
    c.dispatch(deviceVaultStatusChanged({ status: 'ready', currentEpoch: chain.currentEpoch, directoryVersion: chain.version }));
  } catch (err) {
    purgeKeys(c.dispatch);
    c.dispatch(deviceVaultFailed({ code: 'verification_failed', message: message(err) }));
  }
}

/** The fingerprints differ: refuse the account, install nothing. */
export function rejectAccountFingerprint(): void {
  const c = ctx;
  if (!c) return;
  c.pendingInstall = null;
  purgeKeys(c.dispatch);
  c.dispatch(deviceVaultFailed({
    code: 'account_mismatch',
    message: 'The account fingerprint did not match. No keys were installed on this device. Check that you are signed in to the right account; if the vault was set up by someone else, request a reset.',
  }));
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
export async function unsealApprovedBridges(only?: readonly string[]): Promise<BridgeFanoutResult> {
  const b = d().bridges;
  if (!b) return { succeeded: [], failed: [] };
  const { chain } = await fetchVerifiedChain();
  const deps2 = bridgeDeps(chain)!;
  const online = only ? [...only] : await b.listOnlineBridgeIds();
  const targets = online.filter((id) => trustedBridgeById(chain, id));
  return deliverKeyringToBridges(targets, chain, deps2);
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
      await sleep(jitter(400, 3000));
      const still = new Set(await b.listOnlineLockedBridgeIds());
      const now = Date.now();
      const targets = candidateIds.filter((id) => still.has(id) && now - (lastAutoAttempt.get(id) ?? 0) >= AUTO_UNSEAL_COOLDOWN_MS && takeLease(id));
      if (targets.length === 0) return;
      for (const id of targets) lastAutoAttempt.set(id, now);
      const result = await unsealApprovedBridges(targets);
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
    },
  });
  if (outcome.kind === 'already-revoked') await refreshDeviceVault('already-revoked');
  return { outcome, bridges };
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
