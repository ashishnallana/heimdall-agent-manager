/**
 * CommandPalette — the unified Cmd/Ctrl-K palette (EL-056 / REQ-SEARCH-PALETTE-UI-1).
 * ------------------------------------------------------------------
 * Purpose: one keyboard-first surface for task chain search + navigation + quick
 * actions, invoked from Cmd/Ctrl-K, the sidebar "Search" item, and the mobile
 * center tab. All entity search is strictly client-side against decrypted task chain
 * titles from searchTitleSlice, with zero backend entity queries.
 *
 * Layer: pattern (product-specific). Built on the shared dialog a11y contract
 * (`useDialogA11y`, the same focus-trap/Esc/scroll-lock/restore Modal uses) and
 * the ARIA combobox pattern (an input `role="combobox"` driving a `role="listbox"`
 * of `role="option"` rows via `aria-activedescendant`).
 *
 * Accessibility (built in, not props):
 *   - Panel is `role="dialog"` + `aria-modal` + `aria-label`; `useDialogA11y`
 *     traps focus, closes on Esc, locks body scroll, and restores focus on close.
 *   - The input is `role="combobox"` (`aria-expanded`, `aria-controls`,
 *     `aria-activedescendant`, `aria-autocomplete="list"`); results are a
 *     `role="listbox"`; each row is a `role="option"` with a stable id and
 *     `aria-selected`. Focus stays on the input; ↑/↓ move the active option,
 *     Enter activates it — the options are not tab stops.
 */
import React, { useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import type { ChainProjectGroup } from '../../../api/endpoints/tasks';
import {
  selectSearchChains,
  setBulkChainTitles,
  type SearchItem,
} from '../../../store/searchTitleSlice';
import {
  selectIsVaultUnlocked,
  getActiveVaultKey,
} from '../../../store/vaultSlice';
import { isVaultArmored, decryptVaultText } from '../../../utils/vaultContent';
import { batchDecryptTitles, type RawSearchItemInput } from '../../../utils/vaultSearch';
import { VaultText, useDecryptedText } from '../../vault/VaultText';
import { Icon, StatusDot, type IconName } from '../primitives';
import { runtimeStatusToTone } from './RuntimeChip';
import { useDialogA11y } from '../composites/useDialogA11y';
import { resolveChainConversationAgent } from '../../../utils/chainConversation';
import { THEMES } from '../../../theme/registry';
import {
  type PaletteConversation,
  type PaletteConversationGroup,
  type PaletteScope,
  type PaletteAction,
  type PaletteResult,
  chainStatusDot,
  taskChainRoute,
  optionId,
  DEFAULT_NAV,
  DEFAULT_ACTIONS,
  paletteNavItems,
  mergePaletteActions,
  matchesQuery,
} from './commandPaletteLogic';

export type {
  PaletteConversation,
  PaletteConversationGroup,
  PaletteScope,
  PaletteAction,
  PaletteResult,
};
export {
  chainStatusDot,
  taskChainRoute,
  optionId,
  DEFAULT_NAV,
  DEFAULT_ACTIONS,
  mergePaletteActions,
  THEMES,
};

export type CommandPaletteProps = {
  open: boolean;
  onClose: () => void;
  onNavigate: (route: string) => void;
  onAction?: (actionId: string) => void;
  actions?: PaletteAction[];
  conversationGroups?: PaletteConversationGroup[];
  chainGroups?: ChainProjectGroup[];
  currentPath?: string;
  scope?: PaletteScope;
  /** REQ-EXP-GATE-2: show the Actions nav entry. Fails closed (hidden) when omitted. */
  actionsEnabled?: boolean;
};

function convoDot(convo: PaletteConversation): { tone: Parameters<typeof StatusDot>[0]['tone']; pulse: boolean } {
  const tone = runtimeStatusToTone(convo.runtimeStatus || '');
  const busy = ['active', 'busy', 'working'].includes(String(convo.activityStatus || '').toLowerCase());
  return { tone, pulse: tone === 'success' && busy };
}

function matches(haystack: string, q: string): boolean {
  return matchesQuery(haystack, q);
}



export function CommandPalette({
  open,
  onClose,
  onNavigate,
  onAction,
  actions = DEFAULT_ACTIONS,
  conversationGroups = [],
  chainGroups = [],
  currentPath = '',
  scope,
  actionsEnabled = false,
}: CommandPaletteProps) {
  const [query, setQuery] = useState('');
  const [activeIndex, setActiveIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const listRef = useRef<HTMLDivElement | null>(null);
  const panelRef = useRef<HTMLDivElement | null>(null);
  const listboxId = 'command-palette-listbox';

  const hasScope = Boolean(scope && (scope.chainId || scope.conversationId));
  const [scoped, setScoped] = useState(true);
  const scopeActive = hasScope && scoped;

  const { text: decryptedScopeLabel } = useDecryptedText(scope?.label);
  const scopeTitle = decryptedScopeLabel || scope?.label || 'This chain';

  // Shared dialog contract: focus trap, Esc-to-close, body scroll-lock, and focus restore.
  useDialogA11y(open, onClose, panelRef);

  const dispatch = useDispatch();

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

  // Retrieve client-side decrypted task chains from Redux title cache
  const searchChains = useSelector((state: any) => {
    try {
      return (selectSearchChains(state) as Record<string, SearchItem>) || {};
    } catch {
      return (state?.searchTitle?.chains as Record<string, SearchItem> | undefined) || {};
    }
  });

  // Batch decrypt any armored task chain titles in chainGroups not yet decrypted in searchChains
  useEffect(() => {
    if (!activeVaultKey) return;
    const toDecrypt: RawSearchItemInput[] = [];
    for (const g of chainGroups) {
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
        console.error('Failed to batch decrypt task chain titles in CommandPalette:', err);
      });

    return () => {
      canceled = true;
    };
  }, [chainGroups, searchChains, activeVaultKey, dispatch]);

  const [decryptedProjectNames, setDecryptedProjectNames] = useState<Record<string, string>>({});

  // Decrypt armored project names in chainGroups/conversationGroups using activeVaultKey
  useEffect(() => {
    if (!activeVaultKey) return;
    let canceled = false;
    const toDecrypt: { id: string; raw: string }[] = [];

    for (const g of chainGroups) {
      if (g.projectId && g.projectName && isVaultArmored(g.projectName) && !decryptedProjectNames[g.projectId]) {
        toDecrypt.push({ id: g.projectId, raw: g.projectName });
      }
    }
    for (const g of conversationGroups) {
      if (g.projectId && g.projectName && isVaultArmored(g.projectName) && !decryptedProjectNames[g.projectId]) {
        toDecrypt.push({ id: g.projectId, raw: g.projectName });
      }
    }

    if (toDecrypt.length === 0) return;

    Promise.all(
      toDecrypt.map(async (item) => {
        try {
          const dec = await decryptVaultText(item.raw, activeVaultKey);
          return { id: item.id, dec };
        } catch {
          return { id: item.id, dec: item.raw };
        }
      })
    ).then((res) => {
      if (!canceled && res.length > 0) {
        setDecryptedProjectNames((prev) => {
          const next = { ...prev };
          for (const item of res) {
            next[item.id] = item.dec;
          }
          return next;
        });
      }
    });

    return () => {
      canceled = true;
    };
  }, [chainGroups, conversationGroups, activeVaultKey, decryptedProjectNames]);

  // Project names index lookup
  const projectNamesById = useMemo(() => {
    const map = new Map<string, string>();
    for (const g of chainGroups) {
      if (g.projectId && g.projectName) {
        map.set(g.projectId, decryptedProjectNames[g.projectId] || g.projectName);
      }
    }
    for (const g of conversationGroups) {
      if (g.projectId && g.projectName) {
        map.set(g.projectId, decryptedProjectNames[g.projectId] || g.projectName);
      }
    }
    return map;
  }, [chainGroups, conversationGroups, decryptedProjectNames]);

  // Combine task chains across ALL projects from props and searchTitleSlice
  const allChains = useMemo(() => {
    const map = new Map<string, {
      chainId: string;
      title: string;
      rawTitle?: string;
      status?: string;
      projectId?: string;
      projectName?: string;
      coordinatorAgentInstanceId?: string;
    }>();

    // 1. Chains passed via chainGroups
    for (const g of chainGroups) {
      for (const ch of g.chains) {
        const id = ch.chainId;
        const searchItem = searchChains[id];
        const title = searchItem?.decryptedTitle || ch.title || 'Untitled chain';
        const pId = ch.projectId || g.projectId;
        const pName = (pId ? projectNamesById.get(pId) : null) || ch.projectName || g.projectName || '';
        map.set(id, {
          chainId: id,
          title,
          rawTitle: searchItem?.rawTitle || ch.title,
          status: searchItem?.status || ch.status,
          projectId: pId,
          projectName: pName,
          coordinatorAgentInstanceId: ch.coordinatorAgentInstanceId,
        });
      }
    }

    // 2. Chains from searchTitleSlice
    for (const item of Object.values(searchChains)) {
      if (item.type !== 'chain' || !item.id) continue;
      const id = item.id;
      const existing = map.get(id);
      const title = item.decryptedTitle || item.rawTitle || existing?.title || 'Untitled chain';
      const status = item.status || existing?.status;
      const projectId = item.projectId || existing?.projectId;
      const projectName = (projectId ? projectNamesById.get(projectId) : '') || existing?.projectName || '';

      if (!existing) {
        map.set(id, {
          chainId: id,
          title,
          rawTitle: item.rawTitle,
          status,
          projectId,
          projectName,
        });
      } else {
        map.set(id, {
          ...existing,
          title,
          status: status || existing.status,
          projectId: projectId || existing.projectId,
          projectName: projectName || existing.projectName,
        });
      }
    }

    return Array.from(map.values());
  }, [chainGroups, searchChains, projectNamesById]);

  // Reset state on open
  useEffect(() => {
    if (open) {
      setQuery('');
      setActiveIndex(0);
      setScoped(true);
      window.setTimeout(() => inputRef.current?.focus(), 0);
    }
  }, [open]);

  // Build the result list: strictly search task chains on query, retain quick navigation on empty
  const results = useMemo<PaletteResult[]>(() => {
    const q = query.trim().toLowerCase();
    const out: PaletteResult[] = [];

    // Empty query: retain quick navigation & default browsing
    if (!q) {
      if (!hasScope) {
        paletteNavItems(actionsEnabled).forEach((item) => {
          out.push({ kind: 'navigate', label: item.label, icon: item.icon, route: item.route, group: 'Navigate' });
        });
        actions.forEach((a) => {
          out.push({ kind: 'action', label: a.label, hint: a.hint, badge: a.badge, icon: a.icon, actionId: a.id, route: a.route, group: 'Actions' });
        });
      }

      if (hasScope && scopeActive) {
        for (const group of conversationGroups) {
          const groupName = (group.projectId && projectNamesById.get(group.projectId)) || group.projectName || 'Conversations';
          group.conversations.forEach((c) => {
            out.push({
              kind: 'conversation',
              label: c.title || c.agentName || c.conversationId,
              hint: c.agentName && c.agentName !== c.title ? c.agentName : undefined,
              route: `/conversations/${encodeURIComponent(c.agentInstanceId || '')}`,
              group: groupName,
              convo: c,
            });
          });
        }
      }

      const chainsToShow = (hasScope && scopeActive && scope?.chainId)
        ? allChains.filter((c) => c.chainId === scope.chainId)
        : allChains;

      for (const ch of chainsToShow) {
        const route = taskChainRoute(ch);
        out.push({
          kind: 'chain',
          label: ch.title,
          hint: ch.projectName || undefined,
          route,
          group: ch.projectName ? `${ch.projectName} — Chains` : 'Chains',
          chainId: ch.chainId,
          status: ch.status,
          projectId: ch.projectId,
          projectName: ch.projectName,
        });
      }

      if (!hasScope) {
        for (const group of conversationGroups) {
          const groupName = (group.projectId && projectNamesById.get(group.projectId)) || group.projectName || 'Conversations';
          group.conversations.forEach((c) => {
            out.push({
              kind: 'conversation',
              label: c.title || c.agentName || c.conversationId,
              hint: c.agentName && c.agentName !== c.title ? c.agentName : undefined,
              route: `/conversations/${encodeURIComponent(c.agentInstanceId || '')}`,
              group: groupName,
              convo: c,
            });
          });
        }
      }

      return out;
    }

    // Non-empty query: search strictly across task chains by decrypted title!
    const matchingChains = allChains.filter((ch) => {
      if (hasScope && scopeActive && scope?.chainId && ch.chainId !== scope.chainId) {
        return false;
      }
      const titleMatches = !isVaultArmored(ch.title) && matches(ch.title, q);
      const projectMatches = ch.projectName && !isVaultArmored(ch.projectName) ? matches(ch.projectName, q) : false;
      return titleMatches || projectMatches;
    });

    for (const ch of matchingChains) {
      const route = taskChainRoute(ch);
      out.push({
        kind: 'chain',
        label: ch.title,
        hint: ch.projectName || undefined,
        route,
        group: ch.projectName ? `${ch.projectName} — Chains` : 'Chains',
        chainId: ch.chainId,
        status: ch.status,
        projectId: ch.projectId,
        projectName: ch.projectName,
      });
    }

    return out;
  }, [query, actions, conversationGroups, allChains, hasScope, scopeActive, scope?.chainId, projectNamesById, actionsEnabled]);

  // Reset active index when results change
  useEffect(() => {
    setActiveIndex(0);
  }, [results]);

  // Keep active option in view
  useEffect(() => {
    const node = listRef.current?.querySelector<HTMLElement>(`[data-palette-index="${activeIndex}"]`);
    node?.scrollIntoView({ block: 'nearest' });
  }, [activeIndex]);

  function activate(result: PaletteResult) {
    // A chain row without a known coordinator would land on the chain page:
    // resolve its coordinator so the chain opens as its conversation.
    if (result.kind === 'chain' && result.route?.startsWith('/chains/')) {
      onClose();
      void resolveChainConversationAgent(dispatch, result.chainId).then((coordinator) => {
        onNavigate(coordinator ? taskChainRoute({ chainId: result.chainId, coordinatorAgentInstanceId: coordinator }) : result.route);
      });
      return;
    }
    if (result.kind === 'navigate' || result.kind === 'conversation' || result.kind === 'chain') {
      if (result.route) {
        onNavigate(result.route);
        onClose();
      }
    } else if (result.kind === 'action') {
      if (result.route) {
        onNavigate(result.route);
      }
      onAction?.(result.actionId);
      onClose();
    }
  }

  function handleKeyDown(event: React.KeyboardEvent) {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      setActiveIndex((i) => (i + 1) % Math.max(results.length, 1));
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      setActiveIndex((i) => (i - 1 + Math.max(results.length, 1)) % Math.max(results.length, 1));
    } else if (event.key === 'Enter') {
      event.preventDefault();
      const result = results[activeIndex];
      if (result) activate(result);
    }
  }

  if (!open) return null;

  // Group results for rendering
  const grouped = new Map<string, { results: PaletteResult[]; indices: number[] }>();
  let flatIndex = 0;
  for (const result of results) {
    const key = result.group;
    if (!grouped.has(key)) grouped.set(key, { results: [], indices: [] });
    grouped.get(key)!.results.push(result);
    grouped.get(key)!.indices.push(flatIndex);
    flatIndex += 1;
  }

  const qTrim = query.trim();

  return (
    <div
      data-debug-id="command-palette"
      role="presentation"
      className="fixed inset-x-0 top-0 app-viewport-height z-modal flex items-start justify-center bg-surface-overlay/80 px-2 pt-[max(env(safe-area-inset-top),0.5rem)] backdrop-blur-sm sm:px-4 sm:pt-[calc(var(--app-viewport-height)*0.12)]"
      onClick={onClose}
    >
      <div
        ref={panelRef}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-label="Command palette"
        data-debug-id="command-palette-panel"
        className="flex max-h-[calc(var(--app-viewport-height)-1rem)] w-full max-w-2xl flex-col overflow-hidden rounded-2xl border border-subtle bg-surface-overlay shadow-overlay outline-none sm:max-h-[calc(var(--app-viewport-height)*0.7)]"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="flex items-center gap-3 border-b border-subtle px-4 py-3">
          <span aria-hidden="true" className="text-muted"><Icon name="search" size={16} /></span>
          <input
            ref={inputRef}
            data-debug-id="command-palette-input"
            role="combobox"
            aria-expanded="true"
            aria-controls={listboxId}
            aria-activedescendant={results.length ? optionId(activeIndex) : undefined}
            aria-autocomplete="list"
            aria-label="Search task chains"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Type a task chain name or jump…"
            className="min-w-0 flex-1 bg-transparent text-[15px] text-primary outline-none placeholder:text-faint"
            autoComplete="off"
            spellCheck={false}
          />
          <kbd className="rounded border border-subtle bg-neutral-soft px-1.5 py-0.5 text-[10px] text-muted">esc</kbd>
        </div>

        {hasScope ? (
          <div data-debug-id="command-palette-scope" className="flex min-w-0 items-center gap-2 border-b border-subtle px-4 py-1.5 text-[11px] text-muted">
            <span className="shrink-0 text-faint">Scope</span>
            <div role="group" aria-label="Search scope" className="inline-flex min-w-0 items-center overflow-hidden rounded-md border border-subtle">
              <button
                type="button"
                data-debug-id="command-palette-scope-chain"
                aria-pressed={scoped}
                onClick={() => setScoped(true)}
                title={scopeTitle}
                className={`max-w-[200px] truncate px-2 py-0.5 ${scoped ? 'bg-accent text-accent-fg' : 'text-muted hover:bg-neutral-soft hover:text-primary'}`}
              >
                <VaultText value={scope?.label} fallback="This chain" />
              </button>
              <button
                type="button"
                data-debug-id="command-palette-scope-all"
                aria-pressed={!scoped}
                onClick={() => setScoped(false)}
                className={`shrink-0 px-2 py-0.5 ${!scoped ? 'bg-accent text-accent-fg' : 'text-muted hover:bg-neutral-soft hover:text-primary'}`}
              >
                All
              </button>
            </div>
          </div>
        ) : null}

        <div
          ref={listRef}
          id={listboxId}
          role="listbox"
          aria-label="Results"
          className="flex-1 overflow-y-auto p-2"
        >
          {results.length === 0 ? (
            <div data-debug-id="command-palette-empty" role="presentation" className="px-3 py-8 text-center text-sm text-muted">
              {qTrim.length === 0
                ? (scopeActive ? 'Type to search task chains in this scope.' : 'Start typing to search task chains or jump.')
                : `No task chains found for “${qTrim}”.`}
            </div>
          ) : (
            Array.from(grouped.entries()).map(([groupLabel, { results: groupResults, indices }]) => (
              <div key={groupLabel} role="group" aria-label={groupLabel} className="mb-1">
                <div aria-hidden="true" data-debug-id={`command-palette-group-${groupLabel.toLowerCase().replace(/\s+/g, '-')}`} className="px-3 py-1 text-[10.5px] font-semibold uppercase tracking-[0.18em] text-faint"><VaultText value={groupLabel} /></div>
                {groupResults.map((result, i) => {
                  const idx = indices[i];
                  const active = idx === activeIndex;
                  const label = result.label;
                  const icon: IconName = ((result as any).icon || 'tasks');
                  const isConvo = result.kind === 'conversation';
                  const isChain = result.kind === 'chain';
                  const unread = isConvo ? Number(result.convo.unreadCount || 0) : 0;
                  const isSelectedConvo = isConvo && Boolean(
                    currentPath &&
                    (currentPath === `/conversations/${result.convo.agentInstanceId}` ||
                     currentPath.startsWith(`/conversations/${result.convo.agentInstanceId}/`))
                  );
                  const isSelectedChain = isChain && Boolean(
                    currentPath && (currentPath === result.route || currentPath.startsWith(result.route + '/'))
                  );
                  const highlight = active || isSelectedConvo || isSelectedChain;
                  return (
                    <div
                      key={`${groupLabel}-${idx}`}
                      role="option"
                      id={optionId(idx)}
                      aria-selected={active}
                      data-debug-id={`command-palette-result-${idx}`}
                      data-palette-index={idx}
                      onClick={() => activate(result)}
                      onMouseEnter={() => setActiveIndex(idx)}
                      className={`flex w-full cursor-pointer items-center gap-3 rounded-lg px-3 py-2 text-left text-sm ${highlight ? 'bg-neutral-soft text-primary font-semibold' : 'text-muted hover:bg-neutral-soft hover:text-primary'}`}
                    >
                      {isChain ? (
                        <span aria-hidden="true" className="grid w-5 place-items-center">
                          <StatusDot tone={chainStatusDot(result.status).tone} pulse={chainStatusDot(result.status).pulse} label={result.status || 'Chain'} />
                        </span>
                      ) : isConvo ? (
                        <span aria-hidden="true" className="grid w-5 place-items-center">
                          <StatusDot tone={convoDot(result.convo).tone} pulse={convoDot(result.convo).pulse} label="" />
                        </span>
                      ) : (
                        <span aria-hidden="true" className="grid w-5 place-items-center text-muted opacity-80"><Icon name={icon} size={16} /></span>
                      )}
                      <span className="flex min-w-0 flex-1 flex-col">
                        <span className={`truncate ${isConvo && result.convo.isCoordinator ? 'text-warning' : ''}`} title={isConvo && result.convo.isCoordinator ? 'Coordinator' : undefined}>
                          <VaultText value={label} as="span" />
                        </span>
                        {isChain && result.hint ? (
                          <span className="truncate text-caption text-muted"><VaultText value={result.hint} /></span>
                        ) : null}
                      </span>
                      {result.kind === 'action' && result.badge ? (
                        <span className="ml-2 inline-flex shrink-0 items-center rounded px-1.5 py-0.5 text-[10px] font-semibold bg-neutral-soft text-muted">
                          {result.badge}
                        </span>
                      ) : null}
                      {isChain && result.status ? (
                        <span className="ml-2 inline-flex shrink-0 items-center rounded px-1.5 py-0.5 text-[10px] font-semibold bg-neutral-soft text-muted capitalize">
                          {result.status.replace(/_/g, ' ')}
                        </span>
                      ) : null}
                      {unread > 0 ? <span className="ml-auto shrink-0 rounded-full bg-accent px-1.5 text-center text-[10px] font-bold leading-4 text-accent-fg">{unread > 99 ? '99+' : unread}</span> : null}
                      {result.hint && !isChain ? <span className="ml-auto shrink-0 truncate self-center pl-2 text-caption text-muted"><VaultText value={result.hint} /></span> : null}
                      {isChain ? (
                        <span aria-hidden="true" className="ml-auto shrink-0 text-muted opacity-60">
                          <Icon name="chevron-right" size={14} />
                        </span>
                      ) : null}
                    </div>
                  );
                })}
              </div>
            ))
          )}
        </div>

        <div className="hidden items-center justify-between border-t border-subtle px-4 py-2 text-caption text-faint sm:flex">
          <span className="flex items-center gap-2">
            <kbd className="rounded border border-subtle bg-neutral-soft px-1.5 py-0.5">↑↓</kbd> navigate
            <kbd className="ml-2 rounded border border-subtle bg-neutral-soft px-1.5 py-0.5">↵</kbd> select
          </span>
          <span data-debug-id="command-palette-search-source">{qTrim ? 'Task chains' : 'Ninjy'}</span>
        </div>
      </div>
    </div>
  );
}

export default CommandPalette;
