import { createSlice, type PayloadAction } from '@reduxjs/toolkit';
import {
  calculatePaneLayouts,
  closePaneInTree,
  createPaneTreeState,
  equalizeTreeRatios,
  getContentPaneIds,
  movePaneInTree,
  PaneTreeState,
  resizeSplitInTree,
  SplitDirection,
  SplitInputDirection,
  splitPaneInTree,
  swapPanesInTree,
  toggleMaximizePaneInTree,
} from '../tiling';
import {
  buildWorkbenchTabId,
  createWorkbenchTabState,
  isWorkbenchSurfaceKind,
  NEW_TAB_ID,
  resolveLegacyPanelToSurfaceKind,
  WorkbenchTabSpec,
  WorkbenchTabState,
} from './workbenchTabId';

export interface TabbedPaneState {
  tabs: WorkbenchTabState[];
  activeTabId: string | undefined; // either a tab.id in `tabs` or `NEW_TAB_ID`
}

export interface WorkspaceWorkbenchState {
  workspaceKey: string;
  tree: PaneTreeState<TabbedPaneState>;
  pendingDropTarget?: { paneId: string; direction: SplitDirection } | null;
}

export interface WorkbenchRootState {
  workspaces: Record<string, WorkspaceWorkbenchState>;
  activeWorkspaceKey: string | null;
}

const initialState: WorkbenchRootState = {
  workspaces: {},
  activeWorkspaceKey: null,
};

function sanitizeTabList(tabs: WorkbenchTabState[] | undefined): WorkbenchTabState[] {
  if (!Array.isArray(tabs)) return [];
  const seen = new Set<string>();
  const clean: WorkbenchTabState[] = [];
  for (const raw of tabs) {
    if (!raw || typeof raw !== 'object' || !isWorkbenchSurfaceKind(raw.kind)) {
      continue;
    }
    const normalized = createWorkbenchTabState(raw);
    if (!normalized.id || normalized.id === NEW_TAB_ID || seen.has(normalized.id)) {
      continue;
    }
    seen.add(normalized.id);
    clean.push(normalized);
  }
  return clean;
}

export function createDefaultWorkspaceWorkbenchState(params: {
  workspaceKey: string;
  defaultAgentInstanceId?: string;
  defaultTitle?: string;
  initialPanel?: string | null;
}): WorkspaceWorkbenchState {
  const {
    workspaceKey,
    defaultAgentInstanceId,
    defaultTitle,
    initialPanel,
  } = params;

  const initialTabs: WorkbenchTabState[] = [];
  if (defaultAgentInstanceId) {
    initialTabs.push(
      createWorkbenchTabState({
        kind: 'agentChat',
        agentInstanceId: defaultAgentInstanceId,
        title: defaultTitle || 'Agent Chat',
      }),
    );
  }

  const tree = createPaneTreeState<TabbedPaneState>(
    {
      tabs: initialTabs,
      activeTabId: initialTabs[0]?.id ?? NEW_TAB_ID,
    },
    'pane-1',
  );

  const surfaceKind = resolveLegacyPanelToSurfaceKind(initialPanel);
  if (surfaceKind && surfaceKind !== 'agentChat') {
    const panelTab = createWorkbenchTabState({
      kind: surfaceKind,
      agentInstanceId:
        surfaceKind === 'agentPty' ? defaultAgentInstanceId : undefined,
    });
    splitPaneInTree(
      tree,
      'pane-1',
      'right',
      {
        tabs: [panelTab],
        activeTabId: panelTab.id,
      },
      'pane-2',
    );
  }

  return {
    workspaceKey,
    tree,
    pendingDropTarget: null,
  };
}

function getOrCreateWorkspace(
  state: WorkbenchRootState,
  workspaceKey: string | undefined,
  defaultAgentInstanceId?: string,
): WorkspaceWorkbenchState | undefined {
  const resolvedKey =
    (workspaceKey && workspaceKey.trim()) ||
    state.activeWorkspaceKey ||
    (defaultAgentInstanceId ? `agent:${defaultAgentInstanceId}` : 'default');

  if (!resolvedKey) {
    return undefined;
  }

  if (!state.workspaces[resolvedKey]) {
    state.workspaces[resolvedKey] = createDefaultWorkspaceWorkbenchState({
      workspaceKey: resolvedKey,
      defaultAgentInstanceId,
    });
  }
  if (!state.activeWorkspaceKey) {
    state.activeWorkspaceKey = resolvedKey;
  }
  return state.workspaces[resolvedKey];
}

function resolveTargetContentPaneId(
  tree: PaneTreeState<TabbedPaneState>,
  requestedPaneId?: string,
): string | undefined {
  if (requestedPaneId && tree.panes[requestedPaneId]?.kind === 'content') {
    return requestedPaneId;
  }
  if (tree.focusedPaneId && tree.panes[tree.focusedPaneId]?.kind === 'content') {
    return tree.focusedPaneId;
  }
  return getContentPaneIds(tree)[0];
}

function findPaneWithTab(
  tree: PaneTreeState<TabbedPaneState>,
  tabId: string,
): { paneId: string; tabIndex: number } | undefined {
  for (const paneId of getContentPaneIds(tree)) {
    const pane = tree.panes[paneId];
    if (pane && pane.kind === 'content') {
      const idx = pane.value.tabs.findIndex((t) => t.id === tabId);
      if (idx >= 0) {
        return { paneId, tabIndex: idx };
      }
    }
  }
  return undefined;
}

function upsertTabInPane(
  paneValue: TabbedPaneState,
  tabSpec: WorkbenchTabSpec,
): WorkbenchTabState {
  const tab = createWorkbenchTabState(tabSpec);
  const existingIdx = paneValue.tabs.findIndex((t) => t.id === tab.id);
  if (existingIdx >= 0) {
    const prev = paneValue.tabs[existingIdx];
    const merged: WorkbenchTabState = {
      ...prev,
      ...tab,
      title: tabSpec.title || prev.title || tab.title,
    };
    paneValue.tabs[existingIdx] = merged;
    paneValue.activeTabId = merged.id;
    return merged;
  }
  paneValue.tabs.push(tab);
  paneValue.activeTabId = tab.id;
  return tab;
}

const workbenchSlice = createSlice({
  name: 'workbench',
  initialState,
  reducers: {
    ensureWorkspaceInitialized(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        defaultAgentInstanceId: string;
        defaultTitle?: string;
        initialPanel?: string | null;
      }>,
    ) {
      const {
        workspaceKey,
        defaultAgentInstanceId,
        defaultTitle,
        initialPanel,
      } = action.payload;
      if (!workspaceKey) return;

      if (!state.workspaces[workspaceKey]) {
        state.workspaces[workspaceKey] = createDefaultWorkspaceWorkbenchState({
          workspaceKey,
          defaultAgentInstanceId,
          defaultTitle,
          initialPanel,
        });
      } else {
        const ws = state.workspaces[workspaceKey];
        const contentIds = getContentPaneIds(ws.tree);
        if (contentIds.length === 0) {
          state.workspaces[workspaceKey] = createDefaultWorkspaceWorkbenchState({
            workspaceKey,
            defaultAgentInstanceId,
            defaultTitle,
            initialPanel,
          });
        } else {
          if (defaultAgentInstanceId) {
            let matchedChatTab = false;
            for (const pid of contentIds) {
              const p = ws.tree.panes[pid];
              if (p && p.kind === 'content') {
                const found = p.value.tabs.find(
                  (t) =>
                    t.kind === 'agentChat' &&
                    t.agentInstanceId === defaultAgentInstanceId,
                );
                if (found) {
                  p.value.activeTabId = found.id;
                  matchedChatTab = true;
                  break;
                }
              }
            }
            if (!matchedChatTab) {
              for (const pid of contentIds) {
                const p = ws.tree.panes[pid];
                if (
                  p &&
                  p.kind === 'content' &&
                  p.value.tabs.length === 1 &&
                  p.value.tabs[0]?.kind === 'agentChat'
                ) {
                  const replaced = createWorkbenchTabState({
                    kind: 'agentChat',
                    agentInstanceId: defaultAgentInstanceId,
                    title: defaultTitle || p.value.tabs[0].title,
                  });
                  p.value.tabs[0] = replaced;
                  p.value.activeTabId = replaced.id;
                  break;
                }
              }
            }
          }
          if (initialPanel) {
            const surfaceKind = resolveLegacyPanelToSurfaceKind(initialPanel);
            if (surfaceKind) {
              const tabSpec: WorkbenchTabSpec = {
                kind: surfaceKind,
                agentInstanceId:
                  surfaceKind === 'agentChat' || surfaceKind === 'agentPty'
                    ? defaultAgentInstanceId
                    : undefined,
              };
              const tabId = buildWorkbenchTabId(tabSpec);
              const existing = findPaneWithTab(ws.tree, tabId);
              if (existing) {
                const pane = ws.tree.panes[existing.paneId];
                if (pane && pane.kind === 'content') {
                  pane.value.activeTabId = tabId;
                  ws.tree.focusedPaneId = existing.paneId;
                }
              } else {
                const targetId = resolveTargetContentPaneId(ws.tree);
                if (targetId) {
                  const newTab = createWorkbenchTabState(tabSpec);
                  splitPaneInTree(ws.tree, targetId, 'right', {
                    tabs: [newTab],
                    activeTabId: newTab.id,
                  });
                }
              }
            }
          }
        }
      }
      state.activeWorkspaceKey = workspaceKey;
    },

    setActiveWorkspaceKey(state, action: PayloadAction<string>) {
      state.activeWorkspaceKey = action.payload;
    },

    setFocusedWorkbenchPane(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        paneId: string;
      }>,
    ) {
      const ws = state.workspaces[action.payload.workspaceKey];
      if (!ws) return;
      if (ws.tree.panes[action.payload.paneId]?.kind === 'content') {
        ws.tree.focusedPaneId = action.payload.paneId;
      }
    },

    splitWorkbenchPane(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        targetPaneId?: string;
        direction: SplitInputDirection;
        initialTabs?: WorkbenchTabState[];
        initialActiveTabId?: string;
        newPaneId?: string;
      }>,
    ) {
      const {
        workspaceKey,
        targetPaneId,
        direction,
        initialTabs,
        initialActiveTabId,
        newPaneId,
      } = action.payload;
      const ws = getOrCreateWorkspace(state, workspaceKey);
      if (!ws) return;

      const resolvedTargetId = resolveTargetContentPaneId(
        ws.tree,
        targetPaneId,
      );
      if (!resolvedTargetId) return;

      const sanitizedTabs = sanitizeTabList(initialTabs);
      const activeTabId =
        initialActiveTabId &&
        (initialActiveTabId === NEW_TAB_ID ||
          sanitizedTabs.some((t) => t.id === initialActiveTabId))
          ? initialActiveTabId
          : sanitizedTabs.length > 0
            ? sanitizedTabs[0].id
            : NEW_TAB_ID;

      splitPaneInTree(
        ws.tree,
        resolvedTargetId,
        direction,
        {
          tabs: sanitizedTabs,
          activeTabId,
        },
        newPaneId,
      );
    },

    closeWorkbenchPane(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        paneId: string;
      }>,
    ) {
      const { workspaceKey, paneId } = action.payload;
      const ws = state.workspaces[workspaceKey];
      const targetPane = ws?.tree.panes[paneId];
      if (!ws || !targetPane || targetPane.kind !== 'content') return;

      const contentIds = getContentPaneIds(ws.tree);
      if (contentIds.length <= 1) {
        const onlyId = contentIds[0];
        const onlyPane = onlyId ? ws.tree.panes[onlyId] : undefined;
        if (onlyPane && onlyPane.kind === 'content') {
          onlyPane.value = {
            tabs: [],
            activeTabId: NEW_TAB_ID,
          };
          ws.tree.maximizedPaneId = null;
        }
        return;
      }

      closePaneInTree(ws.tree, paneId);
    },

    moveWorkbenchPane(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        sourcePaneId: string;
        targetPaneId: string;
        direction: SplitInputDirection;
      }>,
    ) {
      const { workspaceKey, sourcePaneId, targetPaneId, direction } =
        action.payload;
      const ws = state.workspaces[workspaceKey];
      if (!ws) return;
      movePaneInTree(ws.tree, sourcePaneId, targetPaneId, direction);
      ws.pendingDropTarget = null;
    },

    swapWorkbenchPanes(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        paneIdA: string;
        paneIdB: string;
      }>,
    ) {
      const { workspaceKey, paneIdA, paneIdB } = action.payload;
      const ws = state.workspaces[workspaceKey];
      if (!ws) return;
      swapPanesInTree(ws.tree, paneIdA, paneIdB);
    },

    resizeWorkbenchSplit(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        splitPaneId: string;
        ratio: number;
      }>,
    ) {
      const { workspaceKey, splitPaneId, ratio } = action.payload;
      const ws = state.workspaces[workspaceKey];
      if (!ws) return;
      resizeSplitInTree(ws.tree, splitPaneId, ratio);
    },

    equalizeWorkbenchPanes(
      state,
      action: PayloadAction<{
        workspaceKey: string;
      }>,
    ) {
      const ws = state.workspaces[action.payload.workspaceKey];
      if (!ws) return;
      equalizeTreeRatios(ws.tree);
    },

    toggleMaximizeWorkbenchPane(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        paneId?: string;
      }>,
    ) {
      const ws = state.workspaces[action.payload.workspaceKey];
      if (!ws) return;
      toggleMaximizePaneInTree(ws.tree, action.payload.paneId);
    },

    openNewTabView(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        paneId?: string;
      }>,
    ) {
      const { workspaceKey, paneId } = action.payload;
      const ws = getOrCreateWorkspace(state, workspaceKey);
      if (!ws) return;

      const targetId = resolveTargetContentPaneId(ws.tree, paneId);
      if (!targetId) return;

      const pane = ws.tree.panes[targetId];
      if (pane && pane.kind === 'content') {
        pane.value.activeTabId = NEW_TAB_ID;
        ws.tree.focusedPaneId = targetId;
      }
    },

    openOrFocusWorkbenchTab(
      state,
      action: PayloadAction<{
        workspaceKey?: string;
        paneId?: string;
        tab: WorkbenchTabSpec;
        splitDirection?: SplitInputDirection;
        replaceNewTab?: boolean;
      }>,
    ) {
      const {
        workspaceKey,
        paneId,
        tab: tabSpec,
        splitDirection,
      } = action.payload;

      const ws = getOrCreateWorkspace(
        state,
        workspaceKey,
        tabSpec.agentInstanceId,
      );
      if (!ws) return;

      const targetPaneId = resolveTargetContentPaneId(ws.tree, paneId);
      if (!targetPaneId) return;

      const targetPane = ws.tree.panes[targetPaneId];
      if (!targetPane || targetPane.kind !== 'content') return;

      const tabId = buildWorkbenchTabId(tabSpec);

      // If caller explicitly passed a target paneId or the target pane currently has NEW_TAB_ID active,
      // open/replace directly in that pane (unless splitDirection is explicitly requested on a non-empty pane).
      const targetIsShowingLauncher =
        targetPane.value.activeTabId === NEW_TAB_ID ||
        targetPane.value.tabs.length === 0;

      if (splitDirection && !targetIsShowingLauncher) {
        // Check if already open in another pane first when no explicit paneId was forced
        if (!paneId) {
          const existing = findPaneWithTab(ws.tree, tabId);
          if (existing) {
            const existingPane = ws.tree.panes[existing.paneId];
            if (existingPane && existingPane.kind === 'content') {
              upsertTabInPane(existingPane.value, tabSpec);
              ws.tree.focusedPaneId = existing.paneId;
              return;
            }
          }
        }
        const createdTab = createWorkbenchTabState(tabSpec);
        splitPaneInTree(ws.tree, targetPaneId, splitDirection, {
          tabs: [createdTab],
          activeTabId: createdTab.id,
        });
        return;
      }

      // If no specific paneId was requested and target is NOT showing NEW_TAB_ID launcher,
      // check if this canonical tab is already open in any pane in the workspace and focus it.
      if (!paneId && !targetIsShowingLauncher) {
        const existing = findPaneWithTab(ws.tree, tabId);
        if (existing) {
          const existingPane = ws.tree.panes[existing.paneId];
          if (existingPane && existingPane.kind === 'content') {
            upsertTabInPane(existingPane.value, tabSpec);
            ws.tree.focusedPaneId = existing.paneId;
            return;
          }
        }
      }

      // Upsert tab in targetPane and replace NEW_TAB_ID as activeTabId in-place
      upsertTabInPane(targetPane.value, tabSpec);
      ws.tree.focusedPaneId = targetPaneId;
    },

    replaceNewTabWithSurface(
      state,
      action: PayloadAction<{
        workspaceKey?: string;
        paneId?: string;
        tab: WorkbenchTabSpec;
      }>,
    ) {
      const { workspaceKey, paneId, tab: tabSpec } = action.payload;
      const ws = getOrCreateWorkspace(
        state,
        workspaceKey,
        tabSpec.agentInstanceId,
      );
      if (!ws) return;

      const targetPaneId = resolveTargetContentPaneId(ws.tree, paneId);
      if (!targetPaneId) return;

      const targetPane = ws.tree.panes[targetPaneId];
      if (!targetPane || targetPane.kind !== 'content') return;

      upsertTabInPane(targetPane.value, tabSpec);
      ws.tree.focusedPaneId = targetPaneId;
    },

    setActiveWorkbenchTab(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        paneId: string;
        tabId: string;
      }>,
    ) {
      const { workspaceKey, paneId, tabId } = action.payload;
      const ws = state.workspaces[workspaceKey];
      if (!ws) return;
      const pane = ws.tree.panes[paneId];
      if (!pane || pane.kind !== 'content') return;

      if (
        tabId === NEW_TAB_ID ||
        pane.value.tabs.some((t) => t.id === tabId)
      ) {
        pane.value.activeTabId = tabId;
        ws.tree.focusedPaneId = paneId;
      }
    },

    closeWorkbenchTab(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        paneId: string;
        tabId: string;
        collapseEmptySplitPane?: boolean;
      }>,
    ) {
      const {
        workspaceKey,
        paneId,
        tabId,
        collapseEmptySplitPane = false,
      } = action.payload;
      const ws = state.workspaces[workspaceKey];
      if (!ws) return;
      const pane = ws.tree.panes[paneId];
      if (!pane || pane.kind !== 'content') return;

      if (tabId === NEW_TAB_ID) {
        if (pane.value.tabs.length > 0) {
          pane.value.activeTabId =
            pane.value.tabs[pane.value.tabs.length - 1].id;
        } else if (
          collapseEmptySplitPane &&
          getContentPaneIds(ws.tree).length > 1
        ) {
          closePaneInTree(ws.tree, paneId);
        } else {
          pane.value.activeTabId = NEW_TAB_ID;
        }
        return;
      }

      const idx = pane.value.tabs.findIndex((t) => t.id === tabId);
      if (idx < 0) return;

      const wasActive = pane.value.activeTabId === tabId;
      pane.value.tabs.splice(idx, 1);

      if (pane.value.tabs.length === 0) {
        if (collapseEmptySplitPane && getContentPaneIds(ws.tree).length > 1) {
          closePaneInTree(ws.tree, paneId);
        } else {
          pane.value.activeTabId = NEW_TAB_ID;
        }
        return;
      }

      if (wasActive) {
        const nextTab =
          pane.value.tabs[idx] ?? pane.value.tabs[idx - 1] ?? pane.value.tabs[0];
        pane.value.activeTabId = nextTab ? nextTab.id : NEW_TAB_ID;
      }
    },

    reorderWorkbenchTabs(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        paneId: string;
        orderedTabIds: string[];
      }>,
    ) {
      const { workspaceKey, paneId, orderedTabIds } = action.payload;
      const ws = state.workspaces[workspaceKey];
      if (!ws) return;
      const pane = ws.tree.panes[paneId];
      if (!pane || pane.kind !== 'content') return;

      const orderMap = new Map<string, number>();
      orderedTabIds.forEach((id, i) => orderMap.set(id, i));

      pane.value.tabs.sort((a, b) => {
        const idxA = orderMap.has(a.id)
          ? orderMap.get(a.id)!
          : Number.MAX_SAFE_INTEGER;
        const idxB = orderMap.has(b.id)
          ? orderMap.get(b.id)!
          : Number.MAX_SAFE_INTEGER;
        return idxA - idxB;
      });
    },

    moveWorkbenchTabToPane(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        sourcePaneId: string;
        targetPaneId: string;
        tabId: string;
        targetIndex?: number;
        collapseEmptySourcePane?: boolean;
      }>,
    ) {
      const {
        workspaceKey,
        sourcePaneId,
        targetPaneId,
        tabId,
        targetIndex,
        collapseEmptySourcePane = true,
      } = action.payload;
      const ws = state.workspaces[workspaceKey];
      if (!ws) return;

      const sourcePane = ws.tree.panes[sourcePaneId];
      const targetPane = ws.tree.panes[targetPaneId];
      if (
        !sourcePane ||
        sourcePane.kind !== 'content' ||
        !targetPane ||
        targetPane.kind !== 'content'
      ) {
        return;
      }

      const sourceIdx = sourcePane.value.tabs.findIndex((t) => t.id === tabId);
      if (sourceIdx < 0) return;

      if (sourcePaneId === targetPaneId) {
        if (
          typeof targetIndex === 'number' &&
          targetIndex >= 0 &&
          targetIndex !== sourceIdx
        ) {
          const [moved] = sourcePane.value.tabs.splice(sourceIdx, 1);
          const clampedIdx = Math.min(
            sourcePane.value.tabs.length,
            Math.max(0, targetIndex),
          );
          sourcePane.value.tabs.splice(clampedIdx, 0, moved);
        }
        sourcePane.value.activeTabId = tabId;
        ws.tree.focusedPaneId = targetPaneId;
        return;
      }

      const [movedTab] = sourcePane.value.tabs.splice(sourceIdx, 1);
      if (sourcePane.value.activeTabId === tabId) {
        const nextSourceTab =
          sourcePane.value.tabs[sourceIdx] ??
          sourcePane.value.tabs[sourceIdx - 1];
        sourcePane.value.activeTabId = nextSourceTab
          ? nextSourceTab.id
          : NEW_TAB_ID;
      }

      const existingTargetIdx = targetPane.value.tabs.findIndex(
        (t) => t.id === movedTab.id,
      );
      if (existingTargetIdx >= 0) {
        targetPane.value.tabs[existingTargetIdx] = {
          ...targetPane.value.tabs[existingTargetIdx],
          ...movedTab,
        };
      } else if (
        typeof targetIndex === 'number' &&
        targetIndex >= 0 &&
        targetIndex <= targetPane.value.tabs.length
      ) {
        targetPane.value.tabs.splice(targetIndex, 0, movedTab);
      } else {
        targetPane.value.tabs.push(movedTab);
      }

      targetPane.value.activeTabId = movedTab.id;
      if (
        collapseEmptySourcePane !== false &&
        sourcePane.value.tabs.length === 0 &&
        getContentPaneIds(ws.tree).length > 1
      ) {
        closePaneInTree(ws.tree, sourcePaneId);
      }
      ws.tree.focusedPaneId = targetPaneId;
    },

    splitWorkbenchPaneWithTab(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        sourcePaneId: string;
        targetPaneId: string;
        tabId: string;
        direction: SplitInputDirection;
      }>,
    ) {
      const {
        workspaceKey,
        sourcePaneId,
        targetPaneId,
        tabId,
        direction,
      } = action.payload;
      const ws = state.workspaces[workspaceKey];
      if (!ws) return;

      const sourcePane = ws.tree.panes[sourcePaneId];
      const targetPane = ws.tree.panes[targetPaneId];
      if (
        !sourcePane ||
        sourcePane.kind !== 'content' ||
        !targetPane ||
        targetPane.kind !== 'content'
      ) {
        return;
      }

      const sourceIdx = sourcePane.value.tabs.findIndex((t) => t.id === tabId);
      if (sourceIdx < 0) return;

      // If dragging the sole tab of a pane onto itself, keep it in place
      if (
        sourcePaneId === targetPaneId &&
        sourcePane.value.tabs.length <= 1
      ) {
        return;
      }

      const [movedTab] = sourcePane.value.tabs.splice(sourceIdx, 1);
      if (sourcePane.value.activeTabId === tabId) {
        const nextSourceTab =
          sourcePane.value.tabs[sourceIdx] ??
          sourcePane.value.tabs[sourceIdx - 1];
        sourcePane.value.activeTabId = nextSourceTab
          ? nextSourceTab.id
          : NEW_TAB_ID;
      }

      const { newChildId } = splitPaneInTree(ws.tree, targetPaneId, direction, {
        tabs: [movedTab],
        activeTabId: movedTab.id,
      });
      if (
        sourcePaneId !== targetPaneId &&
        sourcePane.value.tabs.length === 0 &&
        getContentPaneIds(ws.tree).length > 1
      ) {
        closePaneInTree(ws.tree, sourcePaneId);
      }
      ws.tree.focusedPaneId = newChildId;
      ws.pendingDropTarget = null;
    },

    replaceWorkbenchTab(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        paneId: string;
        tabId: string;
        tab: WorkbenchTabSpec;
      }>,
    ) {
      const { workspaceKey, paneId, tabId, tab: tabSpec } = action.payload;
      const ws = state.workspaces[workspaceKey];
      if (!ws) return;
      const pane = ws.tree.panes[paneId];
      if (!pane || pane.kind !== 'content') return;
      const idx = pane.value.tabs.findIndex((t) => t.id === tabId);
      if (idx < 0) return;
      const nextTab = createWorkbenchTabState(tabSpec);
      if (nextTab.id === tabId) {
        pane.value.tabs[idx] = { ...pane.value.tabs[idx], ...nextTab };
        pane.value.activeTabId = nextTab.id;
        ws.tree.focusedPaneId = paneId;
        return;
      }
      const existingIdx = pane.value.tabs.findIndex((t) => t.id === nextTab.id);
      if (existingIdx >= 0) {
        // Target tab already open in this pane: drop the old one and focus the existing.
        pane.value.tabs.splice(idx, 1);
      } else {
        pane.value.tabs[idx] = nextTab;
      }
      pane.value.activeTabId = nextTab.id;
      ws.tree.focusedPaneId = paneId;
    },

    updateWorkbenchTabParams(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        paneId?: string;
        tabId: string;
        patch: Partial<WorkbenchTabState>;
      }>,
    ) {
      const { workspaceKey, paneId, tabId, patch } = action.payload;
      const ws = state.workspaces[workspaceKey];
      if (!ws) return;

      const applyPatchToTab = (tab: WorkbenchTabState) => {
        Object.assign(tab, patch, {
          id: tab.id,
        });
        if (patch.currentPath !== undefined) {
          tab.currentPath = String(patch.currentPath || '').replace(/^\/+/, '');
        }
      };

      if (paneId) {
        const pane = ws.tree.panes[paneId];
        if (pane && pane.kind === 'content') {
          const tab = pane.value.tabs.find((t) => t.id === tabId);
          if (tab) {
            applyPatchToTab(tab);
            return;
          }
        }
      }

      for (const id of getContentPaneIds(ws.tree)) {
        const pane = ws.tree.panes[id];
        if (pane && pane.kind === 'content') {
          const tab = pane.value.tabs.find((t) => t.id === tabId);
          if (tab) {
            applyPatchToTab(tab);
            return;
          }
        }
      }
    },

    openPreviewInWorkbench(
      state,
      action: PayloadAction<{
        sessionId: string;
        label?: string;
        port?: number;
        currentPath?: string;
        workspaceKey?: string;
        paneId?: string;
        splitDirection?: SplitInputDirection;
      }>,
    ) {
      const {
        sessionId,
        label,
        port,
        currentPath,
        workspaceKey,
        paneId,
        splitDirection,
      } = action.payload;
      if (!sessionId) return;

      const ws = getOrCreateWorkspace(state, workspaceKey);
      if (!ws) return;

      const tabSpec: WorkbenchTabSpec = {
        kind: 'preview',
        sessionId,
        port,
        title:
          label ||
          (port ? `Preview :${port}` : `Preview (${sessionId.slice(0, 8)})`),
        currentPath:
          currentPath !== undefined
            ? String(currentPath || '').replace(/^\/+/, '')
            : '',
      };
      const tabId = buildWorkbenchTabId(tabSpec);

      // 1. Check if this preview session is already open in any pane in the workspace
      const existing = findPaneWithTab(ws.tree, tabId);
      if (existing) {
        const existingPane = ws.tree.panes[existing.paneId];
        if (existingPane && existingPane.kind === 'content') {
          const existingTab = existingPane.value.tabs[existing.tabIndex];
          if (label) existingTab.title = label;
          if (port !== undefined) existingTab.port = port;
          if (currentPath !== undefined) {
            existingTab.currentPath = String(currentPath || '').replace(
              /^\/+/,
              '',
            );
          }
          existingPane.value.activeTabId = tabId;
          ws.tree.focusedPaneId = existing.paneId;
          return;
        }
      }

      // 2. If a specific paneId was given or the focused pane is currently showing NEW_TAB_ID, open in place
      const targetPaneId = resolveTargetContentPaneId(ws.tree, paneId);
      if (!targetPaneId) return;

      const targetPane = ws.tree.panes[targetPaneId];
      if (!targetPane || targetPane.kind !== 'content') return;

      const targetIsShowingLauncher =
        targetPane.value.activeTabId === NEW_TAB_ID ||
        targetPane.value.tabs.length === 0;

      if (paneId || targetIsShowingLauncher) {
        upsertTabInPane(targetPane.value, tabSpec);
        ws.tree.focusedPaneId = targetPaneId;
        return;
      }

      // 3. If there is already a second pane (e.g. a non-chat utility pane), or if splitDirection is given
      if (splitDirection) {
        const createdTab = createWorkbenchTabState(tabSpec);
        splitPaneInTree(ws.tree, targetPaneId, splitDirection, {
          tabs: [createdTab],
          activeTabId: createdTab.id,
        });
        return;
      }

      const contentIds = getContentPaneIds(ws.tree);
      if (contentIds.length === 1) {
        // Split right so the preview opens side-by-side without clobbering the main chat pane
        const createdTab = createWorkbenchTabState(tabSpec);
        splitPaneInTree(ws.tree, targetPaneId, 'right', {
          tabs: [createdTab],
          activeTabId: createdTab.id,
        });
      } else {
        upsertTabInPane(targetPane.value, tabSpec);
        ws.tree.focusedPaneId = targetPaneId;
      }
    },

    setWorkbenchPendingDropTarget(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        target: { paneId: string; direction: SplitDirection } | null;
      }>,
    ) {
      const ws = state.workspaces[action.payload.workspaceKey];
      if (!ws) return;
      ws.pendingDropTarget = action.payload.target;
    },

    hydrateWorkspaceWorkbench(
      state,
      action: PayloadAction<{
        workspaceKey: string;
        tree: PaneTreeState<TabbedPaneState>;
      }>,
    ) {
      const { workspaceKey, tree } = action.payload;
      if (
        !workspaceKey ||
        !tree ||
        typeof tree !== 'object' ||
        Array.isArray(tree) ||
        typeof tree.rootPaneId !== 'string' ||
        !tree.panes ||
        typeof tree.panes !== 'object' ||
        Array.isArray(tree.panes) ||
        !tree.panes[tree.rootPaneId]
      ) {
        return;
      }

      const sanitizedPanes: PaneTreeState<TabbedPaneState>['panes'] = {};
      for (const [paneId, pane] of Object.entries(tree.panes)) {
        if (!pane || typeof pane !== 'object') continue;
        if (pane.kind === 'split') {
          if (
            typeof pane.leftChildId !== 'string' ||
            !pane.leftChildId ||
            typeof pane.rightChildId !== 'string' ||
            !pane.rightChildId
          ) {
            continue;
          }
          sanitizedPanes[paneId] = {
            kind: 'split',
            axis: pane.axis === 'vertical' ? 'vertical' : 'horizontal',
            leftChildId: pane.leftChildId,
            rightChildId: pane.rightChildId,
            ratio:
              typeof pane.ratio === 'number' &&
              Number.isFinite(pane.ratio) &&
              !Number.isNaN(pane.ratio)
                ? Math.max(5, Math.min(95, pane.ratio))
                : 50,
          };
        } else if (pane.kind === 'content') {
          const tabs = sanitizeTabList(pane.value?.tabs);
          const rawActive =
            typeof pane.value?.activeTabId === 'string'
              ? pane.value.activeTabId
              : undefined;
          const activeTabId =
            rawActive === NEW_TAB_ID
              ? NEW_TAB_ID
              : rawActive && tabs.some((t) => t.id === rawActive)
                ? rawActive
                : tabs[0]?.id ?? NEW_TAB_ID;
          sanitizedPanes[paneId] = {
            kind: 'content',
            value: {
              tabs,
              activeTabId,
            },
          };
        }
      }

      if (!sanitizedPanes[tree.rootPaneId]) {
        return;
      }

      // Prune unreachable nodes not visited from rootPaneId
      const reachablePanes: PaneTreeState<TabbedPaneState>['panes'] = {};
      const visited = new Set<string>();
      const visit = (id: string) => {
        if (!id || visited.has(id)) return;
        const node = sanitizedPanes[id];
        if (!node) return;
        visited.add(id);
        reachablePanes[id] = node;
        if (node.kind === 'split') {
          visit(node.leftChildId);
          visit(node.rightChildId);
        }
      };
      visit(tree.rootPaneId);

      const candidateTree: PaneTreeState<TabbedPaneState> = {
        rootPaneId: tree.rootPaneId,
        panes: reachablePanes,
        focusedPaneId: tree.focusedPaneId,
        maximizedPaneId: tree.maximizedPaneId ?? null,
      };

      const { contentLayouts } = calculatePaneLayouts(candidateTree);
      if (contentLayouts.length === 0) return;

      const contentIds = contentLayouts.map((l) => l.paneId);

      candidateTree.focusedPaneId =
        candidateTree.focusedPaneId &&
        candidateTree.panes[candidateTree.focusedPaneId]?.kind === 'content'
          ? candidateTree.focusedPaneId
          : contentIds[0];

      candidateTree.maximizedPaneId =
        contentIds.length > 1 &&
        candidateTree.maximizedPaneId &&
        candidateTree.panes[candidateTree.maximizedPaneId]?.kind === 'content'
          ? candidateTree.maximizedPaneId
          : null;

      state.workspaces[workspaceKey] = {
        workspaceKey,
        tree: candidateTree,
        pendingDropTarget: null,
      };
    },
  },
});

export const {
  ensureWorkspaceInitialized,
  setActiveWorkspaceKey,
  setFocusedWorkbenchPane,
  splitWorkbenchPane,
  closeWorkbenchPane,
  moveWorkbenchPane,
  swapWorkbenchPanes,
  resizeWorkbenchSplit,
  equalizeWorkbenchPanes,
  toggleMaximizeWorkbenchPane,
  openNewTabView,
  openOrFocusWorkbenchTab,
  replaceNewTabWithSurface,
  setActiveWorkbenchTab,
  closeWorkbenchTab,
  reorderWorkbenchTabs,
  moveWorkbenchTabToPane,
  splitWorkbenchPaneWithTab,
  updateWorkbenchTabParams,
  replaceWorkbenchTab,
  openPreviewInWorkbench,
  setWorkbenchPendingDropTarget,
  hydrateWorkspaceWorkbench,
} = workbenchSlice.actions;

function extractWorkbenchSlice(state: any): WorkbenchRootState {
  if (state && state.workbench && state.workbench.workspaces) {
    return state.workbench as WorkbenchRootState;
  }
  if (state && state.workspaces && typeof state.workspaces === 'object') {
    return state as WorkbenchRootState;
  }
  return initialState;
}

export const selectWorkbenchRootState = (state: any): WorkbenchRootState =>
  extractWorkbenchSlice(state);

export const selectActiveWorkspaceKey = (state: any): string | null =>
  extractWorkbenchSlice(state).activeWorkspaceKey;

export const selectWorkspaceWorkbench = (
  state: any,
  workspaceKey: string | null | undefined,
): WorkspaceWorkbenchState | undefined => {
  const root = extractWorkbenchSlice(state);
  const key = workspaceKey || root.activeWorkspaceKey;
  if (!key) return undefined;
  return root.workspaces[key];
};

export const selectWorkspaceWorkbenchTree = (
  state: any,
  workspaceKey: string | null | undefined,
): PaneTreeState<TabbedPaneState> | undefined =>
  selectWorkspaceWorkbench(state, workspaceKey)?.tree;

export const selectFocusedWorkbenchPaneId = (
  state: any,
  workspaceKey: string | null | undefined,
): string | undefined =>
  selectWorkspaceWorkbench(state, workspaceKey)?.tree.focusedPaneId;

export const selectFocusedWorkbenchPane = (
  state: any,
  workspaceKey: string | null | undefined,
): TabbedPaneState | undefined => {
  const tree = selectWorkspaceWorkbenchTree(state, workspaceKey);
  if (!tree) return undefined;
  const focused = tree.panes[tree.focusedPaneId];
  if (focused && focused.kind === 'content') {
    return focused.value;
  }
  const firstId = getContentPaneIds(tree)[0];
  const first = firstId ? tree.panes[firstId] : undefined;
  return first && first.kind === 'content' ? first.value : undefined;
};

export const selectWorkbenchMaximizedPaneId = (
  state: any,
  workspaceKey: string | null | undefined,
): string | null =>
  selectWorkspaceWorkbench(state, workspaceKey)?.tree.maximizedPaneId ?? null;

export const selectWorkbenchPendingDropTarget = (
  state: any,
  workspaceKey: string | null | undefined,
): { paneId: string; direction: SplitDirection } | null =>
  selectWorkspaceWorkbench(state, workspaceKey)?.pendingDropTarget ?? null;

export const selectAllWorkspaceTabs = (
  state: any,
  workspaceKey: string | null | undefined,
): WorkbenchTabState[] => {
  const tree = selectWorkspaceWorkbenchTree(state, workspaceKey);
  if (!tree) return [];
  const tabs: WorkbenchTabState[] = [];
  for (const paneId of getContentPaneIds(tree)) {
    const pane = tree.panes[paneId];
    if (pane && pane.kind === 'content') {
      tabs.push(...pane.value.tabs);
    }
  }
  return tabs;
};

export default workbenchSlice.reducer;
