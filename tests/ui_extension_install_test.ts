// Exercise the real React surfaces, RTK endpoints and cookie-authenticated wire contract.
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
const { bridgeSupportApi } = await import('../src/ui/api/endpoints/bridgeSupport.ts');
const { ProviderSetupSurface } = await import('../src/ui/components/providers/ProviderSetupSurface.tsx');
const { default: BridgesPanel } = await import('../src/ui/components/settings/BridgesPanel.tsx');
const { extensionInstallLabel, isExtensionInstallTerminal } = await import('../src/ui/components/extension/extensionInstallModel.ts');
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

async function surfaceHarness(options: { state?: string; online?: boolean; cliPresent?: boolean; recover?: boolean } = {}) {
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
  const bridge = { bridge_id: 'bridge-1', label: 'Test bridge', status: options.online === false ? 'offline' : 'online',
    version: '0.4.30', latest_version: '0.4.31', update_available: true, update_artifact_available: true };
  const provider = { provider: 'codex', display_name: 'Codex', enabled: true,
    state: options.cliPresent === false ? 'absent' : 'present', models: [],
    extension: { state: options.state || 'absent', min_version: '0.4.31', version: '0.1.0' } };
  let command: ProviderExtensionCommand | null = options.recover ? {
    command_id: 'recovered', bridge_id: bridge.bridge_id, provider: 'codex', status: 'installing',
    progress_percent: 50, message: 'Installing recovered command', parent_command_id: 'bridge-update',
  } : null;
  let postError = '';
  globalThis.fetch = (async (input: any, init: any = {}) => {
    const path = new URL(String(input), 'https://hub.example.test').pathname;
    const method = init.method || 'GET';
    requests.push({ path, method, body: init.body ? JSON.parse(init.body) : undefined });
    if (path.endsWith('/extension-install') && method === 'POST') {
      if (postError) return new Response(JSON.stringify({ error: { message: postError, code: 'conflict' } }), { status: 409 });
      command = { command_id: `install-${requests.length}`, bridge_id: bridge.bridge_id, provider: 'codex',
        status: 'dispatched', progress_percent: 0, message: '', parent_command_id: '' };
      return Response.json({ data: command }, { status: 202 });
    }
    if (path.includes('/extension-install/')) return Response.json({ data: command });
    if (path.endsWith('/provider-status')) return Response.json({ data: { providers: [provider], extension_commands: command ? [command] : [] } });
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
    requests, query, provider,
    text: () => dom.window.document.body.textContent || '',
    rejectPost(message: string) { postError = message; },
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
    async progress(status: ProviderExtensionCommand['status'], percent: number, message = '') {
      assert.ok(command);
      command = { ...command, status, progress_percent: percent, message };
      if (status === 'succeeded') provider.extension = { ...provider.extension, state: 'present', version: '0.4.31' };
      // Force the same real query the poll uses, without sleeping for each state.
      await act(async () => {
        await store.dispatch(bridgeSupportApi.endpoints.getProviderExtensionInstall.initiate({
          bridgeId: bridge.bridge_id, provider: 'codex', commandId: command!.command_id,
        }, { subscribe: false, forceRefetch: true }));
      });
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

test('ProviderSetupSurface installs in one click and waits for verified success even at 100 percent', async () => {
  const h = await surfaceHarness();
  try {
    await h.render();
    const button = h.query('provider-extension-install-btn-codex') as HTMLButtonElement;
    assert.equal(button.textContent, 'Install Extension');
    assert.equal(button.disabled, false);
    await h.click('provider-extension-install-btn-codex');
    const posts = () => h.requests.filter((r) => r.method === 'POST' && r.path.endsWith('/extension-install'));
    assert.equal(posts().length, 1);
    assert.deepEqual(posts()[0].body, {});
    assert.equal(button.disabled, true);
    assert.match(h.text(), /Waiting for the bridge/);
    await h.progress('accepted', 100);
    assert.equal(button.disabled, true);
    assert.doesNotMatch(h.text(), /installed and verified/);
    await h.progress('installing', 70, 'Verifying extension files');
    assert.match(h.text(), /Verifying extension files/);
    assert.equal(h.query('provider-extension-progress-codex')!.querySelector('progress')!.value, 70);
    await h.progress('succeeded', 100);
    assert.match(h.text(), /Extension installed and verified/);
    assert.equal(h.query('provider-extension-install-btn-codex'), null);
    assert.match(h.text(), /Extension installed v0\.4\.31/);
  } finally { await h.close(); }
});

test('outdated action displays target version, reports dispatch and terminal failures, and retries', async () => {
  const h = await surfaceHarness({ state: 'outdated' });
  try {
    await h.render();
    assert.match(h.query('provider-extension-install-btn-codex')!.textContent!, /Update to v0\.4\.31/);
    h.rejectPost('Another install is active');
    await h.click('provider-extension-install-btn-codex');
    assert.match(h.text(), /Another install is active/);
    assert.equal((h.query('provider-extension-install-btn-codex') as HTMLButtonElement).disabled, false);
    h.rejectPost('');
    await h.click('provider-extension-install-btn-codex');
    assert.doesNotMatch(h.text(), /Another install is active/);
    await h.progress('failed', 40, 'Provider CLI refused installation');
    assert.match(h.text(), /Provider CLI refused installation/);
    assert.equal(h.query('provider-extension-progress-codex')!.getAttribute('role'), 'alert');
    assert.equal((h.query('provider-extension-install-btn-codex') as HTMLButtonElement).disabled, false);
    await h.click('provider-extension-install-btn-codex');
    assert.equal((h.query('provider-extension-install-btn-codex') as HTMLButtonElement).disabled, true);
    assert.doesNotMatch(h.text(), /Provider CLI refused installation/);
    await h.progress('cancelled', 0);
    assert.match(h.text(), /installation cancelled/);
    assert.equal((h.query('provider-extension-install-btn-codex') as HTMLButtonElement).disabled, false);
  } finally { await h.close(); }
});

test('navigation recovers automatic install progress and blocks duplicate dispatch', async () => {
  const h = await surfaceHarness({ recover: true });
  try {
    await h.render();
    assert.match(h.text(), /Installing recovered command/);
    const button = h.query('provider-extension-install-btn-codex') as HTMLButtonElement;
    assert.equal(button.disabled, true);
    await h.click('provider-extension-install-btn-codex');
    assert.equal(h.requests.filter((r) => r.method === 'POST').length, 0);
    await h.progress('succeeded', 100);
    assert.match(h.text(), /installed and verified/);
  } finally { await h.close(); }
});

test('offline bridges disable installation and missing provider CLIs have no install action', async () => {
  for (const options of [{ online: false }, { cliPresent: false }]) {
    const h = await surfaceHarness(options);
    try {
      await h.render();
      const button = h.query('provider-extension-install-btn-codex') as HTMLButtonElement | null;
      if (options.online === false) {
        assert.equal(button?.disabled, true);
        assert.match(h.text(), /Connect this bridge/);
      } else assert.equal(button, null);
      assert.equal(h.requests.filter((r) => r.method === 'POST').length, 0);
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
