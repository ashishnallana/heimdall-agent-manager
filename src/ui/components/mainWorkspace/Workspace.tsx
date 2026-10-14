import React, { useCallback, useEffect, useMemo, useRef } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { TilingContainer, getOverlayPosition, type RenderPaneProps } from '../../tiling';
import {
  NEW_PANE_AGENT_ID,
  assignMainPaneAgent,
  closeMainPane,
  hydrateWorkspaceLayout,
  isRealAgentId,
  navigateMainToAgent,
  resizeMainSplit,
  selectFocusedMainAgentId,
  selectMainAgentIds,
  selectMainTree,
  setFocusedMainPane,
  splitMainPane,
  type MainPaneValue,
} from '../../store/workspaceLayoutSlice';
import {
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
import { buildRouteHash, getRouteSearch } from '../../utils/appLocation';
import {
  readAuxPanesState,
  readWorkspaceChromeState,
  readWorkspaceLayoutState,
  removeLegacyWorkbenchStorage,
  writeAuxPanesState,
  writeWorkspaceChromeState,
  writeWorkspaceLayoutState,
} from '../../utils/clientPersistence';
import { AuxDock } from '../aux/AuxDock';
import { useAgentAuxContext } from '../aux/useAgentAuxContext';
import { AgentChatPane } from '../workbench/AgentChatPane';
import { MainPaneFrame } from './MainPaneFrame';
import { MobileMainPager } from './MobileMainPager';
import { NewChatPanePicker } from './NewChatPanePicker';

export interface WorkspaceProps {
  /** Agent from the route (`/conversations/:agentInstanceId`). */
  routeAgentInstanceId: string;
  focusMessageId?: string;
  isMobile?: boolean;
}

function navigateHashToAgent(agentInstanceId: string) {
  if (typeof window === 'undefined') return;
  window.location.hash = buildRouteHash(`/conversations/${encodeURIComponent(agentInstanceId)}`, '');
}

/**
 * The ONE global Workspace for `/conversations/:agentInstanceId` (Jetski
 * `MainContent`): a Main split tree of agent chats plus ONE aux dock on the
 * right, toggled from the chat header's [≡].
 *
 * - The URL tracks the focused pane's agent; navigating to an agent not in Main
 *   replaces the focused pane's agent, an open one is focused (dedupe).
 * - Which aux strip is shown follows Jetski's useTreeId rule: one Main pane ->
 *   that agent's strip; two or more -> one shared strip that ignores focus.
 * - Layout and strips persist globally (never keyed by task chain).
 */
export function Workspace({ routeAgentInstanceId, focusMessageId, isMobile = false }: WorkspaceProps) {
  const dispatch = useDispatch();
  const tree = useSelector(selectMainTree);
  const focusedAgentId = useSelector(selectFocusedMainAgentId);
  const mainAgentIds = useSelector(selectMainAgentIds);
  const auxTreeId = useSelector(selectCurrentAuxTreeId);
  const auxPane = useSelector((state: any) => selectAuxPane(state, auxTreeId));
  const auxPanesState = useSelector(selectAuxPanesState);
  const auxWidth = useSelector(selectAuxWidth);
  const isAuxMaximized = useSelector(selectIsAuxMaximized);
  const pendingDrop = useSelector(selectPendingSplitDrop);

  // Aux context agent: the strip owner in single view; the focused agent in split view.
  const ctxAgentId =
    auxTreeId?.kind === 'agent'
      ? auxTreeId.agentInstanceId
      : isRealAgentId(focusedAgentId)
        ? focusedAgentId
        : mainAgentIds[0] || '';
  const ctx = useAgentAuxContext(ctxAgentId);
  const hasChain = ctx.isResolved ? Boolean(ctx.chainId) : true;
  const auxOpen = Boolean(auxTreeId && auxPane?.isPaneOpen);

  // 1. Hydrate the global workspace once (before the route sync below runs).
  const hydratedRef = useRef(false);
  useEffect(() => {
    if (hydratedRef.current) return;
    hydratedRef.current = true;
    const layout = readWorkspaceLayoutState();
    if (layout) dispatch(hydrateWorkspaceLayout(layout));
    const aux = readAuxPanesState();
    if (aux) dispatch(hydrateAuxPanes(aux));
    const chrome = readWorkspaceChromeState();
    if (chrome) dispatch(hydrateWorkspaceChrome(chrome));
    removeLegacyWorkbenchStorage();
  }, [dispatch]);

  // 2. Route -> Main: focus the agent if open, else put it in the focused pane.
  useEffect(() => {
    const id = (routeAgentInstanceId || '').trim();
    if (!id || id === NEW_PANE_AGENT_ID) return;
    dispatch(navigateMainToAgent(id));
  }, [dispatch, routeAgentInstanceId]);

  // 3. Main -> URL: the URL tracks the focused pane's agent.
  const prevFocusedRef = useRef<string | null>(null);
  useEffect(() => {
    if (prevFocusedRef.current === focusedAgentId) return;
    const first = prevFocusedRef.current === null;
    prevFocusedRef.current = focusedAgentId;
    if (first) return;
    if (isRealAgentId(focusedAgentId) && focusedAgentId !== routeAgentInstanceId) {
      navigateHashToAgent(focusedAgentId);
    }
  }, [focusedAgentId, routeAgentInstanceId]);

  // 4. Persist (global, not keyed by chain).
  useEffect(() => {
    if (hydratedRef.current) writeWorkspaceLayoutState(tree);
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
    if (!auxTreeId || auxPane || !ctx.isResolved) return;
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
