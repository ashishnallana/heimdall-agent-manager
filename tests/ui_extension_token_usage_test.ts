// Per-instance token usage (chain T3r): normalization of the instance JSON's
// token_usage / token_totals, the list badge thresholds (amber >= 40 %, red >=
// 70 %), the Runtime card's context meter and lifetime totals, and that every
// piece renders nothing when the data is absent.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_extension_token_usage_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const model = await import('../src/ui/components/extension/tokenUsageModel.ts');
const view = await import('../src/ui/components/extension/TokenUsage.tsx');

const SNAPSHOT = {
  tool_calls: 12, est_tokens_total: 4200, context_tokens: 130000, context_window: 200000,
  window_source: 'config', context_pct: 65, output_tokens_total: 900, compactions: 1, run_count: 3, updated_at_ms: 1,
};
const TOTALS = { total_context_tokens: 310000, total_est_tool_tokens: 9100, total_output_tokens: 1500, runs_counted: 2, last_run_counted: 2 };

async function render(element: any): Promise<string> {
  const React = await import('react');
  const { renderToStaticMarkup } = await import('react-dom/server');
  return renderToStaticMarkup(React.createElement(React.Fragment, null, element));
}

test('normalizes the snapshot and totals; rejects absent or malformed data', () => {
  const u = model.normalizeTokenUsage(SNAPSHOT)!;
  assert.equal(u.contextPct, 65);
  assert.equal(u.contextWindow, 200000);
  assert.equal(u.windowSource, 'config');
  assert.equal(u.runCount, 3);
  for (const raw of [undefined, null, 'x', [], {}, { tool_calls: -1, est_tokens_total: 1 }, { tool_calls: 1 }]) {
    assert.equal(model.normalizeTokenUsage(raw), null, JSON.stringify(raw));
  }
  // No context reported yet: no percentage even with a window.
  assert.equal(model.normalizeTokenUsage({ tool_calls: 0, est_tokens_total: 0, context_window: 200000, compactions: 0 })!.contextPct, null);
  // Percentage derived when the bridge omitted it.
  assert.equal(model.normalizeTokenUsage({ tool_calls: 1, est_tokens_total: 1, context_tokens: 500000, context_window: 1000000 })!.contextPct, 50);
  assert.deepEqual(model.normalizeTokenTotals(TOTALS), { totalContextTokens: 310000, totalEstToolTokens: 9100, totalOutputTokens: 1500, runsCounted: 2 });
  for (const raw of [undefined, null, {}, { runs_counted: 0 }]) assert.equal(model.normalizeTokenTotals(raw), null);
});

test('badge tone: neutral below 40 %, amber at 40 %, red at 70 %', () => {
  assert.equal(model.contextTone(39), 'neutral');
  assert.equal(model.contextTone(40), 'warning');
  assert.equal(model.contextTone(69), 'warning');
  assert.equal(model.contextTone(70), 'danger');
  assert.equal(model.contextTone(100), 'danger');
  // Snapshot thresholds win over the fallback constants.
  assert.equal(model.contextTone(50, 60, 80), 'neutral');
  assert.equal(model.contextTone(65, 60, 80), 'warning');
  assert.equal(model.contextTone(80, 60, 80), 'danger');
  const snap = model.normalizeTokenUsage({ tool_calls: 0, est_tokens_total: 0, warn_pct: 30, rollover_pct: 60, compactions: 0 })!;
  assert.deepEqual([snap.warnPct, snap.rolloverPct], [30, 60]);
  const bare = model.normalizeTokenUsage({ tool_calls: 0, est_tokens_total: 0, compactions: 0 })!;
  assert.deepEqual([bare.warnPct, bare.rolloverPct], [null, null]);
  const badge = model.contextBadge({ token_usage: { ...SNAPSHOT, context_tokens: 164000, context_pct: 82 } })!;
  assert.equal(badge.tone, 'danger');
  assert.equal(badge.label, 'ctx 82%');
  assert.match(badge.tooltip, /164K of 200K tokens \(82%\)/);
  assert.match(badge.tooltip, /window: model config/);
  const custom = model.contextBadge({ token_usage: { ...SNAPSHOT, context_tokens: 100000, context_pct: 50, warn_pct: 60, rollover_pct: 80 } })!;
  assert.equal(custom.tone, 'neutral');
  const customWarn = model.contextBadge({ token_usage: { ...SNAPSHOT, context_tokens: 130000, context_pct: 65, warn_pct: 60, rollover_pct: 80 } })!;
  assert.equal(customWarn.tone, 'warning');
  assert.equal(model.contextBadge({}), null);
  assert.equal(model.contextBadge({ token_usage: { tool_calls: 0, est_tokens_total: 0, compactions: 0 } }), null, 'hidden without a context figure');
});

test('formatTokens is compact', () => {
  assert.equal(model.formatTokens(950), '950');
  assert.equal(model.formatTokens(1250), '1.2K');
  assert.equal(model.formatTokens(130000), '130K');
  assert.equal(model.formatTokens(1500000), '1.5M');
  assert.equal(model.formatTokens(475000), '475K');
});

test('list badge renders with its tone and is hidden without data', async () => {
  const amber = await render(view.ContextUsageBadge({ instance: { token_usage: SNAPSHOT }, instanceId: 'inst_a' }));
  assert.match(amber, /data-debug-id="live-instance-context-inst_a"/);
  assert.match(amber, /data-context-tone="warning"/);
  assert.match(amber, /ctx 65%/);
  assert.equal(view.ContextUsageBadge({ instance: {}, instanceId: 'inst_a' }), null);
  assert.equal(view.ContextUsageBadge({ instance: null, instanceId: 'inst_a' }), null);
});

test('Runtime card meter shows % of window and its source; totals list every sum', async () => {
  const meter = await render(view.ContextMeter({ instance: { token_usage: SNAPSHOT } }));
  assert.match(meter, /role="progressbar"/);
  assert.match(meter, /aria-valuenow="65"/);
  assert.match(meter, /65% · 130K \/ 200K tokens/);
  assert.match(meter, /window: model config/);
  assert.match(meter, /data-context-tone="warning"/);

  const pending = await render(view.ContextMeter({ instance: { token_usage: { tool_calls: 2, est_tokens_total: 40, context_window: 200000, window_source: 'default', compactions: 0 } } }));
  assert.match(pending, /No context reported yet · window 200K \(default\)/);
  assert.doesNotMatch(pending, /progressbar/);

  const totals = await render(view.TokenTotalsSummary({ instance: { token_totals: TOTALS } }));
  assert.match(totals, /data-debug-id="live-instance-total-context">310K</);
  assert.match(totals, /data-debug-id="live-instance-total-tool">9.1K</);
  assert.match(totals, /data-debug-id="live-instance-total-output">1.5K</);
  assert.match(totals, /data-debug-id="live-instance-total-runs">2</);

  assert.equal(view.ContextMeter({ instance: {} }), null);
  assert.equal(view.TokenTotalsSummary({ instance: {} }), null);
  assert.equal(view.TokenTotalsSummary({ instance: { token_totals: { runs_counted: 0 } } }), null);
});

test('instance list rows and the Runtime card render the token pieces', () => {
  const read = (rel: string) => fs.readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8');
  const list = read('../src/ui/components/agents/AgentListPage.tsx');
  assert.match(list, /<ContextUsageBadge instance=\{inst\} instanceId=\{instId\} \/>/);
  const detail = read('../src/ui/components/agents/AgentDetail.tsx');
  assert.match(detail, /<ContextMeter instance=\{inst\} \/>/);
  assert.match(detail, /<TokenTotalsSummary instance=\{inst\} \/>/);
  const ws = read('../src/ui/api/wsInvalidation.ts');
  assert.match(ws, /change === 'token_usage_changed'/);
});

test('usage_supported: unavailable copy when false, "waiting for signal" when true without a figure', async () => {
  const base = { tool_calls: 2, est_tokens_total: 40, context_window: 200000, window_source: 'default', compactions: 0, updated_at_ms: 1 };
  assert.equal(model.normalizeTokenUsage(base)!.usageSupported, null);
  assert.equal(model.normalizeTokenUsage({ ...base, usage_supported: false })!.usageSupported, false);
  assert.equal(model.normalizeTokenUsage({ ...base, usage_supported: 'no' })!.usageSupported, null);

  const off = await render(view.ContextMeter({ instance: { provider: 'antigravity', token_usage: { ...base, usage_supported: false } } }));
  assert.match(off, /Context tracking unavailable for antigravity/);
  assert.match(off, /data-context-state="unsupported"/);
  assert.doesNotMatch(off, /progressbar|No context reported|Waiting for signal/);
  assert.match(await render(view.ContextMeter({ instance: { token_usage: { ...base, usage_supported: false } } })), /unavailable for this provider/);

  const on = await render(view.ContextMeter({ instance: { provider: 'claude', token_usage: { ...base, usage_supported: true } } }));
  assert.match(on, /Waiting for signal/);
  assert.match(on, /data-context-state="waiting"/);
  assert.doesNotMatch(on, /unavailable/);

  // A real figure always wins the meter when supported.
  assert.match(await render(view.ContextMeter({ instance: { token_usage: { ...SNAPSHOT, usage_supported: true } } })), /progressbar/);

  const badge = await render(view.ContextUsageBadge({ instance: { provider: 'antigravity', token_usage: { ...base, usage_supported: false } }, instanceId: 'inst_x' }));
  assert.match(badge, /ctx n\/a/);
  assert.match(badge, /Context tracking unavailable for antigravity/);
  const waiting = await render(view.ContextUsageBadge({ instance: { provider: 'claude', token_usage: { ...base, usage_supported: true } }, instanceId: 'inst_x' }));
  assert.match(waiting, /data-context-state="waiting"/);
  assert.match(waiting, /Waiting for signal/);
  assert.doesNotMatch(waiting, /unavailable|n\/a/);
  // Unknown capability without a figure stays hidden.
  assert.equal(view.ContextUsageBadge({ instance: { token_usage: base }, instanceId: 'inst_x' }), null);
});

test('reported window shows a "reported" source and an amber note only on mismatch', async () => {
  const base = { tool_calls: 2, est_tokens_total: 40, context_tokens: 50000, context_window: 258400, window_source: 'reported', reported_window: 258400, compactions: 0, updated_at_ms: 1 };
  const ok = await render(view.ContextMeter({ instance: { token_usage: base } }));
  assert.match(ok, /window: reported/);
  assert.doesNotMatch(ok, /live-instance-window-mismatch/);
  const bad = await render(view.ContextMeter({ instance: { token_usage: { ...base, window_mismatch: true } } }));
  assert.match(bad, /window: reported/);
  assert.match(bad, /data-debug-id="live-instance-window-mismatch"/);
  assert.match(bad, /258K window/);
});

test('estimate-only snapshot renders a "~" prefix and the estimate tooltip', async () => {
  const est = { tool_calls: 5, est_tokens_total: 100000, context_source: 'estimate', estimated_context_tokens: 150000, context_window: 200000, context_pct: 75, compactions: 0, updated_at_ms: 1 };
  const u = model.normalizeTokenUsage(est)!;
  assert.equal(u.isEstimate, true);
  assert.equal(u.contextTokens, null);
  assert.equal(u.contextPct, 75);
  const badge = model.contextBadge({ token_usage: est })!;
  assert.equal(badge.label, 'ctx ~75%');
  assert.equal(badge.state, 'value');
  assert.match(badge.tooltip, /estimated from tool traffic/);
  const meter = await render(view.ContextMeter({ instance: { token_usage: est } }));
  assert.match(meter, /~75%/);
  assert.match(meter, /estimated from tool traffic/);
  // Provider figure wins: no "~".
  const real = model.normalizeTokenUsage({ ...est, context_tokens: 40000, context_pct: 20 })!;
  assert.equal(real.isEstimate, false);
  assert.equal(model.contextBadge({ token_usage: { ...est, context_tokens: 40000, context_pct: 20 } })!.label, 'ctx 20%');
  assert.doesNotMatch(await render(view.ContextMeter({ instance: { token_usage: { ...est, context_tokens: 40000, context_pct: 20 } } })), /~75|estimated from/);
});

test('estimate renders even when the provider has no usage capability (Antigravity)', async () => {
  const est = { tool_calls: 5, est_tokens_total: 100000, context_source: 'estimate', estimated_context_tokens: 150000, context_window: 200000, context_pct: 75, usage_supported: false, compactions: 0, updated_at_ms: 1 };
  const badge = model.contextBadge({ provider: 'antigravity', token_usage: est })!;
  assert.equal(badge.state, 'value');
  assert.equal(badge.label, 'ctx ~75%');
  const meter = await render(view.ContextMeter({ instance: { provider: 'antigravity', token_usage: est } }));
  assert.match(meter, /~75%/);
  assert.doesNotMatch(meter, /unavailable/);
  // Without any figure it is still unsupported.
  assert.equal(model.contextBadge({ token_usage: { ...est, context_source: undefined, estimated_context_tokens: undefined, context_pct: undefined } })!.state, 'unsupported');
});
