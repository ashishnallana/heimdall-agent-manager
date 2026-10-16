// InstanceRunDirPanel — the "Run dir" tab peer to Files/Tasks.
//
// READ-ONLY browser for an agent INSTANCE's bridge-managed run directory (the
// exact context materialized for the agent: AGENTS.md/CLAUDE.md, .heimdall/,
// skills/, bootstrap manifest). Forked from ProjectFilesPanel; the FS MUTATIONS
// (create/rename/move/delete/mkdir) are removed — it is view + comment only.
// Show-hidden defaults ON here (the point is to see dotfiles/.heimdall). Keeps
// single-directory listing + breadcrumb, cursor pagination ("Load more"), the
// bounded file preview (size cap + type gate), and the line-comment / publish-
// comments review flow (writes no files — posts collected comments as a chat
// message, exactly what the user asked for).
//
// Cache is keyed by (instanceId, path) in instanceFs.ts, so navigating only
// refetches the affected directory.
//
// PHASE-4 FOLLOW-UP (Spec 4.3/6 — list virtualization): large directories are
// currently bounded by the contract's cursor pagination (limit 200 + "Load more"
// via next_cursor/has_more) inside a scroll container, which keeps the mounted
// DOM small in practice. True windowing (react-window/equiv) is deferred because
// the pinned virtualizers require React 19 while this app is on React 18 (the
// @vimee/* deps hold the React-19 peer); adding one needs either a React-18
// compatible virtualizer or a React bump. Tracked as a Phase-4 follow-up.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import MarkdownBody from '../MarkdownBody';
import { highlightToLines, languageForFile, type CodeToken } from '../../utils/codeHighlight';
import { Icon, IconButton } from '@ui';
import {
  useLazyListInstanceDirQuery,
  useLazyReadInstanceFileQuery,
  type FsEntry,
  type FsListResult,
  type FsReadFileResult,
} from '../../api/endpoints/instanceFs';

function str(v: any): string {
  return String(v ?? '').trim();
}

// Format all pending line comments into a single markdown chat message, grouped
// by file and ordered by line, with the source line as context.
function formatCommentsMarkdown(comments: FileLineComment[]): string {
  const byPath = new Map<string, FileLineComment[]>();
  for (const c of comments) {
    const list = byPath.get(c.path) || [];
    list.push(c);
    byPath.set(c.path, list);
  }
  const parts: string[] = ['Code review comments:', ''];
  for (const [path, list] of byPath) {
    parts.push(`**${path}**`);
    for (const c of [...list].sort((a, b) => a.line - b.line || a.createdAt - b.createdAt)) {
      if (c.line > 0) {
        parts.push(`- L${c.line}: \`${c.lineText.trim()}\``);
      } else {
        // Line 0 = file/folder-level comment (no specific line).
        parts.push(`- (${c.lineText.trim() || 'general'})`);
      }
      for (const bodyLine of c.body.split('\n')) parts.push(`  > ${bodyLine}`);
    }
    parts.push('');
  }
  return parts.join('\n').trim();
}

// Human-friendly byte size for the entry rows + file viewer header.
function formatBytes(value: number): string {
  const n = Number(value) || 0;
  if (n <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.min(units.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
  const scaled = n / Math.pow(1024, i);
  return `${scaled >= 100 || i === 0 ? Math.round(scaled) : scaled.toFixed(1)} ${units[i]}`;
}

// Compact relative time (falls back to the raw string if unparseable).
function formatModified(iso: string): string {
  const s = str(iso);
  if (!s) return '';
  const t = Date.parse(s);
  if (Number.isNaN(t)) return s;
  const diff = Date.now() - t;
  const min = Math.floor(diff / 60000);
  if (min < 1) return 'just now';
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  if (day < 30) return `${day}d ago`;
  return new Date(t).toLocaleDateString();
}

// Join a project-root-relative dir with a child name.
function joinPath(dir: string, name: string): string {
  return dir ? `${dir}/${name}` : name;
}

// Basename of a path.
function baseName(path: string): string {
  const clean = str(path).replace(/\/+$/, '');
  const idx = clean.lastIndexOf('/');
  return idx < 0 ? clean : clean.slice(idx + 1);
}

const LIST_LIMIT = 200;

// A single line comment (UI-local, in-memory), anchored to a file path + line.
export type FileLineComment = {
  id: string;
  path: string; // project-root-relative file path
  line: number; // 1-based
  lineText: string; // snapshot of the source line for message context
  body: string;
  createdAt: number;
};

export type InstanceRunDirPanelProps = {
  agentInstanceId: string;
  // Label for the run-dir root crumb (e.g. the instance display name).
  rootLabel?: string;
  // Scope key for the in-memory comment store: comments reset when this changes
  // (e.g. switching conversations) so review notes never leak across chats.
  conversationKey?: string;
  // Publish the collected comments as a single chat message. Returns true on
  // success (the panel then clears the local store). Parent owns the send.
  onPublishComments?: (markdown: string) => Promise<boolean>;
  onClose?: () => void;
  isMobile?: boolean;
  debugPrefix?: string;
};

export default function InstanceRunDirPanel({
  agentInstanceId,
  rootLabel,
  conversationKey = '',
  onPublishComments,
  onClose,
  isMobile = false,
  debugPrefix = 'instance-run-dir',
}: InstanceRunDirPanelProps) {
  void isMobile; // accepted for parity with the Files panel; layout is responsive via CSS.
  const [listDir] = useLazyListInstanceDirQuery();
  const [readFile, readState] = useLazyReadInstanceFileQuery();

  const [cwd, setCwd] = useState(''); // run-dir-relative path ('' = root)
  const [rootAbs, setRootAbs] = useState('');
  const [entries, setEntries] = useState<FsEntry[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [truncated, setTruncated] = useState(false);
  const [loading, setLoading] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState('');
  // Show hidden by DEFAULT: the whole point of the run-dir view is to reveal
  // dotfiles/dirs (.heimdall/, .git/) that make up the agent's context.
  const [includeHidden, setIncludeHidden] = useState(true);
  // Timestamp of the last successful listing fetch, shown as "refreshed HH:MM".
  const [lastRefreshed, setLastRefreshed] = useState<number | null>(null);

  // The file currently open in the read-only viewer (null = list view).
  const [viewFile, setViewFile] = useState<FsReadFileResult | null>(null);

  // In-memory review comments, tracked ACROSS all files in this conversation.
  // Reset when the conversation scope changes so notes never leak between chats.
  const [comments, setComments] = useState<FileLineComment[]>([]);
  const [publishing, setPublishing] = useState(false);
  const [publishError, setPublishError] = useState('');
  useEffect(() => {
    setComments([]);
    setPublishError('');
  }, [conversationKey, agentInstanceId]);

  const addComment = useCallback((path: string, line: number, lineText: string, body: string) => {
    const text = str(body);
    if (!text) return;
    setComments((prev) => [
      ...prev,
      { id: `flc_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`, path, line, lineText, body: text, createdAt: Date.now() },
    ]);
  }, []);
  const editComment = useCallback((id: string, body: string) => {
    const text = str(body);
    setComments((prev) => prev.map((c) => (c.id === id ? { ...c, body: text } : c)).filter((c) => c.body));
  }, []);
  const deleteComment = useCallback((id: string) => {
    setComments((prev) => prev.filter((c) => c.id !== id));
  }, []);

  // Path-level (file/folder) comment composer: the target path (or null when
  // closed) and its draft. line 0 marks a path-scoped comment.
  const [pathCommentFor, setPathCommentFor] = useState<{ path: string; label: string } | null>(null);
  const [pathCommentDraft, setPathCommentDraft] = useState('');

  const commentsForPath = useCallback(
    (path: string) => comments.filter((c) => c.path === path),
    [comments],
  );
  const filesWithComments = useMemo(() => new Set(comments.map((c) => c.path)).size, [comments]);

  const publishComments = useCallback(async () => {
    if (!onPublishComments || comments.length === 0) return;
    setPublishError('');
    setPublishing(true);
    try {
      const ok = await onPublishComments(formatCommentsMarkdown(comments));
      if (ok) setComments([]);
      else setPublishError('Could not send comments.');
    } catch (e: any) {
      setPublishError(str(e?.message) || 'Could not send comments.');
    } finally {
      setPublishing(false);
    }
  }, [onPublishComments, comments]);

  // Load a directory listing (optionally appending a paginated page).
  const load = useCallback(
    async (path: string, opts?: { cursor?: string | null; append?: boolean }) => {
      if (!agentInstanceId) return;
      const append = Boolean(opts?.append);
      setError('');
      if (append) setLoadingMore(true);
      else setLoading(true);
      try {
        const res: FsListResult = await listDir({
          instanceId: agentInstanceId,
          path,
          includeHidden,
          cursor: opts?.cursor ?? null,
          limit: LIST_LIMIT,
        }).unwrap();
        if (!res.ok) {
          setError(str(res.error?.message) || 'Could not open directory');
          if (!append) setEntries([]);
          return;
        }
        setRootAbs(res.root || '');
        setTruncated(Boolean(res.truncated));
        setHasMore(Boolean(res.has_more));
        setNextCursor(res.next_cursor ?? null);
        setEntries((prev) => (append ? [...prev, ...(res.entries || [])] : res.entries || []));
        if (!append) setCwd(path);
        setLastRefreshed(Date.now());
      } catch (e: any) {
        setError(str(e?.error || e?.message) || 'Bridge unavailable');
        if (!append) setEntries([]);
      } finally {
        if (append) setLoadingMore(false);
        else setLoading(false);
      }
    },
    [agentInstanceId, includeHidden, listDir],
  );

  // Reset to the project ROOT only when the project/bridge changes, so we never
  // show a stale directory carried over from another project. The hidden toggle
  // must NOT reset here (Spec 4.2/4.3 — it refetches the CURRENT dir; see below).
  useEffect(() => {
    setViewFile(null);
    void load('');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [agentInstanceId]);

  // Show/hide-hidden refetches the CURRENT directory in place (Spec 4.2/4.3) —
  // it must not jump back to root. Skip the initial mount so this doesn't
  // double-fire alongside the project/bridge effect on first render.
  const hiddenMounted = useRef(false);
  useEffect(() => {
    if (!hiddenMounted.current) {
      hiddenMounted.current = true;
      return;
    }
    void load(cwd);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [includeHidden]);

  const openDir = useCallback(
    (path: string) => {
      setViewFile(null);
      void load(path);
    },
    [load],
  );

  const refresh = useCallback(() => {
    if (viewFile) {
      void openFile(viewFile.path);
      return;
    }
    void load(cwd);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cwd, viewFile, load]);

  // Breadcrumb crumbs: project root -> cwd.
  const crumbs = useMemo(() => {
    const out: { label: string; path: string }[] = [
      { label: rootLabel ? rootLabel : baseName(rootAbs) || 'run dir', path: '' },
    ];
    if (cwd) {
      const segs = cwd.split('/').filter(Boolean);
      let acc = '';
      for (const seg of segs) {
        acc = acc ? `${acc}/${seg}` : seg;
        out.push({ label: seg, path: acc });
      }
    }
    return out;
  }, [cwd, rootAbs, rootLabel]);

  // Dirs first, then files; names asc (server already sorts this way, but keep it
  // stable client-side for appended pages too).
  const sortedEntries = useMemo(() => {
    return [...entries].sort((a, b) => {
      if (a.is_dir !== b.is_dir) return a.is_dir ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
  }, [entries]);

  // ---- File viewer ----------------------------------------------------------

  // Accumulated viewer content across paged reads. `viewFile` holds the metadata
  // + first chunk; `viewContent` is the stitched text; `viewNextOffset`/`viewEof`
  // drive lazy paging. We assume the file doesn't change between pages.
  const [viewContent, setViewContent] = useState('');
  const [viewNextOffset, setViewNextOffset] = useState(0);
  const [viewEof, setViewEof] = useState(true);
  const [loadingMoreFile, setLoadingMoreFile] = useState(false);
  // Path of the file whose contents are currently being fetched — drives the
  // inline spinner next to that file's name in the list.
  const [openingPath, setOpeningPath] = useState('');

  const openFile = useCallback(
    async (path: string) => {
      setError('');
      setOpeningPath(path);
      try {
        const res: FsReadFileResult = await readFile({ instanceId: agentInstanceId, path, offset: 0 }).unwrap();
        setViewFile(res);
        if (res.viewable && res.encoding === 'utf8') {
          setViewContent(res.content || '');
          setViewNextOffset(Number(res.offset || 0) + Number(res.bytes_returned || (res.content ? res.content.length : 0)));
          setViewEof(res.eof !== false);
        } else {
          // Images / non-viewable: no paging.
          setViewContent(res.content || '');
          setViewNextOffset(0);
          setViewEof(true);
        }
        if (!res.ok && res.error?.message) setError(str(res.error.message));
      } catch (e: any) {
        setError(str(e?.error || e?.message) || 'Could not read file');
      } finally {
        setOpeningPath((cur) => (cur === path ? '' : cur));
      }
    },
    [agentInstanceId, readFile],
  );

  const loadMoreFile = useCallback(async () => {
    if (!viewFile || viewEof || loadingMoreFile) return;
    setLoadingMoreFile(true);
    try {
      const res: FsReadFileResult = await readFile({ instanceId: agentInstanceId, path: viewFile.path, offset: viewNextOffset }).unwrap();
      if (res.ok && res.viewable) {
        setViewContent((prev) => prev + (res.content || ''));
        setViewNextOffset(Number(res.offset || 0) + Number(res.bytes_returned || (res.content ? res.content.length : 0)));
        setViewEof(res.eof !== false);
      } else if (res.error?.message) {
        setError(str(res.error.message));
        setViewEof(true);
      }
    } catch (e: any) {
      setError(str(e?.error || e?.message) || 'Could not load more of this file');
      setViewEof(true);
    } finally {
      setLoadingMoreFile(false);
    }
  }, [agentInstanceId, readFile, viewFile, viewNextOffset, viewEof, loadingMoreFile]);

  // ---- Render ---------------------------------------------------------------

  const wrapperCls = 'relative flex h-full min-h-0 w-full flex-col bg-surface';

  return (
    <div data-debug-id={`${debugPrefix}-panel`} className={wrapperCls}>

      {/* Pending review comments bar — spans ALL files in this conversation. */}
      {comments.length > 0 ? (
        <div data-debug-id={`${debugPrefix}-comments-bar`} className="flex items-center gap-2 border-b border-accent/30 bg-accent/10 px-3 py-2">
          <div data-debug-id={`${debugPrefix}-comments-count`} className="min-w-0 flex-1 text-[11.5px] text-accent">
            {comments.length} comment{comments.length === 1 ? '' : 's'} on {filesWithComments} file{filesWithComments === 1 ? '' : 's'}
            {publishError ? <span className="ml-2 text-danger">{publishError}</span> : null}
          </div>
          <button
            data-debug-id={`${debugPrefix}-comments-clear-btn`}
            type="button"
            onClick={() => { setComments([]); setPublishError(''); }}
            disabled={publishing}
            className="shrink-0 rounded-lg border border-subtle px-2 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-50"
          >
            Clear
          </button>
          <button
            data-debug-id={`${debugPrefix}-comments-send-btn`}
            type="button"
            onClick={() => void publishComments()}
            disabled={publishing || !onPublishComments}
            className="shrink-0 rounded-lg bg-accent px-2.5 py-1 text-caption font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50"
            title={onPublishComments ? 'Send all comments to the agent' : 'Sending is unavailable here'}
          >
            {publishing ? 'Sending…' : 'Send to agent'}
          </button>
        </div>
      ) : null}

      {!agentInstanceId ? (
        <div data-debug-id={`${debugPrefix}-no-instance`} className="grid flex-1 place-items-center p-6 text-center text-xs text-muted">
          No agent instance is associated with this conversation.
        </div>
      ) : viewFile ? (
        <FileView
          file={viewFile}
          content={viewContent}
          hasMore={!viewEof}
          loadingMore={loadingMoreFile}
          onLoadMore={loadMoreFile}
          fetching={readState.isFetching}
          debugPrefix={debugPrefix}
          comments={commentsForPath(viewFile.path)}
          onAddComment={(line, lineText, body) => addComment(viewFile.path, line, lineText, body)}
          onEditComment={editComment}
          onDeleteComment={deleteComment}
          onCommentFile={() => { setPathCommentDraft(''); setPathCommentFor({ path: viewFile.path, label: `file: ${baseName(viewFile.path)}` }); }}
          onBack={() => setViewFile(null)}
        />
      ) : (
        <>
          {/* Breadcrumb */}
          <div data-debug-id={`${debugPrefix}-breadcrumb`} className="flex items-center justify-between gap-1 border-b border-subtle px-3 py-1.5 text-[12px] text-muted">
            <div className="flex min-w-0 flex-1 flex-wrap items-center gap-0.5">
              {(() => {
                const folderCount = comments.filter((c) => c.path === (cwd || '/') && c.line === 0).length;
                return (
                  <button
                    data-debug-id={`${debugPrefix}-folder-comment-btn`}
                    type="button"
                    onClick={() => { setPathCommentDraft(''); setPathCommentFor({ path: cwd || '/', label: `folder: ${cwd || 'project root'}` }); }}
                    title="Comment on this folder"
                    aria-label="Comment on this folder"
                    className={`mr-1 relative grid h-6 w-6 shrink-0 place-items-center rounded border ${folderCount > 0 ? 'border-accent bg-accent/20 text-accent' : 'border-subtle text-muted hover:bg-neutral-soft hover:text-primary'}`}
                  >
                    <Icon name="chat" size={12} />
                    {folderCount > 0 ? <span className="absolute -right-1 -top-1 grid h-3.5 min-w-3.5 place-items-center rounded-full bg-accent px-0.5 text-[8px] font-bold text-accent-fg">{folderCount}</span> : null}
                  </button>
                );
              })()}
              {crumbs.map((c, i) => (
                <span key={c.path || 'root'} className="flex items-center gap-0.5">
                  {i > 0 ? <Icon name="chevron-right" size={12} className="text-faint" /> : null}
                  <button
                    data-debug-id={`${debugPrefix}-crumb-${i}`}
                    type="button"
                    onClick={() => openDir(c.path)}
                    disabled={i === crumbs.length - 1}
                    className="max-w-[160px] truncate rounded px-1 py-0.5 hover:bg-neutral-soft hover:text-primary disabled:cursor-default disabled:text-primary disabled:hover:bg-transparent"
                  >
                    {c.label}
                  </button>
                </span>
              ))}
            </div>
            <IconButton
              icon="refresh"
              label={lastRefreshed ? `Refresh (last: ${new Date(lastRefreshed).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })})` : 'Refresh'}
              variant="solid"
              size="sm"
              data-debug-id={`${debugPrefix}-refresh-btn`}
              onClick={refresh}
              className="shrink-0"
            />
          </div>

          {/* Toolbar (read-only: hidden toggle only) */}
          <div className="flex flex-wrap items-center gap-1.5 border-b border-subtle px-3 py-2">
            <span className="text-[10.5px] text-faint">Read-only · the agent's run context</span>
            <button
              data-debug-id={`${debugPrefix}-hidden-toggle`}
              type="button"
              onClick={() => setIncludeHidden((v) => !v)}
              aria-pressed={includeHidden ? 'true' : 'false'}
              title={includeHidden ? 'Hide dotfiles (names starting with ".")' : 'Show hidden dotfiles (names starting with ".")'}
              className={`ml-auto rounded-lg border px-2 py-1 text-caption ${includeHidden ? 'border-accent bg-accent/10 text-accent' : 'border-subtle text-muted hover:bg-neutral-soft hover:text-primary'}`}
            >
              {includeHidden ? 'Hide hidden' : 'Show hidden'}
            </button>
          </div>

          {/* Directory list */}
          <div data-debug-id={`${debugPrefix}-list`} className="min-h-0 flex-1 overflow-y-auto overscroll-contain p-1 [-webkit-overflow-scrolling:touch] touch-pan-y" style={{ touchAction: 'pan-y' }}>
            {loading ? (
              <div data-debug-id={`${debugPrefix}-loading`} className="p-4 text-center text-xs text-muted">Loading…</div>
            ) : error && sortedEntries.length === 0 ? (
              // Don't show the misleading "empty folder" placeholder when the load
              // actually FAILED (e.g. project not configured on this bridge, or the
              // bridge is offline). The error banner below carries the reason.
              <div data-debug-id={`${debugPrefix}-load-error`} className="p-6 text-center text-xs text-muted">Couldn’t load files — see the message below.</div>
            ) : sortedEntries.length === 0 ? (
              <div data-debug-id={`${debugPrefix}-empty`} className="p-6 text-center text-xs text-faint">This folder is empty.</div>
            ) : (
              <ul>
                {sortedEntries.map((e) => {
                  const isOpening = !e.is_dir && openingPath === joinPath(cwd, e.name);
                  return (
                  <li key={`${e.is_dir ? 'd' : 'f'}:${e.name}`} className="group flex items-center gap-2 border-b border-subtle/40 px-3 py-1.5 hover:bg-neutral-soft">
                    <button
                      data-debug-id={`${debugPrefix}-entry-${e.name}`}
                      type="button"
                      disabled={isOpening}
                      onClick={() => (e.is_dir ? openDir(joinPath(cwd, e.name)) : void openFile(joinPath(cwd, e.name)))}
                      className="flex min-w-0 flex-1 items-center gap-2 text-left"
                    >
                      {isOpening ? (
                        <Icon name="refresh" size={15} className="shrink-0 animate-spin text-accent" title="Loading file…" />
                      ) : (
                        <Icon name={e.is_dir ? 'folder' : 'file'} size={15} className={`shrink-0 ${e.is_dir ? 'text-accent' : 'text-muted'}`} />
                      )}
                      <span className={`min-w-0 flex-1 truncate text-[13px] ${e.hidden ? 'text-faint' : 'text-primary'}`}>{e.name}</span>
                      {e.has_git ? <span className="shrink-0 rounded bg-success-soft px-1.5 py-0.5 text-[9px] font-bold text-success">git</span> : null}
                      {!e.is_dir ? <span className="shrink-0 text-[10px] tabular-nums text-faint">{formatBytes(e.size)}</span> : null}
                      {e.modified_at ? <span className="hidden shrink-0 text-[10px] text-faint sm:inline">{formatModified(e.modified_at)}</span> : null}
                    </button>
                  </li>
                  );
                })}
              </ul>
            )}

            {/* Load more (cursor pagination) */}
            {hasMore ? (
              <div className="p-3 text-center">
                <button
                  data-debug-id={`${debugPrefix}-load-more-btn`}
                  type="button"
                  disabled={loadingMore}
                  onClick={() => void load(cwd, { cursor: nextCursor, append: true })}
                  className="rounded-lg border border-subtle px-3 py-1.5 text-caption text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-50"
                >
                  {loadingMore ? 'Loading…' : 'Load more'}
                </button>
              </div>
            ) : null}
            {truncated ? (
              <div data-debug-id={`${debugPrefix}-truncated`} className="px-3 pb-3 text-center text-[10px] text-warning">
                Listing truncated to the server maximum.
              </div>
            ) : null}
          </div>
        </>
      )}

      {/* Path-level (file/folder) comment composer overlay. */}
      {pathCommentFor ? (
        <div className="absolute inset-x-0 bottom-0 z-10 border-t border-accent/40 bg-surface p-3 shadow-panel">
          <div data-debug-id={`${debugPrefix}-path-composer`} className="mx-auto max-w-2xl">
            <div className="mb-1 text-caption text-muted">Comment on {pathCommentFor.label}</div>
            <textarea
              data-debug-id={`${debugPrefix}-path-composer-input`}
              autoFocus
              value={pathCommentDraft}
              onChange={(e) => setPathCommentDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Escape') { e.preventDefault(); setPathCommentFor(null); }
                if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && pathCommentDraft.trim()) {
                  e.preventDefault();
                  addComment(pathCommentFor.path, 0, pathCommentFor.label, pathCommentDraft);
                  setPathCommentFor(null);
                }
              }}
              rows={3}
              placeholder={`Comment on ${pathCommentFor.label}… (Cmd/Ctrl+Enter to save)`}
              className="w-full resize-y rounded border border-subtle bg-surface-raised p-2 text-[12px] text-primary placeholder:text-muted focus:border-accent focus:outline-none"
            />
            <div className="mt-1.5 flex justify-end gap-1.5">
              <button data-debug-id={`${debugPrefix}-path-composer-cancel`} type="button" onClick={() => setPathCommentFor(null)} className="rounded-lg border border-subtle px-2.5 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary">Cancel</button>
              <button
                data-debug-id={`${debugPrefix}-path-composer-save`}
                type="button"
                disabled={!pathCommentDraft.trim()}
                onClick={() => { addComment(pathCommentFor.path, 0, pathCommentFor.label, pathCommentDraft); setPathCommentFor(null); }}
                className="rounded-lg bg-accent px-2.5 py-1 text-caption font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50"
              >
                Comment
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {error ? (
        <div data-debug-id={`${debugPrefix}-error`} className="border-t border-danger/30 bg-danger-soft px-3 py-2 text-caption text-danger">
          {error}
        </div>
      ) : null}
    </div>
  );
}

// ---- Read-only file viewer --------------------------------------------------

function isMarkdownFile(pathOrName: string): boolean {
  const n = String(pathOrName || '').toLowerCase();
  return n.endsWith('.md') || n.endsWith('.markdown') || n.endsWith('.mdx');
}

function FileView({
  file,
  content,
  hasMore,
  loadingMore,
  onLoadMore,
  fetching,
  debugPrefix,
  comments,
  onAddComment,
  onEditComment,
  onDeleteComment,
  onCommentFile,
  onBack,
}: {
  file: FsReadFileResult;
  content: string; // stitched text content across paged reads
  hasMore: boolean; // more of this file remains to load
  loadingMore: boolean;
  onLoadMore: () => void;
  fetching: boolean;
  debugPrefix: string;
  comments: FileLineComment[];
  onAddComment: (line: number, lineText: string, body: string) => void;
  onEditComment: (id: string, body: string) => void;
  onDeleteComment: (id: string) => void;
  onCommentFile: () => void;
  onBack: () => void;
}) {
  const name = baseName(file.path);
  const fileLevelCount = comments.filter((c) => c.line === 0).length;
  const isImage = file.viewable && file.encoding === 'base64';
  const dataUri = isImage ? `data:${file.mime || 'application/octet-stream'};base64,${file.content || ''}` : '';
  const isText = file.viewable && !isImage;
  const isMarkdown = isText && isMarkdownFile(file.path);

  // View modes for markdown: "rendered" (MarkdownBody) or "source" (highlighted).
  const [mdRendered, setMdRendered] = useState(true);
  // Soft-wrap toggle for the code/source view (off = horizontal scroll).
  const [wrap, setWrap] = useState(false);
  const showCode = isText && !(isMarkdown && mdRendered);

  return (
    <div data-debug-id={`${debugPrefix}-file-view`} className="flex min-h-0 flex-1 flex-col">
      <div className="flex items-center gap-2 border-b border-subtle px-3 py-2">
        <button
          data-debug-id={`${debugPrefix}-file-back-btn`}
          type="button"
          onClick={onBack}
          className="inline-flex items-center gap-1 rounded-lg border border-subtle px-2 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary"
        >
          <Icon name="chevron-left" size={13} /> Back
        </button>
        <div className="min-w-0 flex-1">
          <div className="truncate text-[12.5px] font-semibold text-primary" title={file.path}>{name}</div>
          <div className="truncate text-[10px] text-faint">
            {[file.mime, file.size != null ? formatBytes(file.size) : '', file.modified_at ? formatModified(file.modified_at) : '']
              .filter(Boolean)
              .join(' · ')}
          </div>
        </div>
        {/* File-level comment */}
        <button
          data-debug-id={`${debugPrefix}-file-comment-btn`}
          type="button"
          onClick={onCommentFile}
          title="Comment on this file"
          aria-label="Comment on this file"
          className={`relative shrink-0 grid h-8 w-8 place-items-center rounded-lg border ${fileLevelCount > 0 ? 'border-accent bg-accent/20 text-accent' : 'border-subtle text-muted hover:bg-neutral-soft hover:text-primary'}`}
        >
          <Icon name="chat" size={14} />
          {fileLevelCount > 0 ? <span className="absolute -right-1 -top-1 grid h-4 min-w-4 place-items-center rounded-full bg-accent px-1 text-[9px] font-bold text-accent-fg">{fileLevelCount}</span> : null}
        </button>
        {/* View controls */}
        {isMarkdown ? (
          <button
            data-debug-id={`${debugPrefix}-file-md-toggle-btn`}
            type="button"
            onClick={() => setMdRendered((v) => !v)}
            className="shrink-0 rounded-lg border border-subtle px-2 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary"
            title={mdRendered ? 'View source' : 'View rendered'}
          >
            {mdRendered ? 'Source' : 'Rendered'}
          </button>
        ) : null}
        {showCode ? (
          <button
            data-debug-id={`${debugPrefix}-file-wrap-toggle-btn`}
            type="button"
            onClick={() => setWrap((v) => !v)}
            aria-pressed={wrap ? 'true' : 'false'}
            className={`shrink-0 rounded-lg border px-2 py-1 text-caption ${wrap ? 'border-accent bg-accent/20 text-accent' : 'border-subtle text-muted hover:bg-neutral-soft hover:text-primary'}`}
            title={wrap ? 'Disable soft wrap' : 'Enable soft wrap'}
          >
            Wrap
          </button>
        ) : null}
      </div>

      <div
        className="min-h-0 flex-1 overflow-auto bg-canvas"
        onScroll={(e) => {
          if (!hasMore || loadingMore) return;
          const el = e.currentTarget;
          // Near-bottom (within ~600px) => fetch the next byte page.
          if (el.scrollHeight - el.scrollTop - el.clientHeight < 600) onLoadMore();
        }}
      >
        {/* File-level comments (line 0), shown above the content. */}
        {comments.filter((c) => c.line === 0).length > 0 ? (
          <div data-debug-id={`${debugPrefix}-file-comments`} className="border-b border-subtle bg-surface-raised p-2">
            {comments.filter((c) => c.line === 0).map((c) => (
              <LineComment key={c.id} comment={c} debugPrefix={debugPrefix} gutterWidthCh={0} onEdit={onEditComment} onDelete={onDeleteComment} />
            ))}
          </div>
        ) : null}
        {fetching && !content ? (
          <div className="p-4 text-center text-xs text-muted">Loading…</div>
        ) : !file.viewable ? (
          <div data-debug-id={`${debugPrefix}-file-unviewable`} className="grid h-full place-items-center p-6 text-center text-xs text-muted">
            {file.error?.cause === 'file_too_large'
              ? `This file is too large to preview (${formatBytes(file.size)}).`
              : file.error?.cause === 'unsupported_type'
                ? 'This file type cannot be previewed.'
                : str(file.error?.message) || 'This file cannot be previewed.'}
          </div>
        ) : isImage ? (
          <div className="grid h-full place-items-center p-4">
            {/* eslint-disable-next-line jsx-a11y/img-redundant-alt */}
            <img data-debug-id={`${debugPrefix}-file-image`} src={dataUri} alt={name} className="max-h-full max-w-full rounded-lg object-contain" />
          </div>
        ) : isMarkdown && mdRendered ? (
          <div data-debug-id={`${debugPrefix}-file-markdown`} className="p-3">
            <MarkdownBody source={content} className="text-primary" />
          </div>
        ) : (
          <>
            <CodeLines
              content={content}
              path={file.path}
              wrap={wrap}
              debugPrefix={debugPrefix}
              comments={comments}
              onAddComment={onAddComment}
              onEditComment={onEditComment}
              onDeleteComment={onDeleteComment}
            />
            {hasMore ? (
              <div className="flex justify-center py-2">
                <button
                  data-debug-id={`${debugPrefix}-file-load-more-btn`}
                  type="button"
                  onClick={onLoadMore}
                  disabled={loadingMore}
                  className="rounded-lg border border-subtle px-3 py-1.5 text-caption text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-50"
                >
                  {loadingMore ? 'Loading…' : 'Load more of this file'}
                </button>
              </div>
            ) : null}
          </>
        )}
      </div>

      {file.truncated ? (
        <div className="border-t border-warning/30 bg-warning-soft px-3 py-1.5 text-center text-[10px] text-warning">
          Preview truncated.
        </div>
      ) : null}
    </div>
  );
}

// CodeLines renders text/code as ONE ROW PER LINE (gutter cell + highlighted code
// cell), which enables the interactive line gutter (hover comment button) and
// inline comment widgets that a monolithic <pre> can't host. Highlighting comes
// from Shiki per-line tokens; it degrades gracefully to plain text (same row
// structure) while tokens resolve or when the language is unknown/unsupported.
function CodeLines({
  content,
  path,
  wrap,
  debugPrefix,
  comments,
  onAddComment,
  onEditComment,
  onDeleteComment,
}: {
  content: string;
  path: string;
  wrap: boolean;
  debugPrefix: string;
  comments: FileLineComment[];
  onAddComment: (line: number, lineText: string, body: string) => void;
  onEditComment: (id: string, body: string) => void;
  onDeleteComment: (id: string) => void;
}) {
  const [tokenLines, setTokenLines] = useState<CodeToken[][] | null>(null);
  const lang = useMemo(() => languageForFile(path), [path]);

  // Raw source split into lines (the fallback + the source-of-truth for line text
  // used in the published message). Drop a single trailing empty line so a final
  // newline doesn't render a phantom row.
  const rawLines = useMemo(() => {
    const arr = (content || '').split('\n');
    if (arr.length > 1 && arr[arr.length - 1] === '') arr.pop();
    return arr;
  }, [content]);

  useEffect(() => {
    let cancelled = false;
    setTokenLines(null);
    if (!content || !lang) return;
    highlightToLines(content, lang).then((out) => {
      if (!cancelled) setTokenLines(out);
    });
    return () => {
      cancelled = true;
    };
  }, [content, lang]);

  // line (1-based) -> comments; and which line has an open composer.
  const commentsByLine = useMemo(() => {
    const m = new Map<number, FileLineComment[]>();
    for (const c of comments) {
      const list = m.get(c.line) || [];
      list.push(c);
      m.set(c.line, list);
    }
    return m;
  }, [comments]);
  const [composerLine, setComposerLine] = useState<number | null>(null);

  const lineCount = Math.max(1, rawLines.length);
  const gutterWidthCh = Math.max(2, String(lineCount).length) + 1;

  return (
    <div data-debug-id={`${debugPrefix}-file-code`} className="min-w-0 py-2 font-mono text-[12px] leading-5">
      {Array.from({ length: lineCount }, (_, i) => {
        const lineNo = i + 1;
        const lineText = rawLines[i] ?? '';
        const tokens = tokenLines?.[i];
        const lineComments = commentsByLine.get(lineNo) || [];
        return (
          <div key={lineNo} data-debug-id={`${debugPrefix}-line-${lineNo}`}>
            <div className="group flex items-start hover:bg-neutral-soft">
              {/* Gutter: line number + hover comment button */}
              <div
                className="relative flex shrink-0 select-none items-center justify-end border-r border-subtle bg-surface pr-2 text-right text-faint"
                style={{ width: `calc(${gutterWidthCh}ch + 22px)` }}
              >
                <button
                  data-debug-id={`${debugPrefix}-line-comment-btn-${lineNo}`}
                  type="button"
                  onClick={() => setComposerLine((v) => (v === lineNo ? null : lineNo))}
                  title="Comment on this line"
                  aria-label={`Comment on line ${lineNo}`}
                  className={`absolute left-1 grid h-4 w-4 place-items-center rounded text-accent ${lineComments.length > 0 ? 'opacity-100' : 'opacity-0 group-hover:opacity-100'} hover:bg-accent/20`}
                >
                  {lineComments.length > 0 ? (
                    <span className="text-[9px] font-bold">{lineComments.length}</span>
                  ) : (
                    <Icon name="chat" size={11} />
                  )}
                </button>
                <button
                  type="button"
                  onClick={() => setComposerLine((v) => (v === lineNo ? null : lineNo))}
                  className="cursor-pointer tabular-nums hover:text-primary"
                >
                  {lineNo}
                </button>
              </div>
              {/* Code cell */}
              <div className={`min-w-0 flex-1 overflow-x-auto px-3 text-primary ${wrap ? 'whitespace-pre-wrap break-words' : 'whitespace-pre'}`}>
                {tokens ? (
                  tokens.length > 0 ? (
                    tokens.map((t, ti) => (
                      <span key={ti} style={t.color ? { color: t.color } : undefined}>{t.content}</span>
                    ))
                  ) : (
                    // Preserve blank-line height.
                    <span>{'\u00a0'}</span>
                  )
                ) : (
                  <span>{lineText || '\u00a0'}</span>
                )}
              </div>
            </div>

            {/* Existing comments for this line */}
            {lineComments.map((c) => (
              <LineComment
                key={c.id}
                comment={c}
                debugPrefix={debugPrefix}
                gutterWidthCh={gutterWidthCh}
                onEdit={onEditComment}
                onDelete={onDeleteComment}
              />
            ))}

            {/* Inline composer for a new comment */}
            {composerLine === lineNo ? (
              <LineComposer
                debugPrefix={debugPrefix}
                lineNo={lineNo}
                gutterWidthCh={gutterWidthCh}
                onCancel={() => setComposerLine(null)}
                onSave={(body) => {
                  onAddComment(lineNo, lineText, body);
                  setComposerLine(null);
                }}
              />
            ) : null}
          </div>
        );
      })}
    </div>
  );
}

// A saved line comment bubble with edit/delete, indented under its line.
function LineComment({
  comment,
  debugPrefix,
  gutterWidthCh,
  onEdit,
  onDelete,
}: {
  comment: FileLineComment;
  debugPrefix: string;
  gutterWidthCh: number;
  onEdit: (id: string, body: string) => void;
  onDelete: (id: string) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(comment.body);
  return (
    <div className="flex" style={{ paddingLeft: `calc(${gutterWidthCh}ch + 22px)` }}>
      <div data-debug-id={`${debugPrefix}-line-comment-${comment.id}`} className="my-1 mr-3 min-w-0 flex-1 rounded-lg border border-accent/30 bg-accent/10 px-2.5 py-1.5 font-sans text-[12px]">
        {editing ? (
          <div>
            <textarea
              data-debug-id={`${debugPrefix}-line-comment-edit-input-${comment.id}`}
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              rows={2}
              className="w-full resize-y rounded border border-subtle bg-surface-raised p-1.5 text-[12px] text-primary focus:border-accent focus:outline-none"
            />
            <div className="mt-1 flex justify-end gap-1.5">
              <button type="button" onClick={() => { setDraft(comment.body); setEditing(false); }} className="rounded border border-subtle px-2 py-0.5 text-caption text-muted hover:bg-neutral-soft hover:text-primary">Cancel</button>
              <button data-debug-id={`${debugPrefix}-line-comment-edit-save-${comment.id}`} type="button" onClick={() => { onEdit(comment.id, draft); setEditing(false); }} className="rounded bg-accent px-2 py-0.5 text-caption font-semibold text-accent-fg hover:opacity-90">Save</button>
            </div>
          </div>
        ) : (
          <div className="flex items-start gap-2">
            <div className="min-w-0 flex-1 whitespace-pre-wrap break-words text-primary">{comment.body}</div>
            <div className="flex shrink-0 items-center gap-1">
              <button data-debug-id={`${debugPrefix}-line-comment-edit-${comment.id}`} type="button" onClick={() => { setDraft(comment.body); setEditing(true); }} title="Edit" className="grid h-5 w-5 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"><Icon name="pencil" size={12} /></button>
              <button data-debug-id={`${debugPrefix}-line-comment-delete-${comment.id}`} type="button" onClick={() => onDelete(comment.id)} title="Delete" className="grid h-5 w-5 place-items-center rounded text-muted hover:bg-danger-soft hover:text-danger"><Icon name="trash" size={12} /></button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

// Inline new-comment composer, indented under its line.
function LineComposer({
  debugPrefix,
  lineNo,
  gutterWidthCh,
  onSave,
  onCancel,
}: {
  debugPrefix: string;
  lineNo: number;
  gutterWidthCh: number;
  onSave: (body: string) => void;
  onCancel: () => void;
}) {
  const [draft, setDraft] = useState('');
  const ref = useRef<HTMLTextAreaElement | null>(null);
  useEffect(() => { ref.current?.focus(); }, []);
  return (
    <div data-debug-id={`${debugPrefix}-line-composer-${lineNo}`} className="flex" style={{ paddingLeft: `calc(${gutterWidthCh}ch + 22px)` }}>
      <div className="my-1 mr-3 min-w-0 flex-1 font-sans">
        <textarea
          ref={ref}
          data-debug-id={`${debugPrefix}-line-composer-input-${lineNo}`}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Escape') { e.preventDefault(); onCancel(); }
            if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') { e.preventDefault(); if (draft.trim()) onSave(draft); }
          }}
          rows={2}
          placeholder={`Comment on line ${lineNo}… (Cmd/Ctrl+Enter to save)`}
          className="w-full resize-y rounded border border-subtle bg-surface-raised p-1.5 text-[12px] text-primary placeholder:text-muted focus:border-accent focus:outline-none"
        />
        <div className="mt-1 flex justify-end gap-1.5">
          <button data-debug-id={`${debugPrefix}-line-composer-cancel-${lineNo}`} type="button" onClick={onCancel} className="rounded border border-subtle px-2 py-0.5 text-caption text-muted hover:bg-neutral-soft hover:text-primary">Cancel</button>
          <button data-debug-id={`${debugPrefix}-line-composer-save-${lineNo}`} type="button" onClick={() => { if (draft.trim()) onSave(draft); }} disabled={!draft.trim()} className="rounded bg-accent px-2 py-0.5 text-caption font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50">Comment</button>
        </div>
      </div>
    </div>
  );
}
