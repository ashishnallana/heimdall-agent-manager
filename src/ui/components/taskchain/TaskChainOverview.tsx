import React, { useState, useEffect } from 'react';
import { useFetchTaskChainDetailQuery } from '../../api/endpoints/tasks';
import { useGetTaskChainFleetsQuery } from '../../api/endpoints/taskChains';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { TicketBoardView } from '../tasks/TicketBoardView';
import { WorkflowPipelineView } from '../tasks/WorkflowPipelineView';
import { TaskDetailView } from '../tasks/TaskDetailView';
import { CreateTaskModal } from '../tasks/CreateTaskModal';
import { FleetManagementDrawer } from '../tasks/FleetManagementDrawer';
import { TaskWire } from '../../api/taskWire';
import { useOpenAgentChat } from '../aux/openAgentChatContext';
import { useFetchAgentInstanceQuery, useFetchAgentIdentityQuery } from '../../api/endpoints/agents';
import { useIsMobile } from '../shell/responsive';

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

export function agentInstanceOptionLabel(
  name: string,
  instanceId: string,
  suffix = '',
  runtimeStatus?: string
): string {
  const shortId = instanceId.slice(-6);
  const statusSuffix = runtimeStatus ? ` (${runtimeStatus})` : '';
  return `${name} [${shortId}]${statusSuffix}${suffix}`;
}

export function memberInstanceOptionLabel(role: string, name: string, instanceId: string): string {
  const shortId = instanceId.slice(-6);
  return `${role}: ${name} [${shortId}]`;
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
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(focusTaskId || null);
  const [showNewTaskModal, setShowNewTaskModal] = useState(false);
  const [showFleetDrawer, setShowFleetDrawer] = useState(false);

  useEffect(() => {
    if (focusTaskId) {
      setSelectedTaskId(focusTaskId);
    }
  }, [focusTaskId]);

  const { data: chainDetailData, isLoading: isLoadingChain, error: chainError } =
    useFetchTaskChainDetailQuery({ chainId }, { skip: !chainId });

  const { data: fleetsData } = useGetTaskChainFleetsQuery({ chainId }, { skip: !chainId });
  const { data: bridgesData } = useListBridgesQuery();

  const chain: any = chainDetailData?.chain;
  const tasks: TaskWire[] = chain?.tasks || [];
  const fleets = Array.isArray(fleetsData) ? fleetsData : [];
  const bridges = bridgesData?.bridges || [];

  if (isLoadingChain && !chain) {
    return (
      <div
        data-debug-id="taskchain-loading"
        className="flex h-full items-center justify-center p-6 text-xs text-muted"
      >
        Loading task chain…
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

  const isWorkflow = chain.kind === 'workflow';

  return (
    <div
      data-debug-id="taskchain-overview-container"
      className="flex h-full w-full flex-col min-w-0 bg-canvas overflow-hidden"
    >
      {/* Title bar (if not hidden) */}
      {!hideTitleBar && (
        <header className="flex items-center justify-between border-b border-subtle px-4 py-3 bg-surface shrink-0">
          <div className="flex items-center gap-2 min-w-0">
            <span className="font-bold text-sm text-primary truncate">
              {chain.title || chainId}
            </span>
            <span
              className={`rounded px-1.5 py-0.5 font-mono text-[10px] font-semibold uppercase ${
                isWorkflow ? 'bg-accent-soft text-accent' : 'bg-neutral-soft text-muted'
              }`}
            >
              {chain.kind || 'ticket'}
            </span>
          </div>

          <div className="flex items-center gap-2 shrink-0">
            <button
              type="button"
              onClick={() => setShowFleetDrawer(true)}
              className="rounded border border-subtle bg-surface-raised px-2.5 py-1 text-xs font-semibold text-primary hover:bg-neutral-soft"
            >
              Fleet
            </button>
            <button
              type="button"
              onClick={() => setShowNewTaskModal(true)}
              className="rounded bg-accent px-2.5 py-1 text-xs font-semibold text-accent-fg hover:opacity-90"
            >
              + Task
            </button>
            {onClose && (
              <button
                type="button"
                onClick={onClose}
                className="text-muted hover:text-primary text-sm font-bold ml-1"
              >
                ✕
              </button>
            )}
          </div>
        </header>
      )}

      {/* Main content: Either Detail View or Board/Pipeline View */}
      <div className="flex-1 min-h-0 overflow-y-auto">
        {selectedTaskId ? (
          <TaskDetailView
            chainId={chainId}
            taskId={selectedTaskId}
            tasks={tasks}
            onClose={() => setSelectedTaskId(null)}
            onSelectTask={(id) => setSelectedTaskId(id)}
            chainFleets={fleets}
          />
        ) : isWorkflow ? (
          <WorkflowPipelineView
            chainId={chainId}
            chain={chain}
            tasks={tasks}
            selectedTaskId={selectedTaskId}
            onSelectTask={(id) => setSelectedTaskId(id)}
          />
        ) : (
          <TicketBoardView
            chainId={chainId}
            tasks={tasks}
            chainFleets={fleets}
            bridges={bridges}
            selectedTaskId={selectedTaskId}
            onSelectTask={(id) => setSelectedTaskId(id)}
            onNewTask={() => setShowNewTaskModal(true)}
            onOpenFleetDrawer={() => setShowFleetDrawer(true)}
            summaryText={chain.summary}
          />
        )}
      </div>

      {/* Create Task Modal */}
      {showNewTaskModal && (
        <CreateTaskModal
          isOpen={showNewTaskModal}
          chainId={chainId}
          onClose={() => setShowNewTaskModal(false)}
          onSuccess={() => setShowNewTaskModal(false)}
        />
      )}

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
