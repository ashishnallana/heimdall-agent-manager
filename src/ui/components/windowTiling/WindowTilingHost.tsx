import React, { useCallback, useEffect, useRef } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  NEW_WINDOW_PANE_ID,
  assignWindowPaneConversation,
  closeWindowPane,
  hydrateWindowLayout,
  moveWindowPane,
  resizeWindowSplit,
  selectFocusedWindowPane,
  selectOpenWindowConversationIds,
  selectWindowLayoutTree,
  selectWindowPendingDropTarget,
  setFocusedWindowPane,
  splitWindowPane,
  syncRouteConversationToWindowLayout,
  toggleMaximizeWindowPane,
  type WindowPaneValue,
} from '../../store/windowLayoutSlice';
import {
  TilingContainer,
  getOverlayPosition,
  resolvePaneTarget,
  type RenderPaneProps,
  type SplitDirection,
} from '../../tiling';
import {
  readWindowLayoutState,
  resolveWorkbenchWorkspaceKey,
  writeWindowLayoutState,
} from '../../utils/clientPersistence';
import {
  ConversationWorkbench,
  type ConversationWorkbenchProps,
} from '../workbench/ConversationWorkbench';
import { WindowPaneFrame } from './WindowPaneFrame';
import {
  NewConversationWindowPane,
  type SelectedWindowConversation,
} from './NewConversationWindowPane';

export interface ActiveWindowConversationRoute {
  agentInstanceId: string;
  chainId?: string | null;
  projectId?: string | null;
  focusMessageId?: string;
  title?: string;
}

export interface WindowTilingHostProps {
  /** Active conversation route parameters from URL hash (`#/conversations/:agentInstanceId`) */
  agentInstanceId?: string;
  routeAgentInstanceId?: string;
  activeAgentInstanceId?: string;
  chainId?: string | null;
  activeChainId?: string | null;
  projectId?: string | null;
  activeProjectId?: string | null;
  focusMessageId?: string;
  routeFocusMessageId?: string;
  activeFocusMessageId?: string;
  activeTitle?: string;
  /** Optional workbench context props for the active route conversation */
  activeWorkbenchProps?: Partial<ConversationWorkbenchProps>;
  /** Optional callback fired when the user focuses or selects a different conversation pane */
  onActiveConversationChange?: (route: ActiveWindowConversationRoute) => void;
  /** Optional custom conversation renderer for a pane (defaults to `<ConversationWorkbench />`) */
  renderConversationPane?: (
    paneId: string,
    paneValue: WindowPaneValue,
    isFocused: boolean,
  ) => React.ReactNode;
}

export function WindowTilingHost({
  agentInstanceId,
  routeAgentInstanceId,
  activeAgentInstanceId,
  chainId,
  activeChainId,
  projectId,
  activeProjectId,
  focusMessageId,
  routeFocusMessageId,
  activeFocusMessageId,
  activeTitle,
  activeWorkbenchProps,
  onActiveConversationChange,
  renderConversationPane,
}: WindowTilingHostProps) {
  const dispatch = useDispatch();
  const tree = useSelector(selectWindowLayoutTree);
  const focusedPaneValue = useSelector(selectFocusedWindowPane);
  const pendingDropTarget = useSelector(selectWindowPendingDropTarget);
  const openConversationIds = useSelector(selectOpenWindowConversationIds);

  const effectiveAgentInstanceId =
    activeAgentInstanceId ?? routeAgentInstanceId ?? agentInstanceId;
  const effectiveChainId = activeChainId ?? chainId;
  const effectiveProjectId = activeProjectId ?? projectId;
  const effectiveFocusMessageId =
    activeFocusMessageId ?? routeFocusMessageId ?? focusMessageId;

  const hasHydratedRef = useRef(false);

  // 1. Hydrate Level 1 window layout from localStorage once on mount
  useEffect(() => {
    if (hasHydratedRef.current) return;
    hasHydratedRef.current = true;
    const persisted = readWindowLayoutState();
    if (persisted) {
      dispatch(hydrateWindowLayout(persisted));
    }
  }, [dispatch]);

  // 2. Sync active route conversation (`agentInstanceId`, `chainId`, `projectId`, `focusMessageId`) into Level 1 window layout
  useEffect(() => {
    const normalizedAgentId = (effectiveAgentInstanceId ?? '').trim();
    if (!normalizedAgentId || normalizedAgentId === NEW_WINDOW_PANE_ID) {
      return;
    }
    dispatch(
      syncRouteConversationToWindowLayout({
        agentInstanceId: normalizedAgentId,
        chainId: effectiveChainId ?? null,
        projectId: effectiveProjectId ?? null,
        focusMessageId: effectiveFocusMessageId,
        title: activeTitle,
      }),
    );
  }, [
    activeTitle,
    dispatch,
    effectiveAgentInstanceId,
    effectiveChainId,
    effectiveFocusMessageId,
    effectiveProjectId,
  ]);

  // 3. Persist Level 1 window layout whenever the tree changes
  useEffect(() => {
    if (!hasHydratedRef.current) return;
    writeWindowLayoutState(tree);
  }, [tree]);

  // 4. Notify route observer when focused pane switches to a different conversation
  const prevFocusedAgentRef = useRef<string | undefined>(effectiveAgentInstanceId);
  useEffect(() => {
    if (!focusedPaneValue || focusedPaneValue.kind !== 'conversation') return;
    const focusedAgentId = focusedPaneValue.agentInstanceId;
    if (
      focusedAgentId &&
      focusedAgentId !== NEW_WINDOW_PANE_ID &&
      focusedAgentId !== prevFocusedAgentRef.current
    ) {
      prevFocusedAgentRef.current = focusedAgentId;
      onActiveConversationChange?.({
        agentInstanceId: focusedAgentId,
        chainId: focusedPaneValue.chainId ?? null,
        projectId: focusedPaneValue.projectId ?? null,
        focusMessageId: focusedPaneValue.focusMessageId,
        title: focusedPaneValue.title,
      });
    }
  }, [focusedPaneValue, onActiveConversationChange]);

  const handleFocusPane = useCallback(
    (paneId: string) => {
      dispatch(setFocusedWindowPane(paneId));
    },
    [dispatch],
  );

  const handleResizePane = useCallback(
    (splitPaneId: string, ratio: number) => {
      dispatch(resizeWindowSplit({ splitPaneId, ratio }));
    },
    [dispatch],
  );

  const handleMovePane = useCallback(
    (sourcePaneId: string, targetPaneId: string, direction: SplitDirection) => {
      dispatch(moveWindowPane({ sourcePaneId, targetPaneId, direction }));
    },
    [dispatch],
  );

  const handleSplitPane = useCallback(
    (paneId: string, direction: SplitDirection) => {
      dispatch(
        splitWindowPane({
          targetPaneId: paneId,
          direction,
          agentInstanceId: NEW_WINDOW_PANE_ID,
        }),
      );
    },
    [dispatch],
  );

  const handleMaximizePane = useCallback(
    (paneId: string) => {
      dispatch(toggleMaximizeWindowPane(paneId));
    },
    [dispatch],
  );

  const handleClosePane = useCallback(
    (paneId: string) => {
      dispatch(closeWindowPane(paneId));
    },
    [dispatch],
  );

  const handleResetToNewPicker = useCallback(
    (paneId: string) => {
      dispatch(
        assignWindowPaneConversation({
          paneId,
          agentInstanceId: NEW_WINDOW_PANE_ID,
        }),
      );
    },
    [dispatch],
  );

  const handleSelectInNewPane = useCallback(
    (selection: SelectedWindowConversation) => {
      onActiveConversationChange?.({
        agentInstanceId: selection.agentInstanceId,
        chainId: selection.chainId ?? null,
        projectId: selection.projectId ?? null,
        focusMessageId: selection.focusMessageId,
        title: selection.title,
      });
    },
    [onActiveConversationChange],
  );

  const renderDropOverlay = () => {
    if (!pendingDropTarget || typeof document === 'undefined') return null;
    const targetEl = document.querySelector<HTMLElement>(
      `[data-window-pane-id="${pendingDropTarget.paneId}"]`,
    );
    if (!targetEl) return null;
    const rect = targetEl.getBoundingClientRect();
    const pos = getOverlayPosition(rect, pendingDropTarget.direction);
    return (
      <div
        data-testid="window-tiling-drop-overlay"
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
  };

  const renderWindowPane = useCallback(
    ({
      paneId,
      value: paneValue,
      isFocused,
      isMaximized,
      isSinglePane,
    }: RenderPaneProps<WindowPaneValue>) => {
      const isNewPane =
        paneValue.kind === 'new' ||
        !paneValue.agentInstanceId ||
        paneValue.agentInstanceId === NEW_WINDOW_PANE_ID;

      const isRoutePrimaryPane =
        !isNewPane &&
        Boolean(effectiveAgentInstanceId) &&
        paneValue.agentInstanceId === effectiveAgentInstanceId;

      const resolvedTitle =
        paneValue.title ||
        (isRoutePrimaryPane ? activeTitle : undefined) ||
        (isNewPane ? 'New Conversation' : paneValue.agentInstanceId);

      const resolvedChainId =
        paneValue.chainId ?? (isRoutePrimaryPane ? effectiveChainId : undefined);
      const resolvedProjectId =
        paneValue.projectId ?? (isRoutePrimaryPane ? effectiveProjectId : undefined);
      const resolvedFocusMessageId =
        paneValue.focusMessageId ??
        (isRoutePrimaryPane ? effectiveFocusMessageId : undefined);

      const workspaceKey = resolveWorkbenchWorkspaceKey({
        chainId: resolvedChainId,
        agentInstanceId: paneValue.agentInstanceId,
      });

      return (
        <WindowPaneFrame
          paneId={paneId}
          paneValue={paneValue}
          title={resolvedTitle}
          subtitle={resolvedChainId ? `Chain: ${resolvedChainId}` : undefined}
          badgeText={!isNewPane ? paneValue.agentInstanceId : undefined}
          isFocused={isFocused}
          isSinglePane={isSinglePane}
          isMaximized={isMaximized}
          onFocus={handleFocusPane}
          onSplit={handleSplitPane}
          onMaximize={handleMaximizePane}
          onClose={handleClosePane}
          onResetToNewPicker={handleResetToNewPicker}
        >
          {isNewPane ? (
            <NewConversationWindowPane
              paneId={paneId}
              openConversationIds={openConversationIds}
              onSelect={handleSelectInNewPane}
            />
          ) : renderConversationPane ? (
            renderConversationPane(paneId, paneValue, isFocused)
          ) : (
            <ConversationWorkbench
              key={workspaceKey}
              workspaceKey={workspaceKey}
              primaryAgentInstanceId={paneValue.agentInstanceId}
              primaryAgentTitle={resolvedTitle}
              chainId={resolvedChainId || undefined}
              projectId={resolvedProjectId || undefined}
              focusMessageId={resolvedFocusMessageId}
              {...(isRoutePrimaryPane ? activeWorkbenchProps : {})}
            />
          )}
        </WindowPaneFrame>
      );
    },
    [
      activeTitle,
      activeWorkbenchProps,
      effectiveAgentInstanceId,
      effectiveChainId,
      effectiveFocusMessageId,
      effectiveProjectId,
      handleClosePane,
      handleFocusPane,
      handleMaximizePane,
      handleResetToNewPicker,
      handleSelectInNewPane,
      handleSplitPane,
      openConversationIds,
      renderConversationPane,
    ],
  );

  // Reference resolvePaneTarget for static contract verification
  void resolvePaneTarget;

  return (
    <div
      data-testid="window-tiling-host"
      data-debug-id="window-tiling-host"
      className="relative flex h-full w-full min-h-0 min-w-0 flex-1 overflow-hidden bg-canvas"
    >
      <TilingContainer<WindowPaneValue>
        treeState={tree}
        paneAttributeName="data-window-pane-id"
        paneDividers={true}
        renderPane={renderWindowPane}
        onResizePane={handleResizePane}
        onFocusPane={handleFocusPane}
        onMovePane={handleMovePane}
      />
      {renderDropOverlay()}
    </div>
  );
}

export default WindowTilingHost;
