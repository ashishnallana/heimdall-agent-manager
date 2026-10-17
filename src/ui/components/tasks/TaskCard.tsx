import React from 'react';
import { Badge, Button, Icon, IconButton, Link, Menu, StatusPill, Text } from '@ui';
import { TaskWire } from '../../api/taskWire';
import {
  TASK_STATE_LABELS,
  TASK_STATE_TONE,
  getTaskBadges,
  getTaskPeople,
  getTaskStatusLines,
  inProgressSentenceRest,
  normalizeTaskState,
  uiToneForBadge,
  workLeaseHolder,
  uiToneForPriority,
} from './taskV2Types';
import { TASK_ACTION_LABELS, getTaskActions, isDraft, type TaskActionId } from './taskActions';
import { useTaskActions } from './useTaskActions';
import { TaskDetails } from './TaskDetails';
import { HolderName } from './HolderName';
import { EMPTY_TASK_NAMES, type TaskNames } from './taskNames';

export interface TaskCardProps {
  task: TaskWire;
  chainId?: string;
  /** Expanded inline (plan REQ-UI-8). */
  expanded?: boolean;
  onToggle?: (taskId: string) => void;
  /** Opens another task of the chain (dependency links). */
  onSelectTask?: (taskId: string) => void;
  chainFleets?: any[];
  names?: TaskNames;
  /** Scroll this card into view once it is mounted (deep links, dependency jumps). */
  scrollIntoView?: boolean;
  onScrolled?: () => void;
  className?: string;
}

/**
 * One task as a single flat card (plan REQ-UI-7, design reference: the Tasks
 * pane on main): title, one sentence on what is happening, who works it, and only
 * the action that matters now. Everything else is one click away: the More menu
 * or the inline details.
 */
export const TaskCard: React.FC<TaskCardProps> = ({
  task,
  chainId = '',
  expanded = false,
  onToggle,
  onSelectTask,
  chainFleets,
  names = EMPTY_TASK_NAMES,
  scrollIntoView = false,
  onScrolled,
  className = '',
}) => {
  const cardRef = React.useRef<HTMLElement | null>(null);
  // Runs after the card exists in the DOM, so a cold deep link (the chain still
  // loading when the route is read) scrolls once its tasks arrive.
  React.useEffect(() => {
    if (!scrollIntoView || !cardRef.current) return;
    cardRef.current.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    onScrolled?.();
  }, [scrollIntoView, onScrolled]);
  const state = normalizeTaskState(task.state);
  const isGate = task.kind === 'gate';
  const now = Date.now();
  const [sentence, detail] = getTaskStatusLines(task, chainFleets, now, names);
  // The holder, time left and bridge already show in the status sentence and the
  // people line, so those badges are dropped here.
  const badges = getTaskBadges(task, chainFleets, now, names).filter((b) => b.kind !== 'lease' && b.kind !== 'bridge');
  const holderLease = workLeaseHolder(task, now);
  const holderUnnamed = Boolean(holderLease && !names.instance(holderLease.instanceId));
  const people = getTaskPeople(task, chainFleets);
  const actions = useTaskActions(chainId, task.task_id, task.title);
  const { primary, more } = getTaskActions(task);

  const workerLabel = people.assignee
    ? names.agent(people.assignee)
    : people.workers.length
      ? `any of ${people.workers.map(names.agent).join(', ')}`
      : 'no worker in fleet';
  const reviewerLabel = [...people.reviewers.map(names.agent), ...(people.userApproval ? ['you'] : [])].join(', ');
  const deps = task.depends_on || [];

  const runAction = async (id: TaskActionId) => {
    switch (id) {
      case 'publish':
        return actions.publish();
      case 'approve':
        return actions.approve();
      // Decisions that need words open the details, where the text box is.
      case 'request_changes':
      case 'answer':
        if (!expanded) onToggle?.(task.task_id);
        return true;
      case 'reopen':
        return actions.reopen();
      case 'cancel':
        if (!window.confirm(`Cancel "${task.title}"?`)) return false;
        return actions.cancel();
      case 'rerun_verify':
        return actions.rerunVerify();
      case 'copy_id':
        try {
          await navigator.clipboard?.writeText(task.task_id);
        } catch {
          /* clipboard unavailable: nothing to do */
        }
        return true;
    }
  };

  const toggle = () => onToggle?.(task.task_id);

  return (
    <article
      ref={cardRef}
      data-debug-id={`task-card-${task.task_id}`}
      data-id={task.task_id}
      aria-label={task.title}
      className={`rounded-lg border bg-surface text-xs ${expanded ? 'border-strong' : 'border-subtle'} ${className}`}
    >
      <div className="space-y-1.5 p-3">
        {/* Row 1: expand + title + state + priority */}
        <div className="flex min-w-0 items-center gap-2">
          <button
            type="button"
            data-debug-id={`task-card-toggle-${task.task_id}`}
            aria-expanded={expanded}
            onClick={toggle}
            className="flex min-w-0 flex-1 items-center gap-1.5 text-left"
          >
            <Icon name={expanded ? 'chevron-down' : 'chevron-right'} size="sm" className="shrink-0 text-muted" />
            <span className="truncate font-semibold text-primary">{task.title}</span>
          </button>
          {isDraft(task) && <Badge tone="neutral">Draft</Badge>}
          {isGate ? (
            <Badge tone="info">Gate</Badge>
          ) : (
            <Badge tone={uiToneForPriority(task.priority)}>{String(task.priority || 'p2').toUpperCase()}</Badge>
          )}
          <StatusPill tone={TASK_STATE_TONE[state]}>{TASK_STATE_LABELS[state]}</StatusPill>
          {more.length > 0 && (
            <Menu
              label={`More actions for ${task.title}`}
              align="end"
              trigger={
                <IconButton icon="more-horizontal" label="More actions" variant="ghost" size="sm" data-debug-id={`task-card-more-${task.task_id}`} />
              }
            >
              {more.map((id) => (
                <Menu.Item key={id} danger={id === 'cancel'} onClick={() => void runAction(id)}>
                  {TASK_ACTION_LABELS[id]}
                </Menu.Item>
              ))}
            </Menu>
          )}
        </div>

        {/* Row 2: what is happening, in one sentence */}
        <Text as="p" role="caption" tone="muted" data-debug-id={`task-card-status-${task.task_id}`}>
          <span className="text-primary">
            {holderUnnamed && holderLease ? (
              <>
                <HolderName instanceId={holderLease.instanceId} names={names} /> {inProgressSentenceRest(holderLease.leftMins)}
              </>
            ) : (
              sentence
            )}
          </span>
          {detail ? ` · ${detail}` : ''}
        </Text>

        {/* Row 3: who works it, who reviews it, what it waits for */}
        {!isGate && (
          <div
            data-debug-id={`task-card-people-${task.task_id}`}
            className="flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-muted"
          >
            <span>
              assignee:{' '}
              {people.holder ? (
                <HolderName instanceId={people.holder} names={names} className="font-semibold text-primary" />
              ) : (
                <span className={people.workers.length ? 'font-semibold text-primary' : 'text-warning'}>{workerLabel}</span>
              )}
            </span>
            <span>
              reviewers: <span className={reviewerLabel ? 'font-semibold text-primary' : 'text-faint'}>{reviewerLabel || 'none'}</span>
            </span>
            {deps.length > 0 && (
              <span>
                waits for:{' '}
                {deps.map((d, i) => (
                  <React.Fragment key={d}>
                    {i > 0 ? ', ' : ''}
                    <Link
                      href={`#/chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(d)}`}
                      onClick={(e) => {
                        if (!onSelectTask) return;
                        e.preventDefault();
                        onSelectTask(d);
                      }}
                    >
                      {names.task(d)}
                    </Link>
                  </React.Fragment>
                ))}
              </span>
            )}
            {task.bridge_id && (
              <span>
                bridge: <span className="font-semibold text-primary">{names.bridge(task.bridge_id)}</span>
              </span>
            )}
            {badges.map((b, i) => (
              <Badge key={i} tone={uiToneForBadge(b.tone)} title={b.title}>
                {b.label}
              </Badge>
            ))}
          </div>
        )}

        {/* Row 4: the action that matters now (the rest is in the More menu) */}
        {(primary.length > 0 || actions.error) && (
          <div className="flex flex-wrap items-center gap-1.5 pt-0.5">
            {primary.map((id) => (
              <Button
                key={id}
                size="sm"
                variant={id === 'request_changes' ? 'secondary' : 'primary'}
                disabled={actions.busy}
                data-debug-id={`task-action-${id}-${task.task_id}`}
                onClick={() => void runAction(id)}
              >
                {TASK_ACTION_LABELS[id]}
              </Button>
            ))}
            {actions.error && (
              <Text role="caption" tone="danger" className="min-w-0 whitespace-pre-line break-words">
                {actions.error}
              </Text>
            )}
          </div>
        )}
      </div>

      {expanded && (
        <TaskDetails
          chainId={chainId}
          task={task}
          actions={actions}
          chainFleets={chainFleets}
          names={names}
          onSelectTask={onSelectTask}
        />
      )}
    </article>
  );
};

export default TaskCard;
