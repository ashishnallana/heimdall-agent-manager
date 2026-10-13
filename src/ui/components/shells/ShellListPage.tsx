/**
 * ShellListPage — `/shells`.
 * ------------------------------------------------------------------
 * Inherits its shape from AgentListPage/ActionListPage. What differs for shells:
 *
 *  1. **Infinite scroll over a keyset window, with a CLIENT-side search on top.**
 *     Shells is the one resource that has both: it pages (unlike actions) and it has
 *     no server search scope (unlike memory/projects/agents) —
 *     `SEARCH_TYPE_ORDER` (`src/hub/domain/search.odin:11`) has no `shell` entry.
 *     So the query filters the rows ALREADY LOADED. That limit is real and the UI
 *     says so where the user can act on it, in the no-results copy: scroll to load
 *     more and the reach widens. Pretending otherwise would produce "it isn't there"
 *     about a session that is.
 *
 *  2. **Tabs are Live | Finished**, the `shell_session_is_terminal` split, and they
 *     are SERVER-side: the tab is the `status` parameter. See shellModel's header.
 *
 *  3. **The Status filter is constrained to the current tab.** Offering "Exited"
 *     under Live is a filter that can only ever return nothing — the same "offer
 *     only what means something in this state" rule the row menu follows.
 *
 *  4. **Kind is the one client-side filter** and is labelled as such in the drawer.
 *     It is not a query parameter the list endpoint accepts, and inventing a CSV for
 *     it would hit Amendment 8's trap (the hub honours only the first token).
 *
 *  5. **Bulk KILL** is the destructive verb (REQ-UI-7). It skips rows that have
 *     terminated since they were ticked rather than firing a request the hub will
 *     409 (`shell_session_service.odin:236`), says so in the confirm, and reports
 *     partial failure honestly.
 *
 *  6. **Nothing re-sorts under the user, structurally.** The list is ordered by
 *     `started_at`, which never changes for a session, so a status change — the
 *     thing that happens constantly here — repaints a row in place via `patchItem`
 *     and cannot move it. Only genuinely NEW sessions produce the "N new" pill.
 */
import React from 'react';
import {
  ActionButton,
  Alert,
  BulkActionBar,
  Button,
  EmptyState,
  FilterBar,
  Icon,
  Input,
  Modal,
  ModalBody,
  ModalFooter,
  PageShell,
  ResourceContainer,
  ResourceSearchFilter,
  Select,
  Tab,
  Tabs,
  TabsList,
  TabsPanel,
  Text,
  Toast,
  TOUCH_TARGET_CLASS,
  useInfiniteList,
  useViewport,
} from '@ui';
import ShellRow from './ShellRow';
import {
  ShellDetailActions,
  ShellDetailBody,
  ShellDetailHeader,
  ShellDetailMeta,
  ShellDetailOverlays,
  ShellDetailPaneSkeleton,
  useShellDetail,
  usePaneIsWide,
} from './ShellDetail';
import { getRouteSearch } from '../../utils/appLocation';
import {
  fetchShellPage,
  useKillShellMutation,
  useRestartShellMutation,
  useSignalShellMutation,
  type ShellSession,
  type ShellSessionKind,
  type ShellSessionStatus,
} from '../../api/endpoints/shells';
import { useDispatch, useSelector } from 'react-redux';
import { openPreviewInWorkbench } from '../../store/workbenchSlice';
import type { ShellState } from '../../store/shellSlice';
import { SetShellPortDialog } from './SetShellPortDialog';
import { bridgeLabel, catalogNote, projectLabel, useActionCatalog } from '../actions/actionCatalog';
import {
  EMPTY_LIST_URL_STATE,
  KIND_FILTER_OPTIONS,
  VERB_LABEL,
  SHELL_TABS,
  activeFilterCount,
  bulkKillBody,
  bulkKillTitle,
  confirmBody,
  confirmTitle,
  hasActiveFilters,
  isDestructive,
  isTerminal,
  kindLabel,
  listCrumbs,
  matchesQuery,
  navigateTo,
  needsConfirm,
  parseShellListUrl,
  previewAccessUrl,
  rememberRow,
  replaceListSearch,
  restartFailureText,
  shellErrorText,
  shellListHref,
  shellTitle,
  shellViewHref,
  statusLabel,
  statusOptionsForTab,
  statusParamFor,
  takeRememberedRow,
  type ShellListUrlState,
  type ShellTab,
  type ShellVerb,
} from './shellModel';

const SEARCH_DEBOUNCE_MS = 250;
const PAGE_SIZE = 25;

type ToastEntry = {
  id: string;
  tone: 'success' | 'danger' | 'info';
  title: string;
  message?: string;
};

export default function ShellListPage({ selectedId = '' }: { selectedId?: string } = {}) {
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
  const twoPane = viewport === 'desktop';
  const searchRef = React.useRef<HTMLInputElement | null>(null);
  const catalog = useActionCatalog();

  /* ---------------- URL state ---------------- */
  const [urlState, setUrlState] = React.useState<ShellListUrlState>(() =>
    parseShellListUrl(getRouteSearch()),
  );
  const tab: ShellTab = urlState.tab || 'live';
  const searching = Boolean(urlState.q);
  const filtersActive = hasActiveFilters(urlState);

  const applyUrlState = React.useCallback((next: ShellListUrlState) => {
    setUrlState(next);
    replaceListSearch(next);
  }, []);

  const clearFilters = React.useCallback(() => {
    applyUrlState({ ...urlState, status: '', bridge: '', project: '', kind: '' });
  }, [applyUrlState, urlState]);

  /* ---------------- Search ---------------- */
  const [queryInput, setQueryInput] = React.useState(urlState.q);
  React.useEffect(() => {
    if (queryInput === urlState.q) return undefined;
    const timer = window.setTimeout(() => {
      applyUrlState({ ...urlState, q: queryInput });
    }, SEARCH_DEBOUNCE_MS);
    return () => window.clearTimeout(timer);
  }, [queryInput, urlState, applyUrlState]);

  /* ---------------- The one data path ----------------
   * There is no second endpoint for search, so unlike Agents there is ONE list here
   * and the query filters it. `resetKey` carries only the SERVER-side narrowings —
   * the tab, the exact status, bridge and project — because those change what the
   * endpoint returns. Kind and the query do not, so changing them must not throw the
   * loaded pages away and re-page from the top.
   *
   * REQ-UI-5 is exact here for the same reason it is on Actions: with a query active
   * the filters are simply not consulted (see `visibleRows`). Per Amendment 7 there
   * is no explanatory banner; the signals are the inert Filters control and a tab
   * strip with nothing selected. */
  const serverStatus = statusParamFor(tab, urlState.status);
  const list = useInfiniteList<ShellSession>({
    fetchPage: ({ cursor, signal }) =>
      fetchShellPage({
        limit: PAGE_SIZE,
        cursor,
        signal,
        status: serverStatus,
        bridgeId: urlState.bridge || undefined,
        projectId: urlState.project || undefined,
      }),
    getItemId: (row) => row.session_id,
    // Not the cursor column (that is `session_id`) — this is read ONLY to tell
    // "this row changed" from "this row is the same" when probing for the N-new
    // pill, and `last_activity_at` is the field that moves when a session does
    // anything at all.
    getCursorValue: (row) => `${row.status}:${row.last_activity_at}`,
    resetKey: [serverStatus, urlState.bridge, urlState.project].join('|'),
  });

  /* Live updates (REQ-UI-20), now PUSH-DRIVEN (REQ-SHELL-6 §6).
   *
   * This list is the one shell view no tag invalidation can reach: it pages through
   * `useInfiniteList` with its own `fetchShellPage` promise, not RTK Query, so the 10s
   * interval that used to live here was the only thing telling it a session had
   * changed. Focus-refetch alone — the pattern AgentListPage and ProjectListPage use —
   * would have turned the grep green while quietly downgrading "push" to "refetch when
   * the user clicks away and back", so instead the push handler bumps `shells.eventSeq`
   * from the same place it invalidates the RTK tags (wsInvalidation.ts,
   * invalidateShellSession) and this effect probes page one when it moves.
   *
   * `eventSeq` MUST NOT become a timer — nothing bumps it but the WS handler; see
   * shellSlice.ts. The focus listener is kept because it is a user action, not a poll,
   * and it also covers the one case push cannot: events emitted while the socket was
   * down, which the bus does not replay.
   *
   * `refresh` never touches the rendered rows — it feeds the "N new or updated" pill —
   * so a burst of events can never yank the list out from under the reader. */
  const shellEventSeq = useSelector((state: { shells?: ShellState }) => state.shells?.eventSeq ?? 0);
  const refreshRef = React.useRef(list.refresh);
  refreshRef.current = list.refresh;
  React.useEffect(() => {
    const tick = () => { refreshRef.current(); };
    window.addEventListener('focus', tick);
    return () => window.removeEventListener('focus', tick);
  }, []);
  React.useEffect(() => {
    // Skip the initial render: the list's own first fetch already covers seq 0.
    if (shellEventSeq === 0) return;
    refreshRef.current();
  }, [shellEventSeq]);

  /* ---------------- Query + client-side filters over the loaded rows ---------- */
  const visibleRows = React.useMemo(() => {
    const rows = list.items;
    if (searching) return rows.filter((row) => matchesQuery(row, urlState.q));
    // The tab and the server filters are already applied by the endpoint; only the
    // client-side Kind filter is left to apply here.
    if (urlState.kind) return rows.filter((row) => row.kind === urlState.kind);
    return rows;
  }, [list.items, searching, urlState.kind, urlState.q]);

  /* Kind options come from the rows actually loaded, so the filter can never offer a
     value that matches nothing on screen. */
  const kindOptions = React.useMemo(() => {
    const present = new Set(list.items.map((row) => row.kind));
    return KIND_FILTER_OPTIONS.filter((entry) => present.has(entry.value));
  }, [list.items]);

  const bridgeOptions = React.useMemo(() => {
    const ids = new Set(list.items.map((row) => String(row.bridge_id || '')).filter(Boolean));
    return Array.from(ids)
      .map((id) => ({ id, label: bridgeLabel(id, catalog) || id }))
      .sort((l, r) => l.label.localeCompare(r.label));
  }, [list.items, catalog]);

  const projectOptions = React.useMemo(() => {
    const ids = new Set(list.items.map((row) => String(row.project_id || '')).filter(Boolean));
    return Array.from(ids)
      .map((id) => ({ id, label: projectLabel(id, catalog) || id }))
      .sort((l, r) => l.label.localeCompare(r.label));
  }, [list.items, catalog]);

  /* ---------------- Scroll restoration ----------------
   * Keyed on `list.status` rather than on `list`: the hook hands back a NEW object
   * every render, so depending on it directly would re-run this on every keystroke.
   * `restoreToId` is read through a ref for the same reason. */
  const restoredRef = React.useRef(false);
  const restoreToIdRef = React.useRef(list.restoreToId);
  restoreToIdRef.current = list.restoreToId;
  React.useEffect(() => {
    if (restoredRef.current) return;
    if (list.status !== 'ready') return;
    restoredRef.current = true;
    const rowId = takeRememberedRow();
    if (!rowId) return;
    void restoreToIdRef.current(rowId).then((outcome) => {
      if (outcome !== 'found') return;
      window.requestAnimationFrame(() => {
        const node = document.querySelector(`[data-shell-row="${CSS.escape(rowId)}"]`);
        node?.scrollIntoView({ block: 'center' });
      });
    });
  }, [list.status]);

  /* ---------------- Selection ---------------- */
  const [selectionMode, setSelectionMode] = React.useState(false);
  const [selectedIds, setSelectedIds] = React.useState<string[]>([]);
  React.useEffect(() => {
    setSelectedIds([]);
  }, [tab, urlState.q, urlState.status, urlState.bridge, urlState.project, urlState.kind]);

  /* ---------------- Toasts ---------------- */
  const [toasts, setToasts] = React.useState<ToastEntry[]>([]);
  const pushToast = React.useCallback((entry: Omit<ToastEntry, 'id'>) => {
    const id = `shell-toast-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
    setToasts((prev) => [...prev.slice(-2), { ...entry, id }]);
  }, []);
  const dismissToast = React.useCallback((id: string) => {
    setToasts((prev) => prev.filter((entry) => entry.id !== id));
  }, []);

  /* ---------------- Bulk kill ---------------- */
  const [bulkConfirm, setBulkConfirm] = React.useState<string[] | null>(null);
  const [bulkBusy, setBulkBusy] = React.useState(false);
  const [killShell] = useKillShellMutation();

  const selectedSessions = React.useMemo(
    () => selectedIds.map((id) => list.items.find((row) => row.session_id === id)).filter(Boolean) as ShellSession[],
    [list.items, selectedIds],
  );
  /* A selection made a minute ago can contain rows that have since terminated. The
     hub 409s on those, so they are skipped rather than fired at, and the confirm says
     how many before the fact instead of reporting them as failures after it. */
  const killable = React.useMemo(() => selectedSessions.filter((row) => !isTerminal(row)), [selectedSessions]);
  const skipped = selectedSessions.length - killable.length;

  const runBulkKill = React.useCallback(
    async (ids: string[]) => {
      setBulkBusy(true);
      const failed: string[] = [];
      let done = 0;
      for (const id of ids) {
        try {
          await killShell({ sessionId: id }).unwrap();
          done += 1;
          // Act in place: the row stays exactly where it is and repaints as killed.
          list.patchItem(id, (prev) => ({ ...prev, status: 'killed' as ShellSessionStatus }));
        } catch {
          failed.push(id);
        }
      }
      setBulkBusy(false);
      // The rows that failed stay selected, so a retry needs no re-ticking.
      setSelectedIds(failed);
      pushToast({
        tone: failed.length ? 'danger' : 'success',
        title: failed.length ? `${done} of ${ids.length} killed` : `${done} killed`,
        message: failed.length ? 'The sessions that failed are still selected.' : undefined,
      });
    },
    [killShell, list, pushToast],
  );

  /* ---------------- Per-row verbs ----------------
   * The POLICY these share with the detail page — which verbs exist in which state,
   * which of them confirm, and what a restart failure says — lives in `shellModel`
   * and is imported by both. That is what stops the two drifting apart; running the
   * detail page's hook from inside a list row would only couple their lifecycles.
   *
   * `patchItem` is the point of all this: a verb fired from a row repaints THAT row
   * where it sits. Nothing re-sorts, nothing jumps to the top. */
  const [rowConfirm, setRowConfirm] = React.useState<{ session: ShellSession; verb: ShellVerb } | null>(null);
  const [busyRow, setBusyRow] = React.useState('');
  const [portSession, setPortSession] = React.useState<ShellSession | null>(null);
  const [restartShell] = useRestartShellMutation();
  const [signalShell] = useSignalShellMutation();
  const dispatch = useDispatch();

  const executeRowVerb = React.useCallback(
    async (session: ShellSession, verb: ShellVerb) => {
      setBusyRow(session.session_id);
      try {
        if (verb === 'kill') {
          await killShell({ sessionId: session.session_id }).unwrap();
          list.patchItem(session.session_id, (prev) => ({ ...prev, status: 'killed' as ShellSessionStatus }));
          pushToast({ tone: 'success', title: 'Killed', message: 'Its output stays readable.' });
        } else if (verb === 'restart') {
          const next = await restartShell({ sessionId: session.session_id }).unwrap();
          // The hub returns the updated row; patching with the SERVER's copy is what
          // makes the next background probe see it as unchanged rather than as news.
          if (next?.session_id) list.patchItem(next.session_id, next);
          pushToast({ tone: 'success', title: 'Restarted' });
        } else if (verb === 'interrupt') {
          // SIGINT = 2.
          await signalShell({ sessionId: session.session_id, signal: 2 }).unwrap();
          pushToast({
            tone: 'success',
            title: 'SIGINT sent',
            message: 'Whether the process stops is up to the process.',
          });
        }
      } catch (err) {
        pushToast({
          tone: 'danger',
          title: "That didn't work",
          message:
            verb === 'restart'
              ? restartFailureText(err)
              : shellErrorText(err, `Couldn't ${VERB_LABEL[verb].toLowerCase()} this session.`),
        });
      } finally {
        setBusyRow('');
      }
    },
    [killShell, list, pushToast, restartShell, signalShell],
  );

  const runRowVerb = React.useCallback(
    (session: ShellSession, verb: ShellVerb) => {
      if (verb === 'set-port') {
        setPortSession(session);
        return;
      }
      if (verb === 'preview') {
        dispatch(
          openPreviewInWorkbench({
            sessionId: session.session_id,
            label: session.label || session.cmd || session.session_id,
            port: session.server_port,
          }),
        );
        return;
      }
      if (verb === 'copy-url') {
        const url = previewAccessUrl(session);
        void (async () => {
          try {
            if (!navigator.clipboard?.writeText) throw new Error('clipboard unavailable');
            await navigator.clipboard.writeText(url);
            pushToast({ tone: 'success', title: 'Access URL copied' });
          } catch {
            // The failure carries the URL, so it never swallows the only copy of it.
            pushToast({ tone: 'danger', title: "Couldn't copy", message: `The URL is ${url}` });
          }
        })();
        return;
      }
      if (needsConfirm(session, verb)) {
        setRowConfirm({ session, verb });
        return;
      }
      void executeRowVerb(session, verb);
    },
    [dispatch, executeRowVerb, pushToast],
  );

  /* ---------------- Keyboard ----------------
   * j/k move and / focuses search. Kill and Restart are deliberately NOT bound: one
   * destroys a running process and the other restarts it, and neither should be one
   * keystroke away while a list has focus. */
  const [cursorId, setCursorId] = React.useState('');
  const cursorRef = React.useRef('');
  cursorRef.current = cursorId || selectedId;

  React.useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      const target = event.target as HTMLElement | null;
      const tag = target?.tagName?.toLowerCase();
      const typing = tag === 'input' || tag === 'textarea' || tag === 'select' || target?.isContentEditable;
      if (event.key === '/' && !typing) {
        event.preventDefault();
        searchRef.current?.focus();
        return;
      }
      if (typing || bulkConfirm) return;

      const items = visibleRows;
      const index = items.findIndex((row) => row.session_id === cursorRef.current);

      if (event.key === 'j' || event.key === 'k') {
        if (items.length === 0) return;
        event.preventDefault();
        const nextIndex = event.key === 'j'
          ? Math.min(items.length - 1, index < 0 ? 0 : index + 1)
          : Math.max(0, index < 0 ? 0 : index - 1);
        const next = items[nextIndex];
        const nextId = next ? next.session_id : '';
        setCursorId(nextId);
        if (twoPane && nextId) navigateTo(shellViewHref(nextId, urlState));
        const node = nextId ? document.querySelector(`[data-shell-row="${CSS.escape(nextId)}"]`) : null;
        node?.scrollIntoView({ block: 'nearest' });
      }
    }
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [bulkConfirm, twoPane, urlState, visibleRows]);

  /* ---------------- Empty states (REQ-UI-16: all four read differently) -------- */
  function emptyState(): React.ReactNode {
    if (searching) {
      return (
        <EmptyState
          data-debug-id="shell-empty-query"
          icon="search"
          title={`No loaded sessions match "${urlState.q}"`}
          // The honest limit, stated where it can be acted on: this search covers what
          // has been loaded, because the hub has no shell search scope.
          description="Search covers the label, command, working directory, kind, status, port and session ID of the sessions loaded so far. Scroll to load more and the search widens."
          action={<Button variant="secondary" onClick={() => { setQueryInput(''); applyUrlState({ ...urlState, q: '' }); }}>Clear search</Button>}
        />
      );
    }
    if (filtersActive) {
      return (
        <EmptyState
          data-debug-id="shell-empty-filtered"
          icon="search"
          title="No sessions match these filters"
          description="Nothing under this tab matches the filters you have applied."
          action={<Button variant="secondary" onClick={clearFilters}>Clear filters</Button>}
        />
      );
    }
    return tab === 'live' ? (
      <EmptyState
        data-debug-id="shell-empty-live"
        icon="terminal"
        title="Nothing running"
        description="A shell session is a process a bridge is running for you — started by an agent, by a chain, or by `ham-ctl shell`. None is running right now."
      />
    ) : (
      <EmptyState
        data-debug-id="shell-empty-finished"
        icon="terminal"
        title="No finished sessions"
        description="Sessions that have exited, been killed or failed appear here with their output still readable."
      />
    );
  }

  /* ---------------- Rows ---------------- */
  const openSession = React.useCallback(
    (sessionId: string) => {
      if (!sessionId) return;
      rememberRow(sessionId);
      navigateTo(shellViewHref(sessionId, urlState));
    },
    [urlState],
  );

  /** Auto-select the first shell session in two-pane mode if none is selected */
  React.useEffect(() => {
    if (twoPane && !selectedId && visibleRows.length > 0) {
      openSession(visibleRows[0].session_id);
    }
  }, [twoPane, selectedId, visibleRows, openSession]);

  const selectable = !searching;

  const listBody = (
    <>
      {list.status === 'error' ? (
        <Alert tone="danger" title="Couldn't load shell sessions">
          <div className="flex flex-col items-start gap-3">
            <span>{shellErrorText(list.error)}</span>
            <Button size="sm" variant="secondary" onClick={() => list.reload()}>Retry</Button>
          </div>
        </Alert>
      ) : list.isLoadingInitial ? (
        <div role="status" aria-live="polite" aria-busy="true" data-debug-id="shell-list-skeleton">
          <span className="sr-only">Loading shell sessions…</span>
          <ul aria-hidden="true" className="flex flex-col">
            {[0, 1, 2, 3, 4, 5].map((i) => (
              <li key={i} className="flex min-h-[72px] flex-col justify-center gap-2 border-b border-subtle px-3 py-3">
                <div className="h-4 w-2/3 animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
                <div className="h-3 w-5/6 animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
                <div className="h-3 w-1/3 animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
              </li>
            ))}
          </ul>
        </div>
      ) : visibleRows.length === 0 ? (
        emptyState()
      ) : (
        <ul
          aria-label={searching ? 'Shell session search results' : 'Shell sessions'}
          data-debug-id={searching ? 'shell-search-rows' : 'shell-rows'}
          className="flex flex-col"
        >
          {visibleRows.map((row) => (
            <ShellRow
              key={row.session_id}
              row={row}
              href={shellViewHref(row.session_id, urlState)}
              selectable={selectable}
              showCheckbox={selectionMode && selectable}
              selected={selectedIds.includes(row.session_id)}
              active={row.session_id === selectedId}
              onSelectedChange={(next) =>
                setSelectedIds((prev) =>
                  next ? [...prev, row.session_id] : prev.filter((id) => id !== row.session_id),
                )
              }
              busy={busyRow === row.session_id}
              onVerb={runRowVerb}
              onOpen={() => openSession(row.session_id)}
            />
          ))}
        </ul>
      )}

      {/* Paging foot. A paging failure KEEPS the loaded rows and offers a retry strip
          rather than replacing the list with an error. */}
      {list.pagingError ? (
        <div className="flex flex-col items-start gap-2 px-3 py-3" data-debug-id="shell-paging-error">
          <Text as="span" role="body-sm" tone="muted">{shellErrorText(list.pagingError)}</Text>
          <Button size="sm" variant="secondary" onClick={() => list.loadMore()}>Try again</Button>
        </div>
      ) : null}
      {list.isPaging ? (
        <div className="px-3 py-3" aria-hidden="true" data-debug-id="shell-paging-skeleton">
          <div className="h-4 w-1/3 animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
        </div>
      ) : null}
      {/* The sentinel. Infinite scroll only — no numbered pages, no Load more, no
          totals: the endpoint is keyset and returns no count. */}
      {!searching && list.hasMore ? <div ref={list.sentinelRef} aria-hidden="true" className="h-px" /> : null}
    </>
  );

  const listSection = (
    <div className={`flex w-full min-w-0 flex-col gap-4 ${twoPane ? 'flex-1 min-h-0 overflow-hidden' : ''}`}>
      {/* "N new" rather than a silent re-sort: nothing moves under the reader until
          they ask for it (REQ-UI-20). */}
      {list.pendingCount > 0 && !searching ? (
        <div className="flex justify-center shrink-0">
          <Button
            size="sm"
            variant="secondary"
            data-debug-id="shell-pending-pill"
            onClick={() => list.applyPending()}
          >
            {list.pendingCount === 1 ? '1 new or updated session' : `${list.pendingCount} new or updated sessions`}
          </Button>
        </div>
      ) : null}
      {list.restoreNotice ? (
        <div className="shrink-0">
          <Alert tone="info" title="Couldn't find where you were">
            <div className="flex flex-col items-start gap-2">
              <span>That session is no longer near the top of this list. You are back at the start.</span>
              <Button size="sm" variant="ghost" onClick={() => list.dismissRestoreNotice()}>Dismiss</Button>
            </div>
          </Alert>
        </div>
      ) : null}

      <div className={twoPane ? 'flex-1 min-h-0 overflow-y-auto' : undefined}>
        {listBody}
      </div>

      {selectable && selectionMode ? (
        <div className="shrink-0">
          <BulkActionBar
            selectedCount={selectedIds.length}
            loadedCount={visibleRows.length}
            onCancel={() => setSelectedIds([])}
          >
            <ActionButton
              icon="stop"
              label="Kill"
              variant="danger"
              loading={bulkBusy}
              disabled={killable.length === 0}
              title={
                killable.length === 0 && selectedIds.length > 0
                  ? 'Every selected session has already finished — there is nothing to kill.'
                  : undefined
              }
              data-debug-id="shell-bulk-kill"
              onClick={() => killable.length && setBulkConfirm(killable.map((row) => row.session_id))}
            />
          </BulkActionBar>
        </div>
      ) : null}
    </div>
  );

  /* ---------------- Toolbar ---------------- */
  const catalogNotes = [
    catalogNote(catalog.projects.state, 'projects'),
    catalogNote(catalog.bridges.state, 'bridges'),
  ].filter(Boolean);

  /* Active filters as removable chips, under the toolbar. */
  const chips: { key: string; label: string; clear: () => void }[] = [];
  if (urlState.status) {
    chips.push({
      key: 'status',
      label: statusLabel(urlState.status),
      clear: () => applyUrlState({ ...urlState, status: '' }),
    });
  }
  if (urlState.kind) {
    chips.push({
      key: 'kind',
      label: kindLabel(urlState.kind),
      clear: () => applyUrlState({ ...urlState, kind: '' }),
    });
  }
  if (urlState.bridge) {
    chips.push({
      key: 'bridge',
      label: bridgeLabel(urlState.bridge, catalog) || urlState.bridge,
      clear: () => applyUrlState({ ...urlState, bridge: '' }),
    });
  }
  if (urlState.project) {
    chips.push({
      key: 'project',
      label: projectLabel(urlState.project, catalog) || urlState.project,
      clear: () => applyUrlState({ ...urlState, project: '' }),
    });
  }

  const filterChipRow =
    filtersActive && !searching ? (
      <div className="flex flex-wrap items-center gap-1.5" data-debug-id="shell-filter-chips">
        {chips.map((chip) => (
          <button
            key={chip.key}
            type="button"
            onClick={chip.clear}
            data-debug-id={`shell-filter-chip-${chip.key}`}
            aria-label={`Remove filter ${chip.label}`}
            className="inline-flex items-center gap-1 rounded-full border border-subtle bg-neutral-soft px-2 py-0.5 text-caption text-muted hover:text-primary focus-visible:shadow-focus focus-visible:outline-none"
          >
            {chip.label}
            <Icon name="close" size="sm" aria-hidden="true" />
          </button>
        ))}
        {/* Gated on `!searching` for Amendment 3's reason: anything beside FilterBar
            stays live while the bar is disabled, and clearing the held filter state
            while a query is active destroys what the cleared query restores. */}
        <Button size="sm" variant="ghost" data-debug-id="shell-filter-clear" onClick={clearFilters}>
          Clear filters
        </Button>
      </div>
    ) : null;

  const listColumn = (
    <div data-debug-id="shell-list-page" className={`flex w-full min-w-0 flex-col gap-3 ${twoPane ? 'flex-1 min-h-0 h-full overflow-hidden' : ''}`}>
      <div data-debug-id="shell-toolbar">
        <ResourceSearchFilter
          searchQuery={queryInput}
          onSearchChange={setQueryInput}
          searchPlaceholder="Search labels, commands and paths…"
          searchDebugId="shell-search-input"
          searchClearDebugId="shell-search-clear"
          searchRef={searchRef}
          activeTab={searching ? '' : tab}
          onTabChange={(next) =>
            // The Status filter is tab-scoped, so a tab change drops a status that cannot
            // exist under the new tab rather than leaving a filter that matches nothing.
            applyUrlState({ ...urlState, tab: next as ShellTab, status: '' })
          }
          selectionMode={selectionMode}
          onToggleSelection={
            selectable
              ? () => {
                  setSelectionMode((prev) => !prev);
                  if (selectionMode) setSelectedIds([]);
                }
              : undefined
          }
          selectionToggleDebugId="shell-toggle-selection-btn"
          tabs={SHELL_TABS.map((entry) => ({
            value: entry.value,
            label: entry.label,
            disabled: searching,
            debugId: `shell-tab-${entry.value}`,
          }))}
          tabsLabel="Shell session state"
          filters={[
            {
              value: urlState.status,
              onChange: (next) =>
                applyUrlState({ ...urlState, status: next as ShellSessionStatus | '' }),
              ariaLabel: 'Session status',
              debugId: 'shell-filter-status',
              disabled: searching,
              widthClassName: 'w-36',
              options: [
                {
                  value: '',
                  label: tab === 'live' ? 'Any live status' : 'Any finished status',
                },
                ...statusOptionsForTab(tab).map((entry) => ({
                  value: entry.value,
                  label: entry.label,
                })),
              ],
            },
            {
              value: urlState.kind,
              onChange: (next) =>
                applyUrlState({ ...urlState, kind: next as ShellSessionKind | '' }),
              ariaLabel: 'Session kind',
              debugId: 'shell-filter-kind',
              disabled: searching || kindOptions.length === 0,
              widthClassName: 'w-28',
              options: [
                { value: '', label: 'Any kind' },
                ...kindOptions.map((entry) => ({
                  value: entry.value,
                  label: entry.label,
                })),
              ],
            },
          ]}
        >
          <FilterBar
            active={Boolean(urlState.bridge || urlState.project)}
            activeCount={(urlState.bridge ? 1 : 0) + (urlState.project ? 1 : 0)}
            iconTrigger
            disabled={searching}
            disabledTitle="Filters don't apply while you're searching"
            surface={isMobile ? 'sheet' : 'popover'}
            note={
              <>
                Status, bridge and project narrow what the server sends. Kind narrows the
                sessions already loaded, so scrolling can bring more into view.
                {catalogNotes.length ? ` ${catalogNotes.join(' ')}` : ''}
              </>
            }
          >
            <Select
              value={urlState.bridge}
              onChange={(next) => applyUrlState({ ...urlState, bridge: next })}
              size="sm"
              aria-label="Bridge"
              disabled={bridgeOptions.length === 0}
              data-debug-id="shell-filter-bridge"
              options={[
                { value: '', label: 'Any bridge' },
                ...bridgeOptions.map((entry) => ({ value: entry.id, label: entry.label })),
              ]}
            />
            <Select
              value={urlState.project}
              onChange={(next) => applyUrlState({ ...urlState, project: next })}
              size="sm"
              aria-label="Project"
              disabled={projectOptions.length === 0}
              data-debug-id="shell-filter-project"
              options={[
                { value: '', label: 'Any project' },
                ...projectOptions.map((entry) => ({ value: entry.id, label: entry.label })),
              ]}
            />
          </FilterBar>
        </ResourceSearchFilter>
      </div>
      {filterChipRow ? <div className="shrink-0">{filterChipRow}</div> : null}
      <div className={`flex min-w-0 flex-col gap-4 ${twoPane ? 'flex-1 min-h-0 overflow-hidden' : ''}`}>
        {listSection}
      </div>
    </div>
  );

  const confirmNames = React.useMemo(
    () =>
      (bulkConfirm || []).map((id) => {
        const row = list.items.find((item) => item.session_id === id);
        return row ? shellTitle(row) : id;
      }),
    [bulkConfirm, list.items],
  );

  const overlays = (
    <>
      {bulkConfirm ? (
        <Modal
          open
          onOpenChange={(next) => { if (!next) setBulkConfirm(null); }}
          title={bulkKillTitle(bulkConfirm.length)}
          size="sm"
          data-debug-id="shell-bulk-kill-modal"
        >
          <ModalBody>
            <Text role="body">{bulkKillBody(confirmNames, skipped)}</Text>
          </ModalBody>
          <ModalFooter>
            <Button variant="secondary" data-debug-id="shell-bulk-kill-cancel" onClick={() => setBulkConfirm(null)}>
              Cancel
            </Button>
            <Button
              variant="danger"
              loading={bulkBusy}
              data-debug-id="shell-bulk-kill-confirm"
              onClick={() => {
                const pending = bulkConfirm;
                setBulkConfirm(null);
                if (pending) void runBulkKill(pending);
              }}
            >
              Kill
            </Button>
          </ModalFooter>
        </Modal>
      ) : null}

      {rowConfirm ? (
        <Modal
          open
          onOpenChange={(next) => { if (!next) setRowConfirm(null); }}
          title={confirmTitle(rowConfirm.session, rowConfirm.verb)}
          size="sm"
          data-debug-id="shell-row-confirm-modal"
        >
          <ModalBody>
            <Text role="body">{confirmBody(rowConfirm.session, rowConfirm.verb)}</Text>
          </ModalBody>
          <ModalFooter>
            <Button variant="secondary" data-debug-id="shell-row-confirm-cancel" onClick={() => setRowConfirm(null)}>
              Cancel
            </Button>
            <Button
              variant={isDestructive(rowConfirm.verb) ? 'danger' : 'primary'}
              loading={Boolean(busyRow)}
              data-debug-id="shell-row-confirm-accept"
              onClick={() => {
                const pending = rowConfirm;
                setRowConfirm(null);
                if (pending) void executeRowVerb(pending.session, pending.verb);
              }}
            >
              {VERB_LABEL[rowConfirm.verb]}
            </Button>
          </ModalFooter>
        </Modal>
      ) : null}

      {portSession ? (
        <SetShellPortDialog session={portSession} onClose={() => setPortSession(null)} />
      ) : null}

      {toasts.length ? (
        <div className="pointer-events-none fixed inset-x-0 app-viewport-bottom z-toast flex flex-col items-center gap-2 p-4 sm:items-end">
          {toasts.map((entry) => (
            <div key={entry.id} className="pointer-events-auto">
              <Toast tone={entry.tone} title={entry.title} duration={4000} onDismiss={() => dismissToast(entry.id)}>
                {entry.message ? <span>{entry.message}</span> : null}
              </Toast>
            </div>
          ))}
        </div>
      ) : null}
    </>
  );

  const headerDescription =
    'Every shell session your bridges are running — started by an agent, by a chain, or by `ham-ctl shell`.';

  return (
    <ResourceContainer
      title="Shells"
      description={headerDescription}
      breadcrumbs={listCrumbs()}
      selectedId={selectedId}
      detailTitle="Shell Details"
      listDebugId="shell-list-page"
      detailDebugId="shell-detail-pane"
      emptyDetailText="Select a session to see its output here."
      list={listColumn}
      detail={
        selectedId ? (
          <ShellDetailPane
            sessionId={selectedId}
            onBack={() => navigateTo(shellListHref(urlState))}
          />
        ) : null
      }
    >
      {overlays}
    </ResourceContainer>
  );
}

/** The right-hand pane of the two-pane layout. */
function ShellDetailPane({
  sessionId,
  onBack,
}: {
  sessionId: string;
  onBack?: () => void;
}) {
  const detail = useShellDetail(sessionId);
  const paneRef = React.useRef<HTMLDivElement | null>(null);
  const wide = usePaneIsWide(paneRef);
  const { query, record, busy, actionError, notice, runVerb } = detail;

  if (query.isLoading) return <ShellDetailPaneSkeleton />;
  if (query.error || !record) {
    return (
      <EmptyState
        data-debug-id="shell-pane-missing"
        icon="search"
        title="That shell session doesn't exist"
        description={query.error ? shellErrorText(query.error) : undefined}
        action={<Button variant="secondary" onClick={() => navigateTo(shellListHref())}>Back to Shells</Button>}
      />
    );
  }

  return (
    <div ref={paneRef} className="min-w-0 flex flex-col min-h-0 h-full overflow-hidden">
      <div className="mb-3 shrink-0">
        <ShellDetailHeader
          record={record}
          busy={busy}
          onVerb={runVerb}
          onBack={onBack}
        />
      </div>
      <div className="flex-1 min-h-0 overflow-y-auto">
        <ShellDetailBody
          record={record}
          actionError={actionError}
          notice={notice}
          wide={wide}
          onVerb={runVerb}
        />
      </div>
      <ShellDetailOverlays
        confirm={detail.confirm}
        onResolve={detail.resolveConfirm}
        portSession={record}
        portDialogOpen={detail.portDialogOpen}
        onClosePortDialog={detail.closePortDialog}
        busy={busy}
      />
    </div>
  );
}

/** Re-exported for the shell's route table. */
export { EMPTY_LIST_URL_STATE };
