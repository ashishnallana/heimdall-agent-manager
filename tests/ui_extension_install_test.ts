// Provider extension install model, the web surfaces that no longer install
// extensions (ham-bridge setup / update does), and the bridge update modal's
// extension-update consent. Exercises the real React surfaces, RTK endpoints
// and cookie-authenticated wire contract.
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import type { ProviderExtensionCommand } from '../src/ui/components/extension/extensionInstallModel.ts';

// Dynamic imports run after the harness registers its Vite-style module resolver.
const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
const { ProviderSetupSurface } = await import('../src/ui/components/providers/ProviderSetupSurface.tsx');
const { default: BridgesPanel } = await import('../src/ui/components/settings/BridgesPanel.tsx');
const { extensionInstallLabel, extensionInstallProgress, isExtensionInstallTerminal } = await import('../src/ui/components/extension/extensionInstallModel.ts');
const { normalizeProviderExtension } = await import('../src/ui/components/extension/extensionBadgeModel.ts');

test('install actions are limited to supported installers and measured absent/outdated states', () => {
  for (const provider of ['claude', 'codex', 'antigravity']) {
    assert.equal(extensionInstallLabel(provider, normalizeProviderExtension({ state: 'absent' })), 'Install Extension');
    assert.equal(extensionInstallLabel(provider, normalizeProviderExtension({ state: 'outdated', min_version: '0.4.31' })), 'Update to v0.4.31');
    for (const state of ['present', 'disabled', 'error', 'unsupported', '']) {
      assert.equal(extensionInstallLabel(provider, normalizeProviderExtension({ state })), '');
    }
  }
  assert.equal(extensionInstallLabel('copilot', normalizeProviderExtension({ state: 'absent' })), '');
  assert.equal(extensionInstallLabel('codex', null), '');
  for (const state of ['queued', 'dispatched', 'accepted', 'installing'] as const) assert.equal(isExtensionInstallTerminal(state), false);
  for (const state of ['succeeded', 'failed', 'cancelled'] as const) assert.equal(isExtensionInstallTerminal(state), true);
});

test('success text requires present discovery', () => {
  const command: ProviderExtensionCommand = {
    command_id: 'old', bridge_id: 'bridge-1', provider: 'codex', status: 'succeeded',
    progress_percent: 100, message: '', parent_command_id: '',
  };
  for (const state of ['absent', 'outdated', 'disabled', 'error', 'unsupported', '']) {
    assert.doesNotMatch(extensionInstallProgress(command, normalizeProviderExtension({ state })), /installed and verified/);
  }
  assert.doesNotMatch(extensionInstallProgress(command, null), /installed and verified/);
  assert.match(extensionInstallProgress(command, normalizeProviderExtension({ state: 'present' })), /installed and verified/);
});

async function surfaceHarness(options: { state?: string } = {}) {
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
  const requests: Array<{ path: string; method: string; body: any }> = [];
  const bridge = { bridge_id: 'bridge-1', label: 'Test bridge', status: 'online',
    version: '0.4.30', latest_version: '0.4.31', update_available: true, update_artifact_available: true };
  const provider = { provider: 'codex', display_name: 'Test provider', enabled: true, state: 'present', models: [],
    extension: { state: options.state || 'absent', min_version: '0.4.31', version: '0.1.0' } };
  globalThis.fetch = (async (input: any, init: any = {}) => {
    const path = new URL(String(input), 'https://hub.example.test').pathname;
    const method = init.method || 'GET';
    requests.push({ path, method, body: init.body ? JSON.parse(init.body) : undefined });
    if (path.endsWith('/provider-status')) return Response.json({ data: { providers: [provider], extension_commands: [] } });
    if (path === '/api/v1/bridges') return Response.json({ data: [bridge] });
    if (path.endsWith('/update') && method === 'POST') return Response.json({ data: { command_id: 'bridge-update' } });
    if (path.includes('pending')) return Response.json({ data: [] });
    if (path.includes('telemetry')) return Response.json({ data: { enabled: false } });
    if (path.includes('/events')) return Response.json({ data: { events: [] } });
    throw new Error(`Unexpected request: ${method} ${path}`);
  }) as typeof fetch;
  const store = configureStore({
    reducer: { [heimdallApi.reducerPath]: heimdallApi.reducer },
    middleware: (defaults) => defaults().concat(heimdallApi.middleware),
    enhancers: (defaults) => defaults({ autoBatch: false }),
  });
  const root = createRoot(dom.window.document.getElementById('root')!);
  const query = (id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
  return {
    requests, query,
    text: () => dom.window.document.body.textContent || '',
    async render(panel = false) {
      await act(async () => {
        root.render(React.createElement(Provider, { store, children: panel
          ? React.createElement(BridgesPanel)
          : React.createElement(ProviderSetupSurface, { bridgeId: bridge.bridge_id, mode: 'settings' }) }));
      });
    },
    async click(id: string) {
      assert.ok(query(id), `Missing ${id}`);
      await act(async () => query(id)!.click());
    },
    async close() {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
      globalThis.fetch = previousFetch;
      dom.window.close();
      for (const [key, descriptor] of saved) {
        if (descriptor) Object.defineProperty(globalThis, key, descriptor);
        else delete (globalThis as any)[key];
      }
    },
  };
}

test('ProviderSetupSurface offers no web install or retry action for absent, outdated or failed extensions', async () => {
  for (const state of ['absent', 'outdated', 'error']) {
    const h = await surfaceHarness({ state });
    try {
      await h.render();
      assert.ok(h.query('provider-extension-badge-codex'), `extension badge renders for ${state}`);
      for (const id of ['provider-extension-action-codex', 'provider-extension-install-btn-codex',
        'provider-extension-retry-btn-codex', 'provider-extension-progress-codex']) {
        assert.equal(h.query(id), null, `${id} must not render for ${state}`);
      }
      assert.equal(h.requests.filter((r) => r.path.includes('/extension-install')).length, 0);
    } finally { await h.close(); }
  }
});

test('bridge update modal defaults extension updates on, sends explicit consent, and honors opt-out', async () => {
  const h = await surfaceHarness();
  try {
    await h.render(true);
    await h.click('settings-bridge-update-btn-bridge-1');
    const checkbox = () => h.query('settings-bridge-update-extensions') as HTMLInputElement;
    assert.equal(checkbox().checked, true);
    await h.click('settings-bridge-update-confirm');
    const updates = () => h.requests.filter((r) => r.path.endsWith('/update') && r.method === 'POST');
    assert.equal(updates()[0].body.update_extensions, true);
    await h.click('settings-bridge-update-btn-bridge-1');
    await h.click('settings-bridge-update-extensions');
    assert.equal(checkbox().checked, false);
    await h.click('settings-bridge-update-confirm');
    assert.equal(updates()[1].body.update_extensions, false);
    await h.click('settings-bridge-update-btn-bridge-1');
    assert.equal(checkbox().checked, true, 'a new update starts with the approved default');
  } finally { await h.close(); }
});
