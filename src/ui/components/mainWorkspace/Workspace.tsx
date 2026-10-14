import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
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
import { NewChatPanePicker } from './NewChatPanePicker';

export interface WorkspaceProps {
  focusMessageId?: string;
  isMobile?: boolean;
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
export function Workspace({ focusMessageId, isMobile = false }: WorkspaceProps) {
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
  const closePane = useCallback((paneId: string) => dispatch(closeMainPane(paneId)), [dispatch]);

  const renderPane = useCallback(
    ({ paneId, value, isFocused, isSinglePane }: RenderPaneProps<MainPaneValue>) => {
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
        >
          {isPicker ? (
            <NewChatPanePicker
              paneId={paneId}
              openConversationIds={mainAgentIds}
              onSelect={(selection) =>
                dispatch(assignMainPaneAgent({ paneId, agentInstanceId: selection.agentInstanceId }))
              }
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
              isAuxOpen={auxOpen}
              onToggleAux={auxTreeId ? toggleAux : undefined}
            />
          )}
        </MainPaneFrame>
      );
    },
    [
      auxOpen,
      auxTreeId,
      closePane,
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
      className="relative flex h-full w-full min-h-0 min-w-0 flex-1 overflow-hidden bg-canvas"
    >
      <div
        data-debug-id="workspace-main"
        className={`relative min-h-0 min-w-0 flex-1 flex-col ${hideMain ? 'hidden' : 'flex'}`}
      >
        {isMobile ? (
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
      {auxOpen && auxTreeId ? <AuxDock treeId={auxTreeId} ctx={ctx} isMobile={isMobile} /> : null}
    </div>
  );
}

export default Workspace;
