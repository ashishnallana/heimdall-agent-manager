// Bridge filesystem directory management endpoints.
//
// Live pass-through to a bridge's sandboxed FS (browse/stat/mkdir), used by the
// bridge-aware directory picker and the per-bridge "does this project path exist?"
// indicator. All paths are sandboxed to the bridge's fs_root by the bridge itself.

import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';
import type { WireError } from '../wireError';

export type BridgeFsEntry = { name: string; is_dir: boolean; hidden: boolean; has_git: boolean };
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
} = bridgeFsApi;
