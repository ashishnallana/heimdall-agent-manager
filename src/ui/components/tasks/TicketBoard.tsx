import React, { useMemo, useState } from 'react';
import { useSelector } from 'react-redux';
import { Alert, Button, ButtonLink, EmptyState, Icon, IconButton, Menu, Tab, Tabs, TabsList, Text } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import type { TaskChainFleet } from '../../api/endpoints/taskChains';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { isVaultArmored } from '../../utils/vaultContent';
import { buildRouteHash } from '../../utils/appLocation';
import { VaultText } from '../vault/VaultText';
import { BoardTicketCard, type TicketOpenFocus } from './BoardTicketCard';
import { TicketFleetTable } from './TicketFleetTable';
import { useTicketClock } from './useTicketClock';
import type { TaskEditField } from './TaskEditModal';
import { EMPTY_TASK_NAMES, type TaskNames } from './taskNames';
import {
  attemptInfo,
  boardFilterCounts,
  formatAgo,
  groupTickets,
  needsYouHeadline,
  progressCaption,
  progressCounts,
  progressSegments,
  type BoardFilter,
  type FinishedOrder,
  type FleetMachine,
} from './ticketModel';

/** Finished rows shown before "Show N more" (REQ-B6). */
export const FINISHED_PREVIEW = 6;

export interface TicketBoardProps {
  chainId: string;
  /** The chain's tickets (workflow stages excluded). */
  tasks: TaskWire[];
  /** Includes current workflow-run tasks, for truthful progress and attention. */
  summaryTasks?: TaskWire[];
  keys: Map<string, string>;
  names?: TaskNames;
  machines: FleetMachine[];
  chainFleets?: TaskChainFleet[];
  chainKind?: string;
  /** Replacement links found so far (gap G2): old task id → new task id. */
  replacedBy?: Record<string, string>;
  isMobile?: boolean;
  onOpenTicket: (taskId: string, focus?: TicketOpenFocus) => void;
  onOpenAgent: (instanceId: string, name: string) => void;
  onEditTicket: (taskId: string, field: TaskEditField) => void;
  onNewTask?: () => void;
  onOpenFleetDrawer?: () => void;
  onOpenReviewRoles?: () => void;
  /** Shown in the board menu while the chain is a draft. */
  onPublishChain?: () => void;
  publishingChain?: boolean;
  publishError?: string;
  /** Workflow runs of the same chain, rendered before the tickets. */
  workSlot?: React.ReactNode;
  hasWorkflowRuns?: boolean;
}

const SEGMENT_CLASS: Record<string, string> = {
  done: 'bg-success',
  in_progress: 'bg-info',
  ready: 'bg-faint',
  cancelled: 'bg-strong',
};

const SEGMENT_LABEL: Record<string, string> = {
  done: 'done',
  in_progress: 'in progress or review',
  ready: 'ready or waiting',
  cancelled: 'cancelled',
};

/** Vault-locked notice shared by the board and the ticket tab (edge states). */
export function VaultLockedBanner({ debugId, editing = false }: { debugId: string; editing?: boolean }) {
  return (
    <div data-debug-id={debugId}>
      <Alert tone="warning" title="Your vault is locked">
        <span className="flex flex-wrap items-center gap-2">
          <span>{editing ? 'Titles and requirements stay masked. Unlock your vault to edit.' : 'Ticket titles stay masked until it is unlocked.'}</span>
          <ButtonLink size="sm" variant="secondary" href={buildRouteHash('/settings/devices', '')} data-debug-id={`${debugId}-unlock`}>
            Unlock vault
          </ButtonLink>
        </span>
      </Alert>
    </div>
  );
}

/**
 * The Tickets board in the aux pane (ticket board spec, REQ-B1..B7): a summary
 * header that leads with what needs you, the progress bar and filter, the fleet
 * table, then the ticket groups. Every value comes from cached queries patched by
 * WebSocket events; the only timer is the local clock for countdowns.
 */
export const TicketBoard: React.FC<TicketBoardProps> = ({
  chainId,
  tasks,
  summaryTasks = tasks,
  keys,
  names = EMPTY_TASK_NAMES,
  machines,
  chainKind = '',
  replacedBy = {},
  isMobile = false,
  onOpenTicket,
  onOpenAgent,
  onEditTicket,
  onNewTask,
  onOpenFleetDrawer,
  onOpenReviewRoles,
  onPublishChain,
  publishingChain = false,
  publishError,
  workSlot,
  hasWorkflowRuns = false,
}) => {
  // Kept per chain: the board is keyed by chain, so this state is too.
  const [filter, setFilter] = useState<BoardFilter>('open');
  const [order, setOrder] = useState<FinishedOrder>('newest');
  const [showAllFinished, setShowAllFinished] = useState(false);
  const now = useTicketClock();
  const vaultUnlocked = useSelector(selectIsVaultUnlocked);

  const counts = useMemo(() => boardFilterCounts(tasks), [tasks]);
  const groups = useMemo(() => groupTickets(tasks, filter, order), [tasks, filter, order]);
  const progress = useMemo(() => progressCounts(summaryTasks), [summaryTasks]);
  const segments = progressSegments(progress);
  const caption = progressCaption(progress);
  const headline = useMemo(() => needsYouHeadline(summaryTasks, keys), [summaryTasks, keys]);
  const masked = !vaultUnlocked && tasks.some((t) => isVaultArmored(t.title));

  const menuItems = [
    ...(onOpenReviewRoles ? [{ label: 'Review roles', onClick: onOpenReviewRoles, debugId: 'task-board-review-roles-btn' }] : []),
    ...(onOpenFleetDrawer ? [{ label: 'Manage fleet', onClick: onOpenFleetDrawer, debugId: 'task-board-fleet-btn' }] : []),
    ...(onPublishChain ? [{ label: 'Publish chain', onClick: onPublishChain, debugId: 'task-board-publish-chain-btn' }] : []),
  ];

  const newTicket = onNewTask ? (
    <Button size={isMobile ? 'md' : 'sm'} variant="primary" leading={<Icon name="plus" size="sm" />} onClick={onNewTask} data-debug-id="task-board-new-task-btn">
      New ticket
    </Button>
  ) : null;

  return (
    <div data-debug-id="ticket-board-view" className="flex flex-col gap-5 p-4 text-left sm:p-5">
      <header className="flex flex-col gap-3" data-debug-id="ticket-board-header">
        <div className="flex min-w-0 items-start justify-between gap-3">
          <div className="min-w-0">
            <Text as="h2" role="heading" className="font-[family-name:var(--font-display)] text-primary" data-debug-id="ticket-board-headline">
              {headline.title}
            </Text>
            {headline.subtitle && (
              <Text as="p" role="body-sm" tone="muted" data-debug-id="ticket-board-subline">
                {headline.subtitle}
              </Text>
            )}
          </div>
          <div className="flex shrink-0 items-center gap-1">
            {menuItems.length > 0 && (
              <Menu
                label="Board actions"
                align="end"
                trigger={<IconButton icon="more-horizontal" label="Board actions" variant="ghost" size={isMobile ? 'md' : 'sm'} data-debug-id="ticket-board-menu-btn" />}
              >
                {menuItems.map((it) => (
                  <Menu.Item key={it.debugId} data-debug-id={it.debugId} onClick={it.onClick} disabled={it.debugId === 'task-board-publish-chain-btn' && publishingChain}>
                    {it.label}
                  </Menu.Item>
                ))}
              </Menu>
            )}
            {!isMobile && newTicket}
          </div>
        </div>
        {isMobile && newTicket && <div>{newTicket}</div>}
        {publishError && (
          <Text role="caption" tone="danger" className="break-words">
            {publishError}
          </Text>
        )}

        {progress.total > 0 && (
          <div className="flex flex-col gap-2">
            <div
              role="img"
              aria-label={segments.map((s) => `${s.count} ${SEGMENT_LABEL[s.key]}`).join(', ')}
              data-debug-id="ticket-board-progress"
              className="flex h-1.5 w-full gap-0.5 overflow-hidden rounded-pill bg-neutral-soft"
            >
              {segments
                .filter((s) => s.count > 0)
                .map((s) => (
                  <span key={s.key} className={`h-full ${SEGMENT_CLASS[s.key]}`} style={{ width: `${s.percent}%` }} />
                ))}
            </div>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <Text as="p" role="caption" tone="muted" data-debug-id="ticket-board-progress-caption">
                <span className="font-semibold text-primary">{caption.lead}</span>
                {caption.rest ? ` · ${caption.rest}` : ''}
              </Text>
              <Tabs value={filter} onChange={(v) => setFilter(v as BoardFilter)} variant="segmented">
                <TabsList label="Filter tickets">
                  {(['open', 'finished', 'all'] as BoardFilter[]).map((f) => (
                    <Tab key={f} value={f} data-debug-id={`ticket-board-filter-${f}`} className={isMobile ? 'min-h-11' : ''}>
                      {f === 'open' ? 'Open' : f === 'finished' ? 'Finished' : 'All'} <span className="tabular-nums text-faint">{counts[f]}</span>
                    </Tab>
                  ))}
                </TabsList>
              </Tabs>
            </div>
          </div>
        )}
      </header>

      {masked && <VaultLockedBanner debugId="ticket-board-vault-locked" />}

      <TicketFleetTable machines={machines} now={now} isMobile={isMobile} onManageFleet={onOpenFleetDrawer} onOpenTicket={(id) => onOpenTicket(id)} onOpenAgent={onOpenAgent} />

      {workSlot}
      {hasWorkflowRuns && tasks.length > 0 && <Text role="overline" tone="faint">Tickets {tasks.length}</Text>}

      {tasks.length === 0 ? (
        hasWorkflowRuns ? null : (
          <EmptyState
            icon="tasks"
            title="No tickets yet"
            description="Add a ticket with a goal and acceptance criteria."
            action={
              onNewTask ? (
                <Button size="sm" variant="primary" data-debug-id="task-board-empty-new-task-btn" onClick={onNewTask}>
                  New ticket
                </Button>
              ) : undefined
            }
          />
        )
      ) : groups.length === 0 ? (
        <Text role="caption" tone="faint" data-debug-id="ticket-board-filter-empty">
          {filter === 'open' ? 'No open tickets. Everything here is finished.' : 'Nothing finished yet.'}
        </Text>
      ) : (
        <div className="flex flex-col gap-6">
          {groups.map((group) => {
            const isFinished = group.key === 'finished';
            const visible = isFinished && !showAllFinished ? group.tasks.slice(0, FINISHED_PREVIEW) : group.tasks;
            const hidden = group.tasks.length - visible.length;
            return (
              <section key={group.key} aria-label={group.label} data-debug-id={`task-board-section-${group.key}`} className="flex flex-col gap-2">
                <div className="flex items-center justify-between gap-2">
                  <Text as="h3" role="overline" tone={group.key === 'needs_you' ? 'warning' : 'faint'}>
                    {group.label} <span className="tabular-nums">{group.tasks.length}</span>
                  </Text>
                  {isFinished && (
                    <Button
                      size="sm"
                      variant="ghost"
                      leading={<Icon name={order === 'newest' ? 'arrow-down' : 'arrow-up'} size="sm" />}
                      onClick={() => setOrder((o) => (o === 'newest' ? 'oldest' : 'newest'))}
                      data-debug-id="ticket-board-finished-order"
                    >
                      {order === 'newest' ? 'Newest first' : 'Oldest first'}
                    </Button>
                  )}
                </div>
                {isFinished ? (
                  <div className="overflow-hidden rounded-lg border border-subtle bg-surface">
                    <ul className="divide-y divide-subtle">
                      {visible.map((t) => (
                        <li key={t.task_id}>
                          <FinishedRow task={t} keyLabel={keys.get(t.task_id) || ''} now={now} isMobile={isMobile} onOpen={() => onOpenTicket(t.task_id)} />
                        </li>
                      ))}
                    </ul>
                    {hidden > 0 && (
                      <button
                        type="button"
                        onClick={() => setShowAllFinished(true)}
                        data-debug-id="task-board-finished-toggle"
                        className="min-h-11 w-full border-t border-subtle px-3 py-2 text-center text-body-sm text-muted hover:bg-surface-raised hover:text-primary focus-visible:outline-none focus-visible:shadow-focus"
                      >
                        Show {hidden} more
                      </button>
                    )}
                  </div>
                ) : (
                  group.tasks.map((t) => (
                    <BoardTicketCard
                      key={t.task_id}
                      task={t}
                      chainId={chainId}
                      tasks={tasks}
                      keys={keys}
                      names={names}
                      now={now}
                      chainKind={chainKind}
                      replacedByTaskId={replacedBy[t.task_id] || null}
                      onOpen={onOpenTicket}
                      onEdit={onEditTicket}
                    />
                  ))
                )}
              </section>
            );
          })}
        </div>
      )}
    </div>
  );
};

/** A finished ticket as one line: check, title, attempts, finished time (REQ-B6). */
function FinishedRow({ task, keyLabel, now, isMobile, onOpen }: { task: TaskWire; keyLabel: string; now: number; isMobile: boolean; onOpen: () => void }) {
  const cancelled = String(task.state || '').toLowerCase().startsWith('cancel');
  const attempts = attemptInfo(task).no;
  return (
    <button
      type="button"
      data-debug-id={`ticket-board-finished-row-${task.task_id}`}
      aria-label={`${keyLabel} ${cancelled ? 'cancelled' : 'done'}`}
      onClick={onOpen}
      className="flex min-h-11 w-full min-w-0 items-center gap-3 px-3 py-2 text-left hover:bg-surface-raised focus-visible:outline-none focus-visible:shadow-focus"
    >
      <Icon name={cancelled ? 'close' : 'check'} size={14} className={`shrink-0 ${cancelled ? 'text-faint' : 'text-success'}`} />
      <VaultText value={task.title} fallback="Untitled ticket" className="min-w-0 flex-1 truncate text-body-sm text-muted" />
      {!isMobile && (
        <span className="shrink-0 text-caption tabular-nums text-faint">
          {attempts} attempt{attempts === 1 ? '' : 's'}
        </span>
      )}
      <span className="w-16 shrink-0 text-right text-caption tabular-nums text-faint">{formatAgo(task.completed_at || task.updated_at || task.created_at, now)}</span>
    </button>
  );
}

export default TicketBoard;
