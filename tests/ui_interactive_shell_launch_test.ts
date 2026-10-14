// REQ-ISHELL-1..6: a new workbench shell starts once, uses the active bridge's
// project path when configured, and otherwise leaves cwd/cmd absent so the bridge
// launches the user's login shell in HOME.
//
// RUN: node --test tests/ui_interactive_shell_launch_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import React from 'react';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';
import {
  buildInteractiveShellRequest,
  resolveProjectBridgeShellCwd,
} from '../src/ui/components/shells/interactiveShellLaunch.ts';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

test('resolves only the path configured for the selected bridge', () => {
  const project = {
    default_path: '/wrong/global/path',
    bridge_paths: [
      { bridge_id: 'bridge-a', path: ' /srv/project-a ' },
      { bridge_id: 'bridge-b', path: '/srv/project-b' },
    ],
  };

  assert.equal(resolveProjectBridgeShellCwd(project, 'bridge-a'), '/srv/project-a');
  assert.equal(resolveProjectBridgeShellCwd(project, 'bridge-b'), '/srv/project-b');
  assert.equal(resolveProjectBridgeShellCwd(project, 'bridge-c'), undefined);
  assert.equal(resolveProjectBridgeShellCwd(project, undefined), undefined);
});

test('empty or missing bridge path leaves cwd absent for the PTY HOME fallback', () => {
  assert.equal(
    resolveProjectBridgeShellCwd(
      { bridge_paths: [{ bridge_id: 'bridge-a', path: '   ' }] },
      'bridge-a',
    ),
    undefined,
  );
  assert.equal(resolveProjectBridgeShellCwd({ bridge_paths: [] }, 'bridge-a'), undefined);
});

test('interactive request omits cmd and an unavailable cwd', () => {
  const request = buildInteractiveShellRequest({
    bridgeId: 'bridge-a',
    chainId: 'chain-a',
    projectId: 'project-a',
  });

  assert.deepEqual(request, {
    bridgeId: 'bridge-a',
    kind: 'shell',
    chain_id: 'chain-a',
    project_id: 'project-a',
  });
  assert.equal('cmd' in request, false);
  assert.equal('cwd' in request, false);
});

test('interactive request trims and forwards a configured cwd', () => {
  assert.deepEqual(
    buildInteractiveShellRequest({ bridgeId: 'bridge-a', cwd: ' /srv/project-a ' }),
    { bridgeId: 'bridge-a', kind: 'shell', cwd: '/srv/project-a' },
  );
});

test('workbench launch uses a fresh-session sentinel and a guarded retryable auto-start', () => {
  const launcher = fs.readFileSync(
    path.join(REPO_ROOT, 'src/ui/components/workbench/WorkbenchNewTabLauncher.tsx'),
    'utf8',
  );
  const pane = fs.readFileSync(
    path.join(REPO_ROOT, 'src/ui/components/workbench/ShellWorkbenchPane.tsx'),
    'utf8',
  );
  const dialog = fs.readFileSync(
    path.join(REPO_ROOT, 'src/ui/components/shells/NewShellDialog.tsx'),
    'utf8',
  );

  assert.match(launcher, /kind: 'shell',[\s\S]*sessionId: 'new'/);
  assert.match(pane, /autoCreateAttemptedRef\.current/);
  assert.match(pane, /buildInteractiveShellRequest/);
  assert.match(pane, /workbench-shell-auto-retry-btn/);
  assert.match(dialog, /resolveProjectBridgeShellCwd/);
  assert.match(dialog, /cwdEditedRef\.current = true/);
});

test('successful auto-start creates once and reports the real session for tab rekeying', async () => {
  const { JSDOM } = await import('jsdom');
  const { Provider } = await import('react-redux');
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { WorkbenchPaneView } = await import(
    '../src/ui/components/workbench/WorkbenchPaneView.tsx'
  );
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');

  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', {
    url: 'http://localhost/',
  });
  const previousWindow = (globalThis as any).window;
  const previousDocument = (globalThis as any).document;
  const previousHTMLElement = (globalThis as any).HTMLElement;
  const previousNavigator = (globalThis as any).navigator;
  const previousFetch = (globalThis as any).fetch;
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  Object.defineProperty(globalThis, 'navigator', { value: dom.window.navigator, configurable: true });
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

  let postCount = 0;
  (globalThis as any).fetch = async (input: any, init: any = {}) => {
    const url = String(input?.url ?? input);
    const method = String(init?.method || input?.method || 'GET').toUpperCase();
    if (method === 'POST' && url.includes('/bridges/bridge-a/shells')) {
      postCount += 1;
      const body = { data: { session: { session_id: 'sh-created', kind: 'shell' } } };
      return {
        ok: true,
        status: 200,
        headers: { get: () => 'application/json' },
        text: async () => JSON.stringify(body),
        json: async () => body,
      } as any;
    }
    const body = { data: { sessions: [] } };
    return {
      ok: true,
      status: 200,
      headers: { get: () => 'application/json' },
      text: async () => JSON.stringify(body),
      json: async () => body,
    } as any;
  };

  const replacements: Array<{ tabId: string; tab: Record<string, unknown> }> = [];
  const store = await makeVaultStore();
  const root = createRoot(dom.window.document.getElementById('root')!);
  try {
    await act(async () => {
      root.render(
        React.createElement(
          Provider,
          { store },
          React.createElement(WorkbenchPaneView, {
            paneId: 'pane-1',
            pane: {
              tabs: [{
                id: 'shell__new',
                kind: 'shell',
                title: 'Shell',
                sessionId: 'new',
                closable: true,
              }],
              activeTabId: 'shell__new',
            },
            workspaceKey: 'chain:chain-a',
            primaryAgentInstanceId: 'agent-a',
            bridgeId: 'bridge-a',
            projectId: 'project-a',
            chainId: 'chain-a',
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
            onReplaceTab: (tabId: string, tab: Record<string, unknown>) => {
              replacements.push({ tabId, tab });
            },
            onSplitPane: () => {},
            onToggleMaximize: () => {},
            onClosePane: () => {},
          }),
        ),
      );
      await new Promise((resolve) => setTimeout(resolve, 50));
    });

    assert.equal(postCount, 1, 'auto-start must issue exactly one shell creation request');
    assert.deepEqual(replacements, [{
      tabId: 'shell__new',
      tab: {
        kind: 'shell',
        sessionId: 'sh-created',
        title: 'Shell',
        bridgeId: 'bridge-a',
        currentPath: undefined,
        closable: true,
      },
    }]);
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    dom.window.close();
    (globalThis as any).window = previousWindow;
    (globalThis as any).document = previousDocument;
    (globalThis as any).HTMLElement = previousHTMLElement;
    Object.defineProperty(globalThis, 'navigator', { value: previousNavigator, configurable: true });
    (globalThis as any).fetch = previousFetch;
  }
});

test('auto-start attempts once and exposes an explicit retry after failure', async () => {
  const { JSDOM } = await import('jsdom');
  const { Provider } = await import('react-redux');
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { ShellWorkbenchPane } = await import(
    '../src/ui/components/workbench/ShellWorkbenchPane.tsx'
  );
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');

  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', {
    url: 'http://localhost/',
  });
  const previousWindow = (globalThis as any).window;
  const previousDocument = (globalThis as any).document;
  const previousHTMLElement = (globalThis as any).HTMLElement;
  const previousNavigator = (globalThis as any).navigator;
  const previousFetch = (globalThis as any).fetch;
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  Object.defineProperty(globalThis, 'navigator', { value: dom.window.navigator, configurable: true });
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

  const posts: Array<Record<string, unknown>> = [];
  (globalThis as any).fetch = async (input: any, init: any = {}) => {
    const url = String(input?.url ?? input);
    const method = String(init?.method || input?.method || 'GET').toUpperCase();
    if (method === 'POST' && url.includes('/bridges/bridge-a/shells')) {
      const rawBody = init?.body || (typeof input?.clone === 'function' ? await input.clone().text() : '');
      posts.push(JSON.parse(String(rawBody || '{}')));
      const body = { error: { message: 'bridge refused test shell' } };
      return {
        ok: false,
        status: 500,
        headers: { get: () => 'application/json' },
        text: async () => JSON.stringify(body),
        json: async () => body,
      } as any;
    }
    const body = { data: { sessions: [] } };
    return {
      ok: true,
      status: 200,
      headers: { get: () => 'application/json' },
      text: async () => JSON.stringify(body),
      json: async () => body,
    } as any;
  };

  const store = await makeVaultStore();
  const root = createRoot(dom.window.document.getElementById('root')!);
  const renderPane = (cwdReady: boolean) => React.createElement(
    Provider,
    { store },
    React.createElement(ShellWorkbenchPane, {
      bridgeId: 'bridge-a',
      projectId: 'project-a',
      chainId: 'chain-a',
      defaultCwd: '/srv/project-a',
      cwdReady,
      autoCreate: true,
    }),
  );
  try {
    await act(async () => {
      root.render(renderPane(false));
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    assert.equal(posts.length, 0, 'auto-start must wait until project cwd resolution completes');

    await act(async () => {
      root.render(renderPane(true));
      await new Promise((resolve) => setTimeout(resolve, 50));
    });

    assert.equal(posts.length, 1, 'initial render must issue exactly one shell start');
    assert.deepEqual(posts[0], {
      kind: 'shell',
      cwd: '/srv/project-a',
      chain_id: 'chain-a',
      project_id: 'project-a',
    });
    const retry = dom.window.document.querySelector(
      '[data-debug-id="workbench-shell-auto-retry-btn"]',
    ) as HTMLButtonElement | null;
    assert.ok(retry, 'failed auto-start must render the retry action');

    await act(async () => {
      retry.click();
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
    assert.equal(posts.length, 2, 'retry must make one additional shell start request');
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    dom.window.close();
    (globalThis as any).window = previousWindow;
    (globalThis as any).document = previousDocument;
    (globalThis as any).HTMLElement = previousHTMLElement;
    Object.defineProperty(globalThis, 'navigator', { value: previousNavigator, configurable: true });
    (globalThis as any).fetch = previousFetch;
  }
});
