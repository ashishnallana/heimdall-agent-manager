/**
 * ActionListPage — `/actions`.
 * ------------------------------------------------------------------
 * Inherits the shape from AgentListPage/ProjectListPage. What differs, and why:
 *
 *  1. **No infinite scroll, and no `useInfiniteList`.** `GET /api/v1/actions`
 *     returns the whole list — no limit, no cursor, no has_more, no count
 *     (`action_handlers.odin:216`). REQ-UI-6 is WAIVED for this resource by user
 *     ruling. `useInfiniteList`'s own doc excludes "a list small enough to load
 *     whole", so using it here would be misusing it, not reusing it.
 *
 *     The happy consequence: **REQ-UI-5 is exactly true here.** Tabs, filters and
 *     search all read the same already-loaded array, so "a query disregards
 *     filters" is a property of one `useMemo` rather than a promise about two
 *     different endpoints. Per Amendment 7 the explanatory banner is gone; the
 *     visible signals are the inert Filters control and no tab selected.
 *
 *  2. **Tabs are Scheduled | On demand, not states.** `in_flight` lasts as long as
 *     one dispatch, so a state tab would move rows out from under a reader. State
 *     is a filter instead.
 *
 *  3. **Filters are client-side** (state / project / bridge), single-select per
 *     Amendment 8, with their options derived from the loaded rows plus the
 *     catalog — so all three catalog states are real here and are rendered.
 *
 *  4. **Delete, not archive**, and it is permanent to the UI. Bulk offers Delete
 *     ONLY: bulk Run now would mint instances across N rows on one mis-click with
 *     nothing to undo it, and a bulk verb should be one you can afford to fire by
 *     accident.
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
  useViewport,
} from '@ui';
import ActionRow from './ActionRow';
import {
  ActionDetailBody,
  ActionDetailHeader,
  ActionDetailPaneSkeleton,
  useActionDetail,
  usePaneIsWide,
} from './ActionDetail';
import { getRouteSearch } from '../../utils/appLocation';
import { isVaultArmored } from '../../utils/vaultContent.ts';
import {
  useDeleteActionMutation,
  useListActionsQuery,
  useRunActionMutation,
  type Action,
} from '../../api/endpoints/actions';
import { bridgeLabel, catalogNote, projectLabel, useActionCatalog, type ActionCatalog } from './actionCatalog';
import {
  ACTION_TABS,
  EMPTY_LIST_URL_STATE,
  STATE_FILTER_OPTIONS,
  actionEditHref,
  actionErrorText,
  actionListHref,
  actionNewHref,
  actionState,
  actionTitle,
  actionViewHref,
  activeFilterCount,
  deleteConfirmBody,
  hasActiveFilters,
  isScheduled,
  listCrumbs,
  matchesTab,
  navigateTo,
  parseActionListUrl,
  rememberRow,
  replaceListSearch,
  scheduleLabel,
  stateLabel,
  takeRememberedRow,
  type ActionListUrlState,
  type ActionState,
  type ActionTab,
  type ActionVerb,
} from './actionModel';

const SEARCH_DEBOUNCE_MS = 250;

type ToastEntry = {
  id: string;
  tone: 'success' | 'danger' | 'info';
  title: string;
  message?: string;
};

/* ------------------------------------------------------------------ *
 * Client-side search
 * ------------------------------------------------------------------ *
 * There is no `action` scope in the hub's search (`domain/search.odin:11`), so this
 * is the whole of it. It is deliberately NOT a scoring fuzzy match: every
 * whitespace-separated term must appear somewhere in the row's searchable text, so
 * the result set is predictable and a user can narrow by adding a word. The fields
 * matched are named in the input's placeholder and in the no-results copy, because
 * a search whose reach is invisible produces "it isn't there" when it is.
 */
function searchableText(row: Action, catalog: ActionCatalog): string {
  return [
    row.prompt_text && !isVaultArmored(row.prompt_text) ? row.prompt_text : '',
    row.id,
    row.cron_expr,
    scheduleLabel(row),
    row.timezone,
    row.target_instance_id ? catalog.instances.byId.get(row.target_instance_id)?.label : '',
    row.target_instance_id,
    row.target_agent_id ? catalog.agents.byId.get(row.target_agent_id)?.label : '',
    row.target_agent_id,
    bridgeLabel(row.target_bridge_id, catalog),
    projectLabel(row.target_project_id, catalog),
    row.target_provider,
    row.target_model,
  ]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();
}

function matchesQuery(row: Action, catalog: ActionCatalog, query: string): boolean {
  const terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (terms.length === 0) return true;
  const haystack = searchableText(row, catalog);
  return terms.every((term) => haystack.includes(term));
}

export default function ActionListPage({ selectedId = '' }: { selectedId?: string } = {}) {
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
  const twoPane = viewport === 'desktop';
  const searchRef = React.useRef<HTMLInputElement | null>(null);

  const catalog = useActionCatalog();

  /* ---------------- URL state ---------------- */
  const [urlState, setUrlState] = React.useState<ActionListUrlState>(() =>
    parseActionListUrl(getRouteSearch()),
  );
  const tab: ActionTab = urlState.tab || 'scheduled';
  const searching = Boolean(urlState.q);
  const filtersActive = hasActiveFilters(urlState);

  const applyUrlState = React.useCallback((next: ActionListUrlState) => {
    setUrlState(next);
    replaceListSearch(next);
  }, []);

  const clearFilters = React.useCallback(() => {
    applyUrlState({ ...urlState, state: '', project: '', bridge: '' });
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

  /* ---------------- The one data path ---------------- */
  const listQuery = useListActionsQuery();
  const allRows: Action[] = React.useMemo(
    () => (listQuery.data?.actions || []) as Action[],
    [listQuery.data],
  );

  /* Live-ish updates: re-read on focus, the same convenience Projects and Agents get.
     There is no keyset window to hold position in, so this is a plain refetch.
     The refetch goes through a ref because RTK hands back a NEW query object every
     render — depending on it directly would tear down and re-add the listener on
     every keystroke. */
  const refetchRef = React.useRef(listQuery.refetch);
  refetchRef.current = listQuery.refetch;
  React.useEffect(() => {
    const onFocus = () => { void refetchRef.current(); };
    window.addEventListener('focus', onFocus);
    return () => window.removeEventListener('focus', onFocus);
  }, []);

  /* ---------------- Tab + filters + search, over one array ----------------
   * REQ-UI-5: a query disregards tab AND filters. Here that is literally one
   * branch rather than a promise about two endpoints. */
  const visibleRows = React.useMemo(() => {
    if (searching) return allRows.filter((row) => matchesQuery(row, catalog, urlState.q));
    return allRows.filter((row) => {
      if (!matchesTab(row, tab)) return false;
      if (urlState.state && actionState(row) !== urlState.state) return false;
      if (urlState.project && String(row.target_project_id || '') !== urlState.project) return false;
      if (urlState.bridge && String(row.target_bridge_id || '') !== urlState.bridge) return false;
      return true;
    });
  }, [allRows, catalog, searching, tab, urlState.bridge, urlState.project, urlState.q, urlState.state]);

  /* Filter options come from the rows actually loaded, so a filter can never offer a
     value that matches nothing. */
  const projectOptions = React.useMemo(() => {
    const ids = new Set(allRows.map((row) => String(row.target_project_id || '')).filter(Boolean));
    return Array.from(ids)
      .map((id) => ({ id, label: projectLabel(id, catalog) }))
      .sort((l, r) => l.label.localeCompare(r.label));
  }, [allRows, catalog]);

  const bridgeOptions = React.useMemo(() => {
    const ids = new Set(allRows.map((row) => String(row.target_bridge_id || '')).filter(Boolean));
    return Array.from(ids)
      .map((id) => ({ id, label: bridgeLabel(id, catalog) }))
      .sort((l, r) => l.label.localeCompare(r.label));
  }, [allRows, catalog]);

  /* ---------------- Scroll restoration ---------------- */
  const restoredRef = React.useRef(false);
  React.useEffect(() => {
    if (restoredRef.current) return;
    if (listQuery.isLoading || allRows.length === 0) return;
    restoredRef.current = true;
    const rowId = takeRememberedRow();
    if (!rowId) return;
    // The whole list is loaded, so there is nothing to page through looking for the
    // remembered row — it is either rendered or it is not in the current filter.
    window.requestAnimationFrame(() => {
      const node = document.querySelector(`[data-action-row="${CSS.escape(rowId)}"]`);
      node?.scrollIntoView({ block: 'center' });
    });
  }, [allRows.length, listQuery.isLoading]);

  /* ---------------- Selection ---------------- */
  const [selectionMode, setSelectionMode] = React.useState(false);
  const [selectedIds, setSelectedIds] = React.useState<string[]>([]);
  React.useEffect(() => {
    setSelectedIds([]);
  }, [tab, urlState.q, urlState.state, urlState.project, urlState.bridge]);

  /* ---------------- Toasts ---------------- */
  const [toasts, setToasts] = React.useState<ToastEntry[]>([]);
  const pushToast = React.useCallback((entry: Omit<ToastEntry, 'id'>) => {
    const id = `action-toast-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
    setToasts((prev) => [...prev.slice(-2), { ...entry, id }]);
  }, []);
  const dismissToast = React.useCallback((id: string) => {
    setToasts((prev) => prev.filter((entry) => entry.id !== id));
  }, []);

  /* ---------------- Verbs ---------------- */
  const [confirm, setConfirm] = React.useState<{ ids: string[] } | null>(null);
  const [bulkBusy, setBulkBusy] = React.useState(false);
  const [busyRow, setBusyRow] = React.useState('');

  const [deleteAction] = useDeleteActionMutation();
  const [runAction] = useRunActionMutation();

  const runOne = React.useCallback(
    async (row: Action) => {
      setBusyRow(row.id);
      try {
        await runAction({ id: row.id }).unwrap();
        pushToast({
          tone: 'success',
          title: 'Run requested',
          message: 'The dispatch happens on the bridge. The row shows as in flight once the lease is taken.',
        });
      } catch (err) {
        pushToast({ tone: 'danger', title: "Couldn't run this action", message: actionErrorText(err) });
      } finally {
        setBusyRow('');
      }
    },
    [pushToast, runAction],
  );

  const runBulkDelete = React.useCallback(
    async (ids: string[]) => {
      setBulkBusy(true);
      const failed: string[] = [];
      let done = 0;
      for (const id of ids) {
        try {
          await deleteAction({ id }).unwrap();
          done += 1;
        } catch {
          failed.push(id);
        }
      }
      setBulkBusy(false);
      setSelectedIds(failed);
      pushToast({
        tone: failed.length ? 'danger' : 'success',
        title: failed.length ? `${done} deleted, ${failed.length} failed` : `${done} deleted`,
        message: failed.length ? 'The rows that failed are still selected.' : undefined,
      });
    },
    [deleteAction, pushToast],
  );

  /* ---------------- Keyboard ----------------
   * j/k move, e edits, / focuses search. Run and Delete are deliberately NOT bound:
   * one dispatches work and the other is irreversible, and neither should be one
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
      if (typing || confirm) return;

      const items = visibleRows;
      const index = items.findIndex((row) => row.id === cursorRef.current);

      if (event.key === 'j' || event.key === 'k') {
        if (items.length === 0) return;
        event.preventDefault();
        const nextIndex = event.key === 'j'
          ? Math.min(items.length - 1, index < 0 ? 0 : index + 1)
          : Math.max(0, index < 0 ? 0 : index - 1);
        const next = items[nextIndex];
        const nextId = next ? next.id : '';
        setCursorId(nextId);
        if (twoPane && nextId) navigateTo(actionViewHref(nextId, urlState));
        const node = nextId ? document.querySelector(`[data-action-row="${CSS.escape(nextId)}"]`) : null;
        node?.scrollIntoView({ block: 'nearest' });
        return;
      }

      if (event.key === 'e') {
        const row = index >= 0 ? items[index] : null;
        if (!row) return;
        event.preventDefault();
        rememberRow(row.id);
        navigateTo(actionEditHref(row.id));
      }
    }
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [confirm, twoPane, urlState, visibleRows]);

  /* ---------------- Empty states (REQ-UI-16: all four read differently) -------- */
  function emptyState(): React.ReactNode {
    if (searching) {
      return (
        <EmptyState
          data-debug-id="action-empty-query"
          icon="search"
          title={`No actions match "${urlState.q}"`}
          description="Search covers the prompt, the schedule, the target's name, and the project, bridge and action IDs."
          action={<Button variant="secondary" onClick={() => { setQueryInput(''); applyUrlState({ ...urlState, q: '' }); }}>Clear search</Button>}
        />
      );
    }
    if (filtersActive) {
      return (
        <EmptyState
          data-debug-id="action-empty-filtered"
          icon="search"
          title="No actions match these filters"
          description="Nothing under this tab matches the filters you have applied."
          action={<Button variant="secondary" onClick={clearFilters}>Clear filters</Button>}
        />
      );
    }
    if (allRows.length > 0) {
      return tab === 'scheduled' ? (
        <EmptyState
          data-debug-id="action-empty-scheduled"
          icon="clock"
          title="Nothing on a schedule"
          description="Every action you have runs only when you run it. Give one a cron schedule and it will appear here."
        />
      ) : (
        <EmptyState
          data-debug-id="action-empty-on-demand"
          icon="zap"
          title="Nothing on demand"
          description="Every action you have runs on its own schedule. An action with no schedule waits here until you run it."
        />
      );
    }
    return (
      <EmptyState
        data-debug-id="action-empty-first-run"
        icon="clock"
        title="No actions yet"
        description="An action is a prompt Ninjy sends to an agent — on a schedule, or whenever you run it."
        action={<Button variant="primary" onClick={() => navigateTo(actionNewHref())}>New action</Button>}
      />
    );
  }

  /* ---------------- Rows ---------------- */
  const openAction = React.useCallback(
    (actionId: string) => {
      if (!actionId) return;
      rememberRow(actionId);
      navigateTo(actionViewHref(actionId, urlState));
    },
    [urlState],
  );

  /** Auto-select the first action in two-pane mode if none is selected */
  React.useEffect(() => {
    if (twoPane && !selectedId && visibleRows.length > 0) {
      openAction(visibleRows[0].id);
    }
  }, [twoPane, selectedId, visibleRows, openAction]);

  const selectable = !searching;

  const listBody = (
    <>
      {listQuery.error ? (
        <Alert tone="danger" title="Couldn't load actions">
          <div className="flex flex-col items-start gap-3">
            <span>{actionErrorText(listQuery.error)}</span>
            <Button size="sm" variant="secondary" onClick={() => void listQuery.refetch()}>Retry</Button>
          </div>
        </Alert>
      ) : listQuery.isLoading ? (
        <div role="status" aria-live="polite" aria-busy="true" data-debug-id="action-list-skeleton">
          <span className="sr-only">Loading actions…</span>
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
          aria-label={searching ? 'Action search results' : 'Actions'}
          data-debug-id={searching ? 'action-search-rows' : 'action-rows'}
          className="flex flex-col"
        >
          {visibleRows.map((row) => (
            <ActionRow
              key={row.id}
              row={row}
              catalog={catalog}
              href={actionViewHref(row.id, urlState)}
              selectable={selectable}
              showCheckbox={selectionMode && selectable}
              selected={selectedIds.includes(row.id)}
              active={row.id === selectedId}
              busy={busyRow === row.id}
              onSelectedChange={(next) =>
                setSelectedIds((prev) => (next ? [...prev, row.id] : prev.filter((id) => id !== row.id)))
              }
              onVerb={(target, verb: ActionVerb) => {
                if (verb === 'edit') {
                  rememberRow(target.id);
                  navigateTo(actionEditHref(target.id));
                  return;
                }
                if (verb === 'run') {
                  void runOne(target);
                  return;
                }
                setConfirm({ ids: [target.id] });
              }}
              onOpen={() => openAction(row.id)}
            />
          ))}
        </ul>
      )}
    </>
  );

  const listSection = (
    <div className={`flex w-full min-w-0 flex-col gap-4 ${twoPane ? 'flex-1 min-h-0 overflow-hidden' : ''}`}>
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
              icon="trash"
              label="Delete"
              variant="danger"
              loading={bulkBusy}
              disabled={selectedIds.length === 0}
              data-debug-id="action-bulk-delete"
              onClick={() => selectedIds.length && setConfirm({ ids: selectedIds })}
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

  const toolbar = (
    <div data-debug-id="action-toolbar">
      <ResourceSearchFilter
        searchQuery={queryInput}
        onSearchChange={setQueryInput}
        searchPlaceholder="Search prompts, schedules and targets…"
        searchDebugId="action-search-input"
        searchClearDebugId="action-search-clear"
        searchRef={searchRef}
        activeTab={searching ? '' : tab}
        onTabChange={(next) => applyUrlState({ ...urlState, tab: next as ActionTab })}
        selectionMode={selectionMode}
        onToggleSelection={() => {
          setSelectionMode((prev) => !prev);
          if (selectionMode) setSelectedIds([]);
        }}
        tabs={ACTION_TABS.map((entry) => ({
          value: entry.value,
          label: entry.label,
          disabled: searching,
          debugId: `action-tab-${entry.value}`,
        }))}
        tabsLabel="Action schedule"
      >
        <FilterBar
          active={filtersActive}
          activeCount={activeFilterCount(urlState)}
          iconTrigger
          disabled={searching}
          disabledTitle="Filters don't apply while you're searching"
          surface={isMobile ? 'sheet' : 'popover'}
          note={
            <>
              Filters narrow the actions already loaded — this list is not paged, so what
              you see is everything.
              {catalogNotes.length ? ` ${catalogNotes.join(' ')}` : ''}
            </>
          }
        >
          <Select
            value={urlState.state}
            onChange={(next) => applyUrlState({ ...urlState, state: next as ActionState | '' })}
            size="sm"
            aria-label="Action state"
            data-debug-id="action-filter-state"
            options={[
              { value: '', label: 'Any state' },
              ...STATE_FILTER_OPTIONS.map((entry) => ({ value: entry.value, label: entry.label })),
            ]}
          />
          <Select
            value={urlState.project}
            onChange={(next) => applyUrlState({ ...urlState, project: next })}
            size="sm"
            aria-label="Project"
            disabled={projectOptions.length === 0}
            data-debug-id="action-filter-project"
            options={[
              { value: '', label: 'Any project' },
              ...projectOptions.map((entry) => ({ value: entry.id, label: entry.label })),
            ]}
          />
          <Select
            value={urlState.bridge}
            onChange={(next) => applyUrlState({ ...urlState, bridge: next })}
            size="sm"
            aria-label="Bridge"
            disabled={bridgeOptions.length === 0}
            data-debug-id="action-filter-bridge"
            options={[
              { value: '', label: 'Any bridge' },
              ...bridgeOptions.map((entry) => ({ value: entry.id, label: entry.label })),
            ]}
          />
        </FilterBar>
      </ResourceSearchFilter>
    </div>
  );

  /* Active filters as removable chips, under the toolbar. */
  const chips: { key: string; label: string; clear: () => void }[] = [];
  if (urlState.state) {
    chips.push({
      key: 'state',
      label: stateLabel(urlState.state),
      clear: () => applyUrlState({ ...urlState, state: '' }),
    });
  }
  if (urlState.project) {
    chips.push({
      key: 'project',
      label: projectLabel(urlState.project, catalog) || urlState.project,
      clear: () => applyUrlState({ ...urlState, project: '' }),
    });
  }
  if (urlState.bridge) {
    chips.push({
      key: 'bridge',
      label: bridgeLabel(urlState.bridge, catalog) || urlState.bridge,
      clear: () => applyUrlState({ ...urlState, bridge: '' }),
    });
  }

  const filterChipRow =
    filtersActive && !searching ? (
      <div className="flex flex-wrap items-center gap-1.5" data-debug-id="action-filter-chips">
        {chips.map((chip) => (
          <button
            key={chip.key}
            type="button"
            onClick={chip.clear}
            data-debug-id={`action-filter-chip-${chip.key}`}
            aria-label={`Remove filter ${chip.label}`}
            className="inline-flex items-center gap-1 rounded-full border border-subtle bg-neutral-soft px-2 py-0.5 text-caption text-muted hover:text-primary focus-visible:shadow-focus focus-visible:outline-none"
          >
            {chip.label}
            <Icon name="close" size="sm" aria-hidden="true" />
          </button>
        ))}
        {/* Gated on `!searching` for Amendment 3's reason: FilterBar's actions slot and
            anything beside it stay live while the bar is disabled, and clearing the
            held filter state while a query is active destroys what is restored when
            the query is cleared. */}
        <Button size="sm" variant="ghost" data-debug-id="action-filter-clear" onClick={clearFilters}>
          Clear filters
        </Button>
      </div>
    ) : null;

  const listColumn = (
    <div className="flex w-full min-w-0 flex-col gap-3 flex-1 min-h-0 h-full overflow-hidden">
      <div className="shrink-0">{toolbar}</div>
      {filterChipRow ? <div className="shrink-0">{filterChipRow}</div> : null}
      <div className="flex min-w-0 flex-col gap-4 flex-1 min-h-0 overflow-hidden">
        {listSection}
      </div>
    </div>
  );

  const confirmTitles = React.useMemo(
    () =>
      (confirm?.ids || []).map((id) => {
        const row = allRows.find((item) => item.id === id);
        return row ? actionTitle(row) : id;
      }),
    [confirm, allRows],
  );

  const overlays = (
    <>
      {confirm ? (
        <Modal
          open
          onOpenChange={(next) => { if (!next) setConfirm(null); }}
          title={confirm.ids.length === 1 ? `Delete "${confirmTitles[0]}"?` : `Delete ${confirm.ids.length} actions?`}
          size="sm"
          data-debug-id="action-delete-modal"
        >
          <ModalBody>
            <Text role="body">{deleteConfirmBody(confirmTitles)}</Text>
          </ModalBody>
          <ModalFooter>
            <Button variant="secondary" data-debug-id="action-delete-cancel" onClick={() => setConfirm(null)}>Cancel</Button>
            <Button
              variant="danger"
              loading={bulkBusy}
              data-debug-id="action-delete-confirm"
              onClick={() => {
                const pending = confirm;
                setConfirm(null);
                if (!pending) return;
                if (pending.ids.length === 1) {
                  const only = pending.ids[0];
                  setBusyRow(only);
                  void deleteAction({ id: only })
                    .unwrap()
                    .then(() => pushToast({ tone: 'success', title: 'Action deleted' }))
                    .catch((err) => pushToast({ tone: 'danger', title: "Couldn't delete this action", message: actionErrorText(err) }))
                    .finally(() => setBusyRow(''));
                  return;
                }
                void runBulkDelete(pending.ids);
              }}
            >
              Delete
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
    'An action is a prompt Ninjy sends to an agent — on a cron schedule, or whenever you run it.';

  return (
    <ResourceContainer
      title="Actions"
      description={headerDescription}
      breadcrumbs={listCrumbs()}
      actions={
        <Button
          variant="primary"
          data-debug-id="action-new-btn"
          leading={<Icon name="plus" size="sm" />}
          onClick={() => navigateTo(actionNewHref())}
        >
          New action
        </Button>
      }
      selectedId={selectedId}
      detailTitle="Action Details"
      listDebugId="action-list-page"
      detailDebugId="action-detail-pane"
      emptyDetailText="Select an action to see it here."
      list={listColumn}
      detail={
        selectedId ? (
          <ActionDetailPane
            actionId={selectedId}
            onAfterDelete={() => navigateTo(actionListHref(urlState))}
            onBack={() => navigateTo(actionListHref(urlState))}
          />
        ) : null
      }
    >
      {overlays}
    </ResourceContainer>
  );
}

/**
 * The right-hand pane of the two-pane layout.
 */
function ActionDetailPane({
  actionId,
  onAfterDelete,
  onBack,
}: {
  actionId: string;
  onAfterDelete: () => void;
  onBack?: () => void;
}) {
  const { query, record, busy, actionError, runNotice, runVerb } = useActionDetail(actionId, (verb) => {
    if (verb === 'delete') onAfterDelete();
  });
  const paneRef = React.useRef<HTMLDivElement | null>(null);
  const wide = usePaneIsWide(paneRef);

  if (query.isLoading) return <ActionDetailPaneSkeleton />;
  if (query.error || !record) {
    return (
      <EmptyState
        data-debug-id="action-pane-missing"
        icon="search"
        title="That action doesn't exist"
        description={query.error ? actionErrorText(query.error) : undefined}
        action={<Button variant="secondary" onClick={() => navigateTo(actionListHref())}>Back to Actions</Button>}
      />
    );
  }

  return (
    <div ref={paneRef} className="min-w-0 flex flex-col min-h-0 h-full overflow-hidden">
      <div className="mb-3 shrink-0">
        <ActionDetailHeader
          record={record}
          busy={busy}
          onVerb={(verb) => void runVerb(verb)}
          onBack={onBack}
        />
      </div>
      <div className="flex-1 min-h-0 overflow-y-auto">
        <ActionDetailBody record={record} actionError={actionError} runNotice={runNotice} wide={wide} />
      </div>
    </div>
  );
}

/** Re-exported for the shell's route table. */
export { EMPTY_LIST_URL_STATE, isScheduled };
