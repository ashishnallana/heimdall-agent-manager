import React from 'react';
import { Badge, Button, Icon, Text, type Tone } from '@ui';
import type { WorkflowRunView } from '../../api/endpoints/workflowRuns';
import { VaultText } from '../vault/VaultText';

const LABELS: Record<string, string> = {
  draft: 'Draft', pending: 'Waiting', running: 'Running', succeeded: 'Succeeded',
  failed: 'Failed', cancelled: 'Cancelled', done: 'Done', ready: 'Ready',
  in_progress: 'In progress', in_review: 'In review', waiting_approval: 'Awaiting approval', backlog: 'Waiting',
};

function statusTone(state: string): Tone {
  if (state === 'succeeded' || state === 'done') return 'success';
  if (state === 'failed') return 'danger';
  if (state === 'running' || state === 'in_progress') return 'info';
  if (state === 'in_review' || state === 'waiting_approval') return 'warning';
  return 'neutral';
}

function WorkflowRunCard({ run, focusTaskId }: { run: WorkflowRunView; focusTaskId?: string }) {
  const stages = run.stages || [];
  const containsFocus = Boolean(focusTaskId && stages.some((stage) => stage.tasks?.some((task) => task.task_id === focusTaskId)));
  const [expanded, setExpanded] = React.useState(run.status === 'running' || containsFocus);
  const card = React.useRef<HTMLElement>(null);
  React.useEffect(() => {
    if (containsFocus) {
      setExpanded(true);
      card.current?.scrollIntoView?.({ block: 'nearest' });
    }
  }, [containsFocus, focusTaskId]);
  const detailsId = `workflow-run-stages-${run.run_id}`;
  return (
    <article ref={card} data-debug-id={`workflow-run-card-${run.run_id}`} className="relative overflow-hidden rounded-xl border border-subtle bg-surface text-left">
      <span aria-hidden="true" className={`absolute inset-y-0 left-0 w-1 ${run.status === 'failed' ? 'bg-danger' : run.status === 'succeeded' ? 'bg-success' : 'bg-accent'}`} />
      <button type="button" data-debug-id={`workflow-run-toggle-${run.run_id}`} aria-expanded={expanded} aria-controls={detailsId} onClick={() => setExpanded((value) => !value)} className="flex w-full items-start gap-2.5 rounded-xl py-4 pl-6 pr-4 text-left focus-visible:outline-none focus-visible:shadow-focus">
        <Icon name="chevron-right" size="sm" className={`mt-0.5 shrink-0 text-faint transition-transform motion-reduce:transition-none ${expanded ? 'rotate-90' : ''}`} />
        <span className="min-w-0 flex-1">
          <VaultText value={run.title || run.workflow_name} fallback="Untitled workflow" className="block break-words text-sm font-semibold text-primary" />
          <span className="mt-2 block text-caption text-muted">Workflow · Execution {run.execution_no} · {stages.filter((stage) => stage.complete).length} of {stages.length} stages done</span>
        </span>
        <Badge tone={statusTone(run.status)}>{LABELS[run.status] || run.status}</Badge>
      </button>
      {run.failure_detail && <VaultText as="p" value={run.failure_detail} className="px-6 pb-3 text-caption text-danger" />}
      {expanded && (
        <div id={detailsId} className="flex flex-col gap-3 border-t border-subtle px-5 py-4">
          <Text role="caption" tone="muted">Read-only · Managed by this chain’s coordinator</Text>
          {stages.map((stage) => (
            <section key={stage.key} data-debug-id={`workflow-run-stage-${run.run_id}-${stage.key}`} className="flex flex-col gap-2 border-l border-subtle pl-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <Text role="caption" tone="muted">{stage.key}{stage.kind === 'gate' ? ' · Approval gate' : ''}</Text>
                <Badge tone={statusTone(stage.state)}>{LABELS[stage.state] || stage.state}</Badge>
              </div>
              {stage.tasks?.map((task) => (
                <div key={task.task_id} data-debug-id={`workflow-run-task-${task.task_id}`} className={`flex flex-wrap items-center justify-between gap-2 rounded-lg border px-3 py-2 ${task.task_id === focusTaskId ? 'border-accent bg-accent-soft' : 'border-subtle bg-canvas'}`}>
                  <VaultText value={task.title} fallback="Untitled task" className="min-w-0 flex-1 break-words text-caption text-primary" />
                  <span className="text-caption text-faint">{LABELS[task.state] || task.state}{task.attempt_no > 0 ? ` · Attempt ${task.attempt_no}` : ''}</span>
                </div>
              ))}
              {!stage.tasks?.length && <Text role="caption" tone="faint">{stage.complete ? 'Completed with no tasks' : run.status === 'cancelled' || run.status === 'failed' ? 'Not started' : 'Waiting for prerequisites'}</Text>}
            </section>
          ))}
        </div>
      )}
    </article>
  );
}

export function WorkflowRunsReadOnly({ runs, loading, error, refresh, focusTaskId }: {
  runs: WorkflowRunView[]; loading: boolean; error?: unknown; refresh: () => void; focusTaskId?: string;
}) {
  if (!loading && !error && runs.length === 0) return null;
  return (
    <section aria-label="Workflow runs" data-debug-id="mixed-work-workflow-runs" className="flex flex-col gap-2">
      <div className="flex items-center justify-between gap-2">
        <Text role="overline" tone="faint" className="uppercase">Workflows {runs.length > 0 ? runs.length : ''}</Text>
        <span className="text-caption text-faint">Read-only</span>
      </div>
      {loading && runs.length === 0 && <Text role="caption" tone="muted">Loading workflows…</Text>}
      {error && (
        <div role="alert" className="flex items-center justify-between gap-3 rounded-lg border border-danger/40 bg-danger-soft p-3">
          <Text role="caption" tone="danger">Could not refresh workflows. {runs.length > 0 ? 'Showing the last loaded state.' : 'Tickets are still available below.'}</Text>
          <Button size="sm" variant="ghost" data-debug-id="mixed-work-workflows-retry" onClick={refresh}>Retry</Button>
        </div>
      )}
      {runs.map((run) => <WorkflowRunCard key={run.run_id} run={run} focusTaskId={focusTaskId} />)}
    </section>
  );
}
