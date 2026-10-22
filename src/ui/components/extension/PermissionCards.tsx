// Agent blocker cards (REQ-EXT-BLK-1..5, UI). What keeps an agent from
// progressing: a provider permission prompt relayed by its extension (tool, what
// it wants to do, Allow / Deny and the time left before the provider falls back
// to its own terminal prompt), or a prompt screen detection found in the
// terminal (an "Open terminal" link). The hub holds the list in memory only;
// state lives in blockersModel.ts and the RTK query is refetched on the
// agent_blockers_changed realtime frame (wsInvalidation.ts).
import React, { Suspense, useEffect, useMemo, useReducer, useState } from 'react';
import { Button, Icon, StatusPill } from '@ui';
import { apiErrorText } from '../../api/cookieFetch';
import { useGetAgentBlockersQuery, useResolveAgentBlockerMutation } from '../../api/endpoints/extension';
import {
  blockerCardView,
  blockersReducer,
  initialBlockersState,
  instanceCanBeBlocked,
  visibleBlockers,
  type AgentBlocker,
  type BlockerDecision,
} from './blockersModel';
import { summarizePermissionInput } from './permissionCardModel';

const MonacoDiffViewer = React.lazy(() => import('../chat/MonacoDiffViewer'));

function useNow(active: boolean, intervalMs = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!active) return undefined;
    const handle = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(handle);
  }, [active, intervalMs]);
  return now;
}

export interface PermissionCardProps {
  request: AgentBlocker;
  nowMs: number;
  runtimeStatus: string;
  submitting?: BlockerDecision;
  error?: string;
  onDecide: (decision: BlockerDecision) => void;
}

export function PermissionCard({ request, nowMs, runtimeStatus, submitting, error, onDecide }: PermissionCardProps) {
  const view = blockerCardView(request, nowMs, runtimeStatus);
  const summary = useMemo(() => summarizePermissionInput(request.tool_name, request.input), [request.tool_name, request.input]);
  const [showDiff, setShowDiff] = useState(false);
  const id = request.blocker_id;
  const busy = Boolean(submitting);
  const urgent = view.phase === 'pending' && view.secondsLeft > 0 && view.secondsLeft <= 30;
  return (
    <section
      data-debug-id={`permission-card-${id}`}
      data-permission-status={view.phase}
      aria-label={`Permission request: ${request.tool_name || 'tool'}`}
      className={`rounded-2xl border bg-surface p-3 shadow-sm ${view.phase === 'pending' ? 'border-warning/40' : 'border-subtle opacity-80'}`}
    >
      <div className="flex flex-wrap items-center gap-2">
        <Icon name="lock" size={14} className="shrink-0 text-warning" />
        <span className="text-sm font-semibold text-primary">
          {request.tool_name || 'Tool'} <span className="font-normal text-muted">wants permission</span>
        </span>
        {request.agent_id ? <span className="truncate text-xs text-muted">subagent {request.agent_id}</span> : null}
        <span className="ml-auto flex items-center gap-2">
          {view.countdown ? (
            <span
              data-debug-id={`permission-card-countdown-${id}`}
              title="Time left before the agent falls back to its terminal prompt"
              className={`inline-flex items-center gap-1 font-mono text-xs ${urgent ? 'text-danger' : 'text-muted'}`}
            >
              <Icon name="clock" size={12} />
              {view.countdown}
            </span>
          ) : (
            <StatusPill tone="neutral">
              <span data-debug-id={`permission-card-status-${id}`}>{view.statusLabel}</span>
            </StatusPill>
          )}
        </span>
      </div>

      <div data-debug-id={`permission-card-input-${id}`} className="mt-2 min-w-0">
        <div
          className={`overflow-x-auto whitespace-pre-wrap break-all rounded-lg border border-subtle bg-surface-raised px-2 py-1.5 text-xs text-primary ${summary.kind === 'other' ? '' : 'font-mono'}`}
        >
          {summary.kind === 'command' ? <span className="select-none text-faint">$ </span> : null}
          {Object.keys(request.input).length === 0 && request.summary ? request.summary : summary.text}
        </div>
        {summary.detail ? <p className="mt-1 text-xs text-muted">{summary.detail}</p> : null}
        {summary.diff ? (
          <div className="mt-1.5">
            <button
              type="button"
              data-debug-id={`permission-card-diff-toggle-${id}`}
              aria-expanded={showDiff}
              onClick={() => setShowDiff((v) => !v)}
              className="inline-flex min-h-8 items-center gap-1 text-xs text-accent hover:underline"
            >
              <Icon name={showDiff ? 'chevron-down' : 'chevron-right'} size={12} />
              {summary.diff.wholeFile ? 'Show new file content' : 'Show diff'}
            </button>
            {showDiff ? (
              <div data-debug-id={`permission-card-diff-${id}`} className="mt-1 overflow-hidden rounded-lg border border-subtle">
                <Suspense fallback={<div className="p-3 text-center text-xs text-muted">Loading diff…</div>}>
                  <MonacoDiffViewer
                    filePath={summary.diff.filePath}
                    original={summary.diff.original}
                    modified={summary.diff.modified}
                    height={220}
                  />
                </Suspense>
              </div>
            ) : null}
          </div>
        ) : null}
      </div>

      {error ? (
        <p role="alert" data-debug-id={`permission-card-error-${id}`} className="mt-2 text-xs text-danger">{error}</p>
      ) : null}

      {view.canDecide ? (
        <div className="mt-3 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button
            variant="secondary"
            tone="danger"
            data-debug-id={`permission-card-deny-btn-${id}`}
            loading={submitting === 'deny'}
            disabled={busy}
            onClick={() => onDecide('deny')}
          >
            Deny
          </Button>
          <Button
            variant="primary"
            tone="success"
            data-debug-id={`permission-card-allow-btn-${id}`}
            loading={submitting === 'allow'}
            disabled={busy}
            onClick={() => onDecide('allow')}
          >
            Allow
          </Button>
        </div>
      ) : view.phase === 'expired' ? (
        <p data-debug-id={`permission-card-expired-${id}`} className="mt-2 text-xs text-muted">{view.statusLabel}</p>
      ) : null}
    </section>
  );
}

/** A prompt screen detection found in the agent terminal; answered only there. */
export function TerminalPromptCard({ blocker, onOpenTerminal }: { blocker: AgentBlocker; onOpenTerminal?: () => void }) {
  const id = blocker.blocker_id;
  return (
    <section
      data-debug-id={`terminal-prompt-card-${id}`}
      aria-label="Agent is waiting for input in its terminal"
      className="flex flex-wrap items-center gap-2 rounded-2xl border border-warning/40 bg-surface p-3 shadow-sm"
    >
      <Icon name="terminal" size={14} className="shrink-0 text-warning" />
      <span className="min-w-0 flex-1 text-sm text-primary">{blocker.summary || 'Waiting for input in terminal'}</span>
      {onOpenTerminal ? (
        <Button variant="secondary" data-debug-id={`terminal-prompt-open-btn-${id}`} onClick={onOpenTerminal}>
          Open terminal
        </Button>
      ) : null}
    </section>
  );
}

/**
 * The blockers of one agent conversation (rendered above the composer). Fetched
 * on mount and refetched on agent_blockers_changed; empty once the instance
 * stops. Allow / Deny only for permission blockers while the instance runs.
 */
export function InstancePermissionCards({
  instanceId,
  runtimeStatus,
  onOpenTerminal,
  className = '',
}: {
  instanceId: string;
  runtimeStatus: string;
  onOpenTerminal?: () => void;
  className?: string;
}) {
  const live = Boolean(instanceId) && instanceCanBeBlocked(runtimeStatus);
  const query = useGetAgentBlockersQuery(instanceId, { skip: !live, refetchOnMountOrArgChange: true });
  const [state, dispatch] = useReducer(blockersReducer, instanceId, initialBlockersState);
  const [resolve] = useResolveAgentBlockerMutation();
  useEffect(() => {
    if (live && query.data) dispatch({ type: 'loaded', snapshot: query.data });
  }, [live, query.data]);
  useEffect(() => {
    if (!live) dispatch({ type: 'instance_stopped' });
  }, [live]);
  const visible = live ? visibleBlockers(state) : [];
  const now = useNow(visible.some((b) => b.kind === 'permission'));
  if (visible.length === 0) return null;
  const onDecide = async (blocker: AgentBlocker, decision: BlockerDecision) => {
    dispatch({ type: 'decision_started', id: blocker.blocker_id, decision });
    const result: any = await resolve({ instanceId, blockerId: blocker.blocker_id, decision });
    if (result?.error) {
      dispatch({ type: 'decision_failed', id: blocker.blocker_id, error: apiErrorText(result.error, 'Could not send the decision.') });
    } else {
      dispatch({ type: 'decision_succeeded', id: blocker.blocker_id });
    }
  };
  return (
    <div data-debug-id="conversation-permission-cards" className={`flex max-h-[45vh] flex-col gap-2 overflow-y-auto ${className}`}>
      {visible.map((blocker) =>
        blocker.kind === 'terminal_prompt' ? (
          <TerminalPromptCard key={blocker.blocker_id} blocker={blocker} onOpenTerminal={onOpenTerminal} />
        ) : (
          <PermissionCard
            key={blocker.blocker_id}
            request={blocker}
            nowMs={now}
            runtimeStatus={runtimeStatus}
            submitting={state.submitting[blocker.blocker_id]}
            error={state.errors[blocker.blocker_id]}
            onDecide={(decision) => void onDecide(blocker, decision)}
          />
        ),
      )}
    </div>
  );
}
