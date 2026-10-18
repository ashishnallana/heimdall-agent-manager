import React from 'react';
import { Button, StatusDot, Text } from '@ui';
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

  // Segments of the stacked progress bar: finished work first, then work in
  // flight, then what has not started. Widths are shares of the total.
  const segments: { key: string; value: number; className: string; label: string }[] =
    isWorkflow && stages.length
      ? [
          { key: 'complete', value: stages.filter((st) => st.complete).length, className: 'bg-success', label: 'complete' },
          { key: 'failed', value: stages.filter((st) => st.failed).length, className: 'bg-danger', label: 'failed' },
        ]
      : [
          { key: 'done', value: counts.done, className: 'bg-success', label: 'done' },
          { key: 'in_review', value: counts.in_review, className: 'bg-warning', label: 'in review' },
          { key: 'in_progress', value: counts.in_progress, className: 'bg-info', label: 'in progress' },
          { key: 'ready', value: counts.ready, className: 'bg-strong', label: 'ready' },
        ];

  const attention = (
    <div data-debug-id="task-attention-line" className="flex min-w-0 flex-wrap items-center gap-2">
      {needsYou > 0 ? (
        onToggleNeedsYou ? (
          <Button
            size="sm"
            variant={needsYouActive ? 'secondary' : 'primary'}
            data-debug-id="attention-needs-you"
            aria-pressed={needsYouActive}
            onClick={onToggleNeedsYou}
          >
            {needsYouActive ? 'Show all tasks' : `${needsYou} ${needsYou === 1 ? 'task needs' : 'tasks need'} you`}
          </Button>
        ) : (
          <Text role="label" tone="accent">
            {needsYou} {needsYou === 1 ? 'task needs' : 'tasks need'} you
          </Text>
        )
      ) : (
        <span className="inline-flex items-center gap-1.5">
          <StatusDot tone="success" label="Nothing needs you" size="sm" />
          <Text role="label" tone="muted">
            Nothing needs you
          </Text>
        </span>
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
  );

  return (
    <div data-debug-id="task-summary-bar" className="space-y-3 text-left">
      {isWorkflow && workflowStatus && (
        <Text as="p" role="body-sm" tone="muted">
          <span className="font-semibold text-primary">{workflowStatus.workflow_name || 'Workflow'}</span>
          {workflowStatus.inputs && typeof workflowStatus.inputs === 'object'
            ? ` · ${Object.entries(workflowStatus.inputs)
                .map(([k, v]) => `${k.replace(/_/g, ' ')}: ${String(v)}`)
                .join(' · ')}`
            : ''}
        </Text>
      )}

      <div className="flex flex-wrap items-center justify-between gap-2">
        {attention}
        {actions && <div className="flex flex-wrap items-center gap-1.5">{actions}</div>}
      </div>

      <div className="space-y-1.5">
        <div
          role="img"
          aria-label={progressLabel}
          data-debug-id="task-progress-bar"
          className="flex h-1.5 w-full gap-0.5 overflow-hidden rounded-full bg-neutral-soft"
        >
          {totalCount > 0 &&
            segments
              .filter((seg) => seg.value > 0)
              .map((seg) => (
                <span
                  key={seg.key}
                  title={`${seg.value} ${seg.label}`}
                  className={`h-full transition-[width] duration-300 motion-reduce:transition-none ${seg.className}`}
                  style={{ width: `${(seg.value / totalCount) * 100}%` }}
                />
              ))}
        </div>
        <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 text-caption text-muted">
          <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
            {TASK_STATES_ORDER.filter((s) => counts[s] > 0).map((s) => (
              <span key={s} className="inline-flex items-center gap-1 tabular-nums">
                <StatusDot tone={TASK_STATE_TONE[s]} label={TASK_STATE_LABELS[s]} size="sm" />
                {counts[s]} {TASK_STATE_LABELS[s].toLowerCase()}
              </span>
            ))}
            <span className="text-faint tabular-nums">
              {workers} worker{workers === 1 ? '' : 's'} · {reviewers} reviewer{reviewers === 1 ? '' : 's'} · {activeLeases} running
            </span>
          </div>
          <span className="tabular-nums text-primary">{progressLabel}</span>
        </div>
      </div>

      {summaryText && (
        <Text as="p" role="body-sm" tone="muted" className="max-w-prose">
          {summaryText}
        </Text>
      )}
    </div>
  );
};

export default TaskSummaryBar;
