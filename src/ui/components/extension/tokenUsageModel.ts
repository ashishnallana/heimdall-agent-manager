// Per-instance token usage (chain "Estimate agent tokens via extensions", T3r).
// Pure logic, no React and no fetch (tests/ui_extension_token_usage_test.ts).
//
// The agent instance JSON carries, when known:
//   token_usage  {tool_calls, est_tokens_total, context_tokens?, context_source?,
//                 estimated_context_tokens? (context_source "estimate": tool-traffic estimate), context_window?,
//                 window_source?, warn_pct?, rollover_pct?, context_pct?, output_tokens_total?, compactions,
//                 run_count?, usage_supported?, updated_at_ms}  (latest bridge snapshot)
//   token_totals {total_context_tokens, total_est_tool_tokens, total_output_tokens,
//                 runs_counted, last_run_counted}  (added at each hub stop/restart)

/** FALLBACK thresholds only: the bridge's shipped config is authoritative and sends warn_pct/rollover_pct on the snapshot. */
const CONTEXT_WARN_PCT = 40;
const CONTEXT_ROLLOVER_PCT = 70;

export interface Thresholds { warnPct: number; rolloverPct: number }

/** The ONLY place the fallback constants are applied: live (bridge-reported) values win; absent/invalid -> constants. */
export function resolveThresholds(warnPct?: number | null, rolloverPct?: number | null): Thresholds {
  const ok = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v) && v > 0;
  return { warnPct: ok(warnPct) ? warnPct : CONTEXT_WARN_PCT, rolloverPct: ok(rolloverPct) ? rolloverPct : CONTEXT_ROLLOVER_PCT };
}

export type ContextTone = 'neutral' | 'warning' | 'danger';
export type WindowSource = 'override' | 'reported' | 'config' | 'default' | '';

export interface TokenUsageSnapshot {
  toolCalls: number;
  estTokensTotal: number;
  contextTokens: number | null;
  /** True when contextPct comes from the bridge's tool-traffic estimate (no provider usage block). */
  isEstimate: boolean;
  /** Tokens behind contextPct: the provider figure, else the estimate. */
  effectiveContextTokens: number | null;
  contextWindow: number | null;
  windowSource: WindowSource;
  /** Thresholds from the bridge config; null = not reported (fallback constants apply). */
  warnPct: number | null;
  rolloverPct: number | null;
  /** Window the provider itself reported; null when none. */
  reportedWindow: number | null;
  /** Reported window differs from the config/default window by more than 10%. */
  windowMismatch: boolean;
  /** Whole % of the window; null until the provider reported a context size. */
  contextPct: number | null;
  outputTokensTotal: number | null;
  compactions: number;
  runCount: number | null;
  /** Provider emits usage.context_tokens (hello "usage" capability); null = not reported (Pi, older bridge). */
  usageSupported: boolean | null;
}

export interface TokenTotals {
  totalContextTokens: number;
  totalEstToolTokens: number;
  totalOutputTokens: number;
  runsCounted: number;
}

function count(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? Math.floor(value) : null;
}

function isObject(raw: unknown): raw is Record<string, unknown> {
  return !!raw && typeof raw === 'object' && !Array.isArray(raw);
}

export function normalizeTokenUsage(raw: unknown): TokenUsageSnapshot | null {
  if (!isObject(raw)) return null;
  const toolCalls = count(raw.tool_calls);
  const est = count(raw.est_tokens_total);
  if (toolCalls === null || est === null) return null;
  const contextTokens = count(raw.context_tokens);
  const contextWindow = count(raw.context_window) || null;
  const source = raw.window_source;
  const estimated = raw.context_source === 'estimate' ? count(raw.estimated_context_tokens) : null;
  const isEstimate = contextTokens === null && estimated !== null;
  const effectiveContextTokens = contextTokens ?? (isEstimate ? estimated : null);
  let contextPct = count(raw.context_pct);
  if (contextPct === null && effectiveContextTokens !== null && contextWindow) contextPct = Math.floor((effectiveContextTokens * 100) / contextWindow);
  if (effectiveContextTokens === null) contextPct = null;
  return {
    toolCalls,
    estTokensTotal: est,
    contextTokens,
    isEstimate,
    effectiveContextTokens,
    contextWindow,
    warnPct: count(raw.warn_pct) || null,
    rolloverPct: count(raw.rollover_pct) || null,
    windowSource: source === 'override' || source === 'reported' || source === 'config' || source === 'default' ? source : '',
    reportedWindow: count(raw.reported_window) || null,
    windowMismatch: raw.window_mismatch === true,
    contextPct,
    outputTokensTotal: count(raw.output_tokens_total),
    compactions: count(raw.compactions) ?? 0,
    runCount: count(raw.run_count),
    usageSupported: typeof raw.usage_supported === 'boolean' ? raw.usage_supported : null,
  };
}

export function normalizeTokenTotals(raw: unknown): TokenTotals | null {
  if (!isObject(raw)) return null;
  const runs = count(raw.runs_counted);
  if (!runs) return null;
  return {
    totalContextTokens: count(raw.total_context_tokens) ?? 0,
    totalEstToolTokens: count(raw.total_est_tool_tokens) ?? 0,
    totalOutputTokens: count(raw.total_output_tokens) ?? 0,
    runsCounted: runs,
  };
}

/** amber at >= warnPct, red at >= rolloverPct (snapshot values; constants are the fallback). Display only: nothing is sent to the agent. */
export function contextTone(pct: number, warnPct?: number | null, rolloverPct?: number | null): ContextTone {
  const th = resolveThresholds(warnPct, rolloverPct);
  if (pct >= th.rolloverPct) return 'danger';
  if (pct >= th.warnPct) return 'warning';
  return 'neutral';
}

/** Compact token count: 950, 1.2K, 130K, 1.5M. */
export function formatTokens(n: number): string {
  if (!Number.isFinite(n) || n < 0) return '0';
  if (n < 1000) return String(Math.floor(n));
  if (n < 1_000_000) {
    const k = n / 1000;
    return `${k < 10 ? (Math.floor(k * 10) / 10).toString() : Math.floor(k).toString()}K`;
  }
  const m = n / 1_000_000;
  return `${m < 10 ? (Math.floor(m * 10) / 10).toString() : Math.floor(m).toString()}M`;
}

export function windowSourceLabel(source: WindowSource): string {
  switch (source) {
    case 'override': return 'user override';
    case 'reported': return 'reported';
    case 'config': return 'model config';
    case 'default': return 'default';
    default: return '';
  }
}

/** What the context UI shows: a figure, "waiting for signal", or "unavailable" (provider cannot report). */
export type ContextTrackingState = 'value' | 'waiting' | 'unsupported';

export function contextTrackingState(usage: TokenUsageSnapshot): ContextTrackingState {
  // A figure (provider or tool-traffic estimate) always renders, even when the provider lacks the usage capability.
  if (usage.contextPct !== null) return 'value';
  if (usage.usageSupported === false) return 'unsupported';
  return usage.contextPct === null ? 'waiting' : 'value';
}

export function contextUnavailableText(provider?: unknown): string {
  const name = typeof provider === 'string' ? provider.trim() : '';
  return `Context tracking unavailable for ${name || 'this provider'}`;
}

export const CONTEXT_ESTIMATE_TEXT = 'estimated from tool traffic';

export const CONTEXT_WAITING_TEXT = 'Waiting for signal';

export interface ContextBadgeModel {
  pct: number | null;
  /** value = figure; waiting = capable provider, no signal yet; unsupported = provider cannot report. */
  state: ContextTrackingState;
  tone: ContextTone;
  label: string;
  tooltip: string;
}

/** The instance-list context badge, or null when there is nothing to say (no snapshot, or unknown capability without a figure). */
export function contextBadge(instance: any): ContextBadgeModel | null {
  const usage = normalizeTokenUsage(instance?.token_usage);
  if (!usage) return null;
  if (contextTrackingState(usage) === 'unsupported') {
    return { pct: null, state: 'unsupported', tone: 'neutral', label: 'ctx n/a', tooltip: contextUnavailableText(instance?.provider) };
  }
  if (usage.contextPct === null) {
    if (usage.usageSupported !== true) return null;
    return { pct: null, state: 'waiting', tone: 'neutral', label: 'ctx …', tooltip: CONTEXT_WAITING_TEXT };
  }
  const pct = usage.contextPct;
  const window = usage.contextWindow ? formatTokens(usage.contextWindow) : '';
  const source = windowSourceLabel(usage.windowSource);
  const tooltip = [
    `Context ${usage.isEstimate ? '~' : ''}${formatTokens(usage.effectiveContextTokens ?? 0)}${window ? ` of ${window}` : ''} tokens (${usage.isEstimate ? '~' : ''}${pct}%)`,
    usage.isEstimate ? CONTEXT_ESTIMATE_TEXT : '',
    source ? `window: ${source}` : '',
  ].filter(Boolean).join(' · ');
  return { pct, state: 'value', tone: contextTone(pct, usage.warnPct, usage.rolloverPct), label: `ctx ${usage.isEstimate ? '~' : ''}${pct}%`, tooltip };
}
