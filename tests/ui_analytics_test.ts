// PostHog product analytics: runtime-config key gating, payload shape, once-per-user
// milestones (REQ-PH-3/4/5, docs/analytics.md).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_analytics_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  Analytics,
  ELECTRON_DEFAULT_HOST,
  WEB_DEFAULT_HOST,
  detectPlatform,
  posthogInitOptions,
  redactCapturedUrls,
  stripUrlQueryAndHash,
  resolveAnalyticsConfig,
  sanitizeProps,
  type AnalyticsClient,
} from '../src/ui/analytics/analytics.ts';
import { observeMilestones } from '../src/ui/analytics/milestones.ts';
import {
  ELECTRON_RUNTIME_CONFIG_URL,
  loadRuntimeConfig,
  parseRuntimeConfig,
  runtimeConfigUrl,
} from '../src/ui/analytics/runtimeConfig.ts';

type Call = [string, ...unknown[]];

function memoryStorage() {
  const map = new Map<string, string>();
  return { getItem: (k: string) => map.get(k) ?? null, setItem: (k: string, v: string) => { map.set(k, v); }, map };
}

function fakeClient(calls: Call[]): AnalyticsClient {
  return {
    init: (key, config) => { calls.push(['init', key, config]); },
    register: (props) => { calls.push(['register', props]); },
    capture: (event, props, options) => { calls.push(['capture', event, props, options]); },
    identify: (id) => { calls.push(['identify', id]); },
    reset: () => { calls.push(['reset']); },
  };
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
const captures = (calls: Call[]) => calls.filter((c) => c[0] === 'capture').map((c) => c[1]);

function started(options: { platform?: 'web' | 'electron'; local?: ReturnType<typeof memoryStorage>; session?: ReturnType<typeof memoryStorage> } = {}) {
  const calls: Call[] = [];
  const analytics = new Analytics();
  const enabled = analytics.init({
    env: { VITE_POSTHOG_KEY: 'phc_test', VITE_APP_VERSION: '1.2.3' },
    platform: options.platform ?? 'web',
    loadClient: async () => fakeClient(calls),
    localStorage: options.local ?? memoryStorage(),
    sessionStorage: options.session ?? memoryStorage(),
    now: () => new Date('2026-11-02T00:00:00Z'),
  });
  return { analytics, calls, enabled };
}

test('without VITE_POSTHOG_KEY nothing is loaded, initialised or sent', async () => {
  for (const env of [undefined, {}, { VITE_POSTHOG_KEY: '' }, { VITE_POSTHOG_KEY: '   ', VITE_POSTHOG_HOST: 'https://x' }]) {
    let loads = 0;
    const analytics = new Analytics();
    const enabled = analytics.init({ env, platform: 'web', loadClient: async () => { loads += 1; return fakeClient([]); } });
    analytics.identify('usr_1');
    analytics.track('app_opened', {});
    analytics.trackOnce('bridge_connected', { bridge_count: 1, online_count: 1 });
    analytics.reset();
    await flush();
    assert.equal(enabled, false);
    assert.equal(analytics.enabled, false);
    assert.equal(loads, 0, 'posthog-js must not even be fetched');
    assert.equal(resolveAnalyticsConfig(env, 'web'), null);
  }
});

test('a key without a client loader stays off (main.tsx passes one only in keyed builds)', () => {
  const analytics = new Analytics();
  assert.equal(analytics.init({ env: { VITE_POSTHOG_KEY: 'k' }, platform: 'web' }), false);
  assert.equal(analytics.enabled, false);
});

test('host defaults per platform, VITE_POSTHOG_HOST overrides, ui_host is US cloud', () => {
  assert.equal(resolveAnalyticsConfig({ VITE_POSTHOG_KEY: 'k' }, 'web')?.apiHost, WEB_DEFAULT_HOST);
  assert.equal(WEB_DEFAULT_HOST, '/ingest');
  assert.equal(resolveAnalyticsConfig({ VITE_POSTHOG_KEY: 'k' }, 'electron')?.apiHost, ELECTRON_DEFAULT_HOST);
  assert.equal(ELECTRON_DEFAULT_HOST, 'https://web.ninjy.ai/ingest');
  assert.equal(resolveAnalyticsConfig({ VITE_POSTHOG_KEY: 'k', VITE_POSTHOG_HOST: 'https://eu.i.posthog.com' }, 'electron')?.apiHost, 'https://eu.i.posthog.com');
  assert.equal(resolveAnalyticsConfig({ VITE_POSTHOG_KEY: 'k' }, 'web')?.uiHost, 'https://us.posthog.com');
  assert.equal(detectPlatform(() => true), 'electron');
  assert.equal(detectPlatform(() => false), 'web');
  assert.equal(detectPlatform(() => { throw new Error('no window'); }), 'web');
  assert.equal(detectPlatform(), 'web', 'no desktop preload under node');
});

test('init turns off autocapture, pageviews and recording and registers platform + version', async () => {
  const { calls, enabled } = started({ platform: 'electron' });
  await flush();
  assert.equal(enabled, true);
  const [, key, config] = calls.find((c) => c[0] === 'init')!;
  assert.equal(key, 'phc_test');
  const options = config as Record<string, unknown>;
  assert.equal(options.api_host, ELECTRON_DEFAULT_HOST);
  assert.equal(options.ui_host, 'https://us.posthog.com');
  assert.equal(options.autocapture, false);
  assert.equal(options.capture_pageview, false);
  assert.equal(options.disable_session_recording, true);
  assert.deepEqual(posthogInitOptions(resolveAnalyticsConfig({ VITE_POSTHOG_KEY: 'k' }, 'electron')!), options);
  assert.deepEqual(calls.find((c) => c[0] === 'register')![1], { platform: 'electron', app_version: '1.2.3' });
  // register happens before the first capture, so every event carries the platform.
  assert.ok(calls.findIndex((c) => c[0] === 'register') < calls.findIndex((c) => c[0] === 'capture'));
});

test('app_opened is sent once per browser session', async () => {
  const session = memoryStorage();
  const first = started({ session });
  const second = started({ session });
  await flush();
  assert.deepEqual(captures(first.calls), ['app_opened']);
  assert.deepEqual(captures(second.calls), []);
});

test('identify sends only the user id, app_login once per user, reset on switch and logout', async () => {
  const local = memoryStorage();
  const { analytics, calls } = started({ local });
  analytics.identify('usr_a');
  analytics.identify('usr_a');
  await flush();
  assert.deepEqual(calls.filter((c) => c[0] === 'identify'), [['identify', 'usr_a']]);
  const login = calls.find((c) => c[0] === 'capture' && c[1] === 'app_login')!;
  assert.deepEqual(login[2], {});
  assert.deepEqual(login[3], { $set_once: { app_login_at: '2026-11-02T00:00:00.000Z' } });

  analytics.identify('usr_b');
  const resetIndex = calls.findIndex((c) => c[0] === 'reset');
  assert.ok(resetIndex > 0 && resetIndex < calls.findIndex((c) => c[0] === 'identify' && c[1] === 'usr_b'));
  analytics.reset();
  assert.equal(analytics.currentUserId, '');
  assert.equal(calls.filter((c) => c[0] === 'reset').length, 2);

  // A returning user on this device does not log a second first-login.
  analytics.identify('usr_a');
  assert.equal(captures(calls).filter((e) => e === 'app_login').length, 2, 'one each for usr_a and usr_b');
});

test('calls made before posthog-js loads are queued in order', async () => {
  const calls: Call[] = [];
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const analytics = new Analytics();
  analytics.init({
    env: { VITE_POSTHOG_KEY: 'k' }, platform: 'web',
    loadClient: async () => { await gate; return fakeClient(calls); },
    localStorage: memoryStorage(), sessionStorage: memoryStorage(),
  });
  analytics.identify('usr_q');
  assert.equal(calls.length, 0);
  release();
  await flush();
  assert.deepEqual(calls.map((c) => c[0] === 'capture' ? `capture:${c[1]}` : c[0]),
    ['init', 'register', 'capture:app_opened', 'identify', 'capture:app_login']);
});

test('automatic URL properties lose their query and hash (device codes, routes)', () => {
  assert.equal(stripUrlQueryAndHash('https://web.ninjy.ai/#/device/add?code=ABCD-1234'), 'https://web.ninjy.ai/');
  assert.equal(stripUrlQueryAndHash('https://web.ninjy.ai/device/add?code=X#y'), 'https://web.ninjy.ai/device/add');
  assert.equal(stripUrlQueryAndHash('file:///opt/Ninjy/index.html#/chains/c1'), 'file:///opt/Ninjy/index.html');
  assert.equal(stripUrlQueryAndHash('$direct'), '$direct');
  const event = {
    event: 'app_login',
    properties: { $current_url: 'https://web.ninjy.ai/?auth_error=1#/x', $referrer: 'https://idp.example/cb?state=s', platform: 'web' },
    $set_once: { $initial_current_url: 'https://web.ninjy.ai/#/device/add?code=Z' },
  };
  const out = redactCapturedUrls(event)!;
  assert.equal(out.properties.$current_url, 'https://web.ninjy.ai/');
  assert.equal(out.properties.$referrer, 'https://idp.example/cb');
  assert.equal(out.properties.platform, 'web');
  assert.equal(out.$set_once.$initial_current_url, 'https://web.ninjy.ai/');
  assert.equal(redactCapturedUrls(null), null);
  assert.equal(posthogInitOptions(resolveAnalyticsConfig({ VITE_POSTHOG_KEY: 'k' }, 'web')!).before_send, redactCapturedUrls);
});

test('sanitizeProps keeps only short primitives', () => {
  assert.deepEqual(sanitizeProps({ n: 2, b: false, s: 'claude', long: 'x'.repeat(65), obj: { a: 1 } as any, nan: NaN, empty: '', undef: undefined }),
    { n: 2, b: false, s: 'claude' });
});

function apiState(bridges: any[]) {
  return { heimdallApi: { queries: { 'listBridges(undefined)': { endpointName: 'listBridges', status: 'fulfilled', data: { bridges } } } } };
}
const fulfilled = (endpointName: string, originalArgs: any, payload: any = {}) =>
  ({ type: 'heimdallApi/executeMutation/fulfilled', meta: { arg: { endpointName, originalArgs } }, payload });

test('funnel milestones fire once per user at the Hub success points with non-content props', async () => {
  const { analytics, calls } = started();
  // Nothing before sign-in.
  observeMilestones(analytics, { type: 'heimdallApi/queries/queryResultPatched' }, apiState([{ bridge_id: 'b1', status: 'online' }]));
  assert.equal(analytics.currentUserId, '');
  analytics.identify('usr_f');

  // An offline bridge is not a connection; the WS patch that marks it online is.
  observeMilestones(analytics, { type: 'heimdallApi/queries/queryResultPatched' }, apiState([{ bridge_id: 'b1', status: 'offline' }]));
  observeMilestones(analytics, { type: 'heimdallApi/queries/queryResultPatched' }, apiState([{ bridge_id: 'b1', status: 'offline' }, { bridge_id: 'b2', runtime_connected: true }]));
  observeMilestones(analytics, { type: 'heimdallApi/queries/queryResultPatched' }, apiState([{ bridge_id: 'b1', status: 'online' }, { bridge_id: 'b2', runtime_connected: true }]));
  // Non-API actions are ignored.
  observeMilestones(analytics, { type: 'chat/messageReceived' }, apiState([{ status: 'online' }]));

  observeMilestones(analytics, { ...fulfilled('listBridgeProviders', { bridgeId: 'b2' }, { providers: [] }), type: 'heimdallApi/executeQuery/fulfilled' }, {});
  observeMilestones(analytics, { ...fulfilled('listBridgeProviders', { bridgeId: 'b2' }, { providers: [{ provider: 'claude', label: 'My secret profile' }, { provider: 'codex' }] }), type: 'heimdallApi/executeQuery/fulfilled' }, {});
  observeMilestones(analytics, fulfilled('createTaskChain', { title: 'Secret plan', description: 'do the thing', kind: 'mixed_work' }), {});
  observeMilestones(analytics, fulfilled('createTaskChain', { title: 'Second', kind: 'team_work' }), {});
  observeMilestones(analytics, { ...fulfilled('createLaunchConversation', { agentId: 'agt_1', provider: 'claude', body: 'hello prompt' }), type: 'heimdallApi/executeMutation/rejected' }, {});
  observeMilestones(analytics, fulfilled('createLaunchConversation', { agentId: 'agt_1', provider: 'claude', body: 'hello prompt' }), {});
  observeMilestones(analytics, fulfilled('startAgentInstance', { instanceId: 'inst_2' }), {});
  await flush();

  const sent = calls.filter((c) => c[0] === 'capture').map((c) => [c[1], c[2]]);
  assert.deepEqual(sent, [
    ['app_opened', {}],
    ['app_login', {}],
    ['bridge_connected', { bridge_count: 2, online_count: 1 }],
    ['provider_configured', { provider: 'claude', provider_count: 2 }],
    ['first_chain_created', { chain_kind: 'mixed_work' }],
    ['first_agent_started', { via: 'createLaunchConversation', provider: 'claude' }],
  ]);
  const payloads = JSON.stringify(calls);
  for (const secret of ['Secret plan', 'do the thing', 'hello prompt', 'My secret profile']) assert.ok(!payloads.includes(secret), secret);
});

// --- Runtime config (/posthog-config.json) -------------------------------------------

type FetchCall = { url: string; init?: Record<string, unknown> };

function fakeFetch(answer: { status?: number; body?: string; error?: Error }, seen: FetchCall[] = []) {
  return async (url: string, init?: Record<string, unknown>) => {
    seen.push({ url, init });
    if (answer.error) throw answer.error;
    const status = answer.status ?? 200;
    return { ok: status >= 200 && status < 300, text: async () => answer.body ?? '' };
  };
}

async function startWith(answer: Parameters<typeof fakeFetch>[0], platform: 'web' | 'electron' = 'web', env = {}) {
  const calls: Call[] = [];
  const seen: FetchCall[] = [];
  let loads = 0;
  const analytics = new Analytics();
  const pending = analytics.start({
    env,
    platform,
    loadConfig: (p) => loadRuntimeConfig({ platform: p, fetch: fakeFetch(answer, seen), origin: 'https://web.ninjy.ai' }),
    loadClient: async () => { loads += 1; return fakeClient(calls); },
    localStorage: memoryStorage(),
    sessionStorage: memoryStorage(),
  });
  // The AuthGate may identify before the config answers.
  analytics.identify('usr_early');
  const on = await pending;
  await flush();
  return { analytics, calls, seen, on, loads: () => loads };
}

test('runtime config present (web): same-origin fetch without cookies, key and relative host used', async () => {
  const { on, seen, calls, analytics, loads } = await startWith({ body: '{"key":"phc_live","host":"/ingest"}' });
  assert.equal(on, true);
  assert.equal(analytics.enabled, true);
  assert.equal(loads(), 1);
  assert.deepEqual(seen, [{ url: 'https://web.ninjy.ai/posthog-config.json', init: { credentials: 'omit', cache: 'no-store' } }]);
  const [, key, options] = calls.find((c) => c[0] === 'init')!;
  assert.equal(key, 'phc_live');
  assert.equal((options as any).api_host, 'https://web.ninjy.ai/ingest');
  // The identify made while the config loaded is replayed after init, in order.
  assert.deepEqual(calls.map((c) => c[0] === 'capture' ? `capture:${c[1]}` : c[0]),
    ['init', 'register', 'capture:app_opened', 'identify', 'capture:app_login']);
  assert.equal(analytics.currentUserId, 'usr_early');
});

test('runtime config present (Electron): reads https://web.ninjy.ai and posts to its /ingest', async () => {
  assert.equal(ELECTRON_RUNTIME_CONFIG_URL, 'https://web.ninjy.ai/posthog-config.json');
  const { on, seen, calls } = await startWith({ body: '{"key":"phc_live"}' }, 'electron');
  assert.equal(on, true);
  assert.equal(seen[0].url, ELECTRON_RUNTIME_CONFIG_URL);
  const options = calls.find((c) => c[0] === 'init')![2] as any;
  assert.equal(options.api_host, 'https://web.ninjy.ai/ingest');
  assert.deepEqual(calls.find((c) => c[0] === 'register')![1], { platform: 'electron', app_version: 'unknown' });
  // Electron's config URL does not depend on the page origin.
  assert.equal(runtimeConfigUrl('electron', 'https://hub.example.com'), ELECTRON_RUNTIME_CONFIG_URL);
});

const OFF_CASES: Array<[string, Parameters<typeof fakeFetch>[0]]> = [
  ['404', { status: 404, body: '<html>Not Found</html>' }],
  ['network error', { error: new TypeError('Failed to fetch') }],
  ['empty key', { body: '{"key":"","host":"/ingest"}' }],
  ['blank key', { body: '{"key":"   "}' }],
  ['missing key', { body: '{"host":"/ingest"}' }],
  ['SPA HTML fallback (200)', { body: '<!doctype html><html></html>' }],
  ['non-object JSON', { body: '["phc_x"]' }],
];

for (const [name, answer] of OFF_CASES) {
  test(`runtime config ${name}: analytics off, posthog-js never loaded, nothing sent, no throw`, async () => {
    for (const platform of ['web', 'electron'] as const) {
      const { on, calls, analytics, loads } = await startWith(answer, platform);
      analytics.track('app_opened', {});
      analytics.trackOnce('bridge_connected', { bridge_count: 1, online_count: 1 });
      analytics.reset();
      await flush();
      assert.equal(on, false);
      assert.equal(analytics.enabled, false);
      assert.equal(loads(), 0, 'posthog-js must not be imported');
      assert.deepEqual(calls, []);
      assert.equal(analytics.currentUserId, '');
    }
  });
}

test('a throwing config loader is treated as no config', async () => {
  const analytics = new Analytics();
  let loads = 0;
  const on = await analytics.start({ platform: 'web', loadConfig: async () => { throw new Error('boom'); }, loadClient: async () => { loads += 1; return fakeClient([]); } });
  assert.equal(on, false);
  assert.equal(loads, 0);
});

test('VITE_POSTHOG_KEY is a dev override: no config fetch, env key and host win', async () => {
  const { on, seen, calls } = await startWith({ body: '{"key":"phc_live"}' }, 'web', { VITE_POSTHOG_KEY: 'phc_dev', VITE_POSTHOG_HOST: 'http://localhost:8010' });
  assert.equal(on, true);
  assert.deepEqual(seen, []);
  const [, key, options] = calls.find((c) => c[0] === 'init')!;
  assert.equal(key, 'phc_dev');
  assert.equal((options as any).api_host, 'http://localhost:8010');
});

test('parseRuntimeConfig resolves hosts against the config URL and rejects non-http hosts', () => {
  const at = 'https://web.ninjy.ai/posthog-config.json';
  assert.deepEqual(parseRuntimeConfig('{"key":" phc_a ","host":"/ingest/"}', at), { key: 'phc_a', host: 'https://web.ninjy.ai/ingest' });
  assert.deepEqual(parseRuntimeConfig('{"key":"phc_a","host":"https://us.i.posthog.com"}', at), { key: 'phc_a', host: 'https://us.i.posthog.com' });
  assert.deepEqual(parseRuntimeConfig('{"key":"phc_a","host":"javascript:alert(1)"}', at), { key: 'phc_a', host: '' });
  assert.deepEqual(parseRuntimeConfig('{"key":"phc_a","host":42}', at), { key: 'phc_a', host: '' });
  assert.equal(parseRuntimeConfig('{"key":7}', at), null);
  assert.equal(parseRuntimeConfig('', at), null);
  assert.equal(parseRuntimeConfig('null', at), null);
  // An empty runtime host falls back to the platform default.
  assert.equal(resolveAnalyticsConfig({}, 'web', { key: 'k', host: '' })?.apiHost, WEB_DEFAULT_HOST);
  assert.equal(resolveAnalyticsConfig({}, 'electron', { key: 'k', host: '' })?.apiHost, ELECTRON_DEFAULT_HOST);
  // A web page without an http(s) origin (tests, file://) has no config to fetch.
  assert.equal(runtimeConfigUrl('web', 'null'), null);
  assert.equal(runtimeConfigUrl('web'), null, 'no window under node');
});

test('a cross-load account switch reset made while the config loads is replayed before identify', async () => {
  const calls: Call[] = [];
  const analytics = new Analytics();
  const pending = analytics.start({
    platform: 'web',
    loadConfig: async () => ({ key: 'k', host: '' }),
    loadClient: async () => fakeClient(calls),
    localStorage: memoryStorage(), sessionStorage: memoryStorage(),
  });
  analytics.reset();
  analytics.identify('usr_new');
  await pending;
  await flush();
  const order = calls.map((c) => c[0]).filter((c) => c === 'reset' || c === 'identify');
  assert.deepEqual(order, ['reset', 'identify']);
});
