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
import { TASK_ACTION_LABELS, editLock, getTaskActions, isDraft, taskNeedsYou, type TaskActionId } from './taskActions';
import { TaskEditModal, type TaskEditField } from './TaskEditModal';
import { describeEffectivePlacement, taskEffectivePlacement } from './fleetSelection';
import { useTaskActions } from './useTaskActions';
import { TaskDetails } from './TaskDetails';
import { HolderName } from './HolderName';
import { PersonChip } from './PersonChip';
import { EMPTY_TASK_NAMES, type TaskNames } from './taskNames';

/** Left-rail color per state (needs-you overrides it with the accent). */
const STATE_RAIL: Record<string, string> = {
  in_progress: 'bg-info',
  in_review: 'bg-warning',
  ready: 'bg-strong',
  backlog: 'bg-subtle',
  done: 'bg-success',
  cancelled: 'bg-subtle',
};

/** Actions whose controls are in TaskDetails (Your review / Waiting on your answer). */
const DECISION_IN_DETAILS = new Set<TaskActionId>(['approve', 'request_changes', 'answer']);

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
  /** Every task of the chain (dependency picker). */
  chainTasks?: TaskWire[];
  /** 'workflow' locks manual edits (the run owns its tasks). */
  chainKind?: string;
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
  chainTasks = [],
  chainKind = '',
  className = '',
}) => {
  const [editing, setEditing] = React.useState<TaskEditField | null>(null);
  const lock = editLock(task, chainKind);
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
  const people = getTaskPeople(task, chainFleets);
  // The bridge that will actually be used (plan REQ-UI-12), never "inherit".
  const placement = describeEffectivePlacement(taskEffectivePlacement(task, chainFleets), names.bridge);
  const actions = useTaskActions(chainId, task.task_id, task.title);
  const { primary, more } = getTaskActions(task);

  const workerLabel = people.assignee
    ? names.agent(people.assignee)
    : people.workers.length
      ? people.workers.map(names.agent).join(', ')
      : 'no worker in fleet';
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
  const needsYou = taskNeedsYou(task);
  const finished = state === 'done' || state === 'cancelled';
  const priority = String(task.priority || 'p2').toLowerCase();
  // Priority only earns a badge while the work is open and urgent.
  const showPriority = !isGate && !finished && (priority === 'p0' || priority === 'p1');
  const rail = needsYou ? 'bg-accent' : STATE_RAIL[state];
  const holderName = people.holder ? names.instance(people.holder) || workerLabel : workerLabel;
  const editItems: { field: TaskEditField; label: string }[] = lock.locked
    ? []
    : [
        { field: 'assignee', label: 'Change assignee' },
        { field: 'reviewers', label: 'Change reviewers' },
        { field: 'deps', label: 'Change what it waits for' },
      ];
  const hasMenu = more.length > 0 || editItems.length > 0;
  // Decisions that need words live in the open details; don't repeat them above.
  const shownPrimary = expanded ? primary.filter((id) => !DECISION_IN_DETAILS.has(id)) : primary;

  return (
    <article
      ref={cardRef}
      data-debug-id={`task-card-${task.task_id}`}
      data-id={task.task_id}
      data-needs-you={needsYou ? 'true' : undefined}
      aria-label={task.title}
      className={[
        'group relative rounded-lg border text-xs transition-[background-color,border-color,box-shadow] duration-150 motion-reduce:transition-none',
        needsYou
          ? 'border-accent bg-accent-soft shadow-glow-accent'
          : expanded
            ? 'border-strong bg-surface-raised shadow-panel'
            : 'border-subtle bg-surface hover:border-strong hover:bg-surface-raised',
        className,
      ].join(' ')}
    >
      {/* State rail: the card's status at a glance, before reading anything. */}
      <span aria-hidden="true" className={`absolute inset-y-0 left-0 w-[3px] rounded-l-lg ${rail}`} />

      <div className="space-y-2 py-3 pl-5 pr-3">
        {/* Row 1: title (wraps to two lines) + state + menu */}
        <div className="flex min-w-0 items-start gap-2">
          <button
            type="button"
            data-debug-id={`task-card-toggle-${task.task_id}`}
            aria-expanded={expanded}
            onClick={toggle}
            className="flex min-w-0 flex-1 items-start gap-1.5 rounded-sm text-left focus-visible:outline-none focus-visible:shadow-focus"
          >
            <Icon
              name="chevron-right"
              size="sm"
              className={`mt-0.5 shrink-0 text-muted transition-transform duration-150 motion-reduce:transition-none ${expanded ? 'rotate-90' : ''}`}
            />
            <span className={`line-clamp-2 text-title ${finished ? 'text-muted' : 'text-primary'}`}>{task.title}</span>
          </button>
          <div className="-my-1 flex shrink-0 items-center">
            {hasMenu && (
              <Menu
                label={`More actions for ${task.title}`}
                align="end"
                trigger={
                  <IconButton icon="more-horizontal" label="More actions" variant="ghost" size="sm" data-debug-id={`task-card-more-${task.task_id}`} />
                }
              >
                {editItems.map((it) => (
                  <Menu.Item key={it.field} onClick={() => setEditing(it.field)}>
                    {it.label}
                  </Menu.Item>
                ))}
                {more.map((id) => (
                  <Menu.Item key={id} danger={id === 'cancel'} onClick={() => void runAction(id)}>
                    {TASK_ACTION_LABELS[id]}
                  </Menu.Item>
                ))}
              </Menu>
            )}
          </div>
        </div>

        {/* Row 2: state first, then what is happening, in one sentence. The
            pills sit here rather than beside the title so the title keeps the
            full width on narrow screens. */}
        <div className="flex flex-wrap items-center gap-1.5">
          <StatusPill tone={TASK_STATE_TONE[state]}>{TASK_STATE_LABELS[state]}</StatusPill>
          {showPriority && <Badge tone={uiToneForPriority(task.priority)}>{priority.toUpperCase()}</Badge>}
          {isDraft(task) && <Badge tone="neutral">Draft</Badge>}
          {isGate && <Badge tone="info">Gate</Badge>}
        </div>
        <Text as="p" role="body-sm" tone="muted" data-debug-id={`task-card-status-${task.task_id}`}>
          <span className="text-primary">
            {holderLease ? (
              <>
                <HolderName instanceId={holderLease.instanceId} names={names} /> {inProgressSentenceRest(holderLease.leftMins)}
              </>
            ) : (
              sentence
            )}
          </span>
          {detail ? ` · ${detail}` : ''}
        </Text>

        {/* Row 3: who works it, who reviews it, what it waits for. Finished
            cards keep only the sentence; the rest is in the details. */}
        {!isGate && (!finished || expanded) && (
          <div data-debug-id={`task-card-people-${task.task_id}`} className="flex flex-wrap items-center gap-x-4 gap-y-1.5 text-caption text-muted">
            {people.holder ? (
              <PersonChip name={holderName} title="Working on it">
                <HolderName instanceId={people.holder} names={names} className="text-primary" />
              </PersonChip>
            ) : (
              <PersonChip name={workerLabel} tone={people.assignee || people.workers.length ? 'default' : 'missing'} title="Assignee" />
            )}
            {(people.reviewers.length > 0 || people.userApproval) && (
              <span className="inline-flex items-center gap-1.5">
                <Icon name="eye" size={12} className="text-faint" title="Reviewers" />
                {people.reviewers.map((r) => (
                  <PersonChip key={r} name={names.agent(r)} title="Reviewer" />
                ))}
                {people.userApproval && <PersonChip name="You" tone="you" title="Needs your approval" />}
              </span>
            )}
            {deps.length > 0 && (
              <span className="inline-flex min-w-0 flex-wrap items-center gap-1">
                <Icon name="git-branch" size={12} className="text-faint" title="Waits for" />
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
            {placement.bridge ? (
              <span
                className="inline-flex items-center gap-1"
                title={`Bridge ${placement.bridgeSource}${placement.model ? `; model ${placement.model} (${placement.modelSource})` : ''}`}
              >
                <Icon name="device" size={12} className="text-faint" />
                {placement.bridge}
              </span>
            ) : null}
            {badges.map((b, i) => (
              <Badge key={i} tone={uiToneForBadge(b.tone)} title={b.title}>
                {b.label}
              </Badge>
            ))}
          </div>
        )}

        {/* Row 4: the action that matters now (the rest is in the More menu) */}
        {(shownPrimary.length > 0 || actions.error) && (
          <div className="flex flex-wrap items-center gap-2 pt-1">
            {shownPrimary.map((id) => (
              <Button
                key={id}
                size="sm"
                variant={id === 'request_changes' || !needsYou ? 'secondary' : 'primary'}
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

      <TaskEditModal
        chainId={chainId}
        task={task}
        field={editing}
        onClose={() => setEditing(null)}
        tasks={chainTasks}
        chainFleets={chainFleets}
        names={names}
      />

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
