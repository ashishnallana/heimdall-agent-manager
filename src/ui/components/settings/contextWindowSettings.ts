// Context-window settings helpers (chain "Estimate agent tokens via extensions", T9).
//
// The bridge owns the shipped config and the user overrides; the hub relays
// GET/PUT/DELETE /api/v1/bridges/{id}/context-windows to it. Every reply is the
// bridge's full state, so the UI always re-renders from the latest reply.

import { resolveThresholds } from '../extension/tokenUsageModel';

export type ContextWindowSource = 'override' | 'reported' | 'config' | 'default';

export interface ContextWindowEntry {
  provider: string;
  model: string;
  resolved_model?: string;
  context_window: number;
  source: ContextWindowSource;
  reported_window?: number;
  window_mismatch?: boolean;
}

export interface ContextWindowState {
  default_window: number;
  min_window: number;
  max_window: number;
  warn_pct: number;
  rollover_pct: number;
  windows: ContextWindowEntry[];
}

// Must match HUB_CONTEXT_WINDOW_MIN/_MAX (hub) and BRIDGE_CONTEXT_WINDOW_MIN/_MAX (bridge).
export const CONTEXT_WINDOW_MIN = 100_000;
export const CONTEXT_WINDOW_MAX = 100_000_000;

export const CONTEXT_WINDOW_PRESETS: ReadonlyArray<{ label: string; value: number }> = [
  { label: '200K', value: 200_000 },
  { label: '500K', value: 500_000 },
  { label: '1M', value: 1_000_000 },
];

export function contextWindowsPath(bridgeId: string): string {
  return `/bridges/${encodeURIComponent(bridgeId)}/context-windows`;
}

export function contextWindowClearPath(bridgeId: string, provider: string, model: string): string {
  const query = new URLSearchParams({ provider, model });
  return `${contextWindowsPath(bridgeId)}?${query.toString()}`;
}

// formatContextWindow renders a token count compactly: 200000 -> "200K", 1000000 -> "1M",
// 1500000 -> "1.5M", 123456 -> "123,456".
export function formatContextWindow(tokens: number): string {
  if (!Number.isFinite(tokens) || tokens <= 0) return '—';
  if (tokens % 1_000_000 === 0) return `${tokens / 1_000_000}M`;
  if (tokens >= 1_000_000 && tokens % 100_000 === 0) return `${tokens / 1_000_000}M`;
  if (tokens % 1_000 === 0) return `${tokens / 1_000}K`;
  return tokens.toLocaleString('en-US');
}

export type CustomWindowParse = { ok: true; value: number } | { ok: false; error: string };

// parseCustomContextWindow accepts a whole token count with optional thousands
// separators or a K/M suffix ("150000", "150,000", "150K", "1.5M"). Values below
// 100K or above the sanity cap are rejected here, before any request is sent.
export function parseCustomContextWindow(text: string): CustomWindowParse {
  const raw = text.trim().replace(/[,_\s]/g, '');
  if (!raw) return { ok: false, error: 'Enter a context window size.' };
  const match = /^(\d+(?:\.\d+)?)([kKmM]?)$/.exec(raw);
  if (!match) return { ok: false, error: 'Use a whole number of tokens, e.g. 150000, 150K or 1.5M.' };
  const multiplier = match[2] === '' ? 1 : match[2].toLowerCase() === 'k' ? 1_000 : 1_000_000;
  const value = Number(match[1]) * multiplier;
  if (!Number.isSafeInteger(value)) return { ok: false, error: 'Use a whole number of tokens.' };
  if (value < CONTEXT_WINDOW_MIN) return { ok: false, error: `Minimum is ${formatContextWindow(CONTEXT_WINDOW_MIN)} tokens.` };
  if (value > CONTEXT_WINDOW_MAX) return { ok: false, error: `Maximum is ${formatContextWindow(CONTEXT_WINDOW_MAX)} tokens.` };
  return { ok: true, value };
}

const SOURCES = new Set<ContextWindowSource>(['override', 'reported', 'config', 'default']);

// normalizeContextWindowState drops malformed rows so a partial or older bridge
// reply never breaks the view.
export function normalizeContextWindowState(data: any): ContextWindowState | null {
  if (!data || typeof data !== 'object' || !Array.isArray(data.windows)) return null;
  const num = (v: any, fallback: number) => (typeof v === 'number' && Number.isFinite(v) ? v : fallback);
  const windows: ContextWindowEntry[] = [];
  for (const w of data.windows) {
    if (!w || typeof w.provider !== 'string' || typeof w.model !== 'string') continue;
    if (typeof w.context_window !== 'number' || !SOURCES.has(w.source)) continue;
    windows.push({
      provider: w.provider,
      model: w.model,
      resolved_model: typeof w.resolved_model === 'string' && w.resolved_model !== w.model ? w.resolved_model : undefined,
      context_window: w.context_window,
      source: w.source,
      reported_window: typeof w.reported_window === 'number' && w.reported_window > 0 ? w.reported_window : undefined,
      window_mismatch: w.window_mismatch === true && w.source !== 'override' ? true : undefined,
    });
  }
  windows.sort((a, b) => a.provider.localeCompare(b.provider) || a.model.localeCompare(b.model));
  const thresholds = resolveThresholds(num(data.warn_pct, 0), num(data.rollover_pct, 0));
  return {
    default_window: num(data.default_window, 200_000),
    min_window: num(data.min_window, CONTEXT_WINDOW_MIN),
    max_window: num(data.max_window, CONTEXT_WINDOW_MAX),
    warn_pct: thresholds.warnPct,
    rollover_pct: thresholds.rolloverPct,
    windows,
  };
}

export function contextWindowSourceLabel(source: ContextWindowSource): string {
  switch (source) {
    case 'override': return 'Override';
    case 'reported': return 'Reported';
    case 'config': return 'Config';
    default: return 'Default';
  }
}

export function contextWindowSourceHelp(source: ContextWindowSource, defaultWindow: number): string {
  switch (source) {
    case 'override': return 'Set by you on this bridge.';
    case 'reported': return 'Reported by the provider for a running instance.';
    case 'config': return 'From the context-window config shipped with the bridge.';
    default: return `Not in the shipped config; using the ${formatContextWindow(defaultWindow)} default. Set an override if this model has a different window.`;
  }
}
