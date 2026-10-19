import React, { useMemo, useState } from 'react';
import { Button, EmptyState, Icon, Text } from '@ui';
import { TaskWire } from '../../api/taskWire';
import { TaskSummaryBar } from './TaskSummaryBar';
import { TaskCard } from './TaskCard';
import { TASK_STATES_ORDER, normalizeTaskState } from './taskV2Types';
import { taskNeedsYou } from './taskActions';
import { TaskChainFleet } from '../../api/endpoints/taskChains';
import { EMPTY_TASK_NAMES, type TaskNames } from './taskNames';

export interface TicketBoardViewProps {
  chainId: string;
  tasks: TaskWire[];
  /** Includes current run tasks for truthful chain-wide progress and attention. */
  summaryTasks?: TaskWire[];
  chainFleets?: TaskChainFleet[];
  /** The card expanded inline (plan REQ-UI-8). */
  expandedTaskId?: string | null;
  onToggleTask: (taskId: string) => void;
  /** Opens a task by id (dependency links): expands it and scrolls to it. */
  onSelectTask?: (taskId: string) => void;
  /** The card to scroll into view once mounted; cleared through onScrolled. */
  scrollTaskId?: string | null;
  onScrolled?: () => void;
  onNewTask?: () => void;
  onOpenFleetDrawer?: () => void;
  onOpenReviewRoles?: () => void;
  /** Shown while the chain itself is still a draft (plan REQ-UI-9). */
  onPublishChain?: () => void;
  publishingChain?: boolean;
  publishError?: string;
  summaryText?: string;
  /** Rendered directly under the summary bar (the chain overview mounts its Active servers panel here). */
  summarySlot?: React.ReactNode;
  /** Whole workflow runs in the same chain, rendered vertically before tickets. */
  workSlot?: React.ReactNode;
  hasWorkflowRuns?: boolean;
  names?: TaskNames;
  className?: string;
}

const PRIORITY_RANK: Record<string, number> = { p0: 0, p1: 1, p2: 2 };

export function sortTasksForBoard(tasks: TaskWire[]): TaskWire[] {
  return [...tasks].sort((a, b) => {
    const needs = Number(taskNeedsYou(b)) - Number(taskNeedsYou(a));
    if (needs) return needs;
    const byState = TASK_STATES_ORDER.indexOf(normalizeTaskState(a.state)) - TASK_STATES_ORDER.indexOf(normalizeTaskState(b.state));
    if (byState) return byState;
    return (PRIORITY_RANK[String(a.priority).toLowerCase()] ?? 3) - (PRIORITY_RANK[String(b.priority).toLowerCase()] ?? 3);
  });
}

type BoardSectionKey = 'needs_you' | 'in_progress' | 'in_review' | 'up_next';

const SECTION_LABELS: Record<BoardSectionKey, string> = {
  needs_you: 'Needs you',
  in_progress: 'In progress',
  in_review: 'In review',
  up_next: 'Up next',
};

/** Open tasks in headed groups, in board order; empty groups are dropped. */
export function groupForBoard(sorted: TaskWire[], expandedTaskId?: string | null) {
  const buckets: Record<BoardSectionKey, TaskWire[]> = { needs_you: [], in_progress: [], in_review: [], up_next: [] };
  for (const t of sorted) {
    if (isFinished(t) && t.task_id !== expandedTaskId) continue;
    const s = normalizeTaskState(t.state);
    const key: BoardSectionKey = taskNeedsYou(t) ? 'needs_you' : s === 'in_progress' ? 'in_progress' : s === 'in_review' ? 'in_review' : 'up_next';
    buckets[key].push(t);
  }
  return (Object.keys(buckets) as BoardSectionKey[])
    .filter((k) => buckets[k].length > 0)
    .map((k) => ({ key: k, label: SECTION_LABELS[k], tasks: buckets[k] }));
}

function SectionLabel({ label, count, accent = false }: { label: string; count: number; accent?: boolean }) {
  return (
    <span className="flex items-center gap-2">
      <Text as="span" role="overline" tone={accent ? 'accent' : 'faint'} className="uppercase">
        {label}
      </Text>
      <span className={`text-caption tabular-nums ${accent ? 'text-accent' : 'text-faint'}`}>{count}</span>
    </span>
  );
}

function isFinished(t: TaskWire): boolean {
  const s = normalizeTaskState(t.state);
  return s === 'done' || s === 'cancelled';
}

/**
 * A ticket chain's tasks as one flat list (plan REQ-UI-7; design reference: the
 * Tasks pane on main). Tasks that need you come first; finished ones fold away.
 */
export const TicketBoardView: React.FC<TicketBoardViewProps> = ({
  chainId,
  tasks = [],
  summaryTasks = tasks,
  chainFleets = [],
  expandedTaskId,
  onToggleTask,
  onSelectTask,
  scrollTaskId,
  onScrolled,
  onNewTask,
  onOpenFleetDrawer,
  onOpenReviewRoles,
  onPublishChain,
  publishingChain = false,
  publishError,
  summaryText,
  summarySlot,
  workSlot,
  hasWorkflowRuns = false,
  names = EMPTY_TASK_NAMES,
  className = '',
}) => {
  const [needsYouOnly, setNeedsYouOnly] = useState(false);
  const [showFinished, setShowFinished] = useState(false);

  const sorted = useMemo(() => sortTasksForBoard(tasks), [tasks]);
  // The needs-you filter turns itself off once nothing needs you, so it can
  // never strand the board empty with no way back (audit finding).
  const filtering = !hasWorkflowRuns && needsYouOnly && sorted.some(taskNeedsYou);
  const visible = filtering ? sorted.filter(taskNeedsYou) : sorted;
  const sections = useMemo(() => groupForBoard(visible, expandedTaskId), [visible, expandedTaskId]);
  const finished = visible.filter((t) => isFinished(t) && t.task_id !== expandedTaskId);

  const renderCard = (task: TaskWire) => (
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
      chainKind=''
    />
  );

  return (
    <div data-debug-id="ticket-board-view" className={`flex flex-col gap-5 p-4 text-left sm:p-5 ${className}`}>
      <TaskSummaryBar
        tasks={summaryTasks}
        chainFleets={chainFleets}
        kind="ticket"
        summaryText={summaryText}
        needsYouActive={filtering}
        onToggleNeedsYou={hasWorkflowRuns ? undefined : () => setNeedsYouOnly((v) => !v)}
        menuItems={[
          ...(onOpenFleetDrawer ? [{ label: 'Fleet', onClick: onOpenFleetDrawer, debugId: 'task-board-fleet-btn' }] : []),
          ...(onOpenReviewRoles ? [{ label: 'Review roles', onClick: onOpenReviewRoles, debugId: 'task-board-review-roles-btn' }] : []),
          ...(onPublishChain && onNewTask ? [{ label: 'New task', onClick: onNewTask, debugId: 'task-board-new-task-menu' }] : []),
        ]}
        primaryAction={
          onPublishChain ? (
            <Button size="sm" variant="primary" loading={publishingChain} onClick={onPublishChain} data-debug-id="task-board-publish-chain-btn">
              Publish chain
            </Button>
          ) : onNewTask ? (
            <Button size="sm" variant="primary" leading={<Icon name="plus" size="sm" />} onClick={onNewTask} data-debug-id="task-board-new-task-btn">
              New task
            </Button>
          ) : undefined
        }
      />
      {publishError && (
        <Text role="caption" tone="danger" className="break-words">
          {publishError}
        </Text>
      )}
      {summarySlot}
      {workSlot}
      {hasWorkflowRuns && tasks.length > 0 && <Text role="overline" tone="faint" className="uppercase">Tickets {tasks.length}</Text>}

      {tasks.length === 0 ? hasWorkflowRuns ? null : (
        <EmptyState
          icon="tasks"
          title="No tasks yet"
          description="Add a task with a goal, acceptance checks and a verify command."
          action={
            onNewTask ? (
              <Button size="sm" variant="primary" data-debug-id="task-board-empty-new-task-btn" onClick={onNewTask}>
                New task
              </Button>
            ) : undefined
          }
        />
      ) : (
        <div className="flex flex-col gap-5">
          {sections.map((sec) => (
            <section key={sec.key} aria-label={sec.label} data-debug-id={`task-board-section-${sec.key}`} className="flex flex-col gap-2">
              <SectionLabel label={sec.label} count={sec.tasks.length} accent={sec.key === 'needs_you'} />
              {sec.tasks.map(renderCard)}
            </section>
          ))}
          {sections.length === 0 && finished.length === 0 && (
            <Text role="caption" tone="faint">
              Nothing here.
            </Text>
          )}
          {finished.length > 0 && (
            <section aria-label="Finished" className="flex flex-col gap-2">
              <button
                type="button"
                aria-expanded={showFinished}
                onClick={() => setShowFinished((v) => !v)}
                data-debug-id="task-board-finished-toggle"
                className="flex items-center gap-1.5 self-start rounded-sm text-left focus-visible:outline-none focus-visible:shadow-focus"
              >
                <Icon
                  name="chevron-right"
                  size="sm"
                  className={`text-faint transition-transform duration-150 motion-reduce:transition-none ${showFinished ? 'rotate-90' : ''}`}
                />
                <SectionLabel label="Finished" count={finished.length} />
              </button>
              {showFinished && finished.map(renderCard)}
            </section>
          )}
        </div>
      )}
    </div>
  );
};

export default TicketBoardView;
