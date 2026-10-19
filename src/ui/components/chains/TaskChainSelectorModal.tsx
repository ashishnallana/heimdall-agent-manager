import React, { useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { useFetchTaskChainGroupsQuery, type ChainProjectGroup } from '../../api/endpoints/tasks';
import {
  selectSearchChains,
  setBulkChainTitles,
  type SearchItem,
} from '../../store/searchTitleSlice';
import {
  selectIsVaultUnlocked,
  getActiveVaultKey,
} from '../../store/vaultSlice';
import { isVaultArmored } from '../../utils/vaultContent';
import { batchDecryptTitles, type RawSearchItemInput } from '../../utils/vaultSearch';
import { VaultText } from '../vault/VaultText';
import { Icon, StatusDot } from '../ui/primitives';
import { useDialogA11y } from '../ui/composites/useDialogA11y';
import { taskChainRoute, chainStatusDot } from '../ui/patterns/commandPaletteLogic';
import { buildRouteHash } from '../../utils/appLocation';
import { resolveChainConversationAgent } from '../../utils/chainConversation';
import {
  searchTaskChainsEncrypted,
  taskChainSearchErrorMessage,
} from '../../utils/taskChainSearch';
import { useAuthUser } from '../auth/AuthUserContext';
import {
  INITIAL_VISIBLE_COUNT,
  type ChainSelectorItem,
  prepareChainSelectorItems,
  filterTaskChains,
  findInitialActiveIndex,
  navigateIndex,
  selectionDirectionForEvent,
  groupChainsByProject,
} from './taskChainSelectorLogic';

export {
  INITIAL_VISIBLE_COUNT,
  type ChainSelectorItem,
  prepareChainSelectorItems,
  filterTaskChains,
  findInitialActiveIndex,
  navigateIndex,
  selectionDirectionForEvent,
  groupChainsByProject,
};

export interface TaskChainSelectorModalProps {
  open: boolean;
  onClose: () => void;
  currentChainId?: string;
  projectId?: string;
  onNavigate?: (route: string) => void;
  /**
   * When provided, picking a chain calls this INSTEAD of navigating (e.g. a
   * Main pane swaps its own agent to the chain's coordinator in place).
   */
  onSelectChain?: (chain: { chainId: string; coordinatorAgentInstanceId?: string }) => void;
  chainGroups?: ChainProjectGroup[];
}

export function TaskChainSelectorModal({
  open,
  onClose,
  currentChainId,
  projectId,
  onNavigate,
  onSelectChain,
  chainGroups: chainGroupsProp,
}: TaskChainSelectorModalProps) {
  const [query, setQuery] = useState('');
  const [activeIndex, setActiveIndex] = useState(0);
  const [visibleCount, setVisibleCount] = useState(INITIAL_VISIBLE_COUNT);
  const [remoteChains, setRemoteChains] = useState<ChainSelectorItem[] | null>(null);
  const [remoteSearchState, setRemoteSearchState] = useState<'idle' | 'searching' | 'stale' | 'error'>('idle');
  const [remoteSearchError, setRemoteSearchError] = useState('');

  const inputRef = useRef<HTMLInputElement | null>(null);
  const listRef = useRef<HTMLDivElement | null>(null);
  const panelRef = useRef<HTMLDivElement | null>(null);

  useDialogA11y(open, onClose, panelRef);

  const dispatch = useDispatch();
  const authUser = useAuthUser();

  const isVaultUnlocked = useSelector((state: any) => {
    try {
      return selectIsVaultUnlocked(state);
    } catch {
      return Boolean(state?.vault?.isUnlocked);
    }
  });

  const activeVaultKey = useMemo(() => {
    if (isVaultUnlocked) {
      return getActiveVaultKey();
    }
    return null;
  }, [isVaultUnlocked]);

  const searchChains = useSelector((state: any) => {
    try {
      return (selectSearchChains(state) as Record<string, SearchItem>) || {};
    } catch {
      return (state?.searchTitle?.chains as Record<string, SearchItem> | undefined) || {};
    }
  });

  const { data: groupsData, isLoading } = useFetchTaskChainGroupsQuery(
    { includeArchived: true },
    { skip: !open },
  );

  const resolvedGroups = useMemo(() => {
    return chainGroupsProp ?? groupsData?.groups ?? [];
  }, [chainGroupsProp, groupsData]);

  // Background batch decryption of armored titles
  useEffect(() => {
    if (!activeVaultKey || !open) return;
    const toDecrypt: RawSearchItemInput[] = [];

    for (const g of resolvedGroups) {
      for (const ch of g.chains) {
        const id = ch.chainId;
        const rawTitle = ch.title || '';
        const searchItem = searchChains[id];
        const isArmored = isVaultArmored(rawTitle);
        const needsDecryption =
          isArmored &&
          (!searchItem ||
            !searchItem.decryptedTitle ||
            isVaultArmored(searchItem.decryptedTitle));

        if (needsDecryption) {
          toDecrypt.push({
            id,
            type: 'chain',
            rawTitle,
            projectId: ch.projectId || g.projectId,
            status: ch.status,
            updatedAt: ch.updatedAt,
          });
        }
      }
    }

    if (toDecrypt.length === 0) return;

    let canceled = false;
    batchDecryptTitles(toDecrypt, activeVaultKey)
      .then((decryptedItems) => {
        if (!canceled && decryptedItems.length > 0) {
          dispatch(setBulkChainTitles(decryptedItems));
        }
      })
      .catch((err) => {
        console.error('Failed to batch decrypt task chain titles in TaskChainSelectorModal:', err);
      });

    return () => {
      canceled = true;
    };
  }, [resolvedGroups, searchChains, activeVaultKey, open, dispatch]);

  // Combine and prepopulate all task chains across projects
  const allChains = useMemo(() => {
    return prepareChainSelectorItems(resolvedGroups, searchChains, currentChainId);
  }, [resolvedGroups, searchChains, currentChainId]);

  // Search content stays transient: results live only in this modal and selecting
  // one navigates to the canonical chain. Nothing here mutates the pinned sidebar.
  useEffect(() => {
    const trimmed = query.trim();
    if (!open || !isVaultUnlocked || trimmed.length < 2 || !authUser?.user_id) {
      setRemoteChains(null);
      setRemoteSearchState('idle');
      return;
    }
    let canceled = false;
    setRemoteChains(null);
    setRemoteSearchError('');
    const timer = setTimeout(() => {
      setRemoteSearchState('searching');
      searchTaskChainsEncrypted(trimmed, authUser.user_id!, { projectId, limit: 40 })
        .then((response) => {
          if (canceled) return;
          const projectNames = new Map(resolvedGroups.map((group) => [group.projectId, group.projectName]));
          // Bridge hits carry no coordinator: fill it from the loaded chain list
          // so picking a hit opens (or swaps in) the coordinator's conversation.
          const coordinators = new Map<string, string>();
          for (const group of resolvedGroups) {
            for (const ch of group.chains || []) {
              if (ch.coordinatorAgentInstanceId) coordinators.set(ch.chainId, ch.coordinatorAgentInstanceId);
            }
          }
          setRemoteChains(response.hits.map((hit) => ({
            chainId: hit.chain_id,
            title: hit.title || 'Untitled chain',
            rawTitle: hit.title || '',
            status: hit.status || '',
            projectId: hit.project_id || '',
            projectName: projectNames.get(hit.project_id) || '',
            updatedAt: hit.updated_at,
            coordinatorAgentInstanceId: coordinators.get(hit.chain_id) || undefined,
            isCurrent: Boolean(currentChainId && hit.chain_id === currentChainId),
          })));
          setRemoteSearchState(response.stale ? 'stale' : 'idle');
        })
        .catch((error) => {
          if (!canceled) {
            setRemoteChains(null);
            setRemoteSearchState('error');
            setRemoteSearchError(taskChainSearchErrorMessage(error));
          }
        });
    }, 150);
    return () => { canceled = true; clearTimeout(timer); };
  }, [query, open, isVaultUnlocked, authUser?.user_id, projectId, resolvedGroups, currentChainId]);

  // Real-time search filter
  const filteredChains = useMemo(() => {
    if (query.trim().length >= 2 && remoteChains) return remoteChains;
    return filterTaskChains(allChains, query);
  }, [allChains, query, remoteChains]);

  useEffect(() => {
    setActiveIndex((current) => (
      filteredChains.length === 0 ? 0 : Math.min(current, filteredChains.length - 1)
    ));
  }, [filteredChains.length]);

  // Reset and focus on open
  useEffect(() => {
    if (!open) return;

    setQuery('');
    const initialIndex = findInitialActiveIndex(allChains, currentChainId);
    setActiveIndex(initialIndex);

    if (initialIndex >= INITIAL_VISIBLE_COUNT) {
      setVisibleCount(Math.min(initialIndex + 20, allChains.length));
    } else {
      setVisibleCount(INITIAL_VISIBLE_COUNT);
    }

    const timer = setTimeout(() => {
      inputRef.current?.focus();
      const el = listRef.current?.querySelector(`[data-chain-index="${initialIndex}"]`) as HTMLElement | null;
      if (el) {
        el.scrollIntoView({ block: 'nearest' });
      }
    }, 0);

    return () => clearTimeout(timer);
  }, [open, currentChainId, allChains.length]);

  // Scroll active item into view during keyboard navigation
  useEffect(() => {
    if (!open) return;
    const activeEl = listRef.current?.querySelector(`[data-chain-index="${activeIndex}"]`) as HTMLElement | null;
    if (activeEl) {
      activeEl.scrollIntoView({ block: 'nearest' });
    }
  }, [activeIndex, open]);

  const handleScroll = (event: React.UIEvent<HTMLDivElement>) => {
    const { scrollTop, scrollHeight, clientHeight } = event.currentTarget;
    if (scrollTop + clientHeight >= scrollHeight - 150) {
      setVisibleCount((prev) => Math.min(prev + 40, filteredChains.length));
    }
  };

  // Opening a chain opens its coordinator's conversation; the coordinator is
  // resolved from the chain detail when the list row doesn't carry it.
  const handleSelect = (chain: ChainSelectorItem) => {
    onClose();
    void resolveChainConversationAgent(dispatch, chain.chainId, chain.coordinatorAgentInstanceId).then((coordinator) => {
      const resolved = { chainId: chain.chainId, coordinatorAgentInstanceId: coordinator || undefined };
      if (onSelectChain) {
        onSelectChain(resolved);
        return;
      }
      const route = taskChainRoute(resolved);
      if (onNavigate) {
        onNavigate(route);
      } else {
        window.location.hash = buildRouteHash(route, '');
      }
    });
  };

  const handleKeyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      onClose();
      return;
    }

    const direction = selectionDirectionForEvent(event);
    if (direction) {
      event.preventDefault();
      setActiveIndex((prev) => {
        const next = navigateIndex(prev, filteredChains.length, direction);
        if (direction === 'down' && next >= visibleCount) {
          setVisibleCount((c) => Math.min(c + 40, filteredChains.length));
        }
        return next;
      });
      return;
    }

    if (event.key === 'Enter') {
      event.preventDefault();
      const selected = filteredChains[activeIndex];
      if (selected) {
        handleSelect(selected);
      }
      return;
    }
  };

  if (!open) return null;

  const visibleItems = filteredChains.slice(0, visibleCount);
  const grouped = groupChainsByProject(visibleItems);
  const qTrim = query.trim();

  return (
    <div
      data-debug-id="task-chain-selector-modal"
      role="presentation"
      className="fixed inset-x-0 top-0 app-viewport-height z-modal flex items-start justify-center bg-surface-overlay/80 px-2 pt-[max(env(safe-area-inset-top),0.5rem)] backdrop-blur-sm sm:px-4 sm:pt-[calc(var(--app-viewport-height)*0.12)]"
      onClick={onClose}
    >
      <div
        ref={panelRef}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-label="Select task chain"
        data-debug-id="task-chain-selector-panel"
        className="flex max-h-[calc(var(--app-viewport-height)-1rem)] w-full max-w-2xl flex-col overflow-hidden rounded-2xl border border-subtle bg-surface-overlay shadow-overlay outline-none sm:max-h-[calc(var(--app-viewport-height)*0.7)]"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center gap-3 border-b border-subtle px-4 py-3">
          <span aria-hidden="true" className="text-muted">
            <Icon name="search" size={16} />
          </span>
          <input
            ref={inputRef}
            data-debug-id="task-chain-selector-search-input"
            role="combobox"
            aria-expanded="true"
            aria-controls="task-chain-selector-listbox"
            aria-activedescendant={filteredChains.length ? `task-chain-option-${activeIndex}` : undefined}
            aria-autocomplete="list"
            aria-label="Search task chains"
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setActiveIndex(0);
              setVisibleCount(INITIAL_VISIBLE_COUNT);
            }}
            onKeyDown={handleKeyDown}
            placeholder="Search task chains by title, project, or ID…"
            className="min-w-0 flex-1 bg-transparent text-[15px] text-primary outline-none placeholder:text-faint"
            autoComplete="off"
            spellCheck={false}
          />
          <kbd className="rounded border border-subtle bg-neutral-soft px-1.5 py-0.5 text-[10px] text-muted">esc</kbd>
        </div>

        <div
          ref={listRef}
          id="task-chain-selector-listbox"
          role="listbox"
          aria-label="Task chains"
          data-debug-id="task-chain-selector-list"
          className="max-h-[calc(var(--app-viewport-height)*0.6)] sm:max-h-[420px] overflow-y-auto p-2"
          onScroll={handleScroll}
        >
          {qTrim.length >= 2 && remoteSearchState !== 'idle' ? (
            <div data-debug-id="task-chain-search-state" className="px-3 py-1 text-xs text-faint">
              {remoteSearchState === 'searching' ? 'Searching unlocked Bridges…' : remoteSearchState === 'stale' ? 'Results may be stale.' : remoteSearchError}
            </div>
          ) : null}
          {isLoading && allChains.length === 0 ? (
            <div data-debug-id="task-chain-selector-loading" className="px-3 py-8 text-center text-sm text-muted">
              Loading task chains…
            </div>
          ) : filteredChains.length === 0 ? (
            <div data-debug-id="task-chain-selector-empty" className="px-3 py-8 text-center text-sm text-muted">
              {qTrim.length === 0
                ? 'No task chains found.'
                : `No task chains matching “${qTrim}”.`}
            </div>
          ) : (
            Array.from(grouped.entries()).map(([projectName, { items: groupItems, indices }]) => (
              <div key={projectName} role="group" aria-label={projectName} className="mb-2">
                <div
                  aria-hidden="true"
                  data-debug-id={`chain-selector-group-${projectName.toLowerCase().replace(/\s+/g, '-')}`}
                  className="px-3 py-1 text-[10.5px] font-semibold uppercase tracking-[0.18em] text-faint"
                >
                  {projectName}
                </div>
                {groupItems.map((chain, i) => {
                  const idx = indices[i];
                  const active = idx === activeIndex;
                  const isCurrent = Boolean(chain.isCurrent);
                  const tonePulse = chainStatusDot(chain.status);

                  return (
                    <div
                      key={chain.chainId}
                      role="option"
                      id={`task-chain-option-${idx}`}
                      aria-selected={active}
                      data-debug-id={`chain-selector-item-${chain.chainId}`}
                      data-chain-id={chain.chainId}
                      data-chain-index={idx}
                      data-current={isCurrent ? 'true' : 'false'}
                      onClick={() => handleSelect(chain)}
                      onMouseEnter={() => setActiveIndex(idx)}
                      className={`flex w-full cursor-pointer items-center gap-3 rounded-lg px-3 py-2 text-left text-sm transition-colors ${
                        active
                          ? 'bg-neutral-soft text-primary font-semibold'
                          : 'text-muted hover:bg-neutral-soft hover:text-primary'
                      }`}
                    >
                      <span aria-hidden="true" className="grid w-5 shrink-0 place-items-center">
                        <StatusDot tone={tonePulse.tone} pulse={tonePulse.pulse} label={chain.status || 'Chain'} />
                      </span>

                      <span className="flex min-w-0 flex-1 flex-col gap-0.5">
                        <span data-debug-id="chain-title-row" className="flex min-w-0 items-center gap-2">
                          <span className="min-w-0 flex-1 truncate">
                            <VaultText value={chain.rawTitle || chain.title} as="span" />
                          </span>
                          {isCurrent ? (
                            <span
                              data-debug-id="chain-current-badge"
                              className="inline-flex shrink-0 items-center rounded px-1.5 py-0.5 text-[10px] font-bold bg-accent/20 text-accent border border-accent/40"
                            >
                              Current
                            </span>
                          ) : null}
                        </span>

                        <span
                          data-debug-id="chain-secondary-meta"
                          className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-0.5 text-caption text-faint"
                        >
                          <span className="truncate">
                            ID: {chain.chainId}
                          </span>
                          {chain.status ? (
                            <span className="inline-flex shrink-0 items-center rounded px-1.5 py-0.5 text-[10px] font-semibold bg-neutral-soft text-muted capitalize sm:hidden">
                              {chain.status.replace(/_/g, ' ')}
                            </span>
                          ) : null}
                          {chain.taskCount !== undefined ? (
                            <span className="shrink-0 sm:hidden">
                              {chain.completedTaskCount ?? 0}/{chain.taskCount} tasks
                            </span>
                          ) : null}
                        </span>
                      </span>

                      {chain.projectName ? (
                        <span
                          data-debug-id="chain-project-badge"
                          className="ml-2 hidden sm:inline-flex shrink-0 items-center rounded px-1.5 py-0.5 text-[10px] font-medium bg-neutral-soft text-muted truncate max-w-[120px]"
                        >
                          {chain.projectName}
                        </span>
                      ) : null}

                      {chain.status ? (
                        <span className="ml-2 hidden sm:inline-flex shrink-0 items-center rounded px-1.5 py-0.5 text-[10px] font-semibold bg-neutral-soft text-muted capitalize">
                          {chain.status.replace(/_/g, ' ')}
                        </span>
                      ) : null}

                      {chain.taskCount !== undefined ? (
                        <span className="ml-2 hidden sm:inline shrink-0 text-caption text-faint">
                          {chain.completedTaskCount ?? 0}/{chain.taskCount} tasks
                        </span>
                      ) : null}

                      <Icon name="chevron-right" size={14} className="ml-1 shrink-0 text-muted opacity-60" />
                    </div>
                  );
                })}
              </div>
            ))
          )}

          {visibleCount < filteredChains.length ? (
            <div className="py-2 text-center text-xs text-muted">
              Showing {visibleCount} of {filteredChains.length} task chains (scroll down for more)
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}

export default TaskChainSelectorModal;
