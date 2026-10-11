// T11-UI-5: right-hand, browser-like preview sidebar.
//
// Replaces the old inline preview pane that lived inside the shells table. Any
// number of running server sessions can be open as tabs; each tab has its own URL
// bar, back/refresh chrome, and iframe. Nothing renders at all when no tab is open,
// so it costs no layout on every other route.
//
// Two presentations, one behaviour: a resizable right-hand aside on pointer widths,
// and — since a preview cannot share the width of a phone with the main content —
// the bottom slide-up sheet (@ui Drawer side="bottom") the app already uses for
// mobile detail surfaces.
import { useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Drawer } from '@ui';
import Icon from '../Icon';
import { TOUCH_TARGET_CLASS, useIsMobile } from '../shell/responsive';
import { useGetShellSessionQuery } from '../../api/endpoints/shells';
import {
  closeTab,
  focusTab,
  selectActivePreviewTabId,
  selectPreviewOpenSeq,
  selectPreviewTabs,
  setTabPath,
  type PreviewTab,
} from '../../store/previewTabsSlice';
import { previewAccessUrl } from './shellModel';

// A session that is no longer running can never serve the iframe, so its tab is
// closed for the user instead of leaving a dead frame behind.
const DEAD_STATUSES = new Set(['exited', 'killed', 'failed']);

const MIN_WIDTH = 320;
const MAX_WIDTH = 1800;
const DEFAULT_WIDTH = 480;
const WIDTH_STORAGE_KEY = 'heimdall:shell:preview-sidebar-width';

function readStoredWidth(): number {
  try {
    const raw = Number(localStorage.getItem(WIDTH_STORAGE_KEY));
    if (Number.isFinite(raw) && raw >= MIN_WIDTH && raw <= MAX_WIDTH) return raw;
  } catch (_err) { /* private mode / blocked storage — fall through to the default */ }
  return DEFAULT_WIDTH;
}

// Watches one open tab's session and closes the tab once the session stops running.
//
// REQ-SHELL-6 §6: no pollingInterval. The comment that used to sit here was correct at
// the time — it said a WS-only implementation "would never fire" because the hub emits
// no event this UI listens for, and that the poll could be dropped once the
// invalidation path worked. That is now the case: the hub DOES publish
// `shell_session_exited` on every terminal status (shell_session_service.odin:1342),
// and wsInvalidation handles it and invalidates the `ShellSession` tag for that id,
// which forces this very query to refetch. The gap was never the event; it was that
// the UI listened for a type nothing produced.
function usePreviewTabLiveness(sessionId: string) {
  const dispatch = useDispatch();
  const { data: session } = useGetShellSessionQuery({ sessionId });
  const status = session?.status;

  useEffect(() => {
    if (status && DEAD_STATUSES.has(status)) dispatch(closeTab(sessionId));
  }, [dispatch, sessionId, status]);
}

// One watcher per open tab, rendered in EVERY branch below — collapsed rail and
// mobile pill included. The watch cannot live inside PreviewFrame: collapsing the
// sidebar unmounts the frames, which would stop the polling exactly when the user
// can no longer see that a session has died, leaving a stale count on the rail.
function PreviewTabWatcher({ sessionId }: { sessionId: string }) {
  usePreviewTabLiveness(sessionId);
  return null;
}

function getIframeRelativePath(win: Window, sessionId: string): string {
  try {
    const url = new URL(win.location.href);
    const prefix = `/api/v1/preview/${encodeURIComponent(sessionId)}/`;
    const full = url.pathname + url.search + url.hash;
    return full.startsWith(prefix) ? full.slice(prefix.length) : full.replace(/^\//, '');
  } catch {
    return '';
  }
}

const MAX_NAV_STACK = 50;

function PreviewFrame({ tab, hidden }: { tab: PreviewTab; hidden: boolean }) {
  const dispatch = useDispatch();
  // Read-only: the watcher above owns the polling for this session, and this
  // subscribes to the same RTK Query cache entry — so this costs no extra request
  // and only drives the "Starting…" overlay.
  const { data: session, isError: sessionLoadFailed } = useGetShellSessionQuery({ sessionId: tab.sessionId });
  const status = session?.status;
  // Draft is what the user is typing; it only becomes the iframe URL on submit, so
  // the frame does not reload on every keystroke.
  const [draft, setDraft] = useState(tab.currentPath);
  // Bumped to force a remount of the iframe — the only reliable same-origin reload
  // that does not depend on reaching into the frame's contentWindow.
  const [reloadKey, setReloadKey] = useState(0);
  const previewBaseUrl = useMemo(
    () => session ? previewAccessUrl(session) : '',
    [session],
  );
  const src = session ? `${previewBaseUrl}${tab.currentPath}` : '';
  const isCrossOrigin = useMemo(() => {
    if (typeof window === 'undefined') return false;
    try {
      return new URL(previewBaseUrl, window.location.origin).origin !== window.location.origin;
    } catch {
      return false;
    }
  }, [previewBaseUrl]);
  const iframeRef = useRef<HTMLIFrameElement>(null);
  // Local nav stack so the back button can go to the previous path, not just root.
  const navStackRef = useRef<string[]>([]);
  const [canGoBack, setCanGoBack] = useState(false);

  // Keep the draft in step when the path changes from outside this input (a tab
  // reopened at a remembered path, say).
  useEffect(() => { setDraft(tab.currentPath); }, [tab.currentPath]);

  // A cross-origin frame is intentionally opaque. Its navigation history is the
  // paths submitted through our own URL bar, so initialize that local history
  // once per tab/origin mode without ever touching contentWindow.
  useEffect(() => {
    if (!isCrossOrigin) return;
    navStackRef.current = [tab.currentPath];
    setCanGoBack(false);
  // `currentPath` is the initial value only; subsequent changes are appended by
  // submitPath/handleBack and must not reset the stack.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isCrossOrigin, tab.sessionId]);

  // Terminate active network connections, audio/video playback, and worker threads
  // in the embedded document when the frame is unmounted.
  useEffect(() => {
    const iframe = iframeRef.current;
    return () => {
      if (iframe) {
        try {
          iframe.src = 'about:blank';
        } catch { /* ignore */ }
      }
    };
  }, [previewBaseUrl, reloadKey]);

  // Sync URL bar from iframe navigation (load, hash changes, and popstate).
  // Works because the preview URL (/api/v1/preview/…) is same-origin with the hub.
  useEffect(() => {
    const iframe = iframeRef.current;
    if (!iframe) return;
    if (isCrossOrigin) return;
    navStackRef.current = [];
    setCanGoBack(false);

    let attachedWin: Window | null = null;

    function detachInnerWindow() {
      if (!attachedWin) return;
      try {
        attachedWin.removeEventListener('hashchange', syncFromIframe);
        attachedWin.removeEventListener('popstate', syncFromIframe);
      } catch { /* cross-origin / destroyed */ }
      attachedWin = null;
    }

    function syncFromIframe() {
      const win = iframeRef.current?.contentWindow;
      if (!win) return;
      try {
        const path = getIframeRelativePath(win, tab.sessionId);
        setDraft(path);
        const currentStack = navStackRef.current;
        if (currentStack.length === 0 || currentStack[currentStack.length - 1] !== path) {
          const next = [...currentStack, path];
          navStackRef.current = next.length > MAX_NAV_STACK ? next.slice(next.length - MAX_NAV_STACK) : next;
        }
        setCanGoBack(navStackRef.current.length > 1);
      } catch { /* cross-origin — nothing to do */ }
    }

    function onLoad() {
      detachInnerWindow();
      syncFromIframe();
      // Re-attach inner-window events after each full page load (they're lost on
      // document replace). SPA hash/popstate navigation won't fire a frame load,
      // so we attach them here to catch back/forward inside the embedded app.
      try {
        const win = iframe.contentWindow;
        if (!win) return;
        win.addEventListener('hashchange', syncFromIframe);
        win.addEventListener('popstate', syncFromIframe);
        attachedWin = win;
      } catch { /* cross-origin */ }
    }

    iframe.addEventListener('load', onLoad);
    return () => {
      iframe.removeEventListener('load', onLoad);
      detachInnerWindow();
    };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isCrossOrigin, previewBaseUrl, reloadKey, tab.sessionId]);

  const handleBack = () => {
    const stack = navStackRef.current;
    if (stack.length > 1) {
      // Pop current, show previous.
      stack.pop();
      const prev = stack[stack.length - 1] ?? '';
      navStackRef.current = stack;
      setCanGoBack(stack.length > 1);
      setDraft(prev);
      if (isCrossOrigin) {
        dispatch(setTabPath({ sessionId: tab.sessionId, path: prev }));
        setReloadKey((key) => key + 1);
        return;
      }
      // Prefer the iframe's own history so SPA state is preserved.
      try {
        iframeRef.current?.contentWindow?.history.back();
        return;
      } catch { /* cross-origin */ }
      // Fallback: full reload to the previous path.
      dispatch(setTabPath({ sessionId: tab.sessionId, path: prev }));
      setReloadKey((key) => key + 1);
    }
  };

  const submitPath = (event: React.FormEvent) => {
    event.preventDefault();
    const path = draft.replace(/^\/+/, '');
    if (isCrossOrigin) {
      const currentStack = navStackRef.current;
      if (currentStack[currentStack.length - 1] !== path) {
        const next = [...currentStack, path];
        navStackRef.current = next.length > MAX_NAV_STACK ? next.slice(next.length - MAX_NAV_STACK) : next;
      }
      setCanGoBack(navStackRef.current.length > 1);
    }
    dispatch(setTabPath({ sessionId: tab.sessionId, path }));
    setReloadKey((key) => key + 1);
  };

  return (
    <div
      data-debug-id={`preview-sidebar-frame-${tab.sessionId}`}
      // Hidden rather than unmounted: switching tabs must not throw away the
      // previewed page's scroll position and in-page state.
      className={`min-h-0 flex-1 flex-col ${hidden ? 'hidden' : 'flex'}`}
    >
      {/* Chrome bar: back, refresh, URL */}
      <form
        onSubmit={submitPath}
        className="flex items-center gap-1 border-b border-subtle bg-surface-raised px-2 py-1.5"
      >
        <button
          type="button"
          title="Back"
          aria-label="Back"
          data-debug-id={`preview-sidebar-back-${tab.sessionId}`}
          disabled={!canGoBack}
          onClick={handleBack}
          className="grid h-6 w-6 shrink-0 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary disabled:cursor-not-allowed disabled:opacity-40"
        >
          <Icon name="arrow-left" size={13} />
        </button>
        <button
          type="button"
          title="Reload preview"
          aria-label="Reload preview"
          data-debug-id={`preview-sidebar-refresh-${tab.sessionId}`}
          onClick={() => setReloadKey((key) => key + 1)}
          className="grid h-6 w-6 shrink-0 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
        >
          <Icon name="refresh" size={13} />
        </button>
        <span className="shrink-0 select-none font-mono text-[10px] text-faint">:{tab.port}/</span>
        <input
          type="text"
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
          placeholder="path inside the server, e.g. docs/index.html"
          aria-label="Preview path"
          data-debug-id={`preview-sidebar-url-${tab.sessionId}`}
          className="min-w-0 flex-1 rounded border border-subtle bg-surface px-2 py-1 font-mono text-[11px] text-primary placeholder:text-faint focus:outline-none focus:ring-1 focus:ring-accent"
        />
        {isCrossOrigin ? (
          <button
            type="button"
            onClick={() => window.open(previewBaseUrl, '_blank', 'noopener,noreferrer')}
            title="If the preview asks you to sign in, open it in a new tab once."
            data-debug-id={`preview-sidebar-sign-in-${tab.sessionId}`}
            className="shrink-0 rounded border border-subtle px-2 py-1 text-[10px] font-medium text-muted hover:bg-neutral-soft hover:text-primary"
          >
            Sign in / open in new tab
          </button>
        ) : null}
      </form>

      {/* Frame */}
      <div className="relative min-h-0 flex-1 bg-surface">
        {!session ? (
          <div className="absolute inset-0 grid place-items-center text-xs text-muted">
            {sessionLoadFailed ? 'Preview details unavailable.' : 'Loading preview…'}
          </div>
        ) : status === 'starting' ? (
          <div className="absolute inset-0 grid place-items-center text-xs text-muted">Starting…</div>
        ) : null}
        {session ? (
          <iframe
            ref={iframeRef}
            // Remounting on reloadKey IS the refresh. Crucially, the frame does
            // not exist until its canonical preview_url has loaded from the Hub.
            key={`${tab.sessionId}:${reloadKey}`}
            src={src}
            title={`Preview: ${tab.label}`}
            className="h-full w-full border-0"
            sandbox="allow-same-origin allow-scripts allow-forms allow-popups"
          />
        ) : null}
      </div>
    </div>
  );
}

// The tab strip + frames, shared by the desktop aside and the mobile sheet so the
// two presentations can never drift on behaviour.
function PreviewTabStrip({
  tabs,
  activeId,
  onCollapse,
  collapseLabel,
  touch,
}: {
  tabs: PreviewTab[];
  activeId: string;
  onCollapse: () => void;
  collapseLabel: string;
  touch: boolean;
}) {
  const dispatch = useDispatch();
  const hit = touch ? TOUCH_TARGET_CLASS : '';
  return (
    <div className="flex shrink-0 items-center gap-1 border-b border-subtle bg-surface-raised px-1.5 py-1">
      <div className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto">
        {tabs.map((tab) => {
          const active = tab.sessionId === activeId;
          return (
            <div
              key={tab.sessionId}
              data-debug-id={`preview-sidebar-tab-${tab.sessionId}`}
              className={`flex shrink-0 items-center gap-1 rounded-t border-b-2 px-2 py-1 text-[11px] transition-colors ${
                active
                  ? 'border-accent bg-surface font-semibold text-primary'
                  : 'border-transparent text-muted hover:bg-neutral-soft hover:text-primary'
              }`}
            >
              <button
                type="button"
                onClick={() => dispatch(focusTab(tab.sessionId))}
                title={`${tab.label}:${tab.port}`}
                className={`max-w-[140px] truncate ${touch ? 'min-h-11' : ''}`}
              >
                {tab.label}
                <span className="ml-1 font-mono text-[10px] text-faint">:{tab.port}</span>
              </button>
              <button
                type="button"
                title="Close tab"
                aria-label={`Close preview ${tab.label}`}
                data-debug-id={`preview-sidebar-tab-close-${tab.sessionId}`}
                onClick={() => dispatch(closeTab(tab.sessionId))}
                className={`grid place-items-center rounded text-faint hover:bg-neutral-soft hover:text-primary ${touch ? TOUCH_TARGET_CLASS : 'h-4 w-4'}`}
              >
                <Icon name="close" size={touch ? 14 : 10} />
              </button>
            </div>
          );
        })}
      </div>
      <button
        type="button"
        title={collapseLabel}
        aria-label={collapseLabel}
        data-debug-id="preview-sidebar-collapse-btn"
        onClick={onCollapse}
        className={`grid shrink-0 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary ${hit || 'h-6 w-6'}`}
      >
        <Icon name="panel-right" size={touch ? 16 : 13} />
      </button>
    </div>
  );
}

export function PreviewSidebar() {
  const tabs = useSelector(selectPreviewTabs);
  const activeTabId = useSelector(selectActivePreviewTabId);
  const openSeq = useSelector(selectPreviewOpenSeq);
  const isMobile = useIsMobile();
  const [collapsed, setCollapsed] = useState(false);
  const seenOpenSeq = useRef(openSeq);
  const [width, setWidth] = useState<number>(readStoredWidth);
  const draggingRef = useRef(false);

  // Pressing "Open Preview" must always show the preview. Collapsing is a view
  // preference, not a decision about the next session the user opens, so any
  // openTab — a new tab, or re-opening one already there — expands the panel again.
  // Without this the button looks like a no-op while collapsed: the tab is created
  // but nothing appears except a count ticking up on the rail.
  useEffect(() => {
    if (openSeq === seenOpenSeq.current) return;
    seenOpenSeq.current = openSeq;
    setCollapsed(false);
  }, [openSeq]);

  // Drag-to-resize on the left edge. Listeners live on window so the drag survives
  // the pointer leaving the 1px handle, and are torn down with the component.
  useEffect(() => {
    function onMove(event: MouseEvent) {
      if (!draggingRef.current) return;
      const maxAllowed = Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, window.innerWidth - 320));
      const next = Math.min(maxAllowed, Math.max(MIN_WIDTH, window.innerWidth - event.clientX));
      setWidth(next);
    }
    function onUp() {
      if (!draggingRef.current) return;
      draggingRef.current = false;
      document.body.style.userSelect = '';
      setWidth((current) => {
        try { localStorage.setItem(WIDTH_STORAGE_KEY, String(current)); } catch (_err) {}
        return current;
      });
    }
    window.addEventListener('mousemove', onMove);
    window.addEventListener('mouseup', onUp);
    return () => {
      window.removeEventListener('mousemove', onMove);
      window.removeEventListener('mouseup', onUp);
      document.body.style.userSelect = '';
    };
  }, []);

  if (tabs.length === 0) return null;

  const activeId = activeTabId || tabs[0].sessionId;
  const frames = tabs.map((tab) => (
    <PreviewFrame key={tab.sessionId} tab={tab} hidden={tab.sessionId !== activeId} />
  ));
  // Rendered by every branch, collapsed ones included — see PreviewTabWatcher.
  const watchers = tabs.map((tab) => <PreviewTabWatcher key={`watch:${tab.sessionId}`} sessionId={tab.sessionId} />);

  // Mobile: a preview cannot share the width of a phone with the main content, so
  // it becomes the bottom slide-up sheet the codebase already uses for detail
  // surfaces (@ui Drawer side="bottom" — portal, focus trap, Esc, scroll lock).
  // Dismissing the sheet only collapses it; the tabs stay open behind the pill.
  if (isMobile) {
    if (collapsed) {
      return (
        <>
        {watchers}
        <button
          type="button"
          title={`Show preview (${tabs.length})`}
          aria-label={`Show preview (${tabs.length})`}
          data-debug-id="preview-sidebar-expand-btn"
          onClick={() => setCollapsed(false)}
          // Positioned below the sidebar toggle icon on mobile.
          className={`fixed top-16 right-3 z-40 inline-flex items-center gap-1.5 rounded-full border border-subtle bg-surface px-3 shadow-panel text-accent md:hidden ${TOUCH_TARGET_CLASS}`}
        >
          <Icon name="panel-right" size={16} />
          <span className="text-xs font-bold">{tabs.length}</span>
        </button>
        </>
      );
    }
    return (
      <Drawer
        open
        onOpenChange={(next) => { if (!next) setCollapsed(true); }}
        title="Preview"
        side="bottom"
        hideHeader
        fullHeight
        data-debug-id="preview-sidebar-sheet"
        className="ui-safe-top ui-safe-bottom h-full max-h-full md:hidden"
      >
        <div className="flex h-full min-h-0 flex-col">
          {watchers}
          <PreviewTabStrip
            tabs={tabs}
            activeId={activeId}
            onCollapse={() => setCollapsed(true)}
            collapseLabel="Hide preview"
            touch
          />
          {frames}
        </div>
      </Drawer>
    );
  }

  if (collapsed) {
    return (
      <aside
        data-debug-id="preview-sidebar-collapsed"
        className="flex w-10 shrink-0 flex-col items-center gap-2 border-l border-subtle bg-surface py-2"
        aria-label="Preview sidebar (collapsed)"
      >
        {watchers}
        <button
          type="button"
          title={`Show preview (${tabs.length})`}
          aria-label={`Show preview (${tabs.length})`}
          data-debug-id="preview-sidebar-expand-btn"
          onClick={() => setCollapsed(false)}
          className="grid h-8 w-8 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
        >
          <Icon name="panel-right" size={15} />
        </button>
        <span className="rounded bg-accent/15 px-1 text-[10px] font-bold text-accent">{tabs.length}</span>
      </aside>
    );
  }

  return (
    <aside
      data-debug-id="preview-sidebar"
      style={{ width }}
      className="relative flex h-full min-h-0 shrink-0 flex-col border-l border-subtle bg-surface"
      aria-label="Preview sidebar"
    >
      {/* Resize handle */}
      <div
        data-debug-id="preview-sidebar-resize-handle"
        role="separator"
        aria-orientation="vertical"
        onMouseDown={() => {
          draggingRef.current = true;
          document.body.style.userSelect = 'none';
        }}
        className="absolute inset-y-0 -left-1 z-10 w-2 cursor-col-resize hover:bg-accent/30"
      />

      {watchers}
      <PreviewTabStrip
        tabs={tabs}
        activeId={activeId}
        onCollapse={() => setCollapsed(true)}
        collapseLabel="Hide preview"
        touch={false}
      />
      {frames}
    </aside>
  );
}

export default PreviewSidebar;
