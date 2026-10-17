import React from 'react';
import { TaskWire } from '../../api/taskWire';
import {
  TASK_STATES_ORDER,
  TASK_STATE_COLORS,
  TASK_STATE_LABELS,
  TaskStateV2,
  normalizeTaskState,
} from './taskV2Types';

export interface TaskSummaryBarProps {
  tasks: TaskWire[];
  chainFleets?: any[];
  bridges?: any[];
  onSelectTask?: (taskId: string) => void;
  kind?: string;
  workflowStatus?: any;
  summaryText?: string;
}

export const TaskSummaryBar: React.FC<TaskSummaryBarProps> = ({
  tasks,
  chainFleets = [],
  bridges = [],
  onSelectTask,
  kind,
  workflowStatus,
  summaryText,
}) => {
  const counts: Record<TaskStateV2, number> = {
    in_progress: 0,
    in_review: 0,
    ready: 0,
    backlog: 0,
    done: 0,
    cancelled: 0,
  };

  tasks.forEach((t) => {
    const s = normalizeTaskState(t.state);
    counts[s] = (counts[s] || 0) + 1;
  });

  const total = tasks.length || 1;
  const nowMs = Date.now();

  // Attention groups
  const blockedTasks = tasks.filter((t) => Boolean(t.blocked_on));
  const awaitingUserTasks = tasks.filter(
    (t) => normalizeTaskState(t.state) === 'in_review' && t.requires_user_approval
  );
  const expiringTasks = tasks.filter((t) => {
    if (normalizeTaskState(t.state) !== 'in_progress') return false;
    const lease = t.leases?.[0];
    if (!lease?.expires_at) return false;
    const leftMins = (new Date(lease.expires_at).getTime() - nowMs) / 60000;
    return leftMins <= 3;
  });
  const unclaimedTasks = tasks.filter((t) => {
    if (normalizeTaskState(t.state) !== 'ready') return false;
    if (!t.ready_since) return false;
    const readyMins = (nowMs - new Date(t.ready_since).getTime()) / 60000;
    return readyMins >= 10;
  });

  const activeLeasesCount = tasks.reduce(
    (acc, t) => acc + (t.leases && t.leases.length > 0 ? t.leases.length : 0),
    0
  );

  const workerFleetRows = chainFleets.filter((f) =>
    (f.roles || []).includes('worker') || !f.roles?.length
  );
  const reviewerFleetRows = chainFleets.filter((f) =>
    (f.roles || []).includes('reviewer')
  );

  // Workflow checks
  const isWorkflow = kind === 'workflow' || Boolean(workflowStatus);
  const workflowStages: any[] = workflowStatus?.stages || [];
  const anyStageFailed = workflowStages.find((st) => st.failed);
  const allStagesComplete =
    workflowStages.length > 0 && workflowStages.every((st) => st.complete);

  return (
    <div
      data-debug-id="task-summary-bar"
      className="flex flex-col gap-3 rounded-2xl border border-subtle bg-surface p-4 text-left"
    >
      {/* Top summary row: Chain / Workflow Title & Done stats */}
      <div className="flex items-center justify-between text-xs font-medium text-muted">
        <span className="font-semibold text-primary uppercase tracking-wider text-[11px]">
          {isWorkflow ? 'Workflow Pipeline' : 'Chain Status'}
        </span>
        <span className="font-mono text-muted">
          {isWorkflow && workflowStages.length > 0
            ? `${workflowStages.filter((s) => s.complete).length}/${workflowStages.length} stages complete`
            : `${counts.done}/${tasks.length} done`}
        </span>
      </div>

      {/* Workflow Run Header (if workflow) */}
      {isWorkflow && workflowStatus && (
        <div className="flex flex-col gap-1.5 rounded-lg bg-surface-raised p-2.5 text-xs text-muted">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-semibold text-primary">
              {workflowStatus.workflow_name || 'Workflow'}
            </span>
            {workflowStatus.workflow_def_ref && (
              <span className="font-mono text-[10px] text-faint">
                {workflowStatus.workflow_def_ref}
              </span>
            )}
          </div>
          {workflowStatus.inputs && typeof workflowStatus.inputs === 'object' && (
            <div className="flex flex-wrap gap-2 text-[11px] font-mono text-faint">
              {Object.entries(workflowStatus.inputs).map(([k, v]) => (
                <span key={k} className="inline-flex gap-1">
                  <span className="text-muted">{k}=</span>
                  <span className="text-primary">{String(v)}</span>
                </span>
              ))}
            </div>
          )}
        </div>
      )}

      {/* Progress Bar */}
      {isWorkflow && workflowStages.length > 0 ? (
        <div className="flex h-2 w-full gap-1 overflow-hidden rounded-full bg-neutral-soft">
          {workflowStages.map((st, i) => {
            const statusClass = st.complete
              ? 'bg-success'
              : st.failed
                ? 'bg-danger'
                : tasks.some(
                      (t) =>
                        t.stage_key === st.key &&
                        ['in_progress', 'in_review'].includes(normalizeTaskState(t.state))
                    )
                  ? 'bg-accent animate-pulse'
                  : 'bg-neutral-soft border border-subtle';
            return (
              <div
                key={i}
                title={`${st.title || st.key}: ${st.complete ? 'complete' : st.failed ? 'failed' : 'pending'}`}
                className={`flex-1 rounded-sm ${statusClass}`}
              />
            );
          })}
        </div>
      ) : (
        <div className="flex h-2 w-full overflow-hidden rounded-full bg-neutral-soft">
          {TASK_STATES_ORDER.map((state) => {
            const count = counts[state];
            if (!count) return null;
            const pct = (count / total) * 100;
            return (
              <div
                key={state}
                title={`${TASK_STATE_LABELS[state]}: ${count}`}
                style={{
                  width: `${pct}%`,
                  backgroundColor: TASK_STATE_COLORS[state],
                }}
                className="h-full transition-all"
              />
            );
          })}
        </div>
      )}

      {/* Legend */}
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1.5 text-xs text-muted">
        {TASK_STATES_ORDER.filter((s) => s !== 'cancelled' || counts[s] > 0).map((s) => (
          <div key={s} className="flex items-center gap-1.5">
            <span
              className="h-2 w-2 rounded-full shrink-0"
              style={{ backgroundColor: TASK_STATE_COLORS[s] }}
            />
            <span className="font-normal">{TASK_STATE_LABELS[s]}</span>
            <span className="font-mono font-semibold text-primary">{counts[s]}</span>
          </div>
        ))}
      </div>

      {/* Attention Strip */}
      <div className="flex flex-wrap items-center gap-2 pt-1 border-t border-subtle">
        {blockedTasks.length > 0 && (
          <button
            type="button"
            data-debug-id="attention-blocked"
            onClick={() => onSelectTask?.(blockedTasks[0].task_id)}
            className="inline-flex items-center gap-1.5 rounded-lg border border-danger/40 bg-danger-soft px-2.5 py-1 text-xs font-semibold text-danger hover:bg-danger/20 transition-colors"
          >
            <span>⛔</span>
            <span>{blockedTasks.length} blocked on you</span>
          </button>
        )}

        {awaitingUserTasks.length > 0 && (
          <button
            type="button"
            data-debug-id="attention-awaiting-user"
            onClick={() => onSelectTask?.(awaitingUserTasks[0].task_id)}
            className="inline-flex items-center gap-1.5 rounded-lg border border-accent/40 bg-accent-soft px-2.5 py-1 text-xs font-semibold text-accent hover:bg-accent/20 transition-colors"
          >
            <span>✎</span>
            <span>{awaitingUserTasks.length} awaiting your approval</span>
          </button>
        )}

        {expiringTasks.length > 0 && (
          <button
            type="button"
            data-debug-id="attention-expiring"
            onClick={() => onSelectTask?.(expiringTasks[0].task_id)}
            className="inline-flex items-center gap-1.5 rounded-lg border border-warning/40 bg-warning-soft px-2.5 py-1 text-xs font-semibold text-warning hover:bg-warning/20 transition-colors"
          >
            <span>⏱</span>
            <span>{expiringTasks.length} lease expiring</span>
          </button>
        )}

        {unclaimedTasks.length > 0 && (
          <button
            type="button"
            data-debug-id="attention-unclaimed"
            onClick={() => onSelectTask?.(unclaimedTasks[0].task_id)}
            className="inline-flex items-center gap-1.5 rounded-lg border border-warning/40 bg-warning-soft px-2.5 py-1 text-xs font-semibold text-warning hover:bg-warning/20 transition-colors"
          >
            <span>⏳</span>
            <span>{unclaimedTasks.length} ready but unclaimed</span>
          </button>
        )}

        {isWorkflow && anyStageFailed && (
          <span className="inline-flex items-center gap-1.5 rounded-lg border border-danger/40 bg-danger-soft px-2.5 py-1 text-xs font-semibold text-danger">
            <span>!</span>
            <span>Stage {anyStageFailed.key} failed — downstream on hold</span>
          </span>
        )}

        {isWorkflow && allStagesComplete && (
          <span className="inline-flex items-center gap-1.5 rounded-lg border border-success/40 bg-success-soft px-2.5 py-1 text-xs font-semibold text-success">
            <span>✓</span>
            <span>Run complete</span>
          </span>
        )}

        {/* Fleet & Leases info chip */}
        <span className="inline-flex items-center rounded-lg border border-subtle bg-surface-raised px-2.5 py-1 font-mono text-[11px] text-muted">
          {activeLeasesCount} active lease{activeLeasesCount === 1 ? '' : 's'} ·{' '}
          {workerFleetRows.length} worker{workerFleetRows.length === 1 ? '' : 's'} ·{' '}
          {reviewerFleetRows.length} reviewer{reviewerFleetRows.length === 1 ? '' : 's'}
        </span>

        {/* Nothing needs you chip */}
        {blockedTasks.length === 0 && awaitingUserTasks.length === 0 && !anyStageFailed && (
          <span className="inline-flex items-center gap-1 rounded-lg border border-success/30 bg-success-soft px-2 py-0.5 text-xs font-medium text-success">
            <span>✓</span>
            <span>nothing needs you</span>
          </span>
        )}
      </div>

      {summaryText && (
        <div className="mt-1 border-t border-subtle pt-2 text-xs leading-relaxed text-muted font-normal">
          {summaryText}
        </div>
      )}
    </div>
  );
};

export default TaskSummaryBar;
