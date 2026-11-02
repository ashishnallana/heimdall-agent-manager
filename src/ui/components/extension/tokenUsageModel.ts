// Per-instance token usage (chain "Estimate agent tokens via extensions", T3r).
// Pure logic, no React and no fetch (tests/ui_extension_token_usage_test.ts).
//
// The agent instance JSON carries, when known:
//   token_usage  {tool_calls, est_tokens_total, context_tokens?, context_window?,
//                 window_source?, context_pct?, output_tokens_total?, compactions,
//                 run_count?, updated_at_ms}  (latest bridge snapshot)
//   token_totals {total_context_tokens, total_est_tool_tokens, total_output_tokens,
//                 runs_counted, last_run_counted}  (added at each hub stop/restart)

/** Thresholds shared with the bridge's shipped config. */
export const CONTEXT_WARN_PCT = 60;
export const CONTEXT_ROLLOVER_PCT = 80;

export type ContextTone = 'neutral' | 'warning' | 'danger';
export type WindowSource = 'override' | 'config' | 'default' | '';

export interface TokenUsageSnapshot {
  toolCalls: number;
  estTokensTotal: number;
  contextTokens: number | null;
  contextWindow: number | null;
  windowSource: WindowSource;
  /** Whole % of the window; null until the provider reported a context size. */
  contextPct: number | null;
  outputTokensTotal: number | null;
  compactions: number;
  runCount: number | null;
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
  let contextPct = count(raw.context_pct);
  if (contextPct === null && contextTokens !== null && contextWindow) contextPct = Math.floor((contextTokens * 100) / contextWindow);
  if (contextTokens === null) contextPct = null;
  return {
    toolCalls,
    estTokensTotal: est,
    contextTokens,
    contextWindow,
    windowSource: source === 'override' || source === 'config' || source === 'default' ? source : '',
    contextPct,
    outputTokensTotal: count(raw.output_tokens_total),
    compactions: count(raw.compactions) ?? 0,
    runCount: count(raw.run_count),
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

/** amber at >= 60 % (warn), red at >= 80 % (rollover threshold). */
export function contextTone(pct: number): ContextTone {
  if (pct >= CONTEXT_ROLLOVER_PCT) return 'danger';
  if (pct >= CONTEXT_WARN_PCT) return 'warning';
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
    case 'config': return 'model config';
    case 'default': return 'default';
    default: return '';
  }
}

export interface ContextBadgeModel {
  pct: number;
  tone: ContextTone;
  label: string;
  tooltip: string;
}

/** The instance-list context badge, or null when there is no context figure. */
export function contextBadge(instance: any): ContextBadgeModel | null {
  const usage = normalizeTokenUsage(instance?.token_usage);
  if (!usage || usage.contextPct === null) return null;
  const pct = usage.contextPct;
  const window = usage.contextWindow ? formatTokens(usage.contextWindow) : '';
  const source = windowSourceLabel(usage.windowSource);
  const tooltip = [
    `Context ${formatTokens(usage.contextTokens ?? 0)}${window ? ` of ${window}` : ''} tokens (${pct}%)`,
    source ? `window: ${source}` : '',
  ].filter(Boolean).join(' · ');
  return { pct, tone: contextTone(pct), label: `ctx ${pct}%`, tooltip };
}
