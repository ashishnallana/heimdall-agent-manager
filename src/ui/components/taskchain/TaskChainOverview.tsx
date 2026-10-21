import React, { useState, useEffect } from 'react';
import { Badge, Button, IconButton, Text } from '@ui';
import { useFetchTaskChainDetailQuery, usePublishTaskChainMutation } from '../../api/endpoints/tasks';
import { useGetTaskChainFleetsQuery } from '../../api/endpoints/taskChains';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { TicketBoardView } from '../tasks/TicketBoardView';
import { VaultText } from '../vault/VaultText';
import { WorkflowPipelineView } from '../tasks/WorkflowPipelineView';
import { useFetchChainWorkflowRunsQuery } from '../../api/endpoints/workflowRuns';
import { CreateTaskModal } from '../tasks/CreateTaskModal';
import { TaskBoardSkeleton } from '../tasks/TaskBoardSkeleton';
import { FleetManagementDrawer } from '../tasks/FleetManagementDrawer';
import { ReviewRolesModal } from '../tasks/ReviewRolesModal';
import { TaskWire } from '../../api/taskWire';
import { resolveSelectedTaskId } from '../tasks/taskV2Types';
import { useOpenAgentChat } from '../auxiliary/openAgentChatContext';
import { useFetchAgentInstanceQuery, useFetchAgentIdentityQuery, useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { buildTaskNames } from '../tasks/taskNames';
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
}) => {
  // The card expanded inline (plan REQ-UI-8). A deep link to a task expands it.
  const [expandedTaskId, setExpandedTaskId] = useState<string | null>(focusTaskId || null);
  const [showNewTaskModal, setShowNewTaskModal] = useState(false);
  const [showFleetDrawer, setShowFleetDrawer] = useState(false);
  const [showReviewRoles, setShowReviewRoles] = useState(false);
  const [publishChain, publishChainState] = usePublishTaskChainMutation();
  const [publishError, setPublishError] = useState('');

  // The card scrolls itself into view once mounted (TaskCard scrollIntoView), so
  // this also works on a cold deep link while the chain is still loading.
  const [scrollTaskId, setScrollTaskId] = useState<string | null>(focusTaskId || null);
  const clearScroll = React.useCallback(() => setScrollTaskId(null), []);
  const expandTask = (taskId: string) => {
    setExpandedTaskId(taskId);
    setScrollTaskId(taskId);
  };
  const toggleTask = (taskId: string) => setExpandedTaskId((cur) => (cur === taskId ? null : taskId));

  useEffect(() => {
    if (focusTaskId) expandTask(focusTaskId);
  }, [focusTaskId]);

  const { data: chainDetailData, isLoading: isLoadingChain, error: chainError } =
    useFetchTaskChainDetailQuery({ chainId }, { skip: !chainId });

  const workflowRunsQuery = useFetchChainWorkflowRunsQuery({ chainId }, {
    skip: !chainId,
    pollingInterval: 5000,
    skipPollingIfUnfocused: true,
    refetchOnReconnect: true,
  });
  const workflowRuns = workflowRunsQuery.currentData?.runs || [];

  const { data: fleetsData } = useGetTaskChainFleetsQuery({ chainId }, { skip: !chainId });
  const { data: bridgesData } = useListBridgesQuery();

  const chain: any = chainDetailData?.chain;
  const tasks: TaskWire[] = chain?.tasks || [];
  const fleets = Array.isArray(fleetsData) ? fleetsData : [];
  const bridges = bridgesData?.bridges || [];
  const { data: identitiesData } = useListAgentIdentitiesQuery();
  // Solo mode (Task System v2): the coordinator also does the work — it is the
  // built-in Soloist, or its own agent has a worker row in the fleet.
  const coordinatorId = String(chain?.coordinator_agent_instance_id || chain?.coordinatorAgentInstanceId || '');
  const { data: coordinatorData } = useFetchAgentInstanceQuery({ instanceId: coordinatorId }, { skip: !coordinatorId });
  const coordinatorAgentId = String((coordinatorData as any)?.instance?.agent_id || (coordinatorData as any)?.instance?.agentId || '');
  const isSolo = React.useMemo(() => {
    if (!coordinatorAgentId) return false;
    const agent: any = (identitiesData?.agents || []).find((a: any) => (a?.agent_id || a?.agentId) === coordinatorAgentId);
    if (agent && (agent.slug === 'soloist' || agent.template_id === 'tmpl_soloist' || agent.templateId === 'tmpl_soloist')) return true;
    return fleets.some((f: any) => (f?.agent_id || f?.agentId) === coordinatorAgentId && String(f?.roles_json || JSON.stringify(f?.roles || ['worker'])).includes('worker'));
  }, [coordinatorAgentId, identitiesData, fleets]);
  // One names resolver per chain view (plan REQ-UI-4): cards, board, pipeline and
  // detail all show titles / agent names / bridge labels instead of raw ids.
  const names = React.useMemo(
    () =>
      buildTaskNames({
        tasks,
        members: chain?.members || [],
        bridges,
        identities: identitiesData?.agents || [],
      }),
    [tasks, chain?.members, bridges, identitiesData],
  );

  if (isLoadingChain && !chain) {
    return (
      <div data-debug-id="taskchain-loading" className="h-full overflow-hidden bg-canvas">
        <TaskBoardSkeleton />
      </div>
    );
  }

  if (chainError || !chain) {
    return (
      <div
        data-debug-id="taskchain-error"
        className="m-4 rounded-xl border border-danger/40 bg-danger-soft p-4 text-xs text-danger text-left"
      >
        Failed to load task chain: {String((chainError as any)?.message || chainError || 'Not found')}
      </div>
    );
  }

  const tickets = tasks.filter((task) => !task.workflow_run_id);
  const currentTasks = tasks.filter((task) => !task.workflow_run_id || workflowRuns.some((run) => run.run_id === task.workflow_run_id && run.execution_no === task.workflow_execution_no));
  const openTaskId = resolveSelectedTaskId(expandedTaskId, tasks, Boolean(chain));
  const chainIsDraft = String(chain.publishState || chain.publish_state || '').toLowerCase() === 'draft';
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
              <span title="Solo mode: the coordinator works the tasks itself (pulling them one at a time) and you review each one.">
                <Badge tone="info">Solo</Badge>
              </span>
            )}
          </div>
          {onClose && <IconButton icon="close" label="Close task chain" data-debug-id="taskchain-close-btn" variant="ghost" size="sm" onClick={onClose} />}
        </header>
      )}

      <div className="min-h-0 flex-1 overflow-y-auto">
          <TicketBoardView
            chainId={chainId}
            tasks={tickets}
            summaryTasks={currentTasks}
            names={names}
            chainFleets={fleets}
            expandedTaskId={openTaskId}
            onToggleTask={toggleTask}
            onSelectTask={expandTask}
            scrollTaskId={scrollTaskId}
            onScrolled={clearScroll}
            onNewTask={() => setShowNewTaskModal(true)}
            onOpenFleetDrawer={() => setShowFleetDrawer(true)}
            onOpenReviewRoles={() => setShowReviewRoles(true)}
            onPublishChain={chainIsDraft ? handlePublishChain : undefined}
            publishingChain={publishChainState.isLoading}
            publishError={publishError}
            summaryText={chain.summary}
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
                      expandedTaskId={openTaskId} onToggleTask={toggleTask} onSelectTask={expandTask}
                      scrollTaskId={scrollTaskId} onScrolled={clearScroll}
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
