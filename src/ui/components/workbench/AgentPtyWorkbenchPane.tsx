import React, { useCallback, useMemo, useState } from 'react';
import {
  useFetchAgentInstanceQuery,
  useStartInstanceMutation,
  useStopAgentInstanceMutation,
  useRestartAgentInstanceMutation,
} from '../../api/endpoints/agents';
import { useGetAgentsLiveQuery } from '../../api/endpoints/agentsLive';
import AgentPaneComposerPanel from '../chat/AgentPaneComposerPanel';
import { useAuxTabActions, type AuxTabAction } from '../aux/auxTabActions';

export interface AgentPtyWorkbenchPaneProps {
  agentInstanceId: string;
  isActiveTab?: boolean;
}

/**
 * Agent PTY aux tab: the live terminal ONLY. The agent comes from the tab
 * content, its status shows as a dot on the tab, and start / restart / stop
 * live in the aux ⋮ menu.
 */
export function AgentPtyWorkbenchPane({
  agentInstanceId,
  isActiveTab = true,
}: AgentPtyWorkbenchPaneProps) {
  const { data: instanceData, refetch } = useFetchAgentInstanceQuery(
    { instanceId: agentInstanceId },
    { skip: !agentInstanceId, pollingInterval: 10000 },
  );
  const { data: liveData } = useGetAgentsLiveQuery();

  const instance = instanceData?.instance;
  const [startInstance] = useStartInstanceMutation();
  const [stopInstance] = useStopAgentInstanceMutation();
  const [restartInstance] = useRestartAgentInstanceMutation();
  const [actionBusy, setActionBusy] = useState<'start' | 'stop' | 'restart' | null>(null);

  const liveAgent = useMemo(() => {
    const allLive = (liveData || []).flatMap((p) =>
      (p.chains || []).flatMap((c) => c.liveAgents || []),
    );
    return allLive.find((a) => a.agentInstanceId === agentInstanceId);
  }, [liveData, agentInstanceId]);

  const rawStatus = String(
    liveAgent?.runtimeStatus || instance?.runtime_status || instance?.runtimeStatus || 'running',
  ).toLowerCase();
  const agentId = String(instance?.agent_id || instance?.agentId || '');
  const isStopped = rawStatus === 'stopped' || rawStatus === 'failed';
  const isStarting = actionBusy === 'start' || rawStatus === 'starting';

  const run = useCallback(
    async (kind: 'start' | 'stop' | 'restart') => {
      if (!agentInstanceId || actionBusy) return;
      setActionBusy(kind);
      try {
        if (kind === 'start') await startInstance(agentInstanceId);
        else if (kind === 'stop') await stopInstance({ instanceId: agentInstanceId, agentId });
        else await restartInstance({ instanceId: agentInstanceId, agentId });
        refetch();
      } finally {
        setActionBusy(null);
      }
    },
    [actionBusy, agentId, agentInstanceId, refetch, restartInstance, startInstance, stopInstance],
  );

  const actions: AuxTabAction[] = isStopped
    ? [{ id: 'pty-start', label: 'Start agent', icon: 'play', disabled: Boolean(actionBusy), onSelect: () => void run('start') }]
    : [
        { id: 'pty-restart', label: 'Restart agent', icon: 'refresh', disabled: Boolean(actionBusy), onSelect: () => void run('restart') },
        { id: 'pty-stop', label: 'Stop agent', icon: 'stop', tone: 'danger', disabled: Boolean(actionBusy), onSelect: () => void run('stop') },
      ];
  useAuxTabActions(actions);

  return (
    <div
      data-debug-id={`workbench-agent-pty-pane-${agentInstanceId}`}
      className="relative flex h-full min-h-0 w-full flex-1 flex-col overflow-hidden bg-surface text-primary"
    >
      <AgentPaneComposerPanel
        agentInstanceId={agentInstanceId}
        isExpanded={true}
        isActiveTab={isActiveTab}
        runtimeStatus={rawStatus}
        isStarting={isStarting}
        runCount={instance?.run_count}
        startedAt={instance?.started_at}
        fillPane={true}
        hideHeader={true}
        className="h-full w-full flex-1 min-h-0"
      />
    </div>
  );
}

export default AgentPtyWorkbenchPane;
