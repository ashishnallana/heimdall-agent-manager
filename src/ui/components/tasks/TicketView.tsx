import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Alert, Badge, Button, EmptyState, Icon, IconButton, Menu, Select, StatusPill, Tab, Tabs, TabsList, Text } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import {
  useFetchChainTaskDetailQuery,
  useFetchCommitDiffQuery,
  useFetchTaskFacetQuery,
  useUpdateTaskPriorityMutation,
} from '../../api/endpoints/tasks';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { showToast } from '../../store/toastSlice';
import { buildRouteHash } from '../../utils/appLocation';
import { decryptEmbeddedVaultTokens } from '../../utils/vaultContent';
import { containsVaultArmored } from '../../utils/vaultCrypto';
import { taskBridgeOptions } from '../../utils/taskBridgePin';
import { DecryptedMarkdown, VaultText } from '../vault';
import {
  TASK_STATE_LABELS,
  TASK_STATE_TONE,
  describeHold,
  getTaskPeople,
  normalizeTaskState,
  reviewLeaseHolders,
  taskChangedFiles,
  taskHold,
} from './taskV2Types';
import {
  TASK_ACTION_LABELS,
  awaitingYourReview,
  blockedOnYou,
  editLock,
  getTaskActions,
  isDraft,
  isSupersededReview,
  recheckToast,
  youApproved,
  type TaskActionId,
} from './taskActions';
import { useTaskActions, type TaskActionsApi } from './useTaskActions';
import { TaskComposer } from './TaskComposer';
import { TaskEditModal, type TaskEditField } from './TaskEditModal';
import { HoldReasonDialog } from './HoldReasonDialog';
import { RequirementsEditorModal, EditedText } from './RequirementsEditorModal';
import { TicketActivity, type ActivityTab } from './TicketActivity';
import { TicketAgentAvatar } from './TicketAgentAvatar';
import { VaultLockedBanner } from './TicketBoard';
import { useChainTickets } from './useChainTickets';
import { useTicketClock, usePrefersReducedMotion } from './useTicketClock';
import { describeEffectivePlacement, taskEffectivePlacement } from './fleetSelection';
import type { TaskNames } from './taskNames';
import {
  FLEET_STATE_LABELS,
  FLEET_STATE_TONE,
  attemptInfo,
  boardOrder,
  dependentsOf,
  diffAcceptance,
  formatAgo,
  formatDuration,
  isFinishedTask,
  isRework,
  keyFor,
  leaseClock,
  parseRequirementsHistory,
  replacementLinks,
  ticketAsk,
  ticketPosition,
  ticketTabTitle,
  type FleetMachine,
  type FleetSlot,
  type FleetSlotState,
} from './ticketModel';

/** Below this width the side column stacks above the main column (REQ-T3). */
export const TICKET_TWO_COLUMN_MIN_PX = 900;

export type TicketFocus = 'decision' | 'requirement_changes' | null | undefined;

export interface TicketViewProps {
  chainId: string;
  taskId: string;
  isMobile?: boolean;
  /** Transient section to reveal once (decision block / requirement changes). */
  focus?: TicketFocus;
  onFocusConsumed?: () => void;
  /** Breadcrumb "Tickets" and Back: focus the board. */
  onShowBoard: () => void;
  /** Linked tickets, Replaces / Replaced by: open or focus that ticket's tab. */
  onOpenTicket: (taskId: string, title: string) => void;
  /** Previous / next: show another ticket in this same tab. */
  onSwitchTicket: (taskId: string, title: string) => void;
  /** Agent rows: that agent's conversation in Main. */
  onOpenAgent: (instanceId: string, name: string) => void;
}

/** The ticket's link in the app (Copy link): opens this ticket tab. */
export function ticketLink(chainId: string, taskId: string): string {
  return buildRouteHash(`/chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}`, '');
}

/** Decrypts vault tokens inside the hub's preformatted history text (gap G1). */
function useOpenHistory(text: string): string {
  const unlocked = useSelector(selectIsVaultUnlocked);
  const [open, setOpen] = useState(text);
  useEffect(() => {
    let live = true;
    if (!text || !unlocked || !containsVaultArmored(text)) {
      setOpen(text);
      return;
    }
    decryptEmbeddedVaultTokens(text)
      .then((t) => live && setOpen(t))
      .catch(() => live && setOpen(text));
    return () => {
      live = false;
    };
  }, [text, unlocked]);
  return open;
}

/** Width of an element, for the two-column breakpoint (the aux pane is narrower than the window). */
function useElementWidth(el: HTMLElement | null): number {
  const [width, setWidth] = useState(0);
  useLayoutEffect(() => {
    if (!el || typeof ResizeObserver === 'undefined') return;
    setWidth(el.getBoundingClientRect().width);
    const ro = new ResizeObserver((entries) => setWidth(entries[0]?.contentRect.width || 0));
    ro.observe(el);
    return () => ro.disconnect();
  }, [el]);
  return width;
}

/**
 * One ticket in its own aux tab, Jira style (REQ-T1..T8): toolbar, title and
 * state, the decision block when it needs you, then Requirements, Linked
 * tickets, Attempts, Changes and Activity, with the state, Agents and Details in
 * a side column once the tab is wide enough. Live from WebSocket-patched caches.
 */
export const TicketView: React.FC<TicketViewProps> = ({ chainId, taskId, isMobile = false, focus, onFocusConsumed, onShowBoard, onOpenTicket, onSwitchTicket, onOpenAgent }) => {
  const ctx = useChainTickets(chainId);
  // A callback ref: the root mounts only once the ticket has loaded.
  const [rootEl, setRootEl] = useState<HTMLDivElement | null>(null);
  const width = useElementWidth(rootEl);
  const wide = !isMobile && width >= TICKET_TWO_COLUMN_MIN_PX;
  const now = useTicketClock(1000);
  const reducedMotion = usePrefersReducedMotion();
  const vaultUnlocked = useSelector(selectIsVaultUnlocked);
  const dispatch = useDispatch();

  const listTask = ctx.tasks.find((t) => t.task_id === taskId) || null;
  const { data: detailData, isLoading: detailLoading } = useFetchChainTaskDetailQuery({ chainId, taskId }, { skip: !chainId || !taskId });
  // The detail carries requirements history and the description; the chain list
  // row is patched first by task events, so take whichever is newer.
  const task: TaskWire | null = useMemo(() => {
    const detail: TaskWire | null = detailData?.task || null;
    if (!detail) return listTask;
    if (!listTask) return detail;
    const newer = Date.parse(String(listTask.updated_at || '')) > Date.parse(String(detail.updated_at || '')) ? listTask : detail;
    return { ...detail, ...newer, requirements: { ...(listTask.requirements || {}), ...(detail.requirements || {}), ...(newer.requirements || {}) } as any };
  }, [detailData?.task, listTask]);

  const actions = useTaskActions(chainId, taskId, task?.title || '', task || undefined);
  const [holdOpen, setHoldOpen] = useState(false);
  const [editing, setEditing] = useState<TaskEditField | null>(null);
  const [reqEditorOpen, setReqEditorOpen] = useState(false);
  const [activityTab, setActivityTab] = useState<ActivityTab>('all');
  const [reqView, setReqView] = useState<'current' | 'changes'>('current');
  const [detailsOpen, setDetailsOpen] = useState(true);
  const [highlight, setHighlight] = useState(false);
  const decisionRef = useRef<HTMLDivElement>(null);
  const activityRef = useRef<HTMLDivElement>(null);
  const shownRevision = useRef<number | null>(null);

  const openHistory = useOpenHistory(String(task?.requirements?.history || ''));
  const history = useMemo(() => parseRequirementsHistory(openHistory), [openHistory]);

  // REQ-T1 click map: Approve / Answer open the tab at its decision block; a
  // requirement-change line opens Activity › Requirement changes.
  useEffect(() => {
    if (!focus || !task) return;
    if (focus === 'decision') decisionRef.current?.scrollIntoView({ block: 'start', behavior: reducedMotion ? 'auto' : 'smooth' });
    if (focus === 'requirement_changes') {
      setActivityTab('requirements');
      requestAnimationFrame(() => activityRef.current?.scrollIntoView({ block: 'start', behavior: reducedMotion ? 'auto' : 'smooth' }));
    }
    onFocusConsumed?.();
  }, [focus, Boolean(task)]);

  // A requirement change arrives as a task update: when the revision moves under
  // an open tab, say so and highlight the card for 3 s (not under reduced motion).
  const revision = Number(task?.requirements?.revision) || 0;
  const [changedUnderYou, setChangedUnderYou] = useState(false);
  useEffect(() => {
    if (!revision) return;
    if (shownRevision.current !== null && revision > shownRevision.current) {
      setChangedUnderYou(true);
      if (!reducedMotion) {
        setHighlight(true);
        const t = setTimeout(() => setHighlight(false), 3000);
        shownRevision.current = revision;
        return () => clearTimeout(t);
      }
    }
    shownRevision.current = revision;
  }, [revision, reducedMotion]);

  const order = useMemo(() => boardOrder(ctx.tickets), [ctx.tickets]);
  const position = ticketPosition(order, taskId);
  const key = keyFor(ctx.keys, taskId);

  const go = (id: string | null) => {
    if (!id) return;
    const t = ctx.tasks.find((x) => x.task_id === id);
    onSwitchTicket(id, ticketTabTitle(keyFor(ctx.keys, id), t?.title || ''));
  };
  // j / k on desktop move between tickets (never while typing).
  useEffect(() => {
    if (isMobile) return;
    const el = rootEl;
    if (!el) return;
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      if (target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName))) return;
      if (e.key === 'j') go(position.next);
      if (e.key === 'k') go(position.prev);
    };
    el.addEventListener('keydown', onKey);
    return () => el.removeEventListener('keydown', onKey);
  });

  if (!task) {
    if (ctx.isLoading || detailLoading) return <TicketSkeleton />;
    return (
      <div className="p-6">
        <EmptyState
          icon="tasks"
          title="This ticket isn't in this chain any more"
          description="It may have been deleted, or the link points at another chain."
          action={
            <Button size="sm" variant="secondary" onClick={onShowBoard} data-debug-id="ticket-view-back-to-board-btn">
              Back to Tickets
            </Button>
          }
          data-debug-id="ticket-view-missing"
        />
      </div>
    );
  }

  const state = normalizeTaskState(task.state);
  const finished = isFinishedTask(task);
  const attempt = attemptInfo(task);
  const lease = leaseClock(task, now);
  const hold = taskHold(task);
  const ask = ticketAsk(task);
  const rework = isRework(task);
  const isGate = task.kind === 'gate';
  const workflowOwned = String(ctx.chain?.kind || '') === 'workflow' || Boolean(task.stage_key) || Boolean(task.workflow_run_id);
  const lock = editLock(task, String(ctx.chain?.kind || ''));
  const { primary, more } = getTaskActions(task);
  const canChangeRequirements = !workflowOwned && !isGate && !finished;
  const priority = String(task.priority || 'p2').toLowerCase();
  const masked = !vaultUnlocked;

  const runAction = async (id: TaskActionId) => {
    switch (id) {
      case 'publish':
        return void actions.publish();
      case 'approve':
        return void actions.approve();
      case 'request_changes':
      case 'answer':
        decisionRef.current?.scrollIntoView({ block: 'start', behavior: reducedMotion ? 'auto' : 'smooth' });
        return;
      case 'reopen':
        return void actions.reopen();
      case 'recheck': {
        const result = await actions.recheck();
        if (result) dispatch(showToast({ ...recheckToast(result), autoDismissMs: 6000 }));
        return;
      }
      case 'hold':
        return setHoldOpen(true);
      case 'release':
        return void actions.release();
      case 'cancel':
        if (window.confirm(`Cancel ${key}?`)) await actions.cancel();
        return;
      case 'copy_id':
        return void copy(task.task_id, 'Ticket id copied');
    }
  };

  const copy = async (text: string, title: string) => {
    try {
      await navigator.clipboard?.writeText(text);
      dispatch(showToast({ kind: 'success', title, autoDismissMs: 2500 }));
    } catch {
      dispatch(showToast({ kind: 'error', title: 'Copy failed', message: text }));
    }
  };
  const copyLink = () => void copy(`${window.location.origin}${window.location.pathname}${ticketLink(chainId, taskId)}`, 'Link copied');

  // State button: only what getTaskActions allows for this ticket and user; a
  // finished ticket offers Reopen only.
  const stateMenu: TaskActionId[] = finished ? ['reopen'] : [...primary, ...more].filter((a) => a !== 'copy_id');
  const editMenu: { field: TaskEditField; label: string }[] = workflowOwned || lock.locked
    ? []
    : [
        { field: 'assignee', label: 'Change assignee' },
        { field: 'reviewers', label: 'Change reviewers' },
        { field: 'deps', label: 'Change dependencies' },
      ];

  const toolbar = (
    <div
      className={[
        'flex min-h-11 items-center gap-1 border-b border-subtle bg-canvas px-3 py-1.5',
        isMobile ? 'sticky top-0 z-sticky' : '',
      ].join(' ')}
      data-debug-id="ticket-view-toolbar"
    >
      {isMobile ? (
        <>
          <IconButton icon="chevron-left" label="Back to Tickets" variant="ghost" size="md" onClick={onShowBoard} data-debug-id="ticket-view-back-btn" />
          <span className="min-w-0 flex-1 truncate font-mono text-body-sm text-primary">
            {key}
            {position.index >= 0 && <span className="text-muted"> · {position.index + 1} of {position.total}</span>}
          </span>
        </>
      ) : (
        <nav aria-label="Breadcrumb" className="flex min-w-0 flex-1 items-center gap-1 text-body-sm">
          <button type="button" onClick={onShowBoard} data-debug-id="ticket-view-breadcrumb-tickets" className="rounded-sm text-muted hover:text-primary focus-visible:outline-none focus-visible:shadow-focus">
            Tickets
          </button>
          <Icon name="chevron-right" size={12} className="text-faint" />
          <span className="font-mono text-primary" aria-current="page">{key}</span>
          {position.index >= 0 && <span className="ml-2 text-caption tabular-nums text-faint">{position.index + 1} of {position.total}</span>}
        </nav>
      )}
      {!isMobile && (
        <>
          <IconButton icon="chevron-left" label="Previous ticket (k)" variant="ghost" size="sm" disabled={!position.prev} onClick={() => go(position.prev)} data-debug-id="ticket-view-prev-btn" />
          <IconButton icon="chevron-right" label="Next ticket (j)" variant="ghost" size="sm" disabled={!position.next} onClick={() => go(position.next)} data-debug-id="ticket-view-next-btn" />
        </>
      )}
      <IconButton icon="copy" label="Copy link" variant="ghost" size={isMobile ? 'md' : 'sm'} onClick={copyLink} data-debug-id="ticket-view-copy-link-btn" />
      <Menu label={`More actions for ${key}`} align="end" trigger={<IconButton icon="more-horizontal" label="More actions" variant="ghost" size={isMobile ? 'md' : 'sm'} data-debug-id="ticket-view-more-btn" />}>
        {editMenu.map((it) => (
          <Menu.Item key={it.field} data-debug-id={`ticket-view-edit-${it.field}`} onClick={() => setEditing(it.field)}>
            {it.label}
          </Menu.Item>
        ))}
        {!workflowOwned && !finished && (
          <Menu.Item data-debug-id="ticket-view-edit-bridge" onClick={() => setDetailsOpen(true)}>
            Change bridge pin
          </Menu.Item>
        )}
        {more.filter((a) => a !== 'copy_id').map((a) => (
          <Menu.Item key={a} danger={a === 'cancel'} data-debug-id={`ticket-view-menu-${a}`} onClick={() => void runAction(a)}>
            {TASK_ACTION_LABELS[a]}
          </Menu.Item>
        ))}
        {hold && !finished && (
          <Menu.Item data-debug-id="ticket-view-menu-release" onClick={() => void runAction('release')}>
            {TASK_ACTION_LABELS.release}
          </Menu.Item>
        )}
        <Menu.Item data-debug-id="ticket-view-menu-copy_id" onClick={() => void runAction('copy_id')}>
          Copy ID
        </Menu.Item>
      </Menu>
    </div>
  );

  const header = (
    <div className="flex flex-col gap-3" data-debug-id="ticket-view-header">
      <Text as="h2" role="heading" className="break-words font-[family-name:var(--font-display)] text-primary" data-debug-id="ticket-view-title">
        <VaultText value={task.title} fallback="Untitled ticket" />
      </Text>
      <div className="flex flex-wrap items-center gap-2">
        <Menu
          label="Change state"
          trigger={
            <button
              type="button"
              disabled={!stateMenu.length}
              data-debug-id="ticket-view-state-btn"
              className="inline-flex min-h-8 items-center gap-1 rounded-pill focus-visible:outline-none focus-visible:shadow-focus disabled:cursor-default"
            >
              <StatusPill tone={hold ? 'warning' : TASK_STATE_TONE[state]}>{hold ? 'Held' : TASK_STATE_LABELS[state]}</StatusPill>
              {stateMenu.length > 0 && <Icon name="chevron-down" size={12} className="text-muted" />}
            </button>
          }
        >
          {stateMenu.map((a) => (
            <Menu.Item key={a} danger={a === 'cancel'} data-debug-id={`ticket-view-state-${a}`} onClick={() => void runAction(a)}>
              {TASK_ACTION_LABELS[a]}
            </Menu.Item>
          ))}
        </Menu>
        <Text as="span" role="body-sm" tone="muted">
          {attempt.label} · {priority.toUpperCase()}
        </Text>
        {rework && <Badge tone="warning">Rework</Badge>}
        {isDraft(task) && <Badge tone="neutral">Draft</Badge>}
      </div>
      {workflowOwned ? (
        <Text as="p" role="caption" tone="faint" data-debug-id="ticket-view-workflow-lock">
          The workflow run owns this ticket, so its requirements and people are set by the run.
        </Text>
      ) : (
        <div className={`flex gap-2 ${isMobile ? '-mx-4 overflow-x-auto px-4 pb-1' : 'flex-wrap'}`} data-debug-id="ticket-view-quick-actions">
          {finished ? (
            <Button size={isMobile ? 'md' : 'sm'} variant="secondary" onClick={() => void runAction('reopen')} disabled={actions.busy} data-debug-id="ticket-view-reopen-btn">
              Reopen
            </Button>
          ) : (
            <>
              {canChangeRequirements && (
                <Button
                  size={isMobile ? 'md' : 'sm'}
                  variant="secondary"
                  leading={<Icon name="pencil" size="sm" />}
                  disabled={masked}
                  title={masked ? 'Unlock your vault to edit' : undefined}
                  onClick={() => setReqEditorOpen(true)}
                  data-debug-id="ticket-view-change-requirements-btn"
                >
                  Change requirements
                </Button>
              )}
              {hold ? (
                <Button size={isMobile ? 'md' : 'sm'} variant="secondary" onClick={() => void runAction('release')} disabled={actions.busy} data-debug-id="ticket-view-release-btn">
                  Release hold
                </Button>
              ) : more.includes('hold') ? (
                <Button size={isMobile ? 'md' : 'sm'} variant="secondary" leading={<Icon name="stop" size="sm" />} onClick={() => void runAction('hold')} disabled={actions.busy} data-debug-id="ticket-view-hold-btn">
                  Hold
                </Button>
              ) : null}
              {!lock.locked && (
                <Button size={isMobile ? 'md' : 'sm'} variant="secondary" leading={<Icon name="git-branch" size="sm" />} onClick={() => setEditing('deps')} data-debug-id="ticket-view-add-dependency-btn">
                  Add dependency
                </Button>
              )}
            </>
          )}
        </div>
      )}
      {actions.error && (
        <Text as="p" role="caption" tone="danger" className="whitespace-pre-line break-words" data-debug-id="ticket-view-action-error">
          {actions.error}
        </Text>
      )}
    </div>
  );

  const people = getTaskPeople(task, ctx.fleets);
  const agentsCard = (
    <TicketAgentsCard task={task} names={ctx.names} machines={ctx.machines} people={people} now={now} onOpenAgent={onOpenAgent} />
  );

  const detailsCard = (
    <TicketDetailsCard
      task={task}
      chainId={chainId}
      names={ctx.names}
      keys={ctx.keys}
      fleets={ctx.fleets}
      bridges={ctx.bridges}
      open={detailsOpen}
      onToggle={() => setDetailsOpen((o) => !o)}
      actions={actions}
      now={now}
      locked={workflowOwned || finished}
      onOpenTicket={(id) => onOpenTicket(id, ticketTabTitle(keyFor(ctx.keys, id), ctx.tasks.find((t) => t.task_id === id)?.title || ''))}
      onCopy={copy}
    />
  );

  const composer = (
    <TaskComposer
      chainId={chainId}
      taskId={taskId}
      debugId="comment-composer"
      rows={1}
      placeholder={masked ? 'Unlock your vault to comment' : 'Add a comment'}
      disabled={actions.busy || masked}
      renderActions={({ body, canSend, reset }) => (
        <Button
          size="sm"
          variant="secondary"
          disabled={!canSend}
          data-debug-id="ticket-view-comment-send-btn"
          onClick={async () => {
            if (await actions.comment(body)) reset();
          }}
        >
          Comment
        </Button>
      )}
    />
  );

  const mainColumn = (
    <div className="flex min-w-0 flex-col gap-5">
      {changedUnderYou && (
        <div data-debug-id="ticket-view-requirements-changed-notice">
          <Alert tone="info" title={`Requirements changed to rev ${revision}`} onDismiss={() => setChangedUnderYou(false)}>
            <button type="button" data-debug-id="ticket-view-see-what-changed-notice" className="text-accent underline" onClick={() => setActivityTab('requirements')}>
              See what changed
            </button>
          </Alert>
        </div>
      )}
      <div ref={decisionRef}>
        <TicketDecisionBlock task={task} chainId={chainId} actions={actions} names={ctx.names} now={now} />
      </div>
      <TicketRequirementsCard
        task={task}
        history={history}
        names={ctx.names}
        now={now}
        view={reqView}
        onViewChange={setReqView}
        highlight={highlight}
        canEdit={canChangeRequirements}
        masked={masked}
        onChange={() => setReqEditorOpen(true)}
        onSeeChanges={() => {
          setActivityTab('requirements');
          activityRef.current?.scrollIntoView({ block: 'start', behavior: reducedMotion ? 'auto' : 'smooth' });
        }}
      />
      <TicketLinkedCard task={task} tasks={ctx.tasks} keys={ctx.keys} onOpenTicket={(id) => onOpenTicket(id, ticketTabTitle(keyFor(ctx.keys, id), ctx.tasks.find((t) => t.task_id === id)?.title || ''))} />
      <TicketAttemptsCard task={task} names={ctx.names} lease={lease} />
      <TicketChangesCard chainId={chainId} task={task} />
      <div ref={activityRef}>
        <TicketActivity
          chainId={chainId}
          task={task}
          names={ctx.names}
          now={now}
          history={history}
          rawHistory={openHistory}
          tab={activityTab}
          onTabChange={setActivityTab}
          composer={!isMobile ? composer : undefined}
        />
      </div>
    </div>
  );

  return (
    <div ref={setRootEl} tabIndex={-1} data-debug-id={`ticket-view-${taskId}`} className="flex h-full min-h-0 flex-col bg-canvas text-left outline-none">
      {toolbar}
      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className={`mx-auto flex w-full flex-col gap-5 p-4 sm:p-5 ${wide ? 'max-w-6xl' : ''}`}>
          {masked && <VaultLockedBanner debugId="ticket-view-vault-locked" editing />}
          {header}
          {wide ? (
            <div className="grid grid-cols-[minmax(0,1fr)_18rem] gap-6">
              {mainColumn}
              <aside className="flex flex-col gap-4" data-debug-id="ticket-view-side-column">
                {agentsCard}
                {detailsCard}
              </aside>
            </div>
          ) : (
            <>
              <div className="flex flex-col gap-4" data-debug-id="ticket-view-side-column">
                {agentsCard}
              </div>
              {mainColumn}
              {detailsCard}
            </>
          )}
        </div>
      </div>
      {isMobile && (
        <div className="sticky bottom-0 z-sticky border-t border-subtle bg-canvas p-3" data-debug-id="ticket-view-sticky-composer">
          {composer}
        </div>
      )}

      <TaskEditModal chainId={chainId} task={task} field={editing} onClose={() => setEditing(null)} tasks={ctx.tickets} chainFleets={ctx.fleets} names={ctx.names} />
      <HoldReasonDialog ticketKey={key} open={holdOpen} busy={actions.busy} onHold={actions.hold} onClose={() => setHoldOpen(false)} />
      <RequirementsEditorModal open={reqEditorOpen} onClose={() => setReqEditorOpen(false)} chainId={chainId} task={task} keys={ctx.keys} names={ctx.names} />
    </div>
  );
};

/* ------------------------------------------------------------------ */

function TicketSkeleton() {
  return (
    <div data-debug-id="ticket-view-loading" className="flex flex-col gap-4 p-5" aria-busy="true" aria-label="Loading ticket">
      <div className="h-11 rounded-md bg-surface motion-safe:animate-pulse" />
      <div className="h-8 w-3/4 rounded-md bg-surface motion-safe:animate-pulse" />
      <div className="h-40 rounded-lg bg-surface motion-safe:animate-pulse" />
      <div className="h-56 rounded-lg bg-surface motion-safe:animate-pulse" />
    </div>
  );
}

function Card({ title, aside, children, debugId, className = '' }: { title?: React.ReactNode; aside?: React.ReactNode; children: React.ReactNode; debugId?: string; className?: string }) {
  return (
    <section data-debug-id={debugId} className={`rounded-lg border border-subtle bg-surface ${className}`}>
      {title !== undefined && (
        <div className="flex flex-wrap items-center justify-between gap-2 px-4 pt-3">
          <Text as="h3" role="title" className="text-primary">{title}</Text>
          {aside}
        </div>
      )}
      <div className="p-4 pt-3">{children}</div>
    </section>
  );
}

/* Decision block (REQ-T3, REQ-T6) ------------------------------------ */

function TicketDecisionBlock({ task, chainId, actions, names, now }: { task: TaskWire; chainId: string; actions: TaskActionsApi; names: TaskNames; now: number }) {
  const ask = ticketAsk(task);
  const hold = taskHold(task);
  const userApproved = youApproved(task);
  const reviewing = awaitingYourReview(task) || userApproved;
  const attemptNo = task.attempt_no || 1;
  const { data: handoffData } = useFetchTaskFacetQuery({ chainId, taskId: task.task_id, attemptNo, kind: 'handoff' }, { skip: !reviewing });
  const { data: vcsData } = useFetchTaskFacetQuery({ chainId, taskId: task.task_id, attemptNo, kind: 'vcs' }, { skip: !reviewing });
  const b: any = task.blocked_on || {};

  if (hold && !(b.kind === 'agent_not_running' || b.kind === 'dispatch')) {
    return (
      <Card title={hold.checkpoint_requested ? 'Held · checkpoint requested' : 'Held'} debugId="task-hold-block" className="border-warning/40">
        {hold.reason ? <DecryptedMarkdown source={hold.reason} compact copyAll={false} data-debug-id="task-hold-reason" /> : null}
        <Text as="p" role="body-sm" tone="muted" data-debug-id="task-hold-meta">
          {[describeHold(hold, now, names), hold.checkpoint_requested ? 'the current holder was asked to hand off' : '', 'no new lease until released'].filter(Boolean).join(' · ')}
        </Text>
        <div className="mt-3">
          <Button size="sm" variant="secondary" disabled={actions.busy} data-debug-id="task-hold-release-btn" onClick={() => void actions.release()}>
            Release hold
          </Button>
        </div>
      </Card>
    );
  }
  if (ask === 'agent_down') {
    return (
      <Card title="Agent not running" debugId="ticket-view-agent-down" className="border-danger/40">
        <Text as="p" role="body-sm" className="text-primary">{String(b.reason || 'The agent could not start.')}</Text>
        <Text as="p" role="caption" tone="muted">Check the agent's bridge, provider and model. Updating its fleet settings retries the start.</Text>
      </Card>
    );
  }
  if (ask === 'publish') {
    return (
      <Card title="Not published" debugId="ticket-view-draft">
        <Text as="p" role="body-sm" tone="muted">Agents can't see this ticket until you publish it.</Text>
        <div className="mt-3">
          <Button size="sm" variant="primary" disabled={actions.busy} onClick={() => void actions.publish()} data-debug-id="ticket-view-publish-btn">
            Publish
          </Button>
        </div>
      </Card>
    );
  }
  if (blockedOnYou(task) && !hold) {
    const question = String(b.question || b.reason || b.message || '').trim();
    return (
      <Card title="Your answer" debugId="answer-blocker-block" className="border-warning/40">
        {question ? (
          <blockquote data-debug-id="answer-question" className="mb-3 border-l-2 border-warning pl-3 text-body-sm text-primary">
            <DecryptedMarkdown source={question} compact copyAll={false} />
          </blockquote>
        ) : (
          <Text as="p" role="body-sm" tone="muted">The agent is waiting on you but did not say what it needs. Check the latest comments, or ask it.</Text>
        )}
        <TaskComposer
          chainId={chainId}
          taskId={task.task_id}
          debugId="answer-composer"
          placeholder="Type your answer. You can paste or attach files."
          disabled={actions.busy}
          renderActions={({ body, canSend, reset }) => (
            <Button size="sm" variant="primary" disabled={!canSend} onClick={async () => { if (await actions.answer(body)) reset(); }}>
              Send answer
            </Button>
          )}
        />
      </Card>
    );
  }
  if (!reviewing) return null;

  const rework = isRework(task);
  const req = task.requirements;
  const submitted = Number(req?.submitted_revision) || 0;
  const current = Number(req?.revision) || 0;
  const handoff = handoffData?.facet;
  const files = taskChangedFiles(vcsData?.facet);
  const votes = (task.reviews || []).filter((r) => !isSupersededReview(r) && r.reviewer !== 'user');
  const worker = task.brief?.assignee ? names.agent(String(task.brief.assignee)) : 'The worker';
  return (
    <Card title="Your review" aside={rework ? <Badge tone="warning">Waiting for rework</Badge> : undefined} debugId="your-review-block" className="border-warning/40">
      <div className="flex flex-col gap-3">
        {rework && (
          <div data-debug-id="ticket-view-rework-notice">
            <Alert tone="warning" title="The requirements changed after this was submitted.">
              {worker} submitted attempt {task.attempt_no || 1} against rev {submitted || current - 1}; the requirements are now rev {current}, so this submission can't be approved. {worker} has been asked to rework it.
            </Alert>
          </div>
        )}
        {handoff?.summary && <DecryptedMarkdown source={String(handoff.summary)} compact copyAll={false} data-debug-id="your-review-summary" />}
        {files.length > 0 && <Text role="caption" tone="muted">{files.length} file{files.length === 1 ? '' : 's'} changed{handoff?.head ? ` · head ${String(handoff.head).slice(0, 7)}` : ''}</Text>}
        {votes.length > 0 && (
          <div className="flex flex-col gap-1" data-debug-id="ticket-view-votes">
            <Text as="span" role="overline" tone="faint">Votes</Text>
            <ul className="flex flex-wrap gap-x-4 gap-y-1">
              {votes.map((v, i) => {
                const label = names.participant(v.reviewer) || names.instance(v.reviewer_instance_id) || 'A reviewer';
                return (
                  <li key={`${v.reviewer}-${v.role}-${i}`} className="inline-flex items-center gap-1.5 text-body-sm">
                    <TicketAgentAvatar name={label} state="idle" />
                    <span className={rework ? 'text-faint line-through' : 'text-primary'}>{label}</span>
                    <span className="text-muted">{v.verdict === 'approve' ? 'approved' : 'requested changes'}</span>
                    {rework && <Badge tone="neutral">for rev {submitted || current - 1} · no longer counts</Badge>}
                  </li>
                );
              })}
            </ul>
          </div>
        )}
        <TaskComposer
          chainId={chainId}
          taskId={task.task_id}
          debugId="your-review-composer"
          placeholder={rework ? `Leave a note for the worker about the rework.` : 'What should change? Needed to request changes.'}
          requireText
          disabled={actions.busy}
          renderActions={({ body, canSend, reset }) => (
            <>
              {rework && <Text role="caption" tone="muted">Approve unlocks when the worker resubmits against rev {current}.</Text>}
              {userApproved ? (
                <Text role="caption" tone="muted" data-debug-id="your-review-approved">You approved</Text>
              ) : (
                <Button size="sm" variant="primary" disabled={actions.busy || rework} onClick={() => void actions.approve()} data-debug-id="ticket-view-approve-btn">
                  Approve
                </Button>
              )}
              <Button
                size="sm"
                variant="secondary"
                disabled={!canSend}
                data-debug-id="ticket-view-request-changes-btn"
                onClick={async () => {
                  if (rework ? await actions.comment(body) : await actions.requestChanges(body)) reset();
                }}
              >
                {rework ? 'Post comment' : 'Request changes'}
              </Button>
            </>
          )}
        />
      </div>
    </Card>
  );
}

/* Agents (REQ-T3) ---------------------------------------------------- */

function TicketAgentsCard({
  task,
  names,
  machines,
  people,
  now,
  onOpenAgent,
}: {
  task: TaskWire;
  names: TaskNames;
  machines: FleetMachine[];
  people: ReturnType<typeof getTaskPeople>;
  now: number;
  onOpenAgent: (instanceId: string, name: string) => void;
}) {
  const state = normalizeTaskState(task.state);
  const slots = machines.flatMap((m) => m.slots);
  const slotForAgent = (agentId: string) => slots.find((s) => s.agentId === agentId && s.instanceId) || slots.find((s) => s.agentId === agentId) || null;
  const offlineSlots = new Set(machines.filter((m) => !m.online).flatMap((m) => m.slots));
  const offline = (slot: FleetSlot | null | undefined) => (slot && offlineSlots.has(slot) ? ' · machine offline' : '');
  const lease = leaseClock(task, now);
  const rows: { id: string; name: string; sub: string; state: FleetSlotState; instanceId: string }[] = [];

  if (lease) {
    rows.push({
      id: `holder-${lease.holderInstanceId}`,
      name: names.instance(lease.holderInstanceId) || names.agent(people.assignee) || 'Worker',
      sub: `Assignee · has the lease · ${formatDuration(lease.leftMs)} left${offline(slots.find((s) => s.instanceId === lease.holderInstanceId))}`,
      state: 'working',
      instanceId: lease.holderInstanceId,
    });
  } else {
    const agentId = people.assignee || people.workers[0] || '';
    const slot = agentId ? slotForAgent(agentId) : null;
    rows.push({
      id: `assignee-${agentId || 'any'}`,
      name: people.assignee ? names.agent(people.assignee) : 'Any worker',
      sub: (state === 'done' ? 'Assignee · finished' : state === 'in_review' ? 'Assignee · handed off' : 'Assignee · waiting for the lease') + offline(slot),
      state: slot ? (slot.state === 'working' || slot.state === 'reviewing' ? 'working' : slot.state) : 'not_running',
      instanceId: slot?.instanceId || '',
    });
  }
  const holders = reviewLeaseHolders(task, now);
  const votes = new Map<string, string>();
  for (const r of task.reviews || []) if (!isSupersededReview(r)) votes.set(names.durableId(r.reviewer || r.reviewer_instance_id), r.verdict);
  for (const agentId of people.reviewers) {
    const holder = holders.find((h) => names.durableId(h.instanceId) === agentId);
    const slot = slotForAgent(agentId);
    const verdict = votes.get(agentId);
    rows.push({
      id: `reviewer-${agentId}`,
      name: names.agent(agentId),
      sub: (holder
        ? `Reviewer · reviewing, ${holder.leftMins}m left`
        : verdict
          ? `Reviewer · ${verdict === 'approve' ? 'approved' : 'requested changes'}`
          : state === 'in_review'
            ? 'Reviewer · up to review'
            : 'Reviewer · next, after handoff') + offline(slot),
      state: holder ? 'working' : slot ? (slot.state === 'working' || slot.state === 'reviewing' ? 'working' : slot.state) : 'not_running',
      instanceId: holder?.instanceId || slot?.instanceId || '',
    });
  }
  if (people.userApproval) {
    rows.push({ id: 'user', name: 'You', sub: votes.get('user') === 'approve' ? 'Reviewer · approved' : 'Reviewer · final approval', state: 'idle', instanceId: '' });
  }
  return (
    <Card debugId="ticket-view-agents" className="overflow-hidden">
      <ul className="-m-4 divide-y divide-subtle">
        {rows.map((r) => {
          const clickable = Boolean(r.instanceId);
          return (
            <li key={r.id}>
              <button
                type="button"
                disabled={!clickable}
                onClick={() => clickable && onOpenAgent(r.instanceId, r.name)}
                data-debug-id={`ticket-view-agent-${r.id}`}
                title={clickable ? `Open ${r.name}'s conversation` : r.state === 'not_running' ? 'Hub starts it when needed' : undefined}
                className="flex min-h-11 w-full min-w-0 items-center gap-3 px-4 py-2.5 text-left enabled:hover:bg-surface-raised focus-visible:outline-none focus-visible:shadow-focus disabled:cursor-default"
              >
                <TicketAgentAvatar name={r.name} state={r.state} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-body-sm font-semibold text-primary">{r.name}</span>
                  <span className="block truncate text-caption text-muted">{r.sub}</span>
                </span>
                {r.id !== 'user' && <StatusPill tone={FLEET_STATE_TONE[r.state]}>{FLEET_STATE_LABELS[r.state]}</StatusPill>}
              </button>
            </li>
          );
        })}
      </ul>
    </Card>
  );
}

/* Requirements (REQ-T4) ---------------------------------------------- */

function TicketRequirementsCard({
  task,
  history,
  names,
  now,
  view,
  onViewChange,
  highlight,
  canEdit,
  masked,
  onChange,
  onSeeChanges,
}: {
  task: TaskWire;
  history: ReturnType<typeof parseRequirementsHistory>;
  names: TaskNames;
  now: number;
  view: 'current' | 'changes';
  onViewChange: (v: 'current' | 'changes') => void;
  highlight: boolean;
  canEdit: boolean;
  masked: boolean;
  onChange: () => void;
  onSeeChanges: () => void;
}) {
  const req = task.requirements;
  const revision = Number(req?.revision) || 1;
  const latest = history && history.length ? history[0] : null;
  const acceptance = (task.brief?.acceptance || []).map(String);
  // Edited / New tags compare with the revision before the current one.
  const prev = latest && latest.revision === revision ? latest.before.acceptance : null;
  const diff = prev ? diffAcceptance(prev, acceptance) : { items: acceptance.map((text) => ({ text, tag: null as null })), removed: [] as string[] };
  const acks = req?.acknowledgements || [];
  const pending = acks.filter((a) => a.pending);
  const who = latest ? (latest.actorKind === 'user' ? 'You' : names.participant(latest.actorId) || names.instance(latest.actorId) || 'An agent') : '';
  const goal = String(task.brief?.goal || task.description || '');
  return (
    <section
      data-debug-id="ticket-view-requirements"
      className={`rounded-lg border bg-surface transition-colors duration-slow motion-reduce:transition-none ${highlight ? 'border-info bg-info-soft' : 'border-subtle'}`}
    >
      <div className="flex flex-wrap items-center justify-between gap-2 px-4 pt-3">
        <span className="flex flex-wrap items-center gap-2">
          <Text as="h3" role="title" className="text-primary">Requirements</Text>
          <Badge tone="neutral" data-debug-id="task-requirements-status">Rev {revision}</Badge>
          {latest && latest.revision === revision && (
            <Text as="span" role="caption" tone="muted">by {who} · {formatAgo(latest.tsMs, now)}</Text>
          )}
        </span>
        <span className="flex items-center gap-2">
          {revision > 1 && (
            <Tabs value={view} onChange={(v) => onViewChange(v as 'current' | 'changes')} variant="segmented">
              <TabsList label="Requirements view">
                <Tab value="current" data-debug-id="ticket-view-requirements-current">Current</Tab>
                <Tab value="changes" data-debug-id="ticket-view-requirements-changes">Changes</Tab>
              </TabsList>
            </Tabs>
          )}
        </span>
      </div>
      <div className="flex flex-col gap-3 p-4 pt-3">
        {pending.length > 0 && (
          <Alert tone="info" icon="info">
            {pending.map((a) => names.instance(a.holder_instance_id) || 'The worker').join(', ')} {pending.length === 1 ? 'was' : 'were'} notified and read{pending.length === 1 ? 's' : ''} rev {revision} before {pending.length === 1 ? 'its' : 'their'} next step.
          </Alert>
        )}
        {view === 'changes' && latest ? (
          <div className="flex flex-col gap-2 text-body-sm" data-debug-id="ticket-view-requirements-diff">
            <Text as="p" role="caption" tone="muted">Since rev {latest.revision - 1}</Text>
            {latest.before.goal !== latest.after.goal && (
              <div className="flex flex-col gap-1">
                <span className="text-faint line-through"><VaultText value={latest.before.goal} /></span>
                <span className="text-primary"><VaultText value={latest.after.goal} /></span>
              </div>
            )}
            {diffAcceptance(latest.before.acceptance, latest.after.acceptance).items.filter((i) => i.tag).map((i, n) => (
              <div key={n} className="flex gap-2">
                <Badge tone={i.tag === 'new' ? 'success' : 'info'}>{i.tag === 'new' ? 'Add' : 'Edit'}</Badge>
                <span className="min-w-0 break-words text-primary"><EditedText previous={i.previous} text={i.text} /></span>
              </div>
            ))}
            {diffAcceptance(latest.before.acceptance, latest.after.acceptance).removed.map((r, n) => (
              <div key={`r${n}`} className="flex gap-2">
                <Badge tone="danger">Remove</Badge>
                <span className="min-w-0 break-words text-faint line-through">{r}</span>
              </div>
            ))}
            <div>
              <Button size="sm" variant="ghost" onClick={onSeeChanges} data-debug-id="ticket-view-see-what-changed">
                See every change
              </Button>
            </div>
          </div>
        ) : (
          <>
            {goal ? (
              <div className="font-[family-name:var(--font-display)] text-body text-primary">
                <DecryptedMarkdown source={goal} compact copyAll={false} data-debug-id="task-details-goal" />
              </div>
            ) : (
              <Text role="caption" tone="faint">No goal yet.</Text>
            )}
            {diff.items.length > 0 && (
              <ul className="divide-y divide-subtle" data-debug-id="ticket-view-acceptance">
                {diff.items.map((i, n) => (
                  <li key={n} className="flex items-start gap-2 py-2 text-body-sm">
                    <span aria-hidden="true" className="mt-0.5 inline-flex h-3.5 w-3.5 shrink-0 items-center justify-center rounded-pill border border-strong text-success">
                      {normalizeTaskState(task.state) === 'done' && <Icon name="check" size={10} />}
                    </span>
                    <span className="min-w-0 flex-1 break-words text-primary">
                      {i.tag === 'edited' ? <EditedText previous={'previous' in i ? i.previous : undefined} text={i.text} /> : <VaultText value={i.text} />}
                    </span>
                    {i.tag === 'edited' && <Badge tone="info">Edited</Badge>}
                    {i.tag === 'new' && <Badge tone="success">New</Badge>}
                  </li>
                ))}
              </ul>
            )}
          </>
        )}
        {acks.length > 0 && revision > 1 && (
          <div className="flex flex-col gap-1" data-debug-id="ticket-view-requirements-readers">
            <Text as="span" role="overline" tone="faint">Who has read rev {revision}</Text>
            <ul className="flex flex-wrap gap-x-4 gap-y-1">
              {acks.map((a) => (
                <li key={a.lease_id} className="inline-flex items-center gap-1.5 text-body-sm">
                  <TicketAgentAvatar name={names.instance(a.holder_instance_id) || 'Agent'} state={a.pending ? 'working' : 'idle'} />
                  <span className="text-primary">{names.instance(a.holder_instance_id) || 'Agent'}</span>
                  <Badge tone={a.pending ? 'info' : 'success'}>{a.pending ? 'Notified · reads at next step' : 'Read'}</Badge>
                </li>
              ))}
            </ul>
          </div>
        )}
        {canEdit && (
          <div>
            <Button size="sm" variant="secondary" leading={<Icon name="pencil" size="sm" />} disabled={masked} title={masked ? 'Unlock your vault to edit' : undefined} onClick={onChange} data-debug-id="ticket-view-requirements-change-btn">
              Change requirements
            </Button>
          </div>
        )}
      </div>
    </section>
  );
}

/* Linked tickets ----------------------------------------------------- */

function TicketLinkedCard({ task, tasks, keys, onOpenTicket }: { task: TaskWire; tasks: TaskWire[]; keys: Map<string, string>; onOpenTicket: (taskId: string) => void }) {
  const waits = (task.depends_on || []).map((id) => tasks.find((t) => t.task_id === id) || ({ task_id: id, title: '', state: '' } as TaskWire));
  const unblocks = dependentsOf(tasks, task.task_id);
  if (!waits.length && !unblocks.length) return null;
  return (
    <section data-debug-id="ticket-view-linked" className="flex flex-col gap-2">
      <Text as="h3" role="title" className="text-primary">Linked tickets</Text>
      {waits.length > 0 && (
        <>
          <Text as="span" role="overline" tone="faint">Waits for</Text>
          <ul className="flex flex-col gap-1.5">
            {waits.map((t) => {
              const s = normalizeTaskState(t.state);
              return (
                <li key={t.task_id}>
                  <button
                    type="button"
                    onClick={() => onOpenTicket(t.task_id)}
                    data-debug-id={`ticket-view-linked-${t.task_id}`}
                    className="flex min-h-11 w-full min-w-0 items-center gap-3 rounded-lg border border-subtle bg-surface px-3 py-2 text-left hover:border-strong hover:bg-surface-raised focus-visible:outline-none focus-visible:shadow-focus"
                  >
                    <span className="shrink-0 font-mono text-caption text-faint">{keyFor(keys, t.task_id)}</span>
                    <VaultText value={t.title} fallback="Untitled ticket" className="min-w-0 flex-1 truncate text-body-sm text-primary" />
                    <StatusPill tone={TASK_STATE_TONE[s]}>{TASK_STATE_LABELS[s]}</StatusPill>
                  </button>
                </li>
              );
            })}
          </ul>
        </>
      )}
      {unblocks.length > 0 && (
        <p className="flex flex-wrap items-center gap-x-2 text-caption text-muted">
          Unblocks
          {unblocks.map((t) => (
            <button
              key={t.task_id}
              type="button"
              onClick={() => onOpenTicket(t.task_id)}
              data-debug-id={`ticket-view-unblocks-${t.task_id}`}
              className="rounded-sm text-muted underline decoration-dotted hover:text-primary focus-visible:outline-none focus-visible:shadow-focus"
            >
              {keyFor(keys, t.task_id)} · <VaultText value={t.title} fallback="Untitled ticket" />
            </button>
          ))}
        </p>
      )}
    </section>
  );
}

/* Attempts (gap G3: only the latest submission's revision is known) --- */

function TicketAttemptsCard({ task, names, lease }: { task: TaskWire; names: TaskNames; lease: ReturnType<typeof leaseClock> }) {
  const attempt = attemptInfo(task);
  const state = normalizeTaskState(task.state);
  const submitted = Number(task.requirements?.submitted_revision) || 0;
  const rework = isRework(task);
  const rows = Array.from({ length: attempt.no }, (_, i) => attempt.no - i);
  return (
    <section data-debug-id="ticket-view-attempts" className="flex flex-col gap-2">
      <Text as="h3" role="title" className="text-primary">Attempts</Text>
      <ul className="divide-y divide-subtle overflow-hidden rounded-lg border border-subtle bg-surface">
        {rows.map((n) => {
          const current = n === attempt.no;
          let text = 'Earlier attempt';
          let pill: { tone: 'info' | 'pending' | 'success' | 'neutral' | 'warning'; label: string } = { tone: 'neutral', label: 'Superseded' };
          if (current) {
            if (state === 'in_progress') {
              text = `${(lease && names.instance(lease.holderInstanceId)) || 'The worker'} · ${rework ? `reworking for rev ${task.requirements?.revision}` : 'working'}`;
              pill = { tone: 'info', label: 'Working' };
            } else if (state === 'in_review') {
              text = submitted ? `Submitted for rev ${submitted}` : 'Submitted';
              pill = rework ? { tone: 'warning', label: 'Out of date' } : { tone: 'pending', label: 'In review' };
            } else if (state === 'done') {
              text = submitted ? `Submitted for rev ${submitted} · accepted` : 'Accepted';
              pill = { tone: 'success', label: 'Done' };
            } else if (state === 'cancelled') {
              text = 'Cancelled';
              pill = { tone: 'neutral', label: 'Cancelled' };
            } else {
              text = 'Waiting for a worker';
              pill = { tone: 'neutral', label: 'Not started' };
            }
          }
          return (
            <li key={n} className="flex min-h-11 items-center gap-3 px-3 py-2 text-body-sm" data-debug-id={`ticket-view-attempt-${n}`}>
              <span className="w-20 shrink-0 text-muted">Attempt {n}</span>
              <span className="min-w-0 flex-1 truncate text-primary">{text}</span>
              <StatusPill tone={pill.tone}>{pill.label}</StatusPill>
            </li>
          );
        })}
      </ul>
      {attempt.warn && !isFinishedTask(task) && (
        <Text as="p" role="caption" tone="warning">{attempt.left === 0 ? 'This is the last attempt.' : `${attempt.left} attempt left.`}</Text>
      )}
    </section>
  );
}

/* Changes and output (fetched on first open) ------------------------- */

function TicketChangesCard({ chainId, task }: { chainId: string; task: TaskWire }) {
  const [open, setOpen] = useState(false);
  const [diffFile, setDiffFile] = useState<string | null>(null);
  const attemptNo = task.attempt_no || 1;
  const skip = !open;
  const { data: vcsData, isFetching } = useFetchTaskFacetQuery({ chainId, taskId: task.task_id, attemptNo, kind: 'vcs' }, { skip });
  const { data: outputData } = useFetchTaskFacetQuery({ chainId, taskId: task.task_id, attemptNo, kind: 'output' }, { skip });
  const vcs = vcsData?.facet;
  const files = taskChangedFiles(vcs);
  const { data: diffData } = useFetchCommitDiffQuery(
    { chainId, directoryId: vcs?.directory_id || 'default', base: vcs?.base || '', head: vcs?.head || '', path: diffFile || '' },
    { skip: !diffFile || !vcs?.base || !vcs?.head },
  );
  const output = outputData?.facet;
  return (
    <section data-debug-id="task-details-changes" className="flex flex-col gap-2">
      <button
        type="button"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
        data-debug-id="ticket-view-changes-toggle"
        className="flex min-h-11 items-center gap-2 self-start rounded-sm text-left focus-visible:outline-none focus-visible:shadow-focus"
      >
        <Icon name={open ? 'chevron-down' : 'chevron-right'} size={14} className="text-muted" />
        <Text as="span" role="title" className="text-primary">Changes</Text>
        {open && files.length > 0 && <Text as="span" role="caption" tone="faint">{files.length} files</Text>}
      </button>
      {open && (
        <div className="flex flex-col gap-2">
          {isFetching && !vcsData && <Text role="caption" tone="faint">Loading changes…</Text>}
          {!isFetching && files.length === 0 && <Text role="caption" tone="faint">No file changes recorded for attempt {attemptNo}.</Text>}
          {files.length > 0 && (
            <ul className="divide-y divide-subtle overflow-hidden rounded-lg border border-subtle bg-surface">
              {files.map(({ path, add, del }) => (
                <li key={path}>
                  <button
                    type="button"
                    aria-expanded={diffFile === path}
                    onClick={() => setDiffFile(diffFile === path ? null : path)}
                    data-debug-id={`ticket-view-changed-file-${path}`}
                    className="flex min-h-11 w-full min-w-0 items-center gap-2 px-3 py-2 text-left hover:bg-surface-raised focus-visible:outline-none focus-visible:shadow-focus"
                  >
                    <span className="min-w-0 flex-1 truncate font-mono text-code-sm text-primary">{path}</span>
                    {typeof add === 'number' && typeof del === 'number' && (
                      <span className="shrink-0 font-mono text-code-sm"><span className="text-success">+{add}</span> <span className="text-danger">-{del}</span></span>
                    )}
                  </button>
                  {diffFile === path && (
                    <pre className="max-h-80 overflow-auto bg-canvas p-3 font-mono text-code-sm text-primary">
                      {diffData ? `${diffData.diff || diffData.raw || ''}${diffData.truncated ? '\n\n(diff truncated)' : ''}` : 'Loading diff…'}
                    </pre>
                  )}
                </li>
              ))}
            </ul>
          )}
          {output && (
            <div data-debug-id="task-details-output" className="flex flex-col gap-1">
              <Text as="span" role="overline" tone="faint">Output</Text>
              {typeof (output.summary || output.text) === 'string' ? (
                <DecryptedMarkdown source={String(output.summary || output.text)} compact copyAll={false} />
              ) : (
                <pre className="max-h-48 overflow-auto rounded-md bg-canvas p-2 font-mono text-code-sm text-primary">{JSON.stringify(output, null, 2)}</pre>
              )}
            </div>
          )}
        </div>
      )}
    </section>
  );
}

/* Details ------------------------------------------------------------ */

function TicketDetailsCard({
  task,
  chainId,
  names,
  keys,
  fleets,
  bridges,
  open,
  onToggle,
  actions,
  now,
  locked,
  onOpenTicket,
  onCopy,
}: {
  task: TaskWire;
  chainId: string;
  names: TaskNames;
  keys: Map<string, string>;
  fleets: any[];
  bridges: any[];
  open: boolean;
  onToggle: () => void;
  actions: TaskActionsApi;
  now: number;
  locked: boolean;
  onOpenTicket: (taskId: string) => void;
  onCopy: (text: string, title: string) => Promise<void>;
}) {
  const [updatePriority, priorityState] = useUpdateTaskPriorityMutation();
  const [moreOpen, setMoreOpen] = useState(false);
  const attempt = attemptInfo(task);
  const lease = leaseClock(task, now);
  const placement = describeEffectivePlacement(taskEffectivePlacement(task, fleets), names.bridge);
  const unpinned = describeEffectivePlacement(taskEffectivePlacement({ ...task, bridge_id: '' }, fleets), names.bridge);
  const bridgeOptions = [
    { value: '', text: unpinned.bridge ? `Fleet default: ${unpinned.bridge}` : "Fleet default: the worker's fleet row decides" },
    ...taskBridgeOptions(bridges, String(task.bridge_id || '')).slice(1).map((o) => ({ value: o.value, text: o.label })),
  ];
  const links = replacementLinks(String(task.comment_summary?.last_comment_preview || ''));
  const priority = String(task.priority || 'p2').toLowerCase();
  const row = (label: string, value: React.ReactNode, debugId?: string) => (
    <div className="grid grid-cols-[6.5rem_minmax(0,1fr)] items-center gap-3 py-2" data-debug-id={debugId}>
      <dt className="text-body-sm text-muted">{label}</dt>
      <dd className="min-w-0 text-body-sm text-primary">{value}</dd>
    </div>
  );
  return (
    <section data-debug-id="ticket-view-details" className="rounded-lg border border-subtle bg-surface">
      <button
        type="button"
        aria-expanded={open}
        onClick={onToggle}
        data-debug-id="ticket-view-details-toggle"
        className="flex min-h-11 w-full items-center justify-between gap-2 px-4 py-2 text-left focus-visible:outline-none focus-visible:shadow-focus"
      >
        <Text as="h3" role="title" className="text-primary">Details</Text>
        <Icon name={open ? 'chevron-up' : 'chevron-down'} size={14} className="text-muted" />
      </button>
      {open && (
        <dl className="divide-y divide-subtle border-t border-subtle px-4">
          {row(
            'Priority',
            locked ? (
              <Badge tone="neutral">{priority.toUpperCase()}</Badge>
            ) : (
              <Select
                size="sm"
                value={priority}
                aria-label="Priority"
                disabled={priorityState.isLoading}
                onChange={(v) => void updatePriority({ chainId, taskId: task.task_id, priority: v })}
                options={[{ value: 'p0', text: 'P0 urgent' }, { value: 'p1', text: 'P1 high' }, { value: 'p2', text: 'P2 normal' }]}
                data-debug-id="ticket-view-priority-select"
              />
            ),
            'ticket-view-detail-priority',
          )}
          {row(
            'Bridge',
            locked ? (
              <span className="font-mono">{placement.bridge || 'Fleet default'}</span>
            ) : (
              <Select size="sm" value={String(task.bridge_id || '')} onChange={(v) => void actions.pinBridge(v)} options={bridgeOptions} disabled={actions.busy} aria-label="Bridge pin" data-debug-id="ticket-view-bridge-select" />
            ),
            'ticket-view-detail-bridge',
          )}
          {row('Attempt', `${attempt.no} of ${attempt.max}${lease?.hardLeftMs != null ? ` · hard limit in ${formatDuration(lease.hardLeftMs)}` : ''}`, 'ticket-view-detail-attempt')}
          {links.replaces && row('Replaces', <button type="button" data-debug-id="ticket-view-replaces-link" className="text-accent hover:underline" onClick={() => onOpenTicket(links.replaces!)}>{keyFor(keys, links.replaces)}</button>, 'ticket-view-detail-replaces')}
          {links.replacedBy && row('Replaced by', <button type="button" data-debug-id="ticket-view-replaced-by-link" className="text-accent hover:underline" onClick={() => onOpenTicket(links.replacedBy!)}>{keyFor(keys, links.replacedBy)}</button>, 'ticket-view-detail-replaced-by')}
          {row(
            'More fields',
            moreOpen ? (
              <dl className="grid grid-cols-[4.5rem_minmax(0,1fr)] gap-x-2 gap-y-1 text-caption">
                <dt className="text-muted">Model</dt>
                <dd className="truncate font-mono">{placement.model || 'fleet default'}</dd>
                <dt className="text-muted">Chain</dt>
                <dd className="truncate font-mono">{chainId}</dd>
                <dt className="text-muted">Kind</dt>
                <dd className="truncate font-mono">{task.kind || 'task'}</dd>
                <dt className="text-muted">Task ID</dt>
                <dd className="flex min-w-0 items-center gap-1">
                  <span className="truncate font-mono">{task.task_id}</span>
                  <IconButton icon="copy" label="Copy ID" size="sm" variant="ghost" onClick={() => void onCopy(task.task_id, 'Ticket id copied')} data-debug-id="ticket-view-copy-id-btn" />
                </dd>
              </dl>
            ) : (
              <button type="button" className="text-muted hover:text-primary" onClick={() => setMoreOpen(true)} data-debug-id="ticket-view-more-fields-btn">
                Model, chain, kind, task ID
              </button>
            ),
            'ticket-view-detail-more',
          )}
          <div className="py-2 text-caption text-faint">
            Created {formatAgo(task.created_at, now)}
            {task.updated_at ? ` · Updated ${formatAgo(task.updated_at, now)}` : ''}
          </div>
        </dl>
      )}
    </section>
  );
}

export default TicketView;
