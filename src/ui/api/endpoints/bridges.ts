// REQ-VAULT-HARDEN-3: Bridges API endpoint for E2EE unseal and public key retrieval

import { ApiError, cookieJsonFetch, cookieMutation } from '../cookieFetch';
import type { WireError } from '../wireError';
import { heimdallApi } from '../heimdallApi';
import type { BridgeUnsealPayload, BridgeUnsealResult } from '../../utils/vaultBridgeUnseal';
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
 * End-to-end unseal helper: wraps the vault key and sends unseal payload to Hub.
 */
export async function unsealBridgeE2EE(
  bridgeId: string,
  bridgePublicKey: string,
  vaultKey: string | CryptoKey | Uint8Array
): Promise<BridgeUnsealResult> {
  const { prepareUnsealPayload } = await import('../../utils/vaultBridgeUnseal');
  const payload = await prepareUnsealPayload(bridgeId, bridgePublicKey, vaultKey);
  return await unsealBridge(bridgeId, payload);
}

/**
 * Locks (purges the vault key on) a single bridge.
 *
 * REQ-BVS-4: this used to swallow EVERY error and `return { ok: true }`, so a lock
 * that never reached the bridge — offline bridge, 401, network failure — rendered as
 * a success and the UI happily reported the vault purged. A status indicator cannot
 * be built on top of a call that cannot fail, so the error now propagates: callers
 * that want to tolerate a failure must catch it explicitly (as
 * `lockAllConnectedBridges` below does), and callers that render state must surface
 * it. The returned `ok` is the hub's own answer, not a fabricated one.
 *
 * @throws ApiError (or the underlying network error) when the lock did not succeed.
 */
export async function lockBridge(bridgeId: string): Promise<{ ok: boolean }> {
  const res = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/lock`, 'POST', {});
  // A 2xx with an explicit `ok: false` is still a failed lock — do not report success.
  const ok = (res as any)?.ok;
  if (ok === false) {
    throw new Error(
      String((res as any)?.message || (res as any)?.error?.message || `Bridge ${bridgeId} refused the lock request`),
    );
  }
  return { ok: true };
}

/**
 * Unseals online bridges that explicitly report a locked vault.
 *
 * REQ-AUX-10: pass raw HEX when it was derived during this browser session. The
 * hardened/IndexedDB-restored CryptoKey is deliberately non-extractable, so this flow
 * never treats that handle as transferable material; callers use
 * `needsReauthentication` to open the secure password/recovery ceremony.
 */
export interface BridgeVaultReconciliationResult {
  targetBridgeIds: string[];
  attemptedBridgeIds: string[];
  succeededBridgeIds: string[];
  failedBridgeIds: string[];
  needsReauthentication: boolean;
}

/**
 * Reconcile a known bridge-list snapshot. Keeping targeting separate from `/bridges`
 * fetching lets AppShell use the same authoritative list it renders and makes partial
 * failures observable instead of collapsing them into a misleading success count.
 */
export async function reconcileLockedBridges(
  bridges: readonly BridgeVaultStatusRecord[],
  vaultKey?: CryptoKey | string | null,
): Promise<BridgeVaultReconciliationResult> {
  const { getActiveBridgeVaultKeyMaterial } = await import('../../store/vaultSlice');
  const targetBridgeIds = selectOnlineLockedBridgeIds(bridges);
  const key = vaultKey || getActiveBridgeVaultKeyMaterial();
  const result: BridgeVaultReconciliationResult = {
    targetBridgeIds,
    attemptedBridgeIds: [],
    succeededBridgeIds: [],
    failedBridgeIds: [],
    needsReauthentication: targetBridgeIds.length > 0 && !key,
  };
  if (!key || targetBridgeIds.length === 0) return result;

  result.attemptedBridgeIds = [...targetBridgeIds];
  const outcomes = await Promise.all(targetBridgeIds.map(async (bridgeId) => {
    try {
      const pubKey = await fetchBridgePublicKey(bridgeId);
      if (!pubKey) throw new Error(`Bridge ${bridgeId} advertised no public key`);
      await unsealBridgeE2EE(bridgeId, pubKey, key);
      return true;
    } catch (err) {
      console.warn(`[reconcileLockedBridges] failed unsealing bridge ${bridgeId}:`, err);
      return false;
    }
  }));
  outcomes.forEach((succeeded, index) => {
    (succeeded ? result.succeededBridgeIds : result.failedBridgeIds).push(targetBridgeIds[index]);
  });
  return result;
}

export async function unsealAllConnectedBridges(vaultKey?: CryptoKey | string | null): Promise<number> {

  try {
    const data = await cookieJsonFetch('/bridges');
    const rawBridges: any[] = data?.bridges || (Array.isArray(data) ? data : []);
    const result = await reconcileLockedBridges(rawBridges, vaultKey);
    return result.succeededBridgeIds.length;
  } catch (err) {
    console.warn('[unsealAllConnectedBridges] failed to list bridges:', err);
    return 0;
  }
}

/**
 * Locks all online bridges and purges vault keys on remote bridges.
 */
export async function lockAllConnectedBridges(): Promise<number> {
  try {
    const data = await cookieJsonFetch('/bridges');
    const rawBridges: any[] = data?.bridges || (Array.isArray(data) ? data : []);
    const onlineBridges = rawBridges.filter((b) => {
      const id = String(b?.bridge_id || b?.bridgeId || b?.id || '');
      if (!id) return false;
      const status = String(b?.status || b?.runtime_status || '').toLowerCase();
      return status !== 'revoked';
    });

    let lockedCount = 0;
    for (const bridge of onlineBridges) {
      const bridgeId = String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
      try {
        await lockBridge(bridgeId);
        lockedCount++;
      } catch (err) {
        console.warn(`[lockAllConnectedBridges] failed locking bridge ${bridgeId}:`, err);
      }
    }
    return lockedCount;
  } catch (err) {
    console.warn('[lockAllConnectedBridges] failed to list bridges:', err);
    return 0;
  }
}

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

export const { useUnsealBridgeMutation, useGetBridgePublicKeyQuery } = bridgesApi;
