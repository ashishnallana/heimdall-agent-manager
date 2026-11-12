/**
 * MemoryListPage — `/memory`.
 * ------------------------------------------------------------------
 * The reference resource list: three tabs, five server-backed filters, a
 * server-scoped search that replaces (rather than filters) the list, keyset
 * infinite scroll, and bulk verbs that differ per tab.
 *
 * Spec: `docs/ui-rebuild/memory.md` revision 3 + Amendment 1 — §1 tabs, §2 filters,
 * §3 search, §4 columns, §5 mobile, §6 actions, §10 states, §11 URL. Section
 * numbers in the comments below refer to it.
 *
 * Everything list-shaped is `@ui`: `DataList` (columns on desktop, cards at
 * ≤767px), `FilterBar` (drawer on mobile, disable-able wholesale), `BulkActionBar`
 * and `useInfiniteList`. What lives here is only what is true of MEMORY.
 */
import React from 'react';
import {
  ActionButton,
  Alert,
  BulkActionBar,
  Button,
  Combobox,
  EmptyState,
  FilterBar,
  Icon,
  Modal,
  ModalBody,
  ModalFooter,
  ResourceContainer,
  ResourceSearchFilter,
  Select,
  Text,
  Toast,
  TOUCH_TARGET_CLASS,
  useInfiniteList,
  useViewport,
  type IconName,
} from '@ui';
import {
  ScopeCatalogNote,
  SCOPE_DIMS,
  scopeCatalogEmptyLabel,
  useMemoryScopeCatalog,
} from '@ui';
import MemoryRow from './MemoryRow';
import {
  MemoryDetailBody,
  MemoryDetailHeader,
  useMemoryDetail,
  usePaneIsWide,
} from './MemoryDetail';
import { getRouteSearch } from '../../utils/appLocation';
import { normalizeMemory } from '../../api/memoryCatalog';
import {
  fetchMemoryPage,
  searchMemoryPage,
  maskVaultArmored,
  memoryErrorText,
  useApproveMemoryMutation,
  useArchiveMemoryMutation,
  useRejectMemoryMutation,
  type MemoryHit,
} from '../../api/endpoints/memory';
import {
  EMPTY_LIST_URL_STATE,
  MEMORY_TABS,
  MEMORY_TYPE_OPTIONS,
  VERB_LABEL,
  absoluteTime,
  hasActiveFilters,
  isMemoryExpired,
  listCrumbs,
  memoryEditHref,
  memoryListHref,
  memoryListSearch,
  memoryNewHref,
  memoryStatus,
  memoryTitle,
  memoryViewHref,
  navigateTo,
  parseMemoryListUrl,
  relativeTime,
  rememberRow,
  replaceListSearch,
  statusForTab,
  statusLabel,
  statusTone,
  takeRememberedRow,
  verbsForStatus,
  type ArchivedView,
  type Memory,
  type MemoryListUrlState,
  type MemoryStatus,
  type MemoryTab,
  type MemoryVerb,
} from './memoryModel';

/** The list endpoint's default page size, and search's maximum — they agree at 50. */
const PAGE_SIZE = 50;
/** §3: the search box is debounced before the list is replaced. */
const SEARCH_DEBOUNCE_MS = 250;
/** §6: how long the single-reject undo stays up. */
const UNDO_MS = 5000;

/** The glyph each bulk verb collapses to on touch. The label is carried either way. */
const BULK_VERB_ICON: Record<MemoryVerb, IconName> = {
  approve: 'check',
  reject: 'close',
  archive: 'folder',
  restore: 'refresh',
  edit: 'pencil',
};

type ToastEntry = {
  id: string;
  tone: 'success' | 'danger' | 'info';
  title: string;
  message?: string;
  undo?: () => void;
  duration?: number;
};

export default function MemoryListPage({ selectedId = '' }: { selectedId?: string } = {}) {
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
  // Two-pane master/detail is a >=1024 layout (spec › Desktop layout). Below that the
  // detail is its own page, which is what `/memory/:id` renders on its own.
  const twoPane = viewport === 'desktop';
  const catalog = useMemoryScopeCatalog();
  const searchRef = React.useRef<HTMLInputElement | null>(null);

  /* ---------------- URL state (§11) ---------------- */
  const [urlState, setUrlState] = React.useState<MemoryListUrlState>(() =>
    parseMemoryListUrl(getRouteSearch()),
  );
  // The probe's answer, used only while the URL names no tab.
  const [probedTab, setProbedTab] = React.useState<MemoryTab | ''>('');
  const tab: MemoryTab = urlState.tab || probedTab || 'active';
  const archivedView: ArchivedView = urlState.archivedView;
  const listStatus = statusForTab(tab, archivedView);
  const searching = Boolean(urlState.q);

  /** Writes state to React AND to the URL, which is replaced, never pushed. */
  const applyUrlState = React.useCallback((next: MemoryListUrlState) => {
    setUrlState(next);
    replaceListSearch(next);
  }, []);

  /* ---------------- Landing tab (§1 / A1.2) ----------------
   * Precedence: an explicit `?tab=` always wins, else Proposals when its first page
   * has a row, else Active. The probe runs ONCE per page load and never re-applies,
   * so the tab cannot move under the user; it never blocks first paint (Active's
   * skeleton renders while it is in flight); and a failure lands on Active in
   * silence, because a failed probe is not worth an error banner. */
  const probedRef = React.useRef(false);
  React.useEffect(() => {
    if (probedRef.current) return;
    probedRef.current = true;
    if (urlState.tab) return;
    // Deliberately NOT abortable. The probe is a one-shot guarded by a ref, and
    // under StrictMode's double-invoke an abort-on-cleanup would cancel the only
    // request the guard will ever allow — leaving every load on Active even when
    // proposals are waiting. A late answer is harmless: it is applied only while
    // the URL still names no tab, and never re-applied.
    void (async () => {
      try {
        const page = await fetchMemoryPage({ status: 'pending', limit: 10 });
        const unexpired = (page.items || []).filter((m: any) => !isMemoryExpired(m));
        if (unexpired.length > 0) setProbedTab('proposals');
      } catch {
        /* Silent: Active is the fallback, and it is already on screen. */
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  /* ---------------- Search (§3) ---------------- */
  const [queryInput, setQueryInput] = React.useState(urlState.q);
  React.useEffect(() => {
    if (queryInput === urlState.q) return undefined;
    const timer = window.setTimeout(() => {
      applyUrlState({ ...urlState, q: queryInput });
    }, SEARCH_DEBOUNCE_MS);
    return () => window.clearTimeout(timer);
  }, [queryInput, urlState, applyUrlState]);
  // While the debounce is pending the loaded rows stay put and dim, so the list
  // never blinks between two different data paths.
  const querySettling = queryInput.trim() !== urlState.q.trim();

  /* ---------------- The two data paths (§3) ----------------
   * A query does not filter the list — it REPLACES it: different rows, bm25 order
   * instead of `updated_at`, and a reduced row shape. Two hooks rather than one
   * keeps each path's item type honest; only one is ever enabled. */
  const list = useInfiniteList<any>({
    fetchPage: async ({ cursor, signal }) => {
      const page = await fetchMemoryPage({
        status: listStatus || undefined,
        type: urlState.type || undefined,
        projectId: urlState.project || undefined,
        agentId: urlState.agent || undefined,
        bridgeId: urlState.bridge || undefined,
        templateId: urlState.template || undefined,
        limit: PAGE_SIZE,
        cursor,
        signal,
      });
      const items = (tab === 'proposals' || listStatus === 'pending')
        ? (page.items || []).filter((m: any) => !isMemoryExpired(m))
        : (page.items || []);
      return {
        ...page,
        items,
      };
    },
    getItemId: (row) => String(row.memoryId || row.id || ''),
    // Memory's cursor column is `updated_at` — this is what lets a probe tell
    // "changed" from "same" for the N-new pill.
    getCursorValue: (row) => String(row.updatedAt || ''),
    resetKey: [listStatus, urlState.type, urlState.project, urlState.agent, urlState.bridge, urlState.template].join('|'),
    enabled: !searching,
  });

  const search = useInfiniteList<MemoryHit>({
    fetchPage: ({ cursor, signal }) =>
      searchMemoryPage({ q: urlState.q, limit: PAGE_SIZE, cursor, signal }),
    getItemId: (hit) => hit.id,
    resetKey: urlState.q,
    enabled: searching,
  });

  const active = searching ? search : list;

  /* ---------------- Live updates (§11, REQ-UI-20) ----------------
   * Memory has no WS stream, so the list re-probes on refocus. Rendered rows hold
   * their position; anything new or changed surfaces as a pill the user applies. */
  React.useEffect(() => {
    if (searching) return undefined;
    const onFocus = () => list.refresh();
    window.addEventListener('focus', onFocus);
    return () => window.removeEventListener('focus', onFocus);
  }, [list, searching]);

  /* ---------------- Scroll restoration (§11) ----------------
   * Capped at 5 pages / 250 rows by the hook. Found → scroll to the row; not found
   * → land at the top with a note, because landing somewhere unexplained is worse. */
  const restoredRef = React.useRef(false);
  React.useEffect(() => {
    if (restoredRef.current) return;
    restoredRef.current = true;
    const rowId = takeRememberedRow();
    if (!rowId || searching) return;
    void list.restoreToId(rowId).then((outcome) => {
      if (outcome !== 'found') return;
      window.requestAnimationFrame(() => {
        const node = document.querySelector(`[data-memory-row="${CSS.escape(rowId)}"]`);
        node?.scrollIntoView({ block: 'center' });
      });
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  React.useEffect(() => {
    if (!list.restoreNotice) return undefined;
    const dismiss = () => list.dismissRestoreNotice();
    window.addEventListener('scroll', dismiss, { capture: true, once: true });
    return () => window.removeEventListener('scroll', dismiss, { capture: true });
  }, [list]);

  /* ---------------- Selection (§6, REQ-UI-19) ---------------- */
  const [selectionMode, setSelectionMode] = React.useState(false);
  const [selectedIds, setSelectedIds] = React.useState<string[]>([]);
  // Selection is scoped to what is on screen: changing tab, filters or query means
  // the selected rows may no longer even be loaded.
  React.useEffect(() => {
    setSelectedIds([]);
  }, [listStatus, urlState.type, urlState.project, urlState.agent, urlState.bridge, urlState.template, urlState.q]);

  /* ---------------- Toasts (§6) ----------------
   * The app's global toast store carries no action slot, and the single-reject undo
   * needs one, so the page renders its own small stack with `@ui` Toast. */
  const [toasts, setToasts] = React.useState<ToastEntry[]>([]);
  const pushToast = React.useCallback((entry: Omit<ToastEntry, 'id'>) => {
    const id = `memory-toast-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
    setToasts((prev) => [...prev.slice(-2), { ...entry, id }]);
  }, []);
  const dismissToast = React.useCallback((id: string) => {
    setToasts((prev) => prev.filter((entry) => entry.id !== id));
  }, []);

  /* ---------------- Mutations (§6) ---------------- */
  const [approveMemory] = useApproveMemoryMutation();
  const [rejectMemory] = useRejectMemoryMutation();
  const [archiveMemory] = useArchiveMemoryMutation();

  /**
   * Runs one verb against one memory and patches the row IN PLACE with the server's
   * own record, so its new status badge appears where the row already sits. The row
   * never jumps, even though the write moves it to the top of the server's order.
   */
  const runVerb = React.useCallback(
    async (memoryId: string, verb: MemoryVerb) => {
      const call =
        verb === 'reject'
          ? rejectMemory({ memoryId }).unwrap()
          : verb === 'archive'
            ? archiveMemory({ memoryId }).unwrap()
            : approveMemory({ memoryId }).unwrap();
      const saved = await call;
      const record = saved && typeof saved === 'object' ? normalizeMemory(saved) : null;
      if (record?.memoryId) list.patchItem(memoryId, record);
      return record;
    },
    [approveMemory, archiveMemory, rejectMemory, list],
  );

  const [busyRow, setBusyRow] = React.useState('');

  const singleVerb = React.useCallback(
    async (row: any, verb: MemoryVerb) => {
      const memoryId = String(row.memoryId || row.id || '');
      if (!memoryId) return;
      setBusyRow(memoryId);
      try {
        await runVerb(memoryId, verb);
        if (verb === 'reject') {
          // §6: reject a single proposal with an UNDO, not a confirm — one row, and
          // the reverse call exists. Archive is the one that confirms, because it
          // changes what agents receive.
          pushToast({
            tone: 'info',
            title: 'Proposal rejected',
            message: maskVaultArmored(memoryTitle(row)),
            duration: UNDO_MS,
            undo: () => {
              void runVerb(memoryId, 'approve').catch((err) =>
                pushToast({ tone: 'danger', title: "Couldn't undo", message: memoryErrorText(err) }),
              );
            },
          });
        }
      } catch (err) {
        // A system memory 403s here in the server's own words (BACKEND-DEP-1's
        // degraded path): the payload carries no read-only signal, so the page
        // attempts the write and surfaces what the hub says rather than guessing.
        pushToast({ tone: 'danger', title: `Couldn't ${VERB_LABEL[verb].toLowerCase()} this memory`, message: memoryErrorText(err) });
      } finally {
        setBusyRow('');
      }
    },
    [pushToast, runVerb],
  );

  /* ---------------- Bulk (§6) ---------------- */
  const [confirm, setConfirm] = React.useState<{ verb: MemoryVerb; ids: string[] } | null>(null);
  const [bulkBusy, setBulkBusy] = React.useState(false);

  const runBulk = React.useCallback(
    async (verb: MemoryVerb, ids: string[]) => {
      setBulkBusy(true);
      const failed: string[] = [];
      let done = 0;
      for (const id of ids) {
        try {
          await runVerb(id, verb);
          done += 1;
        } catch {
          failed.push(id);
        }
      }
      setBulkBusy(false);
      // Partial failure is reported honestly and the failed rows STAY selected, so
      // a retry hits only them.
      setSelectedIds(failed);
      const past = verb === 'approve' ? 'approved' : verb === 'reject' ? 'rejected' : verb === 'archive' ? 'archived' : 'restored';
      pushToast({
        tone: failed.length ? 'danger' : 'success',
        title: failed.length ? `${done} ${past}, ${failed.length} failed` : `${done} ${past}`,
        message: failed.length ? 'The rows that failed are still selected.' : undefined,
      });
    },
    [pushToast, runVerb],
  );

  /** §6: bulk anything confirms; approve and restore are constructive and do not. */
  const requestBulk = React.useCallback(
    (verb: MemoryVerb) => {
      if (selectedIds.length === 0) return;
      if (verb === 'approve' || verb === 'restore') {
        void runBulk(verb, selectedIds);
        return;
      }
      setConfirm({ verb, ids: selectedIds });
    },
    [runBulk, selectedIds],
  );

  /* ---------------- Filters (§2) ---------------- */
  const filtersActive = hasActiveFilters(urlState);
  /** How many filters are actually applied — the number on the Filters button. */
  const activeFilterCount = [urlState.type, urlState.project, urlState.agent, urlState.bridge, urlState.template]
    .filter(Boolean).length;
  const clearFilters = () =>
    applyUrlState({ ...urlState, type: '', project: '', agent: '', bridge: '', template: '' });

  /** The human name of the filter state being held while a query is active (§3). */
  const heldStateLabel = React.useMemo(() => {
    const parts: string[] = [MEMORY_TABS.find((entry) => entry.value === tab)?.label || 'Active'];
    if (urlState.type) parts.push(urlState.type);
    for (const dim of SCOPE_DIMS) {
      const id =
        dim.key === 'projectIds' ? urlState.project
          : dim.key === 'agentIds' ? urlState.agent
            : dim.key === 'bridgeIds' ? urlState.bridge
              : urlState.template;
      if (id) parts.push(catalog[dim.key].byId.get(id) || id);
    }
    return parts.join(' · ');
  }, [catalog, tab, urlState]);

  /**
   * §2 / design pass: the page shows the filters that are ON, as removable chips,
   * and keeps the five controls behind the Filters button. A chip you cannot click
   * would be just a second label, so each one clears its own filter.
   */
  const filterChips = React.useMemo(() => {
    const entries: { key: string; label: string; clear: () => void }[] = [];
    if (urlState.type) {
      entries.push({ key: 'type', label: urlState.type, clear: () => applyUrlState({ ...urlState, type: '' }) });
    }
    for (const dim of SCOPE_DIMS) {
      const field = dim.key === 'projectIds' ? 'project' : dim.key === 'agentIds' ? 'agent' : dim.key === 'bridgeIds' ? 'bridge' : 'template';
      const id = urlState[field as 'project' | 'agent' | 'bridge' | 'template'];
      if (!id) continue;
      entries.push({
        key: field,
        label: catalog[dim.key].byId.get(id) || id,
        clear: () => applyUrlState({ ...urlState, [field]: '' } as MemoryListUrlState),
      });
    }
    return entries;
  }, [applyUrlState, catalog, urlState]);

  const scopeFilterControls = SCOPE_DIMS.map((dim) => {
    const current =
      dim.key === 'projectIds' ? urlState.project
        : dim.key === 'agentIds' ? urlState.agent
          : dim.key === 'bridgeIds' ? urlState.bridge
            : urlState.template;
    const anyLabel = `Any ${dim.label.toLowerCase().replace(/s$/, '')}`;
    return (
      <div key={dim.key} className="w-full">
        <Combobox
          // Single-select, deliberately: the hub honours only the FIRST token of a
          // dimension filter (content_handlers.odin:690-698), so a multi-select
          // control would show three chips and filter by one.
          options={[{ value: '', title: anyLabel }, ...catalog[dim.key].options]}
          value={current}
          onChange={(next) => {
            const key = dim.key === 'projectIds' ? 'project' : dim.key === 'agentIds' ? 'agent' : dim.key === 'bridgeIds' ? 'bridge' : 'template';
            applyUrlState({ ...urlState, [key]: next } as MemoryListUrlState);
          }}
          placeholder={anyLabel}
          loading={catalog[dim.key].loading}
          // Same catalog as the form, so the same three states: a filter whose
          // catalog is empty or failed says which, rather than opening on nothing.
          emptyLabel={scopeCatalogEmptyLabel(catalog[dim.key], dim.label.toLowerCase())}
          size="sm"
          debugId={`memory-filter-${dim.debug}`}
          searchPlaceholder={`Search ${dim.label.toLowerCase()}…`}
        />
        <ScopeCatalogNote
          entry={catalog[dim.key]}
          noun={dim.label.toLowerCase()}
          debugId={`memory-filter-${dim.debug}-state`}
        />
      </div>
    );
  });

  /* ---------------- Keyboard (spec › Desktop layout) ----------------
   * j/k move through the loaded rows, a approves, r rejects, / focuses search. They
   * are bound on the window, so they work without the list holding focus — and every
   * one of them is ignored while the user is typing in a field or a modal is open,
   * because a single-letter shortcut that fires inside an input is a bug, not a
   * feature. Each verb is only sent when the focused row actually offers it. */
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
      if (typing || confirm) return;

      const items = list.items;
      const currentId = cursorRef.current;
      const index = items.findIndex((row: any) => String(row.memoryId || row.id || '') === currentId);

      if (event.key === 'j' || event.key === 'k') {
        if (items.length === 0) return;
        event.preventDefault();
        const nextIndex = event.key === 'j'
          ? Math.min(items.length - 1, index < 0 ? 0 : index + 1)
          : Math.max(0, index < 0 ? 0 : index - 1);
        const next = items[nextIndex];
        const nextId = next ? String(next.memoryId || next.id || '') : '';
        setCursorId(nextId);
        // In two-pane, moving the cursor opens the memory — that IS the pane's job.
        if (twoPane && nextId) navigateTo(memoryViewHref(nextId, urlState));
        const node = nextId ? document.querySelector(`[data-memory-row="${CSS.escape(nextId)}"]`) : null;
        node?.scrollIntoView({ block: 'nearest' });
        return;
      }

      if (event.key === 'a' || event.key === 'r') {
        const row = index >= 0 ? items[index] : null;
        if (!row) return;
        const verb: MemoryVerb = event.key === 'a' ? 'approve' : 'reject';
        if (!verbsForStatus(memoryStatus(row)).includes(verb)) return;
        event.preventDefault();
        void singleVerb(row, verb);
      }
    }
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [confirm, list.items, singleVerb, twoPane, urlState]);

  /* ---------------- Rows (spec › LIST VIEW › Rows) ----------------
   * The column table is gone. A memory row is four lines, on every viewport:
   *
   *     title + "…" trigger  /  body line 1  /  body line 2  /  pills … time
   *
   * `MemoryRow` owns that shape. 72px is a FLOOR, not the height — four lines take
   * what they take (measured at 135px with the current type scale).
   *
   * The row carries a single "…" menu and NOTHING else: no inline Approve/Reject, no
   * hover-revealed cluster, and no swipe gesture — all three were built and then
   * removed at the user's request. Approve and Reject live in the row menu and in the
   * bulk bar during selection, and nowhere else on this page.
   *
   * `DataList`'s table path is untouched and still generic: Agents and Actions carry
   * more columns than Memory ever did and still need it (Amendment 4). */

  /**
   * Auto-advance (spec › GLOBAL FIXES): acting on a proposal moves to the NEXT one
   * rather than leaving the user on a row that is no longer in this tab. It only
   * fires in the two-pane layout, where there is a pane to advance; on a list with no
   * open pane there is nothing to advance to and the row simply updates in place.
   */
  const advanceFrom = React.useCallback(
    (memoryId: string) => {
      const items = tab === 'proposals' ? list.items.filter((m: any) => !isMemoryExpired(m)) : list.items;
      const index = items.findIndex((row: any) => String(row.memoryId || row.id || '') === memoryId);
      if (index < 0) return '';
      const next = items[index + 1] || items[index - 1];
      return next ? String(next.memoryId || next.id || '') : '';
    },
    [list.items, tab],
  );


  /* ---------------- Empty states (§10) ---------------- */
  function emptyState(): React.ReactNode {
    if (searching) {
      return (
        <EmptyState
          data-debug-id="memory-empty-query"
          icon="search"
          title={`No memories match “${urlState.q}”`}
          description="Search covers memory titles and bodies. Try a shorter phrase."
          action={<Button variant="secondary" onClick={() => { setQueryInput(''); applyUrlState({ ...urlState, q: '' }); }}>Clear search</Button>}
        />
      );
    }
    if (filtersActive) {
      return (
        <EmptyState
          data-debug-id="memory-empty-filters"
          icon="layers"
          title="No memories match these filters"
          description="Try a broader type, or clear the scope filters — global memories show under every scope."
          action={<Button variant="secondary" onClick={clearFilters}>Clear filters</Button>}
        />
      );
    }
    if (tab === 'proposals') {
      return (
        <EmptyState
          data-debug-id="memory-empty-proposals"
          icon="check"
          title="No proposals waiting"
          description="When an agent proposes a memory, it lands here for you to approve."
        />
      );
    }
    if (tab === 'archived') {
      return archivedView === 'rejected' ? (
        <EmptyState
          data-debug-id="memory-empty-rejected"
          icon="close"
          title="No rejected proposals"
          description="Proposals you turn down are kept here, and can still be approved later."
        />
      ) : (
        <EmptyState
          data-debug-id="memory-empty-archived"
          icon="folder"
          title="Nothing archived"
          description="Archiving takes a memory out of force without deleting it. Archived memories wait here until you restore them."
        />
      );
    }
    return (
      <EmptyState
        data-debug-id="memory-empty-first-run"
        icon="spark"
        title="No memories yet"
        description="Memories are durable facts, habits and skills your agents carry between sessions. Create one, or let an agent propose it."
        action={<Button variant="primary" onClick={() => navigateTo(memoryNewHref())}>New memory</Button>}
      />
    );
  }

  /* ---------------- The list foot: sentinel, paging skeleton, retry ---------------- */
  const footer = (
    <div>
      {active.isPaging ? (
        <div data-debug-id="memory-paging-skeleton" aria-hidden="true" className="flex flex-col gap-2 py-3">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-5 w-full animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
          ))}
        </div>
      ) : null}
      {active.pagingError ? (
        // A paging failure never destroys the rows already loaded.
        <div data-debug-id="memory-paging-error" className="py-3">
          <Alert tone="danger" title="Couldn't load more memories">
            <div className="flex items-center gap-3">
              <span>{memoryErrorText(active.pagingError)}</span>
              <Button size="sm" variant="secondary" onClick={() => active.loadMore()}>Retry</Button>
            </div>
          </Alert>
        </div>
      ) : null}
      {active.hasMore && !active.pagingError ? (
        <div ref={active.sentinelRef} data-debug-id="memory-scroll-sentinel" className="h-px w-full" />
      ) : null}
    </div>
  );

  const bulkVerbs: MemoryVerb[] =
    tab === 'proposals' ? ['approve', 'reject']
      : tab === 'active' ? ['archive']
        : archivedView === 'rejected' ? ['approve'] : ['restore'];

  /**
   * Everything below the tab strip: the Archived sub-control, the filter bar, the
   * list itself and the bulk bar. It is one variable because it renders INSIDE the
   * tab panel normally and OUTSIDE it while a query is active — search results
   * belong to no tab, and a panel labelled by a tab that is not selected would
   * claim otherwise.
   */
  /* ---------------- The rows themselves ---------------- */
  const activeTab = searching ? '' : tab;
  const rows = searching ? search.items : list.items;
  const visibleRows = (activeTab === 'proposals' ? rows.filter(m => !isMemoryExpired(m)) : rows);

  /** Open a memory: in the two-pane layout that means the pane, not a navigation. */
  const openMemory = React.useCallback(
    (memoryId: string) => {
      if (!memoryId) return;
      rememberRow(memoryId);
      navigateTo(memoryViewHref(memoryId, urlState));
    },
    [urlState],
  );

  /** Auto-select the first memory in two-pane mode if none is selected */
  React.useEffect(() => {
    if (twoPane && !selectedId && visibleRows.length > 0) {
      const firstId = String(visibleRows[0].memoryId || visibleRows[0].id || '');
      if (firstId) {
        navigateTo(memoryViewHref(firstId, urlState));
      }
    }
  }, [twoPane, selectedId, visibleRows, urlState]);

  const listBody = (
    <>
      {active.status === 'error' ? (
        <Alert tone="danger" title="Couldn't load memories">
          <div className="flex flex-col items-start gap-3">
            <span>{memoryErrorText(active.error)}</span>
            <Button size="sm" variant="secondary" onClick={() => active.reload()}>Retry</Button>
          </div>
        </Alert>
      ) : active.isLoadingInitial ? (
        // Skeleton ROWS at the real row height — never a spinner, never a shift.
        <div role="status" aria-live="polite" aria-busy="true" data-debug-id="memory-list-skeleton">
          <span className="sr-only">Loading memories…</span>
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
          aria-label={searching ? 'Memory search results' : 'Memories'}
          data-debug-id="memory-rows"
          className={['flex flex-col', querySettling ? 'opacity-60' : ''].filter(Boolean).join(' ')}
        >
          {visibleRows.map((row: any) => {
            const memoryId = String(row.memoryId || row.id || '');
            return (
              <MemoryRow
                key={memoryId}
                row={row}
                catalog={catalog}
                href={memoryViewHref(memoryId, urlState)}
                // A search hit carries no reliable status, so it is a navigation
                // target only: no selection, and no verbs that need a status.
                selectable={!searching}
                showCheckbox={selectionMode && !searching}
                selected={selectedIds.includes(memoryId)}
                active={memoryId === selectedId}
                busy={busyRow === memoryId}
                onSelectedChange={(next) =>
                  setSelectedIds((prev) => (next ? [...prev, memoryId] : prev.filter((id) => id !== memoryId)))
                }
                onVerb={(target, verb) => {
                  if (verb === 'edit') {
                    rememberRow(memoryId);
                    navigateTo(memoryEditHref(memoryId));
                    return;
                  }
                  if (verb === 'archive') {
                    setConfirm({ verb, ids: [memoryId] });
                    return;
                  }
                  void singleVerb(target, verb);
                }}
                onOpen={() => openMemory(memoryId)}
              />
            );
          })}
        </ul>
      )}
      {footer}
    </>
  );

  /**
   * Everything below the tabs: the Archived sub-control, the rows and the bulk bar.
   * One variable because it renders INSIDE the tab panel normally and OUTSIDE it
   * while a query is active — search results belong to no tab, and a panel labelled
   * by a tab that is not selected would claim otherwise.
   */
  const listSection = (
    <div className={`flex w-full min-w-0 flex-col gap-4 ${twoPane ? 'flex-1 min-h-0 overflow-hidden' : ''}`}>
      {/* The Archived tab's second level. Both options are terminal — a memory under
          this tab is out of force either way — so neither level can misdescribe its
          contents. The Rejected view issues no request until it is selected. */}
      {tab === 'archived' && !searching ? (
        <div role="group" aria-label="Archived memories" data-debug-id="memory-archived-view" className="flex items-center gap-2 shrink-0">
          {(['archived', 'rejected'] as ArchivedView[]).map((view) => (
            <Button
              key={view}
              size="sm"
              variant={archivedView === view ? 'primary' : 'secondary'}
              aria-pressed={archivedView === view}
              data-debug-id={`memory-archived-view-${view}`}
              onClick={() => applyUrlState({ ...urlState, archivedView: view })}
            >
              {view === 'archived' ? 'Archived' : 'Rejected'}
            </Button>
          ))}
        </div>
      ) : null}

      {/* REQ-UI-5's explanatory banner is REMOVED at the user's instruction. The
          behaviour it described is unchanged — a query still replaces the list and
          the server still disregards tabs and filters — and the UI still SHOWS that
          rather than only saying it: the tabs go unselected and the Filters control
          goes inert while a query is active. What is gone is the paragraph, not the
          signal. The held filter state is still restored when the query is cleared. */}

      {/* REQ-UI-20: nothing re-sorts under the user. Changes from elsewhere wait
          behind this pill and are applied only on tap. */}
      {!searching && list.pendingCount > 0 ? (
        <div className="shrink-0">
          <Button size="sm" variant="secondary" data-debug-id="memory-pending-pill" onClick={() => list.applyPending()}>
            {list.pendingCount} new or updated — refresh
          </Button>
        </div>
      ) : null}

      {list.restoreNotice ? (
        <div className="shrink-0">
          <Text role="body-sm" tone="muted" data-debug-id="memory-restore-notice">
            Couldn&apos;t find where you were — showing the top of the list.
          </Text>
        </div>
      ) : null}

      <div className={twoPane ? 'flex-1 min-h-0 overflow-y-auto' : undefined}>
        {listBody}
      </div>

      {/* Bulk verbs are scoped to what the current tab can actually do. Search
          results offer none — the row is a navigation target there. */}
      {!searching ? (
        <div className="shrink-0">
          <BulkActionBar
            selectedCount={selectedIds.length}
            loadedCount={list.loadedCount}
            onCancel={() => setSelectedIds([])}
          >
            {bulkVerbs.map((verb) => (
              <ActionButton
                key={verb}
                icon={BULK_VERB_ICON[verb]}
                label={VERB_LABEL[verb]}
                variant={verb === 'reject' || verb === 'archive' ? 'danger' : 'primary'}
                loading={bulkBusy}
                disabled={selectedIds.length === 0}
                data-debug-id={`memory-bulk-${verb}`}
                onClick={() => requestBulk(verb)}
              />
            ))}
          </BulkActionBar>
        </div>
      ) : null}
    </div>
  );

  /* ---------------- Toolbar (spec › LIST VIEW › Toolbar) ----------------
   * One row, 12px below the header: search takes the slack, then Filters carrying a
   * count of what is actually applied, then Select. Below 768 Filters and Select are
   * icon buttons — `ActionButton` makes that the component's rule, not the page's. */
  const searchFilter = (
    <ResourceSearchFilter
      searchQuery={queryInput}
      onSearchChange={(next) => {
        setQueryInput(next);
        if (!next) {
          applyUrlState({ ...urlState, q: '' });
        }
      }}
      searchPlaceholder="Search titles and bodies…"
      searchDebugId="memory-search-input"
      searchRef={searchRef}
      searchClearDebugId="memory-search-clear"
      activeTab={searching ? '' : tab}
      onTabChange={(next) => applyUrlState({ ...urlState, tab: next as MemoryTab })}
      selectionMode={selectionMode}
      onToggleSelection={() => {
        setSelectionMode((prev) => !prev);
        if (selectionMode) setSelectedIds([]);
      }}
      tabsLabel="Memory status"
      tabs={MEMORY_TABS.map((entry) => ({
        value: entry.value,
        label: entry.label,
        disabled: searching,
        debugId: `memory-tab-${entry.value}`,
      }))}
    >
      <div className="flex items-center gap-2">
        <FilterBar
          active={filtersActive}
          activeCount={activeFilterCount}
          iconTrigger
          disabled={searching}
          disabledTitle="Filters don't apply while you're searching"
          surface={isMobile ? 'sheet' : 'popover'}
          note={
            <>
              Scope filters show memories that <strong>apply to</strong> the selection — including global memories.
            </>
          }
        >
          <Select
            value={urlState.type}
            onChange={(next) => applyUrlState({ ...urlState, type: next })}
            size="sm"
            aria-label="Type"
            data-debug-id="memory-filter-type"
          >
            <option value="">All types</option>
            {MEMORY_TYPE_OPTIONS.map((type) => (
              <option key={type} value={type}>{type}</option>
            ))}
          </Select>
          {scopeFilterControls}
        </FilterBar>
      </div>
    </ResourceSearchFilter>
  );

  /* Active filters as removable chips, under the toolbar. Only what is ON gets page
     space; the controls that mostly read "All" stay behind the button. */
  const filterChipRow =
    filterChips.length && !searching ? (
      <div className="flex flex-wrap items-center gap-1.5" data-debug-id="memory-filter-chips">
        {filterChips.map((chip) => (
          <button
            key={chip.key}
            type="button"
            onClick={chip.clear}
            data-debug-id={`memory-filter-chip-${chip.key}`}
            aria-label={`Remove filter ${chip.label}`}
            className="inline-flex items-center gap-1 rounded-full border border-subtle bg-neutral-soft px-2 py-0.5 text-caption text-muted hover:text-primary focus-visible:shadow-focus focus-visible:outline-none"
          >
            {chip.label}
            <Icon name="close" size="sm" aria-hidden="true" />
          </button>
        ))}
        {/* Clear filters lives with the chips, not in the toolbar. It is gated on
            `!searching` for Amendment 3's reason: while a query is active the Alert
            promises to restore the exact held filter state, and a live Clear would
            destroy the state being promised. */}
        <Button size="sm" variant="ghost" data-debug-id="memory-filter-clear" onClick={clearFilters}>
          Clear filters
        </Button>
      </div>
    ) : null;

  const listColumn = (
    <div data-debug-id="memory-list-page" className="flex w-full min-w-0 flex-col gap-3 flex-1 min-h-0 h-full overflow-hidden">
      {searchFilter}
      {filterChipRow ? <div className="shrink-0">{filterChipRow}</div> : null}
      <div className="flex-1 min-h-0 overflow-hidden flex flex-col">
        {listSection}
      </div>
    </div>
  );

  const overlays = (
    <>
      {confirm ? (
        <ConfirmModal
          verb={confirm.verb}
          ids={confirm.ids}
          rows={visibleRows}
          busy={bulkBusy}
          onCancel={() => setConfirm(null)}
          onConfirm={() => {
            const pending = confirm;
            setConfirm(null);
            void runBulk(pending.verb, pending.ids);
          }}
        />
      ) : null}

      {toasts.length ? (
        <div className="pointer-events-none fixed inset-x-0 app-viewport-bottom z-toast flex flex-col items-center gap-2 p-4 sm:items-end">
          {toasts.map((entry) => (
            <div key={entry.id} className="pointer-events-auto">
              <Toast
                tone={entry.tone}
                title={entry.title}
                duration={entry.duration ?? 4000}
                onDismiss={() => dismissToast(entry.id)}
              >
                <div className="flex items-center gap-3">
                  {entry.message ? <span>{entry.message}</span> : null}
                  {entry.undo ? (
                    <Button
                      size="sm"
                      variant="secondary"
                      data-debug-id="memory-toast-undo"
                      onClick={() => { entry.undo?.(); dismissToast(entry.id); }}
                    >
                      Undo
                    </Button>
                  ) : null}
                </div>
              </Toast>
            </div>
          ))}
        </div>
      ) : null}
    </>
  );

  /* ---------------- Two-pane (spec › Desktop layout) ----------------
   * At >=1024 the list keeps its place on the left (max 420px) and the memory opens
   * in a pane on the right. The ROUTE is unchanged — `#/memory/:id` still deep-links
   * to the same memory — so a pasted link and a click land in the same place, and
   * the same memory never has two URLs. Between 768 and 1023 the spec asks for a
   * single centred column, which is what `width="content"` gives. */
  return (
    <ResourceContainer
      title="Memory"
      description="Durable facts, habits and skills your agents carry between sessions. An empty scope applies to all."
      breadcrumbs={listCrumbs()}
      actions={
        <Button
          variant="primary"
          data-debug-id="memory-new-btn"
          leading={<Icon name="plus" size="sm" />}
          onClick={() => navigateTo(memoryNewHref())}
        >
          New memory
        </Button>
      }
      selectedId={selectedId}
      detailTitle="Memory Details"
      listDebugId="memory-list-column"
      detailDebugId="memory-detail-pane"
      emptyDetailText="Select a memory to see it here."
      list={listColumn}
      detail={
        selectedId ? (
          <MemoryDetailPane
            memoryId={selectedId}
            onAfterVerb={(saved) => {
              // Same as the row verbs: patch the row with the server's record, so its
              // new status shows without a reload (useInfiniteList rows never see
              // tag invalidation).
              const record = saved && typeof saved === 'object' ? normalizeMemory(saved) : null;
              if (record?.memoryId) list.patchItem(selectedId, record);
              const next = advanceFrom(selectedId);
              // Auto-advance to the next proposal; if this was the last one,
              // close the pane rather than leaving a stale record open.
              navigateTo(next ? memoryViewHref(next, urlState) : memoryListHref(urlState));
            }}
            onDeleted={(deletedId) => {
              // Pick the neighbour before the row goes, then drop it in place.
              const next = advanceFrom(deletedId);
              list.removeItem(deletedId);
              pushToast({ tone: 'success', title: 'Memory deleted' });
              navigateTo(next && next !== deletedId ? memoryViewHref(next, urlState) : memoryListHref(urlState));
            }}
          />
        ) : null
      }
    >
      {overlays}
    </ResourceContainer>
  );
}

/**
 * The right-hand pane of the two-pane layout: the same detail the standalone page
 * renders, with its own heading instead of the page's `<h1>` (the page already has
 * one, and a second would break the single-h1 contract `PageShell` enforces).
 */
function MemoryDetailPane({
  memoryId,
  onAfterVerb,
  onDeleted,
}: {
  memoryId: string;
  onAfterVerb: (saved: unknown) => void;
  onDeleted: (memoryId: string) => void;
}) {
  const { query, record, busy, actionError, runVerb } = useMemoryDetail(memoryId, (_verb, saved) => onAfterVerb(saved));
  const paneRef = React.useRef<HTMLDivElement | null>(null);
  const wide = usePaneIsWide(paneRef);

  if (query.isLoading) {
    return (
      <div role="status" aria-live="polite" className="p-6">
        <Text role="body-sm" tone="muted">Loading…</Text>
      </div>
    );
  }
  if (query.error || !record) {
    return (
      <div className="p-6">
        <Alert tone="danger" title="Couldn't load that memory">
          {query.error ? memoryErrorText(query.error) : 'It may have been removed.'}
        </Alert>
      </div>
    );
  }

  return (
    <div ref={paneRef} className="flex min-w-0 flex-col gap-3 flex-1 min-h-0 h-full overflow-hidden" data-debug-id="memory-pane">
      <MemoryDetailHeader
        record={record}
        busy={busy}
        onVerb={(verb) => void runVerb(verb)}
        onDeleted={onDeleted}
      />
      <div className="flex-1 min-h-0 overflow-y-auto">
        <MemoryDetailBody record={record} actionError={actionError} wide={wide} />
      </div>
    </div>
  );
}

/**
 * The destructive confirm (§6, REQ-UI-18). Archive always confirms — it changes
 * what agents receive. Reject confirms only in bulk, because an N-row mistake is
 * not undoable in one tap.
 */
function ConfirmModal({
  verb,
  ids,
  rows,
  busy,
  onCancel,
  onConfirm,
}: {
  verb: MemoryVerb;
  ids: string[];
  rows: any[];
  busy: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  const titles = ids
    .map((id) => rows.find((row) => String(row.memoryId || row.id || '') === id))
    .filter(Boolean)
    .slice(0, 3)
    .map((row) => maskVaultArmored(memoryTitle(row)));
  const count = ids.length;
  const single = count === 1;
  const label = verb === 'archive' ? (single ? 'Archive' : `Archive ${count}`) : `Reject ${count}`;
  const title = verb === 'archive'
    ? (single ? 'Archive this memory?' : `Archive ${count} memories?`)
    : `Reject ${count} proposals?`;
  const body = verb === 'archive'
    ? (single
      ? `Archive “${titles[0] || 'this memory'}”? Agents will stop receiving it. You can restore it from the Archived tab.`
      : `Archive ${count} memories? Agents will stop receiving them. You can restore them from the Archived tab.`)
    : `Reject ${count} proposals? They'll stay under Archived › Rejected and can be approved later.`;

  return (
    <Modal open onOpenChange={(next) => { if (!next) onCancel(); }} title={title} size="sm" data-debug-id="memory-confirm-modal">
      <ModalBody>
        <Text role="body">{body}</Text>
        {!single && titles.length ? (
          <ul className="mt-3 list-disc pl-5 text-body-sm text-muted">
            {titles.map((entry) => <li key={entry}>{entry}</li>)}
            {count > titles.length ? <li>and {count - titles.length} more</li> : null}
          </ul>
        ) : null}
      </ModalBody>
      <ModalFooter>
        <Button variant="secondary" data-debug-id="memory-confirm-cancel" onClick={onCancel}>Cancel</Button>
        <Button variant="danger" loading={busy} data-debug-id="memory-confirm-accept" onClick={onConfirm}>{label}</Button>
      </ModalFooter>
    </Modal>
  );
}

/** Re-exported for the shell's route table. */
export { memoryListSearch, EMPTY_LIST_URL_STATE };
