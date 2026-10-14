import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Icon } from '@ui';
import { TilingContainer, getOverlayPosition, type RenderPaneProps } from '../../tiling';
import {
  NEW_PANE_AGENT_ID,
  assignMainPaneAgent,
  closeMainPane,
  isRealAgentId,
  resizeMainSplit,
  selectFocusedMainAgentId,
  selectMainAgentIds,
  selectMainLeafIds,
  selectMainTree,
  setFocusedMainPane,
  setLayoutFromUrl,
  splitMainPane,
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
  toggleAuxPane,
} from '../../store/auxPanesSlice';
import {
  hydrateWorkspaceChrome,
  selectAuxWidth,
  selectIsAuxMaximized,
  selectPendingSplitDrop,
} from '../../store/workspaceChromeSlice';
import { resolveLegacyPanelToAuxContent, type AuxContent } from '../../store/auxTabId';
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
import { MainPaneFrame } from './MainPaneFrame';
import { MobileMainPager } from './MobileMainPager';
import HomePage from '../home/HomePage';
import { PANE_ANIMATION_MS, TOP_CHROME_HEIGHT } from '../shell/shellChrome';

export interface WorkspaceProps {
  focusMessageId?: string;
  isMobile?: boolean;
  /** Hidden sidebar: spacer reserving the fixed top-left cluster in the top-left pane's header. */
  leading?: React.ReactNode;
  /** Hidden sidebar: update-available badge, in the fixed top-right cluster. */
  trailing?: React.ReactNode;
}

function readRoute(): { pathname: string; search: string } {
  return { pathname: getRoutePathname(), search: getRouteSearch() };
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
export function Workspace({ focusMessageId, isMobile = false, leading, trailing }: WorkspaceProps) {
  const dispatch = useDispatch();
  const tree = useSelector(selectMainTree);
  const focusedAgentId = useSelector(selectFocusedMainAgentId);
  const mainAgentIds = useSelector(selectMainAgentIds);
  const leafIds = useSelector(selectMainLeafIds);
  const loc = useRouteLocation();
  const route = useMemo(() => parseConversationIdsFromRoute(loc.pathname, loc.search), [loc]);
  const routeAgentInstanceId = route.focused || '';
  const auxTreeId = useSelector(selectCurrentAuxTreeId);
  const auxPane = useSelector((state: any) => selectAuxPane(state, auxTreeId));
  const auxPanesState = useSelector(selectAuxPanesState);
  const auxWidth = useSelector(selectAuxWidth);
  const isAuxMaximized = useSelector(selectIsAuxMaximized);
  const pendingDrop = useSelector(selectPendingSplitDrop);

  // Aux context agent = the focused Main pane's agent (single or split view).
  const ctxAgentId = auxTreeId?.agentInstanceId || '';
  const ctx = useAgentAuxContext(ctxAgentId);
  const hasChain = ctx.isResolved ? Boolean(ctx.chainId) : true;
  const auxOpen = Boolean(auxTreeId && auxPane?.isPaneOpen);

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
      isRealAgentId(prevFocused) &&
      isRealAgentId(focused) &&
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
      className={`grid h-8 w-8 shrink-0 place-items-center rounded-lg transition-colors disabled:cursor-not-allowed disabled:opacity-40 ${
        auxOpen ? 'bg-accent/15 text-accent' : 'text-muted hover:bg-neutral-soft hover:text-primary'
      }`}
    >
      <Icon name="panel-right" size={18} />
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
          headerLeading={isTopLeftMost ? leading : null}
          headerTrailing={isTopRightMost && !dockOccupiesTopRight ? topRightSpacer : null}
        >
          {isPicker ? (
            // Jetski: a '_new' pane renders the new-conversation (home) view.
            // Launching or picking a task chain fills THIS pane.
            <HomePage
              pane={{
                onOpenAgent: (agentInstanceId) =>
                  dispatch(assignMainPaneAgent({ paneId, agentInstanceId })),
              }}
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
          className={`relative min-h-0 min-w-0 flex-1 flex-col ${hideMain ? 'hidden' : 'flex'}`}
        >
          {!layoutReady ? null : isMobile ? (
            <MobileMainPager tree={tree} renderPane={renderPane} onFocusPane={focusPane} />
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
          <AuxDock treeId={auxTreeId} ctx={ctx} isMobile={isMobile} shown={auxShown} reserveRight={topRightWidth} />
        ) : null}
      </div>
      <div
        ref={topRightRef}
        data-debug-id="workspace-top-right-cluster"
        className="absolute right-0 top-0 z-30 flex items-center gap-1 pl-1 pr-2"
        style={{ height: TOP_CHROME_HEIGHT }}
      >
        {trailing}
        {auxToggle}
      </div>
    </div>
  );
}

export default Workspace;
