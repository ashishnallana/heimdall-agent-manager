// REQ-VAULT-HARDEN-3: Bridges API endpoint for E2EE unseal and public key retrieval

import { ApiError, cookieJsonFetch, cookieMutation } from '../cookieFetch';
import type { WireError } from '../wireError';
import { heimdallApi } from '../heimdallApi';
import type {
  BridgeUnsealPayload,
  BridgeUnsealResult,
  BridgeUnsealTarget,
} from '../../utils/vaultBridgeUnseal';
import {
  selectOnlineLockedBridgeIds,
  type BridgeVaultStatusRecord,
} from '../../utils/bridgeVaultStatus';

/**
 * Dispatches an E2EE wrapped unseal payload to Hub for the specified Bridge.
 * The Hub passes the blind ciphertext directly to Bridge via WebSocket command socket.
 */
export async function unsealBridge(
  bridgeId: string,
  payload: BridgeUnsealPayload
): Promise<BridgeUnsealResult> {
  const res = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/unseal`, 'POST', payload);
  // A 2xx relaying the bridge's `ok: false` is a refused unseal (REQ-ERR-PROTO-A):
  // throw its typed error instead of letting callers report success.
  if ((res as any)?.ok === false) {
    const err = (res as any)?.error as WireError | undefined;
    throw new ApiError(
      String(err?.message || `Bridge ${bridgeId} refused the unseal`),
      undefined,
      err?.code,
      err?.class || undefined,
      err?.cause,
    );
  }
  return res as BridgeUnsealResult;
}

/**
 * Fetches the ephemeral ECDH public key advertised by a live Bridge.
 */
export async function fetchBridgePublicKey(bridgeId: string): Promise<string> {
  const res = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/public-key`);
  return (res as any)?.public_key || (res as any)?.bridge_public_key || '';
}

/**
 * Fetches everything an unseal needs about a bridge's current unseal key: the
 * ephemeral ECDH key, its boot id, the identity key and the identity signature over
 * the ephemeral key. `enrollment` asks for the enrolling process's key.
 */
export async function fetchBridgeUnsealTarget(bridgeId: string, enrollment = false): Promise<BridgeUnsealTarget> {
  const { bridgeUnsealTargetFromRecord } = await import('../../utils/vaultBridgeUnseal');
  const query = enrollment ? '?enrollment=1' : '';
  const res = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/public-key${query}`);
  return bridgeUnsealTargetFromRecord(bridgeId, (res as any)?.data ?? res);
}

/**
 * REQ-EA-6: where an atomic enrollment stands. `GET /bridges/{id}/enrollment`.
 * A bridge is enrolled only once its vault key reaches the enrolling process
 * (`ham-bridge enroll`), which holds an enroll-only connection until then.
 */
export interface BridgeEnrollmentStatus {
  bridge_id: string;
  enrollment_state: 'pending' | 'enrolled';
  /** RFC 3339 deadline after which the hub rolls the enrollment back ('' for an attach). */
  enrollment_pending_until: string;
  /** Whether the enrolling process is connected and can receive the key. */
  enroll_connected: boolean;
  /** The key the connected enrolling process holds ('' when not connected). */
  enroll_public_key: string;
  vault_status: string;
}

/**
 * Reads an enrollment's state. Resolves `null` when the hub no longer knows the
 * bridge: a new bridge's row is deleted when its enrollment is rolled back.
 */
export async function fetchBridgeEnrollmentStatus(bridgeId: string, signal?: AbortSignal): Promise<BridgeEnrollmentStatus | null> {
  try {
    const res = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/enrollment`, signal ? { signal } : undefined);
    const data = ((res as any)?.data ?? res) as BridgeEnrollmentStatus;
    return data && typeof data === 'object' ? data : null;
  } catch (err: any) {
    if (err instanceof ApiError && err.status === 404) return null;
    throw err;
  }
}

/**
 * One bridge row (`GET /bridges/{id}`): status, enrollment_state, vault_status, ….
 * Resolves `null` when the hub does not know the bridge (404).
 */
export async function fetchBridgeRow(bridgeId: string, signal?: AbortSignal): Promise<Record<string, any> | null> {
  try {
    const res = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}`, signal ? { signal } : undefined);
    const data = (res as any)?.data ?? res;
    return data && typeof data === 'object' ? data : null;
  } catch (err: any) {
    if (err instanceof ApiError && err.status === 404) return null;
    throw err;
  }
}

/** A bridge that is approved but not enrolled yet (REQ-EA-1). */
export interface PendingBridgeEnrollment {
  bridge_id: string;
  label: string;
  machine_hostname: string;
  enrollment_pending_until: string;
  /** The existing bridge stays enrolled while its replacement is pending. */
  replacing: boolean;
}

/**
 * The owner's pending enrollments, including replacements of enrolled bridges.
 * Opt-in enrollment_in_progress keeps ordinary bridge pickers unchanged. The
 * enrollment_state fallback supports Hubs predating replacement discovery.
 */
export async function fetchPendingBridgeEnrollments(): Promise<PendingBridgeEnrollment[]> {
  const res = await cookieJsonFetch('/bridges?include_pending=1');
  const body = (res as any)?.data ?? res;
  const rows: any[] = Array.isArray(body) ? body : Array.isArray(body?.bridges) ? body.bridges : [];
  return rows
    .filter((row) => row?.enrollment_state === 'pending' || row?.enrollment_in_progress === true)
    .map((row) => ({
      bridge_id: String(row.bridge_id || ''),
      label: String(row.label || ''),
      machine_hostname: String(row.machine_hostname || ''),
      enrollment_pending_until: String(row.enrollment_pending_until || ''),
      replacing: row.enrollment_state === 'enrolled',
    }))
    .filter((row) => row.bridge_id !== '');
}

/** Abandons a pending enrollment now instead of at its deadline. Idempotent. */
/**
 * Cancels a pending enrollment (REQ-EA-3). `rolledBack` is the Hub's verdict: it is
 * false when the bridge's commit won the race and it is enrolled after all, so the
 * caller must not report a rollback. A Hub that predates the field reports none,
 * which reads as rolled back, as it always did.
 */
export async function cancelBridgeEnrollment(bridgeId: string): Promise<{ rolledBack: boolean }> {
  const res = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/enrollment/cancel`, 'POST', {});
  return { rolledBack: (res as any)?.rolled_back !== false };
}

/** GET /bridges rows (list or `{bridges}`), tolerant of either envelope. */
async function listBridgeRows(): Promise<any[]> {
  const data = await cookieJsonFetch('/bridges');
  return data?.bridges || (Array.isArray(data) ? data : []);
}

/**
 * Bridges whose vault reports locked while online — the ones a chain-verified
 * re-unseal should reach (see services/deviceVault.unsealApprovedBridges).
 */
export async function listOnlineLockedBridgeIds(): Promise<string[]> {
  return selectOnlineLockedBridgeIds(await listBridgeRows() as BridgeVaultStatusRecord[]);
}

/**
 * Bridges that report `unpaired`: enrolled but never given keys, and unable to accept
 * them any more (they missed their enrollment's first unseal). Revoke + re-enroll.
 */
export async function listUnpairedBridgeIds(): Promise<string[]> {
  return (await listBridgeRows())
    .filter((b) => String(b?.vault_status ?? '').toLowerCase() === 'unpaired')
    .map((b) => String(b?.bridge_id || b?.bridgeId || b?.id || ''))
    .filter(Boolean);
}

/** Every online, non-revoked bridge id (re-unseal after a rotation). */
export async function listOnlineBridgeIds(): Promise<string[]> {
  return (await listBridgeRows())
    .filter((b) => {
      const status = String(b?.status || b?.runtime_status || '').toLowerCase();
      return status === 'online' || status === 'connected';
    })
    .map((b) => String(b?.bridge_id || b?.bridgeId || b?.id || ''))
    .filter(Boolean);
}

/** The transport the device vault uses to deliver keyrings to bridges. */
export const bridgeUnsealTransport = {
  fetchTarget: (bridgeId: string, enrollment: boolean) => fetchBridgeUnsealTarget(bridgeId, enrollment),
  dispatch: (bridgeId: string, payload: BridgeUnsealPayload) => unsealBridge(bridgeId, payload),
  listOnlineBridgeIds,
  listOnlineLockedBridgeIds,
};

export const bridgesApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    unsealBridge: build.mutation<BridgeUnsealResult, { bridgeId: string; payload: BridgeUnsealPayload }>({
      queryFn: async ({ bridgeId, payload }) => {
        try {
          const data = await unsealBridge(bridgeId, payload);
          return { data };
        } catch (err: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(err?.message || err) } as any };
        }
      },
    }),
    getBridgePublicKey: build.query<string, string>({
      queryFn: async (bridgeId) => {
        try {
          const data = await fetchBridgePublicKey(bridgeId);
          return { data };
        } catch (err: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(err?.message || err) } as any };
        }
      },
    }),
  }),
});
