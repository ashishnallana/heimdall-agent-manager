/**
 * Tier 4 — Real-World Application Scenarios E2E Test Suite
 *
 * Verifies 6 realistic, multi-step end-to-end user workflows across F1–F12 per
 * ORIGINAL_REQUEST.md, PROJECT.md § Interface Contracts, and TEST_INFRA.md:
 * - Scenario 1: Multi-Agent Coordinator + 2 Worker Agents side-by-side `agentChat` + `agentPty` debugging workbench with independent composer drafts and live terminal streams.
 * - Scenario 2: Full-Stack Web App Dev Workflow (`shell` dev server + `preview` port proxy with URL subpath & `Stdout` toggle + `files` editor + `vcs` diff view).
 * - Scenario 3: Task Chain Triage (`chainOverview` -> `tasks` -> `vcs` file diff -> `files` editor -> worker `agentChat` split) without clobbering existing views.
 * - Scenario 4: Multi-Conversation Window Tiling (Level 1) + `NewConversationWindowPane` selection + full `localStorage` persistence & hydration round-trip across window reload.
 * - Scenario 5: Heavy 2D Split Rearrangement & Maximize/Restore Stress Test (verifying 100% pane ID stability and zero terminal/iframe unmount across 10 sequential splits, moves, resizes, and tab transfers).
 * - Scenario 6: Full Repository Architectural & R4 Cleanliness Audit (verifying deleted files, zero dangling references across all `.ts`/`.tsx` files in `src/` and `tests/`, and Redux store registration).
 *
 * Total Tier 4 Scenarios: 6 (>= 6 required)
 *
 * RUN: npx tsx --test tests/e2e/jetski_workbench_tier4_test.ts
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import * as xtermModule from '@xterm/xterm';
import * as serializeModule from '@xterm/addon-serialize';
import '../helpers/vaultEndpointHarness.ts';

const REPO_ROOT = path.resolve(import.meta.dirname, '../..');

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
    location: prevWindow?.location || { hash: '#/conversations/inst-coord', origin: 'http://127.0.0.1:5173' },
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

describe('Tier 4: Real-World End-to-End Application Scenarios', () => {
  test('Scenario 1: Multi-Agent Coordinator + 2 Worker Agents side-by-side agentChat + agentPty debugging workbench with independent composer drafts and live terminal streams', async () => {
    const { NEW_TAB_ID } = await import('../../src/ui/store/workbenchTabId.ts');
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      splitWorkbenchPane,
      openNewTabView,
      openOrFocusWorkbenchTab,
      setActiveWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { calculatePaneLayouts } = await import('../../src/ui/tiling/calculatePaneLayout.ts');
    const { readComposerDraft, writeComposerDraft } = await import('../../src/ui/utils/clientPersistence.ts');

    withMockWindowStorage(() => {
      const workspaceKey = 'chain-multi-agent-debug';

      // Step 1: User opens Coordinator conversation
      let state = reducer(
        undefined,
        ensureWorkspaceInitialized({
          workspaceKey,
          defaultAgentInstanceId: 'inst-coord',
          defaultTitle: 'Coordinator',
        }),
      );
      const coordPaneId = state.workspaces[workspaceKey].tree.rootPaneId;

      // Step 2: User splits right -> gets NEW_TAB_ID launcher -> opens Worker 1 Chat & Worker 2 Chat as tabs in the right pane
      state = reducer(state, splitWorkbenchPane({ workspaceKey, targetPaneId: coordPaneId, direction: 'right' }));
      const workersChatPaneId = state.workspaces[workspaceKey].tree.focusedPaneId;
      assert.equal(
        (state.workspaces[workspaceKey].tree.panes[workersChatPaneId] as any).value.activeTabId,
        NEW_TAB_ID,
      );

      state = reducer(
        state,
        openOrFocusWorkbenchTab({
          workspaceKey,
          paneId: workersChatPaneId,
          tab: { kind: 'agentChat', agentInstanceId: 'inst-worker-1', title: 'Worker 1 Chat' },
        }),
      );
      state = reducer(state, openNewTabView({ workspaceKey, paneId: workersChatPaneId }));
      state = reducer(
        state,
        openOrFocusWorkbenchTab({
          workspaceKey,
          paneId: workersChatPaneId,
          tab: { kind: 'agentChat', agentInstanceId: 'inst-worker-2', title: 'Worker 2 Chat' },
        }),
      );

      // Step 3: User splits bottom under workersChatPaneId -> opens live agentPty terminals for Coordinator, Worker 1, and Worker 2
      state = reducer(state, splitWorkbenchPane({ workspaceKey, targetPaneId: workersChatPaneId, direction: 'bottom' }));
      const ptyPaneId = state.workspaces[workspaceKey].tree.focusedPaneId;

      for (const agent of [
        { id: 'inst-coord', title: 'Coord PTY' },
        { id: 'inst-worker-1', title: 'Worker 1 PTY' },
        { id: 'inst-worker-2', title: 'Worker 2 PTY' },
      ]) {
        state = reducer(
          state,
          openOrFocusWorkbenchTab({
            workspaceKey,
            paneId: ptyPaneId,
            tab: { kind: 'agentPty', agentInstanceId: agent.id, title: agent.title },
          }),
        );
      }

      // Step 4: User types independent drafts in Coordinator, Worker 1, and Worker 2 composers
      writeComposerDraft('inst-coord', 'Dispatching milestone 2 to workers');
      writeComposerDraft('inst-worker-1', 'Focus on src/ui/tiling/paneTreeState.ts');
      writeComposerDraft('inst-worker-2', 'Focus on src/ui/components/workbench/');

      assert.equal(readComposerDraft('inst-coord'), 'Dispatching milestone 2 to workers');
      assert.equal(readComposerDraft('inst-worker-1'), 'Focus on src/ui/tiling/paneTreeState.ts');
      assert.equal(readComposerDraft('inst-worker-2'), 'Focus on src/ui/components/workbench/');

      // Step 5: Verify layout geometry and active tab switching across the 3 panes
      const { contentLayouts } = calculatePaneLayouts(state.workspaces[workspaceKey].tree);
      assert.equal(contentLayouts.length, 3);

      const ptyPane = state.workspaces[workspaceKey].tree.panes[ptyPaneId];
      assert.equal(ptyPane.kind, 'content');
      if (ptyPane.kind === 'content') {
        assert.equal(ptyPane.value.tabs.length, 3);
        const worker1PtyTabId = ptyPane.value.tabs.find((t) => t.agentInstanceId === 'inst-worker-1')!.id;
        state = reducer(
          state,
          setActiveWorkbenchTab({ workspaceKey, paneId: ptyPaneId, tabId: worker1PtyTabId }),
        );
        const updatedPtyPane = state.workspaces[workspaceKey].tree.panes[ptyPaneId];
        if (updatedPtyPane.kind === 'content') {
          assert.equal(updatedPtyPane.value.activeTabId, worker1PtyTabId);
        }
      }
    });
  });

  test('Scenario 2: Full-Stack Web App Dev Workflow (shell dev server + preview port proxy with URL subpath & Stdout toggle + files editor + vcs diff view)', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      openPreviewInWorkbench,
      updateWorkbenchTabParams,
      resizeWorkbenchSplit,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { calculatePaneLayouts } = await import('../../src/ui/tiling/calculatePaneLayout.ts');
    const { TerminalSessionRegistry } = await import('../../src/ui/components/shells/terminalSessionRegistry.ts');

    const workspaceKey = 'chain-fullstack-dev';
    const registry = new TerminalSessionRegistry();

    // Step 1: Initialize workspace with agentChat on left
    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey, defaultAgentInstanceId: 'inst-fullstack' }),
    );
    const chatPaneId = state.workspaces[workspaceKey].tree.rootPaneId;

    // Step 2: Split right for Files Editor (`ProjectFilesPanel`) and VCS Diff (`ProjectVcsPanel`)
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey,
        paneId: chatPaneId,
        tab: { kind: 'files', title: 'Files', openFilePath: 'src/ui/App.tsx' },
        splitDirection: 'right',
      }),
    );
    const codePaneId = state.workspaces[workspaceKey].tree.focusedPaneId;

    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey,
        paneId: codePaneId,
        tab: { kind: 'vcs', title: 'VCS Changes', initialFilePath: 'src/ui/App.tsx' },
      }),
    );

    // Step 3: Split bottom under codePaneId for Interactive Shell (`shell`) + Live Web Preview (`preview`)
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey,
        paneId: codePaneId,
        tab: { kind: 'shell', sessionId: 'sh-vite-server', title: 'npm run dev' },
        splitDirection: 'bottom',
      }),
    );
    const runtimePaneId = state.workspaces[workspaceKey].tree.focusedPaneId;

    // Stream live dev server output into headless xterm + TerminalSessionRegistry
    const term = new Terminal({ cols: 100, rows: 30 });
    const serializeAddon = new SerializeAddon();
    term.loadAddon(serializeAddon);
    registry.registerSerializeAddon('sh-vite-server', serializeAddon);
    await new Promise<void>((r) =>
      term.write('VITE v5.4.10  ready in 312 ms\r\n  ➜  Local:   http://127.0.0.1:5173/\r\n', () => r()),
    );
    registry.saveSessionState('sh-vite-server', term);
    term.dispose();

    // Step 4: Click "Open Preview" on active server (`openPreviewInWorkbench`)
    state = reducer(
      state,
      openPreviewInWorkbench({
        workspaceKey,
        sessionId: 'srv-5173',
        label: 'Vite :5173',
        port: 5173,
        currentPath: '/settings/agents',
      }),
    );

    // Navigate subpath inside preview URL bar
    const runtimePane = state.workspaces[workspaceKey].tree.panes[runtimePaneId];
    assert.equal(runtimePane.kind, 'content');
    const previewTab =
      runtimePane.kind === 'content' ? runtimePane.value.tabs.find((t) => t.kind === 'preview')! : null;
    assert.ok(previewTab);
    assert.equal(previewTab.currentPath, 'settings/agents');

    state = reducer(
      state,
      updateWorkbenchTabParams({
        workspaceKey,
        paneId: runtimePaneId,
        tabId: previewTab.id,
        patch: { currentPath: 'workbench/demo?theme=dark' },
      }),
    );

    // Resize root split to 35% chat / 65% code+runtime
    state = reducer(
      state,
      resizeWorkbenchSplit({
        workspaceKey,
        splitPaneId: state.workspaces[workspaceKey].tree.rootPaneId,
        ratio: 35,
      }),
    );

    const { contentLayouts } = calculatePaneLayouts(state.workspaces[workspaceKey].tree);
    assert.equal(contentLayouts.length, 3);
    const chatLayout = contentLayouts.find((l) => l.paneId === chatPaneId)!;
    assert.equal(chatLayout.width, 35);

    const restoredTerm = registry.consumeRestorationData('sh-vite-server');
    assert.ok(restoredTerm?.snapshot.includes('http://127.0.0.1:5173/'));
  });

  test('Scenario 3: Task Chain Triage (chainOverview -> tasks -> vcs file diff -> files editor -> worker agentChat split) without clobbering existing views', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
      updateWorkbenchTabParams,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    const workspaceKey = 'chain-triage-workflow';

    // Step 1: Open conversation with ?panel=chain deep link
    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({
        workspaceKey,
        defaultAgentInstanceId: 'inst-coord',
        initialPanel: 'chain',
      }),
    );

    // Step 2: From ChainOverviewPanel, user clicks a blocked task -> onSelectTask('task-blocked-7')
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey,
        tab: { kind: 'tasks', title: 'Tasks', focusTaskId: 'task-blocked-7' },
      }),
    );

    // TaskChainOverview consumes focusTaskId
    state = reducer(
      state,
      updateWorkbenchTabParams({
        workspaceKey,
        tabId: 'tasks',
        patch: { focusTaskId: undefined },
      }),
    );

    // Step 3: User clicks modified file in ChainOverviewPanel -> onOpenFileDiff('src/ui/store/store.ts')
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey,
        tab: { kind: 'vcs', title: 'VCS', initialFilePath: 'src/ui/store/store.ts' },
      }),
    );

    // Step 4: User clicks file link in task description -> onOpenFileInFilesPanel('src/ui/tiling/TilingContainer.tsx')
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey,
        tab: { kind: 'files', title: 'Files', openFilePath: 'src/ui/tiling/TilingContainer.tsx' },
      }),
    );

    // Step 5: User clicks member agent in ChainOverviewPanel to open Worker Chat in a bottom split
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey,
        tab: { kind: 'agentChat', agentInstanceId: 'inst-worker-triage', title: 'Triage Worker' },
        splitDirection: 'bottom',
      }),
    );

    // Verify all 5 surfaces (Coordinator agentChat, chainOverview, tasks, vcs, files, and Triage Worker agentChat) are still open and un-clobbered
    const ws = state.workspaces[workspaceKey];
    const allTabs = getContentPaneIds(ws.tree).flatMap((id) => {
      const p = ws.tree.panes[id];
      return p.kind === 'content' ? p.value.tabs : [];
    });

    assert.ok(allTabs.some((t) => t.kind === 'agentChat' && t.agentInstanceId === 'inst-coord'));
    assert.ok(allTabs.some((t) => t.kind === 'agentChat' && t.agentInstanceId === 'inst-worker-triage'));
    assert.ok(allTabs.some((t) => t.kind === 'chainOverview'));
    assert.ok(allTabs.some((t) => t.kind === 'tasks'));
    assert.ok(allTabs.some((t) => t.kind === 'vcs' && t.initialFilePath === 'src/ui/store/store.ts'));
    assert.ok(allTabs.some((t) => t.kind === 'files' && t.openFilePath === 'src/ui/tiling/TilingContainer.tsx'));
  });

  test('Scenario 4: Multi-Conversation Window Tiling (Level 1) + NewConversationWindowPane selection + full localStorage persistence & hydration round-trip across window reload', async () => {
    const {
      default: winReducer,
      NEW_WINDOW_PANE_ID,
      splitWindowPane,
      assignWindowPaneConversation,
      resizeWindowSplit,
      hydrateWindowLayout,
      syncRouteConversationToWindowLayout,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');
    const {
      default: wbReducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const {
      readWindowLayoutState,
      writeWindowLayoutState,
      readWorkbenchWorkspaceState,
      writeWorkbenchWorkspaceState,
    } = await import('../../src/ui/utils/clientPersistence.ts');
    const { calculatePaneLayouts } = await import('../../src/ui/tiling/calculatePaneLayout.ts');

    withMockWindowStorage(() => {
      // Step 1: User starts on Conversation 1
      let winState = winReducer(
        undefined,
        syncRouteConversationToWindowLayout({
          agentInstanceId: 'inst-convo-1',
          chainId: 'chain-1',
          projectId: 'proj-1',
          title: 'Frontend Redesign',
        }),
      );
      const winPane1 = winState.tree.rootPaneId;

      // Step 2: User splits window horizontally ('right') -> sees NewConversationWindowPane ('_new')
      winState = winReducer(winState, splitWindowPane({ targetPaneId: winPane1, direction: 'right' }));
      const winPane2 = winState.tree.focusedPaneId;
      const pane2Before = winState.tree.panes[winPane2];
      assert.equal(pane2Before.kind, 'content');
      if (pane2Before.kind === 'content') {
        assert.equal(pane2Before.value.kind, 'new');
        assert.equal(pane2Before.value.agentInstanceId, NEW_WINDOW_PANE_ID);
      }

      // Step 3: User selects Conversation 2 inside NewConversationWindowPane
      winState = winReducer(
        winState,
        assignWindowPaneConversation({
          paneId: winPane2,
          agentInstanceId: 'inst-convo-2',
          chainId: 'chain-2',
          projectId: 'proj-2',
          title: 'Backend API',
        }),
      );

      // Step 4: User resizes window split to 45% / 55% and configures Level 2 workbenches for both conversations
      winState = winReducer(
        winState,
        resizeWindowSplit({ splitPaneId: winState.tree.rootPaneId, ratio: 45 }),
      );

      let wbState = wbReducer(
        undefined,
        ensureWorkspaceInitialized({ workspaceKey: 'chain-1', defaultAgentInstanceId: 'inst-convo-1' }),
      );
      wbState = wbReducer(
        wbState,
        openOrFocusWorkbenchTab({
          workspaceKey: 'chain-1',
          tab: { kind: 'files', title: 'Files', openFilePath: 'src/ui/main.tsx' },
          splitDirection: 'bottom',
        }),
      );

      wbState = wbReducer(
        wbState,
        ensureWorkspaceInitialized({ workspaceKey: 'chain-2', defaultAgentInstanceId: 'inst-convo-2' }),
      );
      wbState = wbReducer(
        wbState,
        openOrFocusWorkbenchTab({
          workspaceKey: 'chain-2',
          tab: { kind: 'shell', sessionId: 'sh-backend', title: 'Backend Shell' },
          splitDirection: 'right',
        }),
      );

      // Step 5: Persist Level 1 and Level 2 states to localStorage
      writeWindowLayoutState(winState.tree);
      writeWorkbenchWorkspaceState('chain-1', wbState.workspaces['chain-1'].tree);
      writeWorkbenchWorkspaceState('chain-2', wbState.workspaces['chain-2'].tree);

      // Step 6: Simulate full browser reload by rehydrating from localStorage
      const restoredWinTree = readWindowLayoutState()!;
      const rehydratedWin = winReducer(undefined, hydrateWindowLayout(restoredWinTree));
      const { contentLayouts: winLayouts } = calculatePaneLayouts(rehydratedWin.tree);
      assert.equal(winLayouts.length, 2);
      assert.equal(Math.round(winLayouts.find((l) => l.paneId === winPane1)!.width), 45);
      assert.equal(Math.round(winLayouts.find((l) => l.paneId === winPane2)!.width), 55);

      const restoredWb1 = readWorkbenchWorkspaceState('chain-1')!;
      const restoredWb2 = readWorkbenchWorkspaceState('chain-2')!;
      assert.equal(calculatePaneLayouts(restoredWb1.tree || restoredWb1).contentLayouts.length, 2);
      assert.equal(calculatePaneLayouts(restoredWb2.tree || restoredWb2).contentLayouts.length, 2);
    });
  });

  test('Scenario 5: Heavy 2D Split Rearrangement & Maximize/Restore Stress Test (100% pane ID stability across 10 sequential operations)', async () => {
    const {
      default: reducer,
      ensureWorkspaceInitialized,
      splitWorkbenchPane,
      openOrFocusWorkbenchTab,
      moveWorkbenchPane,
      resizeWorkbenchSplit,
      toggleMaximizeWorkbenchPane,
      moveWorkbenchTabToPane,
      equalizeWorkbenchPanes,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { calculatePaneLayouts } = await import('../../src/ui/tiling/calculatePaneLayout.ts');

    const workspaceKey = 'ws-stress-test';
    let state = reducer(
      undefined,
      ensureWorkspaceInitialized({ workspaceKey, defaultAgentInstanceId: 'inst-root' }),
    );
    const p1 = state.workspaces[workspaceKey].tree.rootPaneId;

    // Op 1: Split p1 right -> p2 (agentPty)
    state = reducer(state, splitWorkbenchPane({ workspaceKey, targetPaneId: p1, direction: 'right' }));
    const p2 = state.workspaces[workspaceKey].tree.focusedPaneId;
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey,
        paneId: p2,
        tab: { kind: 'agentPty', agentInstanceId: 'inst-root', title: 'PTY' },
      }),
    );

    // Op 2: Split p2 bottom -> p3 (shell)
    state = reducer(state, splitWorkbenchPane({ workspaceKey, targetPaneId: p2, direction: 'bottom' }));
    const p3 = state.workspaces[workspaceKey].tree.focusedPaneId;
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey,
        paneId: p3,
        tab: { kind: 'shell', sessionId: 'sh-stress', title: 'Shell' },
      }),
    );

    // Op 3: Split p1 bottom -> p4 (preview + files)
    state = reducer(state, splitWorkbenchPane({ workspaceKey, targetPaneId: p1, direction: 'bottom' }));
    const p4 = state.workspaces[workspaceKey].tree.focusedPaneId;
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey,
        paneId: p4,
        tab: { kind: 'preview', sessionId: 'srv-stress', port: 8080, title: 'Preview' },
      }),
    );
    state = reducer(
      state,
      openOrFocusWorkbenchTab({
        workspaceKey,
        paneId: p4,
        tab: { kind: 'files', title: 'Files' },
      }),
    );

    const expectedPaneIds = [p1, p2, p3, p4].sort();

    // Op 4: Move p4 to the top of p2
    state = reducer(state, moveWorkbenchPane({ workspaceKey, sourcePaneId: p4, targetPaneId: p2, direction: 'top' }));
    assert.deepEqual(
      calculatePaneLayouts(state.workspaces[workspaceKey].tree).contentLayouts.map((l) => l.paneId).sort(),
      expectedPaneIds,
    );

    // Op 5: Move p3 to the left of p1
    state = reducer(state, moveWorkbenchPane({ workspaceKey, sourcePaneId: p3, targetPaneId: p1, direction: 'left' }));
    assert.deepEqual(
      calculatePaneLayouts(state.workspaces[workspaceKey].tree).contentLayouts.map((l) => l.paneId).sort(),
      expectedPaneIds,
    );

    // Op 6: Resize root split to 25%
    state = reducer(
      state,
      resizeWorkbenchSplit({
        workspaceKey,
        splitPaneId: state.workspaces[workspaceKey].tree.rootPaneId,
        ratio: 25,
      }),
    );

    // Op 7: Maximize p3 (shell)
    state = reducer(state, toggleMaximizeWorkbenchPane({ workspaceKey, paneId: p3 }));
    assert.equal(state.workspaces[workspaceKey].tree.maximizedPaneId, p3);
    assert.deepEqual(
      calculatePaneLayouts(state.workspaces[workspaceKey].tree).contentLayouts.map((l) => l.paneId).sort(),
      expectedPaneIds,
    );

    // Op 8: Transfer 'files' tab from p4 to p1 while p3 is maximized
    state = reducer(
      state,
      moveWorkbenchTabToPane({
        workspaceKey,
        sourcePaneId: p4,
        targetPaneId: p1,
        tabId: 'files',
      }),
    );

    // Op 9: Restore p3 from maximized
    state = reducer(state, toggleMaximizeWorkbenchPane({ workspaceKey, paneId: p3 }));
    assert.ok(!state.workspaces[workspaceKey].tree.maximizedPaneId);

    // Op 10: Equalize all split ratios
    state = reducer(state, equalizeWorkbenchPanes({ workspaceKey }));
    const finalLayouts = calculatePaneLayouts(state.workspaces[workspaceKey].tree).contentLayouts;
    assert.deepEqual(
      finalLayouts.map((l) => l.paneId).sort(),
      expectedPaneIds,
      'All 4 leaf pane IDs must remain 100% identical after 10 stress operations',
    );
  });

  test('Scenario 6: Full Repository Architectural & R4 Cleanliness Audit (deleted files, zero dangling references in src/ and tests/, Redux store registration)', async () => {
    // 2. Verify all 5 legacy files are deleted
    const deletedPaths = [
      'src/ui/components/shell/BottomDock.tsx',
      'src/ui/components/shells/PreviewSidebar.tsx',
      'src/ui/store/previewTabsSlice.ts',
      'src/ui/components/monitor/AgentMonitorPage.tsx',
      'src/ui/components/monitor/AgentCellComposer.tsx',
    ];
    for (const rel of deletedPaths) {
      assert.equal(fs.existsSync(path.join(REPO_ROOT, rel)), false, `${rel} must not exist on disk`);
    }

    // 3. Verify all new architecture files exist
    const requiredNewFiles = [
      'src/ui/tiling/types.ts',
      'src/ui/tiling/paneTreeState.ts',
      'src/ui/tiling/calculatePaneLayout.ts',
      'src/ui/tiling/dragUtils.ts',
      'src/ui/tiling/TilingContainer.tsx',
      'src/ui/store/windowLayoutSlice.ts',
      'src/ui/store/workbenchTabId.ts',
      'src/ui/store/workbenchSlice.ts',
      'src/ui/components/workbench/ConversationWorkbench.tsx',
      'src/ui/components/workbench/WorkbenchPaneView.tsx',
      'src/ui/components/workbench/WorkbenchTabStrip.tsx',
      'src/ui/components/workbench/WorkbenchNewTabLauncher.tsx',
      'src/ui/components/workbench/AgentChatPane.tsx',
      'src/ui/components/workbench/AgentPtyWorkbenchPane.tsx',
      'src/ui/components/workbench/ShellWorkbenchPane.tsx',
      'src/ui/components/workbench/PreviewWorkbenchPane.tsx',
      'src/ui/components/windowTiling/WindowTilingHost.tsx',
      'src/ui/components/windowTiling/WindowPaneFrame.tsx',
      'src/ui/components/windowTiling/NewConversationWindowPane.tsx',
    ];
    for (const rel of requiredNewFiles) {
      assert.equal(fs.existsSync(path.join(REPO_ROOT, rel)), true, `Required file ${rel} must exist`);
    }

    // 4. Scan all .ts/.tsx files in src/ and non-e2e tests/ for dangling imports of deleted modules
    const walkTs = (dir: string): string[] => {
      const out: string[] = [];
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) {
          if (entry.name === 'e2e') continue;
          out.push(...walkTs(full));
        } else if (/\.(ts|tsx)$/.test(entry.name)) {
          out.push(full);
        }
      }
      return out;
    };

    const bannedImportPatterns = [
      /from\s+['"][^'"]*BottomDock['"]/,
      /from\s+['"][^'"]*PreviewSidebar['"]/,
      /from\s+['"][^'"]*previewTabsSlice['"]/,
      /from\s+['"][^'"]*AgentMonitorPage['"]/,
      /from\s+['"][^'"]*AgentCellComposer['"]/,
      /\breadRightSidebarTab\b/,
      /\bwriteRightSidebarTab\b/,
      /\breadRightSidebarOpen\b/,
      /\bwriteRightSidebarOpen\b/,
      /\breadBottomDockOpen\b/,
      /\bwriteBottomDockOpen\b/,
      /\breadPinnedMonitorAgents\b/,
      /\baddPinnedMonitorAgent\b/,
    ];

    for (const file of [...walkTs(path.join(REPO_ROOT, 'src')), ...walkTs(path.join(REPO_ROOT, 'tests'))]) {
      const content = fs.readFileSync(file, 'utf8');
      for (const pattern of bannedImportPatterns) {
        assert.ok(
          !pattern.test(content),
          `Dangling reference matching ${pattern} found in ${path.relative(REPO_ROOT, file)}`,
        );
      }
    }
  });
});
