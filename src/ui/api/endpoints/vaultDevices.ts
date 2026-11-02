// Passwordless vault device-directory API (docs/plans/passwordless-vault.md §2 P2/P3).
//
// EVERY call to the vault directory / device endpoints lives here, so hub API changes
// land in one file. Mutations are signed with the device key (vaultRequestSigner):
// the body string signed is exactly the body string sent.
//
// Responses are untrusted input: callers verify everything with
// vaultDirectoryVerify / vaultKeyringWrap before acting on it.

import { ApiError, apiUrl, errorFromResponse } from '../cookieFetch';
import { pairHubOrigin } from '../../utils/vaultPairing';
import { signedRequestHeaders, type RequestSigner } from '../../utils/vaultRequestSigner';
import type { VaultDirectory } from '../../utils/vaultDirectoryVerify';
import type { SignedKeyringWrap } from '../../utils/vaultKeyringWrap';

export interface VaultSignerContext {
  userId: string;
  signer: RequestSigner;
}

const API = '/api/v1';

/**
 * The hub origin a NEW browser binds into its own pairing stretch (plan §1 "Pairing"):
 * the origin of the API base this page talks to. It is declared to the hub next to the
 * pair_salt (pair_hub_origin); an approver derives with each candidate's DECLARED
 * origin, never with its own page origin. Throws outside an http(s) page.
 */
export function pairingHubOrigin(): string {
  const here = (globalThis as { location?: { href?: string } }).location?.href;
  if (!here) throw new Error('No page address to bind the pairing to');
  return pairHubOrigin(new URL(apiUrl(`${API}/`), here).href);
}

/** fetch is injectable for hermetic tests. */
let fetchImpl: typeof fetch = (input, init) => fetch(input, init);
export function setVaultDevicesFetch(f: typeof fetch | null): void {
  fetchImpl = f ?? ((input, init) => fetch(input, init));
}

async function vaultRequest(method: string, path: string, opts: { body?: unknown; signed?: VaultSignerContext } = {}): Promise<any> {
  const fullPath = `${API}${path}`;
  const body = opts.body === undefined ? '' : JSON.stringify(opts.body);
  const headers: Record<string, string> = {};
  if (body) headers['Content-Type'] = 'application/json';
  if (opts.signed) Object.assign(headers, await signedRequestHeaders(opts.signed.signer, opts.signed.userId, method, fullPath, body));
  const res = await fetchImpl(apiUrl(fullPath), { method, headers, body: body || undefined, credentials: 'include' });
  if (!res.ok) throw await errorFromResponse(res);
  const text = await res.text();
  if (!text) return {};
  const parsed = JSON.parse(text);
  return parsed?.data !== undefined ? parsed.data : parsed;
}

export function isApiStatus(err: unknown, status: number): boolean {
  return err instanceof ApiError && err.status === status;
}

// ── reads ────────────────────────────────────────────────────────────────────

/** The account directory, or null when no vault exists yet (404). */
export async function fetchVaultDirectory(signed?: VaultSignerContext): Promise<VaultDirectory | null> {
  try {
    const data = await vaultRequest('GET', '/vault/directory', { signed });
    if (data && data.configured === false) return null;
    return data as VaultDirectory;
  } catch (err) {
    if (isApiStatus(err, 404)) return null;
    throw err;
  }
}

export interface VaultSelfStatus {
  device_id: string;
  status: 'pending' | 'approved' | 'revoked' | string;
  directory_version: number;
  wrap?: SignedKeyringWrap | null;
  /** The approver's pair_mac over this device's approval (hub-blind pairing). */
  pair_mac?: string;
}

export async function fetchVaultSelf(signed: VaultSignerContext): Promise<VaultSelfStatus> {
  return vaultRequest('GET', '/vault/devices/self', { signed });
}

// ── enrollment of this device ───────────────────────────────────────────────

export interface GenesisBody {
  /** Log seq 1: self-signed, introduces epoch 1. */
  genesis_statement: string;
  signature: unknown;
  wrap: SignedKeyringWrap;
}

/** Browser session (cookie) auth only; self-signed statements in the body. */
export async function postVaultGenesis(body: GenesisBody): Promise<{ directory_version: number; current_epoch: number }> {
  return vaultRequest('POST', '/vault/directory/genesis', { body });
}

export interface RegisterResult {
  device_id: string;
  fingerprint: string;
  status: string;
  /** How long the pending request lives (the hub never knows the pairing code). */
  code_expires_at?: string;
}

/**
 * Register this device as pending. `pairLookup` / `pairKeyMac` are derived from the
 * secret pairing code this device shows (the code never leaves the device);
 * `pairSalt` is the public salt of the pairing stretch and `pairHubOrigin` the
 * canonical hub origin this device bound into it (declared for the approver).
 */
export async function postVaultRegister(statement: string, proofSignature: unknown, pairLookup: string, pairKeyMac: string, pairSalt: string, pairHubOrigin: string): Promise<RegisterResult> {
  return vaultRequest('POST', '/vault/devices/register', { body: { statement, proof_signature: proofSignature, pair_lookup: pairLookup, pair_key_mac: pairKeyMac, pair_salt: pairSalt, pair_hub_origin: pairHubOrigin } });
}

// ── approval surface (/device/add) ──────────────────────────────────────────

export interface BrowserCodeInfo {
  kind: 'browser';
  device_id: string;
  device_kind: string;
  fingerprint: string;
  label: string;
  sign_public_key: string;
  ecdh_public_key: string;
  sign_alg: string;
  wrap_alg: string;
  created_at?: string;
  code_expires_at?: string;
  /** The self-signed register statement the device made; pair_key_mac covers it. */
  register_statement: string;
  pair_key_mac: string;
  pair_salt: string;
  pair_hub_origin?: string;
}

/** An approver-owned, non-revoked, non-pending bridge a bridge grant may reuse (most recently seen first). */
export interface ReusableBridge {
  bridge_id: string;
  label: string;
  machine_hostname: string;
  status: 'online' | 'offline' | string;
  /** RFC 3339. */
  last_seen: string;
}

export interface BridgeCodeInfo {
  kind: 'bridge';
  /**
   * The enrolling bridge's untrusted hint at the identity it used before. The hub
   * returns it only when it names an entry of `reusable_bridges`, else ''.
   */
  previous_bridge_id?: string;
  /** Bridges this approval may reuse instead of registering a new one; [] when none. */
  reusable_bridges?: ReusableBridge[];
  device_label?: string;
  os?: string;
  client?: string;
  bridge_identity_public_key: string;
  bridge_identity_fingerprint?: string;
  is_bridge_enrollment?: boolean;
  bridge_public_key?: string;
  bridge_key_fingerprint?: string;
  hub_observed?: Record<string, unknown>;
  host_asserted?: Record<string, unknown>;
  /** MAC over identity|ecdh|code_challenge under the bridge's pairing code. */
  pair_key_mac: string;
  code_challenge: string;
  pair_salt: string;
  pair_hub_origin?: string;
  [k: string]: unknown;
}

export type DeviceCodeInfo = BrowserCodeInfo | BridgeCodeInfo;

export interface PairCandidate {
  kind: 'browser' | 'bridge';
  pair_salt: string;
  /** The canonical hub origin the NEW device declares it bound into its stretch. */
  pair_hub_origin: string;
}

export interface PairCandidateList {
  candidates: PairCandidate[];
  /** Hub-configured aliases (besides this page's own API origin) a declared origin may name. */
  pairingHubOrigins: string[];
}

/**
 * Public salts and declared hub origins of the requests this user could approve (own
 * pending browsers, then pending bridges): the lookup is derived from the typed code,
 * a request's salt and the hub origin that request declared.
 */
export async function fetchPairCandidates(): Promise<PairCandidateList> {
  const res = await vaultRequest('POST', '/device/pair-salts', { body: {} });
  return {
    candidates: Array.isArray(res?.candidates) ? res.candidates : [],
    pairingHubOrigins: Array.isArray(res?.pairing_hub_origins) ? res.pairing_hub_origins.filter((o: unknown) => typeof o === 'string') : [],
  };
}

/**
 * Resolve a pending device by the lookups the APPROVER derived from the typed code,
 * one per candidate pair_salt (at most 8); the answer's pair_salt names the match.
 */
export async function verifyPairLookups(pairLookups: string[]): Promise<DeviceCodeInfo> {
  return vaultRequest('POST', '/device/verify', { body: { pair_lookups: pairLookups } });
}

export interface BrowserApprovalBody {
  pair_lookup: string;
  /** HMAC under the pairing code over (approval, root, head): the new device verifies it. */
  pair_mac: string;
  expected_version: number;
  statement: string;
  signature: unknown;
  wrap: SignedKeyringWrap;
}

export async function postApproveBrowser(deviceId: string, body: BrowserApprovalBody, signed: VaultSignerContext): Promise<{ directory_version: number }> {
  return vaultRequest('POST', `/vault/devices/${encodeURIComponent(deviceId)}/approve`, { body, signed });
}

/** A recovery credential: its signed approve op, keyring wrap and sealed recovery blob. */
export interface RecoveryKeyBody {
  expected_version: number;
  statement: string;
  signature: unknown;
  wrap: SignedKeyringWrap;
  recovery_blob: string;
}

export async function postRecoveryKey(body: RecoveryKeyBody, signed: VaultSignerContext): Promise<{ directory_version: number; device_id: string }> {
  return vaultRequest('POST', '/vault/devices/recovery', { body, signed });
}

export interface BridgeApprovalBody {
  pair_lookup: string;
  approve: boolean;
  vault_approval?: { expected_version: number; statement: string; signature: unknown };
  /** Reuse this existing bridge identity. Mutually exclusive with `new_bridge_label`. */
  target_bridge_id?: string;
  new_bridge_label?: string;
  /**
   * New bridge only: retire this bridge of yours in the same hub transaction that
   * registers the new one (a full plan's "register new and sunset one"). If the
   * approval is refused or rolled back, it keeps working. Never sent with
   * `target_bridge_id`.
   */
  sunset_bridge_id?: string;
}

/** Bridge approvals go through the device-auth flow with the signed vault approval attached. */
export async function postApproveBridge(body: BridgeApprovalBody): Promise<any> {
  return vaultRequest('POST', '/device/approve', { body });
}

export async function postDenyDevice(deviceId: string, expectedVersion: number, signed: VaultSignerContext): Promise<any> {
  return vaultRequest('POST', `/vault/devices/${encodeURIComponent(deviceId)}/deny`, { body: { expected_version: expectedVersion }, signed });
}

// ── revoke / rotation ───────────────────────────────────────────────────────

export interface RevokeBody {
  expected_version: number;
  /** One `revoke` log op: names the target and introduces epoch current+1. */
  revoke_statement: string;
  signature: unknown;
  wraps: SignedKeyringWrap[];
}

export async function postRevokeDevice(deviceId: string, body: RevokeBody, signed: VaultSignerContext): Promise<{ directory_version: number; bridge_credentials_revoked?: boolean }> {
  return vaultRequest('POST', `/vault/devices/${encodeURIComponent(deviceId)}/revoke`, { body, signed });
}

export interface RotateBody {
  expected_version: number;
  /** One `rotate` log op (no subject), introducing epoch current+1. */
  statement: string;
  signature: unknown;
  wraps: SignedKeyringWrap[];
}

/** Advance to epoch current+1 without a revocation (explicit user rotation). */
export async function postRotateDirectory(body: RotateBody, signed: VaultSignerContext): Promise<{ directory_version: number }> {
  return vaultRequest('POST', '/vault/directory/rotate', { body, signed });
}

// ── reset (72 h delayed) ────────────────────────────────────────────────────

/** Request a vault reset from a fresh login. Signed by this (pending) device when it has a key. */
export async function postVaultReset(signed?: VaultSignerContext): Promise<any> {
  return vaultRequest('POST', '/vault/directory/reset', { body: {}, signed });
}

/** Cancel a scheduled reset; any approved device may. */
export async function postVaultResetCancel(signed: VaultSignerContext): Promise<any> {
  return vaultRequest('POST', '/vault/directory/reset/cancel', { body: {}, signed });
}
