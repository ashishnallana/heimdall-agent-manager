import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { makeVaultStore } from './helpers/vaultEndpointHarness.ts';

const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
const { bridgeSupportApi } = await import('../src/ui/api/endpoints/bridgeSupport.ts');
const { providerSetupApi, refreshBridgeProviderCatalog } = await import('../src/ui/components/providers/providerSetupApi.ts');
const { normalizeModelCatalog, modelCatalogSummary } = await import('../src/ui/components/providers/modelCatalogStatus.ts');
const { resolvedFleetProviderModel } = await import('../src/ui/components/tasks/fleetSelection.ts');

const tick = () => new Promise(resolve => setTimeout(resolve, 30));
function response(data: any, status = 200): any {
  return { ok: status < 400, status, text: async () => JSON.stringify({ data }),
    json: async () => ({ data }), headers: { get: () => 'application/json' } };
}
function provider(models = ['saved-model'], metadata = {}): any {
  return { provider: 'codex', enabled: true, state: 'present', catalog_state: 'active',
    models: models.map(model_id => ({ model_id, label: model_id, state: 'active' })), ...metadata };
}

test('catalog metadata preserves empty results, old-bridge fallback and last-good failure text', () => {
  assert.match(modelCatalogSummary(normalizeModelCatalog({})), /Built-in model list/);
  assert.match(modelCatalogSummary({ models_has_snapshot: true, models_state: 'timeout' }), /keeping the last successful list/);
  assert.doesNotMatch(modelCatalogSummary({ models_has_snapshot: true, models_state: 'success' }), /Built-in|failed/);
  assert.deepEqual(resolvedFleetProviderModel({ provider: 'codex', model: 'saved-unavailable' }, [{ provider: 'codex', models: [] }]),
    { provider: 'codex', model: 'saved-unavailable' });
});

test('setup detection and enable changes never fetch models; explicit refresh serializes two stages without retry', async () => {
  const previous = globalThis.fetch;
  const calls: any[] = [];
  globalThis.fetch = async (_url, init: any) => { calls.push({ method: init.method, body: JSON.parse(init.body) }); return response({ providers: [provider([])] }); };
  try {
    const current: any = { bridge: { bridge_id: 'a' }, discovery: {}, providers: [provider()] };
    const detected = await providerSetupApi.discover(current);
    assert.deepEqual(calls.map(c => c.body), [{ stage: 'providers' }]);
    assert.deepEqual(detected.providers[0].models, [], 'valid empty lists never reintroduce seeds');
    await providerSetupApi.setEnabled(current, 'codex', true);
    assert.deepEqual(calls.map(c => c.body), [{ stage: 'providers' }, { enabled: true }]);
    calls.length = 0;
    await refreshBridgeProviderCatalog('a');
    assert.deepEqual(calls.map(c => c.body), [{ stage: 'providers' }, { stage: 'models' }]);
    calls.length = 0;
    globalThis.fetch = async (_url, init: any) => {
      calls.push(JSON.parse(init.body));
      if (calls.length === 2) throw new Error('offline');
      return response({});
    };
    await assert.rejects(refreshBridgeProviderCatalog('a'), /offline/);
    assert.equal(calls.length, 2, 'model failures do not retry either stage');
  } finally { globalThis.fetch = previous; }
});

test('real endpoint refresh invalidates only its bridge and retains the returned last-good list', async () => {
  const previous = globalThis.fetch;
  const store = await makeVaultStore();
  const calls: string[] = [];
  let refreshed = false;
  globalThis.fetch = async (input: any, init: any = {}) => {
    const url = new URL(String(input), 'http://localhost');
    calls.push((init.method || 'GET') + ' ' + url.pathname);
    if (init.method === 'POST') {
      if (JSON.parse(init.body).stage === 'models') refreshed = true;
      return response({ providers: [] });
    }
    const isA = url.pathname.includes('/a/');
    return response({ providers: [provider(isA ? (refreshed ? ['new-seed-absent-id'] : ['old-a']) : ['only-b'],
      { models_has_snapshot: true, models_source: 'codex_app_server', models_state: refreshed ? 'authentication_required' : 'success' })] });
  };
  const a = store.dispatch(bridgeSupportApi.endpoints.listBridgeProviders.initiate({ bridgeId: 'a' }));
  const b = store.dispatch(bridgeSupportApi.endpoints.listBridgeProviders.initiate({ bridgeId: 'b' }));
  try {
    await Promise.all([a, b]);
    assert.equal(calls.filter(c => c.startsWith('POST')).length, 0);
    await store.dispatch(bridgeSupportApi.endpoints.refreshBridgeModels.initiate({ bridgeId: 'a' })).unwrap();
    await tick();
    const select = (id: string) => bridgeSupportApi.endpoints.listBridgeProviders.select({ bridgeId: id })(store.getState()).data;
    assert.deepEqual(select('a').providers[0].models, ['new-seed-absent-id']);
    assert.equal(select('a').providers[0].models_state, 'authentication_required');
    assert.deepEqual(select('b').providers[0].models, ['only-b']);
    assert.equal(calls.filter(c => c === 'GET /api/v1/bridges/b/provider-status').length, 1);
  } finally { a.unsubscribe(); b.unsubscribe(); store.dispatch(heimdallApi.util.resetApiState()); globalThis.fetch = previous; }
});

test('mounted picker probes only on Refresh, preserves unavailable selections, and exposes new models', async () => {
  const { JSDOM } = await import('jsdom');
  const { Provider } = await import('react-redux');
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { default: RuntimeConfigurationOptions } = await import('../src/ui/components/chat/RuntimeConfigurationOptions.tsx');
  const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true });
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'KeyboardEvent', 'MutationObserver', 'getComputedStyle', 'IS_REACT_ACT_ENVIRONMENT', 'requestAnimationFrame', 'cancelAnimationFrame'];
  const previous: any = Object.fromEntries(keys.map(k => [k, (globalThis as any)[k]]));
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node, KeyboardEvent: dom.window.KeyboardEvent, MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window), IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: (cb: any) => setTimeout(() => cb(Date.now()), 0), cancelAnimationFrame: (id: any) => clearTimeout(id) });
  (dom.window as any).matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  dom.window.HTMLElement.prototype.scrollIntoView = () => {};
  // React DOM was loaded by endpoint imports before the document existed and
  // therefore selects its legacy input-event adapter in this headless harness.
  (dom.window.HTMLElement.prototype as any).attachEvent = () => {};
  (dom.window.HTMLElement.prototype as any).detachEvent = () => {};
  dom.window.requestAnimationFrame = globalThis.requestAnimationFrame;
  dom.window.cancelAnimationFrame = globalThis.cancelAnimationFrame;
  const prevFetch = globalThis.fetch;
  const stages: string[] = [];
  let rows = ['saved-model'];
  let configurationWire: any;
  globalThis.fetch = async (_url, init: any = {}) => {
    if (String(_url).endsWith('/reconfigurations')) {
      configurationWire = JSON.parse(init.body);
      return response({ operation_id: 'model-op', phase: 'queued' });
    }
    if (init.method === 'POST') {
      const stage = JSON.parse(init.body).stage; stages.push(stage);
      if (stage === 'models') rows = ['new-seed-absent-id'];
    }
    return response({ providers: [provider(rows, { models_has_snapshot: true, models_state: 'success' })] });
  };
  const store = await makeVaultStore();
  const root = createRoot(dom.window.document.getElementById('root')!);
  const changes: any[] = [];
  const tree = React.createElement(Provider, { store }, React.createElement(RuntimeConfigurationOptions, {
    bridges: [{ bridge_id: 'a', status: 'online', label: 'A', runtime_connected: true }],
    selection: { bridgeId: 'a', provider: 'codex', model: 'saved-model' }, onChange: (v: any) => changes.push(v), debugPrefix: 'models',
  }));
  try {
    await act(async () => { root.render(tree); await tick(); }); await act(tick);
    assert.deepEqual(stages, []);
    const button = dom.window.document.querySelector('[data-debug-id="models-model-refresh-btn"]') as HTMLElement;
    assert.ok(button);
    await act(async () => { button.click(); await tick(); }); await act(tick);
    assert.deepEqual(stages, ['providers', 'models']);
    assert.match(dom.window.document.body.textContent || '', /Selected model is unavailable/);
    assert.deepEqual(changes, [], 'refresh cannot silently change the saved model');
    const trigger = dom.window.document.querySelector('[data-debug-id="models-model-select-codex"]') as HTMLElement;
    await act(async () => { trigger.click(); await tick(); });
    const option = dom.window.document.querySelector('[data-debug-id="models-model-select-codex-option-new-seed-absent-id"]') as HTMLElement;
    assert.ok(option, 'newly discovered model is selectable');
    await act(async () => { option.click(); await tick(); });
    assert.deepEqual(changes, [{ bridgeId: 'a', provider: 'codex', model: 'new-seed-absent-id' }]);
    const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
    await act(async () => {
      await store.dispatch(agentsApi.endpoints.applyInstanceConfiguration.initiate({
        instanceId: 'inst-model', bridge_id: changes[0].bridgeId, project_id: '',
        provider: changes[0].provider, model: changes[0].model,
        expected_revision: 0, idempotency_key: 'model-test',
      })).unwrap();
    });
    assert.equal(configurationWire.model, 'new-seed-absent-id', 'selected ID reaches the actual reconfiguration request unchanged');
    const cached = bridgeSupportApi.endpoints.listBridgeProviders.select({ bridgeId: 'a' })(store.getState()).data;
    assert.deepEqual(cached.providers[0].models, ['new-seed-absent-id']);
    assert.deepEqual(resolvedFleetProviderModel({ provider: 'codex', model: '' }, cached.providers),
      { provider: 'codex', model: 'new-seed-absent-id' });

    // Enrollment automatically detects binaries, then waits for the explicitly
    // labelled enable-and-refresh action before requesting any model metadata.
    const { ProviderSetupSurface } = await import('../src/ui/components/providers/ProviderSetupSurface.tsx');
    const enrollmentStages: string[] = [];
    let enabled = false;
    let applied = 0;
    globalThis.fetch = async (input: any, init: any = {}) => {
      const path = new URL(String(input), 'http://localhost').pathname;
      if (path === '/api/v1/bridges') return response({ bridges: [{ bridge_id: 'c', status: 'online', label: 'C' }] });
      if (init.method === 'PUT') enabled = JSON.parse(init.body).enabled;
      if (init.method === 'POST') {
        const stage = JSON.parse(init.body).stage;
        enrollmentStages.push(stage);
        if (stage === 'models') assert.equal(enabled, true, 'enablement is saved before stage two');
      }
      return response({ providers: [{ ...provider(), enabled }] });
    };
    await act(async () => { root.render(React.createElement(Provider, { store }, React.createElement(ProviderSetupSurface, {
      bridgeId: 'c', mode: 'enrollment', variant: 'compact', onApply: () => { applied += 1; },
    }))); await tick(); });
    await act(tick);
    assert.deepEqual(enrollmentStages, ['providers'], 'enrollment mount never probes models');
    const apply = dom.window.document.querySelector('[data-debug-id="provider-setup-apply-btn"]') as HTMLElement;
    assert.match(apply.textContent || '', /refresh models/);
    await act(async () => { apply.click(); await tick(); }); await act(tick);
    assert.deepEqual(enrollmentStages, ['providers', 'models']);
    assert.equal(applied, 1);
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    // RTK batches subscription synchronization on a 500ms timer, even after unmount.
    // Drain it before restoring the browser globals its notifier captured.
    await act(async () => { await new Promise(resolve => setTimeout(resolve, 600)); });
    globalThis.fetch = prevFetch;
    for (const k of keys) (globalThis as any)[k] = previous[k];
    dom.window.close();
  }
});
