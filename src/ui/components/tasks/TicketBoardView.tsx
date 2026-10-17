import React, { useMemo, useState } from 'react';
import { Button, EmptyState, Text } from '@ui';
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
  names = EMPTY_TASK_NAMES,
  className = '',
}) => {
  const [needsYouOnly, setNeedsYouOnly] = useState(false);
  const [showFinished, setShowFinished] = useState(false);

  const sorted = useMemo(() => sortTasksForBoard(tasks), [tasks]);
  const visible = needsYouOnly ? sorted.filter(taskNeedsYou) : sorted;
  const open = visible.filter((t) => !isFinished(t) || t.task_id === expandedTaskId);
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
    <div data-debug-id="ticket-board-view" className={`flex flex-col gap-3 p-4 text-left ${className}`}>
      <TaskSummaryBar
        tasks={tasks}
        chainFleets={chainFleets}
        kind="ticket"
        summaryText={summaryText}
        needsYouActive={needsYouOnly}
        onToggleNeedsYou={() => setNeedsYouOnly((v) => !v)}
        actions={
          <>
            {onPublishChain && (
              <Button size="sm" variant="primary" loading={publishingChain} onClick={onPublishChain} data-debug-id="task-board-publish-chain-btn">
                Publish chain
              </Button>
            )}
            {onOpenFleetDrawer && (
              <Button size="sm" variant="secondary" onClick={onOpenFleetDrawer} data-debug-id="task-board-fleet-btn">
                Fleet
              </Button>
            )}
            {onOpenReviewRoles && (
              <Button size="sm" variant="secondary" onClick={onOpenReviewRoles} data-debug-id="task-board-review-roles-btn">
                Review roles
              </Button>
            )}
            {onNewTask && (
              <Button size="sm" variant="primary" onClick={onNewTask} data-debug-id="task-board-new-task-btn">
                New task
              </Button>
            )}
          </>
        }
      />
      {publishError && (
        <Text role="caption" tone="danger" className="break-words">
          {publishError}
        </Text>
      )}

      {tasks.length === 0 ? (
        <EmptyState
          icon="tasks"
          title="No tasks yet"
          description="Add a task with a goal, acceptance checks and a verify command."
          action={
            onNewTask ? (
              <Button size="sm" variant="primary" onClick={onNewTask}>
                New task
              </Button>
            ) : undefined
          }
        />
      ) : (
        <div className="flex flex-col gap-2">
          {open.map(renderCard)}
          {open.length === 0 && finished.length === 0 && (
            <Text role="caption" tone="faint">
              Nothing here.
            </Text>
          )}
          {finished.length > 0 && (
            <>
              <div>
                <Button size="sm" variant="ghost" onClick={() => setShowFinished((v) => !v)} data-debug-id="task-board-finished-toggle">
                  {showFinished ? 'Hide finished' : `Show ${finished.length} finished`}
                </Button>
              </div>
              {showFinished && finished.map(renderCard)}
            </>
          )}
        </div>
      )}
    </div>
  );
};

export default TicketBoardView;
