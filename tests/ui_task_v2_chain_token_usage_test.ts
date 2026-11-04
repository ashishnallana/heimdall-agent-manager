// Task chain overview token usage (T10): normalization of
// GET /task-chains/{id}/token-usage, the per-agent rows (lifetime total, current
// context %), per-instance rows, the chain total, the empty state, and that
// token_usage_changed on a chain instance refreshes the chain's usage.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_task_v2_chain_token_usage_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const model = await import('../src/ui/components/taskchain/chainTokenUsageModel.ts');
const view = await import('../src/ui/components/taskchain/ChainTokenUsage.tsx');

const fig = (ctx: number, tool: number, out: number, runs: number) => ({ total_tokens: ctx + out, context_tokens: ctx, est_tool_tokens: tool, output_tokens: out, runs });

const PAYLOAD = {
  chain_id: 'chain_a', has_data: true, instances: 4, instances_with_data: 3, warn_pct: 40, rollover_pct: 70,
  total: fig(530000, 7840, 4920, 5),
  agents: [
    {
      agent_id: 'agt_worker', agent_name: 'Worker', has_data: true, live_instances: 2,
      lifetime: fig(510000, 7800, 4920, 4),
      context: { pct: 85, tokens: 170000, window: 200000, agent_instance_id: 'inst_w1' },
      instances: [
        { agent_instance_id: 'inst_w1', display_name: 'worker #1', runtime_status: 'running', live: true, has_data: true, snapshot_counted: false, lifetime: fig(430000, 7500, 4900, 3), run_count: 3, context_pct: 85, context_tokens: 170000, context_window: 200000, window_source: 'config' },
        { agent_instance_id: 'inst_w2', display_name: 'worker #2', runtime_status: 'stopped', live: false, has_data: true, snapshot_counted: true, lifetime: fig(80000, 300, 20, 1), run_count: 4, context_pct: 25 },
        { agent_instance_id: 'inst_w3', display_name: '', runtime_status: 'idle', live: true, has_data: false, snapshot_counted: false, lifetime: fig(0, 0, 0, 0) },
      ],
    },
    {
      agent_id: 'agt_coord', agent_name: '', has_data: true, live_instances: 0,
      lifetime: fig(20000, 40, 0, 1),
      instances: [{ agent_instance_id: 'inst_c1', display_name: 'coord', runtime_status: 'stopped', live: false, has_data: true, snapshot_counted: false, lifetime: fig(20000, 40, 0, 1), run_count: 1 }],
    },
  ],
};

async function render(element: any): Promise<string> {
  const React = await import('react');
  const { renderToStaticMarkup } = await import('react-dom/server');
  return renderToStaticMarkup(React.createElement(React.Fragment, null, element));
}

test('normalizes the payload (and its {data} envelope); per-agent and per-instance figures', () => {
  const u = model.normalizeChainTokenUsage(PAYLOAD)!;
  assert.ok(u.hasData);
  assert.equal(u.agents.length, 2);
  assert.deepEqual(u.total, { totalTokens: 534920, contextTokens: 530000, estToolTokens: 7840, outputTokens: 4920, runs: 5 });
  const w = u.agents[0];
  assert.equal(w.name, 'Worker');
  assert.equal(w.context!.pct, 85);
  assert.equal(w.context!.tone, 'danger');
  assert.equal(w.context!.instanceId, 'inst_w1');
  assert.equal(w.instances[0].context!.tone, 'danger');
  // A stopped instance never shows a "current" context %, even if one is sent.
  assert.equal(w.instances[1].context, null);
  assert.equal(w.instances[2].hasData, false);
  // Unnamed agent falls back to its id; no live instance -> no context.
  assert.equal(u.agents[1].name, 'agt_coord');
  assert.equal(u.agents[1].context, null);
  assert.equal(model.shareOfTotal(w.lifetime, u.total), 96);
  assert.deepEqual(model.normalizeChainTokenUsage({ data: PAYLOAD }), u);
});

test('missing / malformed data yields the empty state, never a crash', async () => {
  for (const raw of [undefined, null, 'x', [], {}, { has_data: false, agents: [] }, { has_data: true, agents: [{ agent_id: 'a', has_data: false, instances: [] }] }]) {
    const u = model.normalizeChainTokenUsage(raw);
    assert.ok(!u || !u.hasData, JSON.stringify(raw));
    const html = await render(view.ChainTokenUsageView({ usage: u }));
    assert.match(html, /data-debug-id="chain-token-usage-empty"/);
    assert.match(html, /No token usage reported yet/);
  }
  // Partial figures default to 0, total derived from context + output.
  assert.deepEqual(model.normalizeFigures({ context_tokens: 10, output_tokens: 5 }), { totalTokens: 15, contextTokens: 10, estToolTokens: 0, outputTokens: 5, runs: 0 });
  assert.deepEqual(model.normalizeFigures({ context_tokens: -3, runs: 'x' }), { totalTokens: 0, contextTokens: 0, estToolTokens: 0, outputTokens: 0, runs: 0 });
});

test('renders per-agent rows (lifetime + context %), instance rows and the chain total', async () => {
  const html = await render(view.ChainTokenUsageView({ usage: model.normalizeChainTokenUsage(PAYLOAD) }));
  assert.match(html, /data-debug-id="chain-token-usage-table"/);
  assert.match(html, /data-debug-id="chain-token-usage-agent-agt_worker"/);
  assert.match(html, /data-debug-id="chain-token-usage-agent-total-agt_worker"[^>]*>514K</);
  assert.match(html, /data-debug-id="chain-token-usage-agent-context-agt_worker" data-context-tone="danger"/);
  assert.match(html, />85%</);
  assert.match(html, /96% of chain/);
  assert.match(html, /data-debug-id="chain-token-usage-agent-context-agt_coord"[^>]*>—</);
  assert.match(html, /data-debug-id="chain-token-usage-instance-inst_w1"/);
  assert.match(html, /data-debug-id="chain-token-usage-instance-inst_w3"/);
  assert.match(html, /data-debug-id="chain-token-usage-total-value"[^>]*>534K</);
  assert.match(html, /Chain total/);
  assert.match(html, /warn 40%, rollover 70%/);
});

test('token usage lives in the Chain overview panel, not the ticket board; token_usage_changed refreshes the chain usage tag', () => {
  const read = (rel: string) => fs.readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8');
  const panel = read('../src/ui/components/chat/ChainOverviewPanel.tsx');
  assert.match(panel, /data-debug-id="chain-overview-section-token-usage"/);
  assert.match(panel, /data-debug-id="chain-overview-section-toggle-tokenUsage"/);
  assert.match(panel, /<ChainTokenUsageSection chainId=\{chainId\} embedded \/>/);
  assert.doesNotMatch(read('../src/ui/components/taskchain/TaskChainOverview.tsx'), /ChainTokenUsage|footerSlot/);
  assert.doesNotMatch(read('../src/ui/components/tasks/TicketBoardView.tsx'), /footerSlot|ChainTokenUsage/);
  const ws = read('../src/ui/api/wsInvalidation.ts');
  // T14: paced per viewed chain (chainTokenUsageRefresh.ts), not one refetch per event.
  assert.match(ws, /tokenChanged \|\| change === 'created'[\s\S]{0,200}requestChainTokenUsageRefresh\(tokenChainId[\s\S]{0,120}type: 'ChainTokenUsage', id \}/);
  assert.match(read('../src/ui/api/endpoints/taskChains.ts'), /\/task-chains\/\$\{encodeURIComponent\(chainId\)\}\/token-usage/);
});

test('chain rows: waiting / unavailable(provider) come from LIVE instances only', async () => {
  const inst = (id: string, live: boolean, extra: Record<string, unknown>) => ({
    agent_instance_id: id, display_name: id, runtime_status: live ? 'running' : 'stopped', live, has_data: true,
    snapshot_counted: false, lifetime: fig(1000, 10, 10, 1), ...extra,
  });
  const agent = (id: string, instances: any[]) => ({ agent_id: id, agent_name: id, has_data: true, live_instances: instances.filter((i) => i.live).length, lifetime: fig(1000, 10, 10, 1), instances });
  const payload = {
    has_data: true, total: fig(1000, 10, 10, 1),
    agents: [
      agent('a_wait', [inst('w1', true, { provider: 'claude', usage_supported: true })]),
      agent('a_off', [inst('o1', true, { provider: 'antigravity', usage_supported: false })]),
      // stopped supported instance must not hide the live unsupported one
      agent('a_mixed1', [inst('m1', false, { provider: 'claude', usage_supported: true }), inst('m2', true, { provider: 'antigravity', usage_supported: false })]),
      // stopped unsupported + live unknown => unknown (dash), not unavailable
      agent('a_mixed2', [inst('n1', false, { provider: 'antigravity', usage_supported: false }), inst('n2', true, { provider: 'claude' })]),
      agent('a_stopped', [inst('s1', false, { provider: 'antigravity', usage_supported: false })]),
    ],
  };
  const u = model.normalizeChainTokenUsage(payload)!;
  const cap = Object.fromEntries(u.agents.map((a: any) => [a.agentId, a.contextCapability]));
  assert.deepEqual(cap, { a_wait: 'waiting', a_off: 'unsupported', a_mixed1: 'unsupported', a_mixed2: 'unknown', a_stopped: 'none' });
  assert.deepEqual(u.agents.find((a: any) => a.agentId === 'a_mixed1')!.unsupportedProviders, ['antigravity']);

  const html = await render(view.ChainTokenUsageView({ usage: u }));
  const cell = (id: string) => html.match(new RegExp(`data-debug-id="${id}"[^>]*>[^<]*`))![0];
  assert.match(cell('chain-token-usage-agent-context-a_wait'), /data-context-state="waiting"[^>]*title="Waiting for signal"/);
  assert.match(cell('chain-token-usage-agent-context-a_off'), /data-context-state="unsupported"[^>]*title="Context tracking unavailable for antigravity"/);
  assert.match(cell('chain-token-usage-agent-context-a_mixed1'), /unavailable for antigravity/);
  assert.match(cell('chain-token-usage-agent-context-a_mixed2'), />—$/);
  assert.match(cell('chain-token-usage-agent-context-a_stopped'), />—$/);
  assert.match(cell('chain-token-usage-instance-context-o1'), /unavailable for antigravity/);
  assert.match(cell('chain-token-usage-instance-context-w1'), /data-context-state="waiting"/);
});

test('contexts use their own snapshot thresholds, not the first/historical pair', () => {
  const inst = (id: string, live: boolean, th: [number, number] | null) => ({
    agent_instance_id: id, display_name: id, runtime_status: live ? 'running' : 'stopped', live, has_data: true,
    snapshot_counted: false, lifetime: fig(1000, 10, 10, 1), ...(live ? { context_pct: 75, context_tokens: 150000, context_window: 200000 } : {}),
    ...(th ? { warn_pct: th[0], rollover_pct: th[1] } : {}),
  });
  const payload = {
    has_data: true, warn_pct: 40, rollover_pct: 70, total: fig(1000, 10, 10, 1),
    agents: [
      { agent_id: 'a1', agent_name: 'a1', has_data: true, live_instances: 1, lifetime: fig(1, 1, 1, 1),
        context: { pct: 75, tokens: 150000, window: 200000, agent_instance_id: 'live', warn_pct: 60, rollover_pct: 80 },
        instances: [inst('old', false, [40, 70]), inst('live', true, [60, 80])] },
      // no per-row pair -> summary pair (40/70) applies: 75% is danger
      { agent_id: 'a2', agent_name: 'a2', has_data: true, live_instances: 1, lifetime: fig(1, 1, 1, 1),
        context: { pct: 75, tokens: 150000, window: 200000, agent_instance_id: 'x' }, instances: [inst('x', true, null)] },
    ],
  };
  const u = model.normalizeChainTokenUsage(payload)!;
  assert.equal(u.agents[0].context!.tone, 'warning');
  assert.equal(u.agents[0].instances[1].context!.tone, 'warning');
  assert.equal(u.agents[1].context!.tone, 'danger');
});

test('chain context carries estimate provenance and effective tokens', async () => {
  const fig0 = fig(1000, 10, 10, 1);
  const payload = {
    has_data: true, total: fig0,
    agents: [{
      agent_id: 'a1', agent_name: 'a1', has_data: true, live_instances: 1, lifetime: fig0,
      context: { pct: 75, tokens: 150000, window: 200000, context_source: 'estimate', agent_instance_id: 'e1' },
      instances: [{ agent_instance_id: 'e1', display_name: 'e1', runtime_status: 'running', live: true, has_data: true, snapshot_counted: false, lifetime: fig0,
        usage_supported: false, context_pct: 75, context_source: 'estimate', estimated_context_tokens: 150000, context_window: 200000 }],
    }],
  };
  const u = model.normalizeChainTokenUsage(payload)!;
  assert.equal(u.agents[0].context!.isEstimate, true);
  assert.equal(u.agents[0].context!.tokens, 150000);
  assert.equal(u.agents[0].instances[0].context!.isEstimate, true);
  assert.equal(u.agents[0].instances[0].context!.tokens, 150000);
  const html = await render(view.ChainTokenUsageView({ usage: u }));
  assert.match(html, /~75%/);
  assert.match(html, /estimated from tool traffic/);
  assert.match(html, /~150K/);
});

// Hidden panes stay mounted (PaneVisibilityProvider), and ChainTokenUsageSection holds a
// viewer registration (retainChainTokenUsageView) until unmount. The overview therefore
// mounts the section only while the panel is visible AND the section is expanded, so a
// hidden pane releases the viewer (no token-usage refetch) and re-mounting catches up
// via the stale-on-mount refetch. Source-level check, like the sibling relocation test.
test('overview mounts token usage only while the pane is visible (hidden pane = no viewer, no refetch)', () => {
  const panel = fs.readFileSync(fileURLToPath(new URL('../src/ui/components/chat/ChainOverviewPanel.tsx', import.meta.url)), 'utf8');
  assert.match(panel, /const panelVisible = usePaneVisible\(\)/);
  assert.match(panel, /!isCollapsed\('tokenUsage'\) && panelVisible && <ChainTokenUsageSection chainId=\{chainId\} embedded \/>/);
  const section = fs.readFileSync(fileURLToPath(new URL('../src/ui/components/taskchain/ChainTokenUsage.tsx', import.meta.url)), 'utf8');
  assert.match(section, /retainChainTokenUsageView\(chainId\)[\s\S]{0,200}if \(view\.stale && !fetchingRef\.current\) refetch\(\)[\s\S]{0,60}return view\.release/);
});

test('chain overview agent controls render without hover or focus gating', () => {
  const panel = fs.readFileSync(fileURLToPath(new URL('../src/ui/components/chat/ChainOverviewPanel.tsx', import.meta.url)), 'utf8');
  const rowStart = panel.indexOf('data-debug-id={`chain-overview-agent-row-${instId}`}');
  const rowEnd = panel.indexOf('chain-overview-restart-agent-${instId}', rowStart);
  assert.ok(rowStart > 0 && rowEnd > rowStart, 'agent row block found');
  const row = panel.slice(rowStart, rowEnd);
  const wrapper = row.match(/<div\s+className="([^"]*)"\s+onClick=\{\(e\) => e\.stopPropagation\(\)\}/);
  assert.ok(wrapper, 'controls wrapper with stopPropagation found');
  const classes = wrapper![1].split(/\s+/);
  assert.ok(classes.includes('flex') && classes.includes('shrink-0'), 'controls are always flex and never shrink');
  assert.ok(!classes.includes('hidden'), 'controls are not hidden');
  assert.ok(!classes.some((c) => c.startsWith('group-hover:') || c.startsWith('group-focus-within:')), 'no hover/focus gating');
  for (const id of ['open-pty', 'start-agent', 'stop-agent']) {
    assert.ok(row.includes(`chain-overview-${id}-\${instId}`), `${id} debug id kept`);
  }
  assert.ok(row.includes('min-w-0 flex-1 truncate'), 'ticket title still truncates');
});
