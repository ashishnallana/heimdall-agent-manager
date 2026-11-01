import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { registerHooks } from 'node:module';
import React from 'react';
import { makeVaultStore, unlockVault, lockVaultFully } from './helpers/vaultEndpointHarness.ts';
const {
  providerProfilesApi,
  profileEnvelope,
  generateProfileId,
  configDirectoryMode,
  profileIdentityError,
  encodeProfileArgs,
  decodeProfileArgs,
  environmentForSave,
} = await import('../src/ui/components/providers/providerProfiles.ts');
const { decryptVaultText, encryptVaultText } = await import('../src/ui/utils/vaultCrypto.ts');
const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
const { sealVaultEnvelope } = await import('../src/ui/utils/vaultCrypto.ts');
const { importRawKeyHex } = await import('./helpers/vaultTestKeyring.ts');
const {
  fleetApplyRequests,
  changedFleetEntries,
  providerModelModified,
  resolvedFleetProviderModel,
} = await import('../src/ui/components/tasks/fleetSelection.ts');
const response = (data: any, status = 200): any => ({
  ok: status < 400,
  status,
  text: async () => JSON.stringify({ data }),
  headers: { get: () => 'application/json' },
});
const keyHex = '11'.repeat(32);
const profile = (id = 'claude_work'): any => ({
  profile_id: id,
  provider: 'claude',
  label_enc: '',
  accent: '#a1b2c3',
  enabled: true,
  environment: [{ name: 'API_TOKEN', value: '', sensitive: true, value_redacted: true }],
  config: { config_dir: '/private/account', launch_args: '"--name" "two words"' },
});

test('wizard identity is random, bounded, collision safe and independent of its label', () => {
  const id = generateProfileId('claude', [], Uint8Array.of(1, 2, 3, 4));
  assert.equal(id, 'claude_bcde');
  assert.equal(generateProfileId('claude', [id], Uint8Array.of(1, 2, 3, 4)), id + '_2');
  assert.equal(profileIdentityError(id, 'Work account', '#a1b2c3', [], ['claude']), '');
  for (const invalid of ['Claude', 'a'.repeat(33), '1account', 'claude'])
    assert.ok(profileIdentityError(invalid, 'Work', '#a1b2c3', [], ['claude']));
  assert.ok(profileIdentityError(id, '', '#a1b2c3', [], []));
  assert.ok(profileIdentityError(id, 'Work', 'red', [], []));
});

test('argument rows retain literals and secret editing distinguishes keep, replace and clear', () => {
  const args = ['--name', 'two words', 'C:\\work\\file', 'a"b', '$HOME', "a'b", 'back\\$literal'];
  assert.deepEqual(decodeProfileArgs(encodeProfileArgs(args)), args);
  assert.throws(() => encodeProfileArgs(Array(33).fill('x')));
  assert.throws(() => encodeProfileArgs(['é'.repeat(600)]));
  const stored = profile().environment;
  assert.equal(environmentForSave(stored)[0].keep, true);
  assert.equal(
    environmentForSave([{ ...stored[0], value: 'replacement' }])[0].value_redacted,
    false,
  );
  assert.equal(environmentForSave([{ ...stored[0], value_redacted: false }])[0].keep, false);
  assert.throws(() => environmentForSave([{ ...stored[0], sensitive: false }]));
  assert.throws(() => environmentForSave([{ name: 'HOME', value: '/tmp', sensitive: false }]));
  assert.throws(() => environmentForSave([...stored, ...stored]));
});

test('UI encoder shares the bridge golden vector exactly', async () => {
  const source = fs.readFileSync(
    new URL('../src/bridge/provider_profiles_test.odin', import.meta.url),
    'utf8',
  );
  const plain = source.match(/PROFILE_GOLDEN_PLAIN :: `([^`]+)`/)![1];
  const expected = source.match(/PROFILE_GOLDEN_TOKEN :: "([^"]+)"/)![1];
  const wire = JSON.parse(plain);
  assert.equal(
    JSON.stringify(
      profileEnvelope(
        'upsert',
        wire.bridge_id,
        wire.boot_id,
        wire.profile_id,
        wire.body,
        wire.ts,
        wire.nonce,
      ),
    ),
    plain,
  );
  const key = await importRawKeyHex(keyHex);
  assert.equal(
    await sealVaultEnvelope(
      new TextEncoder().encode(plain),
      key,
      'c8f193e678e762f9',
      1,
      Uint8Array.from({ length: 12 }, (_, i) => i),
    ),
    expected,
  );
});

test('real profile API seals every operation and authenticates response nonce; stale boot retries once', async () => {
  const store = await makeVaultStore();
  await unlockVault(store, keyHex);
  const oldFetch = globalThis.fetch;
  const calls: any[] = [];
  let stale = true;
  let badNonce = false;
  globalThis.fetch = async (url: any, init: any = {}) => {
    if (String(url).endsWith('/public-key')) return response({ unseal_boot_id: 'boot_test' });
    const body = JSON.parse(init.body);
    assert.deepEqual(Object.keys(body), ['sealed']);
    assert.ok(!init.body.includes('/private/account') && !init.body.includes('replacement'));
    const opened = JSON.parse(await decryptVaultText(body.sealed));
    calls.push({ method: init.method, url: String(url), opened });
    assert.equal(opened.bridge_id, 'bridge_test');
    assert.equal(opened.boot_id, 'boot_test');
    if (stale) {
      stale = false;
      return response({ ok: false, error: 'profile_stale_boot' });
    }
    return response({
      ok: true,
      sealed:
        opened.op === 'get'
          ? await encryptVaultText(
              JSON.stringify({ nonce: badNonce ? 'another' : opened.nonce, profiles: [profile()] }),
            )
          : '',
    });
  };
  try {
    const loaded = await providerProfilesApi.operate('bridge_test', 'claude_work', 'get');
    assert.equal(loaded?.config.config_dir, '/private/account');
    assert.equal(calls.length, 2);
    assert.notEqual(calls[0].opened.nonce, calls[1].opened.nonce);
    await providerProfilesApi.operate('bridge_test', 'claude_work', 'upsert', {
      ...profile(),
      environment: [{ name: 'TOKEN', value: 'replacement', sensitive: true }],
    });
    await providerProfilesApi.operate('bridge_test', 'claude_work', 'reset');
    await providerProfilesApi.operate('bridge_test', 'claude_work', 'remove');
    assert.deepEqual(
      calls.map((c) => c.method),
      ['POST', 'POST', 'PUT', 'POST', 'DELETE'],
    );
    badNonce = true;
    await assert.rejects(
      providerProfilesApi.operate('bridge_test', 'claude_work', 'get'),
      /did not match/,
    );
    await lockVaultFully(store);
    await assert.rejects(
      providerProfilesApi.operate('bridge_test', 'claude_work', 'get'),
      /Unlock/,
    );
  } finally {
    globalThis.fetch = oldFetch;
    await lockVaultFully(store);
    store.dispatch(heimdallApi.util.resetApiState());
  }
});

test('fleet same-driver account change survives change detection, restart decision and actual wire', async () => {
  const original = [
    {
      agent_id: 'worker',
      capacity: 1,
      provider: 'claude',
      provider_profile: 'claude_one',
      model: 'same',
      bridge_models: {},
    },
  ];
  const draft = { worker: { provider: 'claude', provider_profile: 'claude_two', model: 'same' } };
  assert.equal(providerModelModified(original, 'worker', draft), true);
  const changed = changedFleetEntries(original, { worker: 1 }, draft);
  assert.equal(changed[0]?.provider_profile, 'claude_two');
  const request = fleetApplyRequests(changed, changed)[0];
  assert.equal(request.provider_profile, 'claude_two');
  assert.equal(request.restartLiveInstances, true);
  assert.deepEqual(
    resolvedFleetProviderModel(
      { provider: 'claude', provider_profile: 'claude_missing', model: '' },
      [{ provider: 'claude', profile_id: 'claude_one', models: ['same'] }],
    ),
    { provider: 'claude', provider_profile: 'claude_missing', model: '' },
  );
  const store = await makeVaultStore();
  const oldFetch = globalThis.fetch;
  let sent: any;
  globalThis.fetch = async (_u: any, init: any) => {
    sent = JSON.parse(init.body);
    return response({ agent_id: 'worker' });
  };
  try {
    const { taskChainsApi } = await import('../src/ui/api/endpoints/taskChains.ts');
    await store
      .dispatch(
        taskChainsApi.endpoints.updateTaskChainFleet.initiate({ chainId: 'chain', ...request }),
      )
      .unwrap();
    assert.equal(sent.provider, 'claude');
    assert.equal(sent.provider_profile, 'claude_two');
  } finally {
    globalThis.fetch = oldFetch;
    store.dispatch(heimdallApi.util.resetApiState());
  }
});

test('mounted wizard validates identity, environment never reveals stored secrets, picker selects exact account', async () => {
  const { JSDOM } = await import('jsdom');
  const { Provider } = await import('react-redux');
  const { createRoot } = await import('react-dom/client');
  const { Simulate } = await import('react-dom/test-utils');
  const { act } = await import('react');
  // Keep real modal/API/lifecycle behavior; isolate the already-covered xterm
  // transport so this test can observe the runtime phase passed to the pane.
  const paneHook = registerHooks({
    load(url: string, context: any, next: any) {
      if (url.endsWith('/chat/AgentPaneComposerPanel.tsx'))
        return {
          format: 'module',
          shortCircuit: true,
          source:
            "import React from 'react'; export default function Pane(p) { return React.createElement('div', {'data-debug-id':'test-terminal-pane','data-runtime':p.runtimeStatus}); }",
        };
      return next(url, context);
    },
  });
  const { default: Surface, ProfileRuntimeEditor } =
    await import('../src/ui/components/providers/ProviderProfilesSurface.tsx');
  const { default: Picker } =
    await import('../src/ui/components/chat/RuntimeConfigurationOptions.tsx');
  const dom = new JSDOM('<!doctype html><div id="root"></div>', {
    url: 'http://localhost/',
    pretendToBeVisual: true,
  });
  const keys = [
    'window',
    'document',
    'HTMLElement',
    'Element',
    'Node',
    'KeyboardEvent',
    'MutationObserver',
    'getComputedStyle',
    'IS_REACT_ACT_ENVIRONMENT',
    'requestAnimationFrame',
    'cancelAnimationFrame',
  ];
  const old: any = Object.fromEntries(keys.map((k) => [k, (globalThis as any)[k]]));
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    KeyboardEvent: dom.window.KeyboardEvent,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: (cb: any) => setTimeout(cb, 0),
    cancelAnimationFrame: clearTimeout,
  });
  (dom.window as any).matchMedia = () => ({
    matches: false,
    addEventListener() {},
    removeEventListener() {},
  });
  dom.window.HTMLElement.prototype.scrollIntoView = () => {};
  const store = await makeVaultStore();
  await unlockVault(store, keyHex);
  const previousFetch = globalThis.fetch;
  const status = ['claude', 'claude_one', 'claude_two'].map((id) => ({
    provider: 'claude',
    profile_id: id,
    enabled: true,
    state: 'present',
    catalog_state: 'active',
    models: [
      { model_id: 'same', state: 'active', label: 'Default' },
      { model_id: 'alternate', state: 'active', label: 'Alternate' },
      { model_id: 'retired', state: 'deprecated', label: 'Retired' },
    ],
  }));
  let savedProfile: any;
  const discoveryRequests: any[] = [];
  const testRequests: any[] = [];
  let testState = 'awaiting_validation';
  globalThis.fetch = async (url: any, init: any = {}) => {
    if (String(url).includes('/provider-tests')) {
      testRequests.push({
        url: String(url),
        method: init.method || 'GET',
        body: init.body ? JSON.parse(init.body) : undefined,
      });
      if (init.method === 'POST' && String(url).endsWith('/provider-tests'))
        testState = 'awaiting_validation';
      if (String(url).endsWith('/validate')) testState = 'stopped';
      return response({
        run_id: 'run_profile',
        agent_instance_id: 'inst_profile',
        state: testState,
      });
    }
    if (String(url).endsWith('/providers/discover')) discoveryRequests.push(JSON.parse(init.body));
    if (String(url).endsWith('/public-key')) return response({ unseal_boot_id: 'boot_mounted' });
    if (init.body && String(url).includes('/provider-profiles/')) {
      const wire = JSON.parse(await decryptVaultText(JSON.parse(init.body).sealed));
      if (wire.op === 'upsert') {
        assert.ok(!init.body.includes('secret-after-save'));
        savedProfile = { ...wire.body, profile_id: wire.profile_id };
        if (!status.some((p) => p.profile_id === wire.profile_id))
          status.push({ ...status[0], profile_id: wire.profile_id });
        savedProfile.config.config_dir = (savedProfile.config.config_dir || '').replace(
          /^~/,
          '/bridge/home',
        );
        savedProfile.environment = savedProfile.environment.map((e: any) => ({
          ...e,
          value: '',
          value_redacted: e.sensitive && !!e.value,
        }));
        return response({ ok: true });
      }
      if (wire.op === 'get')
        return response({
          ok: true,
          sealed: await encryptVaultText(
            JSON.stringify({ nonce: wire.nonce, profiles: [savedProfile] }),
          ),
        });
    }
    return String(url).endsWith('/provider-profiles')
      ? response({ profiles: status })
      : String(url).endsWith('/bridges')
        ? response({ bridges: [] })
        : response({ providers: status });
  };
  const root = createRoot(dom.window.document.getElementById('root')!);
  const tick = () => new Promise((r) => setTimeout(r, 25));
  const q = (id: string): any => dom.window.document.querySelector('[data-debug-id="' + id + '"]');
  const click = async (id: string) => {
    assert.ok(q(id), id);
    await act(async () => {
      q(id).click();
      await tick();
    });
  };
  const change = async (id: string, value: string) => {
    await act(async () => {
      Simulate.change(q(id), { target: { value } } as any);
    });
  };
  try {
    await act(async () => {
      root.render(
        React.createElement(
          Provider,
          { store },
          React.createElement(Surface, {
            bridge: { bridge_id: 'b', status: 'online', vault_status: 'unlocked' },
          }),
        ),
      );
      await tick();
    });
    await act(tick);
    assert.ok(q('profiles-list'), 'bridge opens on its provider list');
    await click('profile-add');
    assert.equal(q('profiles-list'), null, 'editor has no adjacent provider switcher');
    assert.equal(q('profile-wizard-step').querySelector('[aria-current="step"]')?.textContent, '1ProviderCurrent step');
    assert.equal(q('profile-wizard-step').querySelectorAll('li').length, 3);
    await click('profile-next');
    assert.match(q('profile-id').value, /^claude_[a-z2-7]{4}$/);
    await click('profile-next');
    assert.match(dom.window.document.body.textContent || '', /Enter a label/);
    await change('profile-label', 'Work account');
    await click('profile-next');
    assert.ok(q('profile-env-add'));
    assert.equal(q('profile-config-dir-mode').value, 'inherit');
    await change('profile-config-dir-mode', 'custom');
    await click('profile-save');
    assert.equal(savedProfile, undefined, 'empty custom directory cannot be saved as inherit');
    await change('profile-config-dir-mode', 'random');
    const wizardRandomPath = q('profile-config-config_dir').value;
    assert.equal(configDirectoryMode(wizardRandomPath), 'random');
    assert.equal(q('profile-config-config_dir').readOnly, true);

    await click('profile-env-add');
    await change('profile-env-name-0', 'WORK_TOKEN');
    await change('profile-env-value-0', 'secret-after-save');
    assert.equal(q('profile-enabled').textContent, 'Disable profile');
    await click('profile-enabled');
    assert.equal(q('profile-enabled').textContent, 'Enable profile');
    await click('profile-save');
    await act(tick);
    assert.ok(savedProfile, 'wizard saved through the real sealed API');
    assert.equal(savedProfile.enabled, false, 'prominent enablement action persists through the sealed save');
    assert.equal(savedProfile.config.config_dir, wizardRandomPath.replace(/^~/, '/bridge/home'));
    assert.equal(
      q('profile-config-dir-mode').value,
      'random',
      'resolved saved path reopens without generating',
    );
    assert.equal(q('profile-config-config_dir').value, savedProfile.config.config_dir);

    assert.equal(
      q('profile-env-value-0').value,
      '',
      'replacement secret leaves component state after save',
    );
    assert.match(q('profile-env-value-0').placeholder, /Stored secret/);
    assert.ok(!dom.window.document.body.innerHTML.includes('secret-after-save'));
    assert.equal(q('profiles-list'), null, 'saved editor remains full width');
    await click('profile-enabled');
    await click('profile-save');
    await act(tick);
    assert.equal(savedProfile.enabled, true, 'enable action restores launch availability after save');
    await click('profile-discover');
    assert.deepEqual(discoveryRequests, [
      { stage: 'providers', providers: ['claude'], profile_id: savedProfile.profile_id },
    ]);
    await change('profile-config-dir-mode', 'custom');
    await change('profile-config-config_dir', '/private/custom');
    await click('profile-save');
    await act(tick);
    assert.equal(savedProfile.config.config_dir, '/private/custom');
    await change('profile-config-dir-mode', 'inherit');
    await click('profile-save');
    await act(tick);
    assert.equal(
      savedProfile.config.config_dir,
      '',
      'inherit clears stored override through sealed save',
    );
    assert.equal(q('profile-test').disabled, false);
    assert.equal(q('profile-test-model').options.length, 2, 'only active models are testable');
    await change('profile-config-dir-mode', 'custom');
    await change('profile-config-config_dir', '/unsaved');
    assert.equal(q('profile-test').disabled, true, 'must save profile edits before testing');
    await click('profile-test');
    assert.equal(testRequests.length, 0);
    await change('profile-config-dir-mode', 'inherit');
    await change('profile-test-model', 'alternate');
    await click('profile-test');
    await act(tick);
    assert.equal(testRequests[0].method, 'POST');
    assert.deepEqual(testRequests[0].body, {
      provider: 'claude',
      model: 'alternate',
      profile_id: savedProfile.profile_id,
    });
    assert.equal(
      q('test-terminal-pane').getAttribute('data-runtime'),
      'running',
      'awaiting validation keeps terminal live',
    );
    assert.match(q('provider-test-input-help').textContent, /plan permits terminal input/);
    await click('provider-test-validate-btn');
    assert.ok(
      testRequests.some((r) => r.url.endsWith('/run_profile/validate') && r.method === 'POST'),
    );
    assert.equal(q('test-terminal-pane').getAttribute('data-runtime'), 'stopped');
    await click('provider-test-done-btn');
    assert.equal(q('provider-test-run-modal'), null);
    await click('profile-test');
    await act(tick);
    await click('provider-test-run-modal-close-btn');
    assert.ok(testRequests.some((r) => r.url.endsWith('/run_profile') && r.method === 'DELETE'));
    assert.equal(q('provider-test-run-modal'), null);
    let latest = profile();
    function EnvHarness() {
      const [p, setP] = React.useState(latest);
      return React.createElement(ProfileRuntimeEditor, {
        profile: p,
        onChange: (next: any) => {
          latest = next;
          setP(next);
        },
      });
    }
    await act(async () => root.render(React.createElement(EnvHarness)));
    assert.equal(q('profile-config-dir-mode').value, 'custom');
    await change('profile-config-dir-mode', 'random');
    const stableRandomPath = latest.config.config_dir;
    await change('profile-env-value-0', 'rerender');
    assert.equal(latest.config.config_dir, stableRandomPath, 'other edits do not reroll');
    await change('profile-env-value-0', '');
    await change('profile-config-dir-mode', 'custom');
    assert.equal(latest.config.config_dir, '/private/account', 'custom draft is retained');
    await change('profile-config-config_dir', '/private/other');
    await change('profile-config-dir-mode', 'inherit');
    assert.equal(latest.config.config_dir, '');
    await change('profile-config-dir-mode', 'random');
    assert.equal(latest.config.config_dir, stableRandomPath, 'mode switches do not reroll');
    await change('profile-config-dir-mode', 'custom');
    assert.equal(latest.config.config_dir, '/private/other');
    assert.equal(q('profile-env-value-0').value, '');
    assert.match(q('profile-env-value-0').placeholder, /Stored secret/);
    assert.equal(q('profile-env-sensitive-0').disabled, true);
    await change('profile-env-value-0', 'replacement');
    assert.equal(environmentForSave(latest.environment)[0].value_redacted, false);
    await change('profile-env-value-0', '');
    assert.equal(environmentForSave(latest.environment)[0].keep, true);
    await click('profile-env-clear-0');
    assert.equal(environmentForSave(latest.environment)[0].keep, false);
    await click('profile-env-add');
    assert.equal(latest.environment[1].sensitive, true);
    await click('profile-arg-add');
    assert.equal(q('profile-arg-2').value, '');
    await change('profile-arg-2', 'space literal');
    assert.deepEqual(decodeProfileArgs(latest.config.launch_args), [
      '--name',
      'two words',
      'space literal',
    ]);
    await act(async () =>
      root.render(
        React.createElement(ProfileRuntimeEditor, {
          profile: latest,
          onChange() {},
          disabled: true,
        }),
      ),
    );
    assert.equal(q('profile-config-dir-mode').matches(':disabled'), true);
    assert.equal(q('profile-config-config_dir').matches(':disabled'), true);
    const picks: any[] = [];
    await act(async () => {
      root.render(
        React.createElement(
          Provider,
          { store },
          React.createElement(Picker, {
            bridges: [{ bridge_id: 'b', status: 'online' }],
            selection: {
              bridgeId: 'b',
              provider: 'claude',
              providerProfile: 'claude_one',
              model: 'same',
            },
            onChange: (p: any) => picks.push(p),
            debugPrefix: 'accounts',
          }),
        ),
      );
      await tick();
    });
    await act(tick);
    await click('accounts-provider-option-claude_two');
    assert.deepEqual(picks, [
      { bridgeId: 'b', provider: 'claude', providerProfile: 'claude_two', model: 'same' },
    ]);
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    await lockVaultFully(store);
    await act(async () => {
      await new Promise((r) => setTimeout(r, 600));
    });
    globalThis.fetch = previousFetch;
    paneHook.deregister();
    for (const key of keys) (globalThis as any)[key] = old[key];
    dom.window.close();
  }
});

test('new conversations, reconfiguration and extension commands carry the chosen account on the wire', async () => {
  const store = await makeVaultStore();
  await unlockVault(store, keyHex);
  const previousFetch = globalThis.fetch;
  const requests: any[] = [];
  globalThis.fetch = async (url: any, init: any = {}) => {
    requests.push({ url: String(url), body: init.body ? JSON.parse(init.body) : undefined });
    return response({});
  };
  try {
    const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
    const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
    const { bridgeSupportApi } = await import('../src/ui/api/endpoints/bridgeSupport.ts');
    const { permissionToggleRequest } =
      await import('../src/ui/components/workbench/permissionToggleModel.ts');
    await store
      .dispatch(
        chatEndpoints.endpoints.createLaunchConversation.initiate({
          agentId: 'agent',
          bridgeId: 'bridge',
          provider: 'claude',
          providerProfile: 'claude_work',
          model: 'same',
          body: 'hello',
        }),
      )
      .unwrap();
    assert.equal(requests[0].body.provider_profile, 'claude_work');
    assert.equal(await decryptVaultText(requests[0].body.initial_message.body), 'hello');
    await store
      .dispatch(
        agentsApi.endpoints.applyInstanceConfiguration.initiate(
          permissionToggleRequest(
            {
              agent_instance_id: 'instance',
              bridge_id: 'bridge',
              provider: 'claude',
              provider_profile: 'claude_work',
              model: 'same',
            },
            false,
            'permissions',
          ),
        ),
      )
      .unwrap();
    assert.equal(
      requests[1].body.provider_profile,
      'claude_work',
      'permission changes preserve the current account',
    );
    await store
      .dispatch(
        bridgeSupportApi.endpoints.installProviderExtension.initiate({
          bridgeId: 'bridge',
          provider: 'claude',
          profileId: 'claude_work',
        }),
      )
      .unwrap();
    assert.deepEqual(requests[2].body, { profile_id: 'claude_work' });
  } finally {
    globalThis.fetch = previousFetch;
    await lockVaultFully(store);
    store.dispatch(heimdallApi.util.resetApiState());
  }
});

test('random directory recognition handles resolved Windows and Unix paths without reinterpreting custom paths', () => {
  const leaf = '.heimdall-claude-12345678-1234-1234-1234-123456789abc';
  for (const base of [
    '~/',
    '/home/bridge/',
    'C:' +
      String.fromCharCode(92) +
      'Users' +
      String.fromCharCode(92) +
      'bridge' +
      String.fromCharCode(92),
  ]) {
    assert.equal(configDirectoryMode(base + leaf), 'random');
    assert.equal(configDirectoryMode(base + leaf + '/nested'), 'custom');
  }
  assert.equal(configDirectoryMode(''), 'inherit');
  assert.equal(configDirectoryMode('/private/account'), 'custom');
});
