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
 * The hub origin pairing binds (pairing stretch, plan §1 "Pairing"): the origin of the
 * API base this page talks to. Throws outside an http(s) page.
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

/** Browser (trusted-proxy) auth only; self-signed statements in the body. */
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
 * `pairSalt` is the public salt of the pairing stretch.
 */
export async function postVaultRegister(statement: string, proofSignature: unknown, pairLookup: string, pairKeyMac: string, pairSalt: string): Promise<RegisterResult> {
  return vaultRequest('POST', '/vault/devices/register', { body: { statement, proof_signature: proofSignature, pair_lookup: pairLookup, pair_key_mac: pairKeyMac, pair_salt: pairSalt } });
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
}

export interface BridgeCodeInfo {
  kind: 'bridge';
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
  [k: string]: unknown;
}

export type DeviceCodeInfo = BrowserCodeInfo | BridgeCodeInfo;

export interface PairCandidate {
  kind: 'browser' | 'bridge';
  pair_salt: string;
}

/**
 * Public salts of the requests this user could approve (own pending browsers, then
 * pending bridges): the lookup is derived from the typed code AND a request's salt.
 */
export async function fetchPairCandidates(): Promise<PairCandidate[]> {
  const res = await vaultRequest('POST', '/device/pair-salts', { body: {} });
  return Array.isArray(res?.candidates) ? res.candidates : [];
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
  target_bridge_id?: string;
  new_bridge_label?: string;
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
