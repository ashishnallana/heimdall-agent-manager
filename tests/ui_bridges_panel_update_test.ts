// REQ-BUPD-3: Unit Tests for UI BridgesPanel Version Badges, Update Notifications, and Trigger Modal
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_bridges_panel_update_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';

import {
  formatBridgeVersion,
  formatLatestVersion,
  isBridgeUpdating,
  isUpdateUnavailableForTarget,
  updateAvailabilityLabel,
  shouldWarnActiveTasks,
  getActiveTaskCount,
} from '../src/ui/components/settings/bridgeUpdate.ts';

// Dynamic imports run after the harness registers its Vite-style module resolver.
const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
const { default: BridgesPanel } = await import('../src/ui/components/settings/BridgesPanel.tsx');

// ---------------------------------------------------------------------------
// 1. Version Formatting and Update Predicates (REQ-BUPD-3)
// ---------------------------------------------------------------------------

test('formatBridgeVersion correctly formats version and commit sha variants', () => {
  assert.equal(
    formatBridgeVersion({ version: '0.1.0', commit_sha: 'a57c83d9' }),
    'v0.1.0 (a57c83d9)',
    'Should format full version with commit sha in parentheses',
  );
  assert.equal(
    formatBridgeVersion({ version: '0.1.0' }),
    'v0.1.0',
    'Should format version without commit sha',
  );
  assert.equal(
    formatBridgeVersion({ commit_sha: 'a57c83d9' }),
    'a57c83d9',
    'Should format commit sha without version prefix',
  );
  assert.equal(
    formatBridgeVersion({ commit_sha: 'a57c83d912345678' }),
    'a57c83d9',
    'Should slice commit sha to 8 characters',
  );
  assert.equal(
    formatBridgeVersion(null),
    '',
    'Should return empty string for null bridge',
  );
  assert.equal(
    formatBridgeVersion(undefined),
    '',
    'Should return empty string for undefined bridge',
  );
  assert.equal(
    formatBridgeVersion({}),
    '',
    'Should return empty string when neither version nor commit is present',
  );
});

test('formatLatestVersion correctly formats latest version indicator', () => {
  assert.equal(
    formatLatestVersion({ latest_version: '0.2.0', latest_commit_sha: '796bfb57' }),
    'v0.2.0 (796bfb57)',
    'Should format latest version with commit sha',
  );
  assert.equal(
    formatLatestVersion({ latest_version: '0.2.0' }),
    'v0.2.0',
    'Should format latest version without commit sha',
  );
  assert.equal(
    formatLatestVersion({}),
    'latest',
    'Should default to latest when no version is provided',
  );
  assert.equal(
    formatLatestVersion(null),
    'latest',
    'Should default to latest for null bridge',
  );
});

// REQ-T13-4: a release without a bundle for the bridge's target (e.g. a
// termux-arm64 bridge on a release that only ships linux-arm64) is shown as
// "not available for <target>", never as an installable update.
test('update availability copy names the target when no bundle exists for it', () => {
  const termux = { update_available: true, update_artifact_available: false, latest_version: '0.3.30', target: 'termux-arm64' };
  assert.equal(isUpdateUnavailableForTarget(termux), true);
  assert.equal(updateAvailabilityLabel(termux), 'v0.3.30 not available for termux-arm64');
  assert.equal(
    updateAvailabilityLabel({ ...termux, target: '' }),
    'v0.3.30 not available for this target',
  );
  const installable = { ...termux, update_artifact_available: true };
  assert.equal(isUpdateUnavailableForTarget(installable), false);
  assert.equal(updateAvailabilityLabel(installable), 'Update available: v0.3.30');
  // Hubs that predate the field omit it: keep the existing behaviour.
  assert.equal(isUpdateUnavailableForTarget({ update_available: true }), false);
  assert.equal(isUpdateUnavailableForTarget({ update_available: false, update_artifact_available: false }), false);
  assert.equal(isUpdateUnavailableForTarget(null), false);
});

test('isBridgeUpdating identifies active update stages', () => {
  assert.equal(isBridgeUpdating({ update_status: 'downloading' }), true);
  assert.equal(isBridgeUpdating({ update_status: 'validating' }), true);
  assert.equal(isBridgeUpdating({ update_status: 'restarting' }), true);

  assert.equal(isBridgeUpdating({ update_status: 'idle' }), false);
  assert.equal(isBridgeUpdating({ update_status: 'healthy' }), false);
  assert.equal(isBridgeUpdating({ update_status: 'complete' }), false);
  assert.equal(isBridgeUpdating({ update_status: 'failed' }), false);
  assert.equal(isBridgeUpdating({}), false);
  assert.equal(isBridgeUpdating(null), false);
});

test('shouldWarnActiveTasks and getActiveTaskCount detect running agent instances', () => {
  assert.equal(shouldWarnActiveTasks({ active_instance_count: 3 }), true);
  assert.equal(getActiveTaskCount({ active_instance_count: 3 }), 3);

  assert.equal(shouldWarnActiveTasks({ instance_count: 1 }), true);
  assert.equal(getActiveTaskCount({ instance_count: 1 }), 1);

  assert.equal(shouldWarnActiveTasks({ active_instance_count: 0 }), false);
  assert.equal(getActiveTaskCount({ active_instance_count: 0 }), 0);

  assert.equal(shouldWarnActiveTasks({}), false);
  assert.equal(getActiveTaskCount({}), 0);
});


// ---------------------------------------------------------------------------
// 2. Web BridgesPanel (REQ-ENR-11 / F29): no window.odinApi.bridgeManager, so
//    there is no "This machine" card and no Uninstall / Revoke / Archive: each
//    installed bridge offers Update (and Rename) only.
// ---------------------------------------------------------------------------

test('web BridgesPanel lists installed bridges with Update only (no This machine card, uninstall or archive)', async () => {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.example.test/', pretendToBeVisual: true });
  const saved = new Map<string, PropertyDescriptor | undefined>();
  for (const [key, value] of Object.entries({
    window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
  }
  assert.equal((dom.window as any).odinApi, undefined, 'web harness has no Electron bridge manager');
  const previousFetch = globalThis.fetch;
  const requests: Array<{ path: string; method: string }> = [];
  const bridges = [
    { bridge_id: 'bridge-online', label: 'Online bridge', status: 'online', runtime_connected: true,
      version: '0.4.30', latest_version: '0.4.31', update_available: true, update_artifact_available: true },
    { bridge_id: 'bridge-offline', label: 'Offline bridge', status: 'offline', version: '0.4.30' },
  ];
  globalThis.fetch = (async (input: any, init: any = {}) => {
    const path = new URL(String(input), 'https://hub.example.test').pathname;
    const method = init.method || 'GET';
    requests.push({ path, method });
    if (path === '/api/v1/bridges') return Response.json({ data: bridges });
    if (path.endsWith('/provider-status')) return Response.json({ data: { providers: [], extension_commands: [] } });
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
  const doc = dom.window.document;
  const query = (id: string) => doc.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
  try {
    await act(async () => {
      root.render(React.createElement(Provider, { store, children: React.createElement(BridgesPanel) }));
    });
    assert.ok(query('settings-bridges-panel'));
    assert.equal(query('settings-this-machine-card'), null, 'no This machine card on the web');
    assert.equal(doc.querySelector('[data-debug-id^="settings-bridge-wizard"]'), null);
    assert.match(query('settings-bridges-list')!.textContent || '', /Installed bridges \(2\)/);
    for (const bridge of bridges) {
      const id = bridge.bridge_id;
      assert.ok(query(`settings-bridge-row-${id}`), `row for ${id}`);
      assert.ok(query(`settings-bridge-update-btn-${id}`), `Update for ${id}`);
      assert.ok(query(`settings-bridge-rename-btn-${id}`), `Rename for ${id}`);
    }
    assert.equal(doc.querySelector('[data-debug-id^="settings-bridge-uninstall-"]'), null, 'no Uninstall / Revoke on the web');
    assert.equal(doc.querySelector('[data-debug-id^="settings-bridge-archive-"]'), null, 'Archive was removed');
    assert.equal(requests.filter((r) => r.method !== 'GET').length, 0);
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

// ---------------------------------------------------------------------------
// 3. Electron "This machine" card: Retry repeats the operation that failed
//    (with its options), and a non-setup failure reads as that operation's own
//    failure, not as a wizard step.
// ---------------------------------------------------------------------------

test('ThisMachineCard retries a failed Re-enroll as Re-enroll and labels the failure by operation', async () => {
  const { default: ThisMachineCard } = await import('../src/ui/components/settings/ThisMachineCard.tsx');
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.example.test/', pretendToBeVisual: true });
  const saved = new Map<string, PropertyDescriptor | undefined>();
  for (const [key, value] of Object.entries({
    window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
  }
  const runs: Array<{ kind: string; options: any }> = [];
  let listener: ((event: any) => void) | null = null;
  const manager: any = {
    getConfig: async () => ({ ok: true, supported: true, platform: 'linux', hubUrl: 'https://hub.example.test', defaultHubUrl: 'https://hub.example.test', bundledVersion: '' }),
    setHubUrl: async () => ({ ok: true }),
    getStatus: async () => ({ supported: true, busy: false, operation: '', installed: true, state: 'connected', bridge_id: 'brg_this', error: '' }),
    list: async () => ({ ok: true, profiles: [] }),
    run: async (kind: string, _target: any, options: any) => { runs.push({ kind, options }); return { ok: true }; },
    cancel: async () => ({ ok: true }),
    openLog: async () => ({ ok: true }),
    onEvent: (callback: (event: any) => void) => { listener = callback; return () => { listener = null; }; },
  };
  const root = createRoot(dom.window.document.getElementById('root')!);
  const doc = dom.window.document;
  const query = (id: string) => doc.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
  const click = async (id: string) => {
    const element = query(id);
    assert.ok(element, `${id} is rendered`);
    await act(async () => { element!.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true })); });
  };
  try {
    await act(async () => { root.render(React.createElement(ThisMachineCard, { manager })); });
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)); });
    await click('settings-this-machine-reenroll-btn');
    await click('settings-this-machine-confirm-ok');
    assert.deepEqual(runs, [{ kind: 'reenroll', options: { bridgeId: 'brg_this', inAppApproval: true } }]);
    await act(async () => { listener!({ type: 'error', message: 'enrollment was not approved', step: 'enroll' }); });
    assert.match(query('settings-bridge-wizard-result')!.textContent || '', /Re-enrollment failed: enrollment was not approved/);
    assert.doesNotMatch(query('settings-bridge-wizard-result')!.textContent || '', /Failed at/);
    assert.equal(query('settings-bridge-wizard'), null, 'the setup wizard is not shown for a re-enroll');
    await click('settings-bridge-wizard-retry');
    assert.deepEqual(runs[1], { kind: 'reenroll', options: { bridgeId: 'brg_this', inAppApproval: true } }, 'Retry repeats the re-enroll, not an update');
  } finally {
    await act(async () => root.unmount());
    dom.window.close();
    for (const [key, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete (globalThis as any)[key];
    }
  }
});
