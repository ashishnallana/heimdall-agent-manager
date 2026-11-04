// T9: per-bridge context-window settings (presets 200K/500K/1M, custom >= 100K).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_bridge_context_windows_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import React, { act } from 'react';

import {
  CONTEXT_WINDOW_PRESETS,
  contextWindowClearPath,
  formatContextWindow,
  normalizeContextWindowState,
  parseCustomContextWindow,
} from '../src/ui/components/settings/contextWindowSettings.ts';

// react-dom decides at load time whether the DOM supports 'input' events, so the
// DOM globals must exist before it is imported (hence the dynamic imports).
const dom = new JSDOM('<!doctype html><html><body></body></html>', { url: 'https://hub.example.test/' });
for (const [key, value] of Object.entries({ window: dom.window, document: dom.window.document,
  HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true })) {
  Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
}
const { createRoot } = await import('react-dom/client');
const { default: BridgeContextWindows } = await import('../src/ui/components/settings/BridgeContextWindows.tsx');

test('presets are exactly 200K, 500K and 1M', () => {
  assert.deepEqual(CONTEXT_WINDOW_PRESETS.map((p) => [p.label, p.value]), [['200K', 200_000], ['500K', 500_000], ['1M', 1_000_000]]);
});

test('custom values below 100K are rejected client-side; suffixes and separators parse', () => {
  assert.deepEqual(parseCustomContextWindow('100000'), { ok: true, value: 100_000 });
  assert.deepEqual(parseCustomContextWindow('150K'), { ok: true, value: 150_000 });
  assert.deepEqual(parseCustomContextWindow(' 1.5m '), { ok: true, value: 1_500_000 });
  assert.deepEqual(parseCustomContextWindow('250,000'), { ok: true, value: 250_000 });
  for (const bad of ['99999', '99K', '0', '50k']) {
    const r = parseCustomContextWindow(bad);
    assert.equal(r.ok, false, bad);
    assert.match((r as any).error, /Minimum is 100K/);
  }
  for (const bad of ['', 'abc', '-200000', '150000.5', '1e6', '200KB']) assert.equal(parseCustomContextWindow(bad).ok, false, bad);
  assert.match((parseCustomContextWindow('101M') as any).error, /Maximum/);
});

test('formatting and state normalization', () => {
  assert.equal(formatContextWindow(200_000), '200K');
  assert.equal(formatContextWindow(1_000_000), '1M');
  assert.equal(formatContextWindow(1_500_000), '1.5M');
  assert.equal(formatContextWindow(123_456), '123,456');
  assert.equal(contextWindowClearPath('brg a', 'claude', 'opus[1m]'), '/bridges/brg%20a/context-windows?provider=claude&model=opus%5B1m%5D');
  assert.equal(normalizeContextWindowState({}), null);
  const s = normalizeContextWindowState({ windows: [
    { provider: 'codex', model: 'gpt-5', context_window: 475000, source: 'config' },
    { provider: 'claude', model: 'opus', resolved_model: 'claude-opus-4', context_window: 200000, source: 'config' },
    { provider: 'claude', model: 'bad', context_window: 'x', source: 'config' },
    { provider: 'claude', model: 'weird', context_window: 1, source: 'nope' },
  ] })!;
  assert.deepEqual(s.windows.map((w) => w.model), ['opus', 'gpt-5'], 'malformed rows dropped, sorted by provider/model');
  assert.equal(s.default_window, 200_000);
  assert.equal(s.warn_pct, 40, 'missing thresholds fall back to the shared 40/70');
  assert.equal(s.rollover_pct, 70);
  assert.equal(s.windows[0].resolved_model, 'claude-opus-4');
});

function bridgeState(windows: any[]) {
  return { type: 'context_window_op_result', ok: true, default_window: 200000, min_window: 100000, max_window: 100000000, warn_pct: 40, rollover_pct: 70, entries: [], overrides: [], windows };
}

const INITIAL = [
  { provider: 'claude', model: 'opus', context_window: 500000, source: 'override' },
  { provider: 'claude', model: 'sonnet', context_window: 200000, source: 'config' },
  { provider: 'gemini', model: 'gemini-3-pro', context_window: 200000, source: 'default' },
];

type Req = { path: string; method: string; body: any };

async function withDom(fn: (dom: JSDOM, container: HTMLElement, requests: Req[], setReply: (r: (req: Req) => Response) => void) => Promise<void>) {
  const container = dom.window.document.createElement('div');
  dom.window.document.body.replaceChildren(container);
  const previousFetch = globalThis.fetch;
  const requests: Req[] = [];
  let reply = (_req: Req) => Response.json({ data: bridgeState(INITIAL) });
  globalThis.fetch = (async (input: any, init: any = {}) => {
    const req = { path: String(input), method: init.method || 'GET', body: init.body ? JSON.parse(init.body) : null };
    requests.push(req);
    return reply(req);
  }) as typeof fetch;
  try {
    await fn(dom, container, requests, (r) => { reply = r; });
  } finally {
    globalThis.fetch = previousFetch;
  }
}

function row(dom: JSDOM, model: string): HTMLElement {
  const el = Array.from(dom.window.document.querySelectorAll('li[data-source]')).find((li) => li.textContent?.includes(`/ ${model}`));
  assert.ok(el, `row for ${model}`);
  return el as HTMLElement;
}

function button(scope: Element, label: string): HTMLButtonElement {
  const el = Array.from(scope.querySelectorAll('button')).find((b) => b.textContent?.trim() === label);
  assert.ok(el, `button ${label}`);
  return el as HTMLButtonElement;
}

async function typeInto(dom: JSDOM, input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, 'value')!.set!;
  await act(async () => {
    setter.call(input, value);
    input.dispatchEvent(new dom.window.Event('input', { bubbles: true }));
  });
}

test('lists each provider/model with its source badge and highlights default (missing) entries', async () => {
  await withDom(async (dom, container, requests) => {
    const root = createRoot(container);
    try {
      await act(async () => { root.render(React.createElement(BridgeContextWindows, { bridgeId: 'brg-1', online: true })); });
      assert.deepEqual(requests[0], { path: '/api/v1/bridges/brg-1/context-windows', method: 'GET', body: null });
      const opus = row(dom, 'opus');
      assert.equal(opus.querySelector('[data-role="context-window-source"]')!.textContent, 'Override');
      assert.equal(opus.querySelector('[data-role="context-window-value"]')!.textContent, '500K');
      assert.equal(row(dom, 'sonnet').querySelector('[data-role="context-window-source"]')!.textContent, 'Config');
      const gemini = row(dom, 'gemini-3-pro');
      assert.equal(gemini.dataset.source, 'default');
      assert.equal(gemini.querySelector('[data-role="context-window-source"]')!.textContent, 'Default');
      assert.match(gemini.className, /warning/, 'default entries are highlighted');
      assert.doesNotMatch(row(dom, 'sonnet').className, /warning/);
      assert.match(dom.window.document.body.textContent || '', /1 model is not in the shipped config/);
      assert.match(dom.window.document.body.textContent || '', /amber at 40% of the window \(display only; nothing is sent to the agent\), and at 70% the agent rolls over: it restarts with a fresh context/);
      assert.doesNotMatch(dom.window.document.body.textContent || '', /get a warning/);
    } finally {
      await act(async () => root.unmount());
    }
  });
});

test('presets, custom value and clear relay to the bridge; custom < 100K never sends a request', async () => {
  await withDom(async (dom, container, requests, setReply) => {
    const root = createRoot(container);
    try {
      await act(async () => { root.render(React.createElement(BridgeContextWindows, { bridgeId: 'brg-1', online: true })); });
      // Preset on a config row.
      setReply((req) => Response.json({ data: bridgeState([INITIAL[0], { ...INITIAL[1], context_window: req.body.context_window, source: 'override' }, INITIAL[2]]) }));
      await act(async () => { button(row(dom, 'sonnet'), 'Change').click(); });
      const presets = Array.from(row(dom, 'sonnet').querySelectorAll('[data-preset]')).map((b) => b.textContent);
      assert.deepEqual(presets, ['200K', '500K', '1M']);
      await act(async () => { button(row(dom, 'sonnet'), '1M').click(); });
      assert.deepEqual(requests.at(-1), { path: '/api/v1/bridges/brg-1/context-windows', method: 'PUT', body: { provider: 'claude', model: 'sonnet', context_window: 1_000_000 } });
      assert.equal(row(dom, 'sonnet').querySelector('[data-role="context-window-value"]')!.textContent, '1M');
      assert.equal(row(dom, 'sonnet').dataset.source, 'override');
      assert.equal(row(dom, 'sonnet').querySelector('[data-role="context-window-editor"]'), null, 'editor closes after save');

      // Custom below the minimum: rejected client-side.
      await act(async () => { button(row(dom, 'gemini-3-pro'), 'Change').click(); });
      const input = row(dom, 'gemini-3-pro').querySelector('input') as HTMLInputElement;
      const before = requests.length;
      await typeInto(dom, input, '90K');
      await act(async () => { button(row(dom, 'gemini-3-pro'), 'Set').click(); });
      assert.equal(requests.length, before, 'no request for a value under 100K');
      assert.match(row(dom, 'gemini-3-pro').querySelector('[data-role="context-window-custom-error"]')!.textContent || '', /Minimum is 100K/);

      // Valid custom value.
      setReply((req) => Response.json({ data: bridgeState([INITIAL[0], INITIAL[1], { ...INITIAL[2], context_window: req.body.context_window, source: 'override' }]) }));
      await typeInto(dom, row(dom, 'gemini-3-pro').querySelector('input') as HTMLInputElement, '1.5M');
      await act(async () => { button(row(dom, 'gemini-3-pro'), 'Set').click(); });
      assert.deepEqual(requests.at(-1)!.body, { provider: 'gemini', model: 'gemini-3-pro', context_window: 1_500_000 });
      assert.equal(row(dom, 'gemini-3-pro').querySelector('[data-role="context-window-value"]')!.textContent, '1.5M');

      // Clear an override.
      setReply(() => Response.json({ data: bridgeState([{ ...INITIAL[0], context_window: 200000, source: 'config' }, INITIAL[1], INITIAL[2]]) }));
      await act(async () => { button(row(dom, 'opus'), 'Change').click(); });
      await act(async () => { button(row(dom, 'opus'), 'Clear override').click(); });
      assert.deepEqual(requests.at(-1), { path: '/api/v1/bridges/brg-1/context-windows?provider=claude&model=opus', method: 'DELETE', body: null });
      assert.equal(row(dom, 'opus').dataset.source, 'config');
      assert.equal(row(dom, 'opus').querySelector('[data-role="context-window-value"]')!.textContent, '200K');
    } finally {
      await act(async () => root.unmount());
    }
  });
});

test('bridge errors are surfaced and the confirmed value is kept; offline bridges get no request', async () => {
  await withDom(async (dom, container, requests, setReply) => {
    const root = createRoot(container);
    try {
      await act(async () => { root.render(React.createElement(BridgeContextWindows, { bridgeId: 'brg-1', online: true })); });
      setReply(() => Response.json({ error: { code: 'validation_failed', message: 'bridge has too many context-window overrides; clear one first', details: { bridge_error: 'too_many_overrides' } } }, { status: 400 }));
      await act(async () => { button(row(dom, 'sonnet'), 'Change').click(); });
      await act(async () => { button(row(dom, 'sonnet'), '500K').click(); });
      const alert = dom.window.document.querySelector('[data-role="context-window-save-error"]');
      assert.match(alert?.textContent || '', /too many context-window overrides.*too_many_overrides/);
      assert.equal(row(dom, 'sonnet').querySelector('[data-role="context-window-value"]')!.textContent, '200K');

      const count = requests.length;
      await act(async () => { root.render(React.createElement(BridgeContextWindows, { bridgeId: 'brg-2', online: false })); });
      assert.equal(requests.length, count, 'offline bridge receives no request');
      assert.match(dom.window.document.body.textContent || '', /connect to view or change/);
      assert.equal(dom.window.document.querySelectorAll('li[data-source]').length, 0);
    } finally {
      await act(async () => root.unmount());
    }
  });
});

test('reported rows keep their badge, and the amber note shows only on mismatch (never under an override)', async () => {
  const state = normalizeContextWindowState(bridgeState([
    { provider: 'codex', model: 'gpt-a', context_window: 258400, source: 'reported', reported_window: 258400, window_mismatch: true },
    { provider: 'codex', model: 'gpt-b', context_window: 200000, source: 'reported', reported_window: 200000 },
    { provider: 'codex', model: 'gpt-c', context_window: 500000, source: 'override', reported_window: 258400, window_mismatch: true },
  ]))!;
  assert.deepEqual(state.windows.map((w) => [w.model, w.source, w.window_mismatch]), [['gpt-a', 'reported', true], ['gpt-b', 'reported', undefined], ['gpt-c', 'override', undefined]]);
  await withDom(async (dom, container, _requests, setReply) => {
    setReply(() => Response.json({ data: bridgeState([
      { provider: 'codex', model: 'gpt-a', context_window: 258400, source: 'reported', reported_window: 258400, window_mismatch: true },
      { provider: 'codex', model: 'gpt-b', context_window: 200000, source: 'reported', reported_window: 200000 },
      { provider: 'codex', model: 'gpt-c', context_window: 500000, source: 'override', reported_window: 258400, window_mismatch: true },
    ]) }));
    const root = createRoot(container);
    try {
      await act(async () => { root.render(React.createElement(BridgeContextWindows, { bridgeId: 'brg-1', online: true })); });
      const a = row(dom, 'gpt-a');
      assert.equal(a.querySelector('[data-role="context-window-source"]')!.textContent, 'Reported');
      assert.equal(a.querySelector('[data-role="context-window-value"]')!.textContent, '258,400');
      assert.match(a.querySelector('[data-role="context-window-mismatch"]')!.textContent || '', /differs from the configured window by more than 10%/);
      const b = row(dom, 'gpt-b');
      assert.equal(b.querySelector('[data-role="context-window-source"]')!.textContent, 'Reported');
      assert.equal(b.querySelector('[data-role="context-window-mismatch"]'), null);
      const c = row(dom, 'gpt-c');
      assert.equal(c.querySelector('[data-role="context-window-source"]')!.textContent, 'Override');
      assert.equal(c.querySelector('[data-role="context-window-mismatch"]'), null);
    } finally {
      await act(async () => root.unmount());
    }
  });
});

test('provider filter shows only that provider models; empty state names the provider; Bridges panel no longer renders it', async () => {
  await withDom(async (dom, container) => {
    const root = createRoot(container);
    try {
      await act(async () => { root.render(React.createElement(BridgeContextWindows, { bridgeId: 'brg-1', online: true, provider: 'claude' })); });
      const models = Array.from(dom.window.document.querySelectorAll('li[data-source]')).map((li) => li.textContent);
      assert.equal(models.length, 2);
      assert.ok(models.every((t) => t?.includes('claude /')));
      assert.doesNotMatch(dom.window.document.body.textContent || '', /gemini-3-pro/);
      assert.doesNotMatch(dom.window.document.body.textContent || '', /not in the shipped config/, 'default-count is for the filtered provider only');
      await act(async () => { root.render(React.createElement(BridgeContextWindows, { bridgeId: 'brg-1', online: true, provider: 'pi' })); });
      assert.match(dom.window.document.body.textContent || '', /No pi models known on this bridge yet/);
    } finally {
      await act(async () => root.unmount());
    }
  });
  const { readFileSync } = await import('node:fs');
  assert.doesNotMatch(readFileSync('src/ui/components/settings/BridgesPanel.tsx', 'utf8'), /BridgeContextWindows/);
  assert.match(readFileSync('src/ui/components/providers/ProviderProfilesSurface.tsx', 'utf8'), /<BridgeContextWindows[^>]*provider=\{draft\.provider\}/);
});
