// Project-scoped filesystem browser endpoints (Project Directory Browser feature).
//
// Built against the LOCKED API contract (art_18d23e8bfc65311a). These are the
// project-scoped Hub wrappers that resolve (project_id -> bridge_id, root_path)
// server-side and relay a WS command to the owning bridge. All request paths are
// RELATIVE to the project root; the bridge re-sandboxes them.
//
//   GET    /api/v1/projects/{projectId}/fs        -> fs_list_dir    (?path=&include_hidden=&cursor=&limit=)
//   GET    /api/v1/projects/{projectId}/fs/file   -> fs_read_file   (?path=)
//   POST   /api/v1/projects/{projectId}/fs/file   -> fs_create_file (body { path })
//   POST   /api/v1/projects/{projectId}/fs/dir    -> fs_make_dir    (body { path })
//   POST   /api/v1/projects/{projectId}/fs/move   -> fs_move        (body { from, to })
//   DELETE /api/v1/projects/{projectId}/fs        -> fs_delete      (?path=&recursive=)
//
// UI cache is keyed by (projectId, bridgeId, path) so switching project/bridge or
// mutating a directory only refetches the affected listing.

import { heimdallApi } from '../heimdallApi';
import type { WireError } from '../wireError';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';
import { isVaultArmored, decryptVaultText, encryptVaultText, getActiveVaultKey } from '../../utils/vaultContent';

// ---- Contract types (mirror the LOCKED contract exactly) --------------------

export type FsEntry = {
  name: string;
  is_dir: boolean;
  hidden: boolean;
  has_git: boolean;
  size: number;
  modified_at: string;
};

export type FsListResult = {
  ok: boolean;
  path: string;
  root: string;
  parent: string;
  entries: FsEntry[];
  next_cursor: string | null;
  has_more: boolean;
  truncated: boolean;
  error?: WireError;
};

export type FsReadFileResult = {
  ok: boolean;
  path: string;
  viewable: boolean;
  content?: string;
  encoding?: 'utf8' | 'base64';
  mime: string;
  size: number;
  modified_at: string;
  truncated: boolean;
  // Byte-range pagination (utf8 text): offset of this chunk, bytes it covers, and
  // whether it reached end of file. Page by requesting offset += bytes_returned.
  offset?: number;
  bytes_returned?: number;
  eof?: boolean;
  error?: WireError;
};

export type FsMutationResult = {
  ok: boolean;
  path: string;
  within_root: boolean;
  error?: WireError;
};

export type FsWriteResult = {
  ok: boolean;
  path: string;
  bytes_written?: number;
  modified_at?: string;
  within_root?: boolean;
  error?: WireError;
};

export type FsSavedItem = {
  path: string;
  bytes_written: number;
  modified_at: string;
};

export type FsErrorItem = {
  path: string;
  error_code: string;
  message: string;
};

export type FsBatchWriteResult = {
  ok: boolean;
  saved: FsSavedItem[];
  errors: FsErrorItem[];
  error?: WireError;
};

export type FsQuickOpenResult = {
  ok: boolean;
  root: string;
  files: string[];
  truncated: boolean;
  error?: WireError;
};

import type {
  FsSearchMatch,
  FsSearchResult,
  FsSearchScope,
  ScopedSearchMatch,
  MultiScopeSearchOptions,
  MultiScopeSearchResult,
} from '../../search/scopedSearchLogic';

export type {
  FsSearchMatch,
  FsSearchResult,
  FsSearchScope,
  ScopedSearchMatch,
  MultiScopeSearchOptions,
  MultiScopeSearchResult,
};

// The bridge's fs causes (WireError.cause), exported for callers that want
// to branch on specific failures (e.g. friendly "already exists" messaging).
export const FS_ERROR_CODES = [
  'path_outside_root',
  'path_not_found',
  'path_not_directory',
  'not_a_file',
  'file_too_large',
  'unsupported_type',
  'path_exists',
  'dest_exists',
  'dir_not_empty',
  'cannot_delete_root',
  'read_failed',
  'write_failed',
  'mkdir_failed',
  'move_failed',
  'delete_failed',
] as const;
export type FsErrorCode = (typeof FS_ERROR_CODES)[number] | '';

// ---- Cache key helpers ------------------------------------------------------

// Tag id for a directory listing. Keyed by (projectId | chainId+dirId | instance::instanceId, bridgeId, path) so a
// mutation in one directory only invalidates that directory's listing.
function fsListTagId(
  target: { projectId?: string; chainId?: string; directoryId?: string; agentInstanceId?: string } | string,
  bridgeId: string,
  path: string,
): string {
  if (typeof target === 'string') {
    return `${target}::${bridgeId}::${path || ''}`;
  }
  const scope =
    target?.agentInstanceId
      ? `instance::${target.agentInstanceId}`
      : target?.chainId && target?.directoryId && target?.directoryId !== 'primary'
      ? `${target.chainId}::${target.directoryId}`
      : target?.projectId || '';
  return `${scope}::${bridgeId}::${path || ''}`;
}

// ---- Arg types --------------------------------------------------------------

export type FsScopeArgs = {
  projectId?: string;
  chainId?: string;
  directoryId?: string;
  agentInstanceId?: string;
  bridgeId?: string;
};

type ListArgs = FsScopeArgs & {
  path?: string;
  includeHidden?: boolean;
  cursor?: string | null;
  limit?: number;
};
type ReadFileArgs = FsScopeArgs & { path: string; offset?: number; limit?: number };
type CreateArgs = FsScopeArgs & { path: string };
type WriteFileArgs = FsScopeArgs & { path: string; content: string; encoding?: 'utf8' | 'base64' };
type BatchWriteFilesArgs = FsScopeArgs & { files: Array<{ path: string; content: string }> };
type MoveArgs = FsScopeArgs & { from: string; to: string };
type DeleteArgs = FsScopeArgs & { path: string; recursive?: boolean };
type QuickOpenArgs = FsScopeArgs & { query?: string; limit?: number };
export type SearchFilesArgs = FsScopeArgs & {
  query: string;
  path?: string;
  caseSensitive?: boolean;
  limit?: number;
};
export type SearchInstanceFilesArgs = {
  agentInstanceId: string;
  query: string;
  path?: string;
  caseSensitive?: boolean;
  limit?: number;
};

function base(target: { projectId?: string; chainId?: string; directoryId?: string; agentInstanceId?: string } | string): string {
  if (typeof target === 'string') {
    return `/projects/${encodeURIComponent(target)}/fs`;
  }
  if (target?.agentInstanceId) {
    return `/agent-instances/${encodeURIComponent(target.agentInstanceId)}/fs`;
  }
  if (target?.chainId && target?.directoryId && target?.directoryId !== 'primary') {
    return `/task-chains/${encodeURIComponent(target.chainId)}/directories/${encodeURIComponent(target.directoryId)}/fs`;
  }
  return `/projects/${encodeURIComponent(target?.projectId || '')}/fs`;
}

// Query fragment that pins the resolution to the conversation's bridge, so a
// project configured on multiple bridges (or on a different/offline bridge) still
// targets the bridge the agent actually runs on. Empty => hub falls back to the
// single configured path.
function bridgeParam(bridgeId?: string): string {
  return bridgeId ? `bridge_id=${encodeURIComponent(bridgeId)}` : '';
}

export const projectFsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    // List a single directory (project-root-relative `path`, '' => project root).
    listProjectDir: build.query<FsListResult, ListArgs>({
      queryFn: async ({ projectId, chainId, directoryId, agentInstanceId, bridgeId = '', path = '', includeHidden = false, cursor = null, limit }) => {
        try {
          const qs = new URLSearchParams();
          // Disambiguate which bridge's project path to use: a project may be
          // configured on multiple bridges (or only on a DIFFERENT bridge than the
          // one the conversation's agent runs on). Passing the conversation's
          // bridge_id makes the hub resolve THIS bridge's path instead of falling
          // back to "the single configured path" (which can be an offline bridge).
          if (bridgeId && !agentInstanceId) qs.set('bridge_id', bridgeId);
          if (path) qs.set('path', path);
          if (agentInstanceId) {
            qs.set('include_hidden', includeHidden ? 'true' : 'false');
          } else {
            if (includeHidden) qs.set('include_hidden', 'true');
          }
          if (cursor) qs.set('cursor', cursor);
          if (limit != null) qs.set('limit', String(limit));
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base({ projectId, chainId, directoryId, agentInstanceId })}${suffix}`);
          return { data: data as FsListResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, chainId, directoryId, agentInstanceId, bridgeId = '', path = '' }) => [
        { type: 'ProjectFs' as const, id: fsListTagId({ projectId, chainId, directoryId, agentInstanceId }, bridgeId, path) },
      ],
    }),

    // Bounded, byte-range-paginated read of a single file for the viewer. Pass
    // offset/limit to stream a large text file in chunks (avoids the one-huge-
    // frame WS relay timeout). We assume the file doesn't change between pages.
    readProjectFile: build.query<FsReadFileResult, ReadFileArgs>({
      queryFn: async ({ projectId, chainId, directoryId, agentInstanceId, bridgeId = '', path, offset, limit }, api) => {
        try {
          const qs = new URLSearchParams({ path });
          if (bridgeId && !agentInstanceId) qs.set('bridge_id', bridgeId);
          if (offset != null && offset > 0) qs.set('offset', String(offset));
          if (limit != null && limit > 0) qs.set('limit', String(limit));
          const data = (await cookieJsonFetch(`${base({ projectId, chainId, directoryId, agentInstanceId })}/file?${qs.toString()}`)) as FsReadFileResult;
          if (data && typeof data.content === 'string' && isVaultArmored(data.content)) {
            const state: any = api?.getState?.();
            const activeKey = getActiveVaultKey();
            const isUnlocked = state?.vault != null
              ? Boolean(state.vault.isUnlocked || state.vault.unlocked || activeKey)
              : Boolean(activeKey);
            if (isUnlocked && activeKey) {
              try {
                data.content = await decryptVaultText(data.content, activeKey);
              } catch {
                // If locked or decryption fails, leave armored (or set error).
              }
            }
          }
          return { data: data as FsReadFileResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      // File views are point reads; keep them per (project, bridge, path). Chunks
      // are fetched lazily (useLazy…) and stitched in the component, so we don't
      // key the cache by offset.
      providesTags: (_result, _error, { projectId, chainId, directoryId, agentInstanceId, bridgeId = '', path }) => [
        { type: 'ProjectFs' as const, id: `file::${fsListTagId({ projectId, chainId, directoryId, agentInstanceId }, bridgeId, path)}` },
      ],
    }),

    // Create an empty file at `path`.
    createProjectFile: build.mutation<FsMutationResult, CreateArgs>({
      queryFn: async ({ projectId, chainId, directoryId, agentInstanceId, bridgeId = '', path }) => {
        try {
          const bp = bridgeParam(bridgeId);
          const data = await cookieMutation(`${base({ projectId, chainId, directoryId, agentInstanceId })}/file${bp ? `?${bp}` : ''}`, 'POST', { path });
          return { data: data as FsMutationResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, chainId, directoryId, agentInstanceId, bridgeId = '', path }) => [
        { type: 'ProjectFs' as const, id: fsListTagId({ projectId, chainId, directoryId, agentInstanceId }, bridgeId, parentOf(path)) },
      ],
    }),

    // Create a directory at `path` (reuses the existing fs_make_dir command).
    createProjectDir: build.mutation<FsMutationResult, CreateArgs>({
      queryFn: async ({ projectId, chainId, directoryId, agentInstanceId, bridgeId = '', path }) => {
        try {
          const bp = bridgeParam(bridgeId);
          const data = await cookieMutation(`${base({ projectId, chainId, directoryId, agentInstanceId })}/dir${bp ? `?${bp}` : ''}`, 'POST', { path });
          return { data: data as FsMutationResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, chainId, directoryId, agentInstanceId, bridgeId = '', path }) => [
        { type: 'ProjectFs' as const, id: fsListTagId({ projectId, chainId, directoryId, agentInstanceId }, bridgeId, parentOf(path)) },
      ],
    }),

    // Rename/move `from` -> `to`. Invalidates both source and dest parents.
    moveProjectPath: build.mutation<FsMutationResult, MoveArgs>({
      queryFn: async ({ projectId, chainId, directoryId, agentInstanceId, bridgeId = '', from, to }) => {
        try {
          const bp = bridgeParam(bridgeId);
          const data = await cookieMutation(`${base({ projectId, chainId, directoryId, agentInstanceId })}/move${bp ? `?${bp}` : ''}`, 'POST', { from, to });
          return { data: data as FsMutationResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, chainId, directoryId, agentInstanceId, bridgeId = '', from, to }) => [
        { type: 'ProjectFs' as const, id: fsListTagId({ projectId, chainId, directoryId, agentInstanceId }, bridgeId, parentOf(from)) },
        { type: 'ProjectFs' as const, id: fsListTagId({ projectId, chainId, directoryId, agentInstanceId }, bridgeId, parentOf(to)) },
      ],
    }),

    // Delete `path` (optionally recursive for non-empty dirs).
    deleteProjectPath: build.mutation<FsMutationResult, DeleteArgs>({
      queryFn: async ({ projectId, chainId, directoryId, agentInstanceId, bridgeId = '', path, recursive = false }) => {
        try {
          const qs = new URLSearchParams({ path });
          if (recursive) qs.set('recursive', 'true');
          if (bridgeId && !agentInstanceId) qs.set('bridge_id', bridgeId);
          const data = await cookieMutation(`${base({ projectId, chainId, directoryId, agentInstanceId })}?${qs.toString()}`, 'DELETE');
          return { data: data as FsMutationResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, chainId, directoryId, agentInstanceId, bridgeId = '', path }) => [
        { type: 'ProjectFs' as const, id: fsListTagId({ projectId, chainId, directoryId, agentInstanceId }, bridgeId, parentOf(path)) },
      ],
    }),

    // Write / overwrite file content at `path` (PUT /projects/{projectId}/fs/file).
    writeProjectFile: build.mutation<FsWriteResult, WriteFileArgs>({
      queryFn: async ({ projectId, chainId, directoryId, agentInstanceId, bridgeId = '', path, content, encoding }, api) => {
        try {
          const bp = bridgeParam(bridgeId);
          let outgoingContent = content;
          const state: any = api?.getState?.();
          const activeKey = getActiveVaultKey();
          const isUnlocked = state?.vault != null
            ? Boolean(state.vault.isUnlocked || state.vault.unlocked || activeKey)
            : Boolean(activeKey);
          if (isUnlocked && activeKey && typeof outgoingContent === 'string') {
            if (!isVaultArmored(outgoingContent)) {
              outgoingContent = await encryptVaultText(outgoingContent, activeKey);
            }
          }
          const data = await cookieMutation(
            `${base({ projectId, chainId, directoryId, agentInstanceId })}/file${bp ? `?${bp}` : ''}`,
            'PUT',
            { path, content: outgoingContent, encoding },
          );
          return { data: data as FsWriteResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, chainId, directoryId, agentInstanceId, bridgeId = '', path }) => [
        { type: 'ProjectFs' as const, id: `file::${fsListTagId({ projectId, chainId, directoryId, agentInstanceId }, bridgeId, path)}` },
        { type: 'ProjectFs' as const, id: fsListTagId({ projectId, chainId, directoryId, agentInstanceId }, bridgeId, parentOf(path)) },
      ],
    }),

    // Batch write multiple files (PUT /projects/{projectId}/fs/files).
    batchWriteProjectFiles: build.mutation<FsBatchWriteResult, BatchWriteFilesArgs>({
      queryFn: async ({ projectId, chainId, directoryId, agentInstanceId, bridgeId = '', files }, api) => {
        try {
          const bp = bridgeParam(bridgeId);
          const state: any = api?.getState?.();
          const activeKey = getActiveVaultKey();
          const isUnlocked = state?.vault != null
            ? Boolean(state.vault.isUnlocked || state.vault.unlocked || activeKey)
            : Boolean(activeKey);
          let outgoingFiles = files;
          if (isUnlocked && activeKey && Array.isArray(files)) {
            outgoingFiles = await Promise.all(
              files.map(async (file) => {
                if (typeof file.content === 'string') {
                  const content = isVaultArmored(file.content)
                    ? file.content
                    : await encryptVaultText(file.content, activeKey);
                  return { ...file, content };
                }
                return file;
              }),
            );
          }
          const data = await cookieMutation(
            `${base({ projectId, chainId, directoryId, agentInstanceId })}/files${bp ? `?${bp}` : ''}`,
            'PUT',
            { files: outgoingFiles },
          );
          return { data: data as FsBatchWriteResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, chainId, directoryId, agentInstanceId, bridgeId = '', files }) => {
        const tags: Array<{ type: 'ProjectFs'; id: string }> = [];
        const parents = new Set<string>();
        for (const file of files || []) {
          tags.push({ type: 'ProjectFs' as const, id: `file::${fsListTagId({ projectId, chainId, directoryId, agentInstanceId }, bridgeId, file.path)}` });
          parents.add(parentOf(file.path));
        }
        for (const parent of parents) {
          tags.push({ type: 'ProjectFs' as const, id: fsListTagId({ projectId, chainId, directoryId, agentInstanceId }, bridgeId, parent) });
        }
        return tags;
      },
    }),

    // Project-scoped fuzzy file path search for Quick Open (GET /projects/{projectId}/fs/quick-open).
    quickOpenProjectFiles: build.query<FsQuickOpenResult, QuickOpenArgs>({
      queryFn: async ({ projectId, chainId, directoryId, agentInstanceId, bridgeId = '', query = '', limit }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId && !agentInstanceId) qs.set('bridge_id', bridgeId);
          if (query) qs.set('query', query);
          if (limit != null) qs.set('limit', String(limit));
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = (await cookieJsonFetch(`${base({ projectId, chainId, directoryId, agentInstanceId })}/quick-open${suffix}`)) as any;
          const files = Array.isArray(data?.files) ? data.files : Array.isArray(data?.matches) ? data.matches : [];
          return { data: { ...data, files } as FsQuickOpenResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),

    // Text search (fs_grep / ripgrep) across a project, chain directory, or agent run-dir.
    searchProjectFiles: build.query<FsSearchResult, SearchFilesArgs>({
      queryFn: async (
        { projectId, chainId, directoryId, agentInstanceId, bridgeId = '', query, path = '', caseSensitive = false, limit = 100 },
        api,
      ) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId && !agentInstanceId) qs.set('bridge_id', bridgeId);
          if (query) qs.set('query', query);
          if (path) qs.set('path', path);
          if (caseSensitive) qs.set('case_sensitive', 'true');
          if (limit != null) qs.set('limit', String(limit));
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = (await cookieJsonFetch(`${base({ projectId, chainId, directoryId, agentInstanceId })}/search${suffix}`)) as any;
          const rawMatches = Array.isArray(data?.matches) ? data.matches : [];
          const state: any = api?.getState?.();
          const activeKey = getActiveVaultKey();
          const isUnlocked = state?.vault != null
            ? Boolean(state.vault.isUnlocked || state.vault.unlocked || activeKey)
            : Boolean(activeKey);

          let matches = rawMatches;
          if (isUnlocked && activeKey) {
            matches = await decryptSearchMatches(rawMatches, activeKey);
          }
          return { data: { ...data, matches } as FsSearchResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),

    // Search agent instance run directory files (GET /api/v1/agent-instances/{instanceId}/fs/search).
    searchInstanceFiles: build.query<FsSearchResult, SearchInstanceFilesArgs>({
      queryFn: async ({ agentInstanceId, query, path = '', caseSensitive = false, limit = 100 }, api) => {
        try {
          const qs = new URLSearchParams();
          if (query) qs.set('query', query);
          if (path) qs.set('path', path);
          if (caseSensitive) qs.set('case_sensitive', 'true');
          if (limit != null) qs.set('limit', String(limit));
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = (await cookieJsonFetch(`/agent-instances/${encodeURIComponent(agentInstanceId)}/fs/search${suffix}`)) as any;
          const rawMatches = Array.isArray(data?.matches) ? data.matches : [];
          const state: any = api?.getState?.();
          const activeKey = getActiveVaultKey();
          const isUnlocked = state?.vault != null
            ? Boolean(state.vault.isUnlocked || state.vault.unlocked || activeKey)
            : Boolean(activeKey);

          let matches = rawMatches;
          if (isUnlocked && activeKey) {
            matches = await decryptSearchMatches(rawMatches, activeKey);
          }
          return { data: { ...data, matches } as FsSearchResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),
  }),
});

// Parent directory of a project-root-relative path (''=root). Kept local so the
// cache invalidation targets the listing that actually changed.
function parentOf(path: string): string {
  const clean = String(path || '').replace(/\/+$/, '');
  const idx = clean.lastIndexOf('/');
  return idx <= 0 ? '' : clean.slice(0, idx);
}

// Decrypt line_content and line for grep search matches when vault is unlocked
async function decryptSearchMatches(rawMatches: any[], activeKey?: CryptoKey | string | null): Promise<any[]> {
  return await Promise.all(
    rawMatches.map(async (m: any) => {
      const updated = { ...m };
      if (typeof updated.line_content === 'string' && isVaultArmored(updated.line_content)) {
        try {
          updated.line_content = await decryptVaultText(updated.line_content, activeKey);
        } catch {}
      }
      if (typeof updated.line === 'string' && isVaultArmored(updated.line)) {
        try {
          updated.line = await decryptVaultText(updated.line, activeKey);
        } catch {}
      }
      if (updated.line_content !== undefined && updated.line === undefined) {
        updated.line = updated.line_content;
      }
      if (updated.line !== undefined && updated.line_content === undefined) {
        updated.line_content = updated.line;
      }
      return updated;
    }),
  );
}

export const {
  useListProjectDirQuery,
  useLazyListProjectDirQuery,
  useReadProjectFileQuery,
  useLazyReadProjectFileQuery,
  useCreateProjectFileMutation,
  useCreateProjectDirMutation,
  useMoveProjectPathMutation,
  useDeleteProjectPathMutation,
  useWriteProjectFileMutation,
  useBatchWriteProjectFilesMutation,
  useQuickOpenProjectFilesQuery,
  useLazyQuickOpenProjectFilesQuery,
  useSearchProjectFilesQuery,
  useLazySearchProjectFilesQuery,
  useSearchInstanceFilesQuery,
  useLazySearchInstanceFilesQuery,
} = projectFsApi;

// ---- Multi-scope search orchestration & deduplication helpers ----------------

export {
  normalizeFsPath,
  deduplicateSearchScopes,
  deduplicateScopeResultsByRoot,
  globToRegExp,
  matchesFilePattern,
  transformSearchQuery,
} from '../../search/scopedSearchLogic';

import {
  deduplicateSearchScopes,
  deduplicateScopeResultsByRoot,
  transformSearchQuery,
  matchesFilePattern,
  normalizeFsPath,
} from '../../search/scopedSearchLogic';

/**
 * Orchestrates multi-scope concurrent searches across deduplicated project,
 * task chain, and agent run directories.
 */
export async function orchestrateMultiScopeSearch(
  options: MultiScopeSearchOptions
): Promise<MultiScopeSearchResult> {
  const {
    query,
    scopes,
    caseSensitive = false,
    wholeWord = false,
    regex = false,
    includePattern = '',
    limitPerScope = 100,
  } = options;

  if (!query.trim() || scopes.length === 0) {
    return {
      scopesSearched: [],
      scopesDeduplicatedOut: [],
      matches: [],
      totalMatches: 0,
      totalFiles: 0,
      isTruncated: false,
      errors: [],
    };
  }

  const { activeScopes, deduplicatedOut } = deduplicateSearchScopes(scopes);
  const backendQuery = transformSearchQuery(query, { regex, wholeWord });

  const errors: Array<{ scopeId: string; scopeLabel: string; error: string }> = [];
  const allMatches: ScopedSearchMatch[] = [];
  let isTruncated = false;

  type ScopeExecutionResult = {
    scope: FsSearchScope;
    root: string;
    matches: FsSearchMatch[];
  };
  const executionResults: ScopeExecutionResult[] = [];

  const searchPromises = activeScopes.map(async (scope) => {
    try {
      const qs = new URLSearchParams();
      if (scope.scopeArgs.bridgeId && !scope.scopeArgs.agentInstanceId) {
        qs.set('bridge_id', scope.scopeArgs.bridgeId);
      }
      qs.set('query', backendQuery);
      if (caseSensitive) qs.set('case_sensitive', 'true');
      qs.set('limit', String(limitPerScope));

      const endpoint = `${base(scope.scopeArgs)}/search?${qs.toString()}`;
      const data = (await cookieJsonFetch(endpoint)) as FsSearchResult;

      if (!data || !data.ok) {
        if (data?.error?.message) {
          errors.push({ scopeId: scope.id, scopeLabel: scope.label, error: data.error.message });
        }
        return;
      }

      if (data.truncated) {
        isTruncated = true;
      }

      const canonicalRoot = normalizeFsPath(data.root || scope.path || '');
      executionResults.push({
        scope: { ...scope, path: canonicalRoot || scope.path },
        root: canonicalRoot,
        matches: data.matches || [],
      });
    } catch (err: any) {
      errors.push({
        scopeId: scope.id,
        scopeLabel: scope.label,
        error: String(err?.message || err),
      });
    }
  });

  await Promise.all(searchPromises);

  // Post-response deduplication using canonical data.root returned by backend
  const { activeResults, subsumedScopes } = deduplicateScopeResultsByRoot(executionResults);

  const finalSearchedScopes: FsSearchScope[] = [];
  const finalDeduplicatedOut: FsSearchScope[] = [...deduplicatedOut, ...subsumedScopes];
  const seenMatchKeys = new Set<string>();

  for (const r of activeResults) {
    finalSearchedScopes.push(r.scope);
    const bridge = (r.scope.bridgeId || 'local').trim();

    for (const m of r.matches) {
      if (!matchesFilePattern(m.path, includePattern)) {
        continue;
      }
      const normRel = normalizeFsPath(m.path);
      const matchKey = r.root
        ? `${bridge}::${r.root}/${normRel}:${m.line_number}:${m.column}`
        : `${bridge}::${r.scope.id}::${normRel}:${m.line_number}:${m.column}`;

      if (seenMatchKeys.has(matchKey)) {
        continue;
      }
      seenMatchKeys.add(matchKey);

      allMatches.push({
        ...m,
        scopeId: r.scope.id,
        scopeLabel: r.scope.label,
        scopeKind: r.scope.kind,
        scopeArgs: r.scope.scopeArgs,
      });
    }
  }

  const matchedFiles = new Set(allMatches.map((m) => `${m.scopeId}::${m.path}`));

  return {
    scopesSearched: finalSearchedScopes,
    scopesDeduplicatedOut: finalDeduplicatedOut,
    matches: allMatches,
    totalMatches: allMatches.length,
    totalFiles: matchedFiles.size,
    isTruncated,
    errors,
  };
}
