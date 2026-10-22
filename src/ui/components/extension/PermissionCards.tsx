// Permission approval cards (REQ-EXT-PERM-1, UI). A provider permission prompt
// relayed by the extension shows here with the tool, what it wants to do, an
// Allow / Deny pair and the time left before the provider falls back to its own
// terminal prompt. State lives in permissionCardModel.ts; the RTK caches are
// kept live by the realtime handler (wsInvalidation.ts).
import React, { Suspense, useEffect, useMemo, useReducer, useState } from 'react';
import { Button, Icon, StatusPill } from '@ui';
import { apiErrorText } from '../../api/cookieFetch';
import {
  useDecidePermissionRequestMutation,
  useListInstancePermissionRequestsQuery,
  useListPendingPermissionRequestsQuery,
} from '../../api/endpoints/extension';
import {
  initialPermissionCardsState,
  permissionCardView,
  permissionCardsReducer,
  summarizePermissionInput,
  visiblePermissionRequests,
  type PermissionDecision,
  type PermissionRequest,
} from './permissionCardModel';

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
  request: PermissionRequest;
  nowMs: number;
  submitting?: PermissionDecision;
  error?: string;
  onDecide: (decision: PermissionDecision) => void;
  /** Agent name for the owner-wide list ('' inside a conversation). */
  agentLabel?: string;
  onOpenAgent?: () => void;
}

export function PermissionCard({ request, nowMs, submitting, error, onDecide, agentLabel, onOpenAgent }: PermissionCardProps) {
  const view = permissionCardView(request, nowMs);
  const summary = useMemo(() => summarizePermissionInput(request.tool_name, request.input), [request.tool_name, request.input]);
  const [showDiff, setShowDiff] = useState(false);
  const id = request.id;
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
        {agentLabel ? (
          onOpenAgent ? (
            <button
              type="button"
              data-debug-id={`permission-card-agent-btn-${id}`}
              onClick={onOpenAgent}
              className="truncate text-xs text-accent hover:underline"
            >
              {agentLabel}
            </button>
          ) : (
            <span className="truncate text-xs text-muted">{agentLabel}</span>
          )
        ) : null}
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
            <StatusPill tone={view.phase === 'allowed' ? 'success' : view.phase === 'denied' ? 'danger' : 'neutral'}>
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
          {summary.text}
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

/**
 * Keeps a list of cards live: syncs the RTK data into the reducer, ticks the
 * countdown while anything is pending, and runs Allow / Deny.
 */
function usePermissionCards(requests: PermissionRequest[] | undefined) {
  const [state, dispatch] = useReducer(permissionCardsReducer, initialPermissionCardsState);
  const [decide] = useDecidePermissionRequestMutation();
  useEffect(() => {
    if (requests) dispatch({ type: 'loaded', requests });
  }, [requests]);
  const anyLive = state.requests.length > 0;
  const now = useNow(anyLive);
  const visible = visiblePermissionRequests(state, now);
  const onDecide = async (request: PermissionRequest, decision: PermissionDecision) => {
    dispatch({ type: 'decision_started', id: request.id, decision });
    const result: any = await decide({ id: request.id, instanceId: request.instance_id, decision });
    if (result?.error) {
      dispatch({ type: 'decision_failed', id: request.id, error: apiErrorText(result.error, 'Could not send the decision.') });
    } else {
      dispatch({ type: 'decision_succeeded', id: request.id, decision, request: result?.data?.permission_request ?? null });
    }
  };
  return { state, visible, now, onDecide };
}

/** Cards for one agent conversation (rendered above the composer). */
export function InstancePermissionCards({ instanceId, className = '' }: { instanceId: string; className?: string }) {
  const query = useListInstancePermissionRequestsQuery(instanceId, { skip: !instanceId });
  const { state, visible, now, onDecide } = usePermissionCards(query.data);
  if (!instanceId || visible.length === 0) return null;
  return (
    <div data-debug-id="conversation-permission-cards" className={`flex max-h-[45vh] flex-col gap-2 overflow-y-auto ${className}`}>
      {visible.map((request) => (
        <PermissionCard
          key={request.id}
          request={request}
          nowMs={now}
          submitting={state.submitting[request.id]}
          error={state.errors[request.id]}
          onDecide={(decision) => void onDecide(request, decision)}
        />
      ))}
    </div>
  );
}

/** Owner-wide pending cards for the attention surface. */
export function PendingPermissionCards({
  agentLabel,
  onOpenAgent,
}: {
  agentLabel?: (request: PermissionRequest) => string;
  onOpenAgent?: (request: PermissionRequest) => void;
}) {
  const query = useListPendingPermissionRequestsQuery(undefined);
  const { state, visible, now, onDecide } = usePermissionCards(query.data);
  if (visible.length === 0) return null;
  return (
    <section data-debug-id="attention-permission-cards" aria-label="Permission requests" className="flex flex-col gap-2">
      <h3 className="px-1 text-xs font-semibold uppercase tracking-wide text-muted">
        Permission requests <span data-debug-id="attention-permission-count">({visible.filter((r) => r.status === 'pending').length})</span>
      </h3>
      {visible.map((request) => (
        <PermissionCard
          key={request.id}
          request={request}
          nowMs={now}
          submitting={state.submitting[request.id]}
          error={state.errors[request.id]}
          onDecide={(decision) => void onDecide(request, decision)}
          agentLabel={agentLabel ? agentLabel(request) : request.agent_id || request.instance_id}
          onOpenAgent={onOpenAgent ? () => onOpenAgent(request) : undefined}
        />
      ))}
    </section>
  );
}
