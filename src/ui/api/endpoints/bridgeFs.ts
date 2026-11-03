// Bridge filesystem directory management endpoints.
//
// Live pass-through to a bridge's sandboxed FS (browse/stat/mkdir/read), used by the
// bridge-aware directory picker, the per-bridge "does this project path exist?"
// indicator and the New project modal's folder inspection (VCS detection and the
// AGENTS.md / CLAUDE.md description prefill). All paths are sandboxed to the
// bridge's fs_root by the bridge itself.

import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';
import type { WireError } from '../wireError';
import { decryptVaultText, getActiveVaultKey, isVaultArmored } from '../../utils/vaultContent';
import type { FsReadFileResult } from './projectFs';

// size / modified_at (RFC3339 UTC) are sent by every current bridge; optional so
// older bridges and existing fixtures stay valid.
export type BridgeFsEntry = { name: string; is_dir: boolean; hidden: boolean; has_git: boolean; size?: number; modified_at?: string };
export type BridgeFsListResult = {
  ok: boolean;
  path: string;
  root: string;
  parent: string;
  entries: BridgeFsEntry[];
  truncated: boolean;
  error?: WireError;
};
export type BridgeFsStatResult = {
  ok: boolean;
  path: string;
  exists: boolean;
  is_dir: boolean;
  has_git: boolean;
  within_root: boolean;
  error?: WireError;
};
export type BridgeFsMkdirResult = {
  ok: boolean;
  path: string;
  created: boolean;
  within_root: boolean;
  error?: WireError;
};

export const bridgeFsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    // List a directory on a bridge. `path` empty => the bridge's fs_root.
    listBridgeDir: build.query<BridgeFsListResult, { bridgeId: string; path?: string }>({
      queryFn: async ({ bridgeId, path = '' }) => {
        try {
          const qs = path ? `?path=${encodeURIComponent(path)}` : '';
          const data = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/fs${qs}`);
          return { data: data as BridgeFsListResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),
    // Stat a single path on a bridge (does it exist / is it a dir?).
    statBridgePath: build.query<BridgeFsStatResult, { bridgeId: string; path: string }>({
      queryFn: async ({ bridgeId, path }) => {
        try {
          const data = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/fs/stat?path=${encodeURIComponent(path)}`);
          return { data: data as BridgeFsStatResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),
    // Read one file on a bridge (no project needed): GET /bridges/{id}/fs/file. The
    // bridge refuses with vault_locked while its vault is locked and otherwise returns
    // the content vault-encrypted, so it is decrypted here with this device's key,
    // exactly like readProjectFile. Left armored when this device cannot decrypt.
    readBridgeFile: build.query<FsReadFileResult, { bridgeId: string; path: string; offset?: number; limit?: number }>({
      queryFn: async ({ bridgeId, path, offset, limit }) => {
        try {
          const qs = new URLSearchParams({ path });
          if (offset != null && offset > 0) qs.set('offset', String(offset));
          if (limit != null && limit > 0) qs.set('limit', String(limit));
          const data = (await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/fs/file?${qs.toString()}`)) as FsReadFileResult;
          if (data && typeof data.content === 'string' && isVaultArmored(data.content)) {
            const activeKey = getActiveVaultKey();
            if (activeKey) {
              try { data.content = await decryptVaultText(data.content, activeKey); } catch { /* stays armored */ }
            }
          }
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),
    // Create a directory (mkdir -p) on a bridge.
    mkdirBridgePath: build.mutation<BridgeFsMkdirResult, { bridgeId: string; path: string }>({
      queryFn: async ({ bridgeId, path }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/fs/mkdir`, 'POST', { path });
          return { data: data as BridgeFsMkdirResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),
  }),
});

export const {
  useListBridgeDirQuery,
  useLazyListBridgeDirQuery,
  useMkdirBridgePathMutation,
  useLazyReadBridgeFileQuery,
} = bridgeFsApi;
