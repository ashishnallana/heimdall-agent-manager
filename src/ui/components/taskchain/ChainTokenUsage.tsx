// Task chain overview: token usage per agent and chain total (T10). The view is
// pure (ChainTokenUsageView renders a normalized payload); the section wires
// the hub query. State logic lives in chainTokenUsageModel.ts.
import React from 'react';
import { ProgressBar, StatusPill, Text } from '@ui';
import { useGetTaskChainTokenUsageQuery } from '../../api/endpoints/taskChains';
import { retainChainTokenUsageView } from '../../api/chainTokenUsageRefresh';
import { CONTEXT_ESTIMATE_TEXT, CONTEXT_WAITING_TEXT, contextUnavailableText, formatTokens } from '../extension/tokenUsageModel';
import {
  normalizeChainTokenUsage,
  shareOfTotal,
  type ChainTokenAgent,
  type ChainTokenContext,
  type ChainTokenFigures,
  type ChainTokenInstance,
  type ChainTokenUsage,
} from './chainTokenUsageModel';

const PILL_TONE = { neutral: 'neutral', warning: 'warning', danger: 'danger' } as const;
const METER_TONE = { neutral: 'accent', warning: 'warning', danger: 'danger' } as const;

function figuresTitle(f: ChainTokenFigures): string {
  return [
    `${f.totalTokens.toLocaleString()} tokens = context ${f.contextTokens.toLocaleString()} (sum of runs) + output ${f.outputTokens.toLocaleString()}`,
    `~${f.estToolTokens.toLocaleString()} est. tool tokens`,
    `${f.runs} run${f.runs === 1 ? '' : 's'}`,
  ].join(' · ');
}

function ContextCell({ context, debugId, unsupported = false, waiting = false, provider }: { context: ChainTokenContext | null; debugId: string; unsupported?: boolean; waiting?: boolean; provider?: string }) {
  if (!context && unsupported) {
    return <span data-debug-id={debugId} data-context-state="unsupported" title={contextUnavailableText(provider)} className="text-faint">n/a</span>;
  }
  if (!context && waiting) return <span data-debug-id={debugId} data-context-state="waiting" title={CONTEXT_WAITING_TEXT} className="text-faint">…</span>;
  if (!context) return <span data-debug-id={debugId} className="text-faint">—</span>;
  const window = context.window ? ` / ${formatTokens(context.window)}` : '';
  const tilde = context.isEstimate ? '~' : '';
  return (
    <span
      data-debug-id={debugId}
      data-context-tone={context.tone}
      data-context-estimate={context.isEstimate ? 'true' : undefined}
      title={`Current context ${tilde}${formatTokens(context.tokens)}${window} tokens (${tilde}${context.pct}% of window)${context.isEstimate ? ` · ${CONTEXT_ESTIMATE_TEXT}` : ''}`}
      className="flex min-w-0 items-center gap-2"
    >
      <span className="hidden w-16 sm:block">
        <ProgressBar value={Math.min(context.pct, 100)} tone={METER_TONE[context.tone]} size="sm" label={`Context ${tilde}${context.pct}% of window`} />
      </span>
      <StatusPill tone={PILL_TONE[context.tone]}>{`${tilde}${context.pct}%`}</StatusPill>
    </span>
  );
}

function InstanceRow({ inst }: { inst: ChainTokenInstance }) {
  const name = inst.displayName || inst.instanceId;
  return (
    <li
      data-debug-id={`chain-token-usage-instance-${inst.instanceId}`}
      className="grid grid-cols-[minmax(0,1fr)_auto_auto] items-center gap-x-3 py-1 text-body-sm"
    >
      <span className="min-w-0 truncate text-muted" title={inst.instanceId}>
        {name}
        <span className="text-faint">{` · ${inst.runtimeStatus || 'unknown'}`}{inst.runCount ? ` · run ${inst.runCount}` : ''}</span>
      </span>
      <ContextCell context={inst.context} debugId={`chain-token-usage-instance-context-${inst.instanceId}`} unsupported={inst.live && inst.usageSupported === false} waiting={inst.live && inst.usageSupported === true} provider={inst.provider} />
      <span className="w-16 text-right tabular-nums text-primary" title={inst.hasData ? figuresTitle(inst.lifetime) : 'No token data reported'}>
        {inst.hasData ? formatTokens(inst.lifetime.totalTokens) : '—'}
      </span>
    </li>
  );
}

function AgentRow({ agent, total }: { agent: ChainTokenAgent; total: ChainTokenFigures }) {
  const share = shareOfTotal(agent.lifetime, total);
  const instances = agent.instances.length;
  return (
    <li data-debug-id={`chain-token-usage-agent-${agent.agentId}`} className="border-b border-subtle last:border-b-0">
      <details>
        <summary className="grid cursor-pointer list-none grid-cols-[minmax(0,1fr)_auto_auto] items-center gap-x-3 py-2">
          <span className="min-w-0">
            <span className="block truncate text-body-sm font-medium text-primary" title={agent.agentId}>{agent.name}</span>
            <span className="block text-caption text-faint">
              {`${instances} instance${instances === 1 ? '' : 's'}`}
              {agent.liveInstances ? ` · ${agent.liveInstances} live` : ''}
              {agent.hasData ? ` · ${agent.lifetime.runs} run${agent.lifetime.runs === 1 ? '' : 's'} · ${share}% of chain` : ' · no data yet'}
            </span>
          </span>
          <ContextCell context={agent.context} debugId={`chain-token-usage-agent-context-${agent.agentId}`} unsupported={agent.contextCapability === 'unsupported'} waiting={agent.contextCapability === 'waiting'} provider={agent.unsupportedProviders.join(', ')} />
          <span
            data-debug-id={`chain-token-usage-agent-total-${agent.agentId}`}
            className="w-16 text-right text-body-sm tabular-nums text-primary"
            title={agent.hasData ? figuresTitle(agent.lifetime) : 'No token data reported'}
          >
            {agent.hasData ? formatTokens(agent.lifetime.totalTokens) : '—'}
          </span>
        </summary>
        <ul className="mb-2 ml-3 border-l border-subtle pl-3">
          {agent.instances.map((inst) => <InstanceRow key={inst.instanceId} inst={inst} />)}
        </ul>
      </details>
    </li>
  );
}

/** Pure view of a normalized payload: empty state, per-agent rows, chain total. */
export function ChainTokenUsageView({ usage }: { usage: ChainTokenUsage | null }) {
  if (!usage || !usage.hasData) {
    return (
      <Text as="p" role="body-sm" tone="muted" data-debug-id="chain-token-usage-empty">
        No token usage reported yet. Figures appear once agents on this chain run with the Heimdall extension.
      </Text>
    );
  }
  const t = usage.total;
  return (
    <div data-debug-id="chain-token-usage-table" className="flex flex-col">
      <div className="grid grid-cols-[minmax(0,1fr)_auto_auto] gap-x-3 pb-1 text-caption uppercase text-faint">
        <span>Agent</span>
        <span>Context now</span>
        <span className="w-16 text-right">Lifetime</span>
      </div>
      <ul className="flex flex-col">
        {usage.agents.map((agent) => <AgentRow key={agent.agentId || agent.name} agent={agent} total={t} />)}
      </ul>
      <div
        data-debug-id="chain-token-usage-total"
        className="mt-1 grid grid-cols-[minmax(0,1fr)_auto] items-baseline gap-x-3 border-t border-subtle pt-2"
        title={figuresTitle(t)}
      >
        <span className="text-body-sm font-medium text-primary">
          Chain total
          <span className="ml-2 text-caption font-normal text-faint">
            {`context ${formatTokens(t.contextTokens)} + output ${formatTokens(t.outputTokens)} · ~${formatTokens(t.estToolTokens)} tool · ${t.runs} run${t.runs === 1 ? '' : 's'}`}
          </span>
        </span>
        <span data-debug-id="chain-token-usage-total-value" className="w-16 text-right text-body-sm font-semibold tabular-nums text-primary">
          {formatTokens(t.totalTokens)}
        </span>
      </div>
      <Text as="p" role="caption" tone="faint" className="mt-1">
        {`Lifetime = context (sum of runs) + output, including the current run. Context now: highest of the agent's live instances; warn ${usage.warnPct}%, rollover ${usage.rolloverPct}%.`}
      </Text>
    </div>
  );
}

/** Fetches the chain's token usage and renders the view. `embedded` drops the card chrome and title for hosts (the Chain overview panel) that supply their own section header. */
export function ChainTokenUsageSection({ chainId, embedded = false }: { chainId: string; embedded?: boolean }) {
  const { data, error, isLoading, isFetching, refetch } = useGetTaskChainTokenUsageQuery({ chainId }, { skip: !chainId });
  const usage = React.useMemo(() => normalizeChainTokenUsage(data), [data]);
  // Token events refresh this card only while it is mounted (T14,
  // api/chainTokenUsageRefresh.ts). Changes missed while it was hidden mark the
  // chain stale: refetch once on mount unless a fetch is already under way.
  const fetchingRef = React.useRef(isFetching);
  fetchingRef.current = isFetching;
  React.useEffect(() => {
    const view = retainChainTokenUsageView(chainId);
    if (view.stale && !fetchingRef.current) refetch();
    return view.release;
  }, [chainId]);
  return (
    <section
      data-debug-id="chain-token-usage"
      className={embedded ? 'min-w-0 text-left' : 'min-w-0 rounded-xl border border-subtle bg-surface p-4 text-left'}
    >
      {!embedded && <Text as="h3" role="overline" tone="faint" className="mb-2 uppercase">Token usage</Text>}
      {isLoading && !data ? (
        <Text as="p" role="body-sm" tone="muted">Loading token usage…</Text>
      ) : error && !data ? (
        <Text as="p" role="body-sm" tone="danger" data-debug-id="chain-token-usage-error">Could not load token usage.</Text>
      ) : (
        <ChainTokenUsageView usage={usage} />
      )}
    </section>
  );
}
