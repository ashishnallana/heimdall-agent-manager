import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Icon } from '@ui';
import { TilingContainer, calculatePaneLayouts, getOverlayPosition, type RenderPaneProps } from '../../tiling';
import {
  NEW_PANE_AGENT_ID,
  assignMainPaneAgent,
  canResizeFocusedMainPane,
  closeMainPane,
  equalizeMainPanes,
  isAgentPaneId,
  isRealAgentId,
  isShellPaneId,
  resizeMainSplit,
  resizeFocusedMainPane,
  selectFocusedMainAgentId,
  selectMainAgentIds,
  selectMainLeafIds,
  selectMainPaneIds,
  selectMainTree,
  setFocusedMainPane,
  setLayoutFromUrl,
  splitMainPane,
  swapMainPanes,
  toggleMaximizeMainPane,
  type LauncherIntent,
  type MainPaneValue,
} from '../../store/workspaceLayoutSlice';
import {
  carryAuxPaneOpenOnFocus,
  ensureAuxPane,
  hydrateAuxPanes,
  openAuxTab,
  selectAuxPane,
  selectAuxPanesState,
  selectCurrentAuxTreeId,
  setAuxPaneOpen,
  toggleAuxPane,
  visibleAuxTabs,
} from '../../store/auxPanesSlice';
import {
  AUX_DEFAULT_WIDTH,
  hydrateWorkspaceChrome,
  selectAuxWidth,
  selectIsAuxMaximized,
  selectPendingSplitDrop,
  setAuxWidth,
} from '../../store/workspaceChromeSlice';
import { auxTabId, resolveLegacyPanelToAuxContent, type AuxContent } from '../../store/auxTabId';
import { isAuxContentAllowed } from '../../store/auxTabGuards';
import { buildRouteHash, getRoutePathname, getRouteSearch } from '../../utils/appLocation';
import {
  buildConversationHash,
  conversationUrlKey,
  navigateToHash,
  parseConversationIdsFromRoute,
  replaceHash,
} from '../../utils/conversationUrl';
import {
  findGroupForAgent,
  loadSavedLayout,
  persistSplitLayout,
  readGroupIndex,
} from '../../store/splitGroups';
import {
  readAuxPanesState,
  readWorkspaceChromeState,
  removeLegacyWorkbenchStorage,
  writeAuxPanesState,
  writeWorkspaceChromeState,
} from '../../utils/clientPersistence';
import { AuxDock } from '../aux/AuxDock';
import { useAgentAuxContext } from '../aux/useAgentAuxContext';
import { AgentChatPane } from '../workbench/AgentChatPane';
import { ShellMainPane } from './ShellMainPane';
import { getContentPaneIds } from '../../tiling';
import { MainPaneFrame } from './MainPaneFrame';
import { MobileMainPager } from './MobileMainPager';
import HomePage from '../home/HomePage';
import { PANE_ANIMATION_MS, chromeIconButtonSizeClass, topChromeHeight } from '../shell/shellChrome';
import { useRegisterActions } from '../../services/shortcuts/useRegisterActions';
import { getDirectionalPaneId, getNextPaneId } from '../../services/shortcuts/shortcutLogic';
import type { AppAction } from '../../services/shortcuts/shortcutLogic';
import ConversationSelectorModal from '../chat/ConversationSelectorModal';
import RunningShellSelectorModal from '../chat/RunningShellSelectorModal';
import TaskChainSelectorModal from '../chains/TaskChainSelectorModal';
import {
  LOCAL_RESOURCE_CHORDS,
  type OpenResourceKind,
  type ResourcePlacement,
} from '../../services/shortcuts/resourceChordMatrix';

export interface WorkspaceProps {
  focusMessageId?: string;
  isMobile?: boolean;
  /** Hidden sidebar: spacer reserving the fixed top-left cluster in the top-left pane's header. */
  leading?: React.ReactNode;
  /** Width occupied by the fixed top-left shell cluster when the sidebar is hidden. */
  leadingWidth?: number;
  /** Hidden sidebar: update-available badge, in the fixed top-right cluster. */
  trailing?: React.ReactNode;
}

function readRoute(): { pathname: string; search: string } {
  return { pathname: getRoutePathname(), search: getRouteSearch() };
}

function focusPaneInput(paneId: string): boolean {
  if (typeof document === 'undefined') return false;
  const frame = document.querySelector<HTMLElement>(`[data-debug-id="main-pane-frame-${paneId}"]`);
  const selectors = [
    '[data-debug-id="conversation-composer-input"]',
    '[data-debug-id="new-convo-composer-input"]',
    '.xterm-helper-textarea',
    'textarea:not([disabled])',
    'input:not([disabled]):not([type="hidden"]):not([type="file"])',
    '[contenteditable="true"]',
  ];
  const target = selectors.reduce<HTMLElement | null>(
    (found, selector) => found ?? frame?.querySelector<HTMLElement>(selector) ?? null,
    null,
  );
  if (!target) return false;
  target.focus({ preventScroll: true });
  return true;
}

/** Subscribes to the hash route (pathname + search, incl. `?focused=`). */
function useRouteLocation() {
  const [loc, setLoc] = useState(readRoute);
  useEffect(() => {
    const update = () =>
      setLoc((prev) => {
        const next = readRoute();
        return prev.pathname === next.pathname && prev.search === next.search ? prev : next;
      });
    window.addEventListener('hashchange', update);
    window.addEventListener('popstate', update);
    update();
    return () => {
      window.removeEventListener('hashchange', update);
      window.removeEventListener('popstate', update);
    };
  }, []);
  return loc;
}

/**
 * The Workspace for `#/conversations/<id1>+<id2>?focused=<id>` (Jetski
 * `MainContent`): a Main split tree of agent chats plus ONE aux dock on the
 * right, toggled from the chat header's [≡].
 *
 * - URL -> layout (RouteToReduxSync): the URL's pane set drives the tree via
 *   `setLayoutFromUrl`; a single-id URL for an agent in a saved split group
 *   opens the whole group focused on it.
 * - Layout -> URL (ReduxToUrlSyncer): in-app edits replace the URL, only when
 *   the URL was stable since the last run (no ping-pong).
 * - The aux dock shows the FOCUSED pane's agent strip; moving focus within a
 *   split carries the open/closed state to the newly focused strip.
 * - Split geometry/groups persist per id set; nothing is keyed by task chain.
 */
export function Workspace({ focusMessageId, isMobile = false, leading, leadingWidth = 0, trailing }: WorkspaceProps) {
  const dispatch = useDispatch();
  const tree = useSelector(selectMainTree);
  const focusedAgentId = useSelector(selectFocusedMainAgentId);
  const mainAgentIds = useSelector(selectMainAgentIds);
  const leafIds = useSelector(selectMainLeafIds);
  const mainPaneIds = useSelector(selectMainPaneIds);
  const mainPaneLayouts = useMemo(() => calculatePaneLayouts(tree).contentLayouts, [tree]);
  const loc = useRouteLocation();
  const route = useMemo(() => parseConversationIdsFromRoute(loc.pathname, loc.search), [loc]);
  const routeAgentInstanceId = route.focused || '';
  const auxTreeId = useSelector(selectCurrentAuxTreeId);
  const auxPane = useSelector((state: any) => selectAuxPane(state, auxTreeId));
  const auxPanesState = useSelector(selectAuxPanesState);
  const auxWidth = useSelector(selectAuxWidth);
  const isAuxMaximized = useSelector(selectIsAuxMaximized);
  const pendingDrop = useSelector(selectPendingSplitDrop);
  const [resourcePickerRequest, setResourcePickerRequest] = useState<{
    resource: OpenResourceKind;
    paneId: string;
    placement: ResourcePlacement;
  } | null>(null);

  // Aux context agent = the focused Main pane's agent (single or split view).
  const ctxAgentId = auxTreeId?.agentInstanceId || '';
  const ctx = useAgentAuxContext(ctxAgentId);
  const hasChain = ctx.isResolved ? Boolean(ctx.chainId) : true;
  const auxOpen = Boolean(auxTreeId && auxPane?.isPaneOpen);
  const auxTabs = visibleAuxTabs(auxPane);
  // The New Tab launcher is always the final aux page once the focused agent's
  // context resolves, even before a materialized tab exists.
  const hasAvailableAux = Boolean(auxTreeId && ctx.isResolved);
  const mainPageCount = leafIds.length;
  const mobileMainContinuumPageCount = mainPageCount + (hasAvailableAux ? auxTabs.length + 1 : 0);
  const mobileAuxContinuumPageCount = mainPageCount + auxTabs.length + 1;

  // 1. Hydrate aux strips + chrome once; drop superseded storage keys.
  const hydratedRef = useRef(false);
  useEffect(() => {
    if (hydratedRef.current) return;
    hydratedRef.current = true;
    const aux = readAuxPanesState();
    if (aux) dispatch(hydrateAuxPanes(aux));
    const chrome = readWorkspaceChromeState();
    if (chrome) dispatch(hydrateWorkspaceChrome(chrome));
    removeLegacyWorkbenchStorage();
  }, [dispatch]);

  // 2. URL -> layout (Jetski RouteToReduxSync).
  const lastSyncKeyRef = useRef<string | null>(null);
  // Main renders only once the layout has been derived from the URL, so the
  // initial placeholder tree never flashes a new-conversation pane.
  const [layoutReady, setLayoutReady] = useState(false);
  const focusedAgentRef = useRef(focusedAgentId);
  focusedAgentRef.current = focusedAgentId;
  useEffect(() => {
    const { ids, focused } = route;
    if (ids.length === 0 || !focused) return;
    const key = conversationUrlKey(ids, focused);
    if (lastSyncKeyRef.current === key) return;
    lastSyncKeyRef.current = key;

    // "Open an agent from anywhere": a single-id URL for an agent that belongs
    // to a saved split group opens the whole group focused on it.
    if (ids.length === 1 && isRealAgentId(ids[0])) {
      const group = findGroupForAgent(readGroupIndex(), ids[0]);
      if (group && group.length > 1) {
        replaceHash(buildConversationHash(group, { focusedId: ids[0] }));
        return;
      }
    }

    const prevFocused = focusedAgentRef.current;
    dispatch(
      setLayoutFromUrl({ ids, focusedId: focused, savedLayout: ids.length > 1 ? loadSavedLayout(ids) : null }),
    );
    setLayoutReady(true);
    // Focus moved within a split: carry the dock open state (Jetski parity).
    if (
      ids.length > 1 &&
      isAgentPaneId(prevFocused) &&
      isAgentPaneId(focused) &&
      prevFocused !== focused &&
      ids.includes(prevFocused)
    ) {
      dispatch(
        carryAuxPaneOpenOnFocus({
          from: { kind: 'agent', agentInstanceId: prevFocused },
          to: { kind: 'agent', agentInstanceId: focused },
        }),
      );
    }
  }, [dispatch, route]);

  // 3. Layout -> URL (Jetski ReduxToUrlSyncer).
  const urlKey = conversationUrlKey(route.ids, route.focused);
  const prevUrlKeyRef = useRef<string | null>(null);
  useEffect(() => {
    if (route.ids.length === 0) return; // not a conversation route
    // Only push for in-app edits (URL stable since last run); if the URL just
    // changed, step 2 reconciles the layout and echoing stale state would loop.
    if (prevUrlKeyRef.current !== urlKey) {
      prevUrlKeyRef.current = urlKey;
      return;
    }
    if (leafIds.length === 0) return;
    if (!leafIds.some(isRealAgentId)) {
      navigateToHash(buildRouteHash('/home', ''));
      return;
    }
    const targetFocused = focusedAgentId || leafIds[0];
    const idsMatch =
      leafIds.length === route.ids.length && leafIds.every((id, i) => id === route.ids[i]);
    if (!idsMatch || targetFocused !== route.focused) {
      replaceHash(buildConversationHash(leafIds, { focusedId: targetFocused }));
    }
  }, [focusedAgentId, leafIds, route, urlKey]);

  // 4. Persist split geometry + groups per id set (Jetski layout persistence).
  const prevActiveKeyRef = useRef<string | null>(null);
  useEffect(() => {
    if (lastSyncKeyRef.current === null) return; // layout not yet derived from the URL
    prevActiveKeyRef.current = persistSplitLayout(tree, prevActiveKeyRef.current);
  }, [tree]);
  useEffect(() => {
    if (hydratedRef.current) writeAuxPanesState(auxPanesState);
  }, [auxPanesState]);
  useEffect(() => {
    if (hydratedRef.current) writeWorkspaceChromeState({ auxWidth });
  }, [auxWidth]);

  // 5. Seed the current strip (Jetski createDefaultPaneState) once the
  //    context agent's chain membership is known.
  useEffect(() => {
    if (!auxTreeId || !ctx.isResolved) return;
    if (auxPane && !(auxPane.activeTabId === undefined && auxPane.tabs.length === 0)) return;
    dispatch(ensureAuxPane({ treeId: auxTreeId, hasChain: Boolean(ctx.chainId) }));
  }, [auxPane, auxTreeId, ctx.chainId, ctx.isResolved, dispatch]);

  // 6. Legacy `?panel=files|vcs|chain|tasks` deep links open an aux tab.
  const consumedPanelRef = useRef('');
  useEffect(() => {
    if (!auxTreeId) return;
    const params = new URLSearchParams(getRouteSearch() || '');
    const panel = params.get('panel') || params.get('sidebar');
    if (!panel) return;
    const key = `${routeAgentInstanceId}:${params.toString()}`;
    if (consumedPanelRef.current === key) return;
    consumedPanelRef.current = key;
    const content = resolveLegacyPanelToAuxContent(panel, {
      filePath: params.get('file') || params.get('path'),
      taskId: params.get('task') || params.get('taskId'),
    });
    if (content) dispatch(openAuxTab({ treeId: auxTreeId, content, hasChain }));
  }, [auxTreeId, dispatch, hasChain, routeAgentInstanceId]);

  const openAuxFromPane = useCallback(
    (paneAgentId: string, content: AuxContent, title?: string) => {
      if (!auxTreeId) return;
      const ownTerminal = content.type === 'agentPty' && content.agentInstanceId === paneAgentId;
      if (
        !ownTerminal &&
        !isAuxContentAllowed(content, {
          ownerAgentId: ctx.agentInstanceId,
          chainId: ctx.chainId,
          participantIds: ctx.participantIds,
        })
      ) {
        return;
      }
      dispatch(openAuxTab({ treeId: auxTreeId, content, title, hasChain }));
    },
    [auxTreeId, ctx.agentInstanceId, ctx.chainId, ctx.participantIds, dispatch, hasChain],
  );

  const toggleAux = useCallback(() => {
    if (auxTreeId) dispatch(toggleAuxPane({ treeId: auxTreeId, hasChain }));
  }, [auxTreeId, dispatch, hasChain]);

  const toggleAuxContent = useCallback(
    (content: AuxContent) => {
      if (!auxTreeId) return;
      if (auxOpen && auxPane?.activeTabId === auxTabId(content)) {
        dispatch(setAuxPaneOpen({ treeId: auxTreeId, open: false, hasChain }));
        return;
      }
      dispatch(openAuxTab({ treeId: auxTreeId, content, hasChain }));
    },
    [auxOpen, auxPane?.activeTabId, auxTreeId, dispatch, hasChain],
  );

  // Fixed top-right cluster (Jetski web): update badge + the ONE side-panel
  // toggle stay in the window's top-right whether or not the aux dock is open.
  // Whatever sits under it (the top-right pane header, or the aux tab strip
  // when the dock is open) reserves its measured width.
  const topRightRef = useRef<HTMLDivElement | null>(null);
  const [topRightWidth, setTopRightWidth] = useState(48);
  useEffect(() => {
    const el = topRightRef.current;
    if (!el) return;
    const measure = () => setTopRightWidth(Math.ceil(el.getBoundingClientRect().width) || el.offsetWidth || 48);
    measure();
    if (typeof ResizeObserver === 'undefined') return;
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Aux dock open / close animation: stay mounted while sliding closed.
  const [auxMounted, setAuxMounted] = useState(auxOpen);
  const [auxShown, setAuxShown] = useState(auxOpen);
  // SH-3: which region holds focus — a Main pane or the aux dock. Pointer-down in
  // either claims it; the active one gets the tmux-style border while more than
  // one pane is visible (desktop only: mobile shows one page at a time).
  const [auxFocused, setAuxFocused] = useState(false);
  useEffect(() => { if (!auxShown) setAuxFocused(false); }, [auxShown]);
  const mainPaneCount = getContentPaneIds(tree).length;
  const showActiveBorder = !isMobile && (mainPaneCount > 1 || auxShown);
  useEffect(() => {
    if (auxOpen) {
      setAuxMounted(true);
      const t = setTimeout(() => setAuxShown(true), 16);
      return () => clearTimeout(t);
    }
    setAuxShown(false);
    const t = setTimeout(() => setAuxMounted(false), PANE_ANIMATION_MS);
    return () => clearTimeout(t);
  }, [auxOpen]);
  const dockOccupiesTopRight = auxMounted && !isMobile;

  const openMobileAux = useCallback(() => {
    if (!auxTreeId || !hasAvailableAux) return;
    dispatch(setAuxPaneOpen({ treeId: auxTreeId, open: true, hasChain }));
  }, [auxTreeId, dispatch, hasAvailableAux, hasChain]);

  const openMobileSidebar = useCallback(() => {
    window.dispatchEvent(new Event('heimdall:open-sidebar'));
  }, []);

  const auxToggle = (
    <button
      type="button"
      data-debug-id="workspace-aux-toggle"
      data-testid="toggle-aux-pane"
      aria-label={auxOpen ? 'Hide side panel' : 'Show side panel'}
      title={auxTreeId ? (auxOpen ? 'Hide side panel' : 'Show side panel') : 'Open a conversation to use the side panel'}
      aria-pressed={auxOpen}
      disabled={!auxTreeId}
      onClick={toggleAux}
      className={`grid ${chromeIconButtonSizeClass(isMobile)} shrink-0 place-items-center transition-colors disabled:cursor-not-allowed disabled:opacity-40 ${
        auxOpen ? 'bg-accent/15 text-accent' : 'text-muted hover:bg-neutral-soft hover:text-primary'
      }`}
    >
      <Icon name="panel-right" size={isMobile ? 20 : 18} />
    </button>
  );

  // 7. Keyboard: Cmd/Ctrl+P (files palette), Cmd/Ctrl+Shift+F (search), Cmd/Ctrl+\ (split right).
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!(event.metaKey || event.ctrlKey) || event.altKey) return;
      const key = event.key.toLowerCase();
      if (key === 'p' && !event.shiftKey && auxTreeId) {
        event.preventDefault();
        dispatch(openAuxTab({ treeId: auxTreeId, content: { type: 'files', openCommandPalette: true }, hasChain }));
      } else if (event.key === '\\' && !event.shiftKey) {
        event.preventDefault();
        dispatch(splitMainPane({ targetPaneId: tree.focusedPaneId, direction: 'right' }));
      }
    };
    // Capture phase so a mounted files panel cannot swallow Cmd+Shift+F.
    const onSearchKeyDown = (event: KeyboardEvent) => {
      if (!(event.metaKey || event.ctrlKey) || event.altKey || !event.shiftKey) return;
      if (event.key.toLowerCase() !== 'f' || !auxTreeId) return;
      event.preventDefault();
      dispatch(openAuxTab({ treeId: auxTreeId, content: { type: 'files', openSearch: true }, hasChain }));
    };
    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('keydown', onSearchKeyDown, true);
    return () => {
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('keydown', onSearchKeyDown, true);
    };
  }, [auxTreeId, dispatch, hasChain, tree.focusedPaneId]);

  const focusPane = useCallback((paneId: string) => dispatch(setFocusedMainPane(paneId)), [dispatch]);
  // Main pane close animation: fade the pane out, then remove it.
  const [closingPaneIds, setClosingPaneIds] = useState<string[]>([]);
  const closePane = useCallback(
    (paneId: string) => {
      setClosingPaneIds((ids) => (ids.includes(paneId) ? ids : [...ids, paneId]));
      setTimeout(() => {
        dispatch(closeMainPane(paneId));
        setClosingPaneIds((ids) => ids.filter((id) => id !== paneId));
      }, PANE_ANIMATION_MS);
    },
    [dispatch],
  );

  const openResourcePicker = useCallback(
    (resource: OpenResourceKind, placement: ResourcePlacement) => {
      setResourcePickerRequest({
        resource,
        paneId: tree.focusedPaneId,
        placement,
      });
    },
    [tree.focusedPaneId],
  );

  const placeResource = useCallback((resourceId: string) => {
    const request = resourcePickerRequest;
    if (!request) return;
    if (request.placement === 'replace') {
      dispatch(assignMainPaneAgent({ paneId: request.paneId, agentInstanceId: resourceId }));
    } else {
      dispatch(splitMainPane({
        targetPaneId: request.paneId,
        direction: request.placement,
        agentInstanceId: resourceId,
      }));
    }
    setResourcePickerRequest(null);
  }, [dispatch, resourcePickerRequest]);

  const openNewLauncher = useCallback((launchIntent: LauncherIntent, placement: ResourcePlacement) => {
    if (placement === 'replace') {
      dispatch(assignMainPaneAgent({
        paneId: tree.focusedPaneId,
        agentInstanceId: NEW_PANE_AGENT_ID,
        launchIntent,
      }));
    } else {
      dispatch(splitMainPane({
        targetPaneId: tree.focusedPaneId,
        direction: placement,
        launchIntent,
      }));
    }
  }, [dispatch, tree.focusedPaneId]);

  const resourceActions: AppAction[] = LOCAL_RESOURCE_CHORDS.map((chord) => ({
    id: chord.id,
    title: chord.title,
    category: 'Workspace',
    sequence: chord.sequence,
    run: () => {
      if (chord.resource) openResourcePicker(chord.resource, chord.placement);
      else if (chord.launchIntent) openNewLauncher(chord.launchIntent, chord.placement);
    },
  }));
  const paneResizeActions: AppAction[] = ([
    { key: 'h', change: 'narrower' as const, title: 'Narrow focused pane' },
    { key: 'j', change: 'taller' as const, title: 'Make focused pane taller' },
    { key: 'k', change: 'shorter' as const, title: 'Make focused pane shorter' },
    { key: 'l', change: 'wider' as const, title: 'Widen focused pane' },
  ]).map((item) => ({
    id: `workspace.resize-${item.change}`,
    title: item.title,
    category: 'Workspace',
    sequence: ['s', 'r', item.key],
    isEnabled: () => auxFocused
      ? (item.change === 'narrower' || item.change === 'wider') && auxShown
      : canResizeFocusedMainPane(tree, item.change),
    run: () => {
      if (auxFocused) {
        if (item.change === 'narrower') dispatch(setAuxWidth((auxWidth ?? AUX_DEFAULT_WIDTH) - 40));
        if (item.change === 'wider') dispatch(setAuxWidth((auxWidth ?? AUX_DEFAULT_WIDTH) + 40));
        return;
      }
      dispatch(resizeFocusedMainPane(item.change));
    },
  }));
  const paneExchangeActions: AppAction[] = ([
    { key: 'h', direction: 'left' as const, title: 'Exchange pane left' },
    { key: 'j', direction: 'down' as const, title: 'Exchange pane down' },
    { key: 'k', direction: 'up' as const, title: 'Exchange pane up' },
    { key: 'l', direction: 'right' as const, title: 'Exchange pane right' },
  ]).map((item) => ({
    id: `workspace.exchange-${item.direction}`,
    title: item.title,
    category: 'Workspace',
    sequence: ['s', 'e', item.key],
    isEnabled: () => !auxFocused && Boolean(getDirectionalPaneId(mainPaneLayouts, tree.focusedPaneId, item.direction)),
    run: () => {
      const target = getDirectionalPaneId(mainPaneLayouts, tree.focusedPaneId, item.direction);
      if (target) dispatch(swapMainPanes({ paneIdA: tree.focusedPaneId, paneIdB: target }));
    },
  }));

  useRegisterActions([
    ...resourceActions,
    ...paneResizeActions,
    ...paneExchangeActions,
    {
      id: 'workspace.resize-equalize',
      title: auxFocused ? 'Reset auxiliary pane width' : 'Equalize Main pane sizes',
      category: 'Workspace',
      sequence: ['s', 'r', '='],
      isEnabled: () => auxFocused ? auxShown : mainPaneIds.length > 1,
      run: () => {
        if (auxFocused) dispatch(setAuxWidth(null));
        else dispatch(equalizeMainPanes());
      },
    },
    {
      id: 'workspace.close-pane',
      title: 'Close focused pane',
      category: 'Workspace',
      sequence: ['s', 'x'],
      isEnabled: () => leafIds.length > 1,
      run: () => {
        if (leafIds.length > 1) closePane(tree.focusedPaneId);
      },
    },
    {
      id: 'workspace.focus-next-pane',
      title: 'Focus next pane',
      category: 'Workspace',
      sequence: ['s', 'w'],
      isEnabled: () => mainPaneIds.length > 1,
      run: () => {
        const nextPaneId = getNextPaneId(mainPaneIds, tree.focusedPaneId);
        if (nextPaneId) dispatch(setFocusedMainPane(nextPaneId));
      },
    },
    {
      id: 'workspace.focus-pane-left',
      title: 'Focus pane left',
      category: 'Workspace',
      sequence: ['s', 'h'],
      isEnabled: () => Boolean(getDirectionalPaneId(mainPaneLayouts, tree.focusedPaneId, 'left')),
      run: () => {
        const paneId = getDirectionalPaneId(mainPaneLayouts, tree.focusedPaneId, 'left');
        if (paneId) dispatch(setFocusedMainPane(paneId));
      },
    },
    {
      id: 'workspace.focus-pane-right',
      title: 'Focus pane right',
      category: 'Workspace',
      sequence: ['s', 'l'],
      isEnabled: () => Boolean(getDirectionalPaneId(mainPaneLayouts, tree.focusedPaneId, 'right')),
      run: () => {
        const paneId = getDirectionalPaneId(mainPaneLayouts, tree.focusedPaneId, 'right');
        if (paneId) dispatch(setFocusedMainPane(paneId));
      },
    },
    {
      id: 'workspace.focus-pane-up',
      title: 'Focus pane above',
      category: 'Workspace',
      sequence: ['s', 'k'],
      isEnabled: () => Boolean(getDirectionalPaneId(mainPaneLayouts, tree.focusedPaneId, 'up')),
      run: () => {
        const paneId = getDirectionalPaneId(mainPaneLayouts, tree.focusedPaneId, 'up');
        if (paneId) dispatch(setFocusedMainPane(paneId));
      },
    },
    {
      id: 'workspace.focus-pane-down',
      title: 'Focus pane below',
      category: 'Workspace',
      sequence: ['s', 'j'],
      isEnabled: () => Boolean(getDirectionalPaneId(mainPaneLayouts, tree.focusedPaneId, 'down')),
      run: () => {
        const paneId = getDirectionalPaneId(mainPaneLayouts, tree.focusedPaneId, 'down');
        if (paneId) dispatch(setFocusedMainPane(paneId));
      },
    },
    {
      id: 'workspace.focus-input',
      title: 'Focus active pane input',
      category: 'Workspace',
      sequence: ['s', 'i'],
      run: () => focusPaneInput(tree.focusedPaneId),
    },
    {
      id: 'workspace.toggle-aux-pane',
      title: 'Toggle auxiliary pane',
      category: 'Workspace',
      sequence: ['s', 'a'],
      isEnabled: () => Boolean(auxTreeId),
      run: toggleAux,
    },
    {
      id: 'workspace.toggle-aux-tasks',
      title: 'Toggle Tasks in auxiliary pane',
      category: 'Workspace',
      sequence: ['s', 'a', 't'],
      isEnabled: () => Boolean(auxTreeId && isAgentPaneId(focusedAgentId) && ctx.isResolved && ctx.chainId),
      run: () => toggleAuxContent({ type: 'tasks' }),
    },
    {
      id: 'workspace.toggle-aux-chat-overview',
      title: 'Toggle Chat overview in auxiliary pane',
      category: 'Workspace',
      sequence: ['s', 'a', 'c'],
      isEnabled: () => Boolean(auxTreeId && isAgentPaneId(focusedAgentId) && ctx.isResolved && ctx.chainId),
      run: () => toggleAuxContent({ type: 'chainOverview' }),
    },
    {
      id: 'workspace.toggle-aux-agent-pty',
      title: 'Toggle Agent PTY in auxiliary pane',
      category: 'Workspace',
      sequence: ['s', 'a', 'a'],
      isEnabled: () => Boolean(auxTreeId && isAgentPaneId(focusedAgentId)),
      run: () => toggleAuxContent({ type: 'agentPty', agentInstanceId: focusedAgentId }),
    },
    {
      id: 'workspace.toggle-maximize',
      title: 'Toggle focused pane maximization',
      category: 'Workspace',
      sequence: ['s', 'm'],
      run: () => dispatch(toggleMaximizeMainPane(tree.focusedPaneId)),
    },
  ]);

  const topRightSpacer = (
    <div aria-hidden="true" data-debug-id="workspace-top-right-spacer" className="shrink-0" style={{ width: Math.max(0, topRightWidth - 12) }} />
  );

  const renderPane = useCallback(
    ({ paneId, value, isFocused, isSinglePane, isTopLeftMost, isTopRightMost }: RenderPaneProps<MainPaneValue>) => {
      const agentId = value.agentInstanceId;
      const isPicker = !isRealAgentId(agentId);
      return (
        <MainPaneFrame
          paneId={paneId}
          isFocused={isFocused}
          isSinglePane={isSinglePane}
          isPicker={isPicker}
          isMobile={isMobile}
          onFocus={focusPane}
          onClose={closePane}
          isClosing={closingPaneIds.includes(paneId)}
          isActive={showActiveBorder && isFocused && !auxFocused}
          headerLeading={isTopLeftMost ? leading : null}
          headerTrailing={isTopRightMost && !dockOccupiesTopRight ? topRightSpacer : null}
        >
          {isPicker ? (
            // Jetski: a '_new' pane renders the new-conversation (home) view.
            // Launching or picking a task chain fills THIS pane.
            <HomePage
              pane={{
                launchIntent: value.launchIntent,
                onOpenAgent: (agentInstanceId) =>
                  dispatch(assignMainPaneAgent({ paneId, agentInstanceId })),
              }}
            />
          ) : isShellPaneId(agentId) ? (
            // SH-1: a Main pane bound to an interactive shell.
            <ShellMainPane
              key={agentId}
              sessionId={agentId}
              isMobile={isMobile}
              isFocused={isFocused}
              openIds={mainAgentIds.filter((id) => id !== agentId)}
              onSwitch={(nextId) => dispatch(assignMainPaneAgent({ paneId, agentInstanceId: nextId }))}
              onClose={() => closePane(paneId)}
              headerLeading={isTopLeftMost ? leading : null}
              headerEnd={isTopRightMost && !dockOccupiesTopRight ? topRightSpacer : null}
            />
          ) : (
            <AgentChatPane
              key={agentId}
              agentInstanceId={agentId}
              paneId={paneId}
              focusMessageId={agentId === routeAgentInstanceId ? focusMessageId : undefined}
              isSinglePane={isSinglePane}
              isMobile={isMobile}
              projectVcsEnabled={ctx.projectVcsEnabled}
              onOpenAuxTab={(content, title) => openAuxFromPane(agentId, content, title)}
              onSwitchAgent={(nextAgentId) =>
                dispatch(assignMainPaneAgent({ paneId, agentInstanceId: nextAgentId }))
              }
              onOpenAgentInSplit={(nextAgentId, direction) =>
                dispatch(splitMainPane({ targetPaneId: paneId, direction, agentInstanceId: nextAgentId }))
              }
              onSplitPane={(direction) => dispatch(splitMainPane({ targetPaneId: paneId, direction }))}
              onReplaceWithNew={() =>
                dispatch(assignMainPaneAgent({ paneId, agentInstanceId: NEW_PANE_AGENT_ID }))
              }
              onClosePane={() => closePane(paneId)}
              isFocusedPane={isFocused}
              headerLeading={isTopLeftMost ? leading : null}
              headerEnd={isTopRightMost && !dockOccupiesTopRight ? topRightSpacer : null}
            />
          )}
        </MainPaneFrame>
      );
    },
    [
      auxFocused,
      showActiveBorder,
      closePane,
      closingPaneIds,
      dockOccupiesTopRight,
      leading,
      topRightSpacer,
      ctx.projectVcsEnabled,
      dispatch,
      focusMessageId,
      focusPane,
      isMobile,
      mainAgentIds,
      openAuxFromPane,
      routeAgentInstanceId,
      toggleAux,
    ],
  );

  const dropOverlay = useMemo(() => {
    if (!pendingDrop || typeof document === 'undefined') return null;
    const el = document.querySelector<HTMLElement>(`[data-main-pane-id="${pendingDrop.paneId}"]`);
    if (!el) return null;
    const rect = el.getBoundingClientRect();
    const pos = getOverlayPosition(rect, pendingDrop.direction);
    return (
      <div
        data-debug-id="workspace-drop-overlay"
        style={{
          position: 'fixed',
          top: rect.top + pos.top,
          left: rect.left + pos.left,
          width: pos.width,
          height: pos.height,
          zIndex: 50,
          pointerEvents: 'none',
        }}
        className="rounded-md border-2 border-accent bg-accent/15 transition-all duration-75"
      />
    );
  }, [pendingDrop]);

  const hideMain = auxOpen && isAuxMaximized && !isMobile;

  return (
    <div
      data-debug-id="workspace"
      data-aux-open={auxOpen ? 'true' : 'false'}
      className="relative flex h-full w-full min-h-0 min-w-0 flex-1 flex-col overflow-hidden bg-canvas"
    >
      <div className="relative flex min-h-0 min-w-0 flex-1 overflow-hidden">
        <div
          data-debug-id="workspace-main"
          onMouseDownCapture={() => setAuxFocused(false)}
          className={`relative min-h-0 min-w-0 flex-1 flex-col ${hideMain ? 'hidden' : 'flex'}`}
        >
          {!layoutReady ? null : isMobile ? (
            <MobileMainPager
              tree={tree}
              renderPane={renderPane}
              onFocusPane={focusPane}
              onSwipeLeftBoundary={hasAvailableAux ? openMobileAux : undefined}
              onSwipeRightBoundary={openMobileSidebar}
              totalPageCount={mobileMainContinuumPageCount}
            />
          ) : (
            <TilingContainer<MainPaneValue>
              treeState={tree}
              paneAttributeName="data-main-pane-id"
              paneDividers={true}
              renderPane={renderPane}
              onResizePane={(splitPaneId, ratio) => dispatch(resizeMainSplit({ splitPaneId, ratio }))}
              onFocusPane={focusPane}
              className="h-full w-full flex-1 min-h-0"
            />
          )}
          {dropOverlay}
        </div>
        {auxMounted && auxTreeId ? (
          <AuxDock
            treeId={auxTreeId}
            ctx={ctx}
            isMobile={isMobile}
            shown={auxShown}
            isActive={showActiveBorder && auxFocused}
            onActivate={() => setAuxFocused(true)}
            reserveLeft={leadingWidth}
            reserveRight={topRightWidth}
            mobileLeadingPageCount={mainPageCount}
            mobileTotalPageCount={mobileAuxContinuumPageCount}
          />
        ) : null}
      </div>
      <div
        ref={topRightRef}
        data-debug-id="workspace-top-right-cluster"
        className="absolute right-0 top-0 z-30 flex items-center gap-1 pl-1 pr-2"
        style={{ height: topChromeHeight(isMobile) }}
      >
        {trailing}
        {auxToggle}
      </div>
      <ConversationSelectorModal
        open={resourcePickerRequest?.resource === 'conversation'}
        onClose={() => setResourcePickerRequest(null)}
        onSelectConversation={placeResource}
      />
      <TaskChainSelectorModal
        open={resourcePickerRequest?.resource === 'task-chain'}
        onClose={() => setResourcePickerRequest(null)}
        onSelectChain={(chain) => {
          if (chain.coordinatorAgentInstanceId) placeResource(chain.coordinatorAgentInstanceId);
          else setResourcePickerRequest(null);
        }}
      />
      <RunningShellSelectorModal
        open={resourcePickerRequest?.resource === 'shell'}
        onClose={() => setResourcePickerRequest(null)}
        onSelectShell={placeResource}
      />
    </div>
  );
}

export default Workspace;
