import React from 'react';
import { useDispatch } from 'react-redux';
import { Badge, Button, Icon, IconButton, Menu, StatusPill, Text } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { TASK_STATE_LABELS, TASK_STATE_TONE, holdSummary, normalizeTaskState, reviewLeaseHolders, taskHold } from './taskV2Types';
import { TASK_ACTION_LABELS, editLock, getTaskActions, recheckToast, type TaskActionId } from './taskActions';
import { showToast } from '../../store/toastSlice';
import { useTaskActions } from './useTaskActions';
import { VaultText, useDecryptedText } from '../vault/VaultText';
import { TicketAgentAvatar } from './TicketAgentAvatar';
import { usePrefersReducedMotion } from './useTicketClock';
import { HoldReasonDialog } from './HoldReasonDialog';
import type { TaskEditField } from './TaskEditModal';
import type { TaskNames } from './taskNames';
import {
  ASK_LABELS,
  attemptInfo,
  formatAgo,
  formatDuration,
  isRework,
  keyFor,
  leaseClock,
  needsYouContext,
  requirementChangeLine,
  ticketAsk,
  upNextContext,
} from './ticketModel';

/** Decisions that need words or context: the card opens the ticket tab at its decision block. */
const OPENS_DECISION = new Set<TaskActionId>(['approve', 'request_changes', 'answer']);

export type TicketOpenFocus = 'decision' | 'requirement_changes' | null;

export interface BoardTicketCardProps {
  task: TaskWire;
  chainId: string;
  /** Every ticket of the chain (dependency context). */
  tasks: readonly TaskWire[];
  keys: Map<string, string>;
  names: TaskNames;
  now: number;
  /** Key of the ticket that replaced this one (gap G2), when known. */
  replacedByTaskId?: string | null;
  chainKind?: string;
  onOpen: (taskId: string, focus?: TicketOpenFocus) => void;
  onEdit: (taskId: string, field: TaskEditField) => void;
}

/**
 * One open ticket on the board (REQ-B4, B5, B7): key, title, state pill, who is
 * on it, lease time left and the attempt once. State is a pill with a word,
 * never a coloured rail, outline or glow. The whole card opens the ticket tab;
 * its controls do their own thing.
 */
export const BoardTicketCard = React.memo(function BoardTicketCard({
  task,
  chainId,
  tasks,
  keys,
  names,
  now,
  replacedByTaskId,
  chainKind = '',
  onOpen,
  onEdit,
}: BoardTicketCardProps) {
  const id = task.task_id;
  const key = keyFor(keys, id);
  const state = normalizeTaskState(task.state);
  const ask = ticketAsk(task);
  const hold = taskHold(task);
  const lease = leaseClock(task, now);
  const attempt = attemptInfo(task);
  // The accessible name never carries vault ciphertext.
  const { text: title } = useDecryptedText(task.title);
  const reqLine = requirementChangeLine(task, now);
  const rework = isRework(task);
  const actions = useTaskActions(chainId, id, task.title, task);
  const [holdOpen, setHoldOpen] = React.useState(false);
  const dispatch = useDispatch();
  const { primary, more } = getTaskActions(task);
  const lock = editLock(task, chainKind);
  const workflowOwned = chainKind === 'workflow' || Boolean(task.stage_key) || Boolean(task.workflow_run_id);
  const isGate = task.kind === 'gate';

  const editItems: { field: TaskEditField; label: string }[] = [];
  if (!workflowOwned && !isGate && state !== 'done' && state !== 'cancelled') editItems.push({ field: 'requirements', label: 'Change requirements' });
  if (!lock.locked) {
    editItems.push({ field: 'assignee', label: 'Change assignee' }, { field: 'reviewers', label: 'Change reviewers' }, { field: 'deps', label: 'Change what it waits for' });
  }

  const run = async (action: TaskActionId) => {
    if (OPENS_DECISION.has(action)) return onOpen(id, 'decision');
    switch (action) {
      case 'publish':
        return void actions.publish();
      case 'reopen':
        return void actions.reopen();
      case 'release':
        return void actions.release();
      case 'recheck': {
        const result = await actions.recheck();
        if (result) dispatch(showToast({ ...recheckToast(result), autoDismissMs: 6000 }));
        return;
      }
      case 'hold':
        return setHoldOpen(true);
      case 'cancel':
        if (window.confirm(`Cancel ${key}?`)) await actions.cancel();
        return;
      case 'copy_id':
        try {
          await navigator.clipboard?.writeText(id);
        } catch {
          /* clipboard unavailable */
        }
        return;
    }
  };

  // A requirement change arriving over the socket highlights the card for 3 s
  // (not under reduced motion).
  const reducedMotion = usePrefersReducedMotion();
  const revision = Number(task.requirements?.revision) || 0;
  const shownRevision = React.useRef(revision);
  const [highlight, setHighlight] = React.useState(false);
  React.useEffect(() => {
    const changed = revision > shownRevision.current;
    shownRevision.current = revision;
    if (!changed || reducedMotion) return;
    setHighlight(true);
    const t = setTimeout(() => setHighlight(false), 3000);
    return () => clearTimeout(t);
  }, [revision, reducedMotion]);

  // Failures show as a toast on the board (edge states: Action fails).
  React.useEffect(() => {
    if (actions.error) dispatch(showToast({ kind: 'error', title: `${key}: action failed`, message: actions.error, autoDismissMs: 8000 }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [actions.error]);

  const holderName = lease ? names.instance(lease.holderInstanceId) || names.agent(String(task.brief?.assignee || '')) : '';
  const reviewing = reviewLeaseHolders(task, now);
  const stop = (e: React.SyntheticEvent) => e.stopPropagation();
  const replacedKey = replacedByTaskId ? keyFor(keys, replacedByTaskId) : '';

  return (
    <article
      data-debug-id={`task-card-${id}`}
      data-id={id}
      data-needs-you={ask ? 'true' : undefined}
      data-highlight={highlight || undefined}
      aria-label={`${key} ${title}`}
      onClick={() => onOpen(id)}
      className={`group cursor-pointer rounded-lg border p-3 text-left transition-colors duration-slow hover:border-strong motion-reduce:transition-none sm:p-4 ${highlight ? 'border-info bg-info-soft' : 'border-subtle bg-surface hover:bg-surface-raised'}`}
    >
      <div className="flex min-w-0 items-start gap-2">
        <span className="mt-px shrink-0 font-mono text-caption text-faint">{key}</span>
        <button
          type="button"
          data-debug-id={`task-card-toggle-${id}`}
          onClick={(e) => {
            stop(e);
            onOpen(id);
          }}
          className="min-w-0 flex-1 rounded-sm text-left focus-visible:outline-none focus-visible:shadow-focus"
        >
          <VaultText value={task.title} fallback="Untitled ticket" className="line-clamp-2 text-title text-primary" />
        </button>
        <span className="flex shrink-0 items-center gap-1">
          {ask ? (
            <Badge tone="warning" data-debug-id={`task-card-ask-${id}`}>{ASK_LABELS[ask]}</Badge>
          ) : (
            <StatusPill tone={hold ? 'warning' : TASK_STATE_TONE[state]}>{hold ? 'Held' : TASK_STATE_LABELS[state]}</StatusPill>
          )}
          {(more.length > 0 || editItems.length > 0) && (
            <span onClick={stop}>
              <Menu
                label={`More actions for ${key}`}
                align="end"
                trigger={<IconButton icon="more-horizontal" label="More actions" variant="ghost" size="sm" data-debug-id={`task-card-more-${id}`} />}
              >
                {editItems.map((it) => (
                  <Menu.Item key={it.field} data-debug-id={`task-card-edit-${it.field}-${id}`} onClick={() => onEdit(id, it.field)}>
                    {it.label}
                  </Menu.Item>
                ))}
                {more.map((action) => (
                  <Menu.Item key={action} danger={action === 'cancel'} data-debug-id={`task-menu-${action}-${id}`} onClick={() => void run(action)}>
                    {TASK_ACTION_LABELS[action]}
                  </Menu.Item>
                ))}
              </Menu>
            </span>
          )}
        </span>
      </div>

      <div className="mt-2 space-y-1.5 pl-0 text-body-sm sm:pl-9">
        {ask ? (
          <Text as="p" role="body-sm" tone={ask === 'agent_down' ? 'danger' : 'muted'} data-debug-id={`task-card-status-${id}`}>
            {needsYouContext(task, names)}
          </Text>
        ) : lease ? (
          <div data-debug-id={`task-card-status-${id}`} className="flex flex-wrap items-center gap-x-3 gap-y-1">
            <span className="inline-flex min-w-0 items-center gap-2">
              <TicketAgentAvatar name={holderName || 'Agent'} state="working" />
              <span className="truncate text-primary">{holderName || 'An agent'} is working</span>
            </span>
            <span className="inline-flex items-center gap-2 text-muted">
              <span aria-hidden="true" className="h-1 w-12 overflow-hidden rounded-pill bg-neutral-soft">
                <span className="block h-full rounded-pill bg-info" style={{ width: `${Math.round(lease.fraction * 100)}%` }} />
              </span>
              <span className="tabular-nums">{formatDuration(lease.leftMs)} left</span>
            </span>
            {attempt.exhausted ? <Badge tone="warning">{attempt.label} · budget spent</Badge> : <span className="text-muted">{attempt.label}</span>}
          </div>
        ) : state === 'in_review' ? (
          <Text as="p" role="body-sm" tone="muted" data-debug-id={`task-card-status-${id}`}>
            {reviewing.length
              ? reviewing.map((h) => `${names.instance(h.instanceId) || 'A reviewer'} is reviewing, ${h.leftMins}m left`).join(' · ')
              : 'Waiting for a reviewer'}
            {attempt.no > 1 || attempt.exhausted ? ` · ${attempt.label}` : ''}
          </Text>
        ) : hold ? (
          <Text as="p" role="body-sm" tone="warning" data-debug-id={`task-card-hold-${id}`}>
            {holdSummary(hold, now, names)}
          </Text>
        ) : (
          <Text as="p" role="body-sm" tone="muted" data-debug-id={`task-card-status-${id}`} className="flex items-center gap-1.5">
            {(task.depends_on || []).length > 0 && <Icon name="git-branch" size={12} className="text-faint" />}
            {upNextContext(task, keys, tasks, names)}
          </Text>
        )}

        {reqLine && (
          <button
            type="button"
            data-debug-id={`task-card-requirements-line-${id}`}
            onClick={(e) => {
              stop(e);
              onOpen(id, 'requirement_changes');
            }}
            className="inline-flex flex-wrap items-center gap-1.5 rounded-sm text-left text-caption text-info hover:underline focus-visible:outline-none focus-visible:shadow-focus"
          >
            <Icon name="clock" size={12} />
            <span>Requirements changed{reqLine.changedAtMs !== null ? ` ${formatAgo(reqLine.changedAtMs, now)}` : ''}</span>
            <Badge tone="neutral">Rev {reqLine.revision}</Badge>
            {reqLine.pendingReaders.length > 0 && (
              <span>{reqLine.pendingReaders.map((r) => names.instance(r) || 'the worker').join(', ')} reads it next</span>
            )}
          </button>
        )}
        {(rework || replacedKey) && (
          <div className="flex flex-wrap items-center gap-1.5">
            {rework && <Badge tone="warning" data-debug-id={`task-card-rework-${id}`}>Rework</Badge>}
            {replacedKey && replacedByTaskId && (
              <button
                type="button"
                data-debug-id={`task-card-replaced-by-${id}`}
                onClick={(e) => {
                  stop(e);
                  onOpen(replacedByTaskId);
                }}
                className="rounded-sm text-caption text-accent hover:underline focus-visible:outline-none focus-visible:shadow-focus"
              >
                Replaced by {replacedKey}
              </button>
            )}
          </div>
        )}

        {primary.length > 0 && (
          <div className="flex flex-wrap items-center gap-2 pt-1" onClick={stop}>
            {primary.map((action) => (
              <Button
                key={action}
                size="sm"
                variant={action === 'approve' || action === 'publish' ? 'primary' : 'secondary'}
                disabled={actions.busy || (action === 'approve' && rework)}
                data-debug-id={`task-action-${action}-${id}`}
                onClick={() => void run(action)}
              >
                {TASK_ACTION_LABELS[action]}
              </Button>
            ))}
          </div>
        )}
      </div>
      <span onClick={stop}>
        <HoldReasonDialog ticketKey={key} open={holdOpen} busy={actions.busy} onHold={actions.hold} onClose={() => setHoldOpen(false)} />
      </span>
    </article>
  );
});

export default BoardTicketCard;
