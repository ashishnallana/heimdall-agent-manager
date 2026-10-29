/**
 * ProjectListPage — `/projects`.
 * ------------------------------------------------------------------
 * The Memory list, applied to projects: four-line rows, a single `…` per row,
 * persistent checkboxes, search inline with the tabs, Filters as an icon button
 * with a count badge, keyset infinite scroll, and a two-pane master/detail at
 * >=1024 that reuses the detail route.
 *
 * What is genuinely different here, and why — the rest is inherited and not
 * re-argued (see `MemoryListPage`):
 *
 *  1. **The tab and the filter are applied in the BROWSER.** `GET /api/v1/projects`
 *     takes `limit` and `cursor` and nothing else (`project_handlers.odin:15-25`) —
 *     no `state`, no `vcs_kind`, no facet of any kind. Memory's tabs are server
 *     queries, so its tab and its paging agree about what a page holds; here they
 *     cannot. The consequence is handled honestly rather than hidden: when a tab
 *     has nothing in the rows loaded so far but the stream has more, the page keeps
 *     pulling (bounded by `FILTER_PAGE_CAP`) and then OFFERS to keep going, instead
 *     of showing an empty state that would be a lie.
 *     One upside falls out of it: switching tabs re-fetches nothing, because both
 *     tabs are views onto the same loaded stream.
 *
 *  2. **Bulk verbs exist on Active only.** An archived project can be edited but
 *     not restored — no endpoint un-archives (`project_service.odin:245-250`) — so
 *     the Archived tab has no bulk verb at all, and it therefore shows no
 *     checkboxes and no bulk bar. Offering a selection model with nothing to do
 *     with it is the Archived-tab lesson from Memory.
 *
 *  3. **Archive confirms and does not offer undo.** Memory's single reject is
 *     undoable, so it uses a toast with an Undo. Nothing here is undoable, so
 *     every archive — single or bulk — goes through the confirm, and the confirm
 *     says what archiving does and does not do to the project's chains and agents.
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
} from '@ui';
import ProjectRow from './ProjectRow';
import {
  ProjectDetailActions,
  ProjectDetailBody,
  ProjectDetailHeader,
  ProjectDetailMeta,
  ProjectDetailPaneSkeleton,
  useProjectDetail,
  usePaneIsWide,
} from './ProjectDetail';
import { getRouteSearch } from '../../utils/appLocation';
import {
  fetchProjectPage,
  searchProjectPage,
  projectErrorText,
  useArchiveProjectMutation,
  type ProjectHit,
  type ProjectRecord,
} from '../../api/endpoints/projects';
import {
  EMPTY_LIST_URL_STATE,
  FILTER_PAGE_CAP,
  PROJECT_TABS,
  archiveConfirmBody,
  hasActiveFilters,
  listCrumbs,
  matchesTab,
  matchesVcsFilter,
  navigateTo,
  parseProjectListUrl,
  projectEditHref,
  projectListHref,
  projectNewHref,
  projectState,
  projectTitle,
  projectViewHref,
  rememberRow,
  replaceListSearch,
  takeRememberedRow,
  vcsFilterLabel,
  type ProjectListUrlState,
  type ProjectTab,
  type ProjectVerb,
} from './projectModel';

/** The list endpoint's default page size, and search's maximum — they agree at 50. */
const PAGE_SIZE = 50;
/** The search box is debounced before the list is replaced. */
const SEARCH_DEBOUNCE_MS = 250;

type ToastEntry = {
  id: string;
  tone: 'success' | 'danger' | 'info';
  title: string;
  message?: string;
};

export default function ProjectListPage({ selectedId = '' }: { selectedId?: string } = {}) {
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
  const twoPane = viewport === 'desktop';
  const searchRef = React.useRef<HTMLInputElement | null>(null);

  /* ---------------- URL state ---------------- */
  const [urlState, setUrlState] = React.useState<ProjectListUrlState>(() =>
    parseProjectListUrl(getRouteSearch()),
  );
  const tab: ProjectTab = urlState.tab || 'active';
  const searching = Boolean(urlState.q);

  const applyUrlState = React.useCallback((next: ProjectListUrlState) => {
    setUrlState(next);
    replaceListSearch(next);
  }, []);

  /* ---------------- Legacy deep links ----------------
   * The old surface addressed a project as `#/projects?projectId=<id>` rather than
   * as a route. Those links are in the wild (and were in the app until this page
   * replaced it), so the query form is translated to the real route once, on
   * mount, with `replace` — a redirect the user can back out of would trap them. */
  React.useEffect(() => {
    const legacy = new URLSearchParams(getRouteSearch().replace(/^\?/, '')).get('projectId');
    if (!legacy) return;
    window.location.replace(`${window.location.pathname}${window.location.search}#${projectViewHref(legacy).replace(/^#/, '')}`);
  }, []);

  /* ---------------- Search ---------------- */
  const [queryInput, setQueryInput] = React.useState(urlState.q);
  React.useEffect(() => {
    if (queryInput === urlState.q) return undefined;
    const timer = window.setTimeout(() => {
      applyUrlState({ ...urlState, q: queryInput });
    }, SEARCH_DEBOUNCE_MS);
    return () => window.clearTimeout(timer);
  }, [queryInput, urlState, applyUrlState]);
  const querySettling = queryInput.trim() !== urlState.q.trim();

  /* ---------------- The two data paths ----------------
   * A query does not filter the list — it REPLACES it: different rows, score order
   * instead of `created_at`, and a reduced row shape with no state on it. Only one
   * hook is ever enabled.
   *
   * Note the list's `resetKey`: it is CONSTANT. The tab and the VCS filter are
   * applied client-side, so changing either must not throw away rows that are
   * already loaded and correct. */
  const list = useInfiniteList<ProjectRecord>({
    fetchPage: ({ cursor, signal }) => fetchProjectPage({ limit: PAGE_SIZE, cursor, signal }),
    getItemId: (row) => row.projectId,
    // Projects key on `created_at` server-side, but that field is never serialised
    // (`project_handlers.odin:77-79`) — so the hook is given `updated_at`, the one
    // timestamp on the wire, purely to tell "this row changed" from "this row is
    // the same" when probing for the N-new pill. The CURSOR itself comes from the
    // page envelope, so paging is unaffected.
    getCursorValue: (row) => row.updatedAt,
    resetKey: 'projects',
    enabled: !searching,
  });

  const search = useInfiniteList<ProjectHit>({
    fetchPage: ({ cursor, signal }) => searchProjectPage({ q: urlState.q, limit: PAGE_SIZE, cursor, signal }),
    getItemId: (hit) => hit.id,
    resetKey: urlState.q,
    enabled: searching,
  });

  const active = searching ? search : list;

  /* ---------------- Client-side tab + filter ---------------- */
  const visibleRows = React.useMemo(
    () => list.items.filter((row) => matchesTab(row, tab) && matchesVcsFilter(row, urlState.vcs)),
    [list.items, tab, urlState.vcs],
  );

  /**
   * Chase rows for the current tab/filter.
   *
   * Because the filter is client-side, "no rows" and "no rows YET" look identical
   * after one page: an archived project could be the 300th row of the stream. So
   * while the filtered view is empty and the stream has more, keep pulling — up to
   * `FILTER_PAGE_CAP` pages, after which the user is offered the choice rather
   * than the page spending their bandwidth silently.
   */
  const [autoPages, setAutoPages] = React.useState(0);
  React.useEffect(() => {
    setAutoPages(0);
  }, [tab, urlState.vcs]);
  React.useEffect(() => {
    if (searching) return;
    if (visibleRows.length > 0) return;
    if (!list.hasMore || list.isPaging || list.isLoadingInitial || list.pagingError) return;
    if (autoPages >= FILTER_PAGE_CAP) return;
    setAutoPages((prev) => prev + 1);
    list.loadMore();
  }, [autoPages, list, searching, visibleRows.length]);

  /** True when the tab looks empty only because the stream has not been walked. */
  const moreToSearch = !searching && visibleRows.length === 0 && list.hasMore;

  /* ---------------- Live updates ----------------
   * Projects have no WS stream, so the list re-probes on refocus. Loaded rows hold
   * their position; anything new or changed surfaces as a pill the user applies. */
  React.useEffect(() => {
    if (searching) return undefined;
    const onFocus = () => list.refresh();
    window.addEventListener('focus', onFocus);
    return () => window.removeEventListener('focus', onFocus);
  }, [list, searching]);

  /* ---------------- Scroll restoration ---------------- */
  const restoredRef = React.useRef(false);
  React.useEffect(() => {
    if (restoredRef.current) return;
    restoredRef.current = true;
    const rowId = takeRememberedRow();
    if (!rowId || searching) return;
    void list.restoreToId(rowId).then((outcome) => {
      if (outcome !== 'found') return;
      window.requestAnimationFrame(() => {
        const node = document.querySelector(`[data-project-row="${CSS.escape(rowId)}"]`);
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

  /* ---------------- Selection ---------------- */
  const [selectionMode, setSelectionMode] = React.useState(false);
  const [selectedIds, setSelectedIds] = React.useState<string[]>([]);
  // Selection is scoped to what is on screen: changing tab, filter or query means
  // the selected rows may not even be visible any more.
  React.useEffect(() => {
    setSelectedIds([]);
  }, [tab, urlState.vcs, urlState.q]);

  /* ---------------- Toasts ---------------- */
  const [toasts, setToasts] = React.useState<ToastEntry[]>([]);
  const pushToast = React.useCallback((entry: Omit<ToastEntry, 'id'>) => {
    const id = `project-toast-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
    setToasts((prev) => [...prev.slice(-2), { ...entry, id }]);
  }, []);
  const dismissToast = React.useCallback((id: string) => {
    setToasts((prev) => prev.filter((entry) => entry.id !== id));
  }, []);

  /* ---------------- Archive ---------------- */
  const [confirm, setConfirm] = React.useState<{ ids: string[] } | null>(null);
  const [bulkBusy, setBulkBusy] = React.useState(false);
  const [busyRow, setBusyRow] = React.useState('');

  const [archiveProject] = useArchiveProjectMutation();

  const runArchive = React.useCallback(
    async (projectId: string) => {
      const saved = await archiveProject({ projectId }).unwrap();
      const record = saved && typeof saved === 'object' ? saved : null;
      if (record) {
        // Patch IN PLACE with the server's own record, so the new Archived pill
        // appears where the row already sits. The row does not jump, even though
        // the write moved it in the server's order.
        list.patchItem(projectId, (prev) => ({ ...prev, state: 'archived', updatedAt: String((record as any).updated_at || prev.updatedAt) }));
      }
    },
    [archiveProject, list],
  );

  const runBulkArchive = React.useCallback(
    async (ids: string[]) => {
      setBulkBusy(true);
      const failed: string[] = [];
      let done = 0;
      for (const id of ids) {
        try {
          await runArchive(id);
          done += 1;
        } catch {
          failed.push(id);
        }
      }
      setBulkBusy(false);
      // Partial failure is reported honestly and the failed rows STAY selected, so
      // a retry hits only them.
      setSelectedIds(failed);
      pushToast({
        tone: failed.length ? 'danger' : 'success',
        title: failed.length ? `${done} archived, ${failed.length} failed` : `${done} archived`,
        message: failed.length ? 'The rows that failed are still selected.' : undefined,
      });
    },
    [pushToast, runArchive],
  );

  /* ---------------- Filters ---------------- */
  const filtersActive = hasActiveFilters(urlState);
  const activeFilterCount = urlState.vcs ? 1 : 0;
  const clearFilters = () => applyUrlState({ ...urlState, vcs: '' });

  /* ---------------- Keyboard ----------------
   * j/k move through the visible rows, e edits, / focuses search. Bound on the
   * window so they work without the list holding focus, ignored while typing or
   * while a modal is open, and a verb only fires when the focused row offers it.
   * There is no single-letter archive: a one-way destructive verb on one keypress
   * is a trap, and it is the one verb on this page with no way back. */
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

      const items = visibleRows;
      const index = items.findIndex((row) => row.projectId === cursorRef.current);

      if (event.key === 'j' || event.key === 'k') {
        if (items.length === 0) return;
        event.preventDefault();
        const nextIndex = event.key === 'j'
          ? Math.min(items.length - 1, index < 0 ? 0 : index + 1)
          : Math.max(0, index < 0 ? 0 : index - 1);
        const next = items[nextIndex];
        const nextId = next ? next.projectId : '';
        setCursorId(nextId);
        if (twoPane && nextId) navigateTo(projectViewHref(nextId, urlState));
        const node = nextId ? document.querySelector(`[data-project-row="${CSS.escape(nextId)}"]`) : null;
        node?.scrollIntoView({ block: 'nearest' });
        return;
      }

      if (event.key === 'e') {
        const row = index >= 0 ? items[index] : null;
        if (!row) return;
        event.preventDefault();
        rememberRow(row.projectId);
        navigateTo(projectEditHref(row.projectId));
      }
    }
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [confirm, twoPane, urlState, visibleRows]);

  /* ---------------- Empty states ---------------- */
  function emptyState(): React.ReactNode {
    if (searching) {
      return (
        <EmptyState
          data-debug-id="project-empty-query"
          icon="search"
          title={`No projects match “${urlState.q}”`}
          // Says what IS searched, so a miss reads as a miss rather than as a
          // broken search: the index covers name, id, slug, repo URL and vcs kind
          // — but NOT the description (`search_repo_sqlite.odin:708-722`).
          description="Search covers project names, paths, slugs and repository URLs — not descriptions."
          action={<Button variant="secondary" onClick={() => { setQueryInput(''); applyUrlState({ ...urlState, q: '' }); }}>Clear search</Button>}
        />
      );
    }
    if (filtersActive) {
      return (
        <EmptyState
          data-debug-id="project-empty-filters"
          icon="layers"
          title="No projects match this filter"
          description="Try a different version-control kind, or clear the filter."
          action={<Button variant="secondary" onClick={clearFilters}>Clear filter</Button>}
        />
      );
    }
    if (tab === 'archived') {
      return (
        <EmptyState
          data-debug-id="project-empty-archived"
          icon="folder"
          title="Nothing archived"
          description="Archiving takes a project out of the Active list without deleting it or touching its chains and agents."
        />
      );
    }
    return (
      <EmptyState
        data-debug-id="project-empty-first-run"
        icon="grid"
        title="No projects yet"
        description="A project points Ninjy at a folder on your machines. Everything an agent does — chains, conversations, memory — hangs off one."
        action={<Button variant="primary" onClick={() => navigateTo(projectNewHref())}>New project</Button>}
      />
    );
  }

  /* ---------------- The list foot ---------------- */
  const footer = (
    <div>
      {active.isPaging ? (
        <div data-debug-id="project-paging-skeleton" aria-hidden="true" className="flex flex-col gap-2 py-3">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-5 w-full animate-pulse rounded-[var(--radius-sm)] bg-neutral-soft" />
          ))}
        </div>
      ) : null}
      {active.pagingError ? (
        // A paging failure never destroys the rows already loaded.
        <div data-debug-id="project-paging-error" className="py-3">
          <Alert tone="danger" title="Couldn't load more projects">
            <div className="flex items-center gap-3">
              <span>{projectErrorText(active.pagingError)}</span>
              <Button size="sm" variant="secondary" onClick={() => active.loadMore()}>Retry</Button>
            </div>
          </Alert>
        </div>
      ) : null}
      {active.hasMore && !active.pagingError ? (
        <div ref={active.sentinelRef} data-debug-id="project-scroll-sentinel" className="h-px w-full" />
      ) : null}
    </div>
  );

  /* ---------------- Rows ---------------- */
  const openProject = React.useCallback(
    (projectId: string) => {
      if (!projectId) return;
      rememberRow(projectId);
      navigateTo(projectViewHref(projectId, urlState));
    },
    [urlState],
  );

  /** Auto-select the first project in two-pane mode if none is selected */
  React.useEffect(() => {
    if (twoPane && !selectedId && visibleRows.length > 0) {
      openProject(visibleRows[0].projectId);
    }
  }, [twoPane, selectedId, visibleRows, openProject]);

  // Checkboxes exist only where a bulk verb does. On Archived there is nothing to
  // do with a selection, so there is no selection.
  const selectable = !searching && tab === 'active';

  const listBody = (
    <>
      {active.status === 'error' ? (
        <Alert tone="danger" title="Couldn't load projects">
          <div className="flex flex-col items-start gap-3">
            <span>{projectErrorText(active.error)}</span>
            <Button size="sm" variant="secondary" onClick={() => active.reload()}>Retry</Button>
          </div>
        </Alert>
      ) : active.isLoadingInitial ? (
        // Skeleton ROWS at the real row height — never a spinner, never a shift.
        <div role="status" aria-live="polite" aria-busy="true" data-debug-id="project-list-skeleton">
          <span className="sr-only">Loading projects…</span>
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
      ) : searching ? (
        search.items.length === 0 ? (
          emptyState()
        ) : (
          <ul
            aria-label="Project search results"
            data-debug-id="project-search-rows"
            className={['flex flex-col', querySettling ? 'opacity-60' : ''].filter(Boolean).join(' ')}
          >
            {search.items.map((hit) => (
              <ProjectRow
                // A search hit has no state, no description and no timestamp — the
                // search API returns a label and a sublabel and nothing else. It is
                // rendered through the same row so the two paths look identical,
                // with the fields it genuinely has.
                key={hit.id}
                row={{
                  projectId: hit.id,
                  name: hit.label,
                  slug: hit.slug,
                  description: '',
                  repoUrl: '',
                  vcsKind: hit.vcsKind,
                  defaultPath: '',
                  state: 'active',
                  updatedAt: '',
                  bridgePaths: [],
                }}
                href={projectViewHref(hit.id, urlState)}
                selectable={false}
                showCheckbox={false}
                selected={false}
                active={hit.id === selectedId}
                onSelectedChange={() => undefined}
                onVerb={(row, verb) => {
                  if (verb === 'edit') navigateTo(projectEditHref(row.projectId));
                }}
                onOpen={() => openProject(hit.id)}
              />
            ))}
          </ul>
        )
      ) : visibleRows.length === 0 ? (
        moreToSearch ? (
          /* The honest version of an empty state on a client-side filter: the tab
             has nothing in the rows loaded so far, but the stream is not finished.
             Saying "nothing here" would be a claim the page cannot support. */
          <div className="flex flex-col items-start gap-3 py-6" data-debug-id="project-more-to-search">
            <Text role="body" tone="muted" className="ui-measure">
              Nothing under {PROJECT_TABS.find((entry) => entry.value === tab)?.label} in the projects loaded so far.
              This list loads in pages, and older projects may still be further down.
            </Text>
            <Button
              size="sm"
              variant="secondary"
              loading={list.isPaging}
              data-debug-id="project-load-more"
              onClick={() => list.loadMore()}
            >
              Keep loading
            </Button>
          </div>
        ) : (
          emptyState()
        )
      ) : (
        <ul aria-label="Projects" data-debug-id="project-rows" className="flex flex-col">
          {visibleRows.map((row) => (
            <ProjectRow
              key={row.projectId}
              row={row}
              href={projectViewHref(row.projectId, urlState)}
              selectable={selectable}
              showCheckbox={selectionMode && selectable}
              selected={selectedIds.includes(row.projectId)}
              active={row.projectId === selectedId}
              busy={busyRow === row.projectId}
              onSelectedChange={(next) =>
                setSelectedIds((prev) => (next ? [...prev, row.projectId] : prev.filter((id) => id !== row.projectId)))
              }
              onVerb={(target, verb: ProjectVerb) => {
                if (verb === 'edit') {
                  rememberRow(target.projectId);
                  navigateTo(projectEditHref(target.projectId));
                  return;
                }
                // Archive always confirms. Nothing here is undoable, so there is no
                // undo-toast path of the kind Memory's single reject uses.
                setConfirm({ ids: [target.projectId] });
              }}
              onOpen={() => openProject(row.projectId)}
            />
          ))}
        </ul>
      )}
      {footer}
    </>
  );

  const listSection = (
    <div className={`flex w-full min-w-0 flex-col gap-4 ${twoPane ? 'flex-1 min-h-0 overflow-hidden' : ''}`}>
      {/* REQ-UI-20: nothing re-sorts under the user. Changes from elsewhere wait
          behind this pill and are applied only on tap. */}
      {!searching && list.pendingCount > 0 ? (
        <div className="shrink-0">
          <Button size="sm" variant="secondary" data-debug-id="project-pending-pill" onClick={() => list.applyPending()}>
            {list.pendingCount} new or updated — refresh
          </Button>
        </div>
      ) : null}

      {list.restoreNotice ? (
        <div className="shrink-0">
          <Text role="body-sm" tone="muted" data-debug-id="project-restore-notice">
            Couldn&apos;t find where you were — showing the top of the list.
          </Text>
        </div>
      ) : null}

      <div className={twoPane ? 'flex-1 min-h-0 overflow-y-auto' : undefined}>
        {listBody}
      </div>

      {selectable ? (
        <div className="shrink-0">
          <BulkActionBar
            selectedCount={selectedIds.length}
            loadedCount={visibleRows.length}
            onCancel={() => setSelectedIds([])}
          >
            <ActionButton
              icon="folder"
              label="Archive"
              variant="danger"
              loading={bulkBusy}
              disabled={selectedIds.length === 0}
              data-debug-id="project-bulk-archive"
              onClick={() => selectedIds.length && setConfirm({ ids: selectedIds })}
            />
          </BulkActionBar>
        </div>
      ) : null}
    </div>
  );

  /* Active filters as removable chips, under the toolbar. */
  const filterChipRow =
    filtersActive && !searching ? (
      <div className="flex flex-wrap items-center gap-1.5" data-debug-id="project-filter-chips">
        <button
          type="button"
          onClick={clearFilters}
          data-debug-id="project-filter-chip-vcs"
          aria-label={`Remove filter ${vcsFilterLabel(urlState.vcs)}`}
          className="inline-flex items-center gap-1 rounded-full border border-subtle bg-neutral-soft px-2 py-0.5 text-caption text-muted hover:text-primary focus-visible:shadow-focus focus-visible:outline-none"
        >
          {vcsFilterLabel(urlState.vcs)}
          <Icon name="close" size="sm" aria-hidden="true" />
        </button>
        <Button size="sm" variant="ghost" data-debug-id="project-filter-clear" onClick={clearFilters}>
          Clear filter
        </Button>
      </div>
    ) : null;

  const listColumn = (
    <div className="flex w-full min-w-0 flex-col gap-3 flex-1 min-h-0 h-full overflow-hidden">
      <div data-debug-id="project-toolbar">
        <ResourceSearchFilter
          searchQuery={queryInput}
          onSearchChange={setQueryInput}
          searchPlaceholder="Search names, paths and repos…"
          searchDebugId="project-search-input"
          searchClearDebugId="project-search-clear"
          searchRef={searchRef}
          activeTab={searching ? '' : tab}
          onTabChange={(next) => applyUrlState({ ...urlState, tab: next as ProjectTab })}
          selectionMode={selectionMode}
          onToggleSelection={() => {
            setSelectionMode((prev) => !prev);
            if (selectionMode) setSelectedIds([]);
          }}
          tabs={PROJECT_TABS.map((entry) => ({
            value: entry.value,
            label: entry.label,
            disabled: searching,
            debugId: `project-tab-${entry.value}`,
          }))}
          tabsLabel="Project state"
        >
          <FilterBar
            active={filtersActive}
            activeCount={activeFilterCount}
            iconTrigger
            disabled={searching}
            disabledTitle="Filters don't apply while you're searching"
            surface={isMobile ? 'sheet' : 'popover'}
            note={<>Version control is read from each project&apos;s own setting, not detected on disk.</>}
          >
            <Select
              value={urlState.vcs}
              onChange={(next) => applyUrlState({ ...urlState, vcs: next })}
              size="sm"
              aria-label="Version control"
              data-debug-id="project-filter-vcs"
              options={[
                { value: '', label: 'Any version control' },
                { value: 'git', label: 'git' },
                { value: 'jj', label: 'jj' },
                { value: 'none', label: 'No VCS' },
              ]}
            />
          </FilterBar>
        </ResourceSearchFilter>
      </div>
      {filterChipRow ? <div className="shrink-0">{filterChipRow}</div> : null}
      <div className="flex min-w-0 flex-col gap-4 flex-1 min-h-0 overflow-hidden">
        {listSection}
      </div>
    </div>
  );

  const confirmNames = React.useMemo(
    () =>
      (confirm?.ids || []).map((id) => {
        const row = list.items.find((item) => item.projectId === id);
        return row ? projectTitle(row) : id;
      }),
    [confirm, list.items],
  );

  const overlays = (
    <>
      {confirm ? (
        <Modal
          open
          onOpenChange={(next) => { if (!next) setConfirm(null); }}
          title={confirm.ids.length === 1 ? `Archive “${confirmNames[0]}”?` : `Archive ${confirm.ids.length} projects?`}
          size="sm"
          data-debug-id="project-archive-modal"
        >
          <ModalBody>
            <Text role="body">{archiveConfirmBody(confirmNames)}</Text>
          </ModalBody>
          <ModalFooter>
            <Button variant="secondary" data-debug-id="project-archive-cancel" onClick={() => setConfirm(null)}>Cancel</Button>
            <Button
              variant="danger"
              loading={bulkBusy}
              data-debug-id="project-archive-confirm"
              onClick={() => {
                const pending = confirm;
                setConfirm(null);
                if (!pending) return;
                if (pending.ids.length === 1) {
                  const only = pending.ids[0];
                  setBusyRow(only);
                  void runArchive(only)
                    .then(() => pushToast({ tone: 'success', title: 'Project archived' }))
                    .catch((err) => pushToast({ tone: 'danger', title: "Couldn't archive this project", message: projectErrorText(err) }))
                    .finally(() => setBusyRow(''));
                  return;
                }
                void runBulkArchive(pending.ids);
              }}
            >
              Archive
            </Button>
          </ModalFooter>
        </Modal>
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
    'A project points Ninjy at a folder on your machines. Chains, conversations and memory all hang off one.';

  return (
    <ResourceContainer
      title="Projects"
      description={headerDescription}
      breadcrumbs={listCrumbs()}
      actions={
        <Button
          variant="primary"
          data-debug-id="project-new-btn"
          leading={<Icon name="plus" size="sm" />}
          onClick={() => navigateTo(projectNewHref())}
        >
          New project
        </Button>
      }
      selectedId={selectedId}
      detailTitle="Project Details"
      listDebugId="project-list-page"
      detailDebugId="project-detail-pane"
      emptyDetailText="Select a project to see it here."
      list={listColumn}
      detail={
        selectedId ? (
          <ProjectDetailPane projectId={selectedId} onAfterArchive={() => undefined} />
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
function ProjectDetailPane({ projectId, onAfterArchive }: { projectId: string; onAfterArchive: () => void }) {
  const { query, record, busy, actionError, runVerb } = useProjectDetail(projectId, () => onAfterArchive());
  const paneRef = React.useRef<HTMLDivElement | null>(null);
  const wide = usePaneIsWide(paneRef);

  if (query.isLoading) return <ProjectDetailPaneSkeleton />;
  if (query.error || !record) {
    return (
      <EmptyState
        data-debug-id="project-pane-missing"
        icon="search"
        title="That project doesn't exist"
        description={query.error ? projectErrorText(query.error) : undefined}
        action={<Button variant="secondary" onClick={() => navigateTo(projectListHref())}>Back to Projects</Button>}
      />
    );
  }

  return (
    <div ref={paneRef} className="min-w-0 flex flex-col min-h-0 h-full overflow-hidden">
      <div className="mb-3 shrink-0">
        <ProjectDetailHeader
          record={record}
          busy={busy}
          onVerb={(verb) => void runVerb(verb)}
        />
      </div>
      <div className="flex-1 min-h-0 overflow-y-auto">
        <ProjectDetailBody record={record} actionError={actionError} wide={wide} />
      </div>
    </div>
  );
}

/** Re-exported for the shell's route table. */
export { EMPTY_LIST_URL_STATE };
export { projectState };
