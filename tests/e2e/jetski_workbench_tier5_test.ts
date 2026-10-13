import '../helpers/vaultEndpointHarness.ts';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import React from 'react';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '../..');

// ============================================================================
// Focus Area 1: Level 1 Window Tiling & Selector Reference Stability (M3 Polish)
// ============================================================================

describe('Tier 5 Adversarial Audit — Focus Area 1: Window Layout Selector Reference Stability & Route Sync', () => {
  test('adv_f1_01: selectOpenWindowConversationIds returns the exact same string[] reference across calls when windowLayout.tree has not changed', async () => {
    const {
      default: windowLayoutReducer,
      assignWindowPaneConversation,
      splitWindowPane,
      setWindowPendingDropTarget,
      selectOpenWindowConversationIds,
    } = await import('../../src/ui/store/windowLayoutSlice.ts');

    let wlState = windowLayoutReducer(
      undefined,
      assignWindowPaneConversation({
        paneId: 'window-pane-1',
        agentInstanceId: 'inst-alpha',
        chainId: 'chain-1',
        projectId: 'proj-1',
      }),
    );
    wlState = windowLayoutReducer(
      wlState,
      splitWindowPane({
        targetPaneId: 'window-pane-1',
        direction: 'right',
        agentInstanceId: 'inst-beta',
        chainId: 'chain-2',
        projectId: 'proj-1',
      }),
    );

    const rootState1 = { windowLayout: wlState };
    const result1 = selectOpenWindowConversationIds(rootState1);
    const result2 = selectOpenWindowConversationIds(rootState1);

    assert.deepEqual(result1, ['inst-alpha', 'inst-beta']);
    assert.equal(
      result1,
      result2,
      'selectOpenWindowConversationIds must return the exact same array reference when tree is unchanged',
    );

    // Non-tree state change (pendingDropTarget) must also preserve the memoized array reference
    const wlStateWithDrop = windowLayoutReducer(
      wlState,
      setWindowPendingDropTarget({ paneId: 'window-pane-1', direction: 'left' }),
    );
    const result3 = selectOpenWindowConversationIds({ windowLayout: wlStateWithDrop });
    assert.equal(
      result1,
      result3,
      'selectOpenWindowConversationIds must preserve reference when only pendingDropTarget changes',
    );
  });
});

// ============================================================================
// Focus Area 2: Level 2 Workbench UI, All 8 Surfaces, & AgentChatPane
// Original Transcript/Composer & Jetski Header/Popup Follow-Up Requirements
// ============================================================================

describe('Tier 5 Adversarial Audit — Focus Area 2: AgentChatPane Follow-up Requirements & Level 2 Workbench Surfaces', () => {
  test('adv_f2_01: AgentChatPane restores original <ChatMessageList> transcript rendering and all required helpers (ORIGINAL_REQUEST L68-69)', () => {
    const chatPanePath = path.join(REPO_ROOT, 'src/ui/components/workbench/AgentChatPane.tsx');
    const source = fs.readFileSync(chatPanePath, 'utf8');

    const requiredTranscriptSymbols = [
      'ChatMessageList',
      'groupTranscriptMessages',
      'renderConversationMessageBody',
      'ThreadMessageBody',
      'PaneCaptureOutput',
      'ShellRunRow',
      'ClubbedRunGroup',
      'isAgentStartMessage',
      'formatMessageTimestamp',
      'deliveryStatusFor',
      'agentIsWorking',
      'handleSendReply',
      'loadOlderMessages',
      'emptyState',
      'AgentActivityBubbles',
      'PinnedShellRuns',
    ];

    for (const sym of requiredTranscriptSymbols) {
      assert.ok(
        source.includes(sym),
        `AgentChatPane.tsx must include original transcript symbol/component "${sym}" per ORIGINAL_REQUEST.md L68-69`,
      );
    }

    assert.ok(
      source.includes('<ChatMessageList'),
      'AgentChatPane.tsx must mount <ChatMessageList',
    );
    assert.ok(
      source.includes('<AgentActivityBubbles'),
      'AgentChatPane.tsx must mount <AgentActivityBubbles',
    );
    assert.ok(
      source.includes('<PinnedShellRuns'),
      'AgentChatPane.tsx must mount <PinnedShellRuns',
    );
  });

  test('adv_f2_02: AgentChatPane preserves all special and standard transcript message types in renderConversationMessageBody (ORIGINAL_REQUEST L70)', () => {
    const chatPanePath = path.join(REPO_ROOT, 'src/ui/components/workbench/AgentChatPane.tsx');
    const source = fs.readFileSync(chatPanePath, 'utf8');

    const requiredMessageTypes = [
      'shell_run_group',
      'shell_run',
      'pane_capture',
      'configuration_change',
      'agent_start_clubbed',
      'isAgentStartMessage',
      "'system'",
      "'action'",
      'ArtifactAttachmentPreview',
    ];

    for (const msgType of requiredMessageTypes) {
      assert.ok(
        source.includes(msgType),
        `AgentChatPane.tsx must handle message type / renderer "${msgType}" per ORIGINAL_REQUEST.md L70`,
      );
    }

    const requiredDebugIds = [
      'conversation-pane-capture-pre-',
      'conversation-configuration-event-',
      'conversation-agent-start-clubbed-',
      'conversation-agent-start-',
      'conversation-system-message-',
      'conversation-action-message-',
      'conversation-thread-empty-state',
      'conversation-thread-empty-avatar',
      'conversation-thread-empty-title',
      'conversation-thread-empty-persona',
    ];

    for (const dbgId of requiredDebugIds) {
      assert.ok(
        source.includes(dbgId),
        `AgentChatPane.tsx must preserve transcript data-debug-id "${dbgId}"`,
      );
    }
  });

  test('adv_f2_03: AgentChatPane restores original renderComposer with MessageComposerInput, MessageComposerActions, AtMentionPopup, context chips, runtime modal, and attachment tray (ORIGINAL_REQUEST L71-72)', () => {
    const chatPanePath = path.join(REPO_ROOT, 'src/ui/components/workbench/AgentChatPane.tsx');
    const source = fs.readFileSync(chatPanePath, 'utf8');

    const requiredComposerComponents = [
      'MessageComposerInput',
      'MessageComposerActions',
      'AtMentionPopup',
      'RuntimeConfigurationOptions',
      'InstanceReconfigurationProgress',
    ];

    for (const comp of requiredComposerComponents) {
      assert.ok(
        source.includes(comp),
        `AgentChatPane.tsx must use "${comp}" in composer per ORIGINAL_REQUEST.md L71-72`,
      );
    }

    const requiredComposerDebugIds = [
      'conversation-composer-card',
      'conversation-composer-context',
      'conversation-composer-bridge-chip',
      'conversation-composer-project-chip',
      'conversation-runtime-status-chip',
      'conversation-runtime-status-toggle-btn',
      'conversation-attachment-tray',
      'conversation-attachment-retry-',
      'conversation-attachment-remove-',
      'conversation-attachment-progress-',
      'conversation-runtime-modal',
    ];

    for (const dbgId of requiredComposerDebugIds) {
      assert.ok(
        source.includes(dbgId),
        `AgentChatPane.tsx must include composer data-debug-id "${dbgId}" per ORIGINAL_REQUEST.md L72-74`,
      );
    }
  });

  test('adv_f2_04: AgentChatPane wires MessageComposerActions onPaneToggle to handleOpenPtyTab (agentPty workbench tab), wires project chip to files workbench tab, and has ZERO inline <AgentPaneComposerPanel mounting (ORIGINAL_REQUEST L72-73 & R4)', () => {
    const chatPanePath = path.join(REPO_ROOT, 'src/ui/components/workbench/AgentChatPane.tsx');
    const source = fs.readFileSync(chatPanePath, 'utf8');

    // 1. Zero inline AgentPaneComposerPanel mounting
    assert.ok(
      !source.includes('<AgentPaneComposerPanel'),
      'AgentChatPane.tsx must NEVER mount <AgentPaneComposerPanel inline inside the composer card',
    );
    assert.ok(
      !source.includes("from '../chat/AgentPaneComposerPanel'") &&
        !source.includes('from "./AgentPaneComposerPanel"'),
      'AgentChatPane.tsx must not import AgentPaneComposerPanel',
    );

    // 2. onPaneToggle wired to open/focus agentPty tab (handleOpenPtyTab)
    assert.ok(
      source.includes('onPaneToggle') && source.includes('handleOpenPtyTab'),
      'AgentChatPane.tsx must wire onPaneToggle on MessageComposerActions to handleOpenPtyTab',
    );

    // 3. Project chip wired to open files workbench tab via handleOpenSurface('files', ...)
    assert.ok(
      source.includes('conversation-composer-project-chip') &&
        source.includes("handleOpenSurface('files'"),
      "AgentChatPane.tsx project chip must open the 'files' workbench tab via handleOpenSurface('files', ...)",
    );
  });

  test('adv_f2_05: MessageComposerActions in JSDOM invokes onPaneToggle (opening agentPty workbench tab), onSettings, and onUpload when toolbar buttons are clicked', async () => {
    const { JSDOM } = await import('jsdom');
    const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>');
    (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).attachEvent = () => {};
    (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).detachEvent = () => {};
    const prevWin = (globalThis as any).window;
    const prevDoc = (globalThis as any).document;
    const prevElem = (globalThis as any).HTMLElement;
    (globalThis as any).window = dom.window;
    (globalThis as any).document = dom.window.document;
    (globalThis as any).HTMLElement = dom.window.HTMLElement;
    (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { MessageComposerActions } = await import('../../src/ui/components/chat/MessageComposer.tsx');

    let root: ReturnType<typeof createRoot> | null = null;
    try {
      const container = dom.window.document.getElementById('root')!;
      root = createRoot(container);

      let paneToggleCalls = 0;
      let settingsCalls = 0;
      let uploadCalls = 0;

      await act(async () => {
        root!.render(
          React.createElement(MessageComposerActions, {
            debugPrefix: 'conversation',
            mobile: false,
            provider: 'gemini',
            model: 'normal',
            onSettings: () => {
              settingsCalls += 1;
            },
            onUpload: () => {
              uploadCalls += 1;
            },
            onPaneToggle: () => {
              paneToggleCalls += 1;
            },
            paneExpanded: false,
            sendDisabled: false,
          }),
        );
      });

      const paneBtn = container.querySelector(
        '[data-debug-id="conversation-request-pane-btn"]',
      ) as HTMLButtonElement | null;
      const attachBtn = container.querySelector(
        '[data-debug-id="conversation-attach-btn"]',
      ) as HTMLButtonElement | null;
      const runtimeBtn = container.querySelector(
        '[data-debug-id="conversation-runtime-menu-btn"]',
      ) as HTMLButtonElement | null;

      assert.ok(paneBtn, 'Desktop MessageComposerActions must render conversation-request-pane-btn');
      assert.ok(attachBtn, 'Desktop MessageComposerActions must render conversation-attach-btn');
      assert.ok(runtimeBtn, 'Desktop MessageComposerActions must render conversation-runtime-menu-btn');

      await act(async () => {
        paneBtn.click();
        attachBtn.click();
        runtimeBtn.click();
      });

      assert.equal(paneToggleCalls, 1, 'Clicking conversation-request-pane-btn must trigger onPaneToggle');
      assert.equal(uploadCalls, 1, 'Clicking conversation-attach-btn must trigger onUpload');
      assert.equal(settingsCalls, 1, 'Clicking conversation-runtime-menu-btn must trigger onSettings');
    } finally {
      if (root) {
        await act(async () => {
          root!.unmount();
        });
      }
      dom.window.close();
      (globalThis as any).window = prevWin;
      (globalThis as any).document = prevDoc;
      (globalThis as any).HTMLElement = prevElem;
    }
  });

  test('adv_f2_06: WorkbenchPaneView SSR renders NEW_TAB_ID launcher alongside hidden existing tabs and renders 4-quadrant drop overlay when pendingDropDirection is set', async () => {
    const { renderToStaticMarkup } = await import('react-dom/server');
    const { Provider } = await import('react-redux');
    const { makeVaultStore } = await import('../helpers/vaultEndpointHarness.ts');
    const { WorkbenchPaneView } = await import('../../src/ui/components/workbench/WorkbenchPaneView.tsx');
    const {
      default: workbenchReducer,
      ensureWorkspaceInitialized,
      openNewTabView,
    } = await import('../../src/ui/store/workbenchSlice.ts');

    const store = await makeVaultStore();
    let wbState = workbenchReducer(
      undefined,
      ensureWorkspaceInitialized({
        workspaceKey: 'ws-adv-paneview',
        defaultAgentInstanceId: 'inst-coord',
        defaultTitle: 'Coordinator',
      }),
    );
    wbState = workbenchReducer(
      wbState,
      openNewTabView({ workspaceKey: 'ws-adv-paneview', paneId: 'pane-1' }),
    );
    const pane1State = (wbState.workspaces['ws-adv-paneview'].tree.panes['pane-1'] as any).value;

    for (const dir of ['left', 'right', 'top', 'bottom'] as const) {
      const html = renderToStaticMarkup(
        React.createElement(
          Provider,
          { store },
          React.createElement(WorkbenchPaneView, {
            paneId: 'pane-1',
            pane: pane1State,
            workspaceKey: 'ws-adv-paneview',
            primaryAgentInstanceId: 'inst-coord',
            chainId: 'chain-1',
            projectId: 'proj-1',
            isFocused: true,
            isMaximized: false,
            isSinglePane: false,
            pendingDropDirection: dir,
            onFocusPane: () => {},
            onSelectTab: () => {},
            onCloseTab: () => {},
            onOpenNewTab: () => {},
            onReplaceNewTab: () => {},
            onOpenOrFocusTab: () => {},
            onUpdateTabParams: () => {},
            onSplitPane: () => {},
            onToggleMaximize: () => {},
            onClosePane: () => {},
          }),
        ),
      );

      // 1. Existing agentChat tab panel remains mounted with class="hidden" and aria-hidden="true"
      assert.ok(
        html.includes('data-debug-id="workbench-tab-panel-agentChat__inst-coord"') &&
          html.includes('aria-hidden="true"') &&
          html.includes('class="hidden"'),
        'Existing tab panel must remain mounted with class="hidden" when NEW_TAB_ID is active',
      );
      // 2. NEW_TAB_ID panel and launcher are mounted and visible
      assert.ok(
        html.includes('data-debug-id="workbench-tab-panel-newTab__empty"'),
        'NEW_TAB_ID tab panel must render when activeTabId === NEW_TAB_ID',
      );
      assert.ok(
        html.includes('data-debug-id="workbench-new-tab-launcher-pane-1"'),
        'WorkbenchNewTabLauncher must render inside pane-1',
      );
      // 3. New Tab pill and close button render in tab strip because tabs.length > 0
      assert.ok(
        html.includes('data-debug-id="workbench-tab-newTab__empty"'),
        'New Tab pill must render in WorkbenchTabStrip',
      );
      assert.ok(
        html.includes('data-debug-id="workbench-tab-close-newTab__empty"'),
        'New Tab pill must be closable when existing tabs are present in the pane',
      );
      // 4. Drop quadrant overlay renders for pendingDropDirection
      assert.ok(
        html.includes('data-debug-id="workbench-pane-drop-overlay-pane-1"'),
        `Drop overlay must render for direction=${dir}`,
      );
    }
  });

  test('adv_f2_07: WorkbenchTabStrip in JSDOM dispatches tab select, middle-click close, close button stopPropagation, + button, 4 split directions, maximize, and pane close', async () => {
    const { JSDOM } = await import('jsdom');
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { WorkbenchTabStrip } = await import('../../src/ui/components/workbench/WorkbenchTabStrip.tsx');

    const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>');
    (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).attachEvent = () => {};
    (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).detachEvent = () => {};
    const prevWin = (globalThis as any).window;
    const prevDoc = (globalThis as any).document;
    const prevElem = (globalThis as any).HTMLElement;
    (globalThis as any).window = dom.window;
    (globalThis as any).document = dom.window.document;
    (globalThis as any).HTMLElement = dom.window.HTMLElement;
    (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

    let root: ReturnType<typeof createRoot> | null = null;
    try {
      const container = dom.window.document.getElementById('root')!;
      root = createRoot(container);

      const selectedTabs: string[] = [];
      const closedTabs: string[] = [];
      const splitDirs: string[] = [];
      let newTabClicks = 0;
      let maximizeClicks = 0;
      let closePaneClicks = 0;

      const tabs = [
        { id: 'agentChat__inst-1', kind: 'agentChat' as const, title: 'Coord Chat', agentInstanceId: 'inst-1' },
        { id: 'files', kind: 'files' as const, title: 'Project Files' },
      ];

      await act(async () => {
        root!.render(
          React.createElement(WorkbenchTabStrip, {
            paneId: 'pane-strip-1',
            tabs,
            activeTabId: 'agentChat__inst-1',
            isFocused: true,
            isMaximized: false,
            isSinglePane: false,
            onSelectTab: (id) => selectedTabs.push(id),
            onCloseTab: (id) => closedTabs.push(id),
            onOpenNewTab: () => {
              newTabClicks += 1;
            },
            onSplitPane: (dir) => splitDirs.push(dir),
            onToggleMaximize: () => {
              maximizeClicks += 1;
            },
            onClosePane: () => {
              closePaneClicks += 1;
            },
          }),
        );
      });

      // Click second tab -> selects 'files'
      const filesTabEl = container.querySelector('[data-debug-id="workbench-tab-files"]') as HTMLElement;
      await act(async () => {
        filesTabEl.click();
      });
      assert.deepEqual(selectedTabs, ['files']);

      // Click close button on 'files' tab -> calls onCloseTab('files') WITHOUT calling onSelectTab again
      const closeFilesBtn = container.querySelector(
        '[data-debug-id="workbench-tab-close-files"]',
      ) as HTMLButtonElement;
      await act(async () => {
        closeFilesBtn.click();
      });
      assert.deepEqual(closedTabs, ['files']);
      assert.equal(selectedTabs.length, 1, 'Close button click must stopPropagation so onSelectTab is not called');

      // Middle-click (button === 1) on 'agentChat__inst-1' -> closes tab
      const chatTabEl = container.querySelector(
        '[data-debug-id="workbench-tab-agentChat__inst-1"]',
      ) as HTMLElement;
      await act(async () => {
        chatTabEl.dispatchEvent(new dom.window.MouseEvent('mousedown', { button: 1, bubbles: true }));
      });
      assert.deepEqual(closedTabs, ['files', 'agentChat__inst-1']);

      // Click + button, 4 split buttons, maximize button, and close pane button
      await act(async () => {
        (container.querySelector('[data-debug-id="workbench-pane-new-tab-btn-pane-strip-1"]') as HTMLElement).click();
        (container.querySelector('[data-debug-id="workbench-pane-split-right-pane-strip-1"]') as HTMLElement).click();
        (container.querySelector('[data-debug-id="workbench-pane-split-bottom-pane-strip-1"]') as HTMLElement).click();
        (container.querySelector('[data-debug-id="workbench-pane-split-left-pane-strip-1"]') as HTMLElement).click();
        (container.querySelector('[data-debug-id="workbench-pane-split-top-pane-strip-1"]') as HTMLElement).click();
        (container.querySelector('[data-debug-id="workbench-pane-maximize-pane-strip-1"]') as HTMLElement).click();
        (container.querySelector('[data-debug-id="workbench-pane-close-pane-strip-1"]') as HTMLElement).click();
      });

      assert.equal(newTabClicks, 1);
      assert.deepEqual(splitDirs, ['right', 'bottom', 'left', 'top']);
      assert.equal(maximizeClicks, 1);
      assert.equal(closePaneClicks, 1);
    } finally {
      if (root) {
        await act(async () => {
          root!.unmount();
        });
      }
      dom.window.close();
      (globalThis as any).window = prevWin;
      (globalThis as any).document = prevDoc;
      (globalThis as any).HTMLElement = prevElem;
    }
  });

  test('adv_f2_08: WorkbenchNewTabLauncher in JSDOM renders all 8 surface cards, respects chainId/projectId disabled guards, and dispatches onSelectSurface for each surface kind', async () => {
    const { JSDOM } = await import('jsdom');
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { configureStore } = await import('@reduxjs/toolkit');
    const { WorkbenchNewTabLauncher } = await import(
      '../../src/ui/components/workbench/WorkbenchNewTabLauncher.tsx'
    );

    const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>');
    (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).attachEvent = () => {};
    (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).detachEvent = () => {};
    const prevWin = (globalThis as any).window;
    const prevDoc = (globalThis as any).document;
    const prevElem = (globalThis as any).HTMLElement;
    (globalThis as any).window = dom.window;
    (globalThis as any).document = dom.window.document;
    (globalThis as any).HTMLElement = dom.window.HTMLElement;
    (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

    let root: ReturnType<typeof createRoot> | null = null;
    try {
      const container = dom.window.document.getElementById('root')!;
      root = createRoot(container);
      // Lightweight store without heimdallApi so WorkbenchNewTabLauncher renders pure body
      const lightStore = configureStore({ reducer: { dummy: (s = {}) => s } });

      const launched: Array<{ kind: string; agentInstanceId?: string; sessionId?: string }> = [];

      // 1. Render with chainId and projectId present -> all 8 cards enabled
      await act(async () => {
        root!.render(
          React.createElement(
            Provider,
            { store: lightStore },
            React.createElement(WorkbenchNewTabLauncher, {
              paneId: 'pane-launch-1',
              primaryAgentInstanceId: 'inst-primary',
              chainId: 'chain-1',
              projectId: 'proj-1',
              onSelectSurface: (tab) => launched.push(tab),
            }),
          ),
        );
      });

      const allKinds = [
        'agentChat',
        'agentPty',
        'shell',
        'preview',
        'files',
        'vcs',
        'chainOverview',
        'tasks',
      ];
      for (const kind of allKinds) {
        const card = container.querySelector(
          `[data-debug-id="workbench-launcher-card-${kind}"]`,
        ) as HTMLButtonElement | null;
        assert.ok(card, `Launcher card for ${kind} must render`);
        assert.equal(card.disabled, false, `Launcher card for ${kind} must be enabled when chainId & projectId exist`);
        await act(async () => {
          card.click();
        });
      }

      assert.deepEqual(
        launched.map((l) => l.kind),
        allKinds,
        'Clicking all 8 launcher cards must dispatch onSelectSurface for each kind in order',
      );
      assert.equal(launched[0].agentInstanceId, 'inst-primary');
      assert.equal(launched[1].agentInstanceId, 'inst-primary');

      // 2. Render without chainId -> chainOverview and tasks cards must be disabled
      await act(async () => {
        root!.render(
          React.createElement(
            Provider,
            { store: lightStore },
            React.createElement(WorkbenchNewTabLauncher, {
              paneId: 'pane-launch-1',
              primaryAgentInstanceId: 'inst-primary',
              chainId: undefined,
              projectId: 'proj-1',
              onSelectSurface: () => {},
            }),
          ),
        );
      });

      const chainCard = container.querySelector(
        '[data-debug-id="workbench-launcher-card-chainOverview"]',
      ) as HTMLButtonElement;
      const tasksCard = container.querySelector(
        '[data-debug-id="workbench-launcher-card-tasks"]',
      ) as HTMLButtonElement;
      assert.equal(chainCard.disabled, true, 'chainOverview card must be disabled when chainId is absent');
      assert.equal(tasksCard.disabled, true, 'tasks card must be disabled when chainId is absent');
    } finally {
      if (root) {
        await act(async () => {
          root!.unmount();
        });
      }
      dom.window.close();
      (globalThis as any).window = prevWin;
      (globalThis as any).document = prevDoc;
      (globalThis as any).HTMLElement = prevElem;
    }
  });

  test('adv_f2_09: AgentPtyWorkbenchPane renders workbench-agent-pty-selector with chain members, dispatches onSelectAgentInstance on change, and wires workbench-agent-pty-open-chat cross-link', async () => {
    const { renderToStaticMarkup } = await import('react-dom/server');
    const { Provider } = await import('react-redux');
    const { makeVaultStore } = await import('../helpers/vaultEndpointHarness.ts');
    const { AgentPtyWorkbenchPane } = await import(
      '../../src/ui/components/workbench/AgentPtyWorkbenchPane.tsx'
    );

    const store = await makeVaultStore();
    const html = renderToStaticMarkup(
      React.createElement(
        Provider,
        { store },
        React.createElement(AgentPtyWorkbenchPane, {
          agentInstanceId: 'inst-coord',
          title: 'Coordinator PTY',
          workspaceKey: 'ws-pty-test',
          paneId: 'pane-pty-1',
          chainId: 'chain-1',
          projectId: 'proj-1',
          members: [
            { agentInstanceId: 'inst-coord', displayName: 'Coordinator', role: 'coordinator' },
            { agentInstanceId: 'inst-worker-1', displayName: 'Worker 1', role: 'worker' },
            { agentInstanceId: 'inst-worker-2', displayName: 'Worker 2', role: 'critic' },
          ],
          isActiveTab: true,
        }),
      ),
    );

    assert.ok(
      html.includes('data-debug-id="workbench-agent-pty-pane-inst-coord"'),
      'AgentPtyWorkbenchPane container debug ID must render',
    );
    assert.ok(
      html.includes('data-debug-id="workbench-agent-pty-selector"'),
      'AgentPtyWorkbenchPane must render workbench-agent-pty-selector <select>',
    );
    assert.ok(
      html.includes('value="inst-coord"') &&
        html.includes('value="inst-worker-1"') &&
        html.includes('value="inst-worker-2"'),
      'workbench-agent-pty-selector must include options for Coordinator, Worker 1, and Worker 2',
    );
    assert.ok(
      html.includes('Worker 1 (worker)') && html.includes('Worker 2 (critic)'),
      'workbench-agent-pty-selector options must format member label and role',
    );
    assert.ok(
      html.includes('data-debug-id="workbench-agent-pty-open-chat"'),
      'AgentPtyWorkbenchPane must render workbench-agent-pty-open-chat cross-link button',
    );
  });

  test('adv_f2_10: PreviewWorkbenchPane normalizePreviewSubpath, buildWorkbenchPreviewUrl, and JSDOM Preview/Stdout toggle keeping iframe mounted with hidden class', async () => {
    const { JSDOM } = await import('jsdom');
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { makeVaultStore } = await import('../helpers/vaultEndpointHarness.ts');
    const {
      PreviewWorkbenchPane,
      normalizePreviewSubpath,
    } = await import('../../src/ui/components/workbench/PreviewWorkbenchPane.tsx');
    const { buildWorkbenchPreviewUrl } = await import('../../src/ui/store/workbenchTabId.ts');

    // 1. Unit test normalizePreviewSubpath and buildWorkbenchPreviewUrl edge cases
    assert.equal(normalizePreviewSubpath(''), '/');
    assert.equal(normalizePreviewSubpath('   '), '/');
    assert.equal(normalizePreviewSubpath('/'), '/');
    assert.equal(normalizePreviewSubpath('dashboard/settings'), '/dashboard/settings');
    assert.equal(normalizePreviewSubpath('/api/v1/health?x=1'), '/api/v1/health?x=1');
    assert.equal(
      buildWorkbenchPreviewUrl('sess-123', '/app/home'),
      '/api/v1/preview/sess-123/app/home',
    );

    // 2. JSDOM interactive test for Preview/Stdout toggle and subpath navigation
    const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>');
    (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).attachEvent = () => {};
    (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).detachEvent = () => {};
    (dom.window.Document.prototype as unknown as Record<string, unknown>).attachEvent = () => {};
    (dom.window.Document.prototype as unknown as Record<string, unknown>).detachEvent = () => {};
    (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).scrollIntoView = () => {};
    const prevWin = (globalThis as any).window;
    const prevDoc = (globalThis as any).document;
    const prevElem = (globalThis as any).HTMLElement;
    (globalThis as any).window = dom.window;
    (globalThis as any).document = dom.window.document;
    (globalThis as any).HTMLElement = dom.window.HTMLElement;
    (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

    let root: ReturnType<typeof createRoot> | null = null;
    const store = await makeVaultStore();
    try {
      const container = dom.window.document.getElementById('root')!;
      root = createRoot(container);

      await act(async () => {
        root!.render(
          React.createElement(
            Provider,
            { store },
            React.createElement(PreviewWorkbenchPane, {
              sessionId: 'srv-5173',
              port: 5173,
              currentPath: '/initial-route',
              label: 'Vite Dev',
            }),
          ),
        );
      });

      const iframeWrapper = container.querySelector(
        '[data-debug-id="workbench-preview-iframe-wrapper"]',
      ) as HTMLElement;
      const iframeEl = container.querySelector(
        '[data-debug-id="workbench-preview-iframe"]',
      ) as HTMLIFrameElement;
      const stdoutTabBtn = container.querySelector(
        '[data-debug-id="workbench-preview-tab-stdout"]',
      ) as HTMLButtonElement;
      const previewTabBtn = container.querySelector(
        '[data-debug-id="workbench-preview-tab-iframe"]',
      ) as HTMLButtonElement;

      assert.ok(iframeWrapper && iframeEl, 'Preview iframe and wrapper must be mounted initially');
      assert.ok(
        !iframeWrapper.className.split(/\s+/).includes('hidden'),
        'Iframe wrapper must be visible when subView === "preview"',
      );
      assert.equal(
        iframeEl.getAttribute('src'),
        '/api/v1/preview/srv-5173/initial-route',
      );
      assert.equal(
        container.querySelector('[data-debug-id="workbench-preview-stdout-wrapper"]'),
        null,
      );

      // Click "Stdout" tab -> iframe stays in DOM with class "hidden", stdout wrapper mounts
      await act(async () => {
        stdoutTabBtn.click();
      });

      assert.ok(
        container.querySelector('[data-debug-id="workbench-preview-iframe"]'),
        'Preview <iframe> must remain mounted in DOM when switched to Stdout view',
      );
      assert.equal(
        iframeWrapper.className,
        'hidden',
        'Iframe wrapper must have class="hidden" when subView === "output"',
      );
      assert.ok(
        container.querySelector('[data-debug-id="workbench-preview-stdout-wrapper"]'),
        'Stdout wrapper must mount when subView === "output"',
      );

      // Click "Preview" tab -> restores iframe visibility and unmounts stdout wrapper
      await act(async () => {
        previewTabBtn.click();
      });
      assert.ok(!iframeWrapper.className.split(/\s+/).includes('hidden'));
      assert.equal(
        container.querySelector('[data-debug-id="workbench-preview-stdout-wrapper"]'),
        null,
      );
    } finally {
      if (root) {
        await act(async () => {
          root!.unmount();
        });
      }
      const { heimdallApi } = await import('../../src/ui/api/heimdallApi.ts');
      store.dispatch(heimdallApi.util.resetApiState());
      dom.window.close();
      (globalThis as any).window = prevWin;
      (globalThis as any).document = prevDoc;
      (globalThis as any).HTMLElement = prevElem;
    }
  });

  test('adv_f2_11: WorkbenchPaneView wires all cross-links (ChainOverviewPanel onSelectTask, onOpenFileDiff, onOpenVcsFiles, onOpenAgentChat, onOpenAgentPty & ProjectVcsPanel onOpenDirectory) to onOpenOrFocusTab without clobbering', () => {
    const paneViewPath = path.join(REPO_ROOT, 'src/ui/components/workbench/WorkbenchPaneView.tsx');
    const source = fs.readFileSync(paneViewPath, 'utf8');

    // Verify ProjectVcsPanel cross-link to files
    assert.ok(
      source.includes('onOpenDirectory') && source.includes("kind: 'files'"),
      'WorkbenchPaneView must wire ProjectVcsPanel onOpenDirectory to open/focus files tab',
    );

    // Verify ChainOverviewPanel cross-links to tasks, vcs, agentChat, and agentPty
    const requiredChainCrossLinks = [
      'onSelectTask',
      'onOpenFileDiff',
      'onOpenVcsFiles',
      'onOpenAgentChat',
      'onOpenAgentPty',
    ];
    for (const propName of requiredChainCrossLinks) {
      assert.ok(
        source.includes(propName),
        `WorkbenchPaneView must wire ChainOverviewPanel cross-link prop "${propName}"`,
      );
    }
  });

  test('adv_f2_12: ConversationWorkbench in JSDOM handles global keyboard shortcuts (Cmd/Ctrl+P -> files Command Palette, Cmd/Ctrl+Shift+F -> files Search, Cmd/Ctrl+\\ -> split right) and ?panel= deep-link hydration', async () => {
    const { JSDOM } = await import('jsdom');
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { configureStore } = await import('@reduxjs/toolkit');
    const { heimdallApi } = await import('../../src/ui/api/heimdallApi.ts');
    const { default: vaultReducer } = await import('../../src/ui/store/vaultSlice.ts');
    const { default: windowLayoutReducer } = await import('../../src/ui/store/windowLayoutSlice.ts');
    const { default: workbenchReducer } = await import('../../src/ui/store/workbenchSlice.ts');
    const { ConversationWorkbench } = await import(
      '../../src/ui/components/workbench/ConversationWorkbench.tsx'
    );
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', {
      url: 'http://127.0.0.1:5173/#/conversations/inst-shortcut',
    });
    (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).attachEvent = () => {};
    (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).detachEvent = () => {};
    (dom.window.Document.prototype as unknown as Record<string, unknown>).attachEvent = () => {};
    (dom.window.Document.prototype as unknown as Record<string, unknown>).detachEvent = () => {};
    (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).scrollIntoView = () => {};
    (dom.window.HTMLElement.prototype as unknown as Record<string, unknown>).focus = () => {};
    const prevWin = (globalThis as any).window;
    const prevDoc = (globalThis as any).document;
    const prevElem = (globalThis as any).HTMLElement;
    const prevLocalStorage = (globalThis as any).localStorage;
    (globalThis as any).window = dom.window;
    (globalThis as any).document = dom.window.document;
    (globalThis as any).HTMLElement = dom.window.HTMLElement;
    (globalThis as any).localStorage = dom.window.localStorage;
    (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

    let root: ReturnType<typeof createRoot> | null = null;
    const dispatchedActions: Array<{ type: string; payload?: any }> = [];
    const store = configureStore({
      reducer: {
        vault: vaultReducer,
        chat: (s: any = { session: { daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test' } }) => s,
        windowLayout: windowLayoutReducer,
        workbench: workbenchReducer,
        [heimdallApi.reducerPath]: heimdallApi.reducer,
      },
      middleware: (g: any) =>
        g({ serializableCheck: false, immutableCheck: false }).concat(
          () => (next: any) => (action: any) => {
            if (action && typeof action.type === 'string') {
              dispatchedActions.push({ type: action.type, payload: action.payload });
            }
            return next(action);
          },
          heimdallApi.middleware,
        ),
    });
    try {
      const container = dom.window.document.getElementById('root')!;
      root = createRoot(container);

      await act(async () => {
        root!.render(
          React.createElement(
            Provider,
            { store },
            React.createElement(ConversationWorkbench, {
              workspaceKey: 'ws-kbd-test',
              primaryAgentInstanceId: 'inst-shortcut',
              primaryAgentTitle: 'Shortcut Agent',
              chainId: 'chain-kbd',
              projectId: 'proj-kbd',
              initialPanelParam: 'vcs',
              initialFilePathParam: 'src/index.ts',
            }),
          ),
        );
      });

      // 1. Verify ?panel=vcs deep-link opened 'vcs' tab with initialFilePath='src/index.ts'
      let wb = (store.getState() as any).workbench.workspaces['ws-kbd-test'];
      assert.ok(wb, 'Workspace ws-kbd-test must be initialized');
      let rootPane = wb.tree.panes[wb.tree.rootPaneId];
      assert.equal(rootPane.kind, 'content');
      const vcsTab = rootPane.value.tabs.find((t: any) => t.kind === 'vcs');
      assert.ok(vcsTab, 'initialPanelParam="vcs" must open vcs tab');
      assert.equal(
        dispatchedActions.some(
          (a) =>
            a.type === 'workbench/openOrFocusWorkbenchTab' &&
            a.payload?.tab?.kind === 'vcs' &&
            a.payload?.tab?.initialFilePath === 'src/index.ts',
        ),
        true,
        'ConversationWorkbench must dispatch openOrFocusWorkbenchTab with kind="vcs" and initialFilePath="src/index.ts"',
      );

      // 2. Dispatch Ctrl+P -> dispatches openOrFocusWorkbenchTab with initialOpenCommandPalette: true (then consumed by ProjectFilesPanel)
      await act(async () => {
        dom.window.dispatchEvent(
          new dom.window.KeyboardEvent('keydown', { key: 'p', ctrlKey: true, bubbles: true }),
        );
      });
      wb = (store.getState() as any).workbench.workspaces['ws-kbd-test'];
      rootPane = wb.tree.panes[wb.tree.rootPaneId];
      const filesTabAfterCtrlP = rootPane.value.tabs.find((t: any) => t.kind === 'files');
      assert.ok(filesTabAfterCtrlP, 'Ctrl+P must open files tab');
      assert.equal(rootPane.value.activeTabId, 'files', 'Ctrl+P must focus files tab');
      assert.equal(
        dispatchedActions.some(
          (a) =>
            a.type === 'workbench/openOrFocusWorkbenchTab' &&
            a.payload?.tab?.kind === 'files' &&
            a.payload?.tab?.initialOpenCommandPalette === true,
        ),
        true,
        'Ctrl+P must dispatch openOrFocusWorkbenchTab for files with initialOpenCommandPalette: true',
      );

      // 3. Dispatch Ctrl+Shift+F -> dispatches openOrFocusWorkbenchTab with initialOpenSearchInFiles: true (then consumed by ProjectFilesPanel)
      await act(async () => {
        dom.window.dispatchEvent(
          new dom.window.KeyboardEvent('keydown', {
            key: 'F',
            ctrlKey: true,
            shiftKey: true,
            bubbles: true,
          }),
        );
      });
      wb = (store.getState() as any).workbench.workspaces['ws-kbd-test'];
      rootPane = wb.tree.panes[wb.tree.rootPaneId];
      const filesTabAfterSearch = rootPane.value.tabs.find((t: any) => t.kind === 'files');
      assert.ok(filesTabAfterSearch, 'Ctrl+Shift+F must keep files tab open');
      assert.equal(
        dispatchedActions.some(
          (a) =>
            a.type === 'workbench/openOrFocusWorkbenchTab' &&
            a.payload?.tab?.kind === 'files' &&
            a.payload?.tab?.initialOpenSearchInFiles === true,
        ),
        true,
        'Ctrl+Shift+F must dispatch openOrFocusWorkbenchTab for files with initialOpenSearchInFiles: true',
      );

      // 4. Dispatch Ctrl+\ -> splits focused pane right
      await act(async () => {
        dom.window.dispatchEvent(
          new dom.window.KeyboardEvent('keydown', { key: '\\', ctrlKey: true, bubbles: true }),
        );
      });
      wb = (store.getState() as any).workbench.workspaces['ws-kbd-test'];
      assert.equal(
        getContentPaneIds(wb.tree).length,
        2,
        'Ctrl+\\ must split the focused workbench pane to the right',
      );
    } finally {
      if (root) {
        await act(async () => {
          root!.unmount();
        });
      }
      store.dispatch(heimdallApi.util.resetApiState());
      dom.window.close();
      (globalThis as any).window = prevWin;
      (globalThis as any).document = prevDoc;
      (globalThis as any).HTMLElement = prevElem;
      (globalThis as any).localStorage = prevLocalStorage;
    }
  });

  test('adv_f2_13: AgentChatPane header (<Project>/<Task chain>/<agent>), ⋮ menu with supported actions & split controls (and zero unsupported items), [≡] button, and floating Chain Overview popup (ORIGINAL_REQUEST L88-126)', () => {
    const chatPanePath = path.join(REPO_ROOT, 'src/ui/components/workbench/AgentChatPane.tsx');
    const source = fs.readFileSync(chatPanePath, 'utf8');

    // 1. Header breadcrumb & switchers
    const requiredHeaderDebugIds = [
      'conversation-thread-header',
      'conversation-thread-breadcrumb',
      'conversation-breadcrumb-project',
      'conversation-thread-title',
      'conversation-chain-agent-switcher-btn',
      'conversation-chain-agent-modal',
      'TaskChainSelectorModal',
      'conversation-thread-vault-pill',
      'conversation-thread-overflow-menu-btn',
      'conversation-right-panel-toggle-btn',
    ];
    for (const id of requiredHeaderDebugIds) {
      assert.ok(
        source.includes(id),
        `AgentChatPane.tsx must include header switcher / debug ID "${id}"`,
      );
    }

    // 2. Vertical 3-dots menu (more-vertical) and supported items + Split controls
    assert.ok(
      source.includes('name="more-vertical"'),
      'AgentChatPane.tsx overflow menu button must render <Icon name="more-vertical" />',
    );
    const requiredMenuDebugIds = [
      'conversation-thread-rename-action',
      'conversation-thread-refresh-btn',
      'conversation-thread-settings-action',
      'conversation-split-right-action',
      'conversation-split-down-action',
      'conversation-split-left-action',
      'conversation-split-up-action',
      'conversation-replace-with-new-action',
      'conversation-remove-from-split-action',
      'conversation-thread-overflow-details',
    ];
    for (const id of requiredMenuDebugIds) {
      assert.ok(
        source.includes(id),
        `AgentChatPane.tsx ⋮ menu must include supported item "${id}"`,
      );
    }

    // 3. Absence of unsupported Jetski menu items
    const unsupportedMenuLabels = [
      'Trajectory Debug View',
      'Telemetry',
      'Code Search',
      'Extensions',
    ];
    for (const badLabel of unsupportedMenuLabels) {
      assert.ok(
        !source.includes(badLabel),
        `AgentChatPane.tsx ⋮ menu must NOT include unsupported item "${badLabel}"`,
      );
    }

    // 4. Floating Chain Overview Popup & Quick Rows + ChainOverviewPanel
    const requiredPopupDebugIds = [
      'workbench-chain-overview-popup-backdrop',
      'workbench-chain-overview-popup',
      'workbench-chain-overview-quick-actions',
      'workbench-chain-overview-popup-close-btn',
      'overview-popup-row-files',
      'overview-popup-row-vcs',
      'overview-popup-row-tasks',
      'overview-popup-row-shell',
      'overview-popup-row-agent-pty',
      'overview-popup-row-preview',
      '<ChainOverviewPanel',
    ];
    for (const id of requiredPopupDebugIds) {
      assert.ok(
        source.includes(id),
        `AgentChatPane.tsx floating Chain Overview popup must include "${id}"`,
      );
    }
  });

  test('adv_f2_14: 3-Step Right-Split Routing (handleOpenInRightSplit / openInRightSplitForAgent) splits right when chat pane is sole pane and reuses secondary pane for subsequent surfaces without clobbering chat pane', async () => {
    const {
      default: workbenchReducer,
      ensureWorkspaceInitialized,
      openOrFocusWorkbenchTab,
    } = await import('../../src/ui/store/workbenchSlice.ts');
    const { buildWorkbenchTabId } = await import('../../src/ui/store/workbenchTabId.ts');
    const { getContentPaneIds } = await import('../../src/ui/tiling/paneTreeState.ts');

    // Helper mirroring the exact 3-step routing algorithm in ConversationWorkbench & AgentChatPane
    const routeFromChatPane = (
      wbState: any,
      workspaceKey: string,
      sourcePaneId: string,
      tab: any,
    ) => {
      const tree = wbState.workspaces[workspaceKey]?.tree;
      const targetTabId = buildWorkbenchTabId(tab);

      if (tree) {
        const contentIds = getContentPaneIds(tree);
        // Step 1: Existing tab in any pane
        for (const candidatePaneId of contentIds) {
          const candidatePane = tree.panes[candidatePaneId];
          if (
            candidatePane &&
            candidatePane.kind === 'content' &&
            candidatePane.value.tabs.some((t: any) => t.id === targetTabId)
          ) {
            return workbenchReducer(
              wbState,
              openOrFocusWorkbenchTab({
                workspaceKey,
                paneId: candidatePaneId,
                tab,
              }),
            );
          }
        }

        // Step 2: Existing secondary pane (id !== sourcePaneId)
        const secondaryPaneId = contentIds.find((id: string) => id !== sourcePaneId);
        if (secondaryPaneId) {
          return workbenchReducer(
            wbState,
            openOrFocusWorkbenchTab({
              workspaceKey,
              paneId: secondaryPaneId,
              tab,
            }),
          );
        }
      }

      // Step 3: Sole chat pane -> split right
      return workbenchReducer(
        wbState,
        openOrFocusWorkbenchTab({
          workspaceKey,
          paneId: sourcePaneId,
          tab,
          splitDirection: 'right',
        }),
      );
    };

    const wsKey = 'ws-right-split-routing';
    let state = workbenchReducer(
      undefined,
      ensureWorkspaceInitialized({
        workspaceKey: wsKey,
        defaultAgentInstanceId: 'inst-coord',
        defaultTitle: 'Coordinator',
      }),
    );

    // Initially only 1 pane ('pane-1') with agentChat__inst-coord
    assert.deepEqual(getContentPaneIds(state.workspaces[wsKey].tree), ['pane-1']);

    // 1. Open 'files' from chat pane ('pane-1') -> Step 3 splits right to create 'pane-2'
    state = routeFromChatPane(state, wsKey, 'pane-1', {
      kind: 'files',
      title: 'Project Files',
    });
    const contentIdsAfterFirst = getContentPaneIds(state.workspaces[wsKey].tree);
    assert.equal(contentIdsAfterFirst.length, 2, 'Opening files from sole chat pane must split right into 2 panes');
    const rightPaneId = contentIdsAfterFirst.find((id) => id !== 'pane-1')!;
    assert.ok(rightPaneId, 'Right split pane must exist');

    // Verify pane-1 still has ONLY agentChat__inst-coord active (never clobbered)
    const pane1 = (state.workspaces[wsKey].tree.panes['pane-1'] as any).value;
    assert.equal(pane1.tabs.length, 1);
    assert.equal(pane1.tabs[0].id, 'agentChat__inst-coord');
    assert.equal(pane1.activeTabId, 'agentChat__inst-coord');

    // Verify right pane has 'files' active
    let rightPane = (state.workspaces[wsKey].tree.panes[rightPaneId] as any).value;
    assert.equal(rightPane.activeTabId, 'files');

    // 2. Open 'agentPty', 'vcs', 'tasks', 'shell', 'preview' from chat pane -> Step 2 opens in rightPaneId without creating a 3rd pane
    for (const surface of [
      { kind: 'agentPty', agentInstanceId: 'inst-coord', title: 'Coordinator PTY' },
      { kind: 'vcs', title: 'VCS / Diff' },
      { kind: 'tasks', title: 'Tasks', focusTaskId: 'task-42' },
      { kind: 'shell', title: 'Interactive Shell' },
      { kind: 'preview', sessionId: 'default', title: 'Web Preview' },
    ]) {
      state = routeFromChatPane(state, wsKey, 'pane-1', surface);
      assert.equal(
        getContentPaneIds(state.workspaces[wsKey].tree).length,
        2,
        `Opening ${surface.kind} when right split exists must reuse right split without creating a 3rd pane`,
      );
    }

    rightPane = (state.workspaces[wsKey].tree.panes[rightPaneId] as any).value;
    assert.deepEqual(
      rightPane.tabs.map((t: any) => t.kind),
      ['files', 'agentPty', 'vcs', 'tasks', 'shell', 'preview'],
    );
    assert.equal(rightPane.activeTabId, 'preview__default');

    // 3. Re-opening 'files' with openFilePath -> Step 1 focuses existing 'files' tab in rightPaneId and updates params
    state = routeFromChatPane(state, wsKey, 'pane-1', {
      kind: 'files',
      title: 'Project Files',
      openFilePath: 'src/App.tsx',
    });
    rightPane = (state.workspaces[wsKey].tree.panes[rightPaneId] as any).value;
    assert.equal(rightPane.activeTabId, 'files');
    assert.equal(
      rightPane.tabs.find((t: any) => t.id === 'files')?.openFilePath,
      'src/App.tsx',
    );
  });

  test('adv_f2_15: WorkbenchPaneView hides tab strip wrapper (className="hidden") when pane has only 1 agentChat tab and shows it (className="shrink-0") when a 2nd tab is added or NEW_TAB_ID is active', async () => {
    const { renderToStaticMarkup } = await import('react-dom/server');
    const { Provider } = await import('react-redux');
    const { makeVaultStore } = await import('../helpers/vaultEndpointHarness.ts');
    const { WorkbenchPaneView } = await import('../../src/ui/components/workbench/WorkbenchPaneView.tsx');
    const { NEW_TAB_ID } = await import('../../src/ui/store/workbenchTabId.ts');

    const store = await makeVaultStore();

    // Case 1: Single agentChat tab -> wrapper has class="hidden"
    const singleChatHtml = renderToStaticMarkup(
      React.createElement(
        Provider,
        { store },
        React.createElement(WorkbenchPaneView, {
          paneId: 'pane-clean-1',
          pane: {
            tabs: [{ id: 'agentChat__inst-1', kind: 'agentChat', title: 'Chat', agentInstanceId: 'inst-1' }],
            activeTabId: 'agentChat__inst-1',
          },
          workspaceKey: 'ws-clean',
          primaryAgentInstanceId: 'inst-1',
          isFocused: true,
          isMaximized: false,
          isSinglePane: true,
          onFocusPane: () => {},
          onSelectTab: () => {},
          onCloseTab: () => {},
          onOpenNewTab: () => {},
          onReplaceNewTab: () => {},
          onOpenOrFocusTab: () => {},
          onUpdateTabParams: () => {},
          onSplitPane: () => {},
          onToggleMaximize: () => {},
          onClosePane: () => {},
        }),
      ),
    );
    assert.ok(
      singleChatHtml.includes('data-debug-id="workbench-pane-tabstrip-wrapper-pane-clean-1" class="hidden"'),
      'Single agentChat tab pane must hide workbench-pane-tabstrip-wrapper with class="hidden"',
    );

    // Case 2: 2 tabs in pane -> wrapper has class="shrink-0"
    const twoTabHtml = renderToStaticMarkup(
      React.createElement(
        Provider,
        { store },
        React.createElement(WorkbenchPaneView, {
          paneId: 'pane-clean-1',
          pane: {
            tabs: [
              { id: 'agentChat__inst-1', kind: 'agentChat', title: 'Chat', agentInstanceId: 'inst-1' },
              { id: 'files', kind: 'files', title: 'Files' },
            ],
            activeTabId: 'files',
          },
          workspaceKey: 'ws-clean',
          primaryAgentInstanceId: 'inst-1',
          isFocused: true,
          isMaximized: false,
          isSinglePane: true,
          onFocusPane: () => {},
          onSelectTab: () => {},
          onCloseTab: () => {},
          onOpenNewTab: () => {},
          onReplaceNewTab: () => {},
          onOpenOrFocusTab: () => {},
          onUpdateTabParams: () => {},
          onSplitPane: () => {},
          onToggleMaximize: () => {},
          onClosePane: () => {},
        }),
      ),
    );
    assert.ok(
      twoTabHtml.includes('data-debug-id="workbench-pane-tabstrip-wrapper-pane-clean-1" class="shrink-0"'),
      'Multi-tab pane must show workbench-pane-tabstrip-wrapper with class="shrink-0"',
    );

    // Case 3: Single agentChat tab but activeTabId === NEW_TAB_ID -> wrapper has class="shrink-0"
    const launcherActiveHtml = renderToStaticMarkup(
      React.createElement(
        Provider,
        { store },
        React.createElement(WorkbenchPaneView, {
          paneId: 'pane-clean-1',
          pane: {
            tabs: [{ id: 'agentChat__inst-1', kind: 'agentChat', title: 'Chat', agentInstanceId: 'inst-1' }],
            activeTabId: NEW_TAB_ID,
          },
          workspaceKey: 'ws-clean',
          primaryAgentInstanceId: 'inst-1',
          isFocused: true,
          isMaximized: false,
          isSinglePane: true,
          onFocusPane: () => {},
          onSelectTab: () => {},
          onCloseTab: () => {},
          onOpenNewTab: () => {},
          onReplaceNewTab: () => {},
          onOpenOrFocusTab: () => {},
          onUpdateTabParams: () => {},
          onSplitPane: () => {},
          onToggleMaximize: () => {},
          onClosePane: () => {},
        }),
      ),
    );
    assert.ok(
      launcherActiveHtml.includes('data-debug-id="workbench-pane-tabstrip-wrapper-pane-clean-1" class="shrink-0"'),
      'Pane with active NEW_TAB_ID launcher must show workbench-pane-tabstrip-wrapper with class="shrink-0"',
    );
  });
});
