// Per-instance token usage (T3r): the instance-list context badge and the
// Runtime card's context meter + lifetime totals. State logic lives in
// tokenUsageModel.ts; these components only render it and render nothing when
// the instance JSON has no data.
import { ProgressBar, StatusPill } from '@ui';
import {
  resolveThresholds,
  CONTEXT_WAITING_TEXT,
  CONTEXT_ESTIMATE_TEXT,
  contextBadge,
  contextTrackingState,
  contextUnavailableText,
  contextTone,
  formatTokens,
  normalizeTokenTotals,
  normalizeTokenUsage,
  windowSourceLabel,
} from './tokenUsageModel';

const BADGE_TONE = { neutral: 'neutral', warning: 'warning', danger: 'danger' } as const;
const METER_TONE = { neutral: 'accent', warning: 'warning', danger: 'danger' } as const;

/** Context % pill for an instance row; null without a context figure. */
export function ContextUsageBadge({ instance, instanceId }: { instance: any; instanceId: string }) {
  const badge = contextBadge(instance);
  if (!badge) return null;
  return (
    <span data-debug-id={`live-instance-context-${instanceId}`} data-context-tone={badge.tone} data-context-state={badge.state} title={badge.tooltip}>
      <StatusPill tone={BADGE_TONE[badge.tone]}>{badge.label}</StatusPill>
    </span>
  );
}

/** Context meter (% of window, window source) for the Runtime card; null without data. */
export function ContextMeter({ instance }: { instance: any }) {
  const usage = normalizeTokenUsage(instance?.token_usage);
  if (!usage) return null;
  const source = windowSourceLabel(usage.windowSource);
  const window = usage.contextWindow ? formatTokens(usage.contextWindow) : '';
  const state = contextTrackingState(usage);
  if (state === 'unsupported') {
    return (
      <div data-debug-id="live-instance-context-meter" data-context-tone="none" data-context-state="unsupported" className="text-body-sm text-muted">
        {contextUnavailableText(instance?.provider)}
        {` · ${usage.toolCalls} tool calls, ~${formatTokens(usage.estTokensTotal)} tool tokens`}
      </div>
    );
  }
  if (usage.contextPct === null) {
    return (
      <div data-debug-id="live-instance-context-meter" data-context-tone="none" data-context-state="waiting" className="text-body-sm text-muted">
        {usage.usageSupported === true ? CONTEXT_WAITING_TEXT : 'No context reported yet'}{window ? ` · window ${window}${source ? ` (${source})` : ''}` : ''}
        {` · ${usage.toolCalls} tool calls, ~${formatTokens(usage.estTokensTotal)} tool tokens`}
      </div>
    );
  }
  const tone = contextTone(usage.contextPct, usage.warnPct, usage.rolloverPct);
  return (
    <div data-debug-id="live-instance-context-meter" data-context-tone={tone} className="mt-0.5 flex flex-col gap-1">
      <ProgressBar
        value={usage.contextPct}
        tone={METER_TONE[tone]}
        size="sm"
        label={`Context ${usage.isEstimate ? '~' : ''}${usage.contextPct}% of window`}
      />
      <div className="flex flex-wrap items-center justify-between gap-x-3 text-body-sm">
        <span className="text-primary" data-debug-id="live-instance-context-pct" data-context-estimate={usage.isEstimate ? 'true' : undefined} title={usage.isEstimate ? CONTEXT_ESTIMATE_TEXT : undefined}>
          {usage.isEstimate ? '~' : ''}{usage.contextPct}% · {usage.isEstimate ? '~' : ''}{formatTokens(usage.effectiveContextTokens ?? 0)}{window ? ` / ${window}` : ''} tokens
        </span>
        <span className="text-muted" data-debug-id="live-instance-context-source" data-window-source={usage.windowSource}>
          {source ? `window: ${source}` : ''}
        </span>
      </div>
      {usage.windowMismatch ? (
        <span className="text-[11px] text-warning" data-debug-id="live-instance-window-mismatch" role="note">
          Provider reports a {formatTokens(usage.reportedWindow ?? 0)} window, which differs from the configured one by more than 10%. Set an override if this is wrong.
        </span>
      ) : null}
      <span className="text-[11px] text-muted">
        {usage.toolCalls} tool calls · ~{formatTokens(usage.estTokensTotal)} tool tokens
        {usage.outputTokensTotal !== null ? ` · ${formatTokens(usage.outputTokensTotal)} output` : ''}
        {usage.compactions ? ` · ${usage.compactions} compaction${usage.compactions === 1 ? '' : 's'}` : ''}
        {` · warn ${resolveThresholds(usage.warnPct, usage.rolloverPct).warnPct}%, rollover ${resolveThresholds(usage.warnPct, usage.rolloverPct).rolloverPct}%`}
      </span>
    </div>
  );
}

/** Lifetime totals across runs (added at every hub stop/restart); null before the first. */
export function TokenTotalsSummary({ instance }: { instance: any }) {
  const totals = normalizeTokenTotals(instance?.token_totals);
  if (!totals) return null;
  return (
    <dl data-debug-id="live-instance-token-totals" className="mt-0.5 grid grid-cols-2 gap-x-3 gap-y-0.5 text-body-sm">
      <dt className="text-muted">Context (sum of runs)</dt>
      <dd className="text-primary" data-debug-id="live-instance-total-context">{formatTokens(totals.totalContextTokens)}</dd>
      <dt className="text-muted">Est. tool tokens</dt>
      <dd className="text-primary" data-debug-id="live-instance-total-tool">{formatTokens(totals.totalEstToolTokens)}</dd>
      <dt className="text-muted">Output tokens</dt>
      <dd className="text-primary" data-debug-id="live-instance-total-output">{formatTokens(totals.totalOutputTokens)}</dd>
      <dt className="text-muted">Runs counted</dt>
      <dd className="text-primary" data-debug-id="live-instance-total-runs">{totals.runsCounted}</dd>
    </dl>
  );
}
