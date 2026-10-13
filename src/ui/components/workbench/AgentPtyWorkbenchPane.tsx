import React, { useCallback, useMemo, useState } from 'react';
import { useDispatch } from 'react-redux';
import { Badge, Button, Icon, Spinner, StatusDot, StatusPill, type Tone } from '@ui';
import {
  useFetchAgentInstanceQuery,
  useStartInstanceMutation,
  useStopAgentInstanceMutation,
  useRestartAgentInstanceMutation,
} from '../../api/endpoints/agents';
import { useGetAgentsLiveQuery } from '../../api/endpoints/agentsLive';
import { useListAllChatConversationsQuery } from '../../api/endpoints/chats';
import { useFetchTaskChainDetailQuery } from '../../api/endpoints/tasks';
import { openOrFocusWorkbenchTab } from '../../store/workbenchSlice';
import AgentPaneComposerPanel from '../chat/AgentPaneComposerPanel';

export interface AgentPtyWorkbenchPaneProps {
  agentInstanceId: string;
  title?: string;
  workspaceKey?: string;
  paneId?: string;
  chainId?: string | null;
  projectId?: string | null;
  members?: any[];
  isActiveTab?: boolean;
  onSelectAgentInstance?: (agentInstanceId: string, title?: string) => void;
  onOpenChat?: (agentInstanceId: string) => void;
  onClose?: () => void;
}

function ptyStatusTone(status: string): Tone {
  const s = String(status || '').toLowerCase();
  if (s === 'running' || s === 'live' || s === 'ready' || s === 'idle') return 'success';
  if (s === 'starting') return 'info';
  if (s === 'stopped' || s === 'failed') return 'danger';
  return 'neutral';
}

export function AgentPtyWorkbenchPane({
  agentInstanceId,
  title,
  chainId,
  projectId,
  members,
  isActiveTab = true,
  onSelectAgentInstance,
  onOpenChat,
}: AgentPtyWorkbenchPaneProps) {
  const dispatch = useDispatch();
  const { data: instanceData, refetch } = useFetchAgentInstanceQuery(
    { instanceId: agentInstanceId },
    { skip: !agentInstanceId, pollingInterval: 10000 },
  );
  const { data: liveData } = useGetAgentsLiveQuery();
  const { data: conversationsData } = useListAllChatConversationsQuery({ limit: 50 });

  const instance = instanceData?.instance;
  const effectiveChainId = String(
    chainId || instance?.chain_id || instance?.chainId || '',
  );
  const { data: chainData } = useFetchTaskChainDetailQuery(
    { chainId: effectiveChainId },
    { skip: !effectiveChainId },
  );

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
    liveAgent?.runtimeStatus ||
      instance?.runtime_status ||
      instance?.runtimeStatus ||
      'running',
  ).toLowerCase();

  const displayName =
    title ||
    instance?.display_name ||
    instance?.displayName ||
    liveAgent?.displayName ||
    agentInstanceId;

  const agentId = String(instance?.agent_id || instance?.agentId || '');
  const isStopped = rawStatus === 'stopped' || rawStatus === 'failed';
  const isStarting = actionBusy === 'start' || rawStatus === 'starting';

  const selectableAgents = useMemo(() => {
    const seen = new Set<string>();
    const options: Array<{ id: string; label: string; role?: string }> = [];

    const addOption = (idRaw: unknown, labelRaw: unknown, roleRaw?: unknown) => {
      const id = String(idRaw || '').trim();
      if (!id || seen.has(id)) return;
      seen.add(id);
      const cleanLabel = String(labelRaw || id)
        .replace(/\s+PTY$/i, '')
        .trim() || id;
      const role = String(roleRaw || '').trim();
      options.push({ id, label: cleanLabel, ...(role ? { role } : {}) });
    };

    // Always include current agentInstanceId first so <select value={agentInstanceId}> matches
    addOption(agentInstanceId, displayName, instance?.role);

    for (const m of members || []) {
      addOption(
        m?.agentInstanceId || m?.agent_instance_id,
        m?.displayName || m?.display_name || m?.agentId || m?.agent_id,
        m?.role,
      );
    }

    for (const m of chainData?.chain?.members || []) {
      addOption(
        m?.agentInstanceId || m?.agent_instance_id,
        m?.displayName || m?.display_name || m?.agentId || m?.agent_id,
        m?.role,
      );
    }

    // Within a task chain, only chain participants may be selected.
    if (chainId) return options;

    for (const p of liveData || []) {
      if (projectId && p?.projectId && p.projectId !== projectId) continue;
      for (const c of p?.chains || []) {
        for (const a of c?.liveAgents || []) {
          addOption(a?.agentInstanceId, a?.displayName || a?.agentInstanceId);
        }
      }
    }

    const convRows = Array.isArray(conversationsData)
      ? conversationsData
      : conversationsData?.data || [];
    for (const row of convRows) {
      if (
        projectId &&
        (row?.project_id || row?.projectId) &&
        String(row?.project_id || row?.projectId) !== projectId
      ) {
        continue;
      }
      addOption(
        row?.agent_instance_id || row?.agentInstanceId,
        row?.title || row?.agent_id || row?.agentId,
      );
    }

    return options;
  }, [
    agentInstanceId,
    chainData?.chain?.members,
    chainId,
    conversationsData,
    displayName,
    instance?.role,
    liveData,
    members,
    projectId,
  ]);

  const handleSelectAgentChange = useCallback(
    (e: React.ChangeEvent<HTMLSelectElement>) => {
      const nextId = e.target.value;
      if (!nextId || nextId === agentInstanceId) return;
      const selected = selectableAgents.find((item) => item.id === nextId);
      const nextTitle = selected?.label ? `${selected.label} PTY` : `${nextId} PTY`;
      if (onSelectAgentInstance) {
        onSelectAgentInstance(nextId, nextTitle);
      } else {
        dispatch(
          openOrFocusWorkbenchTab({
            tab: {
              kind: 'agentPty',
              agentInstanceId: nextId,
              title: nextTitle,
            },
          }),
        );
      }
    },
    [agentInstanceId, dispatch, onSelectAgentInstance, selectableAgents],
  );

  const handleStart = useCallback(async () => {
    if (!agentInstanceId || actionBusy) return;
    setActionBusy('start');
    try {
      await startInstance(agentInstanceId);
      refetch();
    } finally {
      setActionBusy(null);
    }
  }, [agentInstanceId, actionBusy, startInstance, refetch]);

  const handleStop = useCallback(async () => {
    if (!agentInstanceId || actionBusy) return;
    setActionBusy('stop');
    try {
      await stopInstance({ instanceId: agentInstanceId, agentId });
      refetch();
    } finally {
      setActionBusy(null);
    }
  }, [agentInstanceId, agentId, actionBusy, stopInstance, refetch]);

  const handleRestart = useCallback(async () => {
    if (!agentInstanceId || actionBusy) return;
    setActionBusy('restart');
    try {
      await restartInstance({ instanceId: agentInstanceId, agentId });
      refetch();
    } finally {
      setActionBusy(null);
    }
  }, [agentInstanceId, agentId, actionBusy, restartInstance, refetch]);

  const handleOpenChatClick = useCallback(() => {
    if (onOpenChat) {
      onOpenChat(agentInstanceId);
    } else {
      dispatch(
        openOrFocusWorkbenchTab({
          tab: {
            kind: 'agentChat',
            agentInstanceId,
            title: displayName,
          },
        }),
      );
    }
  }, [agentInstanceId, dispatch, displayName, onOpenChat]);

  return (
    <div
      data-debug-id={`workbench-agent-pty-pane-${agentInstanceId}`}
      className="flex h-full min-h-0 w-full flex-col overflow-hidden bg-surface text-primary"
    >
      {/* Compact PTY Pane Header */}
      <div
        data-debug-id="workbench-agent-pty-header"
        className="flex h-9 shrink-0 items-center justify-between gap-2 border-b border-subtle bg-surface-raised/60 px-3"
      >
        <div className="flex min-w-0 items-center gap-2">
          <StatusDot tone={ptyStatusTone(rawStatus)} label={rawStatus} size="sm" />
          <select
            data-debug-id="workbench-agent-pty-selector"
            aria-label="Select agent instance for terminal"
            value={agentInstanceId}
            onChange={handleSelectAgentChange}
            className="max-w-[200px] truncate rounded border border-subtle bg-surface px-1.5 py-0.5 text-xs font-semibold text-primary focus:border-accent focus:outline-none"
          >
            {selectableAgents.map((opt) => (
              <option key={opt.id} value={opt.id}>
                {opt.role ? `${opt.label} (${opt.role})` : opt.label}
              </option>
            ))}
          </select>
          <span className="sr-only truncate text-xs font-semibold text-primary" title={displayName}>
            {displayName}
          </span>
          {agentId ? <Badge tone="neutral">{agentId}</Badge> : null}
          <StatusPill tone={ptyStatusTone(rawStatus)}>{rawStatus}</StatusPill>
        </div>

        <div className="flex shrink-0 items-center gap-1.5">
          <button
            type="button"
            data-debug-id="workbench-agent-pty-open-chat"
            onClick={handleOpenChatClick}
            title="Open Agent Chat tab"
            className="inline-flex items-center gap-1 rounded border border-subtle bg-surface px-2 py-0.5 text-[11px] font-medium text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name="chat" size={12} />
            <span>Chat</span>
          </button>

          {isStopped ? (
            <Button
              size="sm"
              variant="primary"
              disabled={Boolean(actionBusy)}
              data-debug-id="workbench-agent-pty-start-btn"
              onClick={() => void handleStart()}
            >
              {actionBusy === 'start' ? <Spinner size="sm" /> : <Icon name="play" size={12} />}
              <span>Start</span>
            </Button>
          ) : (
            <>
              <button
                type="button"
                disabled={Boolean(actionBusy)}
                data-debug-id="workbench-agent-pty-restart-btn"
                onClick={() => void handleRestart()}
                title="Restart Agent"
                aria-label="Restart Agent"
                className="grid h-6 w-6 place-items-center rounded border border-subtle bg-surface text-muted transition-colors hover:bg-neutral-soft hover:text-primary disabled:opacity-50"
              >
                {actionBusy === 'restart' ? <Spinner size="sm" /> : <Icon name="refresh" size={12} />}
              </button>
              <button
                type="button"
                disabled={Boolean(actionBusy)}
                data-debug-id="workbench-agent-pty-stop-btn"
                onClick={() => void handleStop()}
                title="Stop Agent"
                aria-label="Stop Agent"
                className="grid h-6 w-6 place-items-center rounded border border-subtle bg-surface text-muted transition-colors hover:bg-danger-soft hover:text-danger disabled:opacity-50"
              >
                {actionBusy === 'stop' ? <Spinner size="sm" /> : <Icon name="stop" size={12} />}
              </button>
            </>
          )}
        </div>
      </div>

      {/* Full-Height Interactive xterm Body */}
      <div className="relative flex flex-1 min-h-0 w-full flex-col overflow-hidden">
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
    </div>
  );
}

export default AgentPtyWorkbenchPane;
