import React, { useState } from 'react';
import { Button, Checkbox, Icon, Modal, ModalBody, ModalFooter, Select, Text, type IconName } from '@ui';
import { TaskWire } from '../../api/taskWire';
import { TaskSummaryBar } from './TaskSummaryBar';
import { TaskCard } from './TaskCard';
import { TaskBoardSkeleton } from './TaskBoardSkeleton';
import { useCancelWorkflowMutation, useFetchWorkflowStatusQuery, useRetryWorkflowMutation } from '../../api/endpoints/tasks';
import { normalizeTaskState } from './taskV2Types';
import { EMPTY_TASK_NAMES, type TaskNames } from './taskNames';
import { taskNeedsYou } from './taskActions';
import { actionErrorMessage } from './useTaskActions';

export interface WorkflowPipelineViewProps {
  chainId: string;
  chain: any;
  tasks: TaskWire[];
  chainFleets?: any[];
  /** The card expanded inline (plan REQ-UI-8). */
  expandedTaskId?: string | null;
  onToggleTask: (taskId: string) => void;
  onSelectTask?: (taskId: string) => void;
  /** The card to scroll into view once mounted; cleared through onScrolled. */
  scrollTaskId?: string | null;
  onScrolled?: () => void;
  onOpenFleetDrawer?: () => void;
  onOpenReviewRoles?: () => void;
  /** Rendered directly under the summary bar (the chain overview mounts its Active servers panel here). */
  summarySlot?: React.ReactNode;
  names?: TaskNames;
  className?: string;
}

type StageStatus = 'complete' | 'failed' | 'active' | 'pending';

/**
 * Stage titles come from the workflow template ("Explore: {{inputs.goal}}").
 * Fill run inputs in, and describe per-item placeholders in words, so a raw
 * template never shows.
 */
export function renderStageTitle(title: string, inputs: Record<string, unknown> = {}): string {
  return String(title || '')
    .replace(/\{\{\s*inputs\.([a-zA-Z0-9_]+)\s*\}\}/g, (_m, key) => (inputs[key] != null ? String(inputs[key]) : key.replace(/_/g, ' ')))
    .replace(/\{\{\s*item\.[a-zA-Z0-9_]+\s*\}\}/g, 'each planned item')
    .replace(/\{\{[^}]*\}\}/g, '…')
    .trim();
}

const STAGE_ICON: Record<StageStatus, IconName | null> = {
  complete: 'check',
  failed: 'close',
  active: 'play',
  pending: null,
};
const STAGE_TEXT_TONE: Record<StageStatus, string> = {
  complete: 'text-success',
  failed: 'text-danger',
  active: 'text-info',
  pending: 'text-faint',
};
const STAGE_STATUS_LABEL: Record<StageStatus, string> = {
  complete: 'complete',
  failed: 'failed',
  active: 'running',
  pending: 'waiting',
};
const STAGE_NODE: Record<StageStatus, string> = {
  complete: 'border-success bg-success text-canvas',
  failed: 'border-danger bg-danger-soft text-danger',
  active: 'border-info bg-info-soft text-info',
  pending: 'border-subtle bg-surface text-faint',
};

/** The stepper marker: a circle per stage, a diamond for gates. */
function StageNode({ status, gate, awaitingDecision }: { status: StageStatus; gate: boolean; awaitingDecision: boolean }) {
  const tone = awaitingDecision ? 'border-accent bg-accent-soft text-accent' : STAGE_NODE[status];
  const icon = STAGE_ICON[status];
  return (
    <span className="relative z-[1] inline-flex h-6 w-6 shrink-0 items-center justify-center" aria-label={awaitingDecision ? 'waiting for your decision' : status}>
      {status === 'active' && !awaitingDecision && (
        <span aria-hidden="true" className="absolute inset-0 rounded-full border border-info opacity-60 motion-safe:animate-ping" />
      )}
      <span
        aria-hidden="true"
        className={`inline-flex items-center justify-center border ${tone} ${gate ? 'h-4 w-4 rotate-45 rounded-[3px]' : 'h-6 w-6 rounded-full'}`}
      >
        {icon && <Icon name={icon} size={gate ? 10 : 12} className={gate ? '-rotate-45' : ''} />}
      </span>
    </span>
  );
}

/**
 * A workflow run as its stages, top to bottom (plan REQ-UI-7). Each stage is a
 * heading with its tasks below as the same flat cards the ticket board uses, so
 * a gate offers Approve / Request changes exactly where a review would.
 */
export const WorkflowPipelineView: React.FC<WorkflowPipelineViewProps> = ({
  chainId,
  chain,
  tasks = [],
  chainFleets = [],
  expandedTaskId,
  onToggleTask,
  onSelectTask,
  scrollTaskId,
  onScrolled,
  onOpenFleetDrawer,
  onOpenReviewRoles,
  summarySlot,
  names = EMPTY_TASK_NAMES,
  className = '',
}) => {
  const { data: workflowStatus, isLoading: loadingStatus } = useFetchWorkflowStatusQuery({ chainId });
  const [retryWorkflow, retryState] = useRetryWorkflowMutation();
  const [cancelWorkflow, cancelState] = useCancelWorkflowMutation();

  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const [retryOpen, setRetryOpen] = useState(false);
  const [retryStageKey, setRetryStageKey] = useState('');
  const [cascadeRetry, setCascadeRetry] = useState(true);
  const [error, setError] = useState('');

  const stages: any[] = workflowStatus?.stages || [];
  const running = chain?.status === 'active';

  const handleRetry = async () => {
    setError('');
    try {
      await retryWorkflow({ chainId, stageKey: retryStageKey || undefined, cascade: cascadeRetry }).unwrap();
      setRetryOpen(false);
    } catch (err) {
      setError(actionErrorMessage(err));
    }
  };

  const handleCancelRun = async () => {
    if (!window.confirm('Cancel this whole workflow run?')) return;
    setError('');
    try {
      await cancelWorkflow({ chainId }).unwrap();
    } catch (err) {
      setError(actionErrorMessage(err));
    }
  };

  if (loadingStatus && !workflowStatus) return <TaskBoardSkeleton stepper cards={3} />;

  return (
    <div data-debug-id="workflow-pipeline-view" className={`flex flex-col gap-5 p-4 text-left sm:p-5 ${className}`}>
      <TaskSummaryBar
        tasks={tasks}
        chainFleets={chainFleets}
        kind="workflow"
        workflowStatus={workflowStatus}
        summaryText={chain?.summary}
        menuItems={[
          ...(onOpenFleetDrawer ? [{ label: 'Fleet', onClick: onOpenFleetDrawer }] : []),
          ...(onOpenReviewRoles ? [{ label: 'Review roles', onClick: onOpenReviewRoles }] : []),
          {
            label: 'Retry a stage…',
            debugId: 'workflow-retry-btn',
            disabled: stages.length === 0,
            onClick: () => {
              setRetryStageKey(stages.find((st) => st.failed)?.key || stages[0]?.key || '');
              setRetryOpen(true);
            },
          },
          ...(running ? [{ label: 'Cancel run', danger: true, debugId: 'workflow-cancel-btn', disabled: cancelState.isLoading, onClick: () => void handleCancelRun() }] : []),
        ]}
      />
      {error && (
        <Text role="caption" tone="danger" className="break-words">
          {error}
        </Text>
      )}
      {summarySlot}

      <ol data-debug-id="workflow-stepper" className="flex flex-col">
        {stages.map((st, idx) => {
          const inst = tasks
            .filter((t) => t.stage_key === st.key)
            .sort((a, b) => (a.stage_index || 0) - (b.stage_index || 0));
          const doneCount = inst.filter((t) => normalizeTaskState(t.state) === 'done').length;
          const status: StageStatus =
            st.complete || (inst.length > 0 && doneCount === inst.length)
              ? 'complete'
              : st.failed || inst.some((t) => normalizeTaskState(t.state) === 'cancelled')
                ? 'failed'
                : inst.some((t) => ['in_progress', 'in_review'].includes(normalizeTaskState(t.state)))
                  ? 'active'
                  : 'pending';
          const isGate = st.kind === 'gate';
          // A gate only asks for a decision while one is actually pending.
          const awaitingDecision = isGate && inst.some(taskNeedsYou);
          const isOpen = !collapsed[st.key];
          const isLast = idx === stages.length - 1;
          const title = renderStageTitle(st.title || st.key, workflowStatus?.inputs || {});
          // One task per stage: the card carries the title, so the stage row only
          // names the step instead of repeating it.
          const single = inst.length === 1;
          const progress =
            inst.length === 0
              ? st.needs?.length
                ? `starts after ${st.needs.map((n: string) => n.replace(/_/g, ' ')).join(', ')}`
                : 'not started'
              : single
                ? STAGE_STATUS_LABEL[status]
                : `${doneCount} of ${inst.length} done`;

          return (
            <li key={st.key} data-debug-id={`stage-card-${st.key}`} className="relative flex gap-3 pb-5 last:pb-0">
              {/* Connector to the next stage: solid once this stage is complete. */}
              {!isLast && (
                <span
                  aria-hidden="true"
                  className={`absolute left-3 top-7 bottom-0 w-px -translate-x-1/2 ${status === 'complete' ? 'bg-success' : 'bg-subtle'}`}
                />
              )}
              <StageNode status={status} gate={isGate} awaitingDecision={awaitingDecision} />

              <div className="min-w-0 flex-1 space-y-2">
                <button
                  type="button"
                  aria-expanded={isOpen}
                  onClick={() => setCollapsed((prev) => ({ ...prev, [st.key]: isOpen }))}
                  className="flex min-h-6 w-full min-w-0 flex-wrap items-center gap-x-2 gap-y-0.5 rounded-sm text-left focus-visible:outline-none focus-visible:shadow-focus"
                >
                  <Text as="span" role="overline" tone="faint" className="shrink-0 uppercase tabular-nums">
                    Step {idx + 1}
                    {isGate ? ' · Gate' : ''}
                  </Text>
                  {!single && <span className="min-w-0 truncate text-title text-primary">{title}</span>}
                  <span className={`shrink-0 text-caption ${awaitingDecision ? 'text-accent' : STAGE_TEXT_TONE[status]}`}>
                    {awaitingDecision ? 'Waiting for your decision' : progress}
                  </span>
                  <Icon
                    name="chevron-right"
                    size="sm"
                    className={`ml-auto shrink-0 text-faint transition-transform duration-150 motion-reduce:transition-none ${isOpen ? 'rotate-90' : ''}`}
                  />
                </button>

                {isOpen && inst.length > 0 && (
                  <div className="flex flex-col gap-2">
                    {inst.map((task) => (
                      <TaskCard
                        key={task.task_id}
                        task={task}
                        chainId={chainId}
                        expanded={expandedTaskId === task.task_id}
                        onToggle={onToggleTask}
                        onSelectTask={onSelectTask}
                        scrollIntoView={scrollTaskId === task.task_id}
                        onScrolled={onScrolled}
                        chainFleets={chainFleets}
                        names={names}
                        chainTasks={tasks}
                        chainKind='workflow'
                      />
                    ))}
                  </div>
                )}
              </div>
            </li>
          );
        })}
      </ol>

      <Modal open={retryOpen} onOpenChange={setRetryOpen} title="Retry a stage" size="sm">
        <ModalBody className="space-y-3">
          <Text as="p" role="caption" tone="muted">
            Runs the stage again. With the downstream option on, later stages are re-created too, and finished items that did
            not change are carried forward.
          </Text>
          <Select
            value={retryStageKey}
            onChange={setRetryStageKey}
            options={stages.map((st) => ({ value: st.key, text: renderStageTitle(st.title || st.key, workflowStatus?.inputs || {}) }))}
            aria-label="Stage to retry"
            width="full"
          />
          <Checkbox checked={cascadeRetry} onChange={setCascadeRetry} label="Also redo the stages after it" />
        </ModalBody>
        <ModalFooter>
          <Button size="sm" variant="ghost" onClick={() => setRetryOpen(false)}>
            Close
          </Button>
          <Button size="sm" variant="primary" loading={retryState.isLoading} onClick={handleRetry}>
            Retry
          </Button>
        </ModalFooter>
      </Modal>
    </div>
  );
};

export default WorkflowPipelineView;
