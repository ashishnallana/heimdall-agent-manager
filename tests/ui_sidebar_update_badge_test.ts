// Sidebar Bridge-update badge: which bridges it advertises (connected, online,
// installable update, not mid-update), its click opening Settings > Bridges at
// that bridge's Update button, and "Manage bridges" opening Settings > Bridges.
// The badge never installs or enrolls a bridge (REQ-BTOP-1 / F29).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_sidebar_update_badge_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { pendingBridgeUpdates } from '../src/ui/components/settings/bridgeUpdate.ts';

// Dynamic imports run after the harness registers its Vite-style module resolver.
const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
const { default: SidebarUpdateBadge } = await import('../src/ui/components/shell/SidebarUpdateBadge.tsx');

const online = { status: 'online', runtime_connected: true, update_available: true };

test('only connected, online bridges with an installable update are advertised', () => {
  const updates = pendingBridgeUpdates([
    { ...online, bridge_id: 'brg_ok', label: 'dawnstar', latest_version: '0.3.40' },
    { ...online, bridge_id: 'brg_offline', status: 'offline', latest_version: '0.3.40' },
    { ...online, bridge_id: 'brg_disconnected', runtime_connected: false, latest_version: '0.3.40' },
    { ...online, bridge_id: 'brg_current', update_available: false },
    { ...online, bridge_id: 'brg_no_bundle', update_artifact_available: false, latest_version: '0.3.40' },
    { ...online, bridge_id: 'brg_updating', update_status: 'downloading', latest_version: '0.3.40' },
  ] as any);
  assert.deepEqual(updates, [{ bridgeId: 'brg_ok', latestVersion: '0.3.40', label: 'dawnstar' }]);
});

test('newest advertised version comes first (numeric compare)', () => {
  const updates = pendingBridgeUpdates([
    { ...online, bridge_id: 'a', latest_version: '0.3.9' },
    { ...online, bridge_id: 'b', latest_version: '0.3.40' },
  ] as any);
  assert.deepEqual(updates.map(u => u.bridgeId), ['b', 'a']);
});

test('empty / malformed input', () => {
  assert.deepEqual(pendingBridgeUpdates(undefined), []);
  assert.deepEqual(pendingBridgeUpdates([{ ...online }] as any), []);
  // The list query's data is `{ bridges: [...] }`; a non-array must never throw.
  assert.deepEqual(pendingBridgeUpdates({ bridges: [] } as any), []);
});

test('popover shows Hub status, opens the update, and "Manage bridges" calls onManage without install/enroll controls', async () => {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.example.test/', pretendToBeVisual: true });
  const saved = new Map<string, PropertyDescriptor | undefined>();
  for (const [key, value] of Object.entries({
    window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
  }
  const previousFetch = globalThis.fetch;
  const bridge = { ...online, bridge_id: 'brg_ok', label: 'dawnstar', version: '0.3.39', latest_version: '0.3.40' };
  globalThis.fetch = (async (input: any) => {
    const path = new URL(String(input), 'https://hub.example.test').pathname;
    if (path === '/api/v1/bridges') return Response.json({ data: [bridge] });
    throw new Error(`Unexpected request: ${path}`);
  }) as typeof fetch;
  const store = configureStore({
    reducer: { [heimdallApi.reducerPath]: heimdallApi.reducer },
    middleware: (defaults) => defaults().concat(heimdallApi.middleware),
    enhancers: (defaults) => defaults({ autoBatch: false }),
  });
  const root = createRoot(dom.window.document.getElementById('root')!);
  const query = (id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
  const click = async (id: string) => {
    assert.ok(query(id), `Missing ${id}`);
    await act(async () => query(id)!.click());
  };
  const opened: unknown[] = [];
  let managed = 0;
  try {
    await act(async () => {
      root.render(React.createElement(Provider, { store, children: React.createElement(SidebarUpdateBadge, {
        onOpen: (update) => opened.push(update), onManage: () => { managed += 1; },
      }) }));
    });
    assert.match(query('shell-bridge-status-btn')!.textContent || '', /Bridge v0\.3\.39/);
    await click('shell-bridge-status-btn');
    assert.ok(query('shell-bridge-status-popover'));
    assert.match(query('shell-bridge-status-popover')!.textContent || '', /Bridge online/);
    for (const removed of ['shell-bridge-install-btn', 'shell-bridge-enroll-btn', 'shell-bridge-pairing-code', 'shell-bridge-copy-pairing-code-btn']) {
      assert.equal(query(removed), null, `${removed} must not render`);
    }
    await click('shell-bridge-manage-btn');
    assert.equal(managed, 1);
    assert.equal(query('shell-bridge-status-popover'), null, 'Manage bridges closes the popover');
    await click('shell-bridge-status-btn');
    await click('shell-bridge-update-available-btn');
    assert.deepEqual(opened, [{ bridgeId: 'brg_ok', latestVersion: '0.3.40', label: 'dawnstar' }]);
    assert.equal(managed, 1);
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    globalThis.fetch = previousFetch;
    dom.window.close();
    for (const [key, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete (globalThis as any)[key];
    }
  }
});
