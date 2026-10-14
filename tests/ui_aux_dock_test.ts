import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import React from 'react';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

async function withDom<T>(fn: (dom: any) => Promise<T>): Promise<T> {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', {
    url: 'http://localhost/#/conversations/agent-a',
  });
  (dom.window.HTMLElement.prototype as any).scrollTo = () => {};
  (dom.window.HTMLElement.prototype as any).scrollIntoView = () => {};
  const prev = {
    window: (globalThis as any).window,
    document: (globalThis as any).document,
    HTMLElement: (globalThis as any).HTMLElement,
    navigator: (globalThis as any).navigator,
    fetch: (globalThis as any).fetch,
    localStorage: (globalThis as any).localStorage,
  };
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).localStorage = dom.window.localStorage;
  Object.defineProperty(globalThis, 'navigator', { value: dom.window.navigator, configurable: true });
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  (globalThis as any).fetch = async () => {
    const body = { data: {} };
    return {
      ok: true,
      status: 200,
      headers: { get: () => 'application/json' },
      text: async () => JSON.stringify(body),
      json: async () => body,
    } as any;
  };
  try {
    return await fn(dom);
  } finally {
    dom.window.close();
    (globalThis as any).window = prev.window;
    (globalThis as any).document = prev.document;
    (globalThis as any).HTMLElement = prev.HTMLElement;
    (globalThis as any).localStorage = prev.localStorage;
    Object.defineProperty(globalThis, 'navigator', { value: prev.navigator, configurable: true });
    (globalThis as any).fetch = prev.fetch;
  }
}

async function makeStore() {
  const { configureStore } = await import('@reduxjs/toolkit');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { default: vaultReducer } = await import('../src/ui/store/vaultSlice.ts');
  const { default: workspaceLayout } = await import('../src/ui/store/workspaceLayoutSlice.ts');
  const { default: auxPanes } = await import('../src/ui/store/auxPanesSlice.ts');
  const { default: workspaceChrome } = await import('../src/ui/store/workspaceChromeSlice.ts');
  return configureStore({
    reducer: {
      vault: vaultReducer,
      workspaceLayout,
      auxPanes,
      workspaceChrome,
      chat: (s: any = { session: { daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test' } }) => s,
      [heimdallApi.reducerPath]: heimdallApi.reducer,
    },
    middleware: (g: any) => g({ serializableCheck: false, immutableCheck: false }).concat(heimdallApi.middleware),
  });
}

const CTX = {
  agentInstanceId: 'agent-a',
  conversationId: '',
  title: 'A',
  chainId: 'chain-a',
  projectId: 'project-a',
  projectName: 'Proj',
  bridgeId: 'bridge-a',
  defaultCwd: '',
  shellDefaultCwd: undefined,
  shellCwdReady: true,
  projectVcsEnabled: false,
  directories: [],
  members: [],
  participantIds: null,
  isResolved: true,
};

test('aux dock: one strip, only the active tab is mounted, multiple shell tabs, clean tab content, ⋮ actions', async () => {
  await withDom(async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const { openAuxTab, setActiveAuxTab, selectAuxPane } = await import('../src/ui/store/auxPanesSlice.ts');
    const { AuxDock } = await import('../src/ui/components/aux/AuxDock.tsx');

    const store = await makeStore();
    const treeId = { kind: 'agent' as const, agentInstanceId: 'agent-a' };
    store.dispatch(openAuxTab({ treeId, content: { type: 'shell', sessionId: 's-1' }, hasChain: true }));
    store.dispatch(openAuxTab({ treeId, content: { type: 'shell', sessionId: 's-2' } }));
    store.dispatch(openAuxTab({ treeId, content: { type: 'preview', sessionId: 'srv', port: 3000 } }));
    store.dispatch(setActiveAuxTab({ treeId, tabId: 'shell__s-1' }));

    const doc = dom.window.document;
    const root = createRoot(doc.getElementById('root')!);
    const q = (sel: string) => doc.querySelector(sel);
    const qa = (sel: string) => Array.from(doc.querySelectorAll(sel));
    const settle = () => new Promise((r) => setTimeout(r, 30));
    try {
      await act(async () => {
        root.render(
          React.createElement(Provider, { store }, React.createElement(AuxDock, { treeId, ctx: CTX as any })),
        );
        await settle();
      });

      // ONE strip with every tab (seeded overview materialized + 2 shells + preview).
      assert.equal(qa('[data-debug-id^="aux-tab-strip-"]').length, 1);
      for (const id of ['overview', 'shell__s-1', 'shell__s-2', 'preview__srv:3000']) {
        assert.ok(q(`[data-debug-id="aux-tab-${id}"]`), `strip shows ${id}`);
      }
      // No split controls inside the aux.
      assert.equal(qa('[data-debug-id*="split"]').length, 0);

      // Only the active tab is mounted (Jetski keep-alive parity).
      assert.deepEqual(
        qa('[data-debug-id^="aux-tab-panel-"]').map((el: any) => el.getAttribute('data-debug-id')),
        ['aux-tab-panel-shell__s-1'],
      );
      // Clean tab content: no shell toolbar / session switcher.
      assert.equal(q('[data-debug-id="workbench-shell-toolbar"]'), null);
      assert.equal(q('[data-debug-id="workbench-shell-session-select"]'), null);

      await act(async () => {
        (q('[data-debug-id="aux-tab-shell__s-2"]') as any).click();
        await settle();
      });
      assert.deepEqual(
        qa('[data-debug-id^="aux-tab-panel-"]').map((el: any) => el.getAttribute('data-debug-id')),
        ['aux-tab-panel-shell__s-2'],
        'switching tabs unmounts the previous one',
      );

      // ⋮ menu: "New shell" opens ANOTHER shell tab (each tab = one interactive shell).
      await act(async () => {
        (q('[data-debug-id="aux-overflow-menu-btn-agent:agent-a"]') as any).click();
        await settle();
      });
      const newShell = q('[data-debug-id="aux-menu-action-shell-new"]') as any;
      assert.ok(newShell, 'shell tab registers a New shell action');
      assert.ok(q('[data-debug-id="aux-menu-action-close-tab"]'));
      await act(async () => {
        newShell.click();
        await settle();
      });
      const shells = selectAuxPane(store.getState(), treeId)!.tabs.filter((t: any) => t.content.type === 'shell');
      assert.equal(shells.length, 3, 'a third, separate shell tab was opened');

      // Preview tab: iframe only, actions move to ⋮.
      await act(async () => {
        (q('[data-debug-id="aux-tab-preview__srv:3000"]') as any).click();
        await settle();
      });
      assert.ok(q('[data-debug-id="workbench-preview-iframe"]'));
      assert.equal(q('[data-debug-id="workbench-preview-toolbar"]'), null);
      await act(async () => {
        (q('[data-debug-id="aux-overflow-menu-btn-agent:agent-a"]') as any).click();
        await settle();
      });
      for (const id of ['preview-reload', 'preview-copy-url', 'preview-open-external', 'preview-go-to-path']) {
        assert.ok(q(`[data-debug-id="aux-menu-action-${id}"]`), `⋮ has ${id}`);
      }
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('clean aux tabs: surfaces no longer render their own header chrome', () => {
  const read = (p: string) => fs.readFileSync(path.join(REPO_ROOT, p), 'utf8');
  assert.doesNotMatch(read('src/ui/components/workbench/AgentPtyWorkbenchPane.tsx'), /workbench-agent-pty-header|workbench-agent-pty-selector|workbench-agent-pty-open-chat/);
  assert.doesNotMatch(read('src/ui/components/workbench/ShellWorkbenchPane.tsx'), /workbench-shell-toolbar|workbench-shell-session-select|NewShellDialog/);
  assert.doesNotMatch(read('src/ui/components/workbench/PreviewWorkbenchPane.tsx'), /workbench-preview-toolbar/);
  assert.doesNotMatch(read('src/ui/components/chat/ChainOverviewPanel.tsx'), /chain-overview-header-toolbar/);
  const chat = read('src/ui/components/workbench/AgentChatPane.tsx');
  assert.match(chat, /\{!isAuxSubagent \? \(\s*<header/, 'sub-agent chat renders no header');
  assert.match(chat, /projectId && !isAuxSubagent/, 'sub-agent chat renders no project chip');
  assert.doesNotMatch(chat, /workbench-chain-overview-popup/, 'floating overview popup is gone');
  assert.match(read('src/ui/components/aux/AuxTabContent.tsx'), /hideTitleBar=\{true\}/);
});

test('workspace: URL <-> layout sync (pane set in the URL, replace pushes, no loops), split groups, mobile sheet', async () => {
  await withDom(async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { setAuxPaneOpen } = await import('../src/ui/store/auxPanesSlice.ts');
    const { readGroupIndex } = await import('../src/ui/store/splitGroups.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');

    const store = await makeStore();
    const doc = dom.window.document;
    const root = createRoot(doc.getElementById('root')!);
    const settle = () => new Promise((r) => setTimeout(r, 40));
    const go = async (hash: string) => {
      await act(async () => {
        dom.window.location.hash = hash;
        dom.window.dispatchEvent(new dom.window.Event('hashchange'));
        await settle();
      });
    };
    let replaces = 0;
    const origReplace = dom.window.history.replaceState.bind(dom.window.history);
    dom.window.history.replaceState = (...args: any[]) => {
      replaces += 1;
      return origReplace(...(args as [any, string, string]));
    };
    const render = (isMobile = false) =>
      root.render(React.createElement(Provider, { store }, React.createElement(Workspace, { isMobile })));
    try {
      await act(async () => {
        render();
        await settle();
      });
      // Legacy single-id URL = the 1-pane case.
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['agent-a']);
      assert.equal(replaces, 0, 'a URL-driven layout is never echoed back');

      // In-app split -> URL replaced with the pane set + focused.
      await act(async () => {
        store.dispatch(layout.splitMainPane({ targetPaneId: 'pane-1', direction: 'right', agentInstanceId: 'agent-b' }));
        await settle();
      });
      assert.equal(dom.window.location.hash, '#/conversations/agent-a+agent-b?focused=agent-b');
      const afterSplit = replaces;
      await act(async () => {
        await settle();
      });
      assert.equal(replaces, afterSplit, 'no ping-pong after the replace');
      assert.deepEqual(readGroupIndex(), [['agent-a', 'agent-b']], 'the split is saved as a group');

      // Focus change -> only ?focused= changes.
      await act(async () => {
        store.dispatch(layout.setFocusedMainPane('pane-1'));
        await settle();
      });
      assert.equal(dom.window.location.hash, '#/conversations/agent-a+agent-b?focused=agent-a');

      // Opening an agent outside the group -> its single view; the group stays saved.
      await go('#/conversations/agent-c');
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['agent-c']);
      assert.deepEqual(readGroupIndex(), [['agent-a', 'agent-b']]);

      // Opening an agent that is in a saved group -> the whole group, focused on it.
      await go('#/conversations/agent-b');
      assert.match(dom.window.location.hash, /^#\/conversations\/agent-a\+agent-b\?focused=agent-b$/);
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['agent-a', 'agent-b']);
      assert.equal(layout.selectFocusedMainAgentId(store.getState()), 'agent-b');

      // Mobile: Main panes page sideways; the aux opens as a full-screen sheet
      // showing the FOCUSED agent's strip.
      await act(async () => {
        store.dispatch(setAuxPaneOpen({ treeId: { kind: 'agent', agentInstanceId: 'agent-b' }, open: true, hasChain: false }));
        render(true);
        await settle();
      });
      assert.ok(doc.querySelector('[data-debug-id="workspace-mobile-pager"]'));
      assert.equal(doc.querySelectorAll('[data-debug-id^="workspace-mobile-page-"]').length, 2);
      const dock = doc.querySelector('[data-debug-id="aux-dock"]');
      assert.ok(dock, 'aux dock rendered');
      assert.equal(dock!.getAttribute('data-aux-tree'), 'agent:agent-b', 'split view shows the focused agent strip');
      assert.equal(dock!.getAttribute('data-aux-mobile-sheet'), 'true');
      assert.equal(dom.window.localStorage.getItem('heimdall:workspace-layout:v1'), null, 'no global layout key');
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});
