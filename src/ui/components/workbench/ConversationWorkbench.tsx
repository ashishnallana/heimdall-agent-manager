import React, { useCallback, useEffect, useRef } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { TilingContainer } from '../../tiling/TilingContainer';
import { getContentPaneIds } from '../../tiling/paneTreeState';
import { getSplitDirection, resolvePaneTarget } from '../../tiling/dragUtils';
import type { RenderPaneProps, SplitDirection } from '../../tiling/types';
import {
  buildWorkbenchTabId,
  resolveLegacyPanelToSurfaceKind,
  type WorkbenchSurfaceKind,
  type WorkbenchTabState,
} from '../../store/workbenchTabId';
import {
  closeWorkbenchPane,
  closeWorkbenchTab,
  ensureWorkspaceInitialized,
  hydrateWorkspaceWorkbench,
  moveWorkbenchTabToPane,
  openNewTabView,
  openOrFocusWorkbenchTab,
  replaceNewTabWithSurface,
  resizeWorkbenchSplit,
  selectActiveWorkspaceKey,
  selectWorkspaceWorkbench,
  setActiveWorkbenchTab,
  setActiveWorkspaceKey,
  setFocusedWorkbenchPane,
  setWorkbenchPendingDropTarget,
  splitWorkbenchPane,
  splitWorkbenchPaneWithTab,
  toggleMaximizeWorkbenchPane,
  updateWorkbenchTabParams,
  type TabbedPaneState,
} from '../../store/workbenchSlice';
import {
  readWorkbenchWorkspaceState,
  writeWorkbenchWorkspaceState,
} from '../../utils/clientPersistence';
import { WorkbenchPaneView } from './WorkbenchPaneView';

export interface ConversationWorkbenchProps {
  workspaceKey: string;
  primaryAgentInstanceId: string;
  primaryAgentTitle?: string;
  chainId?: string;
  projectId?: string;
  projectName?: string;
  bridgeId?: string;
  defaultCwd?: string;
  projectVcsEnabled?: boolean;
  directories?: any[];
  members?: any[];
  focusMessageId?: string;
  initialPanelParam?: string | null;
  initialFilePathParam?: string | null;
  initialTaskIdParam?: string | null;
  isMobile?: boolean;
  onPublishComments?: (markdown: string) => Promise<boolean>;
  onOpenQuickOpen?: () => void;
}

export function ConversationWorkbench({
  workspaceKey,
  primaryAgentInstanceId,
  primaryAgentTitle,
  chainId,
  projectId,
  projectName,
  bridgeId,
  defaultCwd,
  projectVcsEnabled = true,
  directories,
  members,
  focusMessageId,
  initialPanelParam,
  initialFilePathParam,
  initialTaskIdParam,
  isMobile = false,
  onPublishComments,
  onOpenQuickOpen,
}: ConversationWorkbenchProps) {
  const dispatch = useDispatch();
  const rootRef = useRef<HTMLDivElement | null>(null);
  const effectiveWorkspaceKey = workspaceKey || primaryAgentInstanceId;

  const activeWorkspaceKey = useSelector(selectActiveWorkspaceKey);
  const workspaceState = useSelector((state: any) =>
    selectWorkspaceWorkbench(state, effectiveWorkspaceKey),
  );

  // Hydrate from localStorage or initialize default 1-pane layout on mount / workspaceKey change
  const hydratedKeysRef = useRef<Set<string>>(new Set());
  useEffect(() => {
    if (!effectiveWorkspaceKey) return;
    dispatch(setActiveWorkspaceKey(effectiveWorkspaceKey));

    if (!hydratedKeysRef.current.has(effectiveWorkspaceKey)) {
      hydratedKeysRef.current.add(effectiveWorkspaceKey);
      const persisted = readWorkbenchWorkspaceState(effectiveWorkspaceKey);
      if (persisted && persisted.rootPaneId && persisted.panes) {
        dispatch(
          hydrateWorkspaceWorkbench({
            workspaceKey: effectiveWorkspaceKey,
            tree: persisted as any,
          }),
        );
      } else {
        dispatch(
          ensureWorkspaceInitialized({
            workspaceKey: effectiveWorkspaceKey,
            defaultAgentInstanceId: primaryAgentInstanceId,
            defaultTitle: primaryAgentTitle,
          }),
        );
      }
    } else {
      dispatch(
        ensureWorkspaceInitialized({
          workspaceKey: effectiveWorkspaceKey,
          defaultAgentInstanceId: primaryAgentInstanceId,
          defaultTitle: primaryAgentTitle,
        }),
      );
    }
  }, [dispatch, effectiveWorkspaceKey, primaryAgentInstanceId, primaryAgentTitle]);

  // Persist tree changes to localStorage
  useEffect(() => {
    if (!effectiveWorkspaceKey || !workspaceState?.tree) return;
    writeWorkbenchWorkspaceState(effectiveWorkspaceKey, workspaceState.tree);
  }, [effectiveWorkspaceKey, workspaceState?.tree]);

  // Deep-link support for legacy `?panel=files|vcs|chain|tasks` URL parameter
  const consumedPanelRef = useRef<string | null>(null);
  useEffect(() => {
    if (!initialPanelParam || !effectiveWorkspaceKey) return;
    const key = `${effectiveWorkspaceKey}:${initialPanelParam}:${initialFilePathParam || ''}:${initialTaskIdParam || ''}`;
    if (consumedPanelRef.current === key) return;
    consumedPanelRef.current = key;

    const surfaceKind = resolveLegacyPanelToSurfaceKind(initialPanelParam);
    if (!surfaceKind) return;

    dispatch(
      openOrFocusWorkbenchTab({
        workspaceKey: effectiveWorkspaceKey,
        tab: {
          kind: surfaceKind,
          openFilePath: initialFilePathParam || null,
          initialFilePath: initialFilePathParam || null,
          focusTaskId: initialTaskIdParam || undefined,
        },
      }),
    );
  }, [
    dispatch,
    effectiveWorkspaceKey,
    initialFilePathParam,
    initialPanelParam,
    initialTaskIdParam,
  ]);

  // Global keyboard shortcuts coordinated at the Workbench level (Cmd+P, Cmd+Shift+F, Cmd+\)
  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (!effectiveWorkspaceKey) return;
      if (activeWorkspaceKey && activeWorkspaceKey !== effectiveWorkspaceKey) return;
      const isMod = event.metaKey || event.ctrlKey;
      if (!isMod) return;

      // Cmd/Ctrl + P -> Open/focus ProjectFilesPanel with Command Palette
      if (event.key.toLowerCase() === 'p' && !event.shiftKey && !event.altKey) {
        event.preventDefault();
        dispatch(
          openOrFocusWorkbenchTab({
            workspaceKey: effectiveWorkspaceKey,
            tab: {
              kind: 'files',
              title: 'Project Files',
              initialOpenCommandPalette: true,
            },
          }),
        );
        return;
      }

      // Cmd/Ctrl + Shift + F is handled by the capture-phase listener below so it
      // still focuses the files tab when a mounted ProjectFilesPanel stops propagation.
      if (event.key.toLowerCase() === 'f' && event.shiftKey && !event.altKey) {
        return;
      }

      // Cmd/Ctrl + \ -> Split focused workbench pane right
      if (event.key === '\\' && !event.altKey) {
        event.preventDefault();
        const focusedPaneId = workspaceState?.tree?.focusedPaneId;
        if (focusedPaneId) {
          dispatch(
            splitWorkbenchPane({
              workspaceKey: effectiveWorkspaceKey,
              targetPaneId: focusedPaneId,
              direction: 'right',
            }),
          );
        }
      }
    }

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [
    activeWorkspaceKey,
    dispatch,
    effectiveWorkspaceKey,
    workspaceState?.tree?.focusedPaneId,
  ]);

  // Cmd/Ctrl + Shift + F -> Open/focus ProjectFilesPanel with Search in Files.
  // Registered in the capture phase because a mounted ProjectFilesPanel also
  // listens in capture and calls stopPropagation, which would otherwise block a
  // bubble-phase listener from focusing the (possibly hidden) files tab.
  useEffect(() => {
    function handleSearchKeyDown(event: KeyboardEvent) {
      if (!effectiveWorkspaceKey) return;
      if (activeWorkspaceKey && activeWorkspaceKey !== effectiveWorkspaceKey) return;
      if (!(event.metaKey || event.ctrlKey)) return;
      if (event.key.toLowerCase() !== 'f' || !event.shiftKey || event.altKey) return;
      event.preventDefault();
      dispatch(
        openOrFocusWorkbenchTab({
          workspaceKey: effectiveWorkspaceKey,
          tab: {
            kind: 'files',
            title: 'Project Files',
            initialOpenSearchInFiles: true,
          },
        }),
      );
    }

    window.addEventListener('keydown', handleSearchKeyDown, true);
    return () => window.removeEventListener('keydown', handleSearchKeyDown, true);
  }, [activeWorkspaceKey, dispatch, effectiveWorkspaceKey]);

  // Pointer-based tab drag-and-drop to move tab between panes or split a target pane
  const handleTabDragStart = useCallback(
    (sourcePaneId: string, tabId: string, startEvent: React.PointerEvent) => {
      const startX = startEvent.clientX;
      const startY = startEvent.clientY;
      let dragging = false;
      const tree = workspaceState?.tree;

      const resolveScopedTarget = (clientX: number, clientY: number) => {
        const target = resolvePaneTarget(clientX, clientY);
        if (!target) return null;
        if (!Boolean(tree?.panes?.[target.paneId])) return null;
        if (rootRef.current) {
          const matchedEl = Array.from(
            rootRef.current.querySelectorAll<HTMLElement>('[data-pane-id]'),
          ).find((el) => el.getAttribute('data-pane-id') === target.paneId);
          if (!matchedEl || !rootRef.current.contains(matchedEl)) return null;
        }
        return target;
      };

      const onPointerMove = (moveEvent: PointerEvent) => {
        const dx = moveEvent.clientX - startX;
        const dy = moveEvent.clientY - startY;
        if (!dragging && Math.hypot(dx, dy) < 8) return;
        dragging = true;

        const target = resolveScopedTarget(moveEvent.clientX, moveEvent.clientY);
        if (!target) {
          dispatch(
            setWorkbenchPendingDropTarget({
              workspaceKey: effectiveWorkspaceKey,
              target: null,
            }),
          );
          return;
        }
        const relativeY = moveEvent.clientY - target.rect.top;
        if (relativeY <= 36 && target.paneId === sourcePaneId) {
          dispatch(
            setWorkbenchPendingDropTarget({
              workspaceKey: effectiveWorkspaceKey,
              target: null,
            }),
          );
          return;
        }
        const direction = getSplitDirection(target.rect, {
          x: moveEvent.clientX,
          y: moveEvent.clientY,
        });
        dispatch(
          setWorkbenchPendingDropTarget({
            workspaceKey: effectiveWorkspaceKey,
            target: { paneId: target.paneId, direction },
          }),
        );
      };

      const onPointerUp = (upEvent: PointerEvent) => {
        window.removeEventListener('pointermove', onPointerMove);
        window.removeEventListener('pointerup', onPointerUp);

        dispatch(
          setWorkbenchPendingDropTarget({
            workspaceKey: effectiveWorkspaceKey,
            target: null,
          }),
        );

        if (!dragging) return;
        const target = resolveScopedTarget(upEvent.clientX, upEvent.clientY);
        if (!target) return;

        // Check if dropped onto the tab strip header (top 36px of pane) -> merge/reorder tab in pane
        const relativeY = upEvent.clientY - target.rect.top;
        if (relativeY <= 36) {
          if (target.paneId === sourcePaneId) {
            dispatch(
              moveWorkbenchTabToPane({
                workspaceKey: effectiveWorkspaceKey,
                sourcePaneId,
                tabId,
                targetPaneId: sourcePaneId,
              }),
            );
            return;
          }
          dispatch(
            moveWorkbenchTabToPane({
              workspaceKey: effectiveWorkspaceKey,
              sourcePaneId,
              tabId,
              targetPaneId: target.paneId,
            }),
          );
          return;
        }

        const direction: SplitDirection = getSplitDirection(target.rect, {
          x: upEvent.clientX,
          y: upEvent.clientY,
        });
        dispatch(
          splitWorkbenchPaneWithTab({
            workspaceKey: effectiveWorkspaceKey,
            sourcePaneId,
            tabId,
            targetPaneId: target.paneId,
            direction,
          }),
        );
      };

      window.addEventListener('pointermove', onPointerMove);
      window.addEventListener('pointerup', onPointerUp);
    },
    [dispatch, effectiveWorkspaceKey, workspaceState?.tree],
  );

  const handleOpenInRightSplit = useCallback(
    (
      sourcePaneId: string,
      tab: Partial<WorkbenchTabState> & { kind: WorkbenchSurfaceKind },
    ) => {
      const tree = workspaceState?.tree;
      const targetTabId = buildWorkbenchTabId(tab);

      if (tree) {
        const contentIds = getContentPaneIds(tree);
        // 1. If a tab with that canonical tabId already exists in any pane, focus that pane & tab
        for (const candidatePaneId of contentIds) {
          const candidatePane = tree.panes[candidatePaneId];
          if (
            candidatePane &&
            candidatePane.kind === 'content' &&
            candidatePane.value.tabs.some((t) => t.id === targetTabId)
          ) {
            dispatch(
              openOrFocusWorkbenchTab({
                workspaceKey: effectiveWorkspaceKey,
                paneId: candidatePaneId,
                tab,
              }),
            );
            return;
          }
        }

        // 2. Otherwise, if another content pane (id !== sourcePaneId) already exists, open/focus there
        const secondaryPaneId = contentIds.find((id) => id !== sourcePaneId);
        if (secondaryPaneId) {
          dispatch(
            openOrFocusWorkbenchTab({
              workspaceKey: effectiveWorkspaceKey,
              paneId: secondaryPaneId,
              tab,
            }),
          );
          return;
        }
      }

      // 3. Otherwise (the chat pane is the only pane in the workspace), split right and open there
      dispatch(
        openOrFocusWorkbenchTab({
          workspaceKey: effectiveWorkspaceKey,
          paneId: sourcePaneId,
          tab,
          splitDirection: 'right',
        }),
      );
    },
    [dispatch, effectiveWorkspaceKey, workspaceState?.tree],
  );

  const renderPane = useCallback(
    ({ paneId, value, isFocused, isMaximized, isSinglePane }: RenderPaneProps<TabbedPaneState>) => {
      const pendingDrop =
        workspaceState?.pendingDropTarget?.paneId === paneId
          ? workspaceState.pendingDropTarget.direction
          : null;

      return (
        <WorkbenchPaneView
          paneId={paneId}
          pane={value}
          workspaceKey={effectiveWorkspaceKey}
          primaryAgentInstanceId={primaryAgentInstanceId}
          chainId={chainId}
          projectId={projectId}
          projectName={projectName}
          bridgeId={bridgeId}
          defaultCwd={defaultCwd}
          projectVcsEnabled={projectVcsEnabled}
          directories={directories}
          members={members}
          focusMessageId={focusMessageId}
          isFocused={isFocused}
          isMaximized={isMaximized}
          isSinglePane={isSinglePane}
          isMobile={isMobile}
          pendingDropDirection={pendingDrop}
          onFocusPane={() =>
            dispatch(
              setFocusedWorkbenchPane({
                workspaceKey: effectiveWorkspaceKey,
                paneId,
              }),
            )
          }
          onSelectTab={(tabId) =>
            dispatch(
              setActiveWorkbenchTab({
                workspaceKey: effectiveWorkspaceKey,
                paneId,
                tabId,
              }),
            )
          }
          onCloseTab={(tabId) =>
            dispatch(
              closeWorkbenchTab({
                workspaceKey: effectiveWorkspaceKey,
                paneId,
                tabId,
              }),
            )
          }
          onOpenNewTab={() =>
            dispatch(
              openNewTabView({
                workspaceKey: effectiveWorkspaceKey,
                paneId,
              }),
            )
          }
          onReplaceNewTab={(tab: Partial<WorkbenchTabState> & { kind: WorkbenchSurfaceKind }) =>
            dispatch(
              replaceNewTabWithSurface({
                workspaceKey: effectiveWorkspaceKey,
                paneId,
                tab,
              }),
            )
          }
          onOpenOrFocusTab={(tab: Partial<WorkbenchTabState> & { kind: WorkbenchSurfaceKind; splitDirection?: SplitDirection }) =>
            dispatch(
              openOrFocusWorkbenchTab({
                workspaceKey: effectiveWorkspaceKey,
                paneId,
                tab,
                splitDirection: tab.splitDirection,
              }),
            )
          }
          onOpenInRightSplit={(tab: Partial<WorkbenchTabState> & { kind: WorkbenchSurfaceKind }) =>
            handleOpenInRightSplit(paneId, tab)
          }
          onUpdateTabParams={(tabId, patch) =>
            dispatch(
              updateWorkbenchTabParams({
                workspaceKey: effectiveWorkspaceKey,
                paneId,
                tabId,
                patch,
              }),
            )
          }
          onSplitPane={(direction) =>
            dispatch(
              splitWorkbenchPane({
                workspaceKey: effectiveWorkspaceKey,
                targetPaneId: paneId,
                direction,
              }),
            )
          }
          onToggleMaximize={() =>
            dispatch(
              toggleMaximizeWorkbenchPane({
                workspaceKey: effectiveWorkspaceKey,
                paneId,
              }),
            )
          }
          onClosePane={() =>
            dispatch(
              closeWorkbenchPane({
                workspaceKey: effectiveWorkspaceKey,
                paneId,
              }),
            )
          }
          onTabDragStart={(tabId, e) => handleTabDragStart(paneId, tabId, e)}
          onPublishComments={onPublishComments}
          onOpenQuickOpen={onOpenQuickOpen}
        />
      );
    },
    [
      bridgeId,
      chainId,
      defaultCwd,
      directories,
      dispatch,
      effectiveWorkspaceKey,
      focusMessageId,
      handleOpenInRightSplit,
      handleTabDragStart,
      isMobile,
      members,
      onOpenQuickOpen,
      onPublishComments,
      primaryAgentInstanceId,
      projectId,
      projectName,
      projectVcsEnabled,
      workspaceState?.pendingDropTarget,
    ],
  );

  if (!workspaceState?.tree) {
    return (
      <div
        data-debug-id="conversation-workbench-initializing"
        className="flex h-full min-h-0 w-full flex-1 items-center justify-center bg-canvas text-xs text-muted"
      >
        Initializing workbench…
      </div>
    );
  }

  return (
    <div
      ref={rootRef}
      data-debug-id={`conversation-workbench-${effectiveWorkspaceKey}`}
      onMouseDownCapture={() => {
        if (activeWorkspaceKey !== effectiveWorkspaceKey) {
          dispatch(setActiveWorkspaceKey(effectiveWorkspaceKey));
        }
      }}
      className="flex h-full min-h-0 w-full min-w-0 flex-1 flex-col overflow-hidden bg-canvas"
    >
      <TilingContainer<TabbedPaneState>
        treeState={workspaceState.tree}
        renderPane={renderPane}
        onResizePane={(sashId, ratio) =>
          dispatch(
            resizeWorkbenchSplit({
              workspaceKey: effectiveWorkspaceKey,
              splitPaneId: sashId,
              ratio,
            }),
          )
        }
        onFocusPane={(paneId) =>
          dispatch(
            setFocusedWorkbenchPane({
              workspaceKey: effectiveWorkspaceKey,
              paneId,
            }),
          )
        }
        paneDividers={true}
        className="h-full w-full flex-1 min-h-0"
      />
    </div>
  );
}

export default ConversationWorkbench;
