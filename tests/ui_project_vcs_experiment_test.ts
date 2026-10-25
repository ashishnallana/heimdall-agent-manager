// REQ-1, REQ-4: Project/VCS experiment key, Settings toggle, and eligibility resolution.
//
// RUN: node --test tests/ui_project_vcs_experiment_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  PROJECT_VCS_EXPERIMENT_KEY,
  resolveProjectVcsExperiment,
} from '../src/ui/components/chat/projectVcsExperiment.ts';

test('uses the stable project_vcs key in the domain and Settings toggle', () => {
  assert.equal(PROJECT_VCS_EXPERIMENT_KEY, 'project_vcs');
});

test('resolves undefined flags as loading', () => {
  assert.equal(resolveProjectVcsExperiment(undefined), 'loading');
});

test('resolves an absent key as disabled after flags load', () => {
  assert.equal(resolveProjectVcsExperiment([]), 'disabled');
  assert.equal(
    resolveProjectVcsExperiment([{ key: 'another_experiment', enabled: true }]),
    'disabled',
  );
});

test('resolves an explicit false Project/VCS flag as disabled', () => {
  assert.equal(
    resolveProjectVcsExperiment([{ key: PROJECT_VCS_EXPERIMENT_KEY, enabled: false }]),
    'disabled',
  );
});

test('resolves an explicit true Project/VCS flag as enabled', () => {
  assert.equal(
    resolveProjectVcsExperiment([{ key: PROJECT_VCS_EXPERIMENT_KEY, enabled: true }]),
    'enabled',
  );
});

test('ignores unrelated flags when resolving a valid Project/VCS flag', () => {
  assert.equal(
    resolveProjectVcsExperiment([
      { key: 'streaming_terminal_pane', enabled: false },
      { key: PROJECT_VCS_EXPERIMENT_KEY, enabled: true },
      { key: 'lsp', enabled: true },
    ]),
    'enabled',
  );
});

test('fails closed for malformed or duplicate Project/VCS flags', () => {
  assert.equal(
    resolveProjectVcsExperiment([
      { key: PROJECT_VCS_EXPERIMENT_KEY, enabled: 'true' },
    ] as unknown as Array<{ key: string; enabled: boolean }>),
    'disabled',
  );
  assert.equal(
    resolveProjectVcsExperiment([
      { key: PROJECT_VCS_EXPERIMENT_KEY, enabled: true },
      { key: PROJECT_VCS_EXPERIMENT_KEY, enabled: true },
    ]),
    'disabled',
  );
  assert.equal(
    resolveProjectVcsExperiment([
      { key: PROJECT_VCS_EXPERIMENT_KEY, enabled: true },
      { key: PROJECT_VCS_EXPERIMENT_KEY, enabled: false },
    ]),
    'disabled',
  );
});

// REQ-EXP-GATE-2: Project Explorer UI gates (launchers, restored tabs, open paths).

import {
  EXPERIMENTAL_SETTINGS_HREF,
  projectExplorerUnavailableMessage,
  resolveProjectExplorerAccess,
} from '../src/ui/components/chat/projectVcsExperiment.ts';
import {
  explorerSafeActiveTab,
  filterExplorerAuxTabs,
  isAuxContentAllowed,
  isExplorerAuxContent,
} from '../src/ui/store/auxTabGuards.ts';

const ENABLED = [{ key: PROJECT_VCS_EXPERIMENT_KEY, enabled: true }];
const DISABLED = [{ key: PROJECT_VCS_EXPERIMENT_KEY, enabled: false }];

test('explorer access is enabled only for a loaded true flag; fetch errors fail closed', () => {
  assert.equal(resolveProjectExplorerAccess(ENABLED, false), 'enabled');
  assert.equal(resolveProjectExplorerAccess(DISABLED, false), 'disabled');
  assert.equal(resolveProjectExplorerAccess([], false), 'disabled');
  assert.equal(resolveProjectExplorerAccess(undefined, false), 'loading');
  assert.equal(resolveProjectExplorerAccess(undefined, true), 'error');
  // A refetch error with stale cached flags must not keep the explorer open.
  assert.equal(resolveProjectExplorerAccess(ENABLED, true), 'error');
});

test('unavailable copy matches the server message and links to Experimental settings', () => {
  assert.equal(
    projectExplorerUnavailableMessage('disabled'),
    'Project Explorer is experimental. Enable it in Settings > Experimental to use it.',
  );
  assert.match(projectExplorerUnavailableMessage('error'), /could not be loaded/);
  assert.match(projectExplorerUnavailableMessage('loading'), /Checking/);
  assert.equal(EXPERIMENTAL_SETTINGS_HREF, '#/settings/experimental');
});

test('only files and vcs aux content count as the explorer', () => {
  assert.equal(isExplorerAuxContent({ type: 'files' }), true);
  assert.equal(isExplorerAuxContent({ type: 'vcs' }), true);
  for (const type of ['chainOverview', 'tasks', 'shell', 'agentPty', 'preview', 'subagentChat', 'artifact'] as const) {
    assert.equal(isExplorerAuxContent({ type }), false, type);
  }
});

test('opening explorer tabs is refused unless enabled; other tabs unaffected', () => {
  for (const explorerEnabled of [undefined, false]) {
    assert.equal(isAuxContentAllowed({ type: 'files', openSearch: true }, { explorerEnabled }), false);
    assert.equal(isAuxContentAllowed({ type: 'vcs', filePath: 'a.ts' }, { explorerEnabled }), false);
    assert.equal(isAuxContentAllowed({ type: 'tasks' }, { explorerEnabled }), true);
    assert.equal(isAuxContentAllowed({ type: 'chainOverview' }, { explorerEnabled }), true);
  }
  assert.equal(isAuxContentAllowed({ type: 'files' }, { explorerEnabled: true }), true);
  assert.equal(isAuxContentAllowed({ type: 'vcs' }, { explorerEnabled: true }), true);
});

test('restored explorer tabs leave the strip while disabled and return when enabled', () => {
  const tabs = [
    { id: 'chain', content: { type: 'chainOverview' as const } },
    { id: 'files', content: { type: 'files' as const } },
    { id: 'shell__s1', content: { type: 'shell' as const, sessionId: 's1' } },
    { id: 'vcs', content: { type: 'vcs' as const } },
  ];
  assert.deepEqual(filterExplorerAuxTabs(tabs, false).map((t) => t.id), ['chain', 'shell__s1']);
  assert.deepEqual(filterExplorerAuxTabs(tabs, true).map((t) => t.id), ['chain', 'files', 'shell__s1', 'vcs']);
});

test('seeded Files default falls back to the launcher; stored explorer tab stays to explain', () => {
  const seeded = { id: 'files', content: { type: 'files' as const } };
  assert.equal(explorerSafeActiveTab(seeded, [], false), null);
  assert.equal(explorerSafeActiveTab(seeded, [], true), seeded);
  assert.equal(explorerSafeActiveTab(seeded, [{ id: 'files' }], false), seeded);
  const tasks = { id: 'tasks', content: { type: 'tasks' as const } };
  assert.equal(explorerSafeActiveTab(tasks, [], false), tasks);
  assert.equal(explorerSafeActiveTab(null, [], false), null);
});

// DOM regression: the real AuxDock with a restored Files tab and live flag toggles.

import React from 'react';

async function withExplorerDom<T>(fn: (dom: any, fetched: string[]) => Promise<T>): Promise<T> {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', {
    url: 'http://localhost/#/conversations/agent-a',
  });
  (dom.window.HTMLElement.prototype as any).scrollTo = () => {};
  (dom.window.HTMLElement.prototype as any).scrollIntoView = () => {};
  const g = globalThis as any;
  const prev = { window: g.window, document: g.document, HTMLElement: g.HTMLElement, navigator: g.navigator, fetch: g.fetch, localStorage: g.localStorage };
  const fetched: string[] = [];
  g.window = dom.window;
  g.document = dom.window.document;
  g.HTMLElement = dom.window.HTMLElement;
  g.localStorage = dom.window.localStorage;
  Object.defineProperty(globalThis, 'navigator', { value: dom.window.navigator, configurable: true });
  g.IS_REACT_ACT_ENVIRONMENT = true;
  g.fetch = async (input: any) => {
    fetched.push(String(input?.url ?? input));
    const body = { data: {} };
    return { ok: true, status: 200, headers: { get: () => 'application/json' }, text: async () => JSON.stringify(body), json: async () => body } as any;
  };
  try {
    return await fn(dom, fetched);
  } finally {
    dom.window.close();
    g.window = prev.window;
    g.document = prev.document;
    g.HTMLElement = prev.HTMLElement;
    g.localStorage = prev.localStorage;
    Object.defineProperty(globalThis, 'navigator', { value: prev.navigator, configurable: true });
    g.fetch = prev.fetch;
  }
}

function explorerCtx(access: 'loading' | 'disabled' | 'enabled' | 'error') {
  return {
    agentInstanceId: 'agent-a', conversationId: '', title: 'A', chainId: '', projectId: 'project-a',
    projectName: 'Proj', bridgeId: 'bridge-a', defaultCwd: '', shellDefaultCwd: undefined, shellCwdReady: true,
    projectVcsEnabled: access === 'enabled', projectExplorerAccess: access,
    directories: [], members: [], participantIds: null, isResolved: true,
  };
}

const isExplorerRequest = (url: string) => /\/(projects|task-chains)\/[^?]*\/(fs|vcs)(\/|\?|$)/.test(url);

test('aux dock: restored explorer tab is hidden and explained while disabled, restored live when enabled', async () => {
  await withExplorerDom(async (dom, fetched) => {
    const { createRoot } = await import('react-dom/client');
    const { Provider } = await import('react-redux');
    const { configureStore } = await import('@reduxjs/toolkit');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const { default: vaultReducer } = await import('../src/ui/store/vaultSlice.ts');
    const { default: workspaceLayout } = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { default: auxPanes, openAuxTab, setActiveAuxTab } = await import('../src/ui/store/auxPanesSlice.ts');
    const { default: workspaceChrome } = await import('../src/ui/store/workspaceChromeSlice.ts');
    const { AuxDock } = await import('../src/ui/components/auxiliary/AuxDock.tsx');
    const store = configureStore({
      reducer: {
        vault: vaultReducer, workspaceLayout, auxPanes, workspaceChrome,
        chat: (s: any = { session: { daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test' } }) => s,
        [heimdallApi.reducerPath]: heimdallApi.reducer,
      },
      middleware: (gdm: any) => gdm({ serializableCheck: false, immutableCheck: false }).concat(heimdallApi.middleware),
    });
    const treeId = { kind: 'agent' as const, agentInstanceId: 'agent-a' };
    // A persisted strip from an earlier session: Files (active) and VCS tabs.
    store.dispatch(openAuxTab({ treeId, content: { type: 'vcs' }, hasChain: false }));
    store.dispatch(openAuxTab({ treeId, content: { type: 'files' }, hasChain: false }));
    store.dispatch(setActiveAuxTab({ treeId, tabId: 'files' }));

    const doc = dom.window.document;
    const q = (sel: string) => doc.querySelector(sel);
    const root = createRoot(doc.getElementById('root')!);
    const settle = () => new Promise((r) => setTimeout(r, 30));
    const render = async (access: 'loading' | 'disabled' | 'enabled' | 'error') => {
      await React.act(async () => {
        root.render(React.createElement(Provider, { store }, React.createElement(AuxDock, { treeId, ctx: explorerCtx(access) as any })));
        await settle();
      });
    };
    try {
      for (const access of ['loading', 'disabled', 'error'] as const) {
        await render(access);
        assert.ok(q(`[data-debug-id="aux-explorer-unavailable-${access}"]`), `${access}: unavailable notice`);
        assert.equal(q('[data-debug-id="aux-tab-files"]'), null, `${access}: Files tab hidden`);
        assert.equal(q('[data-debug-id="aux-tab-vcs"]'), null, `${access}: VCS tab hidden`);
        const link = q('[data-debug-id="aux-explorer-unavailable-settings-link"]');
        if (access === 'loading') assert.equal(link, null);
        else assert.equal(link?.getAttribute('href'), '#/settings/experimental');
      }
      assert.deepEqual(fetched.filter(isExplorerRequest), [], 'no file/VCS/search request while not enabled');

      // Toggle on without reload: tabs and panel come back.
      await render('enabled');
      assert.ok(q('[data-debug-id="aux-tab-files"]'), 'Files tab restored');
      assert.ok(q('[data-debug-id="aux-tab-vcs"]'), 'VCS tab restored');
      assert.equal(q('[data-debug-id^="aux-explorer-unavailable-"]'), null);
      for (let i = 0; i < 50 && fetched.filter(isExplorerRequest).length === 0; i += 1) {
        await React.act(async () => { await new Promise((r) => setTimeout(r, 20)); });
      }
      assert.ok(fetched.filter(isExplorerRequest).length > 0, `enabled Files panel queries the explorer API (saw ${fetched.join(', ')})`);

      // Toggle off while open: content unmounts and no further explorer queries start.
      await render('disabled');
      const before = fetched.filter(isExplorerRequest).length;
      await React.act(async () => { await new Promise((r) => setTimeout(r, 60)); });
      assert.ok(q('[data-debug-id="aux-explorer-unavailable-disabled"]'), 'toggle off hides the open explorer');
      assert.equal(q('[data-debug-id="aux-tab-files"]'), null);
      assert.equal(fetched.filter(isExplorerRequest).length, before, 'no explorer requests after toggle off');
    } finally {
      await React.act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('aux launcher: Files/VCS cards and the seeded Files default appear only when enabled', async () => {
  await withExplorerDom(async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { Provider } = await import('react-redux');
    const { configureStore } = await import('@reduxjs/toolkit');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const { default: vaultReducer } = await import('../src/ui/store/vaultSlice.ts');
    const { default: workspaceLayout } = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { default: auxPanes, ensureAuxPane, setActiveAuxTab } = await import('../src/ui/store/auxPanesSlice.ts');
    const { NEW_TAB_ID } = await import('../src/ui/store/auxTabId.ts');
    const { default: workspaceChrome } = await import('../src/ui/store/workspaceChromeSlice.ts');
    const { AuxDock } = await import('../src/ui/components/auxiliary/AuxDock.tsx');
    const store = configureStore({
      reducer: {
        vault: vaultReducer, workspaceLayout, auxPanes, workspaceChrome,
        chat: (s: any = { session: { daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test' } }) => s,
        [heimdallApi.reducerPath]: heimdallApi.reducer,
      },
      middleware: (gdm: any) => gdm({ serializableCheck: false, immutableCheck: false }).concat(heimdallApi.middleware),
    });
    const treeId = { kind: 'agent' as const, agentInstanceId: 'agent-a' };
    store.dispatch(ensureAuxPane({ treeId, hasChain: false }));

    const doc = dom.window.document;
    const q = (sel: string) => doc.querySelector(sel);
    const root = createRoot(doc.getElementById('root')!);
    const settle = () => new Promise((r) => setTimeout(r, 30));
    const render = async (access: 'disabled' | 'enabled') => {
      await React.act(async () => {
        root.render(React.createElement(Provider, { store }, React.createElement(AuxDock, { treeId, ctx: explorerCtx(access) as any })));
        await settle();
      });
    };
    try {
      await render('disabled');
      assert.ok(q('[data-debug-id="aux-launcher-surface-grid"]'), 'seeded Files default falls back to the launcher');
      assert.equal(q('[data-debug-id="aux-launcher-card-files"]'), null);
      assert.equal(q('[data-debug-id="aux-launcher-card-vcs"]'), null);
      assert.ok(q('[data-debug-id="aux-launcher-card-shell"]'), 'unrelated surfaces remain');
      assert.equal(q('[data-debug-id^="aux-explorer-unavailable-"]'), null, 'no notice for a never-opened seed');

      store.dispatch(setActiveAuxTab({ treeId, tabId: NEW_TAB_ID }));
      await render('enabled');
      assert.ok(q('[data-debug-id="aux-launcher-card-files"]'), 'Files card when enabled');
      assert.ok(q('[data-debug-id="aux-launcher-card-vcs"]'), 'VCS card when enabled');
    } finally {
      await React.act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});
