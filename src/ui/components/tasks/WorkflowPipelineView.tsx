import React, { useState } from 'react';
import { Icon, type IconName } from '@ui';
import { TaskWire } from '../../api/taskWire';
import { TaskSummaryBar } from './TaskSummaryBar';
import { TaskCard } from './TaskCard';
import {
  useFetchWorkflowStatusQuery,
  useRetryWorkflowMutation,
  useCancelWorkflowMutation,
  useUserReviewTaskMutation,
} from '../../api/endpoints/tasks';
import { normalizeTaskState } from './taskV2Types';

export interface WorkflowPipelineViewProps {
  chainId: string;
  chain: any;
  tasks: TaskWire[];
  selectedTaskId?: string | null;
  onSelectTask: (taskId: string) => void;
  className?: string;
}

export const WorkflowPipelineView: React.FC<WorkflowPipelineViewProps> = ({
  chainId,
  chain,
  tasks = [],
  selectedTaskId,
  onSelectTask,
  className = '',
}) => {
  const { data: workflowStatus } = useFetchWorkflowStatusQuery({ chainId });
  const [retryWorkflow, { isLoading: isRetrying }] = useRetryWorkflowMutation();
  const [cancelWorkflow, { isLoading: isCancelling }] = useCancelWorkflowMutation();
  const [userReviewTask] = useUserReviewTaskMutation();

  const [openStages, setOpenStages] = useState<Record<string, boolean>>({});
  const [cascadeRetry, setCascadeRetry] = useState(true);
  const [retryStageKey, setRetryStageKey] = useState<string>('');
  const [showRetryModal, setShowRetryModal] = useState(false);

  const toggleStage = (stageKey: string) => {
    setOpenStages((prev) => ({ ...prev, [stageKey]: !prev[stageKey] }));
  };

  const stages: any[] = workflowStatus?.stages || [];

  const handleGateAction = async (task: TaskWire, verdict: 'approve' | 'request_changes') => {
    try {
      await userReviewTask({
        chainId,
        taskId: task.task_id,
        verdict,
      }).unwrap();
    } catch (err) {
      console.error('Failed to submit gate review decision', err);
    }
  };

  const handleDoRetry = async () => {
    try {
      await retryWorkflow({
        chainId,
        stageKey: retryStageKey || undefined,
        cascade: cascadeRetry,
      }).unwrap();
      setShowRetryModal(false);
    } catch (err) {
      console.error('Failed to retry workflow', err);
    }
  };

  const handleDoCancel = async () => {
    if (!window.confirm('Cancel this entire workflow run?')) return;
    try {
      await cancelWorkflow({ chainId }).unwrap();
    } catch (err) {
      console.error('Failed to cancel workflow', err);
    }
  };

  return (
    <div
      data-debug-id="workflow-pipeline-view"
      className={`flex flex-col gap-4 text-left p-4 sm:p-6 overflow-y-auto ${className}`}
    >
      {/* Workflow Summary Bar */}
      <TaskSummaryBar
        tasks={tasks}
        kind="workflow"
        workflowStatus={workflowStatus}
        onSelectTask={onSelectTask}
        summaryText={chain?.summary}
      />

      {/* Workflow Controls Bar */}
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-subtle pb-3">
        <div className="flex items-center gap-2">
          <span className="text-xs font-bold uppercase tracking-wider text-muted">
            Pipeline Stages ({stages.length})
          </span>
          {chain?.status === 'active' && (
            <span className="rounded-full bg-accent-soft px-2 py-0.5 font-mono text-[10px] text-accent">
              running
            </span>
          )}
        </div>

        <div className="flex items-center gap-2">
          <button
            type="button"
            data-debug-id="workflow-retry-btn"
            onClick={() => {
              setRetryStageKey(stages[0]?.key || '');
              setShowRetryModal(true);
            }}
            disabled={isRetrying}
            className="rounded border border-subtle bg-surface px-2.5 py-1 text-xs font-semibold text-primary hover:bg-surface-raised transition-colors"
          >
            Retry Stage…
          </button>

          {chain?.status === 'active' && (
            <button
              type="button"
              data-debug-id="workflow-cancel-btn"
              onClick={handleDoCancel}
              disabled={isCancelling}
              className="rounded border border-danger/40 bg-danger-soft px-2.5 py-1 text-xs font-semibold text-danger hover:bg-danger/20 transition-colors"
            >
              Cancel Run
            </button>
          )}
        </div>
      </div>

      {/* Stages List */}
      <div className="relative flex flex-col gap-4">
        {stages.map((st, i) => {
          const inst = tasks.filter((t) => t.stage_key === st.key);
          const done = inst.filter((t) => normalizeTaskState(t.state) === 'done').length;
          const failed = Boolean(
            st.failed || inst.some((t) => normalizeTaskState(t.state) === 'cancelled')
          );
          const active = inst.some((t) =>
            ['in_progress', 'in_review'].includes(normalizeTaskState(t.state))
          );
          const complete = Boolean(
            st.complete || (inst.length > 0 && done === inst.length)
          );
          const isMaterialised = inst.length > 0;
          const status = complete ? 'complete' : failed ? 'failed' : active ? 'active' : 'pending';

          const isOpen = openStages[st.key] !== false;

          const stageIcon: IconName | null = complete ? 'check' : failed ? 'alert' : active ? 'clock' : null;
          const glyphColor = complete
            ? 'bg-success-soft text-success border-success/40'
            : failed
              ? 'bg-danger-soft text-danger border-danger/40'
              : active
                ? 'bg-accent-soft text-accent border-accent/40 animate-pulse'
                : 'bg-neutral-soft text-muted border-subtle';

          const isGate = st.kind === 'gate';
          const gateTask = isGate && inst.length > 0 ? inst[0] : null;

          return (
            <div
              key={st.key}
              data-debug-id={`stage-card-${st.key}`}
              className="relative flex flex-col rounded-xl border border-subtle bg-surface/50 overflow-hidden"
            >
              {/* Stage header */}
              <header
                role="button"
                tabIndex={0}
                onClick={() => toggleStage(st.key)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    toggleStage(st.key);
                  }
                }}
                className="flex items-center justify-between px-4 py-3 bg-surface hover:bg-surface-raised cursor-pointer select-none transition-colors"
              >
                <div className="flex items-center gap-2.5 min-w-0">
                  <span
                    className={`grid h-5 w-5 place-items-center rounded-full border text-[11px] font-bold shrink-0 ${glyphColor}`}
                  >
                    {stageIcon ? <Icon name={stageIcon} size={12} /> : null}
                  </span>
                  <span className="truncate text-xs font-bold text-primary">
                    {st.title || st.key}
                  </span>
                  <span className="font-mono text-[10px] text-faint rounded bg-neutral-soft px-1.5 py-0.5">
                    {st.key}
                  </span>
                  {st.needs && st.needs.length > 0 && (
                    <span className="hidden sm:inline-flex font-mono text-[10px] text-muted rounded border border-subtle px-1.5 py-0.5">
                      needs {st.needs.join(', ')}
                    </span>
                  )}
                </div>

                <div className="flex items-center gap-2 shrink-0">
                  <span className="font-mono text-[11px] text-muted">
                    {isGate
                      ? complete
                        ? 'approved'
                        : isMaterialised
                          ? 'waiting on you'
                          : 'after dependencies'
                      : isMaterialised
                        ? `${done}/${inst.length} done`
                        : st.parallel
                          ? `${st.parallel} parallel`
                          : st.for_each
                            ? `expands from ${st.for_each}`
                            : '1 instance'}
                  </span>
                  <Icon name={isOpen ? 'chevron-down' : 'chevron-right'} size="sm" className="text-muted" />
                </div>
              </header>

              {/* Stage body */}
              {isOpen && (
                <div className="p-4 space-y-3">
                  {!isMaterialised ? (
                    <div className="rounded-xl border border-dashed border-subtle/80 bg-surface-raised/40 p-4 text-center text-xs text-muted">
                      materialises when {(st.needs || []).join(' + ') || 'upstream stages'} complete
                      {st.for_each ? ` · one instance per item of ${st.for_each}` : ''}
                    </div>
                  ) : isGate && gateTask ? (
                    <div
                      data-debug-id={`stage-gate-${st.key}`}
                      className="rounded-xl border border-accent/40 bg-accent-soft/20 p-4 flex flex-col gap-3"
                    >
                      <div className="flex items-center justify-between">
                        <span className="text-xs font-semibold text-accent uppercase tracking-wide">
                          Human Decision Gate
                        </span>
                        <span className="font-mono text-[11px] text-muted">
                          {gateTask.task_id}
                        </span>
                      </div>
                      <p className="text-xs leading-relaxed text-primary">
                        {gateTask.brief?.goal || 'Review and approve downstream stage execution.'}
                      </p>
                      {normalizeTaskState(gateTask.state) === 'done' ? (
                        <div className="inline-flex items-center gap-1.5 text-xs font-semibold text-success">
                          <Icon name="check" size="sm" />
                          <span>Approved — downstream stages unlocked</span>
                        </div>
                      ) : (
                        <div className="flex items-center gap-2 pt-1">
                          <button
                            type="button"
                            onClick={() => handleGateAction(gateTask, 'approve')}
                            className="rounded-lg bg-success px-3 py-1.5 text-xs font-semibold text-white hover:opacity-90 transition-opacity"
                          >
                            Approve Stage
                          </button>
                          <button
                            type="button"
                            onClick={() => handleGateAction(gateTask, 'request_changes')}
                            className="rounded-lg border border-subtle bg-surface px-3 py-1.5 text-xs font-semibold text-primary hover:bg-surface-raised transition-colors"
                          >
                            Request Changes
                          </button>
                          <button
                            type="button"
                            onClick={() => onSelectTask(gateTask.task_id)}
                            className="ml-auto text-xs text-accent hover:underline"
                          >
                            View gate details
                          </button>
                        </div>
                      )}
                    </div>
                  ) : (
                    <div className="space-y-2">
                      {inst
                        .slice()
                        .sort((a, b) => (a.stage_index || 0) - (b.stage_index || 0))
                        .map((task) => (
                          <TaskCard
                            key={task.task_id}
                            task={task}
                            selected={selectedTaskId === task.task_id}
                            onSelect={onSelectTask}
                          />
                        ))}
                    </div>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </div>

      {/* Retry Modal */}
      {showRetryModal && (
        <div
          data-debug-id="workflow-retry-modal"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div className="w-full max-w-md rounded-2xl border border-subtle bg-surface p-5 space-y-4 shadow-xl">
            <h3 className="text-sm font-bold text-primary">
              Retry Workflow Stage
            </h3>
            <p className="text-xs text-muted leading-relaxed">
              Re-executes a failed or completed stage. With cascade enabled, downstream tasks are re-run while unchanged items are carried forward.
            </p>

            <label className="flex flex-col gap-1 text-xs text-muted">
              <span>Stage to retry</span>
              <select
                value={retryStageKey}
                onChange={(e) => setRetryStageKey(e.target.value)}
                className="rounded-lg border border-subtle bg-surface-raised px-3 py-2 text-primary text-xs outline-none focus:border-accent"
              >
                {stages.map((st) => (
                  <option key={st.key} value={st.key}>
                    {st.key} ({st.title || st.key})
                  </option>
                ))}
              </select>
            </label>

            <label className="flex items-center gap-2 text-xs text-primary cursor-pointer select-none">
              <input
                type="checkbox"
                checked={cascadeRetry}
                onChange={(e) => setCascadeRetry(e.target.checked)}
                className="h-4 w-4 accent-accent"
              />
              <span>--cascade (cancel and re-materialise downstream stages)</span>
            </label>

            <div className="flex items-center justify-end gap-2 pt-2 border-t border-subtle">
              <button
                type="button"
                onClick={() => setShowRetryModal(false)}
                className="rounded-lg border border-subtle bg-surface px-3 py-1.5 text-xs font-semibold text-muted hover:text-primary transition-colors"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={handleDoRetry}
                disabled={isRetrying}
                className="rounded-lg bg-accent px-4 py-1.5 text-xs font-semibold text-accent-fg hover:opacity-90 transition-opacity"
              >
                {isRetrying ? 'Retrying…' : 'Run Retry'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default WorkflowPipelineView;
