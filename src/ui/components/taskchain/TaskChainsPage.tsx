import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Badge, ResourceContainer, ResourceSearchFilter, useViewport } from '@ui';
import Icon from '../Icon';
import { buildRouteHash } from '../../utils/appLocation';
import ProjectLaunchModal from '../projects/ProjectLaunchModal';
import CreateChainModal from './CreateChainModal';
import {
  useFetchTaskChainGroupsQuery,
  useFetchTaskChainProjectPageQuery,
  useLazyFetchTaskChainProjectPageQuery,
  useUpdateTaskChainMutation,
  type ChainListItem,
  type ChainProjectGroup,
} from '../../api/endpoints/tasks';
import { useListProjectsQuery, type Project } from '../../api/endpoints/projects';
import { useArchivedProjectIds } from '../projects/projectModel';
import { useIsMobile } from '../shell/responsive';
import { TaskChainOverview } from './TaskChainOverview';
import { useSelector } from 'react-redux';
import { selectIsVaultUnlocked, getActiveVaultKey } from '../../store/vaultSlice';
import { decryptProjectList } from '../../utils/vaultProjects';
import { decryptChainList } from '../../utils/vaultChains';
import { isVaultArmored } from '../../utils/vaultContent';
import { VaultText } from '../vault/VaultText';

interface TaskChainsPageProps {
  chainId?: string;
  // Optional deep-link target task (from '/chains/:chainId/tasks/:taskId'); the
  // chain view auto-opens + scrolls to it. Undefined for the plain chain route.
  taskId?: string;
  isMobile?: boolean;
}

function shellHash(path: string): string {
  return buildRouteHash(path, '');
}

// Per-project preview page size for the "Load more" pager. The default view
// previews up to 5 chains per project (from the grouped endpoint); each Load more
// then pulls a page of this size via the per-project cursor endpoint.
const PAGE_SIZE = 20;

// The four status filters, as tabs in the list pane's filter row.
const STATUS_TABS: { value: 'active' | 'completed' | 'archived' | 'all'; label: string }[] = [
  { value: 'active', label: 'Active' },
  { value: 'completed', label: 'Completed' },
  { value: 'archived', label: 'Archived' },
  { value: 'all', label: 'All' },
];

function statusBadgeClass(status: string): string {
  switch (String(status || '').toLowerCase()) {
    case 'active':
      return 'bg-accent/10 text-accent border-accent/20';
    case 'completed':
      return 'bg-success-soft text-success border-success/20';
    case 'archived':
      return 'bg-warning-soft text-warning border-warning/30';
    case 'cancelled':
      return 'bg-neutral-soft text-muted border-subtle';
    default:
      return 'bg-neutral-soft text-muted border-subtle';
  }
}

function formatUpdatedAt(value: string): string {
  if (!value) return '';
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return value;
  return d.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

// One chain row: status badge + title + updated_at. Clicking the row SELECTS the
// chain into the detail pane (REQ-TCUI-2) rather than navigating away. The
// coordinator's conversation stays reachable as an icon button in the action
// cluster (instance-id route from TC-ROUTING; the id is already in the row, so no
// extra fetch). Rows without a coordinator simply omit that button.
function ChainRow({
  chain,
  active,
  onSelect,
  onArchive,
  onRestore,
}: {
  chain: ChainListItem;
  active: boolean;
  onSelect?: (chainId: string) => void;
  onArchive?: (chainId: string) => void;
  onRestore?: (chainId: string) => void;
}) {
  const coordinator = chain.coordinatorAgentInstanceId;
  const isMobile = useIsMobile();
  const isArchived = chain.status === 'archived';

  // Title on its own line, meta beneath it — the same shape `ResourceEntryCard` gives
  // `IssueRow`. The old single-line row was built for a full-width page; inside
  // ResourceContainer's <=420px list column its content no longer fits, and the title (the
  // only `flex-1 min-w-0` item) was the one that collapsed — to literally 0px, so `truncate`
  // clipped it away entirely and rows rendered with an empty gap where the name should be.
  const inner = (
    <>
      <span className="block min-w-0 truncate text-sm text-primary">
        <VaultText value={chain.title} fallback={chain.chainId} />
      </span>
      <span className="flex min-w-0 flex-wrap items-center gap-2">
        <span
          data-debug-id={`task-chains-row-status-${chain.chainId}`}
          className={`shrink-0 rounded-md border px-2 py-0.5 text-caption font-semibold capitalize ${statusBadgeClass(chain.status)}`}
        >
          {chain.status || 'unknown'}
        </span>
        {chain.kind === 'workflow' && (
          <span className="shrink-0 rounded-md bg-accent-soft px-1.5 py-0.5 text-caption font-mono text-accent">
            workflow
          </span>
        )}
        <span
          data-debug-id={`task-chains-row-task-count-${chain.chainId}`}
          className="shrink-0 rounded-md border border-subtle bg-surface-raised px-1.5 py-0.5 text-caption text-muted"
          title={`${chain.taskCount} ${chain.taskCount === 1 ? 'task' : 'tasks'}`}
        >
          {chain.taskCount}
        </span>
        {chain.updatedAt ? (
          <span className="shrink-0 text-caption text-faint">{formatUpdatedAt(chain.updatedAt)}</span>
        ) : null}
      </span>
    </>
  );

  const href = isMobile
    ? shellHash(`/conversations/${encodeURIComponent(coordinator)}`)
    : shellHash(`/conversations/${encodeURIComponent(coordinator)}?panel=tasks`);

  return (
    <div
      data-debug-id={`task-chains-row-${chain.chainId}`}
      className={[
        'flex items-start justify-between gap-2 rounded-xl border px-3 py-2.5 transition-colors',
        active
          ? 'border-accent/40 bg-accent/10'
          : 'border-subtle bg-surface hover:bg-surface-raised',
      ].join(' ')}
    >
      {/* The flex row lives on an inner <span>, NOT on the <button>. Firefox wraps a
          button's children in an anonymous box, so `display:flex` on the button itself does
          not make them flex items: the title's `flex-1` collapsed to zero width and the
          title rendered invisibly (present in the DOM, painted at 0px) while the count and
          date overflowed and were clipped. Keeping the real <button> preserves the
          semantics and keyboard behaviour; the inner span does the layout. */}
      <button
        type="button"
        data-debug-id={`task-chains-row-select-${chain.chainId}`}
        onClick={() => onSelect?.(chain.chainId)}
        aria-current={active ? 'true' : undefined}
        title="Open this task chain"
        className="min-w-0 flex-1 text-left"
      >
        <span className={`flex w-full min-w-0 flex-col justify-center gap-1.5 overflow-hidden ${isMobile ? 'min-h-11' : 'min-h-[32px]'}`}>
          {inner}
        </span>
      </button>

      <div className="flex shrink-0 items-center gap-2 pl-2" data-debug-id={`task-chains-row-actions-${chain.chainId}`}>
        {coordinator ? (
          <a
            href={href}
            data-debug-id={`task-chains-row-coordinator-link-${chain.chainId}`}
            title="Open coordinator conversation"
            aria-label={`Open coordinator conversation (${coordinator})`}
            onClick={(e) => {
              e.stopPropagation();
              if (isMobile) {
                window.dispatchEvent(new CustomEvent('heimdall:close-sidebar'));
              }
            }}
            className={`inline-flex shrink-0 items-center justify-center border ${isMobile ? 'h-11 w-11 rounded-full' : 'h-[32px] w-[32px] min-h-[32px] rounded-lg'} border-subtle bg-surface text-muted transition-colors hover:border-strong hover:bg-surface-raised hover:text-primary`}
          >
            <Icon name="chat" size={isMobile ? 18 : 14} />
          </a>
        ) : null}
        {isArchived ? (
          <button
            type="button"
            data-debug-id={`task-chains-restore-btn-${chain.chainId}`}
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              onRestore?.(chain.chainId);
            }}
            title="Restore chain to active"
            aria-label="Restore chain to active"
            className={`rounded-lg border border-subtle bg-surface font-semibold text-primary transition-colors hover:border-strong hover:bg-surface-raised ${isMobile ? 'min-h-11 px-3.5 text-sm' : 'min-h-[32px] px-2.5 py-1 text-xs'}`}
          >
            Restore
          </button>
        ) : (
          <button
            type="button"
            data-debug-id={`task-chains-archive-btn-${chain.chainId}`}
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              onArchive?.(chain.chainId);
            }}
            title="Archive chain"
            aria-label="Archive chain"
            className={`rounded-lg border border-subtle bg-surface text-muted transition-colors hover:border-warning/40 hover:bg-warning-soft hover:text-warning ${isMobile ? 'min-h-11 px-3.5 text-sm' : 'min-h-[32px] px-2.5 py-1 text-xs'}`}
          >
            Archive chain
          </button>
        )}
      </div>
    </div>
  );
}

// A collapsible per-project card that previews chains and pages the rest in via
// the per-project cursor endpoint. `initial*` seed the first page (from either the
// grouped endpoint or the filtered project fetch); further pages accumulate in
// local state. Remounts (keyed by projectId) reset state on filter change.
function ChainGroupCard({
  projectId,
  projectName,
  initialChains,
  initialHasMore,
  initialNextCursor,
  totalCount,
  onlyWithTasks,
  filterStatus,
  filterKind = 'all',
  matchesSearch,
  activeChainId,
  onSelectChain,
  collapsed,
  onToggle,
  onLaunchProject,
  onArchiveChain,
  onRestoreChain,
}: {
  projectId: string;
  projectName: string;
  initialChains: ChainListItem[];
  initialHasMore: boolean;
  initialNextCursor: string;
  totalCount: number;
  onlyWithTasks: boolean;
  filterStatus: 'active' | 'completed' | 'archived' | 'all';
  filterKind?: 'all' | 'ticket' | 'workflow';
  // Applied here as well as in the page's `groups` memo, so rows pulled in by
  // "Load more" are filtered by the search box too.
  matchesSearch: (chain: ChainListItem) => boolean;
  activeChainId: string;
  onSelectChain?: (chainId: string) => void;
  collapsed: boolean;
  onToggle: () => void;
  onLaunchProject?: (project: { projectId: string; name: string }) => void;
  onArchiveChain?: (chainId: string) => void;
  onRestoreChain?: (chainId: string) => void;
}) {
  const isMobile = useIsMobile();
  const [extra, setExtra] = useState<ChainListItem[]>([]);
  const [cursor, setCursor] = useState<string>(initialNextCursor);
  const [hasMore, setHasMore] = useState<boolean>(initialHasMore);
  const [loadMorePage, { isFetching }] = useLazyFetchTaskChainProjectPageQuery();

  // Reset accumulated pages when the seed changes (e.g. a background refetch of
  // the grouped list, or the filtered project's first page reloading).
  useEffect(() => {
    setExtra([]);
    setCursor(initialNextCursor);
    setHasMore(initialHasMore);
  }, [projectId, initialNextCursor, initialHasMore]);

  const rawChains = useMemo(() => [...initialChains, ...extra], [initialChains, extra]);

  const chains = useMemo(() => {
    return rawChains.filter((c) => {
      if (!matchesSearch(c)) return false;
      if (filterStatus === 'active') return c.status === 'active';
      if (filterStatus === 'completed') return c.status === 'completed';
      if (filterStatus === 'archived') return c.status === 'archived';
      if (filterKind === 'ticket' && c.kind === 'workflow') return false;
      if (filterKind === 'workflow' && c.kind !== 'workflow') return false;
      return true;
    });
  }, [rawChains, filterStatus, filterKind, matchesSearch]);

  const onLoadMore = async () => {
    try {
      const res = await loadMorePage({
        projectId,
        limit: PAGE_SIZE,
        cursor,
        hasTasks: onlyWithTasks,
        includeArchived: filterStatus === 'archived' || filterStatus === 'all',
      }).unwrap();
      setExtra((prev) => [...prev, ...(res.chains || [])]);
      setCursor(res.nextCursor || '');
      setHasMore(Boolean(res.hasMore));
    } catch {
      // Leave the button in place so the user can retry; RTK surfaces the error
      // state on the trigger if needed.
      setHasMore(true);
    }
  };

  const displayName = projectName || (projectId ? projectId : 'Unassigned');
  const hasProject = Boolean(projectId && projectId !== '__unassigned__');

  return (
    <div
      data-debug-id={`task-chains-project-group-${projectId || 'unassigned'}`}
      className="overflow-hidden rounded-2xl border border-subtle bg-surface"
    >
      <div className="flex items-center justify-between gap-2 border-b border-subtle bg-surface-raised px-4 py-3 transition-colors hover:bg-neutral-soft">
        <button
          type="button"
          data-debug-id={`task-chains-project-toggle-${projectId || 'unassigned'}`}
          onClick={onToggle}
          className="flex min-w-0 flex-1 items-center gap-3 text-left"
        >
          <span className="shrink-0 text-muted">
            <Icon name={collapsed ? 'chevron-right' : 'chevron-down'} size={14} />
          </span>
          <div className="flex min-w-0 items-center gap-2">
            <Icon name="folder" size={15} className="shrink-0 text-accent" />
            <span className="truncate text-sm font-semibold text-primary"><VaultText value={displayName} fallback="Unassigned" /></span>
          </div>
        </button>
        <div className="flex shrink-0 items-center gap-2">
          {hasProject && (
            <button
              type="button"
              data-debug-id={`task-chains-project-launch-btn-${projectId}`}
              onClick={(e) => {
                e.stopPropagation();
                onLaunchProject?.({ projectId, name: projectName || displayName });
              }}
              title={`Launch agent for ${displayName}`}
              aria-label={`Launch agent for ${displayName}`}
              className={`flex items-center justify-center border border-subtle bg-neutral-soft text-muted transition-colors hover:border-strong hover:bg-surface-raised hover:text-primary ${isMobile ? 'h-11 w-11 rounded-full' : 'h-6 w-6 rounded-lg'}`}
            >
              <Icon name="plus" size={isMobile ? 18 : 13} />
            </button>
          )}
          <span
            data-debug-id={`task-chains-project-count-${projectId || 'unassigned'}`}
            className="rounded-md border border-subtle bg-surface px-2 py-0.5 text-xs text-muted"
          >
            {totalCount} {totalCount === 1 ? 'chain' : 'chains'}
          </span>
        </div>
      </div>

      {!collapsed && (
        <div className="space-y-2 p-4">
          {chains.length === 0 ? (
            <p className="py-2 text-xs italic text-faint">No task chains in this project.</p>
          ) : (
            chains.map((chain) => (
              <ChainRow
                key={chain.chainId}
                chain={chain}
                active={activeChainId === chain.chainId}
                onSelect={onSelectChain}
                onArchive={onArchiveChain}
                onRestore={onRestoreChain}
              />
            ))
          )}
          {hasMore && (
            <button
              type="button"
              data-debug-id={`task-chains-load-more-${projectId || 'unassigned'}`}
              onClick={() => void onLoadMore()}
              disabled={isFetching}
              className={`mt-1 w-full rounded-xl border border-subtle bg-surface-raised px-3 font-semibold ${isMobile ? 'min-h-11 text-sm' : 'py-2 text-xs'} text-muted transition-colors hover:bg-neutral-soft hover:text-primary disabled:opacity-50`}
            >
              {isFetching ? 'Loading…' : 'Load more'}
            </button>
          )}
        </div>
      )}
    </div>
  );
}

export const TaskChainsPage: React.FC<TaskChainsPageProps> = ({ chainId: initialChainId, taskId: focusTaskId, isMobile }) => {
  // Read the viewport the same way ResourceContainer does, so the page and the
  // container can never disagree about where the 2-pane boundary is.
  const viewport = useViewport();
  const twoPane = viewport === 'desktop';
  const isMobileViewport = isMobile ?? viewport === 'mobile';

  const [selectedChainId, setSelectedChainId] = useState<string>(initialChainId || '');
  const [filterProjectId, setFilterProjectId] = useState<string>('');
  const [filterStatus, setFilterStatus] = useState<'active' | 'completed' | 'archived' | 'all'>('active');
  const [filterKind, setFilterKind] = useState<'all' | 'ticket' | 'workflow'>('all');
  const [showCreateChainModal, setShowCreateChainModal] = useState(false);
  const [searchQuery, setSearchQuery] = useState<string>('');
  // Roughly half of real chains carry no tasks yet and have nothing to show, so
  // the list hides them by default; the toggle brings them back.
  const [onlyWithTasks, setOnlyWithTasks] = useState<boolean>(true);
  const [showArchivedProjects, setShowArchivedProjects] = useState<boolean>(false);
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const [launchModalProject, setLaunchModalProject] = useState<{ projectId: string; name: string } | null>(null);

  useEffect(() => {
    setSelectedChainId(initialChainId || '');
  }, [initialChainId]);

  const shouldIncludeArchived = showArchivedProjects || filterStatus === 'archived' || filterStatus === 'all';

  // The list queries no longer skip when a chain is selected: on desktop the list
  // and the detail are shown TOGETHER, so the list must stay loaded. Only the
  // filterProjectId split (grouped endpoint vs per-project endpoint) remains.
  const groupsQuery = useFetchTaskChainGroupsQuery(
    { hasTasks: onlyWithTasks, includeArchived: shouldIncludeArchived },
    { skip: Boolean(filterProjectId) },
  );
  const projectPageQuery = useFetchTaskChainProjectPageQuery(
    { projectId: filterProjectId, limit: PAGE_SIZE, hasTasks: onlyWithTasks, includeArchived: shouldIncludeArchived },
    { skip: !filterProjectId },
  );
  const projectsQuery = useListProjectsQuery();
  const archivedProjectIds = useArchivedProjectIds();

  const [updateTaskChain] = useUpdateTaskChainMutation();

  const handleArchiveChain = async (chainId: string) => {
    try {
      await updateTaskChain({ chainId, status: 'archived' }).unwrap();
    } catch (err: any) {
      console.error('Failed to archive task chain:', err);
    }
  };

  const handleRestoreChain = async (chainId: string) => {
    try {
      await updateTaskChain({ chainId, status: 'active' }).unwrap();
    } catch (err: any) {
      console.error('Failed to restore task chain:', err);
    }
  };

  const projects: Project[] = useMemo(() => {
    const list: Project[] = projectsQuery.data?.projects || [];
    if (showArchivedProjects) return list;
    return list.filter((p) => !archivedProjectIds.has(p.project_id));
  }, [projectsQuery.data, showArchivedProjects, archivedProjectIds]);

  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const [decryptedProjects, setDecryptedProjects] = useState<Project[]>(projects);

  useEffect(() => {
    let active = true;
    const activeKey = getActiveVaultKey();
    if (!isUnlocked || !activeKey) {
      setDecryptedProjects(
        projects.map((p) => ({
          ...p,
          name: p.name ? p.name.replace(/vault:v1:[A-Za-z0-9+/=_-]+/g, '[🔒 Encrypted]') : p.name,
        }))
      );
      return;
    }
    decryptProjectList(projects, activeKey).then((res) => {
      if (active) setDecryptedProjects(res);
    });
    return () => {
      active = false;
    };
  }, [projects, isUnlocked]);

  const rawGroups: ChainProjectGroup[] = useMemo(() => {
    const raw = filterProjectId
      ? (projectPageQuery.data ? [projectPageQuery.data] : [])
      : (groupsQuery.data?.groups || []);
    if (!showArchivedProjects) {
      return raw.filter((g) => !g.projectId || !archivedProjectIds.has(g.projectId));
    }
    return raw;
  }, [filterProjectId, projectPageQuery.data, groupsQuery.data, showArchivedProjects, archivedProjectIds]);

  // Chain titles are vault-encrypted, so the search box must match the DECRYPTED
  // title — matching `chain.title` directly would be matching ciphertext. Titles
  // are decrypted once into a chainId -> plaintext map; armored titles that cannot
  // be read (vault locked) are simply absent, so those chains match on chainId only.
  const allChains = useMemo(() => rawGroups.flatMap((g) => g.chains), [rawGroups]);
  const [titleByChainId, setTitleByChainId] = useState<Record<string, string>>({});

  useEffect(() => {
    let active = true;
    const activeKey = getActiveVaultKey();
    if (!isUnlocked || !activeKey) {
      const plain: Record<string, string> = {};
      for (const chain of allChains) {
        const raw = String(chain.title || '');
        if (raw && !isVaultArmored(raw)) plain[chain.chainId] = raw;
      }
      setTitleByChainId(plain);
      return;
    }
    decryptChainList(allChains, activeKey)
      .then((list) => {
        if (!active) return;
        const next: Record<string, string> = {};
        for (const chain of list) {
          const title = String(chain.title || '');
          if (title && !isVaultArmored(title)) next[chain.chainId] = title;
        }
        setTitleByChainId(next);
      })
      .catch(() => {
        // Search degrades to chainId matching rather than breaking the list.
        if (active) setTitleByChainId({});
      });
    return () => {
      active = false;
    };
  }, [allChains, isUnlocked]);

  const normalizedQuery = searchQuery.trim().toLowerCase();
  const matchesSearch = useCallback(
    (chain: ChainListItem) => {
      if (!normalizedQuery) return true;
      if (chain.chainId.toLowerCase().includes(normalizedQuery)) return true;
      const title = titleByChainId[chain.chainId];
      return Boolean(title) && title.toLowerCase().includes(normalizedQuery);
    },
    [normalizedQuery, titleByChainId],
  );

  const groups: ChainProjectGroup[] = useMemo(() => {
    return rawGroups
      .map((g) => {
        const matching = g.chains.filter((c) => {
          if (!matchesSearch(c)) return false;
          if (filterStatus === 'active') return c.status === 'active';
          if (filterStatus === 'completed') return c.status === 'completed';
          if (filterStatus === 'archived') return c.status === 'archived';
          if (filterKind === 'ticket' && c.kind === 'workflow') return false;
          if (filterKind === 'workflow' && c.kind !== 'workflow') return false;
          return true;
        });
        return {
          ...g,
          chains: matching,
          chainTotal: matching.length,
        };
      })
      .filter((g) => Boolean(filterProjectId) || g.chains.length > 0);
  }, [rawGroups, filterStatus, filterKind, filterProjectId, matchesSearch]);

  const totalChains = useMemo(() => groups.reduce((sum, g) => sum + (g.chainTotal || g.chains.length), 0), [groups]);
  const isLoading = filterProjectId ? projectPageQuery.isLoading : groupsQuery.isLoading;
  const error = filterProjectId ? projectPageQuery.error : groupsQuery.error;

  // Desktop shows both panes, so an empty detail pane is wasted space: preselect
  // the first visible chain (mirrors IssueListPage). State only — no route push,
  // so '/chains' stays '/chains' until the user actually picks a row.
  const firstChainId = groups[0]?.chains[0]?.chainId || '';
  useEffect(() => {
    if (twoPane && !selectedChainId && firstChainId) {
      setSelectedChainId(firstChainId);
    }
  }, [twoPane, selectedChainId, firstChainId]);

  const toggleCollapse = (projectId: string) => {
    const key = projectId || '__unassigned__';
    setCollapsed((prev) => ({ ...prev, [key]: !prev[key] }));
  };

  // Selecting a row syncs the hash route so deep links and the browser back button
  // keep working. AppShell renders TaskChainsPage from the same position for both
  // '/chains' and '/chains/*', so this updates the page in place rather than
  // remounting it — the filters, collapse state and loaded pages all survive.
  const handleSelectChain = (chainId: string) => {
    setSelectedChainId(chainId);
    window.location.hash = shellHash(`/chains/${encodeURIComponent(chainId)}`);
  };

  const handleCloseDetail = () => {
    setSelectedChainId('');
    window.location.hash = shellHash('/chains');
  };

  const listColumn = (
    <div data-debug-id="task-chains-page" className="flex h-full min-w-0 flex-col overflow-hidden text-left">
      <ResourceSearchFilter
        searchQuery={searchQuery}
        onSearchChange={setSearchQuery}
        searchPlaceholder="Search chains…"
        searchDebugId="task-chains-search-input"
        activeTab={filterStatus}
        onTabChange={(tab) => setFilterStatus(tab as 'active' | 'completed' | 'archived' | 'all')}
        // The status <Select> this replaces was named by a <label htmlFor>; the tabs list needs
        // an explicit label or it falls back to ResourceSearchFilter's generic "Filter tabs".
        tabsLabel="Filter chains by status"
        tabs={STATUS_TABS.map((tab) => ({
          value: tab.value,
          label: tab.label,
          debugId: `task-chains-filter-status-${tab.value}`,
        }))}
        filters={[
          {
            value: filterProjectId,
            onChange: setFilterProjectId,
            options: [
              { value: '', label: 'All projects' },
              ...decryptedProjects.map((p) => ({
                value: p.project_id,
                label: p.name || p.project_id,
              })),
            ],
            ariaLabel: 'Filter by project',
            debugId: 'task-chains-project-filter',
          },
          {
            value: filterKind,
            onChange: (val) => setFilterKind(val as 'all' | 'ticket' | 'workflow'),
            options: [
              { value: 'all', label: 'All kinds' },
              { value: 'ticket', label: 'Tickets' },
              { value: 'workflow', label: 'Workflows' },
            ],
            ariaLabel: 'Filter by kind',
            debugId: 'task-chains-kind-filter',
          },
        ]}
        showFooterCounter
        itemsCount={totalChains}
        itemsLabel="chain"
        counterDebugId="task-chains-footer-count"
      >
        <label
          htmlFor="task-chains-has-tasks-filter"
          className={`inline-flex cursor-pointer items-center gap-2 rounded-xl border border-subtle bg-surface px-3 py-1.5 text-sm text-muted ${isMobileViewport ? 'min-h-11' : 'min-h-[32px]'}`}
        >
          <input
            id="task-chains-has-tasks-filter"
            data-debug-id="task-chains-has-tasks-filter"
            type="checkbox"
            checked={onlyWithTasks}
            onChange={(e) => setOnlyWithTasks(e.target.checked)}
            className="h-4 w-4 accent-accent"
          />
          Only chains with tasks
        </label>

        <label
          htmlFor="task-chains-include-archived-filter"
          className={`inline-flex cursor-pointer items-center gap-2 rounded-xl border border-subtle bg-surface px-3 py-1.5 text-sm text-muted ${isMobileViewport ? 'min-h-11' : 'min-h-[32px]'}`}
        >
          <input
            id="task-chains-include-archived-filter"
            data-debug-id="task-chains-include-archived-filter"
            type="checkbox"
            checked={showArchivedProjects}
            onChange={(e) => setShowArchivedProjects(e.target.checked)}
            className="h-4 w-4 accent-accent"
          />
          Include archived projects
        </label>
      </ResourceSearchFilter>

      <div className="min-h-0 flex-1 overflow-y-auto p-4">
        {isLoading && (
          <div data-debug-id="task-chains-loading" className="rounded-2xl border border-subtle bg-surface p-6 text-sm text-muted">
            Loading task chains…
          </div>
        )}

        {!isLoading && error && (
          <div data-debug-id="task-chains-error" className="rounded-xl border border-danger/30 bg-danger-soft p-5 text-sm text-danger">
            Failed to load task chains: {String((error as any)?.error || (error as any)?.message || error)}
          </div>
        )}

        {!isLoading && !error && groups.length === 0 && (
          <div
            data-debug-id="task-chains-empty-state"
            className="flex flex-col items-center justify-center rounded-2xl border border-dashed border-subtle bg-surface/50 p-12 text-center"
          >
            <div className="mb-4 grid h-12 w-12 place-items-center rounded-2xl bg-neutral-soft text-muted">
              <Icon name="tasks" size={24} />
            </div>
            <h3 className="text-base font-semibold text-primary">No Task Chains</h3>
            <p className="mt-1 max-w-md text-xs leading-relaxed text-muted">
              {normalizedQuery
                ? 'No task chains match your search.'
                : filterProjectId
                  ? 'This project has no task chains matching filter.'
                  : 'Task chains appear here once a coordinator starts a multi-agent workflow.'}
            </p>
          </div>
        )}

        {!isLoading && !error && groups.length > 0 && (
          <div data-debug-id="task-chains-project-groups" className="space-y-6">
            {groups.map((group) => {
              const key = group.projectId || '__unassigned__';
              return (
                <ChainGroupCard
                  key={key}
                  projectId={group.projectId}
                  projectName={group.projectName}
                  initialChains={group.chains}
                  initialHasMore={group.hasMore}
                  initialNextCursor={group.nextCursor}
                  totalCount={group.chainTotal || group.chains.length}
                  onlyWithTasks={onlyWithTasks}
                  filterStatus={filterStatus}
                  filterKind={filterKind}
                  matchesSearch={matchesSearch}
                  activeChainId={selectedChainId}
                  onSelectChain={handleSelectChain}
                  collapsed={Boolean(collapsed[key])}
                  onToggle={() => toggleCollapse(group.projectId)}
                  onLaunchProject={setLaunchModalProject}
                  onArchiveChain={handleArchiveChain}
                  onRestoreChain={handleRestoreChain}
                />
              );
            })}
          </div>
        )}
      </div>
    </div>
  );

  return (
    <ResourceContainer
      title={
        <div className="flex items-center justify-between w-full pr-2">
          <span className="inline-flex items-center gap-2.5">
            Task Chains
            <Badge data-debug-id="task-chains-total-count" tone="info">
              {totalChains} {totalChains === 1 ? 'chain' : 'chains'}
            </Badge>
          </span>
          <button
            type="button"
            data-debug-id="task-chains-new-chain-btn"
            onClick={() => setShowCreateChainModal(true)}
            className="inline-flex items-center gap-1.5 rounded-lg bg-accent px-3 py-1 text-xs font-semibold text-accent-fg hover:opacity-90 transition-opacity"
          >
            <span>+</span>
            <span>New Chain</span>
          </button>
        </div>
      }
      description="Multi-agent workflows grouped by project. Select a chain to follow its tasks, dependencies, and reviews."
      breadcrumbs={[{ label: 'Task Chains' }]}
      selectedId={selectedChainId}
      detailTitle="Task Chain"
      listDebugId="task-chains-list-column"
      detailDebugId="task-chains-detail-pane"
      emptyDetailText="Select a task chain to see it here."
      list={listColumn}
      detail={
        selectedChainId ? (
          <TaskChainOverview
            embedded
            chainId={selectedChainId}
            focusTaskId={focusTaskId}
            isMobile={isMobile}
            onClose={handleCloseDetail}
          />
        ) : null
      }
    >
      <ProjectLaunchModal
        isOpen={Boolean(launchModalProject)}
        project={launchModalProject}
        onClose={() => setLaunchModalProject(null)}
        onLaunched={(instanceId) => {
          setLaunchModalProject(null);
          window.location.hash = buildRouteHash('/conversations/' + encodeURIComponent(instanceId), '');
        }}
      />
      <CreateChainModal
        isOpen={showCreateChainModal}
        onClose={() => setShowCreateChainModal(false)}
        projects={decryptedProjects}
        defaultProjectId={filterProjectId}
        onCreated={(newChainId) => {
          setShowCreateChainModal(false);
          handleSelectChain(newChainId);
        }}
      />
    </ResourceContainer>
  );
};

export default TaskChainsPage;
