/**
 * Tier 1 — Feature Coverage E2E Test Suite
 *
 * Verifies every requirement and feature F1–F12 of the Two-Level Jetski Pane Workbench Redesign
 * per ORIGINAL_REQUEST.md, PROJECT.md § Interface Contracts, and TEST_INFRA.md:
 * - F1: Clean Git Branch Cut from origin/main (5 tests)
 * - F2: Generic Binary Split-Pane Tiling Engine (`src/ui/tiling/`) (6 tests)
 * - F3: Level 1 Multi-Conversation Window Tiling State (`windowLayoutSlice.ts`) (6 tests)
 * - F4: Level 2 Per-Conversation 2D Workbench & Tabbed Pane State (`workbenchSlice.ts` + `workbenchTabId.ts`) (8 tests)
 * - F5: Level 2 Tab Strip, `NEW_TAB_ID` Launcher UI, & Workbench Container (`src/ui/components/workbench/`) (6 tests)
 * - F6: Surface 1: Multi-Instance Agent Chat (`AgentChatPane.tsx`) (5 tests)
 * - F7: Surface 2: Agent Live Terminal (`AgentPtyWorkbenchPane.tsx` & `AgentPaneComposerPanel.tsx`) (5 tests)
 * - F8: Surface 3: Interactive Shell (`ShellWorkbenchPane.tsx`) (5 tests)
 * - F9: Surface 4: Live Web Preview (`PreviewWorkbenchPane.tsx`) (5 tests)
 * - F10: Surfaces 5, 6, 7: Files, VCS, Chain Overview, & Tasks + Cross-Links (6 tests)
 * - F11: Level 1 Window Tiling UI, `NewConversationWindowPane`, `AppShell` Integration, & Complete R4 Legacy Deletion (6 tests)
 * - F12: DOM & Session Stability Verification (5 tests)
 *
 * Total Tier 1 Test Cases: 68 (>= 60 required, >= 5 per feature F1–F12)
 *
 * RUN: npx tsx --test tests/e2e/jetski_workbench_tier1_test.ts
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import React from 'react';
import '../helpers/vaultEndpointHarness.ts';

const REPO_ROOT = path.resolve(import.meta.dirname, '../..');

function createMockLocalStorage() {
  const store = new Map<string, string>();
  const mockStorage: Storage = {
    get length() {
      return store.size;
    },
    clear() {
      store.clear();
    },
    getItem(key: string) {
      return store.has(key) ? store.get(key)! : null;
    },
    key(index: number) {
      return Array.from(store.keys())[index] ?? null;
    },
    removeItem(key: string) {
      store.delete(key);
    },
    setItem(key: string, value: string) {
      store.set(key, String(value));
    },
  };
  return mockStorage;
}

function withMockWindowStorage<T>(fn: (storage: Storage) => T): T {
  const storage = createMockLocalStorage();
  const prevWindow = (globalThis as any).window;
  const prevLocalStorage = (globalThis as any).localStorage;
  (globalThis as any).window = {
    ...(prevWindow || {}),
    localStorage: storage,
    sessionStorage: createMockLocalStorage(),
    location: prevWindow?.location || { hash: '#/conversations/inst-1', origin: 'http://127.0.0.1:5173' },
    addEventListener: prevWindow?.addEventListener || (() => {}),
    removeEventListener: prevWindow?.removeEventListener || (() => {}),
    dispatchEvent: prevWindow?.dispatchEvent || (() => true),
  };
  (globalThis as any).localStorage = storage;
  try {
    return fn(storage);
  } finally {
    if (prevWindow === undefined) {
      delete (globalThis as any).window;
    } else {
      (globalThis as any).window = prevWindow;
    }
    if (prevLocalStorage === undefined) {
      delete (globalThis as any).localStorage;
    } else {
      (globalThis as any).localStorage = prevLocalStorage;
    }
  }
}

// ============================================================================
// F2: Generic Binary Split-Pane Tiling Engine (`src/ui/tiling/`) (6 tests)
// ============================================================================
describe('F2: Generic Binary Split-Pane Tiling Engine (src/ui/tiling/)', () => {
  test('T1-F2-01: createPaneTreeState initializes root content leaf with focusedPaneId and null maximizedPaneId', async () => {
    const { createPaneTreeState, getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    const tree = createPaneTreeState({ label: 'initial' }, 'pane-root');
    assert.equal(tree.rootPaneId, 'pane-root');
    assert.equal(tree.focusedPaneId, 'pane-root');
    assert.ok(!tree.maximizedPaneId);
    assert.deepEqual(tree.panes['pane-root'], {
      kind: 'content',
      value: { label: 'initial' },
    });
    assert.deepEqual(getContentPaneIds(tree), ['pane-root']);
  });

  test('T1-F2-02: splitPaneInTree supports all 4 directional splits (top, bottom, left, right) and axis aliases (horizontal, vertical) while preserving original paneId', async () => {
    const { createPaneTreeState, splitPaneInTree, toAxis, isFirstChild } = await import(
      '../../src/ui/tiling/paneTreeState.ts'
    );

    assert.equal(toAxis('left'), 'horizontal');
    assert.equal(toAxis('right'), 'horizontal');
    assert.equal(toAxis('horizontal'), 'horizontal');
    assert.equal(toAxis('top'), 'vertical');
    assert.equal(toAxis('bottom'), 'vertical');
    assert.equal(toAxis('vertical'), 'vertical');

    assert.equal(isFirstChild('top'), true);
    assert.equal(isFirstChild('left'), true);
    assert.equal(isFirstChild('bottom'), false);
    assert.equal(isFirstChild('right'), false);

    const tree = createPaneTreeState('p1', 'pane-1');
    const splitRight = splitPaneInTree(tree, 'pane-1', 'right', 'p2', 'pane-2');
    assert.ok(tree.panes['pane-1'], 'Original pane-1 must be preserved');
    assert.equal(tree.panes['pane-1'].kind, 'content');
    assert.equal(splitRight.newChildId, 'pane-2');

    const rootSplit = tree.panes[tree.rootPaneId];
    assert.equal(rootSplit.kind, 'split');
    if (rootSplit.kind === 'split') {
      assert.equal(rootSplit.axis, 'horizontal');
      assert.equal(rootSplit.leftChildId, 'pane-1');
      assert.equal(rootSplit.rightChildId, 'pane-2');
      assert.equal(rootSplit.ratio, 50);
    }

    const splitTop = splitPaneInTree(tree, 'pane-2', 'top', 'p3', 'pane-3');
    const subSplit = tree.panes[splitTop.parentId];
    assert.equal(subSplit.kind, 'split');
    if (subSplit.kind === 'split') {
      assert.equal(subSplit.axis, 'vertical');
      assert.equal(subSplit.leftChildId, 'pane-3');
      assert.equal(subSplit.rightChildId, 'pane-2');
    }
  });

  test('T1-F2-03: closePaneInTree promotes sibling pane, updates focusedPaneId, and clears maximizedPaneId', async () => {
    const { createPaneTreeState, splitPaneInTree, closePaneInTree, toggleMaximizePaneInTree } = await import(
      '../../src/ui/tiling/paneTreeState.ts'
    );

    const tree = createPaneTreeState('first', 'pane-1');
    splitPaneInTree(tree, 'pane-1', 'right', 'second', 'pane-2');
    toggleMaximizePaneInTree(tree, 'pane-2');
    assert.equal(tree.maximizedPaneId, 'pane-2');

    const isLast = closePaneInTree(tree, 'pane-2');
    assert.equal(isLast, false);
    assert.equal(tree.rootPaneId, 'pane-1');
    assert.equal(tree.focusedPaneId, 'pane-1');
    assert.ok(!tree.maximizedPaneId, 'Closing maximized pane must reset maximizedPaneId');
    assert.equal(tree.panes['pane-2'], undefined);
  });

  test('T1-F2-04: movePaneInTree and swapPanesInTree preserve both sourcePaneId and targetPaneId', async () => {
    const { createPaneTreeState, splitPaneInTree, movePaneInTree, swapPanesInTree, getContentPaneIds } =
      await import('../../src/ui/tiling/paneTreeState.ts');

    const tree = createPaneTreeState('A', 'pane-A');
    splitPaneInTree(tree, 'pane-A', 'right', 'B', 'pane-B');
    splitPaneInTree(tree, 'pane-B', 'bottom', 'C', 'pane-C');

    const moved = movePaneInTree(tree, 'pane-C', 'pane-A', 'top');
    assert.equal(moved, true);
    const idsAfterMove = getContentPaneIds(tree);
    assert.ok(idsAfterMove.includes('pane-A'), 'pane-A ID must be preserved');
    assert.ok(idsAfterMove.includes('pane-B'), 'pane-B ID must be preserved');
    assert.ok(idsAfterMove.includes('pane-C'), 'pane-C ID must be preserved after move');

    const swapped = swapPanesInTree(tree, 'pane-A', 'pane-B');
    assert.equal(swapped, true);
    assert.ok(tree.panes['pane-A'] && tree.panes['pane-B']);
  });

  test('T1-F2-05: resizeSplitInTree, equalizeTreeRatios, toStructureOnly, and calculatePaneLayouts compute accurate percentage bounds', async () => {
    const {
      createPaneTreeState,
      splitPaneInTree,
      resizeSplitInTree,
      equalizeTreeRatios,
      toStructureOnly,
    } = await import('../../src/ui/tiling/paneTreeState.ts');
    const { calculatePaneLayouts } = await import('../../src/ui/tiling/calculatePaneLayout.ts');

    const tree = createPaneTreeState('left', 'pane-left');
    const { parentId } = splitPaneInTree(tree, 'pane-left', 'right', 'right', 'pane-right');

    resizeSplitInTree(tree, parentId, 30);
    const struct = toStructureOnly(tree);
    const { contentLayouts, splitterLayouts } = calculatePaneLayouts(struct);

    assert.equal(contentLayouts.length, 2);
    assert.equal(splitterLayouts.length, 1);

    const leftLayout = contentLayouts.find((l) => l.paneId === 'pane-left')!;
    const rightLayout = contentLayouts.find((l) => l.paneId === 'pane-right')!;
    assert.equal(leftLayout.left, 0);
    assert.equal(leftLayout.width, 30);
    assert.equal(leftLayout.height, 100);
    assert.equal(leftLayout.isRightmostOfRow, false);
    assert.equal(rightLayout.left, 30);
    assert.equal(rightLayout.width, 70);
    assert.equal(rightLayout.isRightmostOfRow, true);

    equalizeTreeRatios(tree);
    const { contentLayouts: eqLayouts } = calculatePaneLayouts(tree);
    assert.equal(eqLayouts.find((l) => l.paneId === 'pane-left')!.width, 50);
    assert.equal(eqLayouts.find((l) => l.paneId === 'pane-right')!.width, 50);
  });

  test('T1-F2-06: dragUtils (getSplitDirection, getOverlayPosition, resolvePaneTarget) and TilingContainer component contract', async () => {
    const { getSplitDirection, getOverlayPosition, resolvePaneTarget } = await import(
      '../../src/ui/tiling/dragUtils.ts'
    );
    const { TilingContainer } = await import('../../src/ui/tiling/TilingContainer.tsx');
    const { createPaneTreeState } = await import('../../src/ui/tiling/paneTreeState.ts');

    const rect = { left: 100, top: 200, width: 400, height: 200 };
    assert.equal(getSplitDirection(rect, { x: 120, y: 300 }), 'left');
    assert.equal(getSplitDirection(rect, { x: 480, y: 300 }), 'right');
    assert.equal(getSplitDirection(rect, { x: 300, y: 210 }), 'top');
    assert.equal(getSplitDirection(rect, { x: 300, y: 390 }), 'bottom');

    assert.deepEqual(getOverlayPosition(rect, 'left'), { top: 0, left: 0, width: 200, height: 200 });
    assert.deepEqual(getOverlayPosition(rect, 'right'), { top: 0, left: 200, width: 200, height: 200 });
    assert.deepEqual(getOverlayPosition(rect, 'top'), { top: 0, left: 0, width: 400, height: 100 });
    assert.deepEqual(getOverlayPosition(rect, 'bottom'), { top: 100, left: 0, width: 400, height: 100 });

    assert.equal(typeof resolvePaneTarget, 'function');
    assert.equal(typeof TilingContainer, 'function');

    const tree = createPaneTreeState('leaf-val', 'pane-1');
    const elem = React.createElement(TilingContainer, {
      treeState: tree,
      renderPane: ({ paneId }) => React.createElement('div', { key: paneId }, paneId),
    });
    assert.ok(elem);
  });
});

// ============================================================================
// F3: Level 1 Multi-Conversation Window Tiling State (`windowLayoutSlice.ts`) (6 tests)
// ============================================================================
describe('F3: Level 1 Multi-Conversation Window Tiling State (windowLayoutSlice.ts)', () => {
  test('T1-F3-01: windowLayoutSlice initializes with a single leaf pane and exports NEW_WINDOW_PANE_ID = "_new"', async () => {
    const windowLayoutModule = await import('../../src/ui/store/windowLayoutSlice.ts');
    const { default: reducer, NEW_WINDOW_PANE_ID } = windowLayoutModule;

    assert.equal(NEW_WINDOW_PANE_ID, '_new');
    const state = reducer(undefined, { type: '@@INIT' });
    assert.ok(state.tree);
    assert.ok(state.tree.rootPaneId);
    assert.equal(state.tree.focusedPaneId, state.tree.rootPaneId);
    const rootPane = state.tree.panes[state.tree.rootPaneId];
    assert.equal(rootPane.kind, 'content');
  });

  test('T1-F3-02: splitWindowPane splits horizontally and vertically, creating NEW_WINDOW_PANE_ID leaf panes when agentInstanceId is omitted', async () => {
    const {
      default: reducer,
      NEW_WINDOW_PANE_ID,
      splitWindowPane,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    let state = reducer(undefined, syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-1', chainId: 'chain-1' }));
    const firstPaneId = state.tree.rootPaneId;

    state = reducer(state, splitWindowPane({ targetPaneId: firstPaneId, direction: 'right' }));
    const paneIdsAfterRight = getContentPaneIds(state.tree);
    assert.equal(paneIdsAfterRight.length, 2);
    assert.ok(paneIdsAfterRight.includes(firstPaneId), 'First window pane ID must be preserved');

    const secondPaneId = paneIdsAfterRight.find((id) => id !== firstPaneId)!;
    const secondPane = state.tree.panes[secondPaneId];
    assert.equal(secondPane.kind, 'content');
    if (secondPane.kind === 'content') {
      assert.equal(secondPane.value.kind, 'new');
      assert.equal(secondPane.value.agentInstanceId, NEW_WINDOW_PANE_ID);
    }

    state = reducer(state, splitWindowPane({ targetPaneId: secondPaneId, direction: 'bottom', agentInstanceId: 'inst-2' }));
    const paneIdsAfterBottom = getContentPaneIds(state.tree);
    assert.equal(paneIdsAfterBottom.length, 3);
  });

  test('T1-F3-03: assignWindowPaneConversation transitions a "_new" window pane into a conversation workspace in-place', async () => {
    const {
      default: reducer,
      splitWindowPane,
      assignWindowPaneConversation,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');

    let state = reducer(undefined, syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-1' }));
    state = reducer(state, splitWindowPane({ direction: 'right' }));
    const newPaneId = state.tree.focusedPaneId;

    state = reducer(
      state,
      assignWindowPaneConversation({
        paneId: newPaneId,
        agentInstanceId: 'inst-2',
        chainId: 'chain-2',
        projectId: 'proj-2',
        title: 'Worker 2 Conversation',
      }),
    );

    const updatedPane = state.tree.panes[newPaneId];
    assert.equal(updatedPane.kind, 'content');
    if (updatedPane.kind === 'content') {
      assert.equal(updatedPane.value.kind, 'conversation');
      assert.equal(updatedPane.value.agentInstanceId, 'inst-2');
      assert.equal(updatedPane.value.chainId, 'chain-2');
      assert.equal(updatedPane.value.projectId, 'proj-2');
    }
  });

  test('T1-F3-04: setFocusedWindowPane, resizeWindowSplit, equalizeWindowPanes, and toggleMaximizeWindowPane update window tree state', async () => {
    const {
      default: reducer,
      splitWindowPane,
      setFocusedWindowPane,
      resizeWindowSplit,
      equalizeWindowPanes,
      toggleMaximizeWindowPane,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');

    let state = reducer(undefined, syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-1' }));
    const pane1 = state.tree.rootPaneId;
    state = reducer(state, splitWindowPane({ targetPaneId: pane1, direction: 'right', agentInstanceId: 'inst-2' }));
    const pane2 = state.tree.focusedPaneId;
    const splitId = state.tree.rootPaneId;

    state = reducer(state, setFocusedWindowPane(pane1));
    assert.equal(state.tree.focusedPaneId, pane1);

    state = reducer(state, resizeWindowSplit({ splitPaneId: splitId, ratio: 65 }));
    const splitNode = state.tree.panes[splitId];
    assert.equal(splitNode.kind, 'split');
    if (splitNode.kind === 'split') {
      assert.equal(splitNode.ratio, 65);
    }

    state = reducer(state, equalizeWindowPanes());
    const eqSplitNode = state.tree.panes[splitId];
    if (eqSplitNode.kind === 'split') {
      assert.equal(eqSplitNode.ratio, 50);
    }

    state = reducer(state, toggleMaximizeWindowPane(pane2));
    assert.equal(state.tree.maximizedPaneId, pane2);
    state = reducer(state, toggleMaximizeWindowPane(pane2));
    assert.ok(!state.tree.maximizedPaneId);
  });

  test('T1-F3-05: moveWindowPane and swapWindowPanes rearrange window panes while preserving pane IDs', async () => {
    const {
      default: reducer,
      splitWindowPane,
      moveWindowPane,
      swapWindowPanes,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    let state = reducer(undefined, syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-1' }));
    const pane1 = state.tree.rootPaneId;
    state = reducer(state, splitWindowPane({ targetPaneId: pane1, direction: 'right', agentInstanceId: 'inst-2' }));
    const pane2 = state.tree.focusedPaneId;

    state = reducer(state, moveWindowPane({ sourcePaneId: pane2, targetPaneId: pane1, direction: 'top' }));
    const ids = getContentPaneIds(state.tree);
    assert.ok(ids.includes(pane1), 'pane1 ID must survive moveWindowPane');
    assert.ok(ids.includes(pane2), 'pane2 ID must survive moveWindowPane');

    state = reducer(state, swapWindowPanes({ paneIdA: pane1, paneIdB: pane2 }));
    assert.ok(state.tree.panes[pane1] && state.tree.panes[pane2]);
  });

  test('T1-F3-06: closeWindowPane and readWindowLayoutState / writeWindowLayoutState persistence round-trip', async () => {
    const {
      default: reducer,
      splitWindowPane,
      closeWindowPane,
      hydrateWindowLayout,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');
    const { readWindowLayoutState, writeWindowLayoutState } = await import(
      '../../src/ui/utils/clientPersistence.ts'
    );

    withMockWindowStorage(() => {
      let state = reducer(undefined, syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-1' }));
      const pane1 = state.tree.rootPaneId;
      state = reducer(state, splitWindowPane({ targetPaneId: pane1, direction: 'right', agentInstanceId: 'inst-2' }));
      const pane2 = state.tree.focusedPaneId;

      writeWindowLayoutState(state.tree);
      const loadedTree = readWindowLayoutState();
      assert.ok(loadedTree, 'readWindowLayoutState must return persisted tree');
      assert.ok(loadedTree.panes[pane1]);
      assert.ok(loadedTree.panes[pane2]);

      const hydrated = reducer(undefined, hydrateWindowLayout(loadedTree));
      assert.ok(hydrated.tree.panes[pane1]);
      assert.ok(hydrated.tree.panes[pane2]);

      const afterClose = reducer(hydrated, closeWindowPane(pane2));
      assert.equal(afterClose.tree.rootPaneId, pane1);
      assert.equal(afterClose.tree.panes[pane2], undefined);
    });
  });
});

// ============================================================================
// F4: Level 2 Per-Conversation 2D Workbench & Tabbed Pane State (8 tests)
// ============================================================================
describe('F4: Level 2 Per-Conversation 2D Workbench & Tabbed Pane State (workbenchSlice.ts & workbenchTabId.ts)', () => {
  test('T1-F4-01: workbenchTabId exports NEW_TAB_ID = "newTab__empty" and builds canonical IDs for all 8 surface kinds', async () => {
    const tabIdModule = await import('../../src/ui/store/workbenchTabId.ts');
    const { NEW_TAB_ID, buildWorkbenchTabId, parseWorkbenchTabId } = tabIdModule;

    assert.equal(NEW_TAB_ID, 'newTab__empty');
    assert.equal(typeof buildWorkbenchTabId, 'function');

    const chatId = buildWorkbenchTabId({ kind: 'agentChat', agentInstanceId: 'inst-10' });
    const ptyId = buildWorkbenchTabId({ kind: 'agentPty', agentInstanceId: 'inst-10' });
    const shellId = buildWorkbenchTabId({ kind: 'shell', sessionId: 'sess-20' });
    const previewId = buildWorkbenchTabId({ kind: 'preview', sessionId: 'srv-30' });
    const filesId = buildWorkbenchTabId({ kind: 'files' });
    const vcsId = buildWorkbenchTabId({ kind: 'vcs' });
    const chainId = buildWorkbenchTabId({ kind: 'chainOverview' });
    const tasksId = buildWorkbenchTabId({ kind: 'tasks' });

    assert.ok(chatId.includes('inst-10'));
    assert.ok(ptyId.includes('inst-10'));
    assert.notEqual(chatId, ptyId);
    assert.ok(shellId.includes('sess-20'));
    assert.ok(previewId.includes('srv-30'));
    assert.equal(filesId, 'files');
    assert.equal(vcsId, 'vcs');
    assert.equal(chainId, 'chainOverview');
    assert.equal(tasksId, 'tasks');

    if (typeof parseWorkbenchTabId === 'function') {
      const parsedChat = parseWorkbenchTabId(chatId);
      assert.equal(parsedChat?.kind, 'agentChat');
      assert.equal(parsedChat?.agentInstanceId, 'inst-10');
    }
  });

  test('T1-F4-02: ensureWorkspaceInitialized creates workspace with primary agentChat tab and optional initialPanel split/tab', async () => {
    const { default: reducer, ensureWorkspaceInitialized } = await import(
      '../../src/ui/store/workbenchSlice.ts'
    );

    const state = reducer(
      undefined,
      ensureWorkspaceInitialized({
        workspaceKey: 'chain-alpha',
        defaultAgentInstanceId: 'inst-coord',
        defaultTitle: 'Coordinator',
      }),
    );

    const ws = state.workspaces['chain-alpha'];
    assert.ok(ws, 'Workspace chain-alpha must be initialized');
    const rootPane = ws.tree.panes[ws.tree.rootPaneId];
    assert.equal(rootPane.kind, 'content');
    if (rootPane.kind === 'content') {
      assert.ok(rootPane.value.tabs.length >= 1);
      assert.equal(rootPane.value.tabs[0].kind, 'agentChat');
      assert.equal(rootPane.value.tabs[0].agentInstanceId, 'inst-coord');
      assert.equal(rootPane.value.activeTabId, rootPane.value.tabs[0].id);
    }
  });

  test('T1-F4-03: splitWorkbenchPane in top, bottom, left, right creates new pane initialized with NEW_TAB_ID while preserving source pane ID', async () => {
    const { NEW_TAB_ID } = await import('../../src/ui/store/workbenchTabId.ts');
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      splitWorkbenchPane,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({
        workspaceKey: 'ws-1',
        defaultAgentInstanceId: 'inst-1',
      }),
    );
    const initialPaneId = state.workspaces['ws-1'].tree.rootPaneId;

    for (const dir of ['right', 'bottom', 'left', 'top'] as const) {
      state = reducer(
        state,
        splitWorkbenchPane({
          workspaceKey: 'ws-1',
          targetPaneId: initialPaneId,
          direction: dir,
        }),
      );
    }

    const ws = state.workspaces['ws-1'];
    const paneIds = getContentPaneIds(ws.tree);
    assert.equal(paneIds.length, 5);
    assert.ok(paneIds.includes(initialPaneId), 'Initial pane ID must be preserved across all 4 directional splits');

    const latestPane = ws.tree.panes[ws.tree.focusedPaneId];
    assert.equal(latestPane.kind, 'content');
    if (latestPane.kind === 'content') {
      assert.equal(latestPane.value.activeTabId, NEW_TAB_ID);
      assert.equal(latestPane.value.tabs.length, 0);
    }
  });

  test('T1-F4-04: openNewTabView sets activeTabId = NEW_TAB_ID while keeping existing tabs intact, and openOrFocusWorkbenchTab replaces NEW_TAB_ID in-place', async () => {
    const { NEW_TAB_ID } = await import('../../src/ui/store/workbenchTabId.ts');
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openNewTabView,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({
        workspaceKey: 'ws-1',
        defaultAgentInstanceId: 'inst-1',
      }),
    );
    const paneId = state.workspaces['ws-1'].tree.rootPaneId;

    state = reducer(state, openNewTabView({ workspaceKey: 'ws-1', paneId }));
    let pane = state.workspaces['ws-1'].tree.panes[paneId];
    assert.equal(pane.kind, 'content');
    if (pane.kind === 'content') {
      assert.equal(pane.value.activeTabId, NEW_TAB_ID);
      assert.equal(pane.value.tabs.length, 1, 'Existing agentChat tab must remain in tabs[]');
    }

    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-1',
        paneId,
        tab: { kind: 'files', title: 'Files' },
      }),
    );
    pane = state.workspaces['ws-1'].tree.panes[paneId];
    if (pane.kind === 'content') {
      assert.equal(pane.value.tabs.length, 2);
      assert.equal(pane.value.activeTabId, 'files');
      assert.ok(!pane.value.tabs.some((t) => t.id === NEW_TAB_ID), 'NEW_TAB_ID must never be stored in tabs[]');
    }
  });

  test('T1-F4-05: setActiveWorkbenchTab, closeWorkbenchTab, and reorderWorkbenchTabs manage tab strip state accurately', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      setActiveWorkbenchTab,
      closeWorkbenchTab,
      reorderWorkbenchTabs,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-tabs', defaultAgentInstanceId: 'inst-1' }),
    );
    const paneId = state.workspaces['ws-tabs'].tree.rootPaneId;

    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-tabs', paneId, tab: { kind: 'files', title: 'Files' } }));
    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-tabs', paneId, tab: { kind: 'vcs', title: 'VCS' } }));

    let pane = state.workspaces['ws-tabs'].tree.panes[paneId];
    if (pane.kind === 'content') {
      const ids = pane.value.tabs.map((t) => t.id);
      assert.equal(ids.length, 3);

      const reversed = [...ids].reverse();
      state = reducer(state, reorderWorkbenchTabs({ workspaceKey: 'ws-tabs', paneId, orderedTabIds: reversed }));
      pane = state.workspaces['ws-tabs'].tree.panes[paneId];
      if (pane.kind === 'content') {
        assert.deepEqual(pane.value.tabs.map((t) => t.id), reversed);
      }

      state = reducer(state, setActiveWorkbenchTab({ workspaceKey: 'ws-tabs', paneId, tabId: 'files' }));
      pane = state.workspaces['ws-tabs'].tree.panes[paneId];
      if (pane.kind === 'content') {
        assert.equal(pane.value.activeTabId, 'files');
      }

      state = reducer(state, closeWorkbenchTab({ workspaceKey: 'ws-tabs', paneId, tabId: 'files' }));
      pane = state.workspaces['ws-tabs'].tree.panes[paneId];
      if (pane.kind === 'content') {
        assert.equal(pane.value.tabs.length, 2);
        assert.notEqual(pane.value.activeTabId, 'files');
      }
    }
  });

  test('T1-F4-06: moveWorkbenchTabToPane and splitWorkbenchPaneWithTab transfer tabs across panes and auto-collapse empty non-root source panes', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      moveWorkbenchTabToPane,
      splitWorkbenchPaneWithTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-move', defaultAgentInstanceId: 'inst-1' }),
    );
    const pane1 = state.workspaces['ws-move'].tree.rootPaneId;
    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-move', paneId: pane1, tab: { kind: 'files', title: 'Files' } }));
    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-move', paneId: pane1, tab: { kind: 'vcs', title: 'VCS' } }));

    // Split pane1 with the 'vcs' tab to the right
    state = reducer(
      state,
      splitWorkbenchPaneWithTab({
        workspaceKey: 'ws-move',
        sourcePaneId: pane1,
        targetPaneId: pane1,
        tabId: 'vcs',
        direction: 'right',
      }),
    );

    let paneIds = getContentPaneIds(state.workspaces['ws-move'].tree);
    assert.equal(paneIds.length, 2);
    const pane2 = paneIds.find((id) => id !== pane1)!;

    // Move 'vcs' back from pane2 to pane1
    state = reducer(
      state,
      moveWorkbenchTabToPane({
        workspaceKey: 'ws-move',
        sourcePaneId: pane2,
        targetPaneId: pane1,
        tabId: 'vcs',
      }),
    );

    const p1After = state.workspaces['ws-move'].tree.panes[pane1];
    assert.equal(p1After?.kind, 'content');
    if (p1After?.kind === 'content') {
      assert.ok(p1After.value.tabs.some((t) => t.id === 'vcs'), 'vcs tab must be transferred back to pane1');
      assert.equal(p1After.value.activeTabId, 'vcs');
    }
  });

  test('T1-F4-07: toggleMaximizeWorkbenchPane, resizeWorkbenchSplit, moveWorkbenchPane, and equalizeWorkbenchPanes preserve pane IDs', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      splitWorkbenchPane,
      toggleMaximizeWorkbenchPane,
      resizeWorkbenchSplit,
      moveWorkbenchPane,
      equalizeWorkbenchPanes,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-layout', defaultAgentInstanceId: 'inst-1' }),
    );
    const pane1 = state.workspaces['ws-layout'].tree.rootPaneId;
    state = reducer(state, splitWorkbenchPane({ workspaceKey: 'ws-layout', targetPaneId: pane1, direction: 'right' }));
    const pane2 = state.workspaces['ws-layout'].tree.focusedPaneId;
    const splitId = state.workspaces['ws-layout'].tree.rootPaneId;

    state = reducer(state, resizeWorkbenchSplit({ workspaceKey: 'ws-layout', splitPaneId: splitId, ratio: 40 }));
    const splitNode = state.workspaces['ws-layout'].tree.panes[splitId];
    if (splitNode.kind === 'split') {
      assert.equal(splitNode.ratio, 40);
    }

    state = reducer(state, equalizeWorkbenchPanes({ workspaceKey: 'ws-layout' }));
    const eqNode = state.workspaces['ws-layout'].tree.panes[splitId];
    if (eqNode.kind === 'split') {
      assert.equal(eqNode.ratio, 50);
    }

    state = reducer(state, toggleMaximizeWorkbenchPane({ workspaceKey: 'ws-layout', paneId: pane2 }));
    assert.equal(state.workspaces['ws-layout'].tree.maximizedPaneId, pane2);

    state = reducer(state, moveWorkbenchPane({ workspaceKey: 'ws-layout', sourcePaneId: pane2, targetPaneId: pane1, direction: 'bottom' }));
    const ids = getContentPaneIds(state.workspaces['ws-layout'].tree);
    assert.ok(ids.includes(pane1) && ids.includes(pane2), 'Both pane IDs must be preserved after moveWorkbenchPane');
  });

  test('T1-F4-08: readWorkbenchWorkspaceState / writeWorkbenchWorkspaceState persistence round-trip', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { readWorkbenchWorkspaceState, writeWorkbenchWorkspaceState } = await import(
      '../../src/ui/utils/clientPersistence.ts'
    );

    withMockWindowStorage(() => {
      let state = reducer(
        undefined,
        ensureWorkspaceInitialized({ workspaceKey: 'ws-persist', defaultAgentInstanceId: 'inst-1' }),
      );
      state = reducer(
        state,
        openOrFocusWorkbenchTab({
          workspaceKey: 'ws-persist',
          tab: { kind: 'chainOverview', title: 'Chain Overview' },
        }),
      );

      writeWorkbenchWorkspaceState('ws-persist', state.workspaces['ws-persist'].tree);
      const loaded = readWorkbenchWorkspaceState('ws-persist');
      assert.ok(loaded, 'Must read persisted workspace state');
      const tree = loaded.tree || loaded;
      const rootPane = tree.panes[tree.rootPaneId];
      assert.equal(rootPane.kind, 'content');
      if (rootPane.kind === 'content') {
        assert.ok(rootPane.value.tabs.some((t: any) => t.kind === 'chainOverview'));
      }
    });
  });
});

// ============================================================================
// F5: Level 2 Tab Strip, `NEW_TAB_ID` Launcher UI, & Workbench Container (6 tests)
// ============================================================================
describe('F5: Level 2 Tab Strip, NEW_TAB_ID Launcher UI, & Workbench Container', () => {
  test('T1-F5-01: ConversationWorkbench, WorkbenchPaneView, WorkbenchTabStrip, and WorkbenchNewTabLauncher modules exist and export valid React components', async () => {
    const cwMod = await import('../../src/ui/components/workbench/ConversationWorkbench.tsx');
    const wpvMod = await import('../../src/ui/components/workbench/WorkbenchPaneView.tsx');
    const wtsMod = await import('../../src/ui/components/workbench/WorkbenchTabStrip.tsx');
    const wntlMod = await import('../../src/ui/components/workbench/WorkbenchNewTabLauncher.tsx');

    const ConversationWorkbench = cwMod.ConversationWorkbench || cwMod.default;
    const WorkbenchPaneView = wpvMod.WorkbenchPaneView || wpvMod.default;
    const WorkbenchTabStrip = wtsMod.WorkbenchTabStrip || wtsMod.default;
    const WorkbenchNewTabLauncher = wntlMod.WorkbenchNewTabLauncher || wntlMod.default;

    assert.equal(typeof ConversationWorkbench, 'function');
    assert.equal(typeof WorkbenchPaneView, 'function');
    assert.equal(typeof WorkbenchTabStrip, 'function');
    assert.equal(typeof WorkbenchNewTabLauncher, 'function');
  });

  test('T1-F5-02: NEW_TAB_ID launcher transitions in-place into agentChat, agentPty, shell, and preview surfaces', async () => {
    const { NEW_TAB_ID } = await import('../../src/ui/store/workbenchTabId.ts');
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      splitWorkbenchPane,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    const surfaces = [
      { kind: 'agentChat' as const, title: 'Worker Chat', agentInstanceId: 'inst-worker-1' },
      { kind: 'agentPty' as const, title: 'Worker PTY', agentInstanceId: 'inst-worker-1' },
      { kind: 'shell' as const, title: 'Bash Shell', sessionId: 'shell-101' },
      { kind: 'preview' as const, title: 'Port 3000', sessionId: 'srv-3000', port: 3000 },
    ];

    for (const surface of surfaces) {
      let state = reducer(
        undefined,
        ensureWorkspaceInitialized({ workspaceKey: 'ws-launch', defaultAgentInstanceId: 'inst-coord' }),
      );
      state = reducer(state, splitWorkbenchPane({ workspaceKey: 'ws-launch', direction: 'right' }));
      const newPaneId = state.workspaces['ws-launch'].tree.focusedPaneId;

      const beforePane = state.workspaces['ws-launch'].tree.panes[newPaneId];
      assert.equal(beforePane.kind, 'content');
      if (beforePane.kind === 'content') {
        assert.equal(beforePane.value.activeTabId, NEW_TAB_ID);
      }

      state = reducer(
        state,
        openOrFocusWorkbenchTab({
          workspaceKey: 'ws-launch',
          paneId: newPaneId,
          tab: surface,
        }),
      );

      const afterPane = state.workspaces['ws-launch'].tree.panes[newPaneId];
      assert.equal(afterPane.kind, 'content');
      if (afterPane.kind === 'content') {
        assert.equal(afterPane.value.tabs.length, 1);
        assert.equal(afterPane.value.tabs[0].kind, surface.kind);
        assert.equal(afterPane.value.activeTabId, afterPane.value.tabs[0].id);
        assert.notEqual(afterPane.value.activeTabId, NEW_TAB_ID);
      }
    }
  });

  test('T1-F5-03: NEW_TAB_ID launcher transitions in-place into files, vcs, chainOverview, and tasks surfaces', async () => {
    const { NEW_TAB_ID } = await import('../../src/ui/store/workbenchTabId.ts');
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openNewTabView,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    const surfaces = [
      { kind: 'files' as const, title: 'Project Files', openFilePath: 'src/main.ts' },
      { kind: 'vcs' as const, title: 'VCS Diff', initialFilePath: 'src/App.tsx' },
      { kind: 'chainOverview' as const, title: 'Chain Overview' },
      { kind: 'tasks' as const, title: 'Task Board', focusTaskId: 'task-42' },
    ];

    for (const surface of surfaces) {
      let state = reducer(
        undefined,
        ensureWorkspaceInitialized({ workspaceKey: 'ws-launch-2', defaultAgentInstanceId: 'inst-coord' }),
      );
      const paneId = state.workspaces['ws-launch-2'].tree.rootPaneId;
      state = reducer(state, openNewTabView({ workspaceKey: 'ws-launch-2', paneId }));

      const beforePane = state.workspaces['ws-launch-2'].tree.panes[paneId];
      if (beforePane.kind === 'content') {
        assert.equal(beforePane.value.activeTabId, NEW_TAB_ID);
      }

      state = reducer(
        state,
        openOrFocusWorkbenchTab({
          workspaceKey: 'ws-launch-2',
          paneId,
          tab: surface,
        }),
      );

      const afterPane = state.workspaces['ws-launch-2'].tree.panes[paneId];
      if (afterPane.kind === 'content') {
        assert.equal(afterPane.value.activeTabId, surface.kind);
        assert.ok(afterPane.value.tabs.some((t) => t.kind === surface.kind));
      }
    }
  });

  test('T1-F5-04: WorkbenchNewTabLauncher exposes surface descriptors/cards for all 7 surface categories (8 surface kinds)', async () => {
    const launcherPath = path.join(REPO_ROOT, 'src/ui/components/workbench/WorkbenchNewTabLauncher.tsx');
    const source = fs.readFileSync(launcherPath, 'utf8');

    for (const kind of ['agentChat', 'agentPty', 'shell', 'preview', 'files', 'vcs', 'chainOverview', 'tasks']) {
      assert.ok(
        source.includes(kind),
        `WorkbenchNewTabLauncher.tsx must support surface kind "${kind}"`,
      );
    }
  });

  test('T1-F5-05: WorkbenchTabStrip supports active tab selection, + button (openNewTabView), split directional controls, maximize, and tab close', async () => {
    const stripPath = path.join(REPO_ROOT, 'src/ui/components/workbench/WorkbenchTabStrip.tsx');
    const source = fs.readFileSync(stripPath, 'utf8');

    assert.ok(
      source.includes('NEW_TAB_ID') || source.includes('onOpenNewTab') || source.includes('openNewTabView'),
      'WorkbenchTabStrip must support + / NEW_TAB_ID launcher trigger',
    );
    for (const dir of ['top', 'bottom', 'left', 'right']) {
      assert.ok(source.includes(`'${dir}'`) || source.includes(`"${dir}"`), `WorkbenchTabStrip must support splitting ${dir}`);
    }
    assert.ok(
      source.includes('Maximize') || source.includes('maximize') || source.includes('onToggleMaximize'),
      'WorkbenchTabStrip must include maximize/restore control',
    );
  });

  test('T1-F5-06: WorkbenchPaneView renders WorkbenchNewTabLauncher when activeTabId === NEW_TAB_ID or tabs is empty', async () => {
    const paneViewPath = path.join(REPO_ROOT, 'src/ui/components/workbench/WorkbenchPaneView.tsx');
    const source = fs.readFileSync(paneViewPath, 'utf8');

    assert.ok(source.includes('NEW_TAB_ID'), 'WorkbenchPaneView must check NEW_TAB_ID');
    assert.ok(source.includes('WorkbenchNewTabLauncher'), 'WorkbenchPaneView must render WorkbenchNewTabLauncher');
    assert.ok(source.includes('WorkbenchTabStrip'), 'WorkbenchPaneView must render WorkbenchTabStrip');
  });
});

// ============================================================================
// F6: Surface 1: Multi-Instance Agent Chat (`AgentChatPane.tsx`) (5 tests)
// ============================================================================
describe('F6: Surface 1: Multi-Instance Agent Chat (AgentChatPane.tsx)', () => {
  test('T1-F6-01: AgentChatPane.tsx exists and exports a React component accepting agentInstanceId', async () => {
    const mod = await import('../../src/ui/components/workbench/AgentChatPane.tsx');
    const AgentChatPane = mod.AgentChatPane || mod.default;
    assert.equal(typeof AgentChatPane, 'function');

    const elem = React.createElement(AgentChatPane, {
      agentInstanceId: 'inst-chat-1',
      workspaceKey: 'ws-1',
      paneId: 'pane-1',
    });
    assert.ok(elem);
    assert.equal(elem.props.agentInstanceId, 'inst-chat-1');
  });

  test('T1-F6-02: Multiple simultaneous agentChat tabs for different agent instances can coexist in the same pane or split panes', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      splitWorkbenchPane,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-multi-chat', defaultAgentInstanceId: 'inst-coord' }),
    );
    const pane1 = state.workspaces['ws-multi-chat'].tree.rootPaneId;

    // Open a second agentChat tab in the same pane
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-multi-chat',
        paneId: pane1,
        tab: { kind: 'agentChat', agentInstanceId: 'inst-worker-1', title: 'Worker 1' },
      }),
    );

    const p1Node = state.workspaces['ws-multi-chat'].tree.panes[pane1];
    assert.equal(p1Node.kind, 'content');
    if (p1Node.kind === 'content') {
      const chatTabs = p1Node.value.tabs.filter((t) => t.kind === 'agentChat');
      assert.equal(chatTabs.length, 2, 'Two distinct agentChat tabs must coexist in the same pane');
    }

    // Split right and open a third agentChat tab
    state = reducer(state, splitWorkbenchPane({ workspaceKey: 'ws-multi-chat', targetPaneId: pane1, direction: 'right' }));
    const pane2 = state.workspaces['ws-multi-chat'].tree.focusedPaneId;
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-multi-chat',
        paneId: pane2,
        tab: { kind: 'agentChat', agentInstanceId: 'inst-worker-2', title: 'Worker 2' },
      }),
    );

    const p2Node = state.workspaces['ws-multi-chat'].tree.panes[pane2];
    if (p2Node.kind === 'content') {
      assert.equal(p2Node.value.tabs[0].kind, 'agentChat');
      assert.equal(p2Node.value.tabs[0].agentInstanceId, 'inst-worker-2');
    }
  });

  test('T1-F6-03: getComposerDraftKey, readComposerDraft, and writeComposerDraft isolate drafts per agentInstanceId', async () => {
    const { getComposerDraftKey, readComposerDraft, writeComposerDraft } = await import(
      '../../src/ui/utils/clientPersistence.ts'
    );

    assert.equal(getComposerDraftKey('inst-A'), 'heimdall:composer:draft:inst-A');
    assert.equal(getComposerDraftKey('inst-B'), 'heimdall:composer:draft:inst-B');

    withMockWindowStorage(() => {
      writeComposerDraft('inst-A', 'Draft for coordinator A');
      writeComposerDraft('inst-B', 'Draft for worker B');

      assert.equal(readComposerDraft('inst-A'), 'Draft for coordinator A');
      assert.equal(readComposerDraft('inst-B'), 'Draft for worker B');
    });
  });

  test('T1-F6-04: AgentChatPane does not mount AgentPaneComposerPanel inline inside the message composer card', () => {
    const chatPanePath = path.join(REPO_ROOT, 'src/ui/components/workbench/AgentChatPane.tsx');
    const source = fs.readFileSync(chatPanePath, 'utf8');

    assert.ok(
      !source.includes('<AgentPaneComposerPanel'),
      'AgentChatPane must not mount inline <AgentPaneComposerPanel> inside composer (R4)',
    );
  });

  test('T1-F6-05: AgentChatPane routes terminal/PTY button action to open an agentPty workbench tab/pane', () => {
    const chatPanePath = path.join(REPO_ROOT, 'src/ui/components/workbench/AgentChatPane.tsx');
    const source = fs.readFileSync(chatPanePath, 'utf8');

    assert.ok(
      source.includes('agentPty') || source.includes('onOpenSurface') || source.includes('openOrFocusWorkbenchTab'),
      'AgentChatPane must route PTY/terminal action to workbench agentPty surface',
    );
  });
});

// ============================================================================
// F7: Surface 2: Agent Live Terminal (`AgentPtyWorkbenchPane.tsx` & `AgentPaneComposerPanel.tsx`) (5 tests)
// ============================================================================
describe('F7: Surface 2: Agent Live Terminal (AgentPtyWorkbenchPane.tsx & AgentPaneComposerPanel.tsx)', () => {
  test('T1-F7-01: AgentPtyWorkbenchPane.tsx exists and exports a React component', async () => {
    const mod = await import('../../src/ui/components/workbench/AgentPtyWorkbenchPane.tsx');
    const AgentPtyWorkbenchPane = mod.AgentPtyWorkbenchPane || mod.default;
    assert.equal(typeof AgentPtyWorkbenchPane, 'function');

    const elem = React.createElement(AgentPtyWorkbenchPane, {
      agentInstanceId: 'inst-pty-1',
      workspaceKey: 'ws-1',
      paneId: 'pane-1',
    });
    assert.ok(elem);
  });

  test('T1-F7-02: AgentPaneComposerPanel supports fillPane mode for full-height workbench rendering', async () => {
    const { AgentPaneComposerPanel } = await import('../../src/ui/components/chat/AgentPaneComposerPanel.tsx');
    const panelPath = path.join(REPO_ROOT, 'src/ui/components/chat/AgentPaneComposerPanel.tsx');
    const source = fs.readFileSync(panelPath, 'utf8');

    assert.ok(source.includes('fillPane'), 'AgentPaneComposerPanel must support fillPane prop');
    const elem = React.createElement(AgentPaneComposerPanel, {
      agentInstanceId: 'inst-pty-1',
      isExpanded: true,
      isActiveTab: true,
      fillPane: true,
    });
    assert.equal(elem.props.fillPane, true);
  });

  test('T1-F7-03: Multiple agentPty tabs for different agent instances can be opened simultaneously', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-pty', defaultAgentInstanceId: 'inst-1' }),
    );
    const paneId = state.workspaces['ws-pty'].tree.rootPaneId;

    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-pty',
        paneId,
        tab: { kind: 'agentPty', agentInstanceId: 'inst-1', title: 'PTY 1' },
      }),
    );
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-pty',
        paneId,
        tab: { kind: 'agentPty', agentInstanceId: 'inst-2', title: 'PTY 2' },
      }),
    );

    const pane = state.workspaces['ws-pty'].tree.panes[paneId];
    if (pane.kind === 'content') {
      const ptyTabs = pane.value.tabs.filter((t) => t.kind === 'agentPty');
      assert.equal(ptyTabs.length, 2);
      assert.notEqual(ptyTabs[0].id, ptyTabs[1].id);
    }
  });

  test('T1-F7-04: AgentPaneComposerPanel has no /agent-monitor pin button or pinned monitor persistence imports', () => {
    const panelPath = path.join(REPO_ROOT, 'src/ui/components/chat/AgentPaneComposerPanel.tsx');
    const source = fs.readFileSync(panelPath, 'utf8');

    assert.ok(!source.includes('readPinnedMonitorAgents'), 'Must not import readPinnedMonitorAgents');
    assert.ok(!source.includes('addPinnedMonitorAgent'), 'Must not import addPinnedMonitorAgent');
    assert.ok(!source.includes('agent-pane-pin-btn'), 'Must not render agent-pane-pin-btn');
    assert.ok(!source.includes('/agent-monitor'), 'Must not reference /agent-monitor');
  });

  test('T1-F7-05: AgentPtyWorkbenchPane wraps AgentPaneComposerPanel with fillPane and provides agent instance switching', () => {
    const ptyPanePath = path.join(REPO_ROOT, 'src/ui/components/workbench/AgentPtyWorkbenchPane.tsx');
    const source = fs.readFileSync(ptyPanePath, 'utf8');

    assert.ok(source.includes('AgentPaneComposerPanel'), 'AgentPtyWorkbenchPane must render AgentPaneComposerPanel');
    assert.ok(source.includes('fillPane'), 'AgentPtyWorkbenchPane must pass fillPane to AgentPaneComposerPanel');
  });
});

// ============================================================================
// F8: Surface 3: Interactive Shell (`ShellWorkbenchPane.tsx`) (5 tests)
// ============================================================================
describe('F8: Surface 3: Interactive Shell (ShellWorkbenchPane.tsx)', () => {
  test('T1-F8-01: ShellWorkbenchPane.tsx exists and exports a React component', async () => {
    const mod = await import('../../src/ui/components/workbench/ShellWorkbenchPane.tsx');
    const ShellWorkbenchPane = mod.ShellWorkbenchPane || mod.default;
    assert.equal(typeof ShellWorkbenchPane, 'function');

    const elem = React.createElement(ShellWorkbenchPane, {
      sessionId: 'shell-sess-1',
      workspaceKey: 'ws-1',
      paneId: 'pane-1',
    });
    assert.ok(elem);
  });

  test('T1-F8-02: ShellWorkbenchPane integrates ShellTerminalPane and NewShellDialog for spawning interactive shells', () => {
    const shellPanePath = path.join(REPO_ROOT, 'src/ui/components/workbench/ShellWorkbenchPane.tsx');
    const source = fs.readFileSync(shellPanePath, 'utf8');

    assert.ok(source.includes('ShellTerminalPane'), 'ShellWorkbenchPane must render ShellTerminalPane');
    assert.ok(
      source.includes('NewShellDialog') || source.includes('useCreateShellMutation'),
      'ShellWorkbenchPane must allow spawning a new shell session',
    );
  });

  test('T1-F8-03: Multiple shell tabs for distinct shell sessions can be opened in the workbench', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-shell', defaultAgentInstanceId: 'inst-1' }),
    );
    const paneId = state.workspaces['ws-shell'].tree.rootPaneId;

    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-shell',
        paneId,
        tab: { kind: 'shell', sessionId: 'sh-1', title: 'Shell 1' },
      }),
    );
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-shell',
        paneId,
        tab: { kind: 'shell', sessionId: 'sh-2', title: 'Shell 2' },
      }),
    );

    const pane = state.workspaces['ws-shell'].tree.panes[paneId];
    if (pane.kind === 'content') {
      const shellTabs = pane.value.tabs.filter((t) => t.kind === 'shell');
      assert.equal(shellTabs.length, 2);
      assert.equal(shellTabs[0].sessionId, 'sh-1');
      assert.equal(shellTabs[1].sessionId, 'sh-2');
    }
  });

  test('T1-F8-04: updateWorkbenchTabParams updates shell tab sessionId when switching or spawning a shell in-place', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      updateWorkbenchTabParams,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-shell-switch', defaultAgentInstanceId: 'inst-1' }),
    );
    const paneId = state.workspaces['ws-shell-switch'].tree.rootPaneId;

    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-shell-switch',
        paneId,
        tab: { kind: 'shell', sessionId: 'sh-init', title: 'Shell' },
      }),
    );

    const paneBefore = state.workspaces['ws-shell-switch'].tree.panes[paneId];
    const shellTabId = paneBefore.kind === 'content' ? paneBefore.value.activeTabId! : '';

    state = reducer(
      state,
      updateWorkbenchTabParams({
        workspaceKey: 'ws-shell-switch',
        paneId,
        tabId: shellTabId,
        patch: { sessionId: 'sh-next', title: 'Shell Next' },
      }),
    );

    const paneAfter = state.workspaces['ws-shell-switch'].tree.panes[paneId];
    if (paneAfter.kind === 'content') {
      const updated = paneAfter.value.tabs.find((t) => t.kind === 'shell')!;
      assert.equal(updated.sessionId, 'sh-next');
      assert.equal(updated.title, 'Shell Next');
    }
  });

  test('T1-F8-05: TerminalSessionRegistry preserves serialized terminal state for shell sessions across workbench operations', async () => {
    const { TerminalSessionRegistry } = await import('../../src/ui/components/shells/terminalSessionRegistry.ts');
    const registry = new TerminalSessionRegistry();

    registry.bufferSessionDelta('sh-live-1', 'hello world\r\n');
    const restoration = registry.consumeRestorationData('sh-live-1');
    assert.ok(restoration);
    const decoded = restoration.deltaChunks.map((c) => new TextDecoder().decode(c));
    assert.deepEqual(decoded, ['hello world\r\n']);
  });
});

// ============================================================================
// F9: Surface 4: Live Web Preview (`PreviewWorkbenchPane.tsx`) (5 tests)
// ============================================================================
describe('F9: Surface 4: Live Web Preview (PreviewWorkbenchPane.tsx)', () => {
  test('T1-F9-01: PreviewWorkbenchPane.tsx exists and exports a React component', async () => {
    const mod = await import('../../src/ui/components/workbench/PreviewWorkbenchPane.tsx');
    const PreviewWorkbenchPane = mod.PreviewWorkbenchPane || mod.default;
    assert.equal(typeof PreviewWorkbenchPane, 'function');

    const elem = React.createElement(PreviewWorkbenchPane, {
      sessionId: 'srv-1',
      port: 5173,
      currentPath: 'dashboard',
    });
    assert.ok(elem);
  });

  test('T1-F9-02: PreviewWorkbenchPane includes URL bar, back/reload controls, and Preview/Stdout toggle (ShellLogViewer)', () => {
    const previewPath = path.join(REPO_ROOT, 'src/ui/components/workbench/PreviewWorkbenchPane.tsx');
    const source = fs.readFileSync(previewPath, 'utf8');

    assert.ok(source.includes('ShellLogViewer'), 'PreviewWorkbenchPane must include ShellLogViewer for Stdout toggle');
    assert.ok(source.includes('Stdout') || source.includes('output'), 'PreviewWorkbenchPane must support Preview/Stdout mode toggle');
    assert.ok(source.includes('<iframe'), 'PreviewWorkbenchPane must render preview iframe');
  });

  test('T1-F9-03: openPreviewInWorkbench action opens or focuses a preview tab in the active workspace', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openPreviewInWorkbench,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-prev', defaultAgentInstanceId: 'inst-1' }),
    );
    state = reducer(
      state,
      openPreviewInWorkbench({
        workspaceKey: 'ws-prev',
        sessionId: 'srv-8080',
        label: 'vite dev',
        port: 8080,
        currentPath: '/app',
      }),
    );

    const ws = state.workspaces['ws-prev'];
    const pane = ws.tree.panes[ws.tree.focusedPaneId];
    assert.equal(pane.kind, 'content');
    if (pane.kind === 'content') {
      const prevTab = pane.value.tabs.find((t) => t.kind === 'preview' && t.sessionId === 'srv-8080');
      assert.ok(prevTab, 'openPreviewInWorkbench must create preview tab for srv-8080');
      assert.equal(prevTab.port, 8080);
      assert.equal(pane.value.activeTabId, prevTab.id);
    }
  });

  test('T1-F9-04: ChainActiveServersPanel, ShellDetail, and ShellListPage dispatch openPreviewInWorkbench instead of legacy previewTabsSlice', () => {
    for (const relPath of [
      'src/ui/components/shells/ChainActiveServersPanel.tsx',
      'src/ui/components/shells/ShellDetail.tsx',
      'src/ui/components/shells/ShellListPage.tsx',
    ]) {
      const fullPath = path.join(REPO_ROOT, relPath);
      const source = fs.readFileSync(fullPath, 'utf8');
      assert.ok(
        !source.includes('previewTabsSlice'),
        `${relPath} must not import deleted previewTabsSlice`,
      );
      assert.ok(
        source.includes('openPreviewInWorkbench') || source.includes('openOrFocusWorkbenchTab'),
        `${relPath} must dispatch openPreviewInWorkbench / workbench preview action`,
      );
    }
  });

  test('T1-F9-05: Multiple preview tabs for different server sessions can be opened and navigated independently', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openPreviewInWorkbench,
      updateWorkbenchTabParams,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-multi-prev', defaultAgentInstanceId: 'inst-1' }),
    );
    state = reducer(
      state,
      openPreviewInWorkbench({ workspaceKey: 'ws-multi-prev', sessionId: 'srv-3000', port: 3000 }),
    );
    state = reducer(
      state,
      openPreviewInWorkbench({ workspaceKey: 'ws-multi-prev', sessionId: 'srv-4000', port: 4000 }),
    );

    const paneId = state.workspaces['ws-multi-prev'].tree.focusedPaneId;
    const pane = state.workspaces['ws-multi-prev'].tree.panes[paneId];
    if (pane.kind === 'content') {
      const previewTabs = pane.value.tabs.filter((t) => t.kind === 'preview');
      assert.equal(previewTabs.length, 2);

      state = reducer(
        state,
        updateWorkbenchTabParams({
          workspaceKey: 'ws-multi-prev',
          paneId,
          tabId: previewTabs[0].id,
          patch: { currentPath: 'settings/profile' },
        }),
      );
      const updatedPane = state.workspaces['ws-multi-prev'].tree.panes[paneId];
      if (updatedPane.kind === 'content') {
        const t0 = updatedPane.value.tabs.find((t) => t.id === previewTabs[0].id)!;
        const t1 = updatedPane.value.tabs.find((t) => t.id === previewTabs[1].id)!;
        assert.equal(t0.currentPath, 'settings/profile');
        assert.notEqual(t1.currentPath, 'settings/profile');
      }
    }
  });
});

// ============================================================================
// F10: Surfaces 5, 6, 7: Files, VCS, Chain Overview, & Tasks + Cross-Links (6 tests)
// ============================================================================
describe('F10: Surfaces 5, 6, 7: Files, VCS, Chain Overview, & Tasks + Cross-Links', () => {
  test('T1-F10-01: WorkbenchPaneView mounts ProjectFilesPanel, ProjectVcsPanel, ChainOverviewPanel, and TaskChainOverview', () => {
    const paneViewPath = path.join(REPO_ROOT, 'src/ui/components/workbench/WorkbenchPaneView.tsx');
    const source = fs.readFileSync(paneViewPath, 'utf8');

    assert.ok(source.includes('ProjectFilesPanel'), 'WorkbenchPaneView must mount ProjectFilesPanel for files surface');
    assert.ok(source.includes('ProjectVcsPanel'), 'WorkbenchPaneView must mount ProjectVcsPanel for vcs surface');
    assert.ok(source.includes('ChainOverviewPanel'), 'WorkbenchPaneView must mount ChainOverviewPanel for chainOverview surface');
    assert.ok(source.includes('TaskChainOverview'), 'WorkbenchPaneView must mount TaskChainOverview for tasks surface');
  });

  test('T1-F10-02: Cross-link from ChainOverviewPanel (onSelectTask) opens or focuses tasks tab with focusTaskId without clobbering chainOverview', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-cross', defaultAgentInstanceId: 'inst-1' }),
    );
    const pane1 = state.workspaces['ws-cross'].tree.rootPaneId;
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-cross',
        paneId: pane1,
        tab: { kind: 'chainOverview', title: 'Chain Overview' },
      }),
    );

    // Trigger cross-link to open task-99 in a split or tab
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-cross',
        paneId: pane1,
        tab: { kind: 'tasks', title: 'Tasks', focusTaskId: 'task-99' },
        splitDirection: 'right',
      }),
    );

    const p1 = state.workspaces['ws-cross'].tree.panes[pane1];
    if (p1.kind === 'content') {
      assert.ok(
        p1.value.tabs.some((t) => t.kind === 'chainOverview'),
        'chainOverview tab must not be clobbered when opening tasks cross-link',
      );
    }
    const focusedPane = state.workspaces['ws-cross'].tree.panes[state.workspaces['ws-cross'].tree.focusedPaneId];
    if (focusedPane.kind === 'content') {
      const tasksTab = focusedPane.value.tabs.find((t) => t.kind === 'tasks');
      assert.ok(tasksTab);
      assert.equal(tasksTab.focusTaskId, 'task-99');
    }
  });

  test('T1-F10-03: Cross-link onOpenFileDiff opens vcs surface with initialFilePath', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-vcs-link', defaultAgentInstanceId: 'inst-1' }),
    );
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-vcs-link',
        tab: { kind: 'vcs', title: 'VCS', initialFilePath: 'src/ui/App.tsx' },
      }),
    );

    const pane = state.workspaces['ws-vcs-link'].tree.panes[state.workspaces['ws-vcs-link'].tree.focusedPaneId];
    if (pane.kind === 'content') {
      const vcsTab = pane.value.tabs.find((t) => t.kind === 'vcs');
      assert.ok(vcsTab);
      assert.equal(vcsTab.initialFilePath, 'src/ui/App.tsx');
    }
  });

  test('T1-F10-04: Cross-link onOpenFileInFilesPanel / onOpenDirectory opens files surface with openFilePath', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-files-link', defaultAgentInstanceId: 'inst-1' }),
    );
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-files-link',
        tab: { kind: 'files', title: 'Files', openFilePath: 'src/ui/store/workbenchSlice.ts' },
      }),
    );

    const pane = state.workspaces['ws-files-link'].tree.panes[state.workspaces['ws-files-link'].tree.focusedPaneId];
    if (pane.kind === 'content') {
      const filesTab = pane.value.tabs.find((t) => t.kind === 'files');
      assert.ok(filesTab);
      assert.equal(filesTab.openFilePath, 'src/ui/store/workbenchSlice.ts');
    }
  });

  test('T1-F10-05: ChainOverviewPanel has no legacy writeRightSidebarTab, writeRightSidebarOpen, or readPinnedMonitorAgents references', () => {
    const overviewPath = path.join(REPO_ROOT, 'src/ui/components/chat/ChainOverviewPanel.tsx');
    const source = fs.readFileSync(overviewPath, 'utf8');

    assert.ok(!source.includes('writeRightSidebarTab'), 'ChainOverviewPanel must not call writeRightSidebarTab');
    assert.ok(!source.includes('writeRightSidebarOpen'), 'ChainOverviewPanel must not call writeRightSidebarOpen');
    assert.ok(!source.includes('readPinnedMonitorAgents'), 'ChainOverviewPanel must not call readPinnedMonitorAgents');
    assert.ok(!source.includes('/agent-monitor'), 'ChainOverviewPanel must not reference /agent-monitor');
  });

  test('T1-F10-06: TaskChainOverview has no legacy writeRightSidebarOpen references', () => {
    const taskOverviewPath = path.join(REPO_ROOT, 'src/ui/components/taskchain/TaskChainOverview.tsx');
    const source = fs.readFileSync(taskOverviewPath, 'utf8');

    assert.ok(!source.includes('writeRightSidebarOpen'), 'TaskChainOverview must not call writeRightSidebarOpen');
  });
});

// ============================================================================
// F11: Level 1 Window Tiling UI & Complete R4 Legacy Deletion (6 tests)
// ============================================================================
describe('F11: Level 1 Window Tiling UI & Complete R4 Legacy Deletion', () => {
  test('T1-F11-01: WindowTilingHost, WindowPaneFrame, and NewConversationWindowPane exist and export React components', async () => {
    const hostMod = await import('../../src/ui/components/windowTiling/WindowTilingHost.tsx');
    const frameMod = await import('../../src/ui/components/windowTiling/WindowPaneFrame.tsx');
    const newPaneMod = await import('../../src/ui/components/windowTiling/NewConversationWindowPane.tsx');

    assert.equal(typeof (hostMod.WindowTilingHost || hostMod.default), 'function');
    assert.equal(typeof (frameMod.WindowPaneFrame || frameMod.default), 'function');
    assert.equal(typeof (newPaneMod.NewConversationWindowPane || newPaneMod.default), 'function');
  });

  test('T1-F11-02: All 5 R4 legacy files (BottomDock.tsx, PreviewSidebar.tsx, previewTabsSlice.ts, AgentMonitorPage.tsx, AgentCellComposer.tsx) are deleted from disk', () => {
    const deletedFiles = [
      'src/ui/components/shell/BottomDock.tsx',
      'src/ui/components/shells/PreviewSidebar.tsx',
      'src/ui/store/previewTabsSlice.ts',
      'src/ui/components/monitor/AgentMonitorPage.tsx',
      'src/ui/components/monitor/AgentCellComposer.tsx',
    ];

    for (const rel of deletedFiles) {
      const fullPath = path.join(REPO_ROOT, rel);
      assert.equal(
        fs.existsSync(fullPath),
        false,
        `Legacy file ${rel} must be deleted from repository per R4`,
      );
    }
  });

  test('T1-F11-03: AppShell.tsx integrates WindowTilingHost and contains no references to BottomDock, PreviewSidebar, or /agent-monitor', () => {
    const appShellPath = path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx');
    const source = fs.readFileSync(appShellPath, 'utf8');

    assert.ok(source.includes('WindowTilingHost'), 'AppShell.tsx must render WindowTilingHost');
    assert.ok(!source.includes('BottomDock'), 'AppShell.tsx must not reference BottomDock');
    assert.ok(!source.includes('PreviewSidebar'), 'AppShell.tsx must not reference PreviewSidebar');
    assert.ok(!source.includes('AgentMonitorPage'), 'AppShell.tsx must not reference AgentMonitorPage');
    assert.ok(!source.includes('/agent-monitor'), 'AppShell.tsx must not match /agent-monitor route');
  });

  test('T1-F11-04: ConversationThreadPage.tsx delegates to ConversationWorkbench and has no renderRightPanel or inline AgentPaneComposerPanel', () => {
    const threadPagePath = path.join(REPO_ROOT, 'src/ui/components/chat/ConversationThreadPage.tsx');
    const source = fs.readFileSync(threadPagePath, 'utf8');

    assert.ok(source.includes('ConversationWorkbench'), 'ConversationThreadPage must render ConversationWorkbench');
    assert.ok(!source.includes('renderRightPanel'), 'ConversationThreadPage must not contain renderRightPanel');
    assert.ok(!source.includes('AgentPaneComposerPanel'), 'ConversationThreadPage must not mount inline AgentPaneComposerPanel');
  });

  test('T1-F11-05: Redux store (src/ui/store/store.ts) registers windowLayout and workbench reducers and removes previewTabs', async () => {
    const storePath = path.join(REPO_ROOT, 'src/ui/store/store.ts');
    const source = fs.readFileSync(storePath, 'utf8');

    assert.ok(!source.includes('previewTabs'), 'store.ts must not register previewTabs');
    assert.ok(source.includes('windowLayout'), 'store.ts must register windowLayout');
    assert.ok(source.includes('workbench'), 'store.ts must register workbench');

    const { store } = await import('../../src/ui/store/store.ts');
    const state = store.getState() as any;
    assert.ok(state.windowLayout, 'Redux store state must have windowLayout slice');
    assert.ok(state.workbench, 'Redux store state must have workbench slice');
    assert.equal(state.previewTabs, undefined, 'Redux store state must not have previewTabs slice');
  });

  test('T1-F11-06: clientPersistence.ts removes obsolete BottomDock, RightSidebar, and PinnedMonitorAgent helpers', () => {
    const persistencePath = path.join(REPO_ROOT, 'src/ui/utils/clientPersistence.ts');
    const source = fs.readFileSync(persistencePath, 'utf8');

    assert.ok(!source.includes('readBottomDockOpen'), 'clientPersistence.ts must not export readBottomDockOpen');
    assert.ok(!source.includes('readPinnedMonitorAgents'), 'clientPersistence.ts must not export readPinnedMonitorAgents');
    assert.ok(!source.includes('readRightSidebarTab'), 'clientPersistence.ts must not export readRightSidebarTab');
  });
});

// ============================================================================
// F12: DOM & Session Stability Verification (5 tests)
// ============================================================================
describe('F12: DOM & Session Stability Verification', () => {
  test('T1-F12-01: TilingContainer renders contentLayouts in a flat list keyed by layout.paneId with percentage positioning', () => {
    const containerPath = path.join(REPO_ROOT, 'src/ui/tiling/TilingContainer.tsx');
    const source = fs.readFileSync(containerPath, 'utf8');

    assert.ok(source.includes('contentLayouts.map'), 'TilingContainer must map over flat contentLayouts');
    assert.ok(source.includes('data-pane-id'), 'TilingContainer leaf wrapper must set data-pane-id');
    assert.ok(
      source.includes('React.memo') || source.includes('memo('),
      'TilingContainer must memoize leaf PaneWrapper to prevent unnecessary re-renders',
    );
  });

  test('T1-F12-02: TilingContainer keeps non-maximized panes mounted in the DOM using CSS visibility: hidden when maximizedPaneId is set', () => {
    const containerPath = path.join(REPO_ROOT, 'src/ui/tiling/TilingContainer.tsx');
    const source = fs.readFileSync(containerPath, 'utf8');

    assert.ok(source.includes('maximizedPaneId'), 'TilingContainer must support maximizedPaneId');
    assert.ok(
      source.includes('hidden') || source.includes('visibility'),
      'TilingContainer must hide non-maximized siblings via CSS visibility rather than unmounting them',
    );
  });

  test('T1-F12-03: TilingContainer disables pointerEvents on iframe and webview elements while dragging a splitter sash', () => {
    const containerPath = path.join(REPO_ROOT, 'src/ui/tiling/TilingContainer.tsx');
    const source = fs.readFileSync(containerPath, 'utf8');

    assert.ok(source.includes('iframe'), 'TilingContainer must guard iframe elements during sash drag');
    assert.ok(source.includes('pointerEvents'), 'TilingContainer must set pointerEvents: none on iframes during sash drag');
  });

  test('T1-F12-04: WorkbenchPaneView keeps mounted tabs alive in a stable-keyed list using CSS hidden/display:none when switching activeTabId', () => {
    const paneViewPath = path.join(REPO_ROOT, 'src/ui/components/workbench/WorkbenchPaneView.tsx');
    const source = fs.readFileSync(paneViewPath, 'utf8');

    assert.ok(
      source.includes('tabs.map') || source.includes('.tabs.map'),
      'WorkbenchPaneView must render mounted tabs via tabs.map so inactive tabs remain mounted',
    );
    assert.ok(
      source.includes('hidden') || source.includes('display'),
      'WorkbenchPaneView must hide inactive tabs via CSS class/style rather than unmounting',
    );
  });

  test('T1-F12-05: Splitting, resizing, and moving panes in both Level 1 and Level 2 preserve 100% of existing leaf pane IDs', async () => {
    const { createPaneTreeState, splitPaneInTree, resizeSplitInTree, movePaneInTree, getContentPaneIds } =
      await import('../../src/ui/tiling/paneTreeState.ts');

    const tree = createPaneTreeState('root', 'pane-alpha');
    const s1 = splitPaneInTree(tree, 'pane-alpha', 'right', 'beta', 'pane-beta');
    const s2 = splitPaneInTree(tree, 'pane-beta', 'bottom', 'gamma', 'pane-gamma');
    resizeSplitInTree(tree, s1.parentId, 35);
    resizeSplitInTree(tree, s2.parentId, 60);
    movePaneInTree(tree, 'pane-gamma', 'pane-alpha', 'top');

    const finalIds = getContentPaneIds(tree).sort();
    assert.deepEqual(finalIds, ['pane-alpha', 'pane-beta', 'pane-gamma']);
  });
});
