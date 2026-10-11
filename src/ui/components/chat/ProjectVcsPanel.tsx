// ProjectVcsPanel — the dedicated "VCS" right-sidebar tab (REQ-VCS-UI-2/3/4/5/6).
//
// A Lazygit-style two-pane layout:
//   Left pane  (≈32%): "Changes" | "Log" sub-tabs.
//       Changes → collapsible Staged / Unstaged / Untracked sections (each row =
//                 filename + status badge + ±counts + per-row write actions), a
//                 Refresh + Commit footer, and (when supported) a Workspaces list.
//       Log     → infinite-scroll commit list; clicking a commit selects it as the
//                 diff base for the right pane.
//   Right pane (≈68%): Changes → clicking a file immediately loads its Monaco
//                 editor inline (editable diff for modified/staged, editable single
//                 editor for added/untracked, read-only for deleted); Ctrl+S / Save
//                 writes the buffer back via saveVcsFile. Log → a two-ref picker and
//                 the commit diff between them.
//
// Capability-driven visibility: the panel NEVER branches on the provider name. Every
// gated feature is decided solely by capabilities.supported_actions (stage / unstage
// / revert / log / workspaces) plus commit_model for the Commit button.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Editor, { DiffEditor, type OnMount, type DiffOnMount, type EditorProps, type DiffEditorProps } from '@monaco-editor/react';

import {
  useGetVcsCapabilitiesQuery,
  useListVcsFilesQuery,
  useGetVcsDiffQuery,
  useLazyListVcsLogQuery,
  useLazyGetVcsCommitDiffQuery,
  useLazyListCommitDiffFilesQuery,
  useListVcsWorkspacesQuery,
  useStageVcsFileMutation,
  useUnstageVcsFileMutation,
  useRevertVcsFileMutation,
  useSaveVcsFileMutation,
  useCommitVcsMutation,
  useUploadVcsMutation,
  useSyncVcsMutation,
  type VcsChangedFile,
  type VcsFileStatus,
  type VcsLogEntry,
  type VcsDiffHunk,
  type VcsCommitDiffFile,
} from '../../api/endpoints/projectVcs';
import { useReadProjectFileQuery, useDeleteProjectPathMutation } from '../../api/endpoints/projectFs';
import { useTheme } from '../../store/themeSlice';
import { languageForFile } from '../../utils/codeHighlight';
import MonacoDiffViewer from './MonacoDiffViewer';
import Icon from '../Icon';

function str(v: any): string {
  return String(v ?? '').trim();
}

// Max bytes to pull for the editable buffer in one request. Files larger than this
// come back truncated; we then fall back to a read-only view so a Save can never
// write back a truncated buffer and drop the file's tail.
const EDIT_READ_LIMIT = 2_000_000;

// reconstructOriginal rebuilds the FULL pre-change text of a file from its full
// current text plus the diff hunks, so the diff editor's read-only "original" side
// has complete context (not just the ±3 lines git ships in each hunk). Walks the
// modified lines, substituting the old-side lines inside each hunk region: context
// (" ") lines appear on both sides, "-" lines are original-only, "+" lines are
// modified-only. Must be fed the pristine loaded buffer (baseline), not the live
// edit buffer, or the hunk offsets desync.
function reconstructOriginal(modifiedText: string, hunks: VcsDiffHunk[]): string {
  if (!hunks.length) return modifiedText;
  const mod = modifiedText.split('\n');
  const orig: string[] = [];
  let mi = 0;
  const sorted = [...hunks].sort((a, b) => (a.new_start || 0) - (b.new_start || 0));
  for (const h of sorted) {
    const start0 = Math.max(0, (h.new_start || 1) - 1);
    while (mi < start0 && mi < mod.length) { orig.push(mod[mi]); mi += 1; }
    for (const l of h.lines || []) {
      if (l.op === ' ') { orig.push(l.text); mi += 1; }
      else if (l.op === '-') { orig.push(l.text); }
      else if (l.op === '+') { mi += 1; }
    }
  }
  while (mi < mod.length) { orig.push(mod[mi]); mi += 1; }
  return orig.join('\n');
}

// Map our codeHighlight language ids onto Monaco's language ids.
function monacoLanguage(filePath: string): string {
  const lang = languageForFile(filePath);
  const map: Record<string, string> = {
    bash: 'shell', zsh: 'shell', sh: 'shell', fish: 'shell', docker: 'dockerfile',
    yml: 'yaml', js: 'javascript', ts: 'typescript', tsx: 'typescript', jsx: 'javascript',
  };
  return map[lang] || lang || 'plaintext';
}

const STATUS_BADGE: Record<VcsFileStatus, { label: string; cls: string }> = {
  added: { label: 'A', cls: 'bg-success-soft text-success' },
  modified: { label: 'M', cls: 'bg-warning-soft text-warning' },
  deleted: { label: 'D', cls: 'bg-danger-soft text-danger' },
  renamed: { label: 'R', cls: 'bg-info-soft text-info' },
  untracked: { label: 'U', cls: 'bg-neutral-soft text-muted' },
};

function statusBadge(status: string): { label: string; cls: string } {
  return STATUS_BADGE[status as VcsFileStatus] ?? { label: '?', cls: 'bg-neutral-soft text-muted' };
}

function ChevronIcon({ collapsed }: { collapsed: boolean }) {
  return (
    <svg width="10" height="10" viewBox="0 0 10 10" className="shrink-0 text-muted"
      style={{ transform: collapsed ? 'rotate(-90deg)' : 'none', transition: 'transform 0.1s' }}>
      <path d="M2 3l3 4 3-4" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

type SaveFeedback = { type: 'success' | 'error'; message: string } | null;

export type ProjectVcsPanelProps = {
  projectId: string;
  experimentEnabled: boolean;
  bridgeId?: string;
  onClose?: () => void;
  isMobile?: boolean;
  debugPrefix?: string;
  // Invoked when an untracked directory row is opened from the Changes tab. The host
  // switches the sidebar to the Files explorer (directories have no diffable content).
  onOpenDirectory?: (path: string) => void;
  openFilePath?: string | null;
  onFileOpened?: () => void;
};

export default function ProjectVcsPanel({
  projectId,
  experimentEnabled,
  bridgeId = '',
  debugPrefix = 'project-vcs',
  isMobile = false,
  onOpenDirectory,
  openFilePath,
  onFileOpened,
}: ProjectVcsPanelProps) {
  // On a narrow (mobile) panel we show one column at a time — either the list or the
  // diff — toggled by activePane, instead of the side-by-side two-pane layout.
  const isSinglePane = isMobile;
  // ---- Capabilities (drives every feature gate) -----------------------------
  const capsQ = useGetVcsCapabilitiesQuery(
    { projectId, bridgeId },
    { skip: !experimentEnabled || !projectId },
  );
  const caps = capsQ.data;
  const hasVcs = Boolean(caps?.ok && str(caps?.provider));
  const supportedActions = caps?.supported_actions ?? [];
  const can = useCallback((action: string) => supportedActions.includes(action), [supportedActions]);

  const uploadLabel = caps?.upload_label || 'Upload';
  const uploadBusyLabel = uploadLabel === 'Push' ? 'Pushing…' : (uploadLabel === 'Upload to Critique' ? 'Uploading…' : `${uploadLabel}ing…`);
  const syncLabel = caps?.sync_label || 'Sync';
  const syncBusyLabel = syncLabel === 'Pull' ? 'Pulling…' : (syncLabel === 'Sync with Head' ? 'Syncing…' : `${syncLabel}ing…`);

  // ---- Panel state ----------------------------------------------------------
  const [activeSubTab, setActiveSubTab] = useState<'changes' | 'log'>('changes');
  // Single-pane column shown on mobile: the list of files/commits, or the diff.
  const [activePane, setActivePane] = useState<'list' | 'diff'>('list');
  const [selectedFile, setSelectedFile] = useState<VcsChangedFile | null>(null);
  // Files checked in the Changes tab for bulk stage/unstage/revert/track/delete.
  const [selectedFiles, setSelectedFiles] = useState<Set<string>>(new Set());
  const [selectedCommit, setSelectedCommit] = useState<VcsLogEntry | null>(null);
  // Which file in the commit's changed-file list is open in the Monaco pane (Log tab).
  const [selectedCommitFile, setSelectedCommitFile] = useState<string | null>(null);
  const [activeWorktreePath, setActiveWorktreePath] = useState<string | null>(null);
  const worktreeArg = activeWorktreePath ?? undefined;

  // Collapsible sections (Changes) + Workspaces.
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const toggleSection = useCallback((key: string) => {
    setCollapsed((prev) => ({ ...prev, [key]: !prev[key] }));
  }, []);

  // ---- Changed files --------------------------------------------------------
  const filesQ = useListVcsFilesQuery(
    { projectId, bridgeId, limit: 500 },
    { skip: !experimentEnabled || !projectId || !hasVcs },
  );
  const files: VcsChangedFile[] = filesQ.data?.files ?? [];

  const staged = useMemo(() => files.filter((f) => f.staged), [files]);
  const unstaged = useMemo(() => files.filter((f) => !f.staged && f.status !== 'untracked'), [files]);
  const untracked = useMemo(() => files.filter((f) => f.status === 'untracked'), [files]);

  // Keep the right-pane selection valid as the list refreshes after a write.
  useEffect(() => {
    if (!selectedFile) return;
    if (!files.some((f) => f.path === selectedFile.path && f.staged === selectedFile.staged)) {
      const stillThere = files.find((f) => f.path === selectedFile.path);
      setSelectedFile(stillThere ?? null);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [files]);

  // Auto-select file when requested via openFilePath prop
  useEffect(() => {
    if (!openFilePath || files.length === 0) return;
    const match = files.find((f) => f.path === openFilePath);
    if (match) {
      setSelectedFile(match);
      setActiveSubTab('changes');
      if (isMobile) {
        setActivePane('diff');
      }
      onFileOpened?.();
    }
  }, [openFilePath, files, isMobile, onFileOpened]);

  // ---- Write mutations ------------------------------------------------------
  const [stageFile, stageState] = useStageVcsFileMutation();
  const [unstageFile, unstageState] = useUnstageVcsFileMutation();
  const [revertFile, revertState] = useRevertVcsFileMutation();
  const [saveVcsFile] = useSaveVcsFileMutation();
  // Untracked files have no VCS history to revert; deleting one is a plain
  // filesystem remove via the project FS endpoint (VcsFiles isn't in its tags, so
  // we refetch the changed-files list ourselves after a delete).
  const [deleteProjectPath, deleteState] = useDeleteProjectPathMutation();
  const [commitVcs, commitState] = useCommitVcsMutation();
  const [uploadVcs, uploadState] = useUploadVcsMutation();
  const [syncVcs, syncState] = useSyncVcsMutation();
  const busyWrite = stageState.isLoading || unstageState.isLoading || revertState.isLoading || deleteState.isLoading || uploadState.isLoading || syncState.isLoading;

  // ---- Commit log (lazy, accumulated) ---------------------------------------
  const [triggerLog] = useLazyListVcsLogQuery();
  const [logEntries, setLogEntries] = useState<VcsLogEntry[]>([]);
  const [logCursor, setLogCursor] = useState<string | null>(null);
  const [logHasMore, setLogHasMore] = useState(false);
  const [logLoading, setLogLoading] = useState(false);
  const [logError, setLogError] = useState('');

  const loadLog = useCallback(async (opts?: { append?: boolean }) => {
    if (!experimentEnabled || !projectId || !can('log')) return;
    const append = Boolean(opts?.append);
    setLogLoading(true);
    setLogError('');
    try {
      const res = await triggerLog({
        projectId, bridgeId, limit: 100,
        cursor: append ? logCursor : null,
        worktree_path: worktreeArg,
      }).unwrap();
      if (!res.ok) { setLogError('Could not read commit log'); return; }
      setLogEntries((prev) => (append ? [...prev, ...(res.entries || [])] : (res.entries || [])));
      setLogHasMore(Boolean(res.has_more));
      setLogCursor(res.next_cursor ?? null);
    } catch (e: any) {
      setLogError(str(e?.error || e?.message) || 'Could not read commit log');
    } finally {
      setLogLoading(false);
    }
  }, [experimentEnabled, projectId, bridgeId, can, triggerLog, logCursor, worktreeArg]);

  // (Re)load the log when the Log tab opens or the active worktree changes.
  useEffect(() => {
    if (activeSubTab === 'log' && can('log')) void loadLog();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeSubTab, activeWorktreePath, hasVcs]);

  // ---- Commit ---------------------------------------------------------------
  const [commitMessage, setCommitMessage] = useState('');
  const [commitError, setCommitError] = useState('');
  const [isAmend, setIsAmend] = useState(false);

  const onToggleAmend = useCallback(async (checked: boolean) => {
    setIsAmend(checked);
    if (!experimentEnabled) return;
    if (checked && !commitMessage.trim()) {
      if (logEntries.length > 0 && logEntries[0]?.subject) {
        setCommitMessage(logEntries[0].subject);
      } else if (can('log') && projectId) {
        try {
          const res = await triggerLog({ projectId, bridgeId, limit: 1, worktree_path: worktreeArg }).unwrap();
          if (res.ok && res.entries && res.entries.length > 0 && res.entries[0].subject) {
            setCommitMessage(res.entries[0].subject);
          }
        } catch {
          // ignore error fetching latest commit message
        }
      }
    }
  }, [experimentEnabled, commitMessage, logEntries, can, projectId, bridgeId, worktreeArg, triggerLog]);

  const handleCommit = useCallback(async () => {
    const msg = commitMessage.trim();
    if (!msg) return;
    setCommitError('');
    try {
      const res = await commitVcs({ projectId, bridgeId, message: msg, amend: isAmend, worktree_path: worktreeArg }).unwrap();
      if (!res.ok) { setCommitError(str(res.error?.message) || 'Commit failed'); return; }
      setCommitMessage('');
      setIsAmend(false);
    } catch (e: any) {
      setCommitError(str(e?.error || e?.message) || 'Commit failed');
    }
  }, [commitVcs, projectId, bridgeId, commitMessage, isAmend, worktreeArg]);

  const [actionError, setActionError] = useState('');

  const handleUpload = useCallback(async () => {
    setActionError('');
    try {
      const res = await uploadVcs({ projectId, bridgeId, worktree_path: worktreeArg }).unwrap();
      if (!res.ok) { setActionError(str(res.error?.message) || `${uploadLabel} failed`); return; }
    } catch (e: any) {
      setActionError(str(e?.error || e?.message) || `${uploadLabel} failed`);
    }
  }, [uploadVcs, projectId, bridgeId, worktreeArg, uploadLabel]);

  const handleSync = useCallback(async () => {
    setActionError('');
    try {
      const res = await syncVcs({ projectId, bridgeId, worktree_path: worktreeArg }).unwrap();
      if (!res.ok) { setActionError(str(res.error?.message) || `${syncLabel} failed`); return; }
    } catch (e: any) {
      setActionError(str(e?.error || e?.message) || `${syncLabel} failed`);
    }
  }, [syncVcs, projectId, bridgeId, worktreeArg, syncLabel]);

  // ---- Checkbox selection helpers (Changes tab bulk actions) ----------------
  const toggleFileSelected = useCallback((path: string) => {
    setSelectedFiles((prev) => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path); else next.add(path);
      return next;
    });
  }, []);
  // Rows a section action targets: the checked rows, or ALL rows when none are checked.
  const sectionTargets = useCallback((rows: VcsChangedFile[]): VcsChangedFile[] => {
    const checked = rows.filter((r) => selectedFiles.has(r.path));
    return checked.length > 0 ? checked : rows;
  }, [selectedFiles]);
  // Apply a per-file action to a section's targets, then drop them from the selection.
  const runSectionAction = useCallback((rows: VcsChangedFile[], action: (path: string) => void) => {
    const targets = sectionTargets(rows);
    targets.forEach((f) => action(f.path));
    setSelectedFiles((prev) => {
      const next = new Set(prev);
      targets.forEach((f) => next.delete(f.path));
      return next;
    });
  }, [sectionTargets]);
  const toggleSectionAll = useCallback((rows: VcsChangedFile[]) => {
    setSelectedFiles((prev) => {
      const allSelected = rows.length > 0 && rows.every((r) => prev.has(r.path));
      const next = new Set(prev);
      if (allSelected) rows.forEach((r) => next.delete(r.path));
      else rows.forEach((r) => next.add(r.path));
      return next;
    });
  }, []);

  const onStage = useCallback((path: string) => {
    void stageFile({ projectId, bridgeId, file: path, worktree_path: worktreeArg });
  }, [stageFile, projectId, bridgeId, worktreeArg]);
  const onUnstage = useCallback((path: string) => {
    void unstageFile({ projectId, bridgeId, file: path, worktree_path: worktreeArg });
  }, [unstageFile, projectId, bridgeId, worktreeArg]);
  const onRevert = useCallback((path: string) => {
    void revertFile({ projectId, bridgeId, file: path, worktree_path: worktreeArg });
  }, [revertFile, projectId, bridgeId, worktreeArg]);
  const onDeleteUntracked = useCallback(async (path: string) => {
    if (typeof window !== 'undefined' && !window.confirm(`Delete untracked file "${path}"? This cannot be undone.`)) return;
    try {
      await deleteProjectPath({ projectId, bridgeId, path }).unwrap();
      setSelectedFile((cur) => (cur?.path === path ? null : cur));
    } finally {
      void filesQ.refetch();
    }
  }, [deleteProjectPath, projectId, bridgeId, filesQ]);


  // ---- Workspaces -----------------------------------------------------------
  const workspacesQ = useListVcsWorkspacesQuery(
    { projectId, bridgeId, worktree_path: worktreeArg },
    { skip: !experimentEnabled || !projectId || !hasVcs || !can('workspaces') },
  );
  const workspaces = workspacesQ.data?.workspaces ?? [];
  const activeWorkspaceLabel = useMemo(() => {
    if (!activeWorktreePath) return '';
    const w = workspaces.find((ws) => ws.path === activeWorktreePath);
    return w?.label || activeWorktreePath;
  }, [activeWorktreePath, workspaces]);

  // ---- Commit-diff (Log right pane; lazy, accumulated) ----------------------
  const [diffBaseRef, setDiffBaseRef] = useState('');
  const [diffHeadRef, setDiffHeadRef] = useState('WORKDIR');
  const [triggerCommitDiff] = useLazyGetVcsCommitDiffQuery();
  const [commitHunks, setCommitHunks] = useState<VcsDiffHunk[]>([]);
  const [commitCursor, setCommitCursor] = useState<string | null>(null);
  const [commitHasMore, setCommitHasMore] = useState(false);
  const [commitDiffLoading, setCommitDiffLoading] = useState(false);
  const [commitDiffError, setCommitDiffError] = useState('');

  // Commit-diff file list (Log left column; loaded via list_files=true, not paginated).
  const [commitDiffFiles, setCommitDiffFiles] = useState<VcsCommitDiffFile[]>([]);
  const [commitDiffFilesLoading, setCommitDiffFilesLoading] = useState(false);
  const [commitDiffFilesError, setCommitDiffFilesError] = useState('');
  const [triggerListCommitDiffFiles] = useLazyListCommitDiffFilesQuery();

  // loadCommitDiff loads (or appends) the per-file hunks for the selected commit file.
  // An explicit opts.file overrides the selectedCommitFile state, so a file click can
  // diff the just-clicked path without waiting for the state update to settle.
  const loadCommitDiff = useCallback(async (opts?: { append?: boolean; file?: string | null }) => {
    if (!experimentEnabled || !projectId || !diffBaseRef) return;
    const append = Boolean(opts?.append);
    const fileArg = opts && 'file' in opts ? opts.file : selectedCommitFile;
    setCommitDiffLoading(true);
    setCommitDiffError('');
    try {
      const res = await triggerCommitDiff({
        projectId, bridgeId,
        base_ref: diffBaseRef,
        head_ref: diffHeadRef || 'WORKDIR',
        file: fileArg ?? undefined,
        cursor: append ? commitCursor : null,
        worktree_path: worktreeArg,
      }).unwrap();
      if (!res.ok) { setCommitDiffError(str(res.error?.message) || 'Could not diff revisions'); return; }
      setCommitHunks((prev) => (append ? [...prev, ...(res.hunks || [])] : (res.hunks || [])));
      setCommitHasMore(Boolean(res.has_more));
      setCommitCursor(res.next_cursor ?? null);
    } catch (e: any) {
      setCommitDiffError(str(e?.error || e?.message) || 'Could not diff revisions');
    } finally {
      setCommitDiffLoading(false);
    }
  }, [experimentEnabled, projectId, bridgeId, diffBaseRef, diffHeadRef, commitCursor, triggerCommitDiff, worktreeArg, selectedCommitFile]);

  // loadCommitDiffFiles loads the flat list of files changed between the two refs.
  const loadCommitDiffFiles = useCallback(async () => {
    if (!experimentEnabled || !projectId || !diffBaseRef) return;
    setCommitDiffFilesLoading(true);
    setCommitDiffFilesError('');
    try {
      const res = await triggerListCommitDiffFiles({
        projectId, bridgeId,
        base_ref: diffBaseRef,
        head_ref: diffHeadRef || 'WORKDIR',
        worktree_path: worktreeArg,
      }).unwrap();
      if (!res.ok) { setCommitDiffFilesError(str(res.error?.message) || 'Could not list files'); setCommitDiffFiles([]); return; }
      setCommitDiffFiles(res.files || []);
    } catch (e: any) {
      setCommitDiffFilesError(str(e?.error || e?.message) || 'Could not list files');
      setCommitDiffFiles([]);
    } finally {
      setCommitDiffFilesLoading(false);
    }
  }, [experimentEnabled, projectId, bridgeId, diffBaseRef, diffHeadRef, triggerListCommitDiffFiles, worktreeArg]);

  // Selecting a commit sets it as the diff base (head defaults to the working copy) and
  // clears any prior file selection + stale file list/hunks.
  const onSelectCommit = useCallback((entry: VcsLogEntry) => {
    setSelectedCommit(entry);
    setDiffBaseRef(entry.hash);
    setDiffHeadRef('WORKDIR');
    setSelectedCommitFile(null);
    setCommitDiffFiles([]);
    setCommitHunks([]);
    setCommitCursor(null);
    setActivePane('diff');
  }, []);

  // When the refs change (and we're on the Log tab), reload the changed-file list and
  // reset the per-file diff selection. The hunk diff loads only once a file is picked.
  useEffect(() => {
    if (activeSubTab === 'log' && diffBaseRef) {
      setSelectedCommitFile(null);
      setCommitHunks([]);
      setCommitCursor(null);
      void loadCommitDiffFiles();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [diffBaseRef, diffHeadRef, activeSubTab]);

  const onSelectFile = useCallback((f: VcsChangedFile) => {
    setSelectedFile(f);
    setActivePane('diff');
  }, []);

  const committableCount = caps?.supports_staging ? staged.length : unstaged.length;
  const hasChanges = isAmend ? true : committableCount > 0;
  const commitDisabled = !hasChanges || !commitMessage.trim() || busyWrite || commitState.isLoading;
  const commitButtonLabel = commitState.isLoading
    ? (isAmend ? 'Amending…' : 'Committing…')
    : isAmend
      ? `Amend Commit${committableCount > 0 ? ` (${committableCount})` : ''}`
      : `Commit${committableCount > 0 ? ` (${committableCount})` : ''}`;

  // ---- Loading / empty states ----------------------------------------------
  const wrapperCls = 'relative flex h-full min-h-0 w-full flex-col bg-surface';

  if (!experimentEnabled) return null;
  if (!projectId) {
    return (
      <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>
        <div className="grid flex-1 place-items-center p-6 text-center text-xs text-muted">
          No project is associated with this conversation.
        </div>
      </div>
    );
  }
  if (capsQ.isLoading || capsQ.isFetching) {
    return (
      <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>
        <div className="grid flex-1 place-items-center p-6 text-center text-xs text-muted">Loading…</div>
      </div>
    );
  }
  if (!hasVcs) {
    return (
      <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>
        <div data-debug-id={`${debugPrefix}-no-vcs`} className="grid flex-1 place-items-center p-6 text-center text-xs text-muted">
          No VCS detected for this project.
        </div>
      </div>
    );
  }

  // ---- Section renderer -----------------------------------------------------
  // Rows carry checkboxes (bulk selection) instead of per-row hover buttons; the
  // section header bar carries a select-all checkbox + the bulk action buttons that
  // apply to the checked rows (or all rows when none are checked).
  const sectionActionCls = 'rounded border border-subtle px-1.5 py-0.5 text-[10px] font-medium text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-50';
  function renderSection(key: string, title: string, rows: VcsChangedFile[]) {
    if (rows.length === 0) return null;
    const isCollapsed = collapsed[key];
    const selCount = rows.filter((r) => selectedFiles.has(r.path)).length;
    const allSelected = selCount === rows.length;
    const someSelected = selCount > 0 && !allSelected;
    const sel = selCount > 0 ? 'selected' : 'all';
    return (
      <div data-debug-id={`${debugPrefix}-section-${key}`} className="border-b border-subtle">
        <div className="flex items-center gap-1.5 border-b border-subtle bg-surface-raised px-2 py-1 text-[11px] font-semibold text-muted">
          <input
            type="checkbox"
            checked={allSelected}
            ref={(el) => { if (el) el.indeterminate = someSelected; }}
            onChange={() => toggleSectionAll(rows)}
            aria-label={`Select all ${title.toLowerCase()}`}
            data-debug-id={`${debugPrefix}-section-selectall-${key}`}
            className="h-3.5 w-3.5 shrink-0 accent-accent"
          />
          <button type="button" onClick={() => toggleSection(key)} className="flex items-center gap-1.5 text-left hover:text-primary">
            <ChevronIcon collapsed={isCollapsed} />
            <span className="uppercase tracking-wide">{title} ({rows.length})</span>
          </button>
          <div className="ml-auto flex items-center gap-1">
            {key === 'staged' && can('unstage') ? (
              <button type="button" disabled={busyWrite} onClick={() => runSectionAction(rows, onUnstage)} className={sectionActionCls} data-debug-id={`${debugPrefix}-bulk-unstage`}>Unstage {sel}</button>
            ) : null}
            {key === 'unstaged' && caps?.supports_staging && can('stage') ? (
              <button type="button" disabled={busyWrite} onClick={() => runSectionAction(rows, onStage)} className={sectionActionCls} data-debug-id={`${debugPrefix}-bulk-stage`}>Stage {sel}</button>
            ) : null}
            {key === 'unstaged' && can('revert') ? (
              <button type="button" disabled={busyWrite} onClick={() => runSectionAction(rows, onRevert)} className={sectionActionCls} data-debug-id={`${debugPrefix}-bulk-revert`}>Revert {sel}</button>
            ) : null}
            {key === 'untracked' && can('stage') ? (
              <button type="button" disabled={busyWrite} onClick={() => runSectionAction(rows, onStage)} className={sectionActionCls} data-debug-id={`${debugPrefix}-bulk-track`}>Track {sel}</button>
            ) : null}
            {key === 'untracked' ? (
              <button type="button" disabled={busyWrite} onClick={() => runSectionAction(rows, (p) => void onDeleteUntracked(p))} className={sectionActionCls} data-debug-id={`${debugPrefix}-bulk-delete`}>Delete {sel}</button>
            ) : null}
          </div>
        </div>
        {!isCollapsed ? (
          <div>
            {rows.map((f) => {
              const badge = statusBadge(f.status);
              const isSel = selectedFile?.path === f.path && selectedFile?.staged === f.staged;
              const isDir = f.path.endsWith('/');
              const bare = isDir ? f.path.slice(0, -1) : f.path;
              const slash = bare.lastIndexOf('/');
              const baseName = (slash >= 0 ? bare.slice(slash + 1) : bare) + (isDir ? '/' : '');
              const dirName = slash >= 0 ? bare.slice(0, slash + 1) : '';
              return (
                <div
                  key={`${f.path}:${f.staged ? 's' : 'u'}`}
                  data-debug-id={`${debugPrefix}-row-${f.path}`}
                  className={`flex items-center gap-2 px-3 py-1 ${isSel ? 'bg-accent/15' : 'hover:bg-neutral-soft'}`}
                >
                  <input
                    type="checkbox"
                    checked={selectedFiles.has(f.path)}
                    onChange={() => toggleFileSelected(f.path)}
                    onClick={(e) => e.stopPropagation()}
                    aria-label={`Select ${f.path}`}
                    data-debug-id={`${debugPrefix}-row-check-${f.path}`}
                    className="h-3.5 w-3.5 shrink-0 accent-accent"
                  />
                  <button
                    type="button"
                    onClick={() => onSelectFile(f)}
                    className="flex min-w-0 flex-1 items-center gap-2 text-left"
                    title={f.path}
                    data-debug-id={`${debugPrefix}-row-select-${f.path}`}
                  >
                    <span className={`grid h-4 w-4 shrink-0 place-items-center rounded text-[9px] font-bold ${badge.cls}`} title={f.status}>
                      {badge.label}
                    </span>
                    <span className="flex min-w-0 flex-1 flex-col" title={f.path}>
                      <span className={`truncate font-mono text-[11px] font-medium ${isSel ? 'text-accent' : 'text-primary'}`}>{baseName}</span>
                      {dirName ? <span className="truncate font-mono text-[10px] text-muted">{dirName}</span> : null}
                    </span>
                    <span className="flex shrink-0 gap-1 font-mono text-[10px]">
                      {f.additions > 0 ? <span className="text-success">+{f.additions}</span> : null}
                      {f.deletions > 0 ? <span className="text-danger">-{f.deletions}</span> : null}
                    </span>
                  </button>
                </div>
              );
            })}
          </div>
        ) : null}
      </div>
    );
  }

  // ---- Render ---------------------------------------------------------------
  return (
    <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>
      {/* Sub-tab row */}
      <div data-debug-id={`${debugPrefix}-subtabs`} className="flex shrink-0 items-center gap-1 border-b border-subtle bg-surface px-2 py-1.5">
        <SubTabButton label="Changes" active={activeSubTab === 'changes'} onClick={() => { setActiveSubTab('changes'); setActivePane('list'); }} debugId={`${debugPrefix}-subtab-changes`} />
        {can('log') ? (
          <SubTabButton label="Log" active={activeSubTab === 'log'} onClick={() => { setActiveSubTab('log'); setActivePane('list'); }} debugId={`${debugPrefix}-subtab-log`} />
        ) : null}
        {(can('sync') || can('pull') || caps?.supports_sync) ? (
          <button
            type="button"
            disabled={syncState.isLoading || busyWrite}
            onClick={() => void handleSync()}
            data-debug-id={`${debugPrefix}-sync-header`}
            title={syncLabel === 'Pull' ? 'Pull latest changes from upstream' : 'Sync with upstream head'}
            className="ml-2 inline-flex items-center gap-1 rounded border border-subtle bg-surface px-2 py-0.5 text-[11px] font-medium text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-50"
          >
            <Icon name="refresh" className={`h-3 w-3 ${syncState.isLoading ? 'animate-spin' : ''}`} />
            <span>{syncState.isLoading ? syncBusyLabel : syncLabel}</span>
          </button>
        ) : null}
        <span className="ml-auto pr-1 text-[11px] text-muted">{caps?.provider}</span>
      </div>

      {/* Active-worktree banner */}
      {activeWorktreePath ? (
        <div data-debug-id={`${debugPrefix}-worktree-banner`} className="flex shrink-0 items-center gap-2 border-b border-info/30 bg-info-soft px-3 py-1 text-[11px] text-info">
          <span className="truncate">Viewing: {activeWorkspaceLabel}</span>
          <button type="button" className="ml-auto rounded px-1 font-medium hover:underline" onClick={() => setActiveWorktreePath(null)}>
            Exit
          </button>
        </div>
      ) : null}

      {/* Two-pane body (single column at a time on mobile, toggled by activePane) */}
      <div className="flex min-h-0 flex-1">
        {/* Left pane — the list of changes / commits */}
        {(!isSinglePane || activePane === 'list') ? (
        <div data-debug-id={`${debugPrefix}-left`} className={`flex min-h-0 flex-col ${isSinglePane ? 'w-full' : 'w-[32%] min-w-[220px] border-r border-subtle'}`}>
          <div className="min-h-0 flex-1 overflow-y-auto">
            {activeSubTab === 'changes' ? (
              <>
                {filesQ.isLoading ? (
                  <div className="p-4 text-center text-xs text-muted">Loading…</div>
                ) : files.length === 0 ? (
                  <div data-debug-id={`${debugPrefix}-changes-empty`} className="p-6 text-center text-xs text-muted">No changes.</div>
                ) : (
                  <>
                    {caps?.supports_staging ? (
                      <>
                        {renderSection('staged', 'Staged', staged)}
                        {renderSection('unstaged', 'Unstaged', unstaged)}
                      </>
                    ) : (
                      renderSection('unstaged', 'Changes', unstaged)
                    )}
                    {renderSection('untracked', 'Untracked', untracked)}
                  </>
                )}
              </>
            ) : (
              <div data-debug-id={`${debugPrefix}-log-list`}>
                {logEntries.length === 0 && logLoading ? (
                  <div className="p-4 text-center text-xs text-muted">Loading…</div>
                ) : logEntries.length === 0 ? (
                  <div className="p-6 text-center text-xs text-muted">{logError || 'No commits.'}</div>
                ) : (
                  logEntries.map((e) => {
                    const isSel = selectedCommit?.hash === e.hash;
                    return (
                      <button
                        key={e.hash}
                        type="button"
                        onClick={() => onSelectCommit(e)}
                        data-debug-id={`${debugPrefix}-log-row-${e.short_hash}`}
                        className={`block w-full border-b border-subtle px-3 py-2 text-left ${isSel ? 'bg-accent/15' : 'hover:bg-neutral-soft'}`}
                      >
                        <div className="flex items-center gap-2">
                          <span className="shrink-0 rounded bg-neutral-soft px-1 font-mono text-[10px] text-accent">{e.short_hash}</span>
                          {e.cl_number ? (
                            <a
                              href={`http://critique/${e.cl_number}`}
                              target="_blank"
                              rel="noreferrer"
                              onClick={(ev) => ev.stopPropagation()}
                              data-debug-id={`${debugPrefix}-log-cl-${e.cl_number}`}
                              className="shrink-0 rounded bg-info-soft px-1 font-mono text-[10px] font-semibold text-info hover:underline"
                              title={`Critique CL ${e.cl_number}`}
                            >
                              CL {e.cl_number}
                            </a>
                          ) : null}
                          {e.review_status ? (
                            <span
                              data-debug-id={`${debugPrefix}-log-status-${e.short_hash}`}
                              className={`shrink-0 rounded px-1 text-[10px] font-medium ${
                                e.review_status === 'LGTM'
                                  ? 'bg-success-soft text-success'
                                  : e.review_status === 'Mailed'
                                  ? 'bg-info-soft text-info'
                                  : 'bg-neutral-soft text-muted'
                              }`}
                            >
                              {e.review_status}
                            </span>
                          ) : null}
                          <span className="min-w-0 flex-1 truncate text-[12px] text-primary" title={e.subject}>{e.subject || '(no message)'}</span>
                        </div>
                        <div className="mt-0.5 flex items-center gap-2 text-[10px] text-muted">
                          <span className="truncate">{e.author}</span>
                          <span className="ml-auto shrink-0">{e.date}</span>
                        </div>
                      </button>
                    );
                  })
                )}
                {logHasMore ? (
                  <button
                    type="button"
                    onClick={() => void loadLog({ append: true })}
                    disabled={logLoading}
                    className="w-full px-3 py-2 text-center text-[11px] font-medium text-accent hover:bg-neutral-soft disabled:opacity-50"
                  >
                    {logLoading ? 'Loading…' : 'Load more'}
                  </button>
                ) : null}
              </div>
            )}

            {/* Workspaces */}
            {can('workspaces') && workspaces.length > 0 ? (
              <div data-debug-id={`${debugPrefix}-workspaces`} className="border-t border-subtle">
                <button
                  type="button"
                  onClick={() => toggleSection('workspaces')}
                  className="flex w-full items-center gap-2 bg-canvas px-3 py-1.5 text-left hover:bg-neutral-soft"
                >
                  <ChevronIcon collapsed={collapsed['workspaces']} />
                  <span className="text-[11px] font-semibold uppercase tracking-wide text-muted">Workspaces</span>
                  <span className="ml-auto rounded-full bg-neutral-soft px-1.5 text-[10px] font-bold text-muted">{workspaces.length}</span>
                </button>
                {!collapsed['workspaces'] ? (
                  <div>
                    {workspaces.map((w) => {
                      const isActive = activeWorktreePath ? w.path === activeWorktreePath : w.is_current;
                      return (
                        <button
                          key={w.path}
                          type="button"
                          disabled={w.is_current}
                          onClick={() => setActiveWorktreePath(w.is_current ? null : w.path)}
                          data-debug-id={`${debugPrefix}-workspace-${w.path}`}
                          className={`flex w-full items-center gap-2 px-3 py-1.5 text-left ${isActive ? 'bg-accent/10' : 'hover:bg-neutral-soft'} disabled:cursor-default`}
                          title={w.path}
                        >
                          <span className="min-w-0 flex-1 truncate text-[12px] text-primary">{w.label || w.path}</span>
                          {w.is_current ? <span className="shrink-0 rounded bg-success-soft px-1 text-[8px] font-bold text-success">current</span> : null}
                          {w.is_locked ? <span className="shrink-0 rounded bg-neutral-soft px-1 text-[8px] font-bold text-muted">locked</span> : null}
                        </button>
                      );
                    })}
                  </div>
                ) : null}
              </div>
            ) : null}
          </div>

          {/* Footer (Changes only): refresh + commit message/button */}
          {activeSubTab === 'changes' ? (
            <div className="flex shrink-0 flex-col gap-1.5 border-t border-subtle bg-surface px-2 py-1.5">
              <div className="flex items-center gap-2">
                <RowButton label="Refresh" onClick={() => void filesQ.refetch()} disabled={filesQ.isFetching} debugId={`${debugPrefix}-refresh`} />
                {(can('sync') || can('pull') || caps?.supports_sync) ? (
                  <RowButton
                    label={syncState.isLoading ? syncBusyLabel : (caps?.sync_label || 'Sync with Head')}
                    onClick={() => void handleSync()}
                    disabled={syncState.isLoading || busyWrite}
                    debugId={`${debugPrefix}-sync-footer`}
                  />
                ) : null}
                <span className="ml-auto text-[11px] text-muted">{files.length} file{files.length === 1 ? '' : 's'}</span>
              </div>
              {caps?.commit_model ? (
                <>
                  <textarea
                    rows={2}
                    value={commitMessage}
                    onChange={(e) => setCommitMessage(e.target.value)}
                    placeholder={isAmend ? 'Amend commit message...' : 'Commit message...'}
                    data-debug-id={`${debugPrefix}-commit-message`}
                    className="w-full resize-none rounded border border-subtle bg-surface px-2 py-1 text-[11px] font-mono text-primary placeholder:text-muted focus:outline-none focus:ring-1 focus:ring-accent"
                  />
                  {commitError ? <p data-debug-id={`${debugPrefix}-commit-error`} className="text-[11px] text-danger">{commitError}</p> : null}
                  {actionError ? <p data-debug-id={`${debugPrefix}-action-error`} className="text-[11px] text-danger">{actionError}</p> : null}
                  <div className="flex items-center justify-between gap-2">
                    {can('amend') || caps?.supports_amend ? (
                      <label className="flex items-center gap-1.5 text-[11px] text-muted cursor-pointer select-none">
                        <input
                          type="checkbox"
                          checked={isAmend}
                          onChange={(e) => void onToggleAmend(e.target.checked)}
                          data-debug-id={`${debugPrefix}-amend-checkbox`}
                          className="h-3.5 w-3.5 accent-accent"
                        />
                        <span>Amend</span>
                      </label>
                    ) : <span />}
                    <div className="flex items-center gap-1.5">
                      {(can('upload') || can('push') || caps?.supports_upload) ? (
                        <button
                          type="button"
                          disabled={uploadState.isLoading || busyWrite}
                          onClick={() => void handleUpload()}
                          data-debug-id={`${debugPrefix}-upload`}
                          title={uploadLabel === 'Push' ? 'Push changes to remote repository' : 'Upload changes to Critique / remote'}
                          className="inline-flex items-center justify-center rounded border border-subtle bg-accent/15 px-2.5 py-1 text-[11px] font-medium text-accent hover:bg-accent/25 disabled:opacity-50"
                        >
                          {uploadState.isLoading ? uploadBusyLabel : (caps?.upload_label || 'Upload to Critique')}
                        </button>
                      ) : null}
                      <button
                        type="button"
                        disabled={commitDisabled}
                        onClick={() => void handleCommit()}
                        data-debug-id={`${debugPrefix}-commit`}
                        className="inline-flex items-center justify-center rounded border border-subtle bg-accent/15 px-2.5 py-1 text-[11px] font-medium text-accent hover:bg-accent/25 disabled:opacity-50"
                      >
                        {commitButtonLabel}
                      </button>
                    </div>
                  </div>
                </>
              ) : null}
            </div>
          ) : null}
        </div>
        ) : null}

        {/* Right pane — diff / commit detail. On mobile a back button returns to the list. */}
        {(!isSinglePane || activePane === 'diff') ? (
        <div data-debug-id={`${debugPrefix}-right`} className="flex min-h-0 flex-1 flex-col">
          {isSinglePane ? (
            <button
              type="button"
              onClick={() => setActivePane('list')}
              data-debug-id={`${debugPrefix}-back-to-list`}
              className="flex shrink-0 items-center gap-1 border-b border-subtle bg-surface-raised px-2 py-0.5 text-[11px] text-muted hover:text-primary"
            >
              <Icon name="arrow-left" size={13} />
              <span>{activeSubTab === 'changes' ? 'Changes' : 'Log'}</span>
            </button>
          ) : null}
          {activeSubTab === 'changes' ? (
            selectedFile ? (
              // Untracked directories surface as "dirname/" in git --porcelain; they have
              // no file content to diff, so show a navigate-to-explorer placeholder instead
              // of mounting Monaco.
              selectedFile.path.endsWith('/') ? (
                <div data-debug-id={`${debugPrefix}-dir-placeholder`} className="grid flex-1 place-items-center p-6 text-center">
                  <div className="flex max-w-xs flex-col items-center gap-3">
                    <Icon name="folder" size={32} className="text-muted" />
                    <div className="break-all font-mono text-[12.5px] text-primary">{selectedFile.path}</div>
                    <p className="text-xs text-muted">Directories cannot be diffed. Open it in the Files explorer to browse its contents.</p>
                    <button
                      type="button"
                      data-debug-id={`${debugPrefix}-open-dir-btn`}
                      onClick={() => onOpenDirectory?.(selectedFile.path)}
                      disabled={!onOpenDirectory}
                      className="inline-flex items-center gap-1.5 rounded border border-subtle bg-neutral-soft px-2.5 py-1 text-[11.5px] font-medium text-muted hover:text-primary disabled:opacity-50"
                    >
                      <Icon name="folder" size={13} />
                      <span>Open in Files tab</span>
                    </button>
                  </div>
                </div>
              ) : (
                <div className="flex min-h-0 flex-1 flex-col">
                  {/* Contextual action toolbar for the selected file */}
                  <div className="flex shrink-0 items-center justify-between gap-2 border-b border-subtle px-2 py-1">
                    <span className="min-w-0 truncate font-mono text-[11px] text-primary" title={selectedFile.path}>
                      {selectedFile.path.slice(selectedFile.path.lastIndexOf('/') + 1)}
                    </span>
                    <div className="flex shrink-0 items-center gap-1">
                      {selectedFile.staged && can('unstage') ? (
                        <button type="button" onClick={() => onUnstage(selectedFile.path)} disabled={busyWrite} data-debug-id={`${debugPrefix}-toolbar-unstage`} className="inline-flex h-6 items-center gap-1 rounded border border-subtle px-2 text-[11px] font-medium text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-50">Unstage</button>
                      ) : null}
                      {!selectedFile.staged && selectedFile.status !== 'untracked' && caps?.supports_staging && can('stage') ? (
                        <button type="button" onClick={() => onStage(selectedFile.path)} disabled={busyWrite} data-debug-id={`${debugPrefix}-toolbar-stage`} className="inline-flex h-6 items-center gap-1 rounded border border-subtle px-2 text-[11px] font-medium text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-50">Stage</button>
                      ) : null}
                      {selectedFile.status === 'untracked' && can('stage') ? (
                        <button type="button" onClick={() => onStage(selectedFile.path)} disabled={busyWrite} data-debug-id={`${debugPrefix}-toolbar-track`} className="inline-flex h-6 items-center gap-1 rounded border border-subtle px-2 text-[11px] font-medium text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-50">Track</button>
                      ) : null}
                      {selectedFile.status !== 'untracked' && can('revert') ? (
                        <button type="button" onClick={() => onRevert(selectedFile.path)} disabled={busyWrite} data-debug-id={`${debugPrefix}-toolbar-revert`} className="inline-flex h-6 items-center gap-1 rounded border border-subtle px-2 text-[11px] font-medium text-danger hover:bg-danger-soft disabled:opacity-50">Revert</button>
                      ) : null}
                      {selectedFile.status === 'untracked' ? (
                        <button type="button" onClick={() => void onDeleteUntracked(selectedFile.path)} disabled={busyWrite} data-debug-id={`${debugPrefix}-toolbar-delete`} className="inline-flex h-6 items-center gap-1 rounded border border-subtle px-2 text-[11px] font-medium text-danger hover:bg-danger-soft disabled:opacity-50">Delete</button>
                      ) : null}
                    </div>
                  </div>
                  <VcsFileEditor
                    key={`${selectedFile.path}:${selectedFile.staged ? 's' : 'u'}`}
                    projectId={projectId}
                    experimentEnabled={experimentEnabled}
                    bridgeId={bridgeId}
                    file={selectedFile}
                    worktreePath={activeWorktreePath}
                    saveVcsFile={saveVcsFile}
                    debugPrefix={debugPrefix}
                  />
                </div>
              )
            ) : (
              <div data-debug-id={`${debugPrefix}-no-selection`} className="grid flex-1 place-items-center p-6 text-center text-xs text-muted">
                Select a file to view its diff.
              </div>
            )
          ) : (
            <div className="flex min-h-0 flex-1 flex-col">
              {/* Two-ref picker */}
              <div className="flex shrink-0 items-center gap-2 border-b border-subtle bg-surface px-3 py-2 text-[11px]">
                <span className="text-muted">Base</span>
                <input
                  value={diffBaseRef}
                  onChange={(e) => setDiffBaseRef(e.target.value)}
                  placeholder="base ref"
                  data-debug-id={`${debugPrefix}-base-ref`}
                  className="w-28 rounded border border-subtle bg-canvas px-1.5 py-0.5 font-mono text-[11px] text-primary"
                />
                <span className="text-muted">→ Head</span>
                <input
                  value={diffHeadRef}
                  onChange={(e) => setDiffHeadRef(e.target.value)}
                  placeholder="WORKDIR"
                  data-debug-id={`${debugPrefix}-head-ref`}
                  className="w-28 rounded border border-subtle bg-canvas px-1.5 py-0.5 font-mono text-[11px] text-primary"
                />
                <button
                  type="button"
                  onClick={() => {
                    setSelectedCommitFile(null);
                    setCommitHunks([]);
                    setCommitCursor(null);
                    void loadCommitDiffFiles();
                  }}
                  disabled={!diffBaseRef || commitDiffFilesLoading}
                  data-debug-id={`${debugPrefix}-diff-btn`}
                  className="rounded border border-subtle bg-neutral-soft px-2 py-0.5 font-medium text-muted hover:text-primary disabled:opacity-50"
                >
                  {commitDiffFilesLoading ? 'Loading…' : 'Diff'}
                </button>
              </div>
              {/* Body: file list (left) + Monaco diff (right) */}
              <div className="flex min-h-0 flex-1">
                {/* File list column */}
                <div className="flex w-[30%] min-h-0 flex-col overflow-y-auto border-r border-subtle" data-debug-id={`${debugPrefix}-commit-files`}>
                  {!diffBaseRef ? (
                    <div className="p-3 text-center text-xs text-muted">Select a commit to see its files.</div>
                  ) : commitDiffFilesLoading ? (
                    <div className="p-3 text-center text-xs text-muted">Loading…</div>
                  ) : commitDiffFilesError ? (
                    <div className="p-3 text-center text-xs text-danger">{commitDiffFilesError}</div>
                  ) : commitDiffFiles.length === 0 ? (
                    <div className="p-3 text-center text-xs text-muted">No changed files.</div>
                  ) : (
                    commitDiffFiles.map((f) => {
                      const badge = statusBadge(f.status);
                      const isSel = selectedCommitFile === f.path;
                      return (
                        <button
                          key={f.path}
                          type="button"
                          onClick={() => {
                            setSelectedCommitFile(f.path);
                            setCommitHunks([]);
                            setCommitCursor(null);
                            void loadCommitDiff({ file: f.path });
                          }}
                          title={f.path}
                          data-debug-id={`${debugPrefix}-commit-file-${f.path}`}
                          className={`flex items-center gap-2 px-2 py-1.5 text-left text-[11.5px] ${isSel ? 'bg-accent/15' : 'hover:bg-neutral-soft'}`}
                        >
                          <span className={`grid h-4 w-4 shrink-0 place-items-center rounded text-[9px] font-bold ${badge.cls}`} title={f.status}>
                            {badge.label}
                          </span>
                          <span className={`min-w-0 flex-1 truncate ${isSel ? 'text-accent' : 'text-primary'}`}>{f.path}</span>
                          <span className="flex shrink-0 gap-1 font-mono text-[10px]">
                            {f.additions > 0 ? <span className="text-success">+{f.additions}</span> : null}
                            {f.deletions > 0 ? <span className="text-danger">-{f.deletions}</span> : null}
                          </span>
                        </button>
                      );
                    })
                  )}
                </div>
                {/* Monaco diff column */}
                <div className="flex min-h-0 flex-1 flex-col overflow-y-auto">
                  {!diffBaseRef ? (
                    <div className="grid h-full place-items-center p-6 text-center text-xs text-muted">Select a commit or enter refs to diff.</div>
                  ) : !selectedCommitFile ? (
                    <div className="grid h-full place-items-center p-6 text-center text-xs text-muted">Select a file to view its diff.</div>
                  ) : commitDiffError && commitHunks.length === 0 ? (
                    <div className="p-4 text-center text-xs text-muted">{commitDiffError}</div>
                  ) : commitHunks.length === 0 && commitDiffLoading ? (
                    <div className="grid h-full place-items-center p-6 text-center text-xs text-muted">Loading diff…</div>
                  ) : commitHunks.length === 0 ? (
                    <div className="p-4 text-center text-xs text-muted">No differences in this file.</div>
                  ) : (
                    <>
                      <MonacoDiffViewer hunks={commitHunks} filePath={selectedCommitFile} sideBySide />
                      {commitHasMore ? (
                        <button
                          type="button"
                          onClick={() => void loadCommitDiff({ append: true })}
                          disabled={commitDiffLoading}
                          className="w-full px-3 py-2 text-center text-[11px] font-medium text-accent hover:bg-neutral-soft disabled:opacity-50"
                        >
                          {commitDiffLoading ? 'Loading…' : 'Load more'}
                        </button>
                      ) : null}
                    </>
                  )}
                </div>
              </div>
            </div>
          )}
        </div>
        ) : null}
      </div>
    </div>
  );
}

// ---- Small row/tab button helpers ------------------------------------------

function RowButton({ label, onClick, disabled, tone, debugId }: { label: string; onClick: () => void; disabled?: boolean; tone?: 'danger'; debugId?: string }) {
  const toneCls = tone === 'danger' ? 'text-danger hover:bg-danger-soft' : 'text-muted hover:text-primary hover:bg-neutral-soft';
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      data-debug-id={debugId}
      className={`rounded border border-subtle px-1.5 py-0.5 text-[10px] font-medium ${toneCls} disabled:opacity-50`}
    >
      {label}
    </button>
  );
}

function SubTabButton({ label, active, onClick, debugId }: { label: string; active: boolean; onClick: () => void; debugId?: string }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      data-debug-id={debugId}
      className={`rounded px-2.5 py-1 text-[12px] font-medium ${active ? 'bg-accent/15 text-accent' : 'text-muted hover:bg-neutral-soft hover:text-primary'}`}
    >
      {label}
    </button>
  );
}

// ---- Right-pane editable file editor ---------------------------------------

type SaveArgs = { projectId: string; bridgeId?: string; file: string; content: string; worktree_path?: string };

function VcsFileEditor({
  projectId,
  experimentEnabled,
  bridgeId,
  file,
  worktreePath,
  saveVcsFile,
  debugPrefix,
}: {
  projectId: string;
  experimentEnabled: boolean;
  bridgeId: string;
  file: VcsChangedFile;
  worktreePath: string | null;
  saveVcsFile: (args: SaveArgs) => { unwrap: () => Promise<{ ok: boolean; error?: { code: string; message: string } }> };
  debugPrefix: string;
}) {
  const { theme } = useTheme();
  const monacoTheme = theme?.appearance === 'light' ? 'light' : 'vs-dark';

  const isDeleted = file.status === 'deleted';
  const isAddedLike = file.status === 'added' || file.status === 'untracked';
  const language = useMemo(() => monacoLanguage(file.path), [file.path]);

  // Full current file text (the editable buffer). A large file comes back
  // truncated → we drop to a read-only view so a Save can't drop its tail.
  const contentQ = useReadProjectFileQuery(
    { projectId, bridgeId, path: file.path, limit: EDIT_READ_LIMIT },
    { skip: !experimentEnabled || isDeleted },
  );
  // Diff hunks — used to render the read-only "original" side of the diff editor
  // (and the deleted-file view). For an added file the hunks are the whole file as
  // additions, so this also drives "view changes" of newly-added files.
  const diffHunksQ = useGetVcsDiffQuery(
    { projectId, bridgeId, file: file.path },
    { skip: !experimentEnabled || !file.path },
  );
  const diffHunks: VcsDiffHunk[] = diffHunksQ.data?.hunks ?? [];

  const notViewable = Boolean(contentQ.data && !contentQ.data.viewable);
  const truncated = Boolean(contentQ.data?.truncated);
  const readOnly = isDeleted || notViewable || truncated;

  const [buffer, setBuffer] = useState('');
  const [baseline, setBaseline] = useState('');
  useEffect(() => {
    if (isDeleted) return;
    if (contentQ.data) {
      const c = contentQ.data.viewable ? (contentQ.data.content ?? '') : '';
      setBuffer(c);
      setBaseline(c);
    }
  }, [contentQ.data, isDeleted]);

  const dirty = !readOnly && buffer !== baseline;

  // Original (pre-change) full text, rebuilt from the pristine loaded buffer plus
  // the diff hunks, so the diff editor shows complete context. The editable side is
  // the live buffer, so Save always writes the whole file.
  const originalText = useMemo(() => reconstructOriginal(baseline, diffHunks), [baseline, diffHunks]);

  const [saving, setSaving] = useState(false);
  const [feedback, setFeedback] = useState<SaveFeedback>(null);

  const doSave = useCallback(async () => {
    if (readOnly || !dirty) return;
    setSaving(true);
    setFeedback(null);
    try {
      const res = await saveVcsFile({ projectId, bridgeId, file: file.path, content: buffer, worktree_path: worktreePath ?? undefined }).unwrap();
      if (res.ok) {
        setBaseline(buffer);
        setFeedback({ type: 'success', message: 'Saved' });
      } else {
        setFeedback({ type: 'error', message: res.error?.message || 'Save failed' });
      }
    } catch (e: any) {
      setFeedback({ type: 'error', message: str(e?.error || e?.message) || 'Save failed' });
    } finally {
      setSaving(false);
    }
  }, [readOnly, dirty, saveVcsFile, projectId, bridgeId, file.path, buffer, worktreePath]);

  // Stable ref so the Monaco Ctrl+S command always calls the latest doSave.
  const saveRef = useRef(doSave);
  useEffect(() => { saveRef.current = doSave; }, [doSave]);

  // Auto-dismiss the save toast.
  useEffect(() => {
    if (!feedback) return;
    const t = setTimeout(() => setFeedback(null), 2500);
    return () => clearTimeout(t);
  }, [feedback]);

  const handleEditorMount: OnMount = (editor, monaco) => {
    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => saveRef.current());
  };
  const handleDiffMount: DiffOnMount = (diffEditor, monaco) => {
    const mod = diffEditor.getModifiedEditor();
    mod.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => saveRef.current());
    const model = mod.getModel();
    model?.onDidChangeContent(() => setBuffer(mod.getValue()));
  };

  const editorOptions: EditorProps['options'] = {
    readOnly,
    minimap: { enabled: false },
    scrollBeyondLastLine: false,
    lineNumbers: 'on',
    automaticLayout: true,
    fontSize: 13,
    tabSize: 2,
  };
  const diffOptions: DiffEditorProps['options'] = {
    readOnly,
    originalEditable: false,
    renderSideBySide: true,
    minimap: { enabled: false },
    scrollBeyondLastLine: false,
    automaticLayout: true,
    fontSize: 13,
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col" data-debug-id={`${debugPrefix}-editor`}>
      {/* Header: path + dirty dot + Save */}
      <div className="flex shrink-0 items-center gap-2 border-b border-subtle bg-surface px-3 py-1.5">
        {dirty ? <span data-debug-id={`${debugPrefix}-dirty-dot`} className="h-2 w-2 shrink-0 rounded-full bg-warning" title="Unsaved changes" /> : null}
        <span className="min-w-0 flex-1 truncate text-[12px] text-primary" title={file.path}>{file.path}</span>
        {feedback ? (
          <span
            data-debug-id={`${debugPrefix}-save-feedback`}
            className={`flex items-center gap-1 text-[11px] ${feedback.type === 'success' ? 'text-success' : 'text-danger'}`}
          >
            <Icon name={feedback.type === 'success' ? 'check' : 'alert'} size={12} />
            <span className="max-w-[160px] truncate">{feedback.message}</span>
          </span>
        ) : null}
        {!readOnly ? (
          <button
            type="button"
            onClick={() => void doSave()}
            disabled={!dirty || saving}
            data-debug-id={`${debugPrefix}-save-btn`}
            className="flex shrink-0 items-center gap-1 rounded border border-subtle bg-neutral-soft px-2 py-0.5 text-[11px] font-medium text-primary hover:bg-accent/15 hover:text-accent disabled:opacity-50"
            title="Save (Ctrl+S)"
          >
            <Icon name="save" size={12} />
            {saving ? 'Saving…' : 'Save'}
          </button>
        ) : null}
      </div>

      {/* Notices for the non-editable cases. */}
      {truncated ? (
        <div className="shrink-0 bg-warning-soft px-3 py-1 text-[11px] text-warning">File is too large to edit here — showing a read-only diff.</div>
      ) : notViewable ? (
        <div className="shrink-0 bg-neutral-soft px-3 py-1 text-[11px] text-muted">Binary file — not editable.</div>
      ) : null}

      {/* Editor body */}
      <div className="min-h-0 flex-1">
        {contentQ.isLoading && !isDeleted ? (
          <div className="grid h-full place-items-center p-4 text-center text-xs text-muted">Loading…</div>
        ) : isDeleted ? (
          <div className="h-full overflow-y-auto">
            <MonacoDiffViewer hunks={diffHunks} filePath={file.path} sideBySide />
          </div>
        ) : readOnly ? (
          <div className="h-full overflow-y-auto">
            <MonacoDiffViewer hunks={diffHunks} filePath={file.path} sideBySide />
          </div>
        ) : isAddedLike ? (
          <Editor
            value={buffer}
            language={language}
            theme={monacoTheme}
            options={editorOptions}
            onChange={(v) => setBuffer(v ?? '')}
            onMount={handleEditorMount}
            height="100%"
            loading={<div className="p-3 text-center text-xs text-muted">Loading editor…</div>}
          />
        ) : (
          <DiffEditor
            original={originalText}
            modified={buffer}
            language={language}
            theme={monacoTheme}
            options={diffOptions}
            onMount={handleDiffMount}
            height="100%"
            loading={<div className="p-3 text-center text-xs text-muted">Loading editor…</div>}
          />
        )}
      </div>
    </div>
  );
}
