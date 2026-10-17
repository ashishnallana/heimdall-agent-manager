import React, { useState, useEffect } from 'react';
import { Icon } from '@ui';
import { TaskWire } from '../../api/taskWire';
import { TaskSummaryBar } from './TaskSummaryBar';
import { TaskCard } from './TaskCard';
import {
  TASK_STATES_ORDER,
  TASK_STATE_COLORS,
  TASK_STATE_LABELS,
  TaskStateV2,
  normalizeTaskState,
} from './taskV2Types';
import { TaskChainFleet } from '../../api/endpoints/taskChains';
import { EMPTY_TASK_NAMES, type TaskNames } from './taskNames';

export interface TicketBoardViewProps {
  chainId: string;
  tasks: TaskWire[];
  chainFleets?: TaskChainFleet[];
  bridges?: any[];
  selectedTaskId?: string | null;
  onSelectTask: (taskId: string) => void;
  onNewTask?: () => void;
  onOpenFleetDrawer?: () => void;
  summaryText?: string;
  names?: TaskNames;
  className?: string;
}

export const TicketBoardView: React.FC<TicketBoardViewProps> = ({
  chainId,
  tasks = [],
  chainFleets = [],
  bridges = [],
  selectedTaskId,
  onSelectTask,
  onNewTask,
  onOpenFleetDrawer,
  summaryText,
  names = EMPTY_TASK_NAMES,
  className = '',
}) => {
  // Collapsible section state
  const [openSections, setOpenSections] = useState<Record<string, boolean>>(() => {
    try {
      const saved = localStorage.getItem(`heimdall.taskv2.sections.${chainId}`);
      if (saved) return JSON.parse(saved);
    } catch {}
    return {
      in_progress: true,
      in_review: true,
      ready: true,
      backlog: true,
      done: true,
      cancelled: false,
    };
  });

  const toggleSection = (stateKey: string) => {
    setOpenSections((prev) => {
      const next = { ...prev, [stateKey]: !prev[stateKey] };
      try {
        localStorage.setItem(`heimdall.taskv2.sections.${chainId}`, JSON.stringify(next));
      } catch {}
      return next;
    });
  };

  const tasksByState: Record<TaskStateV2, TaskWire[]> = {
    in_progress: [],
    in_review: [],
    ready: [],
    backlog: [],
    done: [],
    cancelled: [],
  };

  tasks.forEach((t) => {
    const s = normalizeTaskState(t.state);
    tasksByState[s].push(t);
  });

  return (
    <div
      data-debug-id="ticket-board-view"
      className={`flex flex-col gap-4 text-left p-4 sm:p-6 overflow-y-auto ${className}`}
    >
      {/* Top summary & attention bar */}
      <TaskSummaryBar
        tasks={tasks}
        chainFleets={chainFleets}
        bridges={bridges}
        onSelectTask={onSelectTask}
        kind="ticket"
        summaryText={summaryText}
      />

      {/* Header with New Task button */}
      <div className="flex items-center justify-between pt-2">
        <h2 className="text-xs font-bold uppercase tracking-wider text-muted">
          Task Board ({tasks.length})
        </h2>
        {onNewTask && (
          <button
            type="button"
            data-debug-id="task-board-new-task-btn"
            onClick={onNewTask}
            className="inline-flex items-center gap-1.5 rounded-lg bg-accent px-3 py-1 text-xs font-semibold text-accent-fg hover:opacity-90 transition-opacity"
          >
            <span>+</span>
            <span>New Task</span>
          </button>
        )}
      </div>

      {/* Collapsible sections for the 5 states + cancelled */}
      <div className="flex flex-col gap-3">
        {TASK_STATES_ORDER.filter(
          (s) => s !== 'cancelled' || tasksByState[s].length > 0
        ).map((s) => {
          const list = tasksByState[s];
          const isOpen = openSections[s] !== false;
          const color = TASK_STATE_COLORS[s];

          return (
            <section
              key={s}
              data-debug-id={`state-section-${s}`}
              className="rounded-xl border border-subtle bg-surface/50 overflow-hidden"
            >
              <header
                role="button"
                tabIndex={0}
                onClick={() => toggleSection(s)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    toggleSection(s);
                  }
                }}
                className="flex items-center justify-between px-3.5 py-2.5 bg-surface hover:bg-surface-raised cursor-pointer select-none transition-colors"
              >
                <div className="flex items-center gap-2">
                  <span
                    className="h-2.5 w-2.5 rounded-full shrink-0"
                    style={{ backgroundColor: color }}
                  />
                  <span className="text-xs font-semibold text-primary">
                    {TASK_STATE_LABELS[s]}
                  </span>
                  <span className="rounded bg-neutral-soft px-1.5 py-0.5 font-mono text-[10px] font-medium text-muted">
                    {list.length}
                  </span>
                </div>
                <Icon name={isOpen ? 'chevron-down' : 'chevron-right'} size="sm" className="text-muted" />
              </header>

              {isOpen && (
                <div className="p-3 space-y-2">
                  {list.length === 0 ? (
                    <div className="rounded-lg border border-dashed border-subtle p-3 text-center text-xs text-muted">
                      No tasks in {TASK_STATE_LABELS[s].toLowerCase()}
                    </div>
                  ) : (
                    list.map((task) => (
                      <TaskCard
                        key={task.task_id}
                        task={task}
                        selected={selectedTaskId === task.task_id}
                        onSelect={onSelectTask}
                        chainFleets={chainFleets}
                        names={names}
                      />
                    ))
                  )}
                </div>
              )}
            </section>
          );
        })}
      </div>
    </div>
  );
};

export default TicketBoardView;
