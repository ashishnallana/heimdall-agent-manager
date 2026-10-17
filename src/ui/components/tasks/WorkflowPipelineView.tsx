import React, { useState } from 'react';
import { Button, Checkbox, Icon, Modal, ModalBody, ModalFooter, Select, Text, type IconName } from '@ui';
import { TaskWire } from '../../api/taskWire';
import { TaskSummaryBar } from './TaskSummaryBar';
import { TaskCard } from './TaskCard';
import { useCancelWorkflowMutation, useFetchWorkflowStatusQuery, useRetryWorkflowMutation } from '../../api/endpoints/tasks';
import { normalizeTaskState } from './taskV2Types';
import { EMPTY_TASK_NAMES, type TaskNames } from './taskNames';
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
  /** Chain-level buttons (e.g. Fleet) shown in the header. */
  actions?: React.ReactNode;
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
  failed: 'alert',
  active: 'clock',
  pending: null,
};
const STAGE_TEXT_TONE: Record<StageStatus, string> = {
  complete: 'text-success',
  failed: 'text-danger',
  active: 'text-info',
  pending: 'text-faint',
};

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
  actions,
  names = EMPTY_TASK_NAMES,
  className = '',
}) => {
  const { data: workflowStatus } = useFetchWorkflowStatusQuery({ chainId });
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

  return (
    <div data-debug-id="workflow-pipeline-view" className={`flex flex-col gap-3 p-4 text-left ${className}`}>
      <TaskSummaryBar
        tasks={tasks}
        chainFleets={chainFleets}
        kind="workflow"
        workflowStatus={workflowStatus}
        summaryText={chain?.summary}
        actions={
          <>
            {actions}
            <Button
              size="sm"
              variant="secondary"
              data-debug-id="workflow-retry-btn"
              disabled={stages.length === 0}
              onClick={() => {
                setRetryStageKey(stages.find((st) => st.failed)?.key || stages[0]?.key || '');
                setRetryOpen(true);
              }}
            >
              Retry stage
            </Button>
            {running && (
              <Button size="sm" variant="secondary" tone="danger" data-debug-id="workflow-cancel-btn" loading={cancelState.isLoading} onClick={handleCancelRun}>
                Cancel run
              </Button>
            )}
          </>
        }
      />
      {error && (
        <Text role="caption" tone="danger" className="break-words">
          {error}
        </Text>
      )}

      <ol className="flex flex-col gap-4">
        {stages.map((st) => {
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
          const isOpen = !collapsed[st.key];
          const icon = STAGE_ICON[status];
          const progress =
            inst.length === 0
              ? st.needs?.length
                ? `starts after ${st.needs.join(', ')}`
                : 'not started'
              : `${doneCount} of ${inst.length} done`;

          return (
            <li key={st.key} data-debug-id={`stage-card-${st.key}`} className="space-y-2">
              <button
                type="button"
                aria-expanded={isOpen}
                onClick={() => setCollapsed((prev) => ({ ...prev, [st.key]: isOpen }))}
                className="flex w-full min-w-0 items-center gap-2 text-left"
              >
                <Icon name={isOpen ? 'chevron-down' : 'chevron-right'} size="sm" className="shrink-0 text-muted" />
                <span className={`inline-flex h-4 w-4 shrink-0 items-center justify-center ${STAGE_TEXT_TONE[status]}`}>
                  {icon ? <Icon name={icon} size={12} title={status} /> : <span className="h-1.5 w-1.5 rounded-full bg-current" />}
                </span>
                <span className="truncate text-xs font-semibold text-primary">
                  {renderStageTitle(st.title || st.key, workflowStatus?.inputs || {})}
                </span>
                <span className="shrink-0 text-[11px] text-muted">· {progress}</span>
                {st.kind === 'gate' && <span className="shrink-0 text-[11px] text-muted">· needs a decision</span>}
              </button>

              {isOpen && inst.length > 0 && (
                <div className="flex flex-col gap-2 pl-6">
                  {inst.map((task) => (
                    <TaskCard
                      key={task.task_id}
                      task={task}
                      chainId={chainId}
                      expanded={expandedTaskId === task.task_id}
                      onToggle={onToggleTask}
                      onSelectTask={onSelectTask}
                      chainFleets={chainFleets}
                      names={names}
                    />
                  ))}
                </div>
              )}
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
