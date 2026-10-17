import React from 'react';
import { TaskWire } from '../../api/taskWire';
import { getTaskBadges, getTaskPeople, normalizeTaskState } from './taskV2Types';
import { formatFleetRoleName } from './FleetManagementDrawer';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';

export interface TaskCardProps {
  task: TaskWire;
  selected?: boolean;
  onSelect?: (taskId: string) => void;
  chainFleets?: any[];
  className?: string;
}

export const TaskCard: React.FC<TaskCardProps> = ({
  task,
  selected = false,
  onSelect,
  chainFleets,
  className = '',
}) => {
  const state = normalizeTaskState(task.state);
  const badges = getTaskBadges(task, chainFleets);
  const isAwaitingUser = state === 'in_review' && task.requires_user_approval;
  const isGate = task.kind === 'gate';
  const people = getTaskPeople(task, chainFleets);
  const { data: identitiesData } = useListAgentIdentitiesQuery();
  const agentName = (id: string) => formatFleetRoleName(id, identitiesData?.agents || []);
  const workerLabel = people.assignee
    ? agentName(people.assignee)
    : people.workers.length
      ? `any of ${people.workers.map(agentName).join(', ')}`
      : 'no worker in fleet';
  const reviewerLabel = [
    ...people.reviewers.map(agentName),
    ...(people.userApproval ? ['you'] : []),
  ].join(', ');
  // The wire sends lowercase p0|p1|p2; older fixtures use P0 / urgent / high.
  const priority = String(task.priority || '').toLowerCase();

  const summary = task.comment_summary?.last_comment_preview ||
    (task.brief?.goal ? String(task.brief.goal) : '');

  const handleClick = () => {
    onSelect?.(task.task_id);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      onSelect?.(task.task_id);
    }
  };

  return (
    <article
      data-debug-id={`task-card-${task.task_id}`}
      data-id={task.task_id}
      tabIndex={0}
      role="button"
      aria-label={task.title}
      onClick={handleClick}
      onKeyDown={handleKeyDown}
      className={`group relative flex flex-col gap-2 rounded-xl border p-3 text-left transition-all cursor-pointer outline-none focus-visible:ring-2 focus-visible:ring-accent ${
        selected
          ? 'border-accent bg-accent/10 shadow-sm'
          : isAwaitingUser
            ? 'border-accent/60 bg-accent/5 hover:border-accent hover:bg-accent/10'
            : 'border-subtle bg-surface hover:border-border-strong hover:bg-surface-raised'
      } ${className}`}
    >
      {/* Top row: id, title, priority or gate */}
      <div className="flex items-center gap-2 min-w-0">
        <span className="shrink-0 font-mono text-[11px] text-muted">
          {task.task_id}
        </span>
        <span className="flex-1 truncate text-sm font-semibold text-primary group-hover:text-accent transition-colors">
          {task.title}
        </span>
        {isGate ? (
          <span className="shrink-0 rounded-md bg-accent-soft px-1.5 py-0.5 font-mono text-[10px] font-semibold text-accent uppercase">
            Gate
          </span>
        ) : (
          <span
            className={`shrink-0 rounded-md px-1.5 py-0.5 font-mono text-[10px] font-semibold uppercase ${
              priority === 'p0' || priority === 'urgent'
                ? 'bg-danger-soft text-danger'
                : priority === 'p1' || priority === 'high'
                  ? 'bg-warning-soft text-warning'
                  : 'bg-neutral-soft text-muted'
            }`}
          >
            {task.priority || 'P1'}
          </span>
        )}
      </div>

      {/* Badges row */}
      {badges.length > 0 && (
        <div className="flex flex-wrap items-center gap-1.5">
          {badges.map((b, i) => {
            const toneClasses =
              b.tone === 'ok'
                ? 'bg-success-soft text-success border-success/30'
                : b.tone === 'accent'
                  ? 'bg-accent-soft text-accent border-accent/30'
                  : b.tone === 'danger'
                    ? 'bg-danger-soft text-danger border-danger/30'
                    : b.tone === 'warn'
                      ? 'bg-warning-soft text-warning border-warning/30'
                      : b.tone === 'info'
                        ? 'bg-info-soft text-info border-info/30'
                        : 'bg-neutral-soft text-muted border-subtle';
            return (
              <span
                key={i}
                title={b.title}
                className={`inline-flex items-center rounded border px-1.5 py-0.5 font-mono text-[10px] font-medium leading-none ${toneClasses}`}
              >
                {b.label}
              </span>
            );
          })}
        </div>
      )}

      {/* People: who works it, who reviews it */}
      {!isGate && (
        <div
          data-debug-id={`task-card-people-${task.task_id}`}
          className="flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-muted"
        >
          <span title={people.assignee ? `Pinned to agent ${people.assignee}` : 'Granted to the next free fleet worker'}>
            Assignee: <span className={people.workers.length ? 'text-primary' : 'text-warning'}>{workerLabel}</span>
          </span>
          {reviewerLabel && (
            <span title="Must approve before Done">
              Reviewers: <span className="text-primary">{reviewerLabel}</span>
            </span>
          )}
        </div>
      )}

      {/* Summary / goal line */}
      {summary && (
        <p className="line-clamp-2 text-xs leading-relaxed text-muted font-normal">
          {summary}
        </p>
      )}
    </article>
  );
};

export default TaskCard;
