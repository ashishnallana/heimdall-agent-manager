// Project-scoped VCS endpoints (VCS Integration feature — REQ-VCS-8/9).
//
// Project-scoped Hub wrappers that resolve (project_id -> bridge_id, root_path)
// server-side and relay a read-only vcs_* WS command to the owning bridge, mirroring
// projectFs.ts. All four backing commands are read-only; the UI uses three of them:
//
//   GET /api/v1/projects/{projectId}/vcs/capabilities  -> vcs_capabilities
//   GET /api/v1/projects/{projectId}/vcs/files          -> vcs_files (?cursor=&limit=)
//   GET /api/v1/projects/{projectId}/vcs/diff           -> vcs_diff  (?file=&cursor=&limit=)
//
// The bridge result JSON is returned verbatim by the hub, so these types mirror the
// bridge serialization in src/bridge/vcs_api.odin exactly. UI cache is keyed by
// (projectId, bridgeId[, file]) so switching project/bridge only refetches what changed.

import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';
import { getActiveVaultKey } from '../../utils/vaultContent';
import { sealFsWriteContent } from '../../utils/vaultCrypto';
import { resolveFsWriteRoot } from './projectFs';

// ---- Contract types (mirror the bridge vcs_* result JSON exactly) -----------

// Shared trailing error object on every vcs_* result (empty code/message on success).
export type VcsError = { code: string; message: string };

export type VcsCapabilities = {
  ok: boolean;
  provider: string;
  supports_staging: boolean;
  supports_amend?: boolean;
  supports_upload?: boolean;
  supports_sync?: boolean;
  upload_label?: string;
  sync_label?: string;
  // Redesign fields (TASK-3): how the provider stages, how it commits, and which
  // write actions the VCS panel may offer. ok/error retained for existing callers.
  staging_model: 'index' | 'none';
  commit_model: 'branch' | 'revision';
  supported_actions: string[];
  error: VcsError;
};

export type VcsStatus = {
  ok: boolean;
  provider: string;
  branch: string;
  remote: string;
  ahead: number;
  behind: number;
  is_clean: boolean;
  error: VcsError;
};

export type VcsFileStatus = 'added' | 'modified' | 'deleted' | 'renamed' | 'untracked';

export type VcsChangedFile = {
  path: string;
  status: VcsFileStatus;
  staged: boolean;
  additions: number;
  deletions: number;
};

export type VcsFilesResult = {
  ok: boolean;
  files: VcsChangedFile[];
  next_cursor: string | null;
  has_more: boolean;
  error: VcsError;
};

export type VcsDiffLine = { op: string; text: string };

export type VcsDiffHunk = {
  old_start: number;
  old_len: number;
  new_start: number;
  new_len: number;
  lines: VcsDiffLine[];
};

export type VcsDiffResult = {
  ok: boolean;
  file: string;
  hunks: VcsDiffHunk[];
  next_cursor: string | null;
  has_more: boolean;
  error: VcsError;
};

// Commit log entry (one revision). Mirrors the bridge vcs_log serialization.
export type VcsLogEntry = {
  hash: string;
  short_hash: string;
  subject: string;
  author: string;
  date: string;
  cl_number?: string;
  review_status?: string;
};

// A named workspace/worktree the provider exposes.
export type VcsWorkspace = {
  path: string;
  label: string;
  is_current: boolean;
  is_locked: boolean;
};

export type VcsLogResult = {
  ok: boolean;
  entries: VcsLogEntry[];
  has_more: boolean;
  next_cursor?: string;
};

export type VcsWorkspacesResult = {
  ok: boolean;
  workspaces: VcsWorkspace[];
};

// One changed file in the commit-diff file-list mode (list_files=true). Mirrors the
// bridge vcs_commit_diff serializer's per-file object (path/status/additions/deletions).
export type VcsCommitDiffFile = {
  path: string;
  status: VcsFileStatus;
  additions: number;
  deletions: number;
};

// Commit-diff response in file-list mode: a flat list of changed files between two
// refs, for the Log tab's file selector (no hunks, no pagination).
export type VcsCommitDiffFilesResult = {
  ok: boolean;
  list_files: true;
  base_ref: string;
  head_ref: string;
  files: VcsCommitDiffFile[];
  error?: VcsError;
};

// ---- Cache key helpers ------------------------------------------------------

// Tag id for a project's VCS data. Keyed by (projectId, bridgeId[, suffix]) so a
// different project/bridge (or file diff) gets its own cache entry.
function vcsTagId(projectId: string, bridgeId: string, suffix = ''): string {
  return `${projectId}::${bridgeId}::${suffix}`;
}

// ---- Arg types --------------------------------------------------------------

type CapabilitiesArgs = { projectId: string; bridgeId?: string };
type FilesArgs = { projectId: string; bridgeId?: string; cursor?: string | null; limit?: number };
type DiffArgs = { projectId: string; bridgeId?: string; file: string; cursor?: string | null; limit?: number };
type LogArgs = { projectId: string; bridgeId?: string; cursor?: string | null; limit?: number; worktree_path?: string };
type CommitDiffArgs = {
  projectId: string;
  bridgeId?: string;
  base_ref: string;
  head_ref: string;
  file?: string;
  cursor?: string | null;
  worktree_path?: string;
};
type CommitDiffFilesArgs = {
  projectId: string;
  bridgeId?: string;
  base_ref: string;
  head_ref?: string;
  worktree_path?: string;
};
type WorkspacesArgs = { projectId: string; bridgeId?: string; worktree_path?: string };
// Write-operation args (stage/unstage/revert): all take a single file path and an
// optional worktree_path.
type VcsFileMutationArgs = { projectId: string; bridgeId?: string; file: string; worktree_path?: string };
// Save (editor write): a file path plus the full buffer text.
type VcsSaveFileArgs = { projectId: string; bridgeId?: string; file: string; content: string; worktree_path?: string };
// Commit: the staged changes are committed with `message`.
type CommitArgs = { projectId: string; bridgeId?: string; message: string; amend?: boolean; worktree_path?: string };
// Repo-level mutations (upload/sync): target the whole repository.
type VcsRepoMutationArgs = { projectId: string; bridgeId?: string; worktree_path?: string };
type VcsMutationResult = { ok: boolean; error?: VcsError };

function base(projectId: string): string {
  return `/projects/${encodeURIComponent(projectId)}/vcs`;
}

export const projectVcsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    // Detect the VCS provider at the project root (drives the "Changes" tab
    // visibility). ok=false / empty provider => no supported VCS.
    getVcsCapabilities: build.query<VcsCapabilities, CapabilitiesArgs>({
      queryFn: async ({ projectId, bridgeId = '' }) => {
        try {
          const qs = new URLSearchParams();
          // Disambiguate which bridge's project path to use (see projectFs.ts): a
          // project may be configured on multiple bridges, so pass the conversation's
          // bridge_id to resolve THIS bridge's path.
          if (bridgeId) qs.set('bridge_id', bridgeId);
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base(projectId)}/capabilities${suffix}`);
          return { data: data as VcsCapabilities };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'capabilities') },
      ],
    }),

    // Paginated list of changed files. Fetched lazily and stitched in the component,
    // so we don't key the cache by cursor.
    listVcsFiles: build.query<VcsFilesResult, FilesArgs>({
      queryFn: async ({ projectId, bridgeId = '', cursor = null, limit }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (cursor) qs.set('cursor', cursor);
          if (limit != null) qs.set('limit', String(limit));
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base(projectId)}/files${suffix}`);
          return { data: data as VcsFilesResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'files') },
      ],
    }),

    // Paginated diff hunks for a single changed file. Pages are fetched lazily and
    // appended in the component, so the cache is keyed by (project, bridge, file) —
    // not by cursor.
    getVcsDiff: build.query<VcsDiffResult, DiffArgs>({
      queryFn: async ({ projectId, bridgeId = '', file, cursor = null, limit }) => {
        try {
          const qs = new URLSearchParams({ file });
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (cursor) qs.set('cursor', cursor);
          if (limit != null) qs.set('limit', String(limit));
          const data = await cookieJsonFetch(`${base(projectId)}/diff?${qs.toString()}`);
          return { data: data as VcsDiffResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '', file }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, `diff::${file}`) },
      ],
    }),

    // Live VCS status (branch, remote, ahead, behind, is_clean).
    getProjectVcsStatus: build.query<VcsStatus, { projectId: string; bridgeId?: string } | string>({
      queryFn: async (arg) => {
        const projectId = typeof arg === 'string' ? arg : arg.projectId;
        const bridgeId = typeof arg === 'string' ? '' : (arg.bridgeId || '');
        if (!projectId) {
          return { data: { ok: false, provider: '', branch: '', remote: '', ahead: 0, behind: 0, is_clean: true, error: { code: 'no_project', message: 'No project ID' } } };
        }
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base(projectId)}/status${suffix}`);
          return { data: data as VcsStatus };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, arg) => {
        const projectId = typeof arg === 'string' ? arg : arg.projectId;
        const bridgeId = typeof arg === 'string' ? '' : (arg.bridgeId || '');
        return [
          { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'status') },
        ];
      },
    }),

    // Paginated commit log. Pages are stitched in the component, so the cache is
    // keyed by (project, bridge[, worktree]) — not by cursor.
    listVcsLog: build.query<VcsLogResult, LogArgs>({
      queryFn: async ({ projectId, bridgeId = '', cursor = null, limit, worktree_path }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (cursor) qs.set('cursor', cursor);
          if (limit != null) qs.set('limit', String(limit));
          if (worktree_path) qs.set('worktree_path', worktree_path);
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base(projectId)}/log${suffix}`);
          return { data: data as VcsLogResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '', worktree_path }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, `log::${worktree_path || ''}`) },
      ],
    }),

    // Diff between two refs (base_ref..head_ref), optionally scoped to one file.
    // Reuses the VcsDiffResult shape from the single-file working-tree diff.
    getVcsCommitDiff: build.query<VcsDiffResult, CommitDiffArgs>({
      queryFn: async ({ projectId, bridgeId = '', base_ref, head_ref, file, cursor = null, worktree_path }) => {
        try {
          const qs = new URLSearchParams({ base_ref, head_ref });
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (file) qs.set('file', file);
          if (cursor) qs.set('cursor', cursor);
          if (worktree_path) qs.set('worktree_path', worktree_path);
          const data = await cookieJsonFetch(`${base(projectId)}/commit-diff?${qs.toString()}`);
          return { data: data as VcsDiffResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '', base_ref, head_ref, file }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, `commit-diff::${base_ref}..${head_ref}::${file || ''}`) },
      ],
    }),

    // Commit-diff in file-list mode (list_files=true): the flat list of files changed
    // between two refs, for the Log tab's file selector. head_ref omitted/"WORKDIR"
    // compares base_ref to the working tree. Not paginated (no cursor/limit).
    listCommitDiffFiles: build.query<VcsCommitDiffFilesResult, CommitDiffFilesArgs>({
      queryFn: async ({ projectId, bridgeId = '', base_ref, head_ref, worktree_path }) => {
        try {
          const qs = new URLSearchParams();
          qs.set('list_files', 'true');
          qs.set('base_ref', base_ref);
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (head_ref) qs.set('head_ref', head_ref);
          if (worktree_path) qs.set('worktree_path', worktree_path);
          const data = await cookieJsonFetch(`${base(projectId)}/commit-diff?${qs.toString()}`);
          return { data: data as VcsCommitDiffFilesResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'commit-diff-files') },
      ],
    }),

    // Workspaces/worktrees the provider exposes.
    listVcsWorkspaces: build.query<VcsWorkspacesResult, WorkspacesArgs>({
      queryFn: async ({ projectId, bridgeId = '', worktree_path }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (worktree_path) qs.set('worktree_path', worktree_path);
          const suffix = qs.toString() ? `?${qs.toString()}` : '';
          const data = await cookieJsonFetch(`${base(projectId)}/workspaces${suffix}`);
          return { data: data as VcsWorkspacesResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId, bridgeId = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'workspaces') },
      ],
    }),

    // Stage one file (git add / equivalent). Invalidates the changed-files list so
    // the panel refetches staged/unstaged state after the write.
    stageVcsFile: build.mutation<VcsMutationResult, VcsFileMutationArgs>({
      queryFn: async ({ projectId, bridgeId = '', file, worktree_path }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (worktree_path) qs.set('worktree_path', worktree_path);
          const url = `${base(projectId)}/stage${qs.size ? `?${qs}` : ''}`;
          const data = await cookieMutation(url, 'POST', { file });
          return { data: data as VcsMutationResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, bridgeId = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'files') },
      ],
    }),

    // Unstage one file (git reset / equivalent). Invalidates the changed-files list.
    unstageVcsFile: build.mutation<VcsMutationResult, VcsFileMutationArgs>({
      queryFn: async ({ projectId, bridgeId = '', file, worktree_path }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (worktree_path) qs.set('worktree_path', worktree_path);
          const url = `${base(projectId)}/unstage${qs.size ? `?${qs}` : ''}`;
          const data = await cookieMutation(url, 'POST', { file });
          return { data: data as VcsMutationResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, bridgeId = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'files') },
      ],
    }),

    // Revert one file's working-tree changes. Invalidates the changed-files list.
    revertVcsFile: build.mutation<VcsMutationResult, VcsFileMutationArgs>({
      queryFn: async ({ projectId, bridgeId = '', file, worktree_path }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (worktree_path) qs.set('worktree_path', worktree_path);
          const url = `${base(projectId)}/revert${qs.size ? `?${qs}` : ''}`;
          const data = await cookieMutation(url, 'POST', { file });
          return { data: data as VcsMutationResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, bridgeId = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'files') },
      ],
    }),

    // Save one file's full text (editor write / Ctrl+S). Invalidates the changed-
    // files list so the panel refetches add/del counts and staged/unstaged state.
    saveVcsFile: build.mutation<VcsMutationResult, VcsSaveFileArgs>({
      queryFn: async ({ projectId, bridgeId = '', file, content, worktree_path }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (worktree_path) qs.set('worktree_path', worktree_path);
          const url = `${base(projectId)}/save-file${qs.size ? `?${qs}` : ''}`;
          // The buffer is sealed for the target bridge, the repo root it writes under
          // (a selected worktree, else the project root the bridge reports) and this
          // exact file path (finding N4 + P4 root binding; the bridge writes it through
          // the same check as fs writes).
          const activeKey = getActiveVaultKey();
          if (!activeKey) throw new Error('Vault key unavailable: file content cannot be encrypted');
          if (!bridgeId) throw new Error('No bridge selected for this save');
          const root = worktree_path || await resolveFsWriteRoot({ projectId }, bridgeId);
          const sealed = await sealFsWriteContent(content, bridgeId, root, file.trim(), activeKey);
          const data = await cookieMutation(url, 'POST', { file, content: sealed });
          return { data: data as VcsMutationResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, bridgeId = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'files') },
      ],
    }),

    // Commit the staged changes with a message. worktree_path (when present) rides as a
    // query param so the hub's vcs_workspaces whitelist guard can validate it, matching
    // the other write mutations; the body carries only the message. Invalidates the
    // changed-files list so the panel refetches clean state after the commit.
    commitVcs: build.mutation<VcsMutationResult, CommitArgs>({
      queryFn: async ({ projectId, bridgeId = '', message, amend = false, worktree_path }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (worktree_path) qs.set('worktree_path', worktree_path);
          const url = `${base(projectId)}/commit${qs.size ? `?${qs}` : ''}`;
          const data = await cookieMutation(url, 'POST', { message, amend });
          return { data: data as VcsMutationResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, bridgeId = '' }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'files') },
      ],
    }),

    // Upload current branch/chain of commits to Critique / remote.
    uploadVcs: build.mutation<VcsMutationResult, VcsRepoMutationArgs>({
      queryFn: async ({ projectId, bridgeId = '', worktree_path }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (worktree_path) qs.set('worktree_path', worktree_path);
          const url = `${base(projectId)}/upload${qs.size ? `?${qs}` : ''}`;
          const data = await cookieMutation(url, 'POST', {});
          return { data: data as VcsMutationResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, bridgeId = '', worktree_path }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'files') },
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'status') },
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, `log::${worktree_path || ''}`) },
      ],
    }),

    // Sync current branch/worktree with upstream head.
    syncVcs: build.mutation<VcsMutationResult, VcsRepoMutationArgs>({
      queryFn: async ({ projectId, bridgeId = '', worktree_path }) => {
        try {
          const qs = new URLSearchParams();
          if (bridgeId) qs.set('bridge_id', bridgeId);
          if (worktree_path) qs.set('worktree_path', worktree_path);
          const url = `${base(projectId)}/sync${qs.size ? `?${qs}` : ''}`;
          const data = await cookieMutation(url, 'POST', {});
          return { data: data as VcsMutationResult };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { projectId, bridgeId = '', worktree_path }) => [
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'files') },
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, 'status') },
        { type: 'ProjectVcs' as const, id: vcsTagId(projectId, bridgeId, `log::${worktree_path || ''}`) },
      ],
    }),
  }),
});

export const {
  useGetVcsCapabilitiesQuery,
  useLazyGetVcsCapabilitiesQuery,
  useListVcsFilesQuery,
  useLazyListVcsFilesQuery,
  useGetVcsDiffQuery,
  useLazyGetVcsDiffQuery,
  useGetProjectVcsStatusQuery,
  useLazyGetProjectVcsStatusQuery,
  useListVcsLogQuery,
  useLazyListVcsLogQuery,
  useGetVcsCommitDiffQuery,
  useLazyGetVcsCommitDiffQuery,
  useListCommitDiffFilesQuery,
  useLazyListCommitDiffFilesQuery,
  useListVcsWorkspacesQuery,
  useLazyListVcsWorkspacesQuery,
  useStageVcsFileMutation,
  useUnstageVcsFileMutation,
  useRevertVcsFileMutation,
  useSaveVcsFileMutation,
  useCommitVcsMutation,
  useUploadVcsMutation,
  useSyncVcsMutation,
} = projectVcsApi;
