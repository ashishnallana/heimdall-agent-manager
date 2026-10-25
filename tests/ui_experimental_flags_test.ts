// REQ-EXP-GATE-1: Actions experiment key, Settings toggle list, and flag resolution.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_experimental_flags_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  ACTIONS_EXPERIMENT_KEY,
  EXPERIMENTAL_FLAGS,
  PROJECT_VCS_EXPERIMENT_KEY,
  resolveActionsExperiment,
  resolveExperimentFlag,
} from '../src/ui/components/settings/experimentFlags.ts';
import { resolveProjectVcsExperiment } from '../src/ui/components/chat/projectVcsExperiment.ts';

test('uses the stable actions key shared with the hub', () => {
  assert.equal(ACTIONS_EXPERIMENT_KEY, 'actions');
});

test('Settings > Experimental lists an Actions toggle and keeps existing toggles', () => {
  const keys = EXPERIMENTAL_FLAGS.map((f) => f.key);
  assert.deepEqual(keys, ['lsp', 'streaming_terminal_pane', PROJECT_VCS_EXPERIMENT_KEY, ACTIONS_EXPERIMENT_KEY]);
  assert.equal(new Set(keys).size, keys.length, 'toggle keys are unique');
  const actions = EXPERIMENTAL_FLAGS.find((f) => f.key === ACTIONS_EXPERIMENT_KEY);
  assert.equal(actions?.label, 'Actions');
  assert.ok(actions?.description);
});

test('Settings labels name the features the Hub and UI unavailable notices point to', () => {
  // Hub 403: "<Feature> is experimental. Enable it in Settings > Experimental to use it."
  const label = (key: string) => EXPERIMENTAL_FLAGS.find((f) => f.key === key)?.label ?? '';
  assert.match(label(PROJECT_VCS_EXPERIMENT_KEY), /^Project Explorer\b/);
  assert.match(label(ACTIONS_EXPERIMENT_KEY), /^Actions\b/);
});

test('Actions is loading until flags load, then disabled when absent or false', () => {
  assert.equal(resolveActionsExperiment(undefined), 'loading');
  assert.equal(resolveActionsExperiment([]), 'disabled');
  assert.equal(resolveActionsExperiment([{ key: PROJECT_VCS_EXPERIMENT_KEY, enabled: true }]), 'disabled');
  assert.equal(resolveActionsExperiment([{ key: ACTIONS_EXPERIMENT_KEY, enabled: false }]), 'disabled');
  assert.equal(resolveActionsExperiment([{ key: ACTIONS_EXPERIMENT_KEY, enabled: true }]), 'enabled');
});

test('Actions and Project/VCS flags resolve independently', () => {
  const flags = [
    { key: PROJECT_VCS_EXPERIMENT_KEY, enabled: true },
    { key: ACTIONS_EXPERIMENT_KEY, enabled: false },
  ];
  assert.equal(resolveProjectVcsExperiment(flags), 'enabled');
  assert.equal(resolveActionsExperiment(flags), 'disabled');
});

test('fails closed for malformed or duplicate flags', () => {
  assert.equal(
    resolveExperimentFlag(
      [{ key: ACTIONS_EXPERIMENT_KEY, enabled: 'true' }] as unknown as Array<{ key: string; enabled: boolean }>,
      ACTIONS_EXPERIMENT_KEY,
    ),
    'disabled',
  );
  assert.equal(
    resolveActionsExperiment([
      { key: ACTIONS_EXPERIMENT_KEY, enabled: true },
      { key: ACTIONS_EXPERIMENT_KEY, enabled: true },
    ]),
    'disabled',
  );
});

// REQ-EXP-GATE-2: Actions entry points and direct routes are gated on the flag.

import React from 'react';
import {
  EXPERIMENTAL_SETTINGS_HREF,
  actionsUnavailableMessage,
  filterActionsNavEntries,
  isActionsRoute,
  resolveActionsAccess,
} from '../src/ui/components/actions/actionsExperiment.ts';

const ACTIONS_ON = [{ key: ACTIONS_EXPERIMENT_KEY, enabled: true }];
const ACTIONS_OFF = [{ key: ACTIONS_EXPERIMENT_KEY, enabled: false }];

test('Actions access is enabled only for a loaded true flag; fetch errors fail closed', () => {
  assert.equal(resolveActionsAccess(ACTIONS_ON, false), 'enabled');
  assert.equal(resolveActionsAccess(ACTIONS_OFF, false), 'disabled');
  assert.equal(resolveActionsAccess([], false), 'disabled');
  assert.equal(resolveActionsAccess(undefined, false), 'loading');
  assert.equal(resolveActionsAccess(undefined, true), 'error');
  // A refetch error with stale cached flags must not keep Actions open.
  assert.equal(resolveActionsAccess(ACTIONS_ON, true), 'error');
});

test('Actions unavailable copy matches the server message and links to Experimental settings', () => {
  assert.equal(
    actionsUnavailableMessage('disabled'),
    'Actions is experimental. Enable it in Settings > Experimental to use it.',
  );
  assert.match(actionsUnavailableMessage('error'), /could not be loaded/);
  assert.match(actionsUnavailableMessage('loading'), /Checking/);
  assert.equal(EXPERIMENTAL_SETTINGS_HREF, '#/settings/experimental');
});

test('every Actions route is recognised; look-alike paths are not', () => {
  for (const path of ['/actions', '/actions/new', '/actions/act_1', '/actions/act_1/edit']) {
    assert.equal(isActionsRoute(path), true, path);
  }
  for (const path of ['/actionsx', '/home', '/agents/actions', '/cards']) {
    assert.equal(isActionsRoute(path), false, path);
  }
});

test('sidebar/mobile nav drops Actions unless enabled and keeps the other entries in order', () => {
  const nav = [{ path: '/home' }, { path: '/actions' }, { path: '/projects' }, { path: '/agents' }];
  for (const access of ['loading', 'disabled', 'error'] as const) {
    assert.deepEqual(filterActionsNavEntries(nav, access).map((n) => n.path), ['/home', '/projects', '/agents'], access);
  }
  assert.deepEqual(filterActionsNavEntries(nav, 'enabled').map((n) => n.path), ['/home', '/actions', '/projects', '/agents']);
});

// DOM regression: the real route gate, driven by the live experiments query.

type ExperimentsReply = 'pending' | 'error' | Array<{ key: string; enabled: boolean }>;

async function withActionsDom<T>(fn: (dom: any, fetched: string[], setExperiments: (r: ExperimentsReply) => void) => Promise<T>): Promise<T> {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', {
    url: 'http://localhost/#/actions',
  });
  const g = globalThis as any;
  const prev = { window: g.window, document: g.document, HTMLElement: g.HTMLElement, navigator: g.navigator, fetch: g.fetch, localStorage: g.localStorage };
  const fetched: string[] = [];
  let experiments: ExperimentsReply = 'pending';
  const reply = (status: number, body: unknown) =>
    ({ ok: status < 400, status, headers: { get: () => 'application/json' }, text: async () => JSON.stringify(body), json: async () => body }) as any;
  const held: Array<(res: any) => void> = [];
  const experimentsResponse = (r: Exclude<ExperimentsReply, 'pending'>) =>
    r === 'error' ? reply(500, { error: { code: 'internal', message: 'boom' } }) : reply(200, { experiments: r });
  g.window = dom.window;
  g.document = dom.window.document;
  g.HTMLElement = dom.window.HTMLElement;
  g.localStorage = dom.window.localStorage;
  Object.defineProperty(globalThis, 'navigator', { value: dom.window.navigator, configurable: true });
  g.IS_REACT_ACT_ENVIRONMENT = true;
  g.fetch = async (input: any) => {
    const url = String(input?.url ?? input);
    fetched.push(url);
    if (url.includes('/me/experiments')) {
      // 'pending' holds the request open until the next reply is chosen.
      if (experiments === 'pending') return new Promise((resolve) => held.push(resolve));
      return experimentsResponse(experiments);
    }
    return reply(200, { actions: [] });
  };
  try {
    return await fn(dom, fetched, (r) => {
      experiments = r;
      if (r !== 'pending') held.splice(0).forEach((resolve) => resolve(experimentsResponse(r)));
    });
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

const isProtectedActionsRequest = (url: string) => /\/api\/v1\/(actions|scheduled-prompts)(\/|\?|$)/.test(url);

test('actions route gate: unavailable notice for loading/error/disabled, no protected fetch, live toggle restores', async () => {
  await withActionsDom(async (dom, fetched, setExperiments) => {
    const { createRoot } = await import('react-dom/client');
    const { Provider } = await import('react-redux');
    const { configureStore } = await import('@reduxjs/toolkit');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const { useListActionsQuery } = await import('../src/ui/api/endpoints/actions.ts');
    const { ActionsRouteGate } = await import('../src/ui/components/actions/ActionsRouteGate.tsx');
    const store = configureStore({
      reducer: { [heimdallApi.reducerPath]: heimdallApi.reducer },
      middleware: (gdm: any) => gdm({ serializableCheck: false, immutableCheck: false }).concat(heimdallApi.middleware),
    });
    // Stands in for ActionListPage: mounting it issues the protected /actions list query.
    function ProtectedActionsPage() {
      useListActionsQuery();
      return React.createElement('div', { 'data-debug-id': 'protected-actions-page' });
    }
    const doc = dom.window.document;
    const q = (sel: string) => doc.querySelector(sel);
    const root = createRoot(doc.getElementById('root')!);
    const settle = () => new Promise((r) => setTimeout(r, 30));
    const refetchExperiments = async (r: ExperimentsReply) => {
      setExperiments(r);
      await React.act(async () => {
        store.dispatch(heimdallApi.util.invalidateTags([{ type: 'Experiments', id: 'ALL' }] as any));
        await settle();
      });
    };
    const expectUnavailable = (access: string) => {
      assert.ok(q(`[data-debug-id="actions-unavailable-${access}"]`), `${access}: unavailable notice`);
      assert.equal(q('[data-debug-id="protected-actions-page"]'), null, `${access}: page not mounted`);
      const link = q('[data-debug-id="actions-unavailable-settings-link"]');
      if (access === 'loading') assert.equal(link, null, 'loading: neutral notice');
      else assert.equal(link?.getAttribute('href'), '#/settings/experimental', `${access}: settings link`);
    };
    try {
      await React.act(async () => {
        root.render(React.createElement(Provider, { store },
          React.createElement(ActionsRouteGate, null, React.createElement(ProtectedActionsPage))));
        await settle();
      });
      expectUnavailable('loading');

      await refetchExperiments('error');
      expectUnavailable('error');

      await refetchExperiments(ACTIONS_OFF);
      expectUnavailable('disabled');

      await refetchExperiments([]);
      expectUnavailable('disabled');
      assert.deepEqual(fetched.filter(isProtectedActionsRequest), [], 'no /actions or /scheduled-prompts request while not enabled');

      await refetchExperiments(ACTIONS_ON);
      assert.ok(q('[data-debug-id="protected-actions-page"]'), 'enabled: page mounts without reload');
      assert.equal(q('[data-debug-id^="actions-unavailable-"]'), null);
      assert.ok(fetched.some(isProtectedActionsRequest), 'enabled: the page loads its actions');

      await refetchExperiments(ACTIONS_OFF);
      expectUnavailable('disabled');
      const before = fetched.filter(isProtectedActionsRequest).length;
      await React.act(async () => {
        store.dispatch(heimdallApi.util.invalidateTags([{ type: 'Actions', id: 'LIST' }] as any));
        await settle();
      });
      assert.equal(fetched.filter(isProtectedActionsRequest).length, before, 'disabled again: no further actions queries');

      await refetchExperiments(ACTIONS_ON);
      assert.ok(q('[data-debug-id="protected-actions-page"]'), 'toggling back on restores the page');
    } finally {
      await React.act(async () => root.unmount());
    }
  });
});
