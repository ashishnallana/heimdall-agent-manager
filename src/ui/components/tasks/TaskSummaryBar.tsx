import React from 'react';
import { Button, IconButton, Menu, StatusDot, Text } from '@ui';
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
  /** The one main chain action (New task / Publish chain), right-aligned. */
  primaryAction?: React.ReactNode;
  /** Everything else (Fleet, Review roles, Retry, Cancel) goes in one menu. */
  menuItems?: SummaryMenuItem[];
}

export interface SummaryMenuItem {
  label: string;
  onClick: () => void;
  danger?: boolean;
  disabled?: boolean;
  debugId?: string;
}

const INPUT_PREVIEW_CHARS = 80;

export interface WorkflowInputEntry {
  label: string;
  /** Complete value; objects are pretty-printed so expanded JSON stays readable. */
  full: string;
  /** One-line, length-capped value for the collapsed preview. */
  preview: string;
}

/** Splits workflow inputs into entries with a compact preview and the intact full text. */
export function summarizeWorkflowInputs(inputs: unknown): WorkflowInputEntry[] {
  if (!inputs || typeof inputs !== 'object') return [];
  return Object.entries(inputs as Record<string, unknown>).map(([k, v]) => {
    const full = typeof v === 'string' ? v : v !== null && typeof v === 'object' ? JSON.stringify(v, null, 2) : String(v);
    const flat = full.replace(/\s+/g, ' ').trim();
    const preview = flat.length > INPUT_PREVIEW_CHARS ? `${flat.slice(0, INPUT_PREVIEW_CHARS)}…` : flat;
    return { label: k.replace(/_/g, ' '), full, preview };
  });
}

/**
 * Workflow name plus a one-line input preview. Long inputs (e.g. a JSON context)
 * stay collapsed behind a disclosure; expanded values scroll inside a bounded box.
 */
export const WorkflowInputsSummary: React.FC<{ name: string; inputs?: unknown }> = ({ name, inputs }) => {
  const [open, setOpen] = React.useState(false);
  const panelId = React.useId();
  const entries = summarizeWorkflowInputs(inputs);
  const truncated = entries.some((e) => e.preview !== e.full);
  const expandable = truncated || entries.some((e) => e.full.includes('\n'));
  return (
    <div data-debug-id="workflow-inputs-summary" className="min-w-0 max-w-full space-y-1.5">
      <div className="flex min-w-0 items-start gap-2">
        <Text as="p" role="body-sm" tone="muted" className="min-w-0 flex-1 break-words [overflow-wrap:anywhere]">
          <span className="font-semibold text-primary">{name}</span>
          {entries.length > 0 && !open ? ` · ${entries.map((e) => `${e.label}: ${e.preview}`).join(' · ')}` : ''}
        </Text>
        {expandable && (
          <button
            type="button"
            data-debug-id="workflow-inputs-toggle"
            aria-expanded={open}
            aria-controls={panelId}
            onClick={() => setOpen((v) => !v)}
            className="shrink-0 rounded-sm text-caption text-accent focus-visible:outline-none focus-visible:shadow-focus"
          >
            {open ? 'Show less' : 'Show details'}
          </button>
        )}
      </div>
      {open && (
        <dl id={panelId} data-debug-id="workflow-inputs-detail" className="max-h-64 min-w-0 space-y-2 overflow-y-auto rounded-md bg-subtle p-2">
          {entries.map((e) => (
            <div key={e.label} className="min-w-0">
              <dt className="text-caption uppercase text-faint">{e.label}</dt>
              <dd className="m-0 min-w-0 max-w-full overflow-x-auto whitespace-pre-wrap break-words text-caption text-muted [overflow-wrap:anywhere]">
                {e.full}
              </dd>
            </div>
          ))}
        </dl>
      )}
    </div>
  );
};

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
  primaryAction,
  menuItems = [],
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

  const needsYouControl =
    needsYou > 0 ? (
      onToggleNeedsYou ? (
        <Button
          size="sm"
          variant={needsYouActive ? 'secondary' : 'primary'}
          data-debug-id="attention-needs-you"
          aria-pressed={needsYouActive}
          onClick={onToggleNeedsYou}
        >
          {needsYouActive ? 'Show all tickets' : `${needsYou} ${needsYou === 1 ? 'ticket needs' : 'tickets need'} you`}
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
    );

  const warnings = [
    expiring > 0 && { tone: 'warning' as const, text: `${expiring} lease${expiring === 1 ? '' : 's'} about to expire` },
    unclaimed > 0 && { tone: 'warning' as const, text: `${unclaimed} ready for ${UNCLAIMED_AFTER_MINS}+ min with no free worker` },
    failedStage && { tone: 'danger' as const, text: `Stage ${failedStage.key.replace(/_/g, ' ')} failed, later stages are on hold` },
    runComplete && { tone: 'success' as const, text: 'Run complete' },
  ].filter(Boolean) as { tone: 'warning' | 'danger' | 'success'; text: string }[];

  return (
    <div data-debug-id="task-summary-bar" className="space-y-3 text-left">
      {isWorkflow && workflowStatus && (
        <WorkflowInputsSummary name={workflowStatus.workflow_name || 'Workflow'} inputs={workflowStatus.inputs} />
      )}

      {/* One row that never wraps its controls: what needs you on the left, the
          chain menu and the single main action on the right. */}
      <div data-debug-id="task-attention-line" className="flex items-center gap-2">
        <div className="min-w-0 flex-1">{needsYouControl}</div>
        {menuItems.length > 0 && (
          <Menu
            label="Chain options"
            align="end"
            trigger={<IconButton icon="more-horizontal" label="Chain options" variant="solid" size="sm" data-debug-id="task-summary-menu" />}
          >
            {menuItems.map((it) => (
              <Menu.Item key={it.label} danger={it.danger} disabled={it.disabled} onClick={it.onClick} data-debug-id={it.debugId}>
                {it.label}
              </Menu.Item>
            ))}
          </Menu>
        )}
        {primaryAction}
      </div>
      {warnings.length > 0 && (
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
          {warnings.map((w) => (
            <Text key={w.text} role="caption" tone={w.tone}>
              {w.text}
            </Text>
          ))}
        </div>
      )}

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
