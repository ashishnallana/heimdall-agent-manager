import React, { useMemo } from 'react';
import { useSelector } from 'react-redux';
import { Badge, Icon } from '@ui';
import { useFetchTaskChainDetailQuery } from '../../api/endpoints/tasks';
import { useListShellsQuery } from '../../api/endpoints/shells';
import { useGetAgentsLiveQuery } from '../../api/endpoints/agentsLive';
import {
  WORKBENCH_SURFACE_REGISTRY,
  type WorkbenchSurfaceKind,
  type WorkbenchTabState,
} from '../../store/workbenchTabId';
import { supportsLivePreview, shellTitle } from '../shells/shellModel';
import { WORKBENCH_SURFACE_ICONS } from './WorkbenchTabStrip';

export interface WorkbenchNewTabLauncherProps {
  paneId: string;
  primaryAgentInstanceId: string;
  chainId?: string;
  projectId?: string;
  bridgeId?: string;
  projectVcsEnabled?: boolean;
  onSelectSurface: (tab: Partial<WorkbenchTabState> & { kind: WorkbenchSurfaceKind }) => void;
}

const LAUNCHER_SURFACE_ORDER: WorkbenchSurfaceKind[] = [
  'agentChat',
  'agentPty',
  'shell',
  'preview',
  'files',
  'vcs',
  'chainOverview',
  'tasks',
];

interface WorkbenchNewTabLauncherBodyProps extends WorkbenchNewTabLauncherProps {
  chainData?: any;
  liveAgentsData?: any;
  shellsData?: any;
}

function WorkbenchNewTabLauncherWithApi(props: WorkbenchNewTabLauncherProps) {
  const { chainId, bridgeId } = props;
  const { data: chainData } = useFetchTaskChainDetailQuery(
    { chainId: chainId || '' },
    { skip: !chainId },
  );
  const { data: liveAgentsData } = useGetAgentsLiveQuery();
  const { data: shellsData } = useListShellsQuery(
    {
      chainId: chainId || undefined,
      bridgeId: bridgeId || undefined,
      status: 'live',
    },
    { skip: !chainId && !bridgeId },
  );

  return (
    <WorkbenchNewTabLauncherBody
      {...props}
      chainData={chainData}
      liveAgentsData={liveAgentsData}
      shellsData={shellsData}
    />
  );
}

export function WorkbenchNewTabLauncher(props: WorkbenchNewTabLauncherProps) {
  const hasApiStore = useSelector((state: any) => Boolean(state?.heimdallApi));
  if (hasApiStore) {
    return <WorkbenchNewTabLauncherWithApi {...props} />;
  }
  return <WorkbenchNewTabLauncherBody {...props} />;
}

function WorkbenchNewTabLauncherBody({
  paneId,
  primaryAgentInstanceId,
  chainId,
  projectId,
  onSelectSurface,
  chainData,
  liveAgentsData,
  shellsData,
}: WorkbenchNewTabLauncherBodyProps) {

  const chainMembers: any[] = useMemo(() => chainData?.chain?.members || [], [chainData]);
  const liveAgents: any[] = useMemo(
    () =>
      (liveAgentsData || []).flatMap((p) =>
        (p.chains || []).flatMap((c) => c.liveAgents || []),
      ),
    [liveAgentsData],
  );
  const liveSessions = useMemo(() => shellsData?.sessions || [], [shellsData]);
  const previewableServers = useMemo(
    () => liveSessions.filter((s) => supportsLivePreview(s)),
    [liveSessions],
  );

  const handleLaunchKind = (kind: WorkbenchSurfaceKind) => {
    const meta = WORKBENCH_SURFACE_REGISTRY[kind];
    if (kind === 'agentChat') {
      onSelectSurface({
        kind: 'agentChat',
        agentInstanceId: primaryAgentInstanceId,
        title: meta.defaultTitle({ agentInstanceId: primaryAgentInstanceId }),
      });
      return;
    }
    if (kind === 'agentPty') {
      onSelectSurface({
        kind: 'agentPty',
        agentInstanceId: primaryAgentInstanceId,
        title: meta.defaultTitle({ agentInstanceId: primaryAgentInstanceId }),
      });
      return;
    }
    if (kind === 'shell') {
      const firstShell = liveSessions[0];
      onSelectSurface({
        kind: 'shell',
        sessionId: firstShell?.session_id,
        title: firstShell
          ? shellTitle(firstShell)
          : meta.defaultTitle({ sessionId: undefined }),
      });
      return;
    }
    if (kind === 'preview') {
      const firstServer = previewableServers[0];
      onSelectSurface({
        kind: 'preview',
        sessionId: firstServer?.session_id || 'default',
        port: firstServer?.server_port,
        title: firstServer
          ? `${shellTitle(firstServer)} :${firstServer.server_port}`
          : meta.defaultTitle({ sessionId: 'default' }),
      });
      return;
    }
    onSelectSurface({
      kind,
      title: meta.defaultTitle({}),
    });
  };

  return (
    <div
      data-debug-id={`workbench-new-tab-launcher-${paneId}`}
      className="flex h-full min-h-0 w-full flex-col items-center justify-start overflow-y-auto bg-canvas p-6 text-primary"
    >
      <div className="w-full max-w-2xl space-y-6">
        <div className="space-y-1 text-center">
          <h3 className="text-sm font-bold text-primary">Open a Workbench Surface</h3>
          <p className="text-xs text-muted">
            Choose a surface to open in this pane, or drag any tab to split the 2D workbench.
          </p>
        </div>

        {/* All 8 Surface Types Grid */}
        <div
          data-debug-id="workbench-launcher-surface-grid"
          className="grid grid-cols-1 gap-2.5 sm:grid-cols-2"
        >
          {LAUNCHER_SURFACE_ORDER.map((kind) => {
            const meta = WORKBENCH_SURFACE_REGISTRY[kind];
            const iconName = WORKBENCH_SURFACE_ICONS[kind] || 'file';
            const disabled =
              ((kind === 'chainOverview' || kind === 'tasks') && !chainId) ||
              ((kind === 'files' || kind === 'vcs') && !projectId && !primaryAgentInstanceId);

            return (
              <button
                key={kind}
                type="button"
                disabled={disabled}
                data-debug-id={`workbench-launcher-card-${kind}`}
                onClick={() => handleLaunchKind(kind)}
                className="flex items-start gap-3 rounded-xl border border-subtle bg-surface p-3 text-left transition-all hover:border-accent/50 hover:bg-surface-raised disabled:cursor-not-allowed disabled:opacity-50"
              >
                <div className="grid h-8 w-8 shrink-0 place-items-center rounded-lg bg-accent/10 text-accent">
                  <Icon name={iconName} size={16} />
                </div>
                <div className="min-w-0 flex-1">
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-xs font-semibold text-primary">{meta.label}</span>
                    {!meta.multiInstance ? (
                      <Badge tone="neutral">Singleton</Badge>
                    ) : null}
                  </div>
                  <p className="mt-0.5 text-[11px] text-muted line-clamp-2">
                    {meta.description}
                  </p>
                </div>
              </button>
            );
          })}
        </div>

        {/* Chain Agents Quick Pick (Chat or PTY) — restricted to chain participants when in a chain */}
        {(chainMembers.length > 0 || (!chainId && liveAgents.length > 0)) ? (
          <div className="space-y-2">
            <h4 className="text-[11px] font-semibold uppercase tracking-wider text-muted">
              {chainId ? 'Chain Agents (Chat or Interactive PTY)' : 'Agents (Chat or Interactive PTY)'}
            </h4>
            <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
              {(chainId ? chainMembers : liveAgents.slice(0, 6)).map((agent: any) => {
                const instId = String(agent.agentInstanceId || agent.agent_instance_id || '');
                if (!instId) return null;
                const name = String(agent.displayName || agent.display_name || instId);
                return (
                  <div
                    key={instId}
                    data-debug-id={`workbench-launcher-agent-${instId}`}
                    className="flex items-center justify-between gap-2 rounded-lg border border-subtle bg-surface px-3 py-2"
                  >
                    <span className="truncate text-xs font-medium text-primary" title={name}>
                      {name}
                    </span>
                    <div className="flex shrink-0 items-center gap-1">
                      <button
                        type="button"
                        data-debug-id={`workbench-launcher-agent-chat-${instId}`}
                        onClick={() =>
                          onSelectSurface({
                            kind: 'agentChat',
                            agentInstanceId: instId,
                            title: name,
                          })
                        }
                        className="rounded border border-subtle bg-surface-raised px-2 py-0.5 text-[11px] font-medium text-primary hover:border-accent hover:text-accent"
                      >
                        Chat
                      </button>
                      <button
                        type="button"
                        data-debug-id={`workbench-launcher-agent-pty-${instId}`}
                        onClick={() =>
                          onSelectSurface({
                            kind: 'agentPty',
                            agentInstanceId: instId,
                            title: `${name} PTY`,
                          })
                        }
                        className="rounded border border-subtle bg-surface-raised px-2 py-0.5 text-[11px] font-medium text-primary hover:border-accent hover:text-accent"
                      >
                        PTY
                      </button>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
        ) : null}

        {/* Active Preview Servers Quick Pick */}
        {previewableServers.length > 0 ? (
          <div className="space-y-2">
            <h4 className="text-[11px] font-semibold uppercase tracking-wider text-muted">
              Active Server Previews
            </h4>
            <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
              {previewableServers.map((srv) => (
                <button
                  key={srv.session_id}
                  type="button"
                  data-debug-id={`workbench-launcher-preview-${srv.session_id}`}
                  onClick={() =>
                    onSelectSurface({
                      kind: 'preview',
                      sessionId: srv.session_id,
                      port: srv.server_port,
                      title: `${shellTitle(srv)} :${srv.server_port}`,
                    })
                  }
                  className="flex items-center justify-between rounded-lg border border-subtle bg-surface px-3 py-2 text-left hover:border-accent/50"
                >
                  <span className="truncate text-xs font-medium text-primary">
                    {shellTitle(srv)}
                  </span>
                  <Badge tone="info">:{srv.server_port}</Badge>
                </button>
              ))}
            </div>
          </div>
        ) : null}
      </div>
    </div>
  );
}

export default WorkbenchNewTabLauncher;
