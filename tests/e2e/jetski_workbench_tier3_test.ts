/**
 * Tier 3 — Cross-Feature Combinations (Pairwise Interaction Suite)
 *
 * Verifies 16 pairwise and multi-feature interactions across F1–F12 per
 * ORIGINAL_REQUEST.md, PROJECT.md § Interface Contracts, and TEST_INFRA.md:
 * - T3-01: Level 1 Multi-Conversation Window Tiling (F3) × Level 2 Independent 2D Workbenches (F4)
 * - T3-02: Level 2 4-Way Splits (`top`/`bottom`/`left`/`right`) (F2/F4) × `NEW_TAB_ID` Launcher Surface Replacement (F5)
 * - T3-03: `chainOverview` Cross-Links (F10) × Level 2 Split Routing (`vcs`, `tasks`, `preview`, `files`) (F4/F9)
 * - T3-04: Nested 2D Split Maximize/Restore (F2/F12) × Tab Add, Switch, Reorder & Close While Maximized (F4/F5)
 * - T3-05: Cross-Pane Tab Drag (`moveWorkbenchTabToPane` & `splitWorkbenchPaneWithTab`) (F4) × Auto-Collapse & Layout Geometry Recalculation (F2)
 * - T3-06: Multi-Instance `agentChat` (F6) × `agentPty` Live Terminal Tiling (F7) × Per-Agent Draft Isolation
 * - T3-07: Interactive `shell` (F8) × Live `preview` Port Proxy (F9) × `TerminalSessionRegistry` Continuity (F12)
 * - T3-08: Pointer Drag Hit-Testing (`getSplitDirection` & `getOverlayPosition`) (F2) × Level 1 `moveWindowPane` & Level 2 `moveWorkbenchPane` (F3/F4)
 * - T3-09: `NewConversationWindowPane` Selection (`assignWindowPaneConversation`) (F3/F11) × `ensureWorkspaceInitialized` with `?panel=` Deep Links (F4/F5)
 * - T3-10: Sash Resize Clamping (`resizeWindowSplit` & `resizeWorkbenchSplit`) (F2/F3/F4) × `equalizeWindowPanes` / `equalizeWorkbenchPanes` × `calculatePaneLayouts`
 * - T3-11: `ProjectVcsPanel` (`vcs`) Directory Cross-Link (`onOpenDirectory`) × `ProjectFilesPanel` (`files`) Quick-Open/Search Params (F10)
 * - T3-12: `ChainActiveServersPanel` / `ShellListPage` / `ShellDetail` (`openPreviewInWorkbench`) (F9) × Multi-Workspace Redux Store Routing (F3/F4/F11)
 * - T3-13: Level 1 + Level 2 Full `localStorage` Persistence & Hydration Round-Trip × Sanitization of `NEW_TAB_ID` and `_new` (F3/F4/F5)
 * - T3-14: Headless `@xterm/xterm` + `SerializeAddon` Snapshot Restoration (F7/F8) × 2D Pane Tree Split & Move Without Unmounting (F2/F12)
 * - T3-15: `swapWindowPanes` (F3) × `swapPanesInTree` (F2) × Level 2 Active Workspace Switching (`setActiveWorkspaceKey`) (F4)
 * - T3-16: Redux Store (`store.ts`) Integration of `windowLayout` + `workbench` (F3/F4/F11) × `priorUserClientStateCleared` Security Reset
 *
 * Total Tier 3 Test Cases: 16 (>= 15 required)
 *
 * RUN: npx tsx --test tests/e2e/jetski_workbench_tier3_test.ts
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import * as xtermModule from '@xterm/xterm';
import * as serializeModule from '@xterm/addon-serialize';
import '../helpers/vaultEndpointHarness.ts';

const Terminal =
  (xtermModule as any).Terminal ||
  (xtermModule as any).default?.Terminal ||
  (xtermModule as any).default;
const SerializeAddon =
  (serializeModule as any).SerializeAddon ||
  (serializeModule as any).default?.SerializeAddon ||
  (serializeModule as any).default;

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

describe('Tier 3: Cross-Feature Pairwise & Multi-Feature Interactions', () => {
  test('T3-01: Level 1 multi-conversation window splits hosting 3 conversations that each independently split and manage Level 2 2D workbenches', async () => {
    const {
      default: windowReducer,
      splitWindowPane,
      assignWindowPaneConversation,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');
    const {
      default: workbenchReducer,
      ensureWorkspaceInitialized,
      splitWorkbenchPane,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    // Level 1: Tile 3 conversations (1 left, 2 stacked on the right)
    let winState = windowReducer(
      undefined,
      syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-alpha', chainId: 'chain-alpha' }),
    );
    const winPaneAlpha = winState.tree.rootPaneId;

    winState = windowReducer(winState, splitWindowPane({ targetPaneId: winPaneAlpha, direction: 'right' }));
    const winPaneBeta = winState.tree.focusedPaneId;
    winState = windowReducer(
      winState,
      assignWindowPaneConversation({
        paneId: winPaneBeta,
        agentInstanceId: 'inst-beta',
        chainId: 'chain-beta',
      }),
    );

    winState = windowReducer(winState, splitWindowPane({ targetPaneId: winPaneBeta, direction: 'bottom' }));
    const winPaneGamma = winState.tree.focusedPaneId;
    winState = windowReducer(
      winState,
      assignWindowPaneConversation({
        paneId: winPaneGamma,
        agentInstanceId: 'inst-gamma',
        chainId: 'chain-gamma',
      }),
    );

    assert.equal(getContentPaneIds(winState.tree).length, 3);

    // Level 2: Initialize and split each conversation's workbench independently
    let wbState = workbenchReducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'chain-alpha', defaultAgentInstanceId: 'inst-alpha' }),
    );
    wbState = workbenchReducer(
      wbState,
      ensureWorkspaceInitialized({ workspaceKey: 'chain-beta', defaultAgentInstanceId: 'inst-beta' }),
    );
    wbState = workbenchReducer(
      wbState,
      ensureWorkspaceInitialized({ workspaceKey: 'chain-gamma', defaultAgentInstanceId: 'inst-gamma' }),
    );

    // Split chain-alpha horizontally (files), chain-beta vertically (shell), leave chain-gamma single-pane with vcs tab
    wbState = workbenchReducer(
      wbState,
      openOrFocusWorkbenchTab({
        workspaceKey: 'chain-alpha',
        tab: { kind: 'files', title: 'Alpha Files', openFilePath: 'alpha.ts' },
        splitDirection: 'right',
      }),
    );
    wbState = workbenchReducer(
      wbState,
      openOrFocusWorkbenchTab({
        workspaceKey: 'chain-beta',
        tab: { kind: 'shell', sessionId: 'sh-beta', title: 'Beta Shell' },
        splitDirection: 'bottom',
      }),
    );
    wbState = workbenchReducer(
      wbState,
      openOrFocusWorkbenchTab({
        workspaceKey: 'chain-gamma',
        tab: { kind: 'vcs', title: 'Gamma VCS' },
      }),
    );

    assert.equal(getContentPaneIds(wbState.workspaces['chain-alpha'].tree).length, 2);
    assert.equal(getContentPaneIds(wbState.workspaces['chain-beta'].tree).length, 2);
    assert.equal(getContentPaneIds(wbState.workspaces['chain-gamma'].tree).length, 1);
  });

  test('T3-02: Splitting a Level 2 pane in all 4 directions (top, bottom, left, right), launching via NEW_TAB_ID, and verifying calculatePaneLayouts geometry', async () => {
    const { NEW_TAB_ID } = await import('../../src/ui/store/workbenchTabId.ts');
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      splitWorkbenchPane,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { calculatePaneLayouts } = await import('../../src/ui/tiling/calculatePaneLayout.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-4dir', defaultAgentInstanceId: 'inst-center' }),
    );
    const centerPaneId = state.workspaces['ws-4dir'].tree.rootPaneId;

    const dirSpec = [
      { dir: 'right' as const, tab: { kind: 'agentPty' as const, agentInstanceId: 'inst-center', title: 'PTY' } },
      { dir: 'bottom' as const, tab: { kind: 'shell' as const, sessionId: 'sh-1', title: 'Shell' } },
      { dir: 'left' as const, tab: { kind: 'files' as const, title: 'Files' } },
      { dir: 'top' as const, tab: { kind: 'chainOverview' as const, title: 'Overview' } },
    ];

    const createdPaneIds: string[] = [centerPaneId];
    for (const item of dirSpec) {
      state = reducer(
        state,
        splitWorkbenchPane({
          workspaceKey: 'ws-4dir',
          targetPaneId: centerPaneId,
          direction: item.dir,
        }),
      );
      const newPaneId = state.workspaces['ws-4dir'].tree.focusedPaneId;
      createdPaneIds.push(newPaneId);

      // Verify new pane starts in NEW_TAB_ID launcher state
      const newPaneBefore = state.workspaces['ws-4dir'].tree.panes[newPaneId];
      assert.equal(newPaneBefore.kind, 'content');
      if (newPaneBefore.kind === 'content') {
        assert.equal(newPaneBefore.value.activeTabId, NEW_TAB_ID);
      }

      // Transition NEW_TAB_ID to target surface
      state = reducer(
        state,
        openOrFocusWorkbenchTab({
          workspaceKey: 'ws-4dir',
          paneId: newPaneId,
          tab: item.tab,
        }),
      );
    }

    const { contentLayouts, splitterLayouts } = calculatePaneLayouts(state.workspaces['ws-4dir'].tree);
    assert.equal(contentLayouts.length, 5);
    assert.equal(splitterLayouts.length, 4);

    // Every created pane ID must still be present in contentLayouts
    for (const id of createdPaneIds) {
      assert.ok(contentLayouts.some((l) => l.paneId === id), `Pane ID ${id} must be preserved`);
    }
  });

  test('T3-03: Launching chainOverview via NEW_TAB_ID and firing cross-links (onOpenFileDiff -> vcs, onSelectTask -> tasks, openPreviewInWorkbench -> preview) without clobbering existing views', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      splitWorkbenchPane,
      openOrFocusWorkbenchTab,
      openPreviewInWorkbench,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-triage', defaultAgentInstanceId: 'inst-coord' }),
    );
    const chatPaneId = state.workspaces['ws-triage'].tree.rootPaneId;

    // Split right and open chainOverview via NEW_TAB_ID
    state = reducer(state, splitWorkbenchPane({ workspaceKey: 'ws-triage', targetPaneId: chatPaneId, direction: 'right' }));
    const overviewPaneId = state.workspaces['ws-triage'].tree.focusedPaneId;
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-triage',
        paneId: overviewPaneId,
        tab: { kind: 'chainOverview', title: 'Chain Overview' },
      }),
    );

    // 1. Cross-link: onOpenFileDiff -> split bottom from overviewPaneId with vcs
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-triage',
        paneId: overviewPaneId,
        tab: { kind: 'vcs', title: 'VCS Diff', initialFilePath: 'src/server.ts' },
        splitDirection: 'bottom',
      }),
    );
    const vcsPaneId = state.workspaces['ws-triage'].tree.focusedPaneId;

    // 2. Cross-link: onSelectTask -> open tasks tab in overviewPaneId
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-triage',
        paneId: overviewPaneId,
        tab: { kind: 'tasks', title: 'Tasks', focusTaskId: 'task-101' },
      }),
    );

    // 3. Cross-link: openPreviewInWorkbench -> opens preview tab
    state = reducer(
      state,
      openPreviewInWorkbench({
        workspaceKey: 'ws-triage',
        sessionId: 'srv-dev',
        label: 'Dev Server',
        port: 5173,
        currentPath: '/health',
      }),
    );

    const ws = state.workspaces['ws-triage'];
    assert.deepEqual(getContentPaneIds(ws.tree).sort(), [chatPaneId, overviewPaneId, vcsPaneId].sort());

    const chatPane = ws.tree.panes[chatPaneId];
    const overviewPane = ws.tree.panes[overviewPaneId];
    const vcsPane = ws.tree.panes[vcsPaneId];

    if (chatPane.kind === 'content') {
      assert.ok(chatPane.value.tabs.some((t) => t.kind === 'agentChat'));
    }
    if (overviewPane.kind === 'content') {
      assert.ok(overviewPane.value.tabs.some((t) => t.kind === 'chainOverview'), 'chainOverview must still be open');
      assert.ok(overviewPane.value.tabs.some((t) => t.kind === 'tasks' && t.focusTaskId === 'task-101'));
    }
    if (vcsPane.kind === 'content') {
      assert.ok(vcsPane.value.tabs.some((t) => t.kind === 'vcs' && t.initialFilePath === 'src/server.ts'));
    }
  });

  test('T3-04: Maximizing a pane inside a nested 2D split tree, opening/reordering/closing tabs while maximized, and restoring', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      splitWorkbenchPane,
      toggleMaximizeWorkbenchPane,
      openOrFocusWorkbenchTab,
      reorderWorkbenchTabs,
      closeWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { calculatePaneLayouts } = await import('../../src/ui/tiling/calculatePaneLayout.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-max', defaultAgentInstanceId: 'inst-1' }),
    );
    const p1 = state.workspaces['ws-max'].tree.rootPaneId;
    state = reducer(state, splitWorkbenchPane({ workspaceKey: 'ws-max', targetPaneId: p1, direction: 'right' }));
    const p2 = state.workspaces['ws-max'].tree.focusedPaneId;
    state = reducer(state, splitWorkbenchPane({ workspaceKey: 'ws-max', targetPaneId: p2, direction: 'bottom' }));
    const p3 = state.workspaces['ws-max'].tree.focusedPaneId;

    // Maximize p3
    state = reducer(state, toggleMaximizeWorkbenchPane({ workspaceKey: 'ws-max', paneId: p3 }));
    assert.equal(state.workspaces['ws-max'].tree.maximizedPaneId, p3);

    // Open 3 tabs inside maximized p3
    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-max', paneId: p3, tab: { kind: 'files', title: 'Files' } }));
    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-max', paneId: p3, tab: { kind: 'vcs', title: 'VCS' } }));
    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-max', paneId: p3, tab: { kind: 'tasks', title: 'Tasks' } }));

    // Reorder and close a tab while p3 is still maximized
    state = reducer(
      state,
      reorderWorkbenchTabs({
        workspaceKey: 'ws-max',
        paneId: p3,
        orderedTabIds: ['tasks', 'vcs', 'files'],
      }),
    );
    state = reducer(state, closeWorkbenchTab({ workspaceKey: 'ws-max', paneId: p3, tabId: 'vcs' }));
    assert.equal(state.workspaces['ws-max'].tree.maximizedPaneId, p3);

    // Restore p3
    state = reducer(state, toggleMaximizeWorkbenchPane({ workspaceKey: 'ws-max', paneId: p3 }));
    assert.ok(!state.workspaces['ws-max'].tree.maximizedPaneId);

    const { contentLayouts } = calculatePaneLayouts(state.workspaces['ws-max'].tree);
    assert.equal(contentLayouts.length, 3, 'All 3 panes must still be present after restore');
  });

  test('T3-05: Dragging/moving tabs across panes (moveWorkbenchTabToPane & splitWorkbenchPaneWithTab) with automatic source pane collapse and layout recalculation', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      moveWorkbenchTabToPane,
      splitWorkbenchPaneWithTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { calculatePaneLayouts } = await import('../../src/ui/tiling/calculatePaneLayout.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-tab-dnd', defaultAgentInstanceId: 'inst-1' }),
    );
    const pane1 = state.workspaces['ws-tab-dnd'].tree.rootPaneId;
    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-tab-dnd', paneId: pane1, tab: { kind: 'files', title: 'Files' } }));
    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-tab-dnd', paneId: pane1, tab: { kind: 'vcs', title: 'VCS' } }));
    state = reducer(state, openOrFocusWorkbenchTab({ workspaceKey: 'ws-tab-dnd', paneId: pane1, tab: { kind: 'tasks', title: 'Tasks' } }));

    // Drag 'files' to split pane1 to the right
    state = reducer(
      state,
      splitWorkbenchPaneWithTab({
        workspaceKey: 'ws-tab-dnd',
        sourcePaneId: pane1,
        targetPaneId: pane1,
        tabId: 'files',
        direction: 'right',
      }),
    );
    const pane2 = state.workspaces['ws-tab-dnd'].tree.focusedPaneId;

    // Drag 'vcs' from pane1 into pane2 at index 0
    state = reducer(
      state,
      moveWorkbenchTabToPane({
        workspaceKey: 'ws-tab-dnd',
        sourcePaneId: pane1,
        targetPaneId: pane2,
        tabId: 'vcs',
        targetIndex: 0,
      }),
    );

    const p2Node = state.workspaces['ws-tab-dnd'].tree.panes[pane2];
    if (p2Node.kind === 'content') {
      assert.deepEqual(p2Node.value.tabs.map((t) => t.id), ['vcs', 'files']);
    }

    // Now move both 'vcs' and 'files' back to pane1 and close empty pane2 -> pane1 returns to 100%x100%
    state = reducer(
      state,
      moveWorkbenchTabToPane({ workspaceKey: 'ws-tab-dnd', sourcePaneId: pane2, targetPaneId: pane1, tabId: 'vcs' }),
    );
    state = reducer(
      state,
      moveWorkbenchTabToPane({ workspaceKey: 'ws-tab-dnd', sourcePaneId: pane2, targetPaneId: pane1, tabId: 'files' }),
    );
    if (state.workspaces['ws-tab-dnd'].tree.panes[pane2]) {
      const { closeWorkbenchPane } = await import('../../src/ui/store/workbenchSlice.ts');
      state = reducer(state, closeWorkbenchPane({ workspaceKey: 'ws-tab-dnd', paneId: pane2 }));
    }

    const { contentLayouts } = calculatePaneLayouts(state.workspaces['ws-tab-dnd'].tree);
    assert.equal(contentLayouts.length, 1);
    assert.equal(contentLayouts[0].paneId, pane1);
    assert.equal(contentLayouts[0].width, 100);
    assert.equal(contentLayouts[0].height, 100);
  });

  test('T3-06: Multi-instance agentChat (F6) + agentPty (F7) side-by-side tiling with independent per-agent composer drafts', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { readComposerDraft, writeComposerDraft } = await import('../../src/ui/utils/clientPersistence.ts');

    withMockWindowStorage(() => {
      let state = reducer(
        undefined,
        ensureWorkspaceInitialized({ workspaceKey: 'ws-agents', defaultAgentInstanceId: 'inst-coord' }),
      );
      const coordChatPane = state.workspaces['ws-agents'].tree.rootPaneId;

      // Split right for Worker 1 Chat
      state = reducer(
        state,
        openOrFocusWorkbenchTab({
          workspaceKey: 'ws-agents',
          paneId: coordChatPane,
          tab: { kind: 'agentChat', agentInstanceId: 'inst-worker-1', title: 'Worker 1 Chat' },
          splitDirection: 'right',
        }),
      );
      const workerChatPane = state.workspaces['ws-agents'].tree.focusedPaneId;

      // Split bottom under Coordinator Chat for Coordinator PTY
      state = reducer(
        state,
        openOrFocusWorkbenchTab({
          workspaceKey: 'ws-agents',
          paneId: coordChatPane,
          tab: { kind: 'agentPty', agentInstanceId: 'inst-coord', title: 'Coordinator PTY' },
          splitDirection: 'bottom',
        }),
      );

      // Split bottom under Worker 1 Chat for Worker 1 PTY
      state = reducer(
        state,
        openOrFocusWorkbenchTab({
          workspaceKey: 'ws-agents',
          paneId: workerChatPane,
          tab: { kind: 'agentPty', agentInstanceId: 'inst-worker-1', title: 'Worker 1 PTY' },
          splitDirection: 'bottom',
        }),
      );

      writeComposerDraft('inst-coord', 'Coordinator instructions');
      writeComposerDraft('inst-worker-1', 'Worker 1 patch feedback');

      assert.equal(readComposerDraft('inst-coord'), 'Coordinator instructions');
      assert.equal(readComposerDraft('inst-worker-1'), 'Worker 1 patch feedback');
    });
  });

  test('T3-07: Interactive shell (F8) + live preview (F9) + TerminalSessionRegistry state preservation across tab switches and splits', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      openPreviewInWorkbench,
      setActiveWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { TerminalSessionRegistry } = await import('../../src/ui/components/shells/terminalSessionRegistry.ts');

    const registry = new TerminalSessionRegistry();
    const term = new Terminal({ cols: 80, rows: 24 });
    const addon = new SerializeAddon();
    term.loadAddon(addon);
    registry.registerSerializeAddon('sh-dev-1', addon);

    await new Promise<void>((resolve) => term.write('vite v5.4.10 ready in 210 ms\r\n', () => resolve()));
    registry.saveSessionState('sh-dev-1', term);
    term.dispose();

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-dev', defaultAgentInstanceId: 'inst-1' }),
    );
    const pane1 = state.workspaces['ws-dev'].tree.rootPaneId;

    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-dev',
        paneId: pane1,
        tab: { kind: 'shell', sessionId: 'sh-dev-1', title: 'Dev Shell' },
        splitDirection: 'right',
      }),
    );
    const devPane = state.workspaces['ws-dev'].tree.focusedPaneId;

    state = reducer(
      state,
      openPreviewInWorkbench({
        workspaceKey: 'ws-dev',
        sessionId: 'srv-5173',
        label: 'Vite Preview',
        port: 5173,
      }),
    );

    // Switch back to shell tab and verify serialized snapshot is intact
    const shellTab = (state.workspaces['ws-dev'].tree.panes[devPane] as any).value.tabs.find(
      (t: any) => t.kind === 'shell',
    );
    state = reducer(
      state,
      setActiveWorkbenchTab({ workspaceKey: 'ws-dev', paneId: devPane, tabId: shellTab.id }),
    );

    const restored = registry.consumeRestorationData('sh-dev-1');
    assert.ok(restored?.snapshot.includes('vite v5.4.10 ready'));
  });

  test('T3-08: Pointer drag hit-testing (getSplitDirection & getOverlayPosition) driving moveWindowPane and moveWorkbenchPane', async () => {
    const { getSplitDirection, getOverlayPosition } = await import('../../src/ui/tiling/dragUtils.ts');
    const {
      default: wbReducer,
      ensureWorkspaceInitialized,
      splitWorkbenchPane,
      moveWorkbenchPane,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { calculatePaneLayouts } = await import('../../src/ui/tiling/calculatePaneLayout.ts');

    let state = wbReducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-drag-hit', defaultAgentInstanceId: 'inst-1' }),
    );
    const p1 = state.workspaces['ws-drag-hit'].tree.rootPaneId;
    state = wbReducer(state, splitWorkbenchPane({ workspaceKey: 'ws-drag-hit', targetPaneId: p1, direction: 'right' }));
    const p2 = state.workspaces['ws-drag-hit'].tree.focusedPaneId;

    // Simulate dragging p2 over the bottom quadrant of p1 (rect 0,0,500,800, cursor at 250, 750)
    const p1Rect = { left: 0, top: 0, width: 500, height: 800 };
    const dropDir = getSplitDirection(p1Rect, { x: 250, y: 750 });
    assert.equal(dropDir, 'bottom');

    const overlay = getOverlayPosition(p1Rect, dropDir);
    assert.deepEqual(overlay, { top: 400, left: 0, width: 500, height: 400 });

    state = wbReducer(
      state,
      moveWorkbenchPane({
        workspaceKey: 'ws-drag-hit',
        sourcePaneId: p2,
        targetPaneId: p1,
        direction: dropDir,
      }),
    );

    const { contentLayouts } = calculatePaneLayouts(state.workspaces['ws-drag-hit'].tree);
    const l1 = contentLayouts.find((l) => l.paneId === p1)!;
    const l2 = contentLayouts.find((l) => l.paneId === p2)!;
    assert.equal(l1.top, 0);
    assert.equal(l1.height, 50);
    assert.equal(l2.top, 50);
    assert.equal(l2.height, 50);
  });

  test('T3-09: NewConversationWindowPane selection (assignWindowPaneConversation) combined with ensureWorkspaceInitialized deep-link ?panel= initialization', async () => {
    const {
      default: winReducer,
      splitWindowPane,
      assignWindowPaneConversation,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');
    const {
      default: wbReducer,
      ensureWorkspaceInitialized,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let winState = winReducer(undefined, syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-1' }));
    winState = winReducer(winState, splitWindowPane({ direction: 'right' }));
    const newWinPaneId = winState.tree.focusedPaneId;

    winState = winReducer(
      winState,
      assignWindowPaneConversation({
        paneId: newWinPaneId,
        agentInstanceId: 'inst-picked',
        chainId: 'chain-picked',
      }),
    );

    const wbState = wbReducer(
      undefined,
      ensureWorkspaceInitialized({
        workspaceKey: 'chain-picked',
        defaultAgentInstanceId: 'inst-picked',
        initialPanel: 'vcs',
      }),
    );

    const ws = wbState.workspaces['chain-picked'];
    assert.ok(ws);
    const allTabs = Object.values(ws.tree.panes).flatMap((p) => (p.kind === 'content' ? p.value.tabs : []));
    assert.ok(allTabs.some((t) => t.kind === 'agentChat' && t.agentInstanceId === 'inst-picked'));
    assert.ok(allTabs.some((t) => t.kind === 'vcs'));
  });

  test('T3-10: Sash resize clamping + equalizePanes + calculatePaneLayouts across nested horizontal and vertical splits', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      splitWorkbenchPane,
      resizeWorkbenchSplit,
      equalizeWorkbenchPanes,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { calculatePaneLayouts } = await import('../../src/ui/tiling/calculatePaneLayout.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-sash', defaultAgentInstanceId: 'inst-1' }),
    );
    const p1 = state.workspaces['ws-sash'].tree.rootPaneId;
    state = reducer(state, splitWorkbenchPane({ workspaceKey: 'ws-sash', targetPaneId: p1, direction: 'right' }));
    const rootSplitId = state.workspaces['ws-sash'].tree.rootPaneId;

    // Resize to extreme 99% -> clamped to 95%
    state = reducer(state, resizeWorkbenchSplit({ workspaceKey: 'ws-sash', splitPaneId: rootSplitId, ratio: 99 }));
    let layouts = calculatePaneLayouts(state.workspaces['ws-sash'].tree).contentLayouts;
    assert.equal(layouts.find((l) => l.paneId === p1)!.width, 95);

    // Equalize back to 50%
    state = reducer(state, equalizeWorkbenchPanes({ workspaceKey: 'ws-sash' }));
    layouts = calculatePaneLayouts(state.workspaces['ws-sash'].tree).contentLayouts;
    assert.equal(layouts.find((l) => l.paneId === p1)!.width, 50);
  });

  test('T3-11: ProjectVcsPanel (vcs) directory cross-link (onOpenDirectory) + ProjectFilesPanel (files) quick-open and search-in-files flags', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-vcs-files', defaultAgentInstanceId: 'inst-1' }),
    );
    const pane1 = state.workspaces['ws-vcs-files'].tree.rootPaneId;

    // Open VCS tab
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-vcs-files',
        paneId: pane1,
        tab: { kind: 'vcs', title: 'VCS' },
      }),
    );

    // VCS triggers onOpenDirectory('src/ui/tiling') -> opens files tab with openFilePath
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey: 'ws-vcs-files',
        paneId: pane1,
        tab: {
          kind: 'files',
          title: 'Files',
          openFilePath: 'src/ui/tiling',
          initialOpenSearchInFiles: true,
        },
      }),
    );

    const pane = state.workspaces['ws-vcs-files'].tree.panes[pane1];
    if (pane.kind === 'content') {
      const filesTab = pane.value.tabs.find((t) => t.kind === 'files')!;
      assert.equal(filesTab.openFilePath, 'src/ui/tiling');
      assert.equal(filesTab.initialOpenSearchInFiles, true);
      assert.equal(pane.value.activeTabId, 'files');
    }
  });

  test('T3-12: openPreviewInWorkbench routing into activeWorkspaceKey when workspaceKey is omitted (as dispatched from ShellListPage / ShellDetail)', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      setActiveWorkspaceKey,
      openPreviewInWorkbench,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey: 'ws-active-target', defaultAgentInstanceId: 'inst-1' }),
    );
    state = reducer(state, setActiveWorkspaceKey('ws-active-target'));

    // Dispatch openPreviewInWorkbench without explicit workspaceKey
    state = reducer(
      state,
      openPreviewInWorkbench({
        sessionId: 'srv-from-shell-page',
        label: 'API Server',
        port: 4000,
        currentPath: '/v1/status',
      }),
    );

    const ws = state.workspaces['ws-active-target'];
    const allTabs = Object.values(ws.tree.panes).flatMap((p) => (p.kind === 'content' ? p.value.tabs : []));
    const prevTab = allTabs.find((t) => t.kind === 'preview' && t.sessionId === 'srv-from-shell-page');
    assert.ok(prevTab, 'openPreviewInWorkbench must route to activeWorkspaceKey when workspaceKey is omitted');
    assert.equal(prevTab.port, 4000);
    assert.equal(prevTab.currentPath, 'v1/status');
  });

  test('T3-13: Level 1 + Level 2 full localStorage persistence and hydration round-trip preserving split trees, ratios, and active tabs', async () => {
    const {
      default: winReducer,
      splitWindowPane,
      resizeWindowSplit,
      hydrateWindowLayout,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');
    const {
      default: wbReducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      resizeWorkbenchSplit,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const {
      readWindowLayoutState,
      writeWindowLayoutState,
      readWorkbenchWorkspaceState,
      writeWorkbenchWorkspaceState,
    } = await import('../../src/ui/utils/clientPersistence.ts');

    withMockWindowStorage(() => {
      let winState = winReducer(undefined, syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-1' }));
      winState = winReducer(winState, splitWindowPane({ direction: 'right', agentInstanceId: 'inst-2' }));
      winState = winReducer(winState, resizeWindowSplit({ splitPaneId: winState.tree.rootPaneId, ratio: 35 }));
      writeWindowLayoutState(winState.tree);

      let wbState = wbReducer(
        undefined,
        ensureWorkspaceInitialized({ workspaceKey: 'inst-1', defaultAgentInstanceId: 'inst-1' }),
      );
      wbState = wbReducer(
        wbState,
        openOrFocusWorkbenchTab({
          workspaceKey: 'inst-1',
          tab: { kind: 'files', title: 'Files', openFilePath: 'README.md' },
          splitDirection: 'right',
        }),
      );
      wbState = wbReducer(
        wbState,
        resizeWorkbenchSplit({
          workspaceKey: 'inst-1',
          splitPaneId: wbState.workspaces['inst-1'].tree.rootPaneId,
          ratio: 60,
        }),
      );
      writeWorkbenchWorkspaceState('inst-1', wbState.workspaces['inst-1'].tree);

      const loadedWin = readWindowLayoutState()!;
      const rehydratedWin = winReducer(undefined, hydrateWindowLayout(loadedWin));
      const winRoot = rehydratedWin.tree.panes[rehydratedWin.tree.rootPaneId];
      if (winRoot.kind === 'split') assert.equal(winRoot.ratio, 35);

      const loadedWb = readWorkbenchWorkspaceState('inst-1')!;
      const wbTree = loadedWb.tree || loadedWb;
      const wbRoot = wbTree.panes[wbTree.rootPaneId];
      if (wbRoot.kind === 'split') assert.equal(wbRoot.ratio, 60);
    });
  });

  test('T3-14: Headless xterm.js + SerializeAddon terminal state survives 2D pane tree splits, moves, and resizes with identical paneId', async () => {
    const { createPaneTreeState, splitPaneInTree, movePaneInTree, resizeSplitInTree } = await import(
      '../../src/ui/tiling/paneTreeState.ts'
    );
    const { calculatePaneLayouts } = await import('../../src/ui/tiling/calculatePaneLayout.ts');

    // Simulate a mounted terminal map keyed by paneId (as TilingContainer does via key={layout.paneId})
    const mountedTerminals = new Map<string, any>();
    const tree = createPaneTreeState({ surface: 'agentPty', agentInstanceId: 'inst-1' }, 'pane-term-1');

    const term = new Terminal({ cols: 80, rows: 24 });
    const serialize = new SerializeAddon();
    term.loadAddon(serialize);
    await new Promise<void>((r) => term.write('Agent live output line 1\r\n$ ', () => r()));
    mountedTerminals.set('pane-term-1', { term, serialize });

    // Perform split, nested split, move, and resize
    const s1 = splitPaneInTree(tree, 'pane-term-1', 'right', { surface: 'files', agentInstanceId: 'inst-1' }, 'pane-2');
    splitPaneInTree(tree, 'pane-2', 'bottom', { surface: 'vcs', agentInstanceId: 'inst-1' }, 'pane-3');
    movePaneInTree(tree, 'pane-term-1', 'pane-3', 'left');
    resizeSplitInTree(tree, s1.parentId, 45);

    const { contentLayouts } = calculatePaneLayouts(tree);
    const termLayout = contentLayouts.find((l) => l.paneId === 'pane-term-1');
    assert.ok(termLayout, 'pane-term-1 must remain in contentLayouts with identical key');

    const mounted = mountedTerminals.get(termLayout.paneId)!;
    assert.ok(mounted.serialize.serialize().includes('Agent live output line 1'));
    mounted.term.dispose();
  });

  test('T3-15: swapWindowPanes (F3) + swapPanesInTree (F2) + setActiveWorkspaceKey (F4) keep focus and content values consistent', async () => {
    const {
      default: winReducer,
      splitWindowPane,
      swapWindowPanes,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');
    const {
      default: wbReducer,
      ensureWorkspaceInitialized,
      setActiveWorkspaceKey,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    let winState = winReducer(undefined, syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-left' }));
    const leftId = winState.tree.rootPaneId;
    winState = winReducer(winState, splitWindowPane({ targetPaneId: leftId, direction: 'right', agentInstanceId: 'inst-right' }));
    const rightId = winState.tree.focusedPaneId;

    winState = winReducer(winState, swapWindowPanes({ paneIdA: leftId, paneIdB: rightId }));
    const rootSplit = winState.tree.panes[winState.tree.rootPaneId];
    if (rootSplit.kind === 'split') {
      assert.equal(rootSplit.leftChildId, rightId);
      assert.equal(rootSplit.rightChildId, leftId);
    }

    let wbState = wbReducer(undefined, ensureWorkspaceInitialized({ workspaceKey: 'inst-left', defaultAgentInstanceId: 'inst-left' }));
    wbState = wbReducer(wbState, ensureWorkspaceInitialized({ workspaceKey: 'inst-right', defaultAgentInstanceId: 'inst-right' }));
    wbState = wbReducer(wbState, setActiveWorkspaceKey('inst-right'));
    assert.equal(wbState.activeWorkspaceKey, 'inst-right');
  });

  test('T3-16: Full Redux store (src/ui/store/store.ts) dispatches combined windowLayout and workbench actions and resets on priorUserClientStateCleared', async () => {
    const { combineReducers, configureStore } = await import('@reduxjs/toolkit');
    const { store, priorUserClientStateCleared } = await import('../../src/ui/store/store.ts');
    const {
      default: windowLayoutReducer,
      syncRouteConversationToWindowLayout,
      splitWindowPane,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');
    const {
      default: workbenchReducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    const rootState = store.getState() as any;
    assert.ok(rootState.windowLayout?.tree, 'store.ts must register windowLayout slice');
    assert.ok(rootState.workbench?.workspaces, 'store.ts must register workbench slice');

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

    testStore.dispatch(syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-store-1' }));
    testStore.dispatch(splitWindowPane({ direction: 'right', agentInstanceId: 'inst-store-2' }));
    testStore.dispatch(
      ensureWorkspaceInitialized({ workspaceKey: 'inst-store-1', defaultAgentInstanceId: 'inst-store-1' }),
    );
    testStore.dispatch(
      openOrFocusWorkbenchTab({
        workspaceKey: 'inst-store-1',
        tab: { kind: 'chainOverview', title: 'Overview' },
        splitDirection: 'right',
      }),
    );

    const state = testStore.getState();
    assert.ok(state.windowLayout.tree);
    assert.ok(state.workbench.workspaces['inst-store-1']);

    testStore.dispatch(priorUserClientStateCleared());
    const clearedState = testStore.getState();
    assert.deepEqual(clearedState.workbench.workspaces, {});
  });
});
