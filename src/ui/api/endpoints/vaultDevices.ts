// Passwordless vault device-directory API (docs/plans/passwordless-vault.md §2 P2/P3).
//
// EVERY call to the vault directory / device endpoints lives here, so hub API changes
// land in one file. Mutations are signed with the device key (vaultRequestSigner):
// the body string signed is exactly the body string sent.
//
// Responses are untrusted input: callers verify everything with
// vaultDirectoryVerify / vaultKeyringWrap before acting on it.

import { ApiError, apiUrl, errorFromResponse } from '../cookieFetch';
import { signedRequestHeaders, type RequestSigner } from '../../utils/vaultRequestSigner';
import type { VaultDirectory } from '../../utils/vaultDirectoryVerify';
import type { SignedKeyringWrap } from '../../utils/vaultKeyringWrap';

export interface VaultSignerContext {
  userId: string;
  signer: RequestSigner;
}

const API = '/api/v1';

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
  /** Present only when the hub just issued/refreshed the code. */
  user_code?: string;
  code_expires_at?: string;
}

export async function postVaultRegister(statement: string, proofSignature: unknown): Promise<RegisterResult> {
  return vaultRequest('POST', '/vault/devices/register', { body: { statement, proof_signature: proofSignature } });
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
  [k: string]: unknown;
}

export type DeviceCodeInfo = BrowserCodeInfo | BridgeCodeInfo;

export async function verifyDeviceCode(userCode: string): Promise<DeviceCodeInfo> {
  return vaultRequest('POST', '/device/verify', { body: { user_code: userCode } });
}

export interface BrowserApprovalBody {
  user_code: string;
  expected_version: number;
  statement: string;
  signature: unknown;
  wrap: SignedKeyringWrap;
}

export async function postApproveBrowser(deviceId: string, body: BrowserApprovalBody, signed: VaultSignerContext): Promise<{ directory_version: number }> {
  return vaultRequest('POST', `/vault/devices/${encodeURIComponent(deviceId)}/approve`, { body, signed });
}

export interface BridgeApprovalBody {
  user_code: string;
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
