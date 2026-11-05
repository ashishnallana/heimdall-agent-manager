import React, { useState, useEffect } from 'react';
import { Badge, Button, IconButton, Text } from '@ui';
import { usePublishTaskChainMutation } from '../../api/endpoints/tasks';
import { TicketBoard } from '../tasks/TicketBoard';
import { TicketView } from '../tasks/TicketView';
import { RequirementsEditorModal } from '../tasks/RequirementsEditorModal';
import { TaskEditModal, type TaskEditField } from '../tasks/TaskEditModal';
import type { TicketOpenFocus } from '../tasks/BoardTicketCard';
import { useChainTickets } from '../tasks/useChainTickets';
import { replacementLinks, ticketTabTitle, keyFor } from '../tasks/ticketModel';
import { buildRouteHash, navigateTo } from '../../utils/appLocation';
import { VaultText } from '../vault/VaultText';
import { WorkflowPipelineView } from '../tasks/WorkflowPipelineView';
import { useFetchChainWorkflowRunsQuery } from '../../api/endpoints/workflowRuns';
import { CreateTaskModal } from '../tasks/CreateTaskModal';
import { TaskBoardSkeleton } from '../tasks/TaskBoardSkeleton';
import { FleetManagementDrawer } from '../tasks/FleetManagementDrawer';
import { ReviewRolesModal } from '../tasks/ReviewRolesModal';
import { useOpenAgentChat } from '../auxiliary/openAgentChatContext';
import { useFetchAgentInstanceQuery, useFetchAgentIdentityQuery, useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { actionErrorMessage } from '../tasks/useTaskActions';
import { useIsMobile } from '../shell/responsive';
import type { WorkflowRunView } from '../../api/endpoints/workflowRuns';

/** Run title + status. The title wraps (long IDs/URLs included) so the badge stays inside the card. */
export const WorkflowRunHeader: React.FC<{ run: Pick<WorkflowRunView, 'title' | 'workflow_name' | 'status' | 'execution_no'> }> = ({ run }) => (
  <div className="flex min-w-0 flex-wrap items-start gap-x-2 gap-y-1 px-4 pt-4">
    <VaultText value={run.title || run.workflow_name} fallback="Untitled workflow" className="block min-w-0 max-w-full flex-1 break-words text-sm font-semibold text-primary [overflow-wrap:anywhere]" />
    <Badge tone="neutral">{run.status} · Execution {run.execution_no}</Badge>
  </div>
);

function shellHash(path: string): string {
  return `#${path.startsWith('/') ? path : `/${path}`}`;
}

export interface TaskChainOverviewProps {
  chainId: string;
  focusTaskId?: string;
  isMobile?: boolean;
  embedded?: boolean;
  hideTitleBar?: boolean;
  onClose?: () => void;
  /**
   * Opens a ticket in its own aux tab (REQ-T1). Without it (the Task Chains
   * page has no aux pane) the ticket opens in place and its breadcrumb returns
   * to the board.
   */
  onOpenTicket?: (taskId: string, title: string, focus?: TicketOpenFocus) => void;
  /** An agent row: that agent's conversation in Main. Defaults to the chat route. */
  onOpenAgent?: (instanceId: string, name: string) => void;
}

/** The existing chat route: the agent's conversation in Main. */
export function openAgentConversation(instanceId: string, isMobile = false): void {
  if (!instanceId) return;
  navigateTo(buildRouteHash(`/conversations/${encodeURIComponent(instanceId)}`, isMobile ? '' : '?panel=tasks'));
  if (isMobile) window.dispatchEvent(new CustomEvent('heimdall:close-sidebar'));
}

export function InstanceIdLink({ instanceId, displayName }: { instanceId: string; displayName?: string }) {
  const trimmed = String(instanceId || '').trim();
  const openAgentChat = useOpenAgentChat();
  const known = Boolean(String(displayName || '').trim());
  const isMobile = useIsMobile();
  const { data } = useFetchAgentInstanceQuery({ instanceId: trimmed }, { skip: !trimmed || known });
  const inst = data?.instance || null;
  const agentId = String(inst?.agent_id || inst?.agentId || '');
  const instName = String(displayName || '').trim() || inst?.display_name || inst?.displayName || '';

  const { data: agentData } = useFetchAgentIdentityQuery({ agentId }, { skip: !agentId || known || Boolean(instName) });
  const agentName = instName || agentData?.agent?.name || agentData?.agent?.display_name || agentData?.agent?.agent_id || agentId || trimmed;

  if (!trimmed) return null;

  const href = isMobile
    ? shellHash(`/conversations/${encodeURIComponent(trimmed)}`)
    : shellHash(`/conversations/${encodeURIComponent(trimmed)}?panel=tasks`);
  const title = `Open chat with ${trimmed}`;
  return (
    <a
      data-debug-id={`taskchain-instance-link-${trimmed}`}
      href={href}
      title={title}
      onClick={(event) => {
        if (openAgentChat && openAgentChat(trimmed, agentName)) {
          event.preventDefault();
          return;
        }
        if (isMobile) {
          window.dispatchEvent(new CustomEvent('heimdall:close-sidebar'));
        }
      }}
      className="font-mono text-accent underline decoration-dotted underline-offset-2 hover:opacity-80"
    >
      {agentName}
    </a>
  );
}

export const TaskChainOverview: React.FC<TaskChainOverviewProps> = ({
  chainId,
  focusTaskId,
  isMobile = false,
  embedded = false,
  hideTitleBar = false,
  onClose,
  onOpenTicket,
  onOpenAgent,
}) => {
  // Without an aux pane the ticket opens in place; a deep link opens it too.
  const [inlineTicket, setInlineTicket] = useState<{ taskId: string; focus?: TicketOpenFocus } | null>(focusTaskId && !onOpenTicket ? { taskId: focusTaskId } : null);
  const [showNewTaskModal, setShowNewTaskModal] = useState(false);
  const [showFleetDrawer, setShowFleetDrawer] = useState(false);
  const [showReviewRoles, setShowReviewRoles] = useState(false);
  const [editing, setEditing] = useState<{ taskId: string; field: TaskEditField } | null>(null);
  const [publishChain, publishChainState] = usePublishTaskChainMutation();
  const [publishError, setPublishError] = useState('');

  const ctx = useChainTickets(chainId);
  const { chain, tasks, tickets, keys, names, fleets, machines } = ctx;

  const openTicket = React.useCallback(
    (taskId: string, focus?: TicketOpenFocus) => {
      const t = tasks.find((x) => x.task_id === taskId);
      if (onOpenTicket) onOpenTicket(taskId, ticketTabTitle(keyFor(keys, taskId), t?.title || ''), focus);
      else setInlineTicket({ taskId, focus });
    },
    [onOpenTicket, tasks, keys],
  );
  // Stable, so the memoized cards skip re-rendering when nothing they show changed.
  const editTicket = React.useCallback((taskId: string, field: TaskEditField) => setEditing({ taskId, field }), []);

  // A deep link to a task (`?panel=tasks&task=` or /chains/:c/tasks/:t) opens that ticket.
  const consumedFocus = React.useRef('');
  useEffect(() => {
    if (!focusTaskId || consumedFocus.current === focusTaskId) return;
    if (onOpenTicket && !tasks.length) return;
    consumedFocus.current = focusTaskId;
    openTicket(focusTaskId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focusTaskId, tasks.length]);

  const openAgent = onOpenAgent || ((instanceId: string) => openAgentConversation(instanceId, isMobile));

  const workflowRunsQuery = useFetchChainWorkflowRunsQuery({ chainId }, {
    skip: !chainId,
    // No poll: workflow_run/stage_changed and task_chain/workflow_* (with run id)
    // invalidate WorkflowRuns:<chain>/<run>; task events still reach Chain:<id>.
    refetchOnReconnect: true,
  });
  const workflowRuns = workflowRunsQuery.currentData?.runs || [];

  const { data: identitiesData } = useListAgentIdentitiesQuery();
  // Solo mode: the coordinator also does the work — it is the
  // built-in Soloist, or its own agent has a worker row in the fleet.
  const coordinatorId = ctx.coordinatorInstanceId;
  const { data: coordinatorData } = useFetchAgentInstanceQuery({ instanceId: coordinatorId }, { skip: !coordinatorId });
  const coordinatorAgentId = String((coordinatorData as any)?.instance?.agent_id || (coordinatorData as any)?.instance?.agentId || '');
  const isSolo = React.useMemo(() => {
    if (!coordinatorAgentId) return false;
    const agent: any = (identitiesData?.agents || []).find((a: any) => (a?.agent_id || a?.agentId) === coordinatorAgentId);
    if (agent && (agent.slug === 'soloist' || agent.template_id === 'tmpl_soloist' || agent.templateId === 'tmpl_soloist')) return true;
    return fleets.some((f: any) => (f?.agent_id || f?.agentId) === coordinatorAgentId && String(f?.roles_json || JSON.stringify(f?.roles || ['worker'])).includes('worker'));
  }, [coordinatorAgentId, identitiesData, fleets]);

  // Gap G2: a replacement is recorded as a comment; the last comment's preview
  // is the only place the board sees it without fetching every thread.
  const replacedBy = React.useMemo(() => {
    const out: Record<string, string> = {};
    for (const t of tickets) {
      const link = replacementLinks(String(t.comment_summary?.last_comment_preview || '')).replacedBy;
      if (link) out[t.task_id] = link;
    }
    return out;
  }, [tickets]);

  if (ctx.isLoading && !chain) {
    return (
      <div data-debug-id="taskchain-loading" className="h-full overflow-hidden bg-canvas">
        <TaskBoardSkeleton />
      </div>
    );
  }

  if (ctx.error || !chain) {
    return (
      <div
        data-debug-id="taskchain-error"
        className="m-4 rounded-xl border border-danger/40 bg-danger-soft p-4 text-xs text-danger text-left"
      >
        Failed to load task chain: {String((ctx.error as any)?.message || (ctx.error as any)?.error || ctx.error || 'Not found')}
      </div>
    );
  }

  if (inlineTicket && !onOpenTicket) {
    return (
      <TicketView
        key={inlineTicket.taskId}
        chainId={chainId}
        taskId={inlineTicket.taskId}
        isMobile={isMobile}
        focus={inlineTicket.focus}
        onFocusConsumed={() => setInlineTicket((cur) => (cur ? { taskId: cur.taskId } : cur))}
        onShowBoard={() => setInlineTicket(null)}
        onOpenTicket={(taskId) => setInlineTicket({ taskId })}
        onSwitchTicket={(taskId) => setInlineTicket({ taskId })}
        onOpenAgent={openAgent}
      />
    );
  }

  const currentTasks = tasks.filter((task) => !task.workflow_run_id || workflowRuns.some((run) => run.run_id === task.workflow_run_id && run.execution_no === task.workflow_execution_no));
  const chainIsDraft = String(chain.publishState || chain.publish_state || '').toLowerCase() === 'draft';
  const editingTask = editing ? tasks.find((t) => t.task_id === editing.taskId) || null : null;
  const handlePublishChain = async () => {
    setPublishError('');
    try {
      await publishChain({ chainId, taskTitles: Object.fromEntries(tasks.map((t) => [t.task_id, t.title])) }).unwrap();
    } catch (err) {
      setPublishError(actionErrorMessage(err));
    }
  };

  return (
    <div
      data-debug-id="taskchain-overview-container"
      className="flex h-full w-full flex-col min-w-0 bg-canvas overflow-hidden"
    >
      {!hideTitleBar && (
        <header className="flex shrink-0 items-center justify-between gap-2 border-b border-subtle bg-surface px-4 py-3">
          <div className="flex min-w-0 items-center gap-2">
            <Text as="h2" role="title" truncate>
              {chain.title || 'Untitled chain'}
            </Text>
            <Badge tone="neutral">Mixed work</Badge>
            {chainIsDraft && <Badge tone="neutral">Draft</Badge>}
            {isSolo && (
              <span title="Solo mode: the coordinator works the tickets itself (pulling them one at a time) and you review each one.">
                <Badge tone="info">Solo</Badge>
              </span>
            )}
          </div>
          {onClose && <IconButton icon="close" label="Close task chain" data-debug-id="taskchain-close-btn" variant="ghost" size="sm" onClick={onClose} />}
        </header>
      )}

      <div className="min-h-0 flex-1 overflow-y-auto">
          <TicketBoard
            chainId={chainId}
            tasks={tickets}
            summaryTasks={currentTasks}
            keys={keys}
            names={names}
            machines={machines}
            chainFleets={fleets}
            chainKind={String(chain.kind || '')}
            replacedBy={replacedBy}
            isMobile={isMobile}
            onOpenTicket={openTicket}
            onOpenAgent={openAgent}
            onEditTicket={editTicket}
            onNewTask={() => setShowNewTaskModal(true)}
            onOpenFleetDrawer={() => setShowFleetDrawer(true)}
            onOpenReviewRoles={() => setShowReviewRoles(true)}
            onPublishChain={chainIsDraft ? handlePublishChain : undefined}
            publishingChain={publishChainState.isLoading}
            publishError={publishError}
            hasWorkflowRuns={workflowRuns.length > 0}
            workSlot={
              <div className="flex flex-col gap-4">
                {workflowRunsQuery.error && <Text role="caption" tone="danger">Could not refresh workflows.</Text>}
                {workflowRuns.map((run) => (
                  <section key={run.run_id} data-debug-id={`workflow-run-card-${run.run_id}`} className="min-w-0 rounded-xl border border-subtle bg-surface">
                    <WorkflowRunHeader run={run} />
                    <WorkflowPipelineView
                      chainId={chainId} chain={chain} run={run}
                      tasks={tasks.filter((task) => task.workflow_run_id === run.run_id && task.workflow_execution_no === run.execution_no)}
                      names={names} chainFleets={fleets}
                      expandedTaskId={null} onToggleTask={(taskId) => openTicket(taskId)} onSelectTask={(taskId) => openTicket(taskId)}
                    />
                  </section>
                ))}
              </div>
            }
          />
      </div>

      {/* Create Task Modal */}
      {showNewTaskModal && (
        <CreateTaskModal
          isOpen={showNewTaskModal}
          chainId={chainId}
          existingTasks={tickets}
          onClose={() => setShowNewTaskModal(false)}
          onSuccess={() => setShowNewTaskModal(false)}
        />
      )}

      {editing && editingTask && editing.field === 'requirements' && (
        <RequirementsEditorModal open onClose={() => setEditing(null)} chainId={chainId} task={editingTask} keys={keys} names={names} />
      )}
      {editing && editingTask && editing.field !== 'requirements' && (
        <TaskEditModal chainId={chainId} task={editingTask} field={editing.field} onClose={() => setEditing(null)} tasks={tickets} chainFleets={fleets} names={names} />
      )}

      <ReviewRolesModal chainId={chainId} open={showReviewRoles} onClose={() => setShowReviewRoles(false)} names={names} />

      {/* Fleet Management Drawer */}
      <FleetManagementDrawer
        chainId={chainId}
        isOpen={showFleetDrawer}
        onClose={() => setShowFleetDrawer(false)}
      />
    </div>
  );
};

export default TaskChainOverview;
