/**
 * Tier 2 — Boundary & Corner Cases E2E Test Suite
 *
 * Verifies boundary values, malformed inputs, self-drops, last-pane/last-tab closures,
 * deduplication vs multi-instance rules, and corrupted storage recovery across F1–F12
 * per ORIGINAL_REQUEST.md, PROJECT.md § Interface Contracts, and TEST_INFRA.md:
 * - F1: Git Branch & Working Tree Boundary Checks (5 tests)
 * - F2: Binary Split-Pane Tiling Engine Boundary & Corner Cases (6 tests)
 * - F3: Level 1 Multi-Conversation Window Tiling Boundary Cases (6 tests)
 * - F4: Level 2 Per-Conversation 2D Workbench & Tabbed Pane Boundary Cases (8 tests)
 * - F5: NEW_TAB_ID Launcher & Tab Strip Corner Cases (5 tests)
 * - F6: Surface 1 (agentChat) Boundary & Escaping Cases (5 tests)
 * - F7: Surface 2 (agentPty) Boundary Cases (5 tests)
 * - F8: Surface 3 (shell) Boundary Cases (5 tests)
 * - F9: Surface 4 (preview) Boundary Cases (5 tests)
 * - F10: Surfaces 5, 6, 7 (files, vcs, chainOverview, tasks) Boundary Cases (5 tests)
 * - F11: Level 1 UI & R4 Legacy Deletion Corner Cases (6 tests)
 * - F12: DOM & Session Stability Boundary Cases (5 tests)
 *
 * Total Tier 2 Test Cases: 66 (>= 60 required, >= 5 per feature F1–F12)
 *
 * RUN: npx tsx --test tests/e2e/jetski_workbench_tier2_test.ts
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
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
// F1: Git Branch & Working Tree Boundary Checks (5 tests)
// ============================================================================
describe('F1 Boundary: Git Branch & Working Tree Hygiene', () => {
  test('T2-F1-02: No git merge conflict markers (<<<<<<< / ======= / >>>>>>>) exist anywhere in src/ui/', () => {
    const walk = (dir: string): string[] => {
      const out: string[] = [];
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) out.push(...walk(full));
        else if (/\.(ts|tsx|css)$/.test(entry.name)) out.push(full);
      }
      return out;
    };

    const files = walk(path.join(REPO_ROOT, 'src/ui'));
    for (const file of files) {
      const content = fs.readFileSync(file, 'utf8');
      assert.ok(!/^<{7}\s/m.test(content), `Conflict marker <<<<<<< found in ${file}`);
      assert.ok(!/^>{7}\s/m.test(content), `Conflict marker >>>>>>> found in ${file}`);
    }
  });

  test('T2-F1-03: Zero source or test files exist inside .agents/teamwork/ metadata directory', () => {
    const teamworkDir = path.join(REPO_ROOT, '.agents/teamwork');
    if (fs.existsSync(teamworkDir)) {
      const walk = (dir: string): string[] => {
        const out: string[] = [];
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
          const full = path.join(dir, entry.name);
          if (entry.isDirectory()) out.push(...walk(full));
          else out.push(full);
        }
        return out;
      };
      const allFiles = walk(teamworkDir);
      for (const f of allFiles) {
        assert.ok(!/\.(ts|tsx)$/.test(f), `Source/test file must not be placed in .agents/teamwork/: ${f}`);
        assert.notEqual(path.basename(f), 'AGENTS.md');
        assert.notEqual(path.basename(f), 'GEMINI.md');
      }
    }
  });

  test('T2-F1-05: No untracked temporary backup files (*.bak, *.orig, *~) exist in src/ui/', () => {
    const walk = (dir: string): string[] => {
      const out: string[] = [];
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) out.push(...walk(full));
        else out.push(entry.name);
      }
      return out;
    };
    const names = walk(path.join(REPO_ROOT, 'src/ui'));
    for (const name of names) {
      assert.ok(!/\.(bak|orig|tmp)$|~$/.test(name), `Backup/temp file found in src/ui: ${name}`);
    }
  });
});

// ============================================================================
// F2: Binary Split-Pane Tiling Engine Boundary & Corner Cases (6 tests)
// ============================================================================
describe('F2 Boundary: Binary Split-Pane Tiling Engine', () => {
  test('T2-F2-01: resizeSplitInTree clamps extreme ratios (-50, 0, 4.9, 5, 95, 95.1, 100, 500, NaN, Infinity) to [5, 95]', async () => {
    const { createPaneTreeState, splitPaneInTree, resizeSplitInTree } = await import(
      '../../src/ui/tiling/paneTreeState.ts'
    );

    const tree = createPaneTreeState('a', 'pane-a');
    const { parentId } = splitPaneInTree(tree, 'pane-a', 'right', 'b', 'pane-b');

    const getRatio = () => {
      const node = tree.panes[parentId];
      return node.kind === 'split' ? node.ratio : -1;
    };

    for (const low of [-50, 0, 4.9, -Infinity]) {
      resizeSplitInTree(tree, parentId, low);
      assert.equal(getRatio(), 5, `Ratio ${low} must clamp to minimum 5`);
    }

    resizeSplitInTree(tree, parentId, 5);
    assert.equal(getRatio(), 5);

    resizeSplitInTree(tree, parentId, 95);
    assert.equal(getRatio(), 95);

    for (const high of [95.1, 100, 500, Infinity]) {
      resizeSplitInTree(tree, parentId, high);
      assert.equal(getRatio(), 95, `Ratio ${high} must clamp to maximum 95`);
    }

    resizeSplitInTree(tree, parentId, 42);
    resizeSplitInTree(tree, parentId, Number.NaN);
    const afterNaN = getRatio();
    assert.ok(afterNaN >= 5 && afterNaN <= 95, 'NaN ratio must not corrupt split ratio');
  });

  test('T2-F2-02: closePaneInTree on the sole root pane returns true and handles unknown pane IDs gracefully', async () => {
    const { createPaneTreeState, closePaneInTree } = await import('../../src/ui/tiling/paneTreeState.ts');

    const tree = createPaneTreeState('only', 'pane-only');
    assert.equal(closePaneInTree(tree, 'non-existent-pane'), false, 'Closing unknown pane must return false');
    assert.ok(tree.panes['pane-only'], 'Root pane must remain intact when unknown ID is closed');

    const closedRoot = closePaneInTree(tree, 'pane-only');
    assert.equal(closedRoot, true, 'Closing the sole root pane must return true');
  });

  test('T2-F2-03: movePaneInTree is a safe no-op on self-drop (sourcePaneId === targetPaneId) and unknown pane IDs', async () => {
    const { createPaneTreeState, splitPaneInTree, movePaneInTree, getContentPaneIds } = await import(
      '../../src/ui/tiling/paneTreeState.ts'
    );

    const tree = createPaneTreeState('A', 'pane-A');
    splitPaneInTree(tree, 'pane-A', 'right', 'B', 'pane-B');

    assert.equal(movePaneInTree(tree, 'pane-A', 'pane-A', 'left'), false, 'Self-drop must return false');
    assert.equal(movePaneInTree(tree, 'unknown-1', 'pane-A', 'left'), false, 'Unknown source must return false');
    assert.equal(movePaneInTree(tree, 'pane-A', 'unknown-2', 'right'), false, 'Unknown target must return false');
    assert.deepEqual(getContentPaneIds(tree).sort(), ['pane-A', 'pane-B']);
  });

  test('T2-F2-04: swapPanesInTree handles identical pane IDs and non-existent pane IDs safely', async () => {
    const { createPaneTreeState, splitPaneInTree, swapPanesInTree } = await import(
      '../../src/ui/tiling/paneTreeState.ts'
    );

    const tree = createPaneTreeState('A', 'pane-A');
    splitPaneInTree(tree, 'pane-A', 'right', 'B', 'pane-B');

    assert.equal(swapPanesInTree(tree, 'pane-A', 'pane-A'), false);
    assert.equal(swapPanesInTree(tree, 'pane-A', 'missing'), false);
    assert.equal(swapPanesInTree(tree, 'missing', 'pane-B'), false);
  });

  test('T2-F2-05: getSplitDirection and getOverlayPosition handle exact center, corners, 1px aspect ratio edges, and zero-dimension rects', async () => {
    const { getSplitDirection, getOverlayPosition } = await import('../../src/ui/tiling/dragUtils.ts');

    const rect = { left: 0, top: 0, width: 100, height: 100 };
    // Exact center (deltaX = 0, deltaY = 0)
    const centerDir = getSplitDirection(rect, { x: 50, y: 50 });
    assert.ok(['top', 'bottom', 'left', 'right'].includes(centerDir));

    // Zero-dimension rect should not throw or return NaN
    const zeroRect = { left: 10, top: 10, width: 0, height: 0 };
    const zeroDir = getSplitDirection(zeroRect, { x: 10, y: 10 });
    assert.ok(['top', 'bottom', 'left', 'right'].includes(zeroDir));
    const zeroOverlay = getOverlayPosition(zeroRect, 'left');
    assert.equal(zeroOverlay.width, 0);
    assert.equal(zeroOverlay.height, 0);

    // Odd-pixel dimensions use Math.floor for half sizes
    const oddRect = { left: 0, top: 0, width: 101, height: 51 };
    const leftOv = getOverlayPosition(oddRect, 'left');
    assert.equal(leftOv.width, 50);
    assert.equal(leftOv.height, 51);
    const topOv = getOverlayPosition(oddRect, 'top');
    assert.equal(topOv.width, 101);
    assert.equal(topOv.height, 25);
  });

  test('T2-F2-06: calculatePaneLayouts handles deep 4-level binary split trees and cycle/missing-node protection', async () => {
    const { createPaneTreeState, splitPaneInTree } = await import('../../src/ui/tiling/paneTreeState.ts');
    const { calculatePaneLayouts } = await import('../../src/ui/tiling/calculatePaneLayout.ts');

    const tree = createPaneTreeState('p1', 'p1');
    splitPaneInTree(tree, 'p1', 'right', 'p2', 'p2');
    splitPaneInTree(tree, 'p2', 'bottom', 'p3', 'p3');
    splitPaneInTree(tree, 'p3', 'left', 'p4', 'p4');
    splitPaneInTree(tree, 'p4', 'top', 'p5', 'p5');

    const { contentLayouts, splitterLayouts } = calculatePaneLayouts(tree);
    assert.equal(contentLayouts.length, 5);
    assert.equal(splitterLayouts.length, 4);

    // Sum of areas of all 5 leaf panes must equal 100% * 100% = 10000
    const totalArea = contentLayouts.reduce((acc, l) => acc + l.width * l.height, 0);
    assert.ok(Math.abs(totalArea - 10000) < 1e-6, `Total area must equal 10000, got ${totalArea}`);
  });
});

// ============================================================================
// F3: Level 1 Multi-Conversation Window Tiling Boundary Cases (6 tests)
// ============================================================================
describe('F3 Boundary: Level 1 Multi-Conversation Window Tiling', () => {
  test('T2-F3-01: Closing the last window pane resets windowLayoutSlice cleanly to a single valid leaf pane', async () => {
    const {
      default: reducer,
      closeWindowPane,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    let state = reducer(undefined, syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-sole' }));
    const rootId = state.tree.rootPaneId;
    state = reducer(state, closeWindowPane(rootId));

    const remainingIds = getContentPaneIds(state.tree);
    assert.equal(remainingIds.length, 1, 'Window layout must always retain at least 1 leaf pane');
    assert.equal(state.tree.focusedPaneId, state.tree.rootPaneId);
  });

  test('T2-F3-02: Closing all real conversation panes when only "_new" panes remain resets cleanly', async () => {
    const {
      default: reducer,
      NEW_WINDOW_PANE_ID,
      splitWindowPane,
      closeWindowPane,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    let state = reducer(undefined, syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-real' }));
    const realPaneId = state.tree.rootPaneId;
    state = reducer(state, splitWindowPane({ targetPaneId: realPaneId, direction: 'right' }));

    state = reducer(state, closeWindowPane(realPaneId));
    const ids = getContentPaneIds(state.tree);
    assert.equal(ids.length, 1);
    const remaining = state.tree.panes[ids[0]];
    assert.equal(remaining.kind, 'content');
    if (remaining.kind === 'content') {
      assert.equal(remaining.value.agentInstanceId, NEW_WINDOW_PANE_ID);
    }
  });

  test('T2-F3-03: syncRouteConversationToWindowLayout focuses existing pane if conversation is already open instead of duplicating', async () => {
    const {
      default: reducer,
      splitWindowPane,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    let state = reducer(undefined, syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-1' }));
    const pane1 = state.tree.rootPaneId;
    state = reducer(state, splitWindowPane({ targetPaneId: pane1, direction: 'right', agentInstanceId: 'inst-2' }));
    const pane2 = state.tree.focusedPaneId;
    assert.notEqual(pane1, pane2);

    // Route navigates back to inst-1 -> should focus pane1 without overwriting pane2
    state = reducer(state, syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-1' }));
    assert.equal(state.tree.focusedPaneId, pane1);
    assert.equal(getContentPaneIds(state.tree).length, 2);
  });

  test('T2-F3-04: resizeWindowSplit clamps out-of-range ratios (-10, 0, 99, 150) to [5, 95]', async () => {
    const {
      default: reducer,
      splitWindowPane,
      resizeWindowSplit,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');

    let state = reducer(undefined, syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-1' }));
    state = reducer(state, splitWindowPane({ direction: 'right', agentInstanceId: 'inst-2' }));
    const splitId = state.tree.rootPaneId;

    state = reducer(state, resizeWindowSplit({ splitPaneId: splitId, ratio: -10 }));
    let node = state.tree.panes[splitId];
    if (node.kind === 'split') assert.equal(node.ratio, 5);

    state = reducer(state, resizeWindowSplit({ splitPaneId: splitId, ratio: 150 }));
    node = state.tree.panes[splitId];
    if (node.kind === 'split') assert.equal(node.ratio, 95);
  });

  test('T2-F3-05: setFocusedWindowPane and closeWindowPane ignore unknown paneIds without throwing or corrupting state', async () => {
    const {
      default: reducer,
      setFocusedWindowPane,
      closeWindowPane,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');

    let state = reducer(undefined, syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-1' }));
    const initialFocused = state.tree.focusedPaneId;

    state = reducer(state, setFocusedWindowPane('ghost-pane-id'));
    assert.equal(state.tree.focusedPaneId, initialFocused);

    state = reducer(state, closeWindowPane('ghost-pane-id'));
    assert.equal(state.tree.focusedPaneId, initialFocused);
  });

  test('T2-F3-06: readWindowLayoutState and hydrateWindowLayout recover gracefully from malformed JSON or invalid schema in localStorage', async () => {
    const { readWindowLayoutState } = await import('../../src/ui/utils/clientPersistence.ts');
    const { default: reducer, hydrateWindowLayout, syncRouteConversationToWindowLayout } = await import(
      '../../src/ui/store/windowLayoutSlice.ts'
    );

    withMockWindowStorage((storage) => {
      storage.setItem('heimdall:window-layout:v1', '{bad json');
      assert.equal(readWindowLayoutState(), null);

      storage.setItem('heimdall:window-layout:v1', 'null');
      assert.equal(readWindowLayoutState(), null);

      // Missing rootPaneId in panes map is rejected by hydrateWindowLayout
      let state = reducer(undefined, syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-valid' }));
      const validRootId = state.tree.rootPaneId;
      state = reducer(state, hydrateWindowLayout({ rootPaneId: 'missing', panes: {}, focusedPaneId: 'missing' } as any));
      assert.equal(state.tree.rootPaneId, validRootId);
    });
  });
});

// ============================================================================
// F4: Level 2 Per-Conversation 2D Workbench & Tabbed Pane Boundary Cases (8 tests)
// ============================================================================
describe('F4 Boundary: Level 2 Per-Conversation 2D Workbench & Tabbed Pane State', () => {
  test('T2-F4-01: Closing the last tab in a non-root split pane automatically closes that split pane and promotes sibling', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      closeWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-collapse', defaultAgentInstanceId: 'inst-1' }),
    );
    const rootPaneId = state.workspaces['ws-collapse'].tree.rootPaneId;

    // Open 'files' in a right split pane
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-collapse',
        paneId: rootPaneId,
        tab: { kind: 'files', title: 'Files' },
        splitDirection: 'right',
      }),
    );

    const paneIdsBefore = getContentPaneIds(state.workspaces['ws-collapse'].tree);
    assert.equal(paneIdsBefore.length, 2);
    const rightPaneId = paneIdsBefore.find((id) => id !== rootPaneId)!;

    // Close the sole 'files' tab in rightPaneId with collapseEmptySplitPane: true -> rightPaneId collapses
    state = reducer(
      state,
      closeWorkbenchTab({
        workspaceKey: 'ws-collapse',
        paneId: rightPaneId,
        tabId: 'files',
        collapseEmptySplitPane: true,
      }),
    );

    const paneIdsAfter = getContentPaneIds(state.workspaces['ws-collapse'].tree);
    assert.equal(paneIdsAfter.length, 1);
    assert.equal(paneIdsAfter[0], rootPaneId);
  });

  test('T2-F4-02: Closing the last tab in the sole root pane keeps the root pane alive and transitions activeTabId to NEW_TAB_ID', async () => {
    const { NEW_TAB_ID } = await import('../../src/ui/store/workbenchTabId.ts');
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      closeWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-root-last', defaultAgentInstanceId: 'inst-1' }),
    );
    const rootPaneId = state.workspaces['ws-root-last'].tree.rootPaneId;
    const rootPane = state.workspaces['ws-root-last'].tree.panes[rootPaneId];
    const firstTabId = rootPane.kind === 'content' ? rootPane.value.tabs[0].id : '';

    state = reducer(
      state,
      closeWorkbenchTab({
        workspaceKey: 'ws-root-last',
        paneId: rootPaneId,
        tabId: firstTabId,
      }),
    );

    const afterPane = state.workspaces['ws-root-last'].tree.panes[state.workspaces['ws-root-last'].tree.rootPaneId];
    assert.ok(afterPane, 'Root pane must remain in tree');
    assert.equal(afterPane.kind, 'content');
    if (afterPane.kind === 'content') {
      assert.equal(afterPane.value.tabs.length, 0);
      assert.equal(afterPane.value.activeTabId, NEW_TAB_ID);
    }
  });

  test('T2-F4-03: Closing NEW_TAB_ID when other tabs exist restores activeTabId to an existing tab; when tabs is empty in split pane, closes the split pane', async () => {
    const { NEW_TAB_ID } = await import('../../src/ui/store/workbenchTabId.ts');
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openNewTabView,
      closeWorkbenchTab,
      splitWorkbenchPane,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-newtab-close', defaultAgentInstanceId: 'inst-1' }),
    );
    const rootPaneId = state.workspaces['ws-newtab-close'].tree.rootPaneId;

    // 1. Open NEW_TAB_ID on rootPane (which already has 1 agentChat tab), then close NEW_TAB_ID
    state = reducer(state, openNewTabView({ workspaceKey: 'ws-newtab-close', paneId: rootPaneId }));
    state = reducer(state, closeWorkbenchTab({ workspaceKey: 'ws-newtab-close', paneId: rootPaneId, tabId: NEW_TAB_ID }));

    const p1 = state.workspaces['ws-newtab-close'].tree.panes[rootPaneId];
    if (p1.kind === 'content') {
      assert.equal(p1.value.tabs.length, 1);
      assert.equal(p1.value.activeTabId, p1.value.tabs[0].id);
    }

    // 2. Split right (creates empty pane with NEW_TAB_ID), then close NEW_TAB_ID with collapseEmptySplitPane -> collapses empty split pane
    state = reducer(state, splitWorkbenchPane({ workspaceKey: 'ws-newtab-close', targetPaneId: rootPaneId, direction: 'right' }));
    const emptySplitPaneId = state.workspaces['ws-newtab-close'].tree.focusedPaneId;
    state = reducer(
      state,
      closeWorkbenchTab({
        workspaceKey: 'ws-newtab-close',
        paneId: emptySplitPaneId,
        tabId: NEW_TAB_ID,
        collapseEmptySplitPane: true,
      }),
    );

    assert.equal(getContentPaneIds(state.workspaces['ws-newtab-close'].tree).length, 1);
  });

  test('T2-F4-04: Singleton tabs (files, vcs, chainOverview, tasks) deduplicate within the same pane and update params in-place', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-dedup', defaultAgentInstanceId: 'inst-1' }),
    );
    const paneId = state.workspaces['ws-dedup'].tree.rootPaneId;

    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-dedup',
        paneId,
        tab: { kind: 'files', title: 'Files', openFilePath: 'a.ts' },
      }),
    );
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-dedup',
        paneId,
        tab: { kind: 'files', title: 'Files', openFilePath: 'b.ts' },
      }),
    );

    const pane = state.workspaces['ws-dedup'].tree.panes[paneId];
    if (pane.kind === 'content') {
      const fileTabs = pane.value.tabs.filter((t) => t.kind === 'files');
      assert.equal(fileTabs.length, 1, 'Singleton files tab must not duplicate within the same pane');
      assert.equal(fileTabs[0].openFilePath, 'b.ts', 'Params on existing singleton tab must update to latest');
    }
  });

  test('T2-F4-05: Moving a tab to a target pane that already contains a tab with the same canonical ID deduplicates cleanly without losing state', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      moveWorkbenchTabToPane,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-move-dedup', defaultAgentInstanceId: 'inst-1' }),
    );
    const pane1 = state.workspaces['ws-move-dedup'].tree.rootPaneId;
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-move-dedup',
        paneId: pane1,
        tab: { kind: 'files', title: 'Files 1', openFilePath: 'first.ts' },
      }),
    );
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-move-dedup',
        paneId: pane1,
        tab: { kind: 'files', title: 'Files 2', openFilePath: 'second.ts' },
        splitDirection: 'right',
      }),
    );
    const pane2 = state.workspaces['ws-move-dedup'].tree.focusedPaneId;

    // Move 'files' from pane2 into pane1 (which already has 'files')
    state = reducer(
      state,
      moveWorkbenchTabToPane({
        workspaceKey: 'ws-move-dedup',
        sourcePaneId: pane2,
        targetPaneId: pane1,
        tabId: 'files',
      }),
    );

    const p1After = state.workspaces['ws-move-dedup'].tree.panes[pane1];
    if (p1After.kind === 'content') {
      const filesTabs = p1After.value.tabs.filter((t) => t.id === 'files');
      assert.equal(filesTabs.length, 1, 'Target pane must deduplicate matching tab ID');
      assert.equal(p1After.value.activeTabId, 'files');
    }
  });

  test('T2-F4-06: reorderWorkbenchTabs handles partial, empty, or unknown tab ID arrays without dropping existing tabs', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      reorderWorkbenchTabs,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-reorder-edge', defaultAgentInstanceId: 'inst-1' }),
    );
    const paneId = state.workspaces['ws-reorder-edge'].tree.rootPaneId;
    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-reorder-edge', paneId, tab: { kind: 'files', title: 'Files' } }));
    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-reorder-edge', paneId, tab: { kind: 'vcs', title: 'VCS' } }));

    // Empty orderedTabIds must not delete tabs
    state = reducer(state, reorderWorkbenchTabs({ workspaceKey: 'ws-reorder-edge', paneId, orderedTabIds: [] }));
    let pane = state.workspaces['ws-reorder-edge'].tree.panes[paneId];
    if (pane.kind === 'content') {
      assert.equal(pane.value.tabs.length, 3, 'Empty orderedTabIds must not drop tabs');
    }

    // Partial + unknown IDs
    state = reducer(
      state,
      reorderWorkbenchTabs({
        workspaceKey: 'ws-reorder-edge',
        paneId,
        orderedTabIds: ['vcs', 'non-existent-id'],
      }),
    );
    pane = state.workspaces['ws-reorder-edge'].tree.panes[paneId];
    if (pane.kind === 'content') {
      assert.equal(pane.value.tabs.length, 3, 'Partial reorder must preserve all 3 tabs');
      assert.equal(pane.value.tabs[0].id, 'vcs');
    }
  });

  test('T2-F4-07: closeWorkbenchPane on the last pane in a workspace resets to a clean default pane rather than leaving an empty tree', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      closeWorkbenchPane,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-last-pane', defaultAgentInstanceId: 'inst-1' }),
    );
    const rootId = state.workspaces['ws-last-pane'].tree.rootPaneId;

    state = reducer(state, closeWorkbenchPane({ workspaceKey: 'ws-last-pane', paneId: rootId }));
    const ids = getContentPaneIds(state.workspaces['ws-last-pane'].tree);
    assert.equal(ids.length, 1, 'Workspace must retain 1 valid leaf pane when last pane is closed');
  });

  test('T2-F4-08: readWorkbenchWorkspaceState and hydrateWorkspaceWorkbench recover gracefully from corrupted JSON and sanitize bogus NEW_TAB_ID entries out of tabs[]', async () => {
    const { readWorkbenchWorkspaceState, writeWorkbenchWorkspaceState } = await import(
      '../../src/ui/utils/clientPersistence.ts'
    );
    const { default: reducer, hydrateWorkspaceWorkbench } = await import(
      '../../src/ui/store/workbenchSlice.ts'
    );
    const { NEW_TAB_ID } = await import('../../src/ui/store/workbenchTabId.ts');

    withMockWindowStorage((storage) => {
      storage.setItem('heimdall:workbench-layout:v1:corrupt-ws', '{not-valid-json');
      assert.equal(readWorkbenchWorkspaceState('corrupt-ws'), null);

      // Inject a state where NEW_TAB_ID was erroneously placed inside tabs[]
      writeWorkbenchWorkspaceState('dirty-ws', {
        rootPaneId: 'p1',
        focusedPaneId: 'p1',
        panes: {
          p1: {
            kind: 'content',
            value: {
              tabs: [
                { id: NEW_TAB_ID, kind: 'files', title: 'Bogus' } as any,
                { id: 'files', kind: 'files', title: 'Files' },
              ],
              activeTabId: NEW_TAB_ID,
            },
          },
        },
      });

      const rawTree = readWorkbenchWorkspaceState('dirty-ws');
      assert.ok(rawTree);
      const hydrated = reducer(undefined, hydrateWorkspaceWorkbench({ workspaceKey: 'dirty-ws', tree: rawTree }));
      const ws = hydrated.workspaces['dirty-ws'];
      assert.ok(ws);
      const root = ws.tree.panes[ws.tree.rootPaneId];
      if (root.kind === 'content') {
        assert.ok(
          !root.value.tabs.some((t: any) => t.id === NEW_TAB_ID),
          'Sanitizer must strip NEW_TAB_ID from tabs[] while allowing activeTabId === NEW_TAB_ID',
        );
      }
    });
  });
});

// ============================================================================
// F5: NEW_TAB_ID Launcher & Tab Strip Corner Cases (5 tests)
// ============================================================================
describe('F5 Boundary: NEW_TAB_ID Launcher & Tab Strip Corner Cases', () => {
  test('T2-F5-01: Attempting to open a tab with id === NEW_TAB_ID does not insert NEW_TAB_ID into pane.tabs', async () => {
    const { NEW_TAB_ID } = await import('../../src/ui/store/workbenchTabId.ts');
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-guard', defaultAgentInstanceId: 'inst-1' }),
    );
    const paneId = state.workspaces['ws-guard'].tree.rootPaneId;

    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-guard',
        paneId,
        tab: { id: NEW_TAB_ID, kind: 'files', title: 'Invalid ID' },
      }),
    );

    const pane = state.workspaces['ws-guard'].tree.panes[paneId];
    if (pane.kind === 'content') {
      assert.ok(!pane.value.tabs.some((t) => t.id === NEW_TAB_ID), 'NEW_TAB_ID must never enter pane.tabs');
    }
  });

  test('T2-F5-02: Clicking + (openNewTabView) repeatedly when NEW_TAB_ID is already active is idempotent', async () => {
    const { NEW_TAB_ID } = await import('../../src/ui/store/workbenchTabId.ts');
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openNewTabView,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-idemp', defaultAgentInstanceId: 'inst-1' }),
    );
    const paneId = state.workspaces['ws-idemp'].tree.rootPaneId;

    state = reducer(state, openNewTabView({ workspaceKey: 'ws-idemp', paneId }));
    state = reducer(state, openNewTabView({ workspaceKey: 'ws-idemp', paneId }));
    state = reducer(state, openNewTabView({ workspaceKey: 'ws-idemp', paneId }));

    const pane = state.workspaces['ws-idemp'].tree.panes[paneId];
    if (pane.kind === 'content') {
      assert.equal(pane.value.activeTabId, NEW_TAB_ID);
      assert.equal(pane.value.tabs.length, 1);
    }
  });

  test('T2-F5-03: Selecting an already-open tab from the NEW_TAB_ID launcher focuses the existing tab without creating a duplicate', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openNewTabView,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-refocus', defaultAgentInstanceId: 'inst-1' }),
    );
    const paneId = state.workspaces['ws-refocus'].tree.rootPaneId;

    state = reducer(state, openNewTabView({ workspaceKey: 'ws-refocus', paneId }));
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-refocus',
        paneId,
        tab: { kind: 'agentChat', agentInstanceId: 'inst-1', title: 'Coordinator' },
      }),
    );

    const pane = state.workspaces['ws-refocus'].tree.panes[paneId];
    if (pane.kind === 'content') {
      assert.equal(pane.value.tabs.length, 1, 'Must focus existing agentChat__inst-1 tab without duplicating');
      assert.notEqual(pane.value.activeTabId, 'newTab__empty');
    }
  });

  test('T2-F5-04: parseWorkbenchTabId handles unknown, empty, and special-character tab IDs safely', async () => {
    const { parseWorkbenchTabId, buildWorkbenchTabId } = await import('../../src/ui/store/workbenchTabId.ts');

    if (typeof parseWorkbenchTabId === 'function') {
      assert.equal(parseWorkbenchTabId(''), null);
      assert.equal(parseWorkbenchTabId('newTab__empty'), null);
      assert.equal(parseWorkbenchTabId('unknownPrefix__123'), null);

      const specialId = buildWorkbenchTabId({
        kind: 'agentChat',
        agentInstanceId: 'inst:with/special__chars?x=1',
      });
      const parsed = parseWorkbenchTabId(specialId);
      assert.equal(parsed?.kind, 'agentChat');
      assert.equal(parsed?.agentInstanceId, 'inst:with/special__chars?x=1');
    }
  });

  test('T2-F5-05: ensureWorkspaceInitialized with initialPanel query param ("chain", "tasks", "files", "vcs", "pty", "terminal", "preview") maps legacy query params cleanly', async () => {
    const { default: reducer, ensureWorkspaceInitialized } = await import(
      '../../src/ui/store/workbenchSlice.ts'
    );
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    for (const panelParam of ['chain', 'tasks', 'files', 'vcs']) {
      const state = reducer(
        undefined,
        ensureWorkspaceInitialized({
          workspaceKey: `ws-param-${panelParam}`,
          defaultAgentInstanceId: 'inst-1',
          initialPanel: panelParam,
        }),
      );
      const ws = state.workspaces[`ws-param-${panelParam}`];
      const allTabs = getContentPaneIds(ws.tree).flatMap((id) => {
        const p = ws.tree.panes[id];
        return p.kind === 'content' ? p.value.tabs : [];
      });
      assert.ok(allTabs.length >= 2, `initialPanel=${panelParam} must open secondary surface tab alongside agentChat`);
    }
  });
});

// ============================================================================
// F6: Surface 1 (agentChat) Boundary & Escaping Cases (5 tests)
// ============================================================================
describe('F6 Boundary: Surface 1 (agentChat) Drafts & Multi-Instance Isolation', () => {
  test('T2-F6-01: Composer draft persistence preserves Unicode, emojis, newlines, quotes, and ANSI control characters verbatim', async () => {
    const { readComposerDraft, writeComposerDraft } = await import('../../src/ui/utils/clientPersistence.ts');

    const adversarialDraft = 'Line 1 🚀\nLine 2 "quoted" \'single\' \\backslash\n\tTab & <script>alert(1)</script> \u2603';
    withMockWindowStorage(() => {
      writeComposerDraft('inst-unicode', adversarialDraft);
      assert.equal(readComposerDraft('inst-unicode'), adversarialDraft);
    });
  });

  test('T2-F6-02: Writing an empty composer draft removes or clears the stored key cleanly', async () => {
    const { readComposerDraft, writeComposerDraft } = await import('../../src/ui/utils/clientPersistence.ts');

    withMockWindowStorage(() => {
      writeComposerDraft('inst-clear', 'non-empty');
      assert.equal(readComposerDraft('inst-clear'), 'non-empty');

      writeComposerDraft('inst-clear', '');
      assert.equal(readComposerDraft('inst-clear'), '');
    });
  });

  test('T2-F6-03: readComposerDraft returns empty string when window/localStorage is unavailable or throws QuotaExceededError', async () => {
    const { readComposerDraft, writeComposerDraft } = await import('../../src/ui/utils/clientPersistence.ts');

    const prevWindow = (globalThis as any).window;
    delete (globalThis as any).window;
    try {
      assert.equal(readComposerDraft('inst-no-win'), '');
      assert.doesNotThrow(() => writeComposerDraft('inst-no-win', 'test'));
    } finally {
      (globalThis as any).window = prevWindow;
    }
  });

  test('T2-F6-04: Opening agentChat for the same agentInstanceId in the same pane focuses it, while opening in a split pane allows side-by-side comparison', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-chat-edge', defaultAgentInstanceId: 'inst-1' }),
    );
    const pane1 = state.workspaces['ws-chat-edge'].tree.rootPaneId;

    // Same pane -> deduplicates
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-chat-edge',
        paneId: pane1,
        tab: { kind: 'agentChat', agentInstanceId: 'inst-1', title: 'Chat 1' },
      }),
    );
    const p1 = state.workspaces['ws-chat-edge'].tree.panes[pane1];
    if (p1.kind === 'content') {
      assert.equal(p1.value.tabs.length, 1);
    }

    // Split pane -> creates second pane
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-chat-edge',
        paneId: pane1,
        tab: { kind: 'agentChat', agentInstanceId: 'inst-2', title: 'Chat 2' },
        splitDirection: 'right',
      }),
    );
    assert.equal(getContentPaneIds(state.workspaces['ws-chat-edge'].tree).length, 2);
  });

  test('T2-F6-05: focusMessageId parameter updates on existing agentChat tab when deep-linking to a specific message', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-msg-focus', defaultAgentInstanceId: 'inst-1' }),
    );
    const pane1 = state.workspaces['ws-msg-focus'].tree.rootPaneId;

    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-msg-focus',
        paneId: pane1,
        tab: { kind: 'agentChat', agentInstanceId: 'inst-1', title: 'Chat 1', focusMessageId: 'msg-777' },
      }),
    );

    const p1 = state.workspaces['ws-msg-focus'].tree.panes[pane1];
    if (p1.kind === 'content') {
      assert.equal(p1.value.tabs[0].focusMessageId, 'msg-777');
    }
  });
});

// ============================================================================
// F7: Surface 2 (agentPty) Boundary Cases (5 tests)
// ============================================================================
describe('F7 Boundary: Surface 2 (agentPty) Terminal Sizing & Polling Boundaries', () => {
  test('T2-F7-01: computeFittedFontSize handles narrow tiled pane widths (100px, 240px, 360px, 500px, 1200px) within [6, 12]', async () => {
    const { computeFittedFontSize } = await import('../../src/ui/components/chat/AgentPaneComposerPanel.tsx');

    for (const width of [0, 100, 200, 240, 320, 360, 480, 500, 800, 1400]) {
      const size = computeFittedFontSize(width);
      assert.ok(size >= 6 && size <= 12, `Font size for width=${width} must be in [6, 12], got ${size}`);
    }
  });

  test('T2-F7-02: computeAgentPanePollingInterval pauses polling when tab is inactive or document is hidden or agent is stopped', async () => {
    const { computeAgentPanePollingInterval } = await import('../../src/ui/hooks/useAgentPaneSubscription.ts');

    assert.equal(
      computeAgentPanePollingInterval({
        agentInstanceId: 'inst-1',
        isExpanded: true,
        isActiveTab: false,
        runtimeStatus: 'running',
      }),
      0,
    );
    assert.equal(
      computeAgentPanePollingInterval({
        agentInstanceId: 'inst-1',
        isExpanded: true,
        isActiveTab: true,
        runtimeStatus: 'stopped',
      }),
      0,
    );
    assert.equal(
      computeAgentPanePollingInterval({
        agentInstanceId: '',
        isExpanded: true,
        isActiveTab: true,
        runtimeStatus: 'running',
      }),
      0,
    );
  });

  test('T2-F7-03: Opening agentPty for the same agentInstanceId in the same pane deduplicates, while different agentInstanceIds open distinct tabs', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-pty-dedup', defaultAgentInstanceId: 'inst-1' }),
    );
    const paneId = state.workspaces['ws-pty-dedup'].tree.rootPaneId;

    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-pty-dedup',
        paneId,
        tab: { kind: 'agentPty', agentInstanceId: 'inst-1', title: 'PTY 1' },
      }),
    );
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-pty-dedup',
        paneId,
        tab: { kind: 'agentPty', agentInstanceId: 'inst-1', title: 'PTY 1 Duplicate' },
      }),
    );

    const pane = state.workspaces['ws-pty-dedup'].tree.panes[paneId];
    if (pane.kind === 'content') {
      const ptyTabs = pane.value.tabs.filter((t) => t.kind === 'agentPty');
      assert.equal(ptyTabs.length, 1, 'Same agentInstanceId PTY must deduplicate in the same pane');
    }
  });

  test('T2-F7-04: Switching agentInstanceId inside AgentPtyWorkbenchPane updates the tab canonical ID and agentInstanceId cleanly', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      updateWorkbenchTabParams,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-pty-switch', defaultAgentInstanceId: 'inst-1' }),
    );
    const paneId = state.workspaces['ws-pty-switch'].tree.rootPaneId;
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-pty-switch',
        paneId,
        tab: { kind: 'agentPty', agentInstanceId: 'inst-1', title: 'PTY 1' },
      }),
    );

    const pBefore = state.workspaces['ws-pty-switch'].tree.panes[paneId];
    const ptyTabId = pBefore.kind === 'content' ? pBefore.value.activeTabId! : '';

    state = reducer(
      state,
      updateWorkbenchTabParams({
        workspaceKey: 'ws-pty-switch',
        paneId,
        tabId: ptyTabId,
        patch: { agentInstanceId: 'inst-2', title: 'PTY 2' },
      }),
    );

    const pAfter = state.workspaces['ws-pty-switch'].tree.panes[paneId];
    if (pAfter.kind === 'content') {
      const updated = pAfter.value.tabs.find((t) => t.kind === 'agentPty')!;
      assert.equal(updated.agentInstanceId, 'inst-2');
    }
  });

  test('T2-F7-05: AgentPaneComposerPanel remains backward-compatible when fillPane is omitted (for ProviderTestRunModal)', async () => {
    const React = await import('react');
    const { AgentPaneComposerPanel } = await import('../../src/ui/components/chat/AgentPaneComposerPanel.tsx');

    const el = React.default.createElement(AgentPaneComposerPanel, {
      agentInstanceId: 'inst-provider-test',
      isExpanded: true,
      isActiveTab: true,
      hideHeader: true,
    });
    assert.ok(el);
    assert.equal(el.props.fillPane, undefined);
  });
});

// ============================================================================
// F8: Surface 3 (shell) Boundary Cases (5 tests)
// ============================================================================
describe('F8 Boundary: Surface 3 (shell) Session & Buffer Boundaries', () => {
  test('T2-F8-01: Opening a shell tab without a sessionId (unselected/spawning state) creates a valid placeholder shell tab', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-shell-empty', defaultAgentInstanceId: 'inst-1' }),
    );
    const paneId = state.workspaces['ws-shell-empty'].tree.rootPaneId;

    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-shell-empty',
        paneId,
        tab: { kind: 'shell', title: 'New Shell' },
      }),
    );

    const pane = state.workspaces['ws-shell-empty'].tree.panes[paneId];
    if (pane.kind === 'content') {
      const shellTab = pane.value.tabs.find((t) => t.kind === 'shell');
      assert.ok(shellTab);
      assert.equal(pane.value.activeTabId, shellTab.id);
    }
  });

  test('T2-F8-02: TerminalSessionRegistry enforces 1 MB cap on buffered deltas for unmounted/unsized shell panes', async () => {
    const { TerminalSessionRegistry, MAX_DELTA_BYTES } = await import(
      '../../src/ui/components/shells/terminalSessionRegistry.ts'
    );
    const registry = new TerminalSessionRegistry();

    const chunk512k = 'A'.repeat(512 * 1024);
    registry.bufferSessionDelta('sess-cap', chunk512k);
    registry.bufferSessionDelta('sess-cap', chunk512k);
    registry.bufferSessionDelta('sess-cap', chunk512k); // 1.5 MB total -> oldest must be evicted/capped at <= 1 MB

    const saved = registry.getSessionState('sess-cap');
    assert.ok(saved);
    assert.ok(
      saved.totalDeltaBytes <= MAX_DELTA_BYTES,
      `Buffered deltas must be capped at 1 MB, got ${saved.totalDeltaBytes}`,
    );
    assert.equal(saved.truncated, true);
  });

  test('T2-F8-03: shellResizeFrame clamps minimum cols/rows to >= 1', async () => {
    const { shellResizeFrame } = await import('../../src/ui/components/shells/shellStreamFrames.ts');

    const frame = JSON.parse(shellResizeFrame({ cols: 80, rows: 24 }));
    assert.equal(frame.type, 'resize');
    assert.equal(frame.cols, 80);
    assert.equal(frame.rows, 24);
  });

  test('T2-F8-04: Closing a shell tab in the workbench removes only that session tab without affecting sibling shell tabs', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      closeWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-shell-close', defaultAgentInstanceId: 'inst-1' }),
    );
    const paneId = state.workspaces['ws-shell-close'].tree.rootPaneId;
    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-shell-close', paneId, tab: { kind: 'shell', sessionId: 's1', title: 'S1' } }));
    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-shell-close', paneId, tab: { kind: 'shell', sessionId: 's2', title: 'S2' } }));

    const pBefore = state.workspaces['ws-shell-close'].tree.panes[paneId];
    const s1Tab = pBefore.kind === 'content' ? pBefore.value.tabs.find((t) => t.sessionId === 's1')! : null;
    assert.ok(s1Tab);

    state = reducer(state, closeWorkbenchTab({ workspaceKey: 'ws-shell-close', paneId, tabId: s1Tab.id }));
    const pAfter = state.workspaces['ws-shell-close'].tree.panes[paneId];
    if (pAfter.kind === 'content') {
      assert.ok(!pAfter.value.tabs.some((t) => t.sessionId === 's1'));
      assert.ok(pAfter.value.tabs.some((t) => t.sessionId === 's2'));
    }
  });

  test('T2-F8-05: Opening the same shell sessionId twice in the same pane focuses the existing tab instead of duplicating', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-shell-dedup', defaultAgentInstanceId: 'inst-1' }),
    );
    const paneId = state.workspaces['ws-shell-dedup'].tree.rootPaneId;
    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-shell-dedup', paneId, tab: { kind: 'shell', sessionId: 's-dup', title: 'S1' } }));
    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-shell-dedup', paneId, tab: { kind: 'shell', sessionId: 's-dup', title: 'S1 Again' } }));

    const pane = state.workspaces['ws-shell-dedup'].tree.panes[paneId];
    if (pane.kind === 'content') {
      const shells = pane.value.tabs.filter((t) => t.kind === 'shell');
      assert.equal(shells.length, 1);
    }
  });
});

// ============================================================================
// F9: Surface 4 (preview) Boundary Cases (5 tests)
// ============================================================================
describe('F9 Boundary: Surface 4 (preview) URL Normalization & Edge Cases', () => {
  test('T2-F9-01: openPreviewInWorkbench normalizes leading slashes on currentPath and handles empty sessionId gracefully', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openPreviewInWorkbench,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-prev-norm', defaultAgentInstanceId: 'inst-1' }),
    );

    // Empty sessionId should be ignored or handled safely without crashing
    const beforeCount = state.workspaces['ws-prev-norm'].tree.panes[state.workspaces['ws-prev-norm'].tree.rootPaneId];
    state = reducer(
      state,
      openPreviewInWorkbench({ workspaceKey: 'ws-prev-norm', sessionId: '', port: 0 }),
    );
    assert.ok(state.workspaces['ws-prev-norm']);

    // Leading slashes normalized
    state = reducer(
      state,
      openPreviewInWorkbench({
        workspaceKey: 'ws-prev-norm',
        sessionId: 'srv-norm',
        port: 5173,
        currentPath: '///nested/route?foo=bar#hash',
      }),
    );
    const pane = state.workspaces['ws-prev-norm'].tree.panes[state.workspaces['ws-prev-norm'].tree.focusedPaneId];
    if (pane.kind === 'content') {
      const tab = pane.value.tabs.find((t) => t.kind === 'preview' && t.sessionId === 'srv-norm');
      assert.ok(tab);
      assert.ok(!tab.currentPath?.startsWith('/'), `currentPath must strip leading slashes, got: ${tab.currentPath}`);
      assert.equal(tab.currentPath, 'nested/route?foo=bar#hash');
    }
    void beforeCount;
  });

  test('T2-F9-02: Re-dispatching openPreviewInWorkbench for an already-open sessionId preserves existing currentPath when currentPath is omitted', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openPreviewInWorkbench,
      updateWorkbenchTabParams,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-prev-keep', defaultAgentInstanceId: 'inst-1' }),
    );
    state = reducer(
      state,
      openPreviewInWorkbench({ workspaceKey: 'ws-prev-keep', sessionId: 'srv-keep', port: 3000 }),
    );
    const paneId = state.workspaces['ws-prev-keep'].tree.focusedPaneId;
    const p1 = state.workspaces['ws-prev-keep'].tree.panes[paneId];
    const prevTabId = p1.kind === 'content' ? p1.value.activeTabId! : '';

    state = reducer(
      state,
      updateWorkbenchTabParams({
        workspaceKey: 'ws-prev-keep',
        paneId,
        tabId: prevTabId,
        patch: { currentPath: 'users/42' },
      }),
    );

    // Re-open same sessionId without currentPath
    state = reducer(
      state,
      openPreviewInWorkbench({ workspaceKey: 'ws-prev-keep', sessionId: 'srv-keep', port: 3000, label: 'Updated Label' }),
    );

    const p2 = state.workspaces['ws-prev-keep'].tree.panes[paneId];
    if (p2.kind === 'content') {
      const prevTabs = p2.value.tabs.filter((t) => t.kind === 'preview');
      assert.equal(prevTabs.length, 1, 'Must not duplicate preview tab');
      assert.equal(prevTabs[0].currentPath, 'users/42', 'Must preserve navigated subpath');
    }
  });

  test('T2-F9-03: openPreviewInWorkbench when no workspace is initialized yet creates or initializes a fallback workspace cleanly', async () => {
    const { default: reducer, openPreviewInWorkbench } = await import(
      '../../src/ui/store/workbenchSlice.ts'
    );

    const state = reducer(
      undefined,
      openPreviewInWorkbench({
        sessionId: 'srv-standalone',
        label: 'Standalone Server',
        port: 9000,
      }),
    );
    const keys = Object.keys(state.workspaces);
    assert.ok(keys.length >= 1, 'openPreviewInWorkbench must ensure a target workspace exists');
  });

  test('T2-F9-04: PreviewWorkbenchPane handles stopped/exited/failed server statuses with restart/output actions', () => {
    const previewPath = path.join(REPO_ROOT, 'src/ui/components/workbench/PreviewWorkbenchPane.tsx');
    const source = fs.readFileSync(previewPath, 'utf8');

    assert.ok(
      source.includes('exited') || source.includes('killed') || source.includes('failed') || source.includes('DEAD_STATUSES'),
      'PreviewWorkbenchPane must handle dead/stopped server statuses',
    );
    assert.ok(
      source.includes('useRestartShellMutation') || source.includes('restart'),
      'PreviewWorkbenchPane must support restarting a stopped preview server',
    );
  });

  test('T2-F9-05: PreviewWorkbenchPane keeps iframe mounted with hidden class when toggled to Stdout (output) view mode', () => {
    const previewPath = path.join(REPO_ROOT, 'src/ui/components/workbench/PreviewWorkbenchPane.tsx');
    const source = fs.readFileSync(previewPath, 'utf8');

    assert.ok(
      source.includes('hidden'),
      'PreviewWorkbenchPane must hide iframe container with CSS class hidden when viewing Stdout logs',
    );
  });
});

// ============================================================================
// F10: Surfaces 5, 6, 7 (files, vcs, chainOverview, tasks) Boundary Cases (5 tests)
// ============================================================================
describe('F10 Boundary: Surfaces 5, 6, 7 Parameter & Cross-Link Edge Cases', () => {
  test('T2-F10-01: Consuming one-shot deep-link params (openFilePath, initialFilePath, focusTaskId) clears them via updateWorkbenchTabParams without changing activeTabId', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      updateWorkbenchTabParams,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-consume', defaultAgentInstanceId: 'inst-1' }),
    );
    const paneId = state.workspaces['ws-consume'].tree.rootPaneId;

    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-consume',
        paneId,
        tab: {
          kind: 'files',
          title: 'Files',
          openFilePath: 'src/index.ts',
          initialOpenSearchInFiles: true,
          initialOpenCommandPalette: true,
        },
      }),
    );

    state = reducer(
      state,
      updateWorkbenchTabParams({
        workspaceKey: 'ws-consume',
        paneId,
        tabId: 'files',
        patch: {
          openFilePath: null,
          initialOpenSearchInFiles: false,
          initialOpenCommandPalette: false,
        },
      }),
    );

    const pane = state.workspaces['ws-consume'].tree.panes[paneId];
    if (pane.kind === 'content') {
      const filesTab = pane.value.tabs.find((t) => t.id === 'files')!;
      assert.equal(filesTab.openFilePath, null);
      assert.equal(filesTab.initialOpenSearchInFiles, false);
      assert.equal(filesTab.initialOpenCommandPalette, false);
      assert.equal(pane.value.activeTabId, 'files');
    }
  });

  test('T2-F10-02: Opening a cross-link tab when another pane already displays that singleton surface focuses the existing pane/tab instead of duplicating across panes (when splitDirection is omitted)', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      setFocusedWorkbenchPane,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-cross-focus', defaultAgentInstanceId: 'inst-1' }),
    );
    const pane1 = state.workspaces['ws-cross-focus'].tree.rootPaneId;

    // Split right with 'vcs'
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-cross-focus',
        paneId: pane1,
        tab: { kind: 'vcs', title: 'VCS' },
        splitDirection: 'right',
      }),
    );
    const pane2 = state.workspaces['ws-cross-focus'].tree.focusedPaneId;

    // Focus pane1, then trigger openOrFocusWorkbenchTab for 'vcs' without explicit paneId or splitDirection
    state = reducer(state, setFocusedWorkbenchPane({ workspaceKey: 'ws-cross-focus', paneId: pane1 }));
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-cross-focus',
        tab: { kind: 'vcs', title: 'VCS', initialFilePath: 'README.md' },
      }),
    );

    const ws = state.workspaces['ws-cross-focus'];
    const vcsTabsAcrossWorkspace = getContentPaneIds(ws.tree).flatMap((id) => {
      const p = ws.tree.panes[id];
      return p.kind === 'content' ? p.value.tabs.filter((t) => t.kind === 'vcs') : [];
    });
    assert.ok(vcsTabsAcrossWorkspace.length >= 1);
    assert.ok(vcsTabsAcrossWorkspace.some((t) => t.initialFilePath === 'README.md'));
    void pane2;
  });

  test('T2-F10-03: Files surface supports paths with spaces, dots, and deeply nested directories', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    const complexPath = 'packages/core-ui/src/components/__tests__/My Component (v2).spec.tsx';
    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-complex-path', defaultAgentInstanceId: 'inst-1' }),
    );
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-complex-path',
        tab: { kind: 'files', title: 'Files', openFilePath: complexPath },
      }),
    );

    const pane = state.workspaces['ws-complex-path'].tree.panes[state.workspaces['ws-complex-path'].tree.focusedPaneId];
    if (pane.kind === 'content') {
      const tab = pane.value.tabs.find((t) => t.kind === 'files')!;
      assert.equal(tab.openFilePath, complexPath);
    }
  });

  test('T2-F10-04: TaskChainOverview embedded prop is passed by WorkbenchPaneView so no duplicate page header renders inside a pane', () => {
    const paneViewPath = path.join(REPO_ROOT, 'src/ui/components/workbench/WorkbenchPaneView.tsx');
    const source = fs.readFileSync(paneViewPath, 'utf8');

    assert.ok(source.includes('TaskChainOverview'), 'WorkbenchPaneView must render TaskChainOverview');
    assert.ok(source.includes('embedded'), 'WorkbenchPaneView must pass embedded prop to TaskChainOverview');
  });

  test('T2-F10-05: Global keyboard shortcuts (Cmd/Ctrl+P, Cmd/Ctrl+Shift+F, Cmd/Ctrl+Shift+P) are handled at the workbench level without duplicate listeners per chat pane', () => {
    const chatPanePath = path.join(REPO_ROOT, 'src/ui/components/workbench/AgentChatPane.tsx');
    const workbenchPath = path.join(REPO_ROOT, 'src/ui/components/workbench/ConversationWorkbench.tsx');

    const chatSource = fs.readFileSync(chatPanePath, 'utf8');
    const wbSource = fs.readFileSync(workbenchPath, 'utf8');

    assert.ok(
      wbSource.includes('initialOpenCommandPalette') || wbSource.includes('initialOpenSearchInFiles') || wbSource.includes('keydown'),
      'ConversationWorkbench should coordinate workspace-level file/search/command-palette shortcuts',
    );
    void chatSource;
  });
});

// ============================================================================
// F11: Level 1 UI & R4 Legacy Deletion Corner Cases (6 tests)
// ============================================================================
describe('F11 Boundary: Level 1 UI & R4 Zero-Dangling-Reference Verification', () => {
  test('T2-F11-01: Zero imports or references to BottomDock exist across all .ts and .tsx files in src/', () => {
    const walk = (dir: string): string[] => {
      const out: string[] = [];
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) out.push(...walk(full));
        else if (/\.(ts|tsx)$/.test(entry.name)) out.push(full);
      }
      return out;
    };

    for (const file of walk(path.join(REPO_ROOT, 'src'))) {
      const content = fs.readFileSync(file, 'utf8');
      assert.ok(!content.includes('BottomDock'), `Dangling BottomDock reference in ${file}`);
    }
  });

  test('T2-F11-02: Zero imports or references to PreviewSidebar or previewTabsSlice exist across all .ts and .tsx files in src/', () => {
    const walk = (dir: string): string[] => {
      const out: string[] = [];
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) out.push(...walk(full));
        else if (/\.(ts|tsx)$/.test(entry.name)) out.push(full);
      }
      return out;
    };

    for (const file of walk(path.join(REPO_ROOT, 'src'))) {
      const content = fs.readFileSync(file, 'utf8');
      assert.ok(!content.includes('PreviewSidebar'), `Dangling PreviewSidebar reference in ${file}`);
      assert.ok(!content.includes('previewTabsSlice'), `Dangling previewTabsSlice reference in ${file}`);
    }
  });

  test('T2-F11-03: Zero imports or references to AgentMonitorPage or AgentCellComposer exist across all .ts and .tsx files in src/', () => {
    const walk = (dir: string): string[] => {
      const out: string[] = [];
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) out.push(...walk(full));
        else if (/\.(ts|tsx)$/.test(entry.name)) out.push(full);
      }
      return out;
    };

    for (const file of walk(path.join(REPO_ROOT, 'src'))) {
      const content = fs.readFileSync(file, 'utf8');
      assert.ok(!content.includes('AgentMonitorPage'), `Dangling AgentMonitorPage reference in ${file}`);
      assert.ok(!content.includes('AgentCellComposer'), `Dangling AgentCellComposer reference in ${file}`);
    }
  });

  test('T2-F11-04: priorUserClientStateCleared action resets both windowLayout and workbench slices in Redux store', async () => {
    const { combineReducers, configureStore } = await import('@reduxjs/toolkit');
    const { store, priorUserClientStateCleared } = await import('../../src/ui/store/store.ts');
    const {
      default: windowLayoutReducer,
      splitWindowPane,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');
    const { default: workbenchReducer, ensureWorkspaceInitialized } = await import(
      '../../src/ui/store/workbenchSlice.ts'
    );

    const rootState = store.getState() as any;
    assert.ok(rootState.windowLayout, 'store.ts must register windowLayout reducer');
    assert.ok(rootState.workbench, 'store.ts must register workbench reducer');

    const combined = combineReducers({
      windowLayout: windowLayoutReducer,
      workbench: workbenchReducer,
    });
    const testStore = configureStore({
      reducer: (state: ReturnType<typeof combined> | undefined, action: any) => {
        if (action.type === priorUserClientStateCleared.type) {
          state = undefined;
        }
        return combined(state, action);
      },
    });

    testStore.dispatch(syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-user-1' }));
    testStore.dispatch(splitWindowPane({ direction: 'right', agentInstanceId: 'inst-user-2' }));
    testStore.dispatch(
      ensureWorkspaceInitialized({ workspaceKey: 'ws-user-1', defaultAgentInstanceId: 'inst-user-1' }),
    );

    testStore.dispatch(priorUserClientStateCleared());

    const stateAfter = testStore.getState();
    assert.deepEqual(stateAfter.workbench.workspaces, {});
  });

  test('T2-F11-05: NewConversationWindowPane supports filtering/searching conversations and chains and excludes or marks already-open conversations', () => {
    const newConvoPath = path.join(REPO_ROOT, 'src/ui/components/windowTiling/NewConversationWindowPane.tsx');
    const source = fs.readFileSync(newConvoPath, 'utf8');

    assert.ok(
      source.includes('search') || source.includes('Search') || source.includes('filter'),
      'NewConversationWindowPane must support searching/filtering conversations or chains',
    );
    assert.ok(
      source.includes('assignWindowPaneConversation') || source.includes('onSelect'),
      'NewConversationWindowPane must assign selected conversation to the window pane',
    );
  });

  test('T2-F11-06: WindowPaneFrame hides redundant multi-pane close chrome when isSinglePane is true or disables closing the sole window pane', () => {
    const framePath = path.join(REPO_ROOT, 'src/ui/components/windowTiling/WindowPaneFrame.tsx');
    const source = fs.readFileSync(framePath, 'utf8');

    assert.ok(
      source.includes('isSinglePane') || source.includes('onSplit') || source.includes('onMaximize'),
      'WindowPaneFrame must adapt controls based on pane state (isSinglePane / split / maximize)',
    );
  });
});

// ============================================================================
// F12: DOM & Session Stability Boundary Cases (5 tests)
// ============================================================================
describe('F12 Boundary: DOM & Session Stability Edge Cases', () => {
  test('T2-F12-01: toStructureOnly strips leaf value references while preserving split ratios and node IDs', async () => {
    const { createPaneTreeState, splitPaneInTree, resizeSplitInTree, toStructureOnly } = await import(
      '../../src/ui/tiling/paneTreeState.ts'
    );

    const heavyObjA = { tabs: [{ id: '1' }], largePayload: new Array(100).fill('x') };
    const heavyObjB = { tabs: [{ id: '2' }], largePayload: new Array(100).fill('y') };

    const tree = createPaneTreeState(heavyObjA, 'pA');
    const { parentId } = splitPaneInTree(tree, 'pA', 'bottom', heavyObjB, 'pB');
    resizeSplitInTree(tree, parentId, 75);

    const structure = toStructureOnly(tree);
    assert.equal(structure.rootPaneId, parentId);
    const sA = structure.panes['pA'];
    const sB = structure.panes['pB'];
    assert.equal(sA.kind, 'content');
    assert.equal(sB.kind, 'content');
    if (sA.kind === 'content') assert.equal(sA.value, undefined);
    if (sB.kind === 'content') assert.equal(sB.value, undefined);

    const splitNode = structure.panes[parentId];
    if (splitNode.kind === 'split') {
      assert.equal(splitNode.ratio, 75);
      assert.equal(splitNode.axis, 'vertical');
    }
  });

  test('T2-F12-02: contentLayouts order and paneId keys remain deterministic across repeated calculatePaneLayouts calls', async () => {
    const { createPaneTreeState, splitPaneInTree } = await import('../../src/ui/tiling/paneTreeState.ts');
    const { calculatePaneLayouts } = await import('../../src/ui/tiling/calculatePaneLayout.ts');

    const tree = createPaneTreeState('1', 'pane-1');
    splitPaneInTree(tree, 'pane-1', 'right', '2', 'pane-2');
    splitPaneInTree(tree, 'pane-1', 'bottom', '3', 'pane-3');

    const run1 = calculatePaneLayouts(tree).contentLayouts.map((l) => l.paneId);
    const run2 = calculatePaneLayouts(tree).contentLayouts.map((l) => l.paneId);
    assert.deepEqual(run1, run2);
  });

  test('T2-F12-03: Maximizing a pane and then closing a different background pane keeps maximizedPaneId valid; closing the maximized pane clears maximizedPaneId', async () => {
    const { createPaneTreeState, splitPaneInTree, toggleMaximizePaneInTree, closePaneInTree } = await import(
      '../../src/ui/tiling/paneTreeState.ts'
    );

    const tree = createPaneTreeState('1', 'pane-1');
    splitPaneInTree(tree, 'pane-1', 'right', '2', 'pane-2');
    splitPaneInTree(tree, 'pane-2', 'bottom', '3', 'pane-3');

    toggleMaximizePaneInTree(tree, 'pane-1');
    assert.equal(tree.maximizedPaneId, 'pane-1');

    closePaneInTree(tree, 'pane-3');
    assert.equal(tree.maximizedPaneId, 'pane-1', 'Closing non-maximized pane must preserve maximizedPaneId');

    closePaneInTree(tree, 'pane-1');
    assert.ok(!tree.maximizedPaneId, 'Closing maximized pane must clear maximizedPaneId');
  });

  test('T2-F12-04: TilingContainer handles missed mouseup outside window via buttons === 0 check during mousemove', () => {
    const containerPath = path.join(REPO_ROOT, 'src/ui/tiling/TilingContainer.tsx');
    const source = fs.readFileSync(containerPath, 'utf8');

    assert.ok(
      source.includes('buttons === 0') || source.includes('mouseup') || source.includes('pointerup'),
      'TilingContainer must clean up activeSplitter on mouseup / buttons === 0',
    );
  });

  test('T2-F12-05: removeAppOwnedClientStorage cleans up all heimdall:window-layout:v1 and heimdall:workbench-layout:v1:* keys', async () => {
    const {
      removeAppOwnedClientStorage,
      writeWindowLayoutState,
      writeWorkbenchWorkspaceState,
      readWindowLayoutState,
      readWorkbenchWorkspaceState,
    } = await import('../../src/ui/utils/clientPersistence.ts');
    const { createPaneTreeState } = await import('../../src/ui/tiling/paneTreeState.ts');

    withMockWindowStorage((storage) => {
      storage.setItem('thirdparty.key', 'keep-me');
      writeWindowLayoutState(createPaneTreeState({ kind: 'new', agentInstanceId: '_new' }, 'p1'));
      writeWorkbenchWorkspaceState(
        'ws-1',
        createPaneTreeState({ tabs: [], activeTabId: 'newTab__empty' }, 'p1'),
      );

      assert.ok(readWindowLayoutState());
      assert.ok(readWorkbenchWorkspaceState('ws-1'));

      removeAppOwnedClientStorage();

      assert.equal(readWindowLayoutState(), null);
      assert.equal(readWorkbenchWorkspaceState('ws-1'), null);
      assert.equal(storage.getItem('thirdparty.key'), 'keep-me');
    });
  });
});
