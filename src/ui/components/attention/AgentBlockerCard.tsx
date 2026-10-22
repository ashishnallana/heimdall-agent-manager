// A live agent blocker in the 'Needs you' surfaces (the global AttentionDeck and
// the chain-scoped ActionTray) — by user decision the ONLY permission-approval
// UI. A permission prompt gets Allow / Deny (POST .../blockers/{id}/resolve); a
// prompt detected in the agent terminal can only be answered there, so it gets
// Open terminal. Resolving hides the card at once; the bridge's next snapshot
// drops it for good (attention_changed refetches), and a failed call brings it back.
// A decision can still be lost after the hub accepted it (the bridge restarts
// before its waiter sees the frame); the hook then re-registers the SAME
// blocker_id, so the hide is lifted after BLOCKER_RESOLVE_CONFIRM_MS and a
// blocker the hub still lists shows again.
import { useCallback, useMemo, useState } from 'react';
import { Button, Icon } from '@ui';
import { apiErrorText } from '../../api/cookieFetch';
import type { AttentionBlockerItem } from '../../api/endpoints/attention';
import { useResolveAgentBlockerMutation } from '../../api/endpoints/extension';
import { attentionScheduler, type ActionScheduler } from '../../services/attention/actionScheduler';
import { buildRouteHash, navigateTo } from '../../utils/appLocation';
import { summarizePermissionInput } from '../extension/permissionCardModel';
import type { BlockerDecision } from '../extension/blockersModel';
import { formatAge, hideKey, isTerminalPromptItem } from './attentionModel';
import { needLabel } from './actionTrayModel';

/** How long a resolved blocker stays hidden before a still-listed one shows again. */
export const BLOCKER_RESOLVE_CONFIRM_MS = 15_000;

/** Allow / Deny one blocker: hides it at once, restores it (and returns the error) on failure. */
export function useResolveBlocker(scheduler: ActionScheduler = attentionScheduler) {
  const [resolve] = useResolveAgentBlockerMutation();
  return useCallback(async (item: AttentionBlockerItem, decision: BlockerDecision): Promise<string> => {
    const key = hideKey(item);
    scheduler.settle(key);
    const result: any = await resolve({ instanceId: item.action_refs.agent_instance_id, blockerId: item.action_refs.blocker_id, decision });
    if (result?.error) {
      scheduler.unsettle(key);
      return apiErrorText(result.error, 'Could not send the decision.');
    }
    scheduler.recheckAfter(key, BLOCKER_RESOLVE_CONFIRM_MS);
    return '';
  }, [resolve, scheduler]);
}

/** The blocked agent's conversation (its terminal tab is one click away there). */
export function openBlockerAgent(item: AttentionBlockerItem) {
  navigateTo(buildRouteHash(`/conversations/${encodeURIComponent(item.action_refs.agent_instance_id)}`, ''));
}

/** What the agent wants to do: tool, summary and the key input line. No ids. */
export function AgentBlockerBody({ item }: { item: AttentionBlockerItem }) {
  const d = item.details;
  const input = useMemo(() => summarizePermissionInput(d.tool_name, (d.input || {}) as Record<string, any>), [d.tool_name, d.input]);
  if (isTerminalPromptItem(item)) {
    return (
      <p data-debug-id="attention-blocker-terminal" className="flex items-center gap-2 text-[14px] text-primary">
        <Icon name="terminal" size={14} className="shrink-0 text-warning" />
        {d.summary || 'The agent is waiting for input in its terminal.'}
      </p>
    );
  }
  return (
    <>
      <h3 data-debug-id="attention-blocker-title" className="text-[17px] font-semibold leading-snug text-primary">
        {d.tool_name ? `Allow ${d.tool_name}?` : 'Allow this action?'}
      </h3>
      {input.text ? (
        <pre data-debug-id="attention-blocker-input" className="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-words rounded-[var(--radius-md)] border border-subtle bg-surface px-3 py-2 font-mono text-[12px] text-primary">
          {input.text}
        </pre>
      ) : d.summary ? (
        <p data-debug-id="attention-blocker-summary" className="mt-2 text-[13px] text-primary">{d.summary}</p>
      ) : null}
      {input.detail ? <p className="mt-1 text-[12px] text-muted">{input.detail}</p> : null}
    </>
  );
}

/** Allow / Deny (permission) or Open terminal (terminal prompt), with the last error. */
export function AgentBlockerActions({ item, compact = false, scheduler, onDone }: { item: AttentionBlockerItem; compact?: boolean; scheduler?: ActionScheduler; onDone?: (label: string) => void }) {
  const resolveBlocker = useResolveBlocker(scheduler);
  const [busy, setBusy] = useState<BlockerDecision | null>(null);
  const [error, setError] = useState('');
  const id = item.action_refs.blocker_id;
  if (isTerminalPromptItem(item)) {
    return (
      <div className="flex flex-wrap items-center gap-2">
        <Button variant="secondary" data-debug-id={`attention-blocker-open-terminal-${id}`} onClick={() => openBlockerAgent(item)}>
          Open terminal
        </Button>
      </div>
    );
  }
  const decide = async (decision: BlockerDecision) => {
    setBusy(decision);
    setError('');
    const err = await resolveBlocker(item, decision);
    setBusy(null);
    if (err) setError(err);
    else onDone?.(decision === 'allow' ? 'Allowed' : 'Denied');
  };
  return (
    <div className="flex flex-col gap-1.5">
      <div className={`flex flex-wrap items-center gap-2 ${compact ? '' : 'justify-start'}`}>
        <Button variant="primary" data-debug-id={`attention-blocker-allow-${id}`} disabled={!!busy} onClick={() => void decide('allow')}>
          {busy === 'allow' ? 'Allowing…' : 'Allow'}
        </Button>
        <Button variant="secondary" data-debug-id={`attention-blocker-deny-${id}`} disabled={!!busy} onClick={() => void decide('deny')}>
          {busy === 'deny' ? 'Denying…' : 'Deny'}
        </Button>
        <Button variant="ghost" data-debug-id={`attention-blocker-open-${id}`} onClick={() => openBlockerAgent(item)}>
          Open agent
        </Button>
      </div>
      {error ? <p role="alert" data-debug-id={`attention-blocker-error-${id}`} className="text-[12px] text-danger">{error}</p> : null}
    </div>
  );
}

/** The tray page for one blocker (ActionTaskCard's layout). */
export function ActionBlockerCard({ item, mobile, now, scheduler }: { item: AttentionBlockerItem; mobile: boolean; now: number; scheduler?: ActionScheduler }) {
  const agent = item.context.agent_name || 'Agent';
  const age = formatAge(item.attention_since, now);
  return (
    <article
      data-debug-id={`action-tray-card-${item.details.blocker_kind}`}
      aria-label={isTerminalPromptItem(item) ? 'Agent waiting for input in its terminal' : 'Agent needs your permission'}
      className="flex h-full min-h-0 min-w-0 flex-col gap-3"
    >
      <header className="min-w-0 space-y-1">
        <div className="flex min-w-0 items-center gap-2 text-[13px] text-muted">
          <span aria-hidden="true" className="grid h-5 w-5 shrink-0 place-items-center rounded-full bg-neutral-soft text-muted">
            <Icon name="bot" size={12} />
          </span>
          <span data-debug-id="action-tray-card-agent" className="min-w-0 truncate">
            <span className="font-medium text-primary">{agent}</span>
            {age ? ` · ${age === 'just now' ? age : `${age} ago`}` : ''}
          </span>
        </div>
        <p data-debug-id="action-tray-card-need" className={`pt-1 text-[12px] font-semibold uppercase tracking-wide text-warning`}>
          {needLabel(item)}
        </p>
      </header>
      <div data-debug-id="action-tray-card-ask" className="min-h-0 flex-1 touch-pan-y overflow-y-auto overscroll-contain pr-1">
        <AgentBlockerBody item={item} />
      </div>
      <div className="shrink-0">
        <AgentBlockerActions item={item} compact scheduler={scheduler} />
      </div>
    </article>
  );
}
