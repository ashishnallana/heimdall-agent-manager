// Per-chain token usage (chain "Estimate agent tokens via extensions", T10).
// Pure logic, no React and no fetch (tests/ui_task_v2_chain_token_usage_test.ts).
//
// Normalizes GET /api/v1/task-chains/{id}/token-usage:
//   {chain_id, has_data, instances, instances_with_data, warn_pct, rollover_pct,
//    total: Figures, agents: [{agent_id, agent_name, has_data, live_instances,
//    lifetime: Figures, context?: {pct, tokens, window, agent_instance_id},
//    instances: [{agent_instance_id, display_name, runtime_status, live, has_data,
//    snapshot_counted, lifetime: Figures, counted?: Figures, run_count?,
//    context_pct?, context_tokens?, context_window?, window_source?}]}]}
//   Figures = {total_tokens, context_tokens, est_tool_tokens, output_tokens, runs}
// total_tokens is context (sum of each run's context) + output, computed by the hub.
import { contextTone, resolveThresholds, type ContextTone, type Thresholds } from '../extension/tokenUsageModel';

export interface ChainTokenFigures {
  totalTokens: number;
  contextTokens: number;
  estToolTokens: number;
  outputTokens: number;
  runs: number;
}

export interface ChainTokenContext {
  pct: number;
  tokens: number;
  window: number | null;
  tone: ContextTone;
  /** True when tokens/pct come from the bridge's tool-traffic estimate. */
  isEstimate: boolean;
}

export interface ChainTokenInstance {
  instanceId: string;
  displayName: string;
  runtimeStatus: string;
  /** Provider id (claude, codex, ...); '' when the hub did not send it. */
  provider: string;
  live: boolean;
  hasData: boolean;
  lifetime: ChainTokenFigures;
  runCount: number | null;
  /** Current % of window; null unless live with a reported context. */
  context: ChainTokenContext | null;
  /** false = provider cannot report context usage; null = not reported. */
  usageSupported: boolean | null;
}

export interface ChainTokenAgent {
  agentId: string;
  /** Display name, falling back to the agent id. */
  name: string;
  hasData: boolean;
  liveInstances: number;
  lifetime: ChainTokenFigures;
  /** Highest current context % among live instances; null when none. */
  context: (ChainTokenContext & { instanceId: string }) | null;
  /**
   * Context capability of the agent's LIVE instances (stopped ones are history):
   *  unsupported = every live instance reports usage_supported=false;
   *  waiting     = some live instance can report but has no figure yet;
   *  unknown     = live instances exist but capability is not (fully) reported;
   *  none        = no live instance.
   */
  contextCapability: 'unsupported' | 'waiting' | 'unknown' | 'none';
  /** Providers of the live unsupported instances, de-duplicated (for the unavailable copy). */
  unsupportedProviders: string[];
  instances: ChainTokenInstance[];
}

export interface ChainTokenUsage {
  hasData: boolean;
  instances: number;
  instancesWithData: number;
  warnPct: number;
  rolloverPct: number;
  total: ChainTokenFigures;
  agents: ChainTokenAgent[];
}

const ZERO: ChainTokenFigures = { totalTokens: 0, contextTokens: 0, estToolTokens: 0, outputTokens: 0, runs: 0 };

function count(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? Math.floor(value) : null;
}

function isObject(raw: unknown): raw is Record<string, any> {
  return !!raw && typeof raw === 'object' && !Array.isArray(raw);
}

export function normalizeFigures(raw: unknown): ChainTokenFigures {
  if (!isObject(raw)) return { ...ZERO };
  const contextTokens = count(raw.context_tokens) ?? 0;
  const outputTokens = count(raw.output_tokens) ?? 0;
  return {
    totalTokens: count(raw.total_tokens) ?? contextTokens + outputTokens,
    contextTokens,
    estToolTokens: count(raw.est_tool_tokens) ?? 0,
    outputTokens,
    runs: count(raw.runs) ?? 0,
  };
}

function makeContext(pct: number | null, tokens: unknown, window: unknown, row: Record<string, any>, summary: Thresholds, estimate = false): ChainTokenContext | null {
  if (pct === null) return null;
  // The row's own snapshot thresholds win; the summary pair is only the fallback for rows that carry none.
  const th = row.warn_pct != null && row.rollover_pct != null ? resolveThresholds(count(row.warn_pct), count(row.rollover_pct)) : summary;
  return { pct, tokens: count(tokens) ?? 0, window: count(window) || null, tone: contextTone(pct, th.warnPct, th.rolloverPct), isEstimate: estimate };
}

function normalizeInstance(raw: unknown, th: Thresholds): ChainTokenInstance | null {
  if (!isObject(raw)) return null;
  const instanceId = String(raw.agent_instance_id || '').trim();
  if (!instanceId) return null;
  const live = raw.live === true;
  return {
    instanceId,
    displayName: String(raw.display_name || '').trim(),
    runtimeStatus: String(raw.runtime_status || ''),
    provider: String(raw.provider || '').trim(),
    live,
    hasData: raw.has_data === true,
    lifetime: normalizeFigures(raw.lifetime),
    runCount: count(raw.run_count),
    context: live ? (() => {
      const est = raw.context_source === 'estimate' && count(raw.context_tokens) === null;
      return makeContext(count(raw.context_pct), est ? raw.estimated_context_tokens : raw.context_tokens, raw.context_window, raw, th, est);
    })() : null,
    usageSupported: typeof raw.usage_supported === 'boolean' ? raw.usage_supported : null,
  };
}

function liveCapability(instances: ChainTokenInstance[]): Pick<ChainTokenAgent, 'contextCapability' | 'unsupportedProviders'> {
  const live = instances.filter((i) => i.live);
  const off = live.filter((i) => i.usageSupported === false);
  const unsupportedProviders = [...new Set(off.map((i) => i.provider).filter(Boolean))];
  if (live.length === 0) return { contextCapability: 'none', unsupportedProviders: [] };
  if (live.some((i) => i.usageSupported === true)) return { contextCapability: 'waiting', unsupportedProviders };
  if (off.length === live.length) return { contextCapability: 'unsupported', unsupportedProviders };
  return { contextCapability: 'unknown', unsupportedProviders };
}

function normalizeAgent(raw: unknown, th: Thresholds): ChainTokenAgent | null {
  if (!isObject(raw)) return null;
  const agentId = String(raw.agent_id || '').trim();
  const instances = (Array.isArray(raw.instances) ? raw.instances : [])
    .map((i: unknown) => normalizeInstance(i, th))
    .filter((i: ChainTokenInstance | null): i is ChainTokenInstance => i !== null);
  if (!agentId && instances.length === 0) return null;
  const ctx = isObject(raw.context) ? raw.context : null;
  const context = ctx ? makeContext(count(ctx.pct), ctx.tokens, ctx.window, ctx, th, ctx.context_source === 'estimate') : null;
  return {
    agentId,
    name: String(raw.agent_name || '').trim() || agentId || 'Unknown agent',
    hasData: raw.has_data === true,
    liveInstances: count(raw.live_instances) ?? 0,
    lifetime: normalizeFigures(raw.lifetime),
    context: context ? { ...context, instanceId: String(ctx?.agent_instance_id || '') } : null,
    ...liveCapability(instances),
    instances,
  };
}

/** Normalizes the endpoint payload (or its {data} envelope); null when unusable. */
export function normalizeChainTokenUsage(raw: unknown): ChainTokenUsage | null {
  const body = isObject(raw) && isObject(raw.data) && !('agents' in raw) ? raw.data : raw;
  if (!isObject(body)) return null;
  // Hub-sent thresholds (from the bridge's shipped config); constants only when absent.
  const th: Thresholds = resolveThresholds(count(body.warn_pct), count(body.rollover_pct));
  const agents = (Array.isArray(body.agents) ? body.agents : [])
    .map((a: unknown) => normalizeAgent(a, th))
    .filter((a: ChainTokenAgent | null): a is ChainTokenAgent => a !== null);
  return {
    hasData: body.has_data === true && agents.some((a: ChainTokenAgent) => a.hasData),
    instances: count(body.instances) ?? agents.reduce((n: number, a: ChainTokenAgent) => n + a.instances.length, 0),
    instancesWithData: count(body.instances_with_data) ?? 0,
    ...th,
    total: normalizeFigures(body.total),
    agents,
  };
}

/** Each agent's share of the chain total, as a whole % (0 when the total is 0). */
export function shareOfTotal(part: ChainTokenFigures, total: ChainTokenFigures): number {
  if (!total.totalTokens) return 0;
  return Math.round((part.totalTokens * 100) / total.totalTokens);
}
