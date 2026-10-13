import assert from 'node:assert/strict';
import { test } from 'node:test';
import React from 'react';

// Mobile: every pane of the 2D split tree is flattened into a side-scrolling pager of
// full-width pages, and the 4 split directions collapse to a single "New Pane" action.
test('mobile workbench flattens split panes into a pager and offers "New Pane" instead of split directions', async () => {
  const { JSDOM } = await import('jsdom');
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { Provider } = await import('react-redux');
  const { configureStore } = await import('@reduxjs/toolkit');
  const { default: workbenchReducer, splitWorkbenchPane, ensureWorkspaceInitialized } = await import(
    '../src/ui/store/workbenchSlice.ts'
  );
  const { default: vaultReducer } = await import('../src/ui/store/vaultSlice.ts');
  const { ConversationWorkbench } = await import('../src/ui/components/workbench/ConversationWorkbench.tsx');
  const { WorkbenchTabStrip } = await import('../src/ui/components/workbench/WorkbenchTabStrip.tsx');
  const { getContentPaneIds } = await import('../src/ui/tiling/paneTreeState.ts');

  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', {
    url: 'http://127.0.0.1:5173/#/conversations/inst-m',
  });
  (dom.window.HTMLElement.prototype as any).scrollTo = () => {};
  (dom.window.HTMLElement.prototype as any).scrollIntoView = () => {};
  const prev = {
    window: (globalThis as any).window,
    document: (globalThis as any).document,
    HTMLElement: (globalThis as any).HTMLElement,
    localStorage: (globalThis as any).localStorage,
  };
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).localStorage = dom.window.localStorage;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const store = configureStore({
    reducer: {
      workbench: workbenchReducer,
      vault: vaultReducer,
      chat: (s: any = { session: { daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test' } }) => s,
      [heimdallApi.reducerPath]: heimdallApi.reducer,
    },
    middleware: (g: any) =>
      g({ serializableCheck: false, immutableCheck: false }).concat(heimdallApi.middleware),
  });
  store.dispatch(
    ensureWorkspaceInitialized({ workspaceKey: 'ws-m', defaultAgentInstanceId: 'inst-m' }),
  );
  // Two splits in different directions -> three content panes in the tree.
  store.dispatch(splitWorkbenchPane({ workspaceKey: 'ws-m', targetPaneId: 'pane-1', direction: 'right' }));
  store.dispatch(splitWorkbenchPane({ workspaceKey: 'ws-m', targetPaneId: 'pane-1', direction: 'bottom' }));
  const tree = (store.getState() as any).workbench.workspaces['ws-m'].tree;
  const paneIds = getContentPaneIds(tree);
  assert.equal(paneIds.length, 3);

  let root: ReturnType<typeof createRoot> | null = null;
  try {
    const container = dom.window.document.getElementById('root')!;
    root = createRoot(container);
    // Render a mobile tab strip on its own to assert the menu shape.
    const splitDirs: string[] = [];
    await act(async () => {
      root!.render(
        React.createElement(
          Provider,
          { store },
          React.createElement(
            'div',
            null,
            React.createElement(ConversationWorkbench, {
              workspaceKey: 'ws-m',
              primaryAgentInstanceId: 'inst-m',
              isMobile: true,
            }),
            React.createElement(WorkbenchTabStrip, {
              paneId: 'strip-m',
              tabs: [],
              activeTabId: undefined,
              isFocused: true,
              isMaximized: false,
              isSinglePane: false,
              isMobile: true,
              onSelectTab: () => {},
              onCloseTab: () => {},
              onOpenNewTab: () => {},
              onSplitPane: (d: string) => splitDirs.push(d),
              onToggleMaximize: () => {},
              onClosePane: () => {},
            }),
          ),
        ),
      );
    });

    const doc = dom.window.document;
    assert.ok(doc.querySelector('[data-debug-id="workbench-mobile-pager"]'), 'mobile renders the pager');
    for (const id of paneIds) {
      assert.ok(
        doc.querySelector(`[data-debug-id="workbench-mobile-page-${id}"]`),
        `pane ${id} is a top-level page`,
      );
    }
    assert.ok(doc.querySelector('[data-debug-id="workbench-mobile-pager-dots"]'), 'page dots shown for >1 pane');

    // Mobile tab strip: no maximize button; menu has "New Pane" and no split directions.
    assert.equal(doc.querySelector('[data-debug-id="workbench-pane-maximize-strip-m"]'), null);
    await act(async () => {
      (doc.querySelector('[data-debug-id="workbench-pane-overflow-menu-btn-strip-m"]') as HTMLElement).click();
    });
    for (const dir of ['right', 'bottom', 'left', 'top']) {
      assert.equal(doc.querySelector(`[data-debug-id="workbench-pane-split-${dir}-strip-m"]`), null);
    }
    const newPane = doc.querySelector('[data-debug-id="workbench-pane-new-pane-action-strip-m"]') as HTMLElement;
    assert.ok(newPane, 'mobile menu offers "New Pane"');
    await act(async () => {
      newPane.click();
    });
    assert.deepEqual(splitDirs, ['right'], '"New Pane" appends a pane');
  } finally {
    if (root) {
      await act(async () => {
        root!.unmount();
      });
    }
    // Drop RTK Query cache timers so the test process can exit.
    store.dispatch(heimdallApi.util.resetApiState());
    dom.window.close();
    (globalThis as any).window = prev.window;
    (globalThis as any).document = prev.document;
    (globalThis as any).HTMLElement = prev.HTMLElement;
    (globalThis as any).localStorage = prev.localStorage;
  }
});
