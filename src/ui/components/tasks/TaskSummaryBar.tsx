import React from 'react';
import { Button, ProgressBar, StatusDot, Text } from '@ui';
import { TaskWire } from '../../api/taskWire';
import { TASK_STATES_ORDER, TASK_STATE_LABELS, TASK_STATE_TONE, TaskStateV2, normalizeTaskState, workLease } from './taskV2Types';
import { taskNeedsYou } from './taskActions';

export interface TaskSummaryBarProps {
  tasks: TaskWire[];
  chainFleets?: any[];
  kind?: string;
  workflowStatus?: any;
  summaryText?: string;
  /** "N need you" filter (plan REQ-UI-7). Omit to hide the toggle. */
  needsYouActive?: boolean;
  onToggleNeedsYou?: () => void;
  /** Chain-level buttons (Fleet, New task, Publish) rendered on the right. */
  actions?: React.ReactNode;
}

const UNCLAIMED_AFTER_MINS = 10;
const EXPIRING_WITHIN_MINS = 3;

/**
 * The quiet header above a chain's tasks: progress, counts, and one line that
 * says whether anything needs you. No card around it (design reference).
 */
export const TaskSummaryBar: React.FC<TaskSummaryBarProps> = ({
  tasks,
  chainFleets = [],
  kind,
  workflowStatus,
  summaryText,
  needsYouActive = false,
  onToggleNeedsYou,
  actions,
}) => {
  const counts = TASK_STATES_ORDER.reduce(
    (acc, s) => ({ ...acc, [s]: 0 }),
    {} as Record<TaskStateV2, number>,
  );
  tasks.forEach((t) => {
    counts[normalizeTaskState(t.state)] += 1;
  });

  const nowMs = Date.now();
  const needsYou = tasks.filter(taskNeedsYou).length;
  const expiring = tasks.filter((t) => {
    const lease: any = workLease(t);
    if (normalizeTaskState(t.state) !== 'in_progress' || !lease?.expires_at) return false;
    return (new Date(lease.expires_at).getTime() - nowMs) / 60000 <= EXPIRING_WITHIN_MINS;
  }).length;
  const unclaimed = tasks.filter(
    (t) =>
      normalizeTaskState(t.state) === 'ready' &&
      t.ready_since &&
      (nowMs - new Date(t.ready_since).getTime()) / 60000 >= UNCLAIMED_AFTER_MINS,
  ).length;
  const activeLeases = tasks.reduce((n, t) => n + (t.leases?.length || 0), 0);
  const workers = chainFleets.filter((f) => (f.roles || []).includes('worker') || !f.roles?.length).length;
  const reviewers = chainFleets.filter((f) => (f.roles || []).some((r: string) => r !== 'worker')).length;

  const isWorkflow = kind === 'workflow' || Boolean(workflowStatus);
  const stages: any[] = workflowStatus?.stages || [];
  const failedStage = stages.find((st) => st.failed);
  const runComplete = stages.length > 0 && stages.every((st) => st.complete);

  const doneCount = isWorkflow && stages.length ? stages.filter((s) => s.complete).length : counts.done;
  const totalCount = isWorkflow && stages.length ? stages.length : tasks.length;
  const progressLabel = `${doneCount} of ${totalCount} ${isWorkflow && stages.length ? 'stages' : 'tasks'} done`;

  return (
    <div data-debug-id="task-summary-bar" className="space-y-2 text-left">
      {isWorkflow && workflowStatus && (
        <Text as="p" role="caption" tone="muted">
          <span className="font-semibold text-primary">{workflowStatus.workflow_name || 'Workflow'}</span>
          {workflowStatus.inputs && typeof workflowStatus.inputs === 'object'
            ? ` · ${Object.entries(workflowStatus.inputs)
                .map(([k, v]) => `${k.replace(/_/g, ' ')}: ${String(v)}`)
                .join(' · ')}`
            : ''}
        </Text>
      )}

      <div className="flex items-center gap-3">
        <ProgressBar
          value={totalCount ? Math.round((doneCount / totalCount) * 100) : 0}
          label={progressLabel}
          tone={failedStage ? 'danger' : runComplete ? 'success' : 'accent'}
          size="sm"
          className="flex-1"
        />
        <Text role="caption" tone="muted" className="shrink-0">
          {progressLabel}
        </Text>
      </div>

      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-muted">
          {TASK_STATES_ORDER.filter((s) => counts[s] > 0).map((s) => (
            <span key={s} className="inline-flex items-center gap-1">
              <StatusDot tone={TASK_STATE_TONE[s]} label={TASK_STATE_LABELS[s]} size="sm" />
              {counts[s]} {TASK_STATE_LABELS[s].toLowerCase()}
            </span>
          ))}
          <span className="text-faint">
            {workers} worker{workers === 1 ? '' : 's'} · {reviewers} reviewer{reviewers === 1 ? '' : 's'} · {activeLeases} running
          </span>
        </div>
        {actions && <div className="flex flex-wrap items-center gap-1.5">{actions}</div>}
      </div>

      <div data-debug-id="task-attention-line" className="flex flex-wrap items-center gap-2 text-[11px]">
        {needsYou > 0 ? (
          onToggleNeedsYou ? (
            <Button
              size="sm"
              variant={needsYouActive ? 'primary' : 'secondary'}
              data-debug-id="attention-needs-you"
              aria-pressed={needsYouActive}
              onClick={onToggleNeedsYou}
            >
              {needsYouActive ? 'Show all tasks' : `${needsYou} ${needsYou === 1 ? 'task needs' : 'tasks need'} you`}
            </Button>
          ) : (
            <Text role="caption" tone="warning">
              {needsYou} {needsYou === 1 ? 'task needs' : 'tasks need'} you
            </Text>
          )
        ) : (
          <Text role="caption" tone="success">
            Nothing needs you
          </Text>
        )}
        {expiring > 0 && (
          <Text role="caption" tone="warning">
            {expiring} lease{expiring === 1 ? '' : 's'} about to expire
          </Text>
        )}
        {unclaimed > 0 && (
          <Text role="caption" tone="warning">
            {unclaimed} ready for {UNCLAIMED_AFTER_MINS}+ min with no free worker
          </Text>
        )}
        {failedStage && (
          <Text role="caption" tone="danger">
            Stage {failedStage.key.replace(/_/g, ' ')} failed, later stages are on hold
          </Text>
        )}
        {runComplete && (
          <Text role="caption" tone="success">
            Run complete
          </Text>
        )}
      </div>

      {summaryText && (
        <Text as="p" role="caption" tone="muted">
          {summaryText}
        </Text>
      )}
    </div>
  );
};

export default TaskSummaryBar;
