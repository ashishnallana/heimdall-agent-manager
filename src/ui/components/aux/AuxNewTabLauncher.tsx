import React, { useMemo } from 'react';
import { useSelector } from 'react-redux';
import { Badge, Icon } from '@ui';
import { useListShellsQuery } from '../../api/endpoints/shells';
import {
  AUX_TAB_REGISTRY,
  newShellTabContent,
  type AuxContent,
  type AuxTabKind,
} from '../../store/auxTabId';
import { supportsLivePreview, shellTitle } from '../shells/shellModel';
import { AUX_TAB_ICONS } from './AuxTabStrip';

export interface AuxLauncherMember {
  agentInstanceId: string;
  displayName?: string;
  role?: string;
}

export interface AuxNewTabLauncherProps {
  treeKey: string;
  /** The agent that owns the strip (the focused Main pane's agent). */
  ownerAgentId: string;
  chainId?: string;
  projectId?: string;
  bridgeId?: string;
  projectVcsEnabled?: boolean;
  /** Participants of the owner's task chain (sub-agent chat targets). */
  members?: AuxLauncherMember[];
  onSelect: (content: AuxContent, title?: string) => void;
}

const LAUNCHER_ORDER: AuxTabKind[] = [
  'chainOverview',
  'files',
  'vcs',
  'tasks',
  'shell',
  'agentPty',
  'preview',
];

interface BodyProps extends AuxNewTabLauncherProps {
  shellsData?: any;
}

function AuxNewTabLauncherWithApi(props: AuxNewTabLauncherProps) {
  const { chainId, bridgeId } = props;
  const { data: shellsData } = useListShellsQuery(
    { chainId: chainId || undefined, bridgeId: bridgeId || undefined, status: 'live' },
    { skip: !chainId && !bridgeId },
  );
  return <AuxNewTabLauncherBody {...props} shellsData={shellsData} />;
}

/** The `+` (NEW_TAB_ID) launcher of the aux strip. */
export function AuxNewTabLauncher(props: AuxNewTabLauncherProps) {
  const hasApiStore = useSelector((state: any) => Boolean(state?.heimdallApi));
  return hasApiStore ? <AuxNewTabLauncherWithApi {...props} /> : <AuxNewTabLauncherBody {...props} />;
}

function AuxNewTabLauncherBody({
  treeKey,
  ownerAgentId,
  chainId,
  projectId,
  members = [],
  onSelect,
  shellsData,
}: BodyProps) {
  const previewable = useMemo(
    () => ((shellsData?.sessions || []) as any[]).filter((s) => supportsLivePreview(s)),
    [shellsData],
  );
  const subAgents = useMemo(
    () => (chainId ? members.filter((m) => m.agentInstanceId && m.agentInstanceId !== ownerAgentId) : []),
    [chainId, members, ownerAgentId],
  );

  const launch = (kind: AuxTabKind) => {
    switch (kind) {
      case 'shell':
        onSelect(newShellTabContent());
        return;
      case 'agentPty':
        onSelect({ type: 'agentPty', agentInstanceId: ownerAgentId });
        return;
      case 'preview': {
        const first = previewable[0];
        if (first) {
          onSelect(
            { type: 'preview', sessionId: first.session_id, port: first.server_port },
            `${shellTitle(first)} :${first.server_port}`,
          );
        }
        return;
      }
      case 'chainOverview':
        onSelect({ type: 'chainOverview' });
        return;
      case 'files':
      case 'vcs':
      case 'tasks':
        onSelect({ type: kind } as AuxContent);
        return;
      default:
        return;
    }
  };

  return (
    <div
      data-debug-id={`aux-new-tab-launcher-${treeKey}`}
      className="flex h-full min-h-0 w-full flex-col items-center justify-start overflow-y-auto bg-canvas p-5 text-primary"
    >
      <div className="w-full max-w-xl space-y-5">
        <div data-debug-id="aux-launcher-surface-grid" className="grid grid-cols-1 gap-2 sm:grid-cols-2">
          {LAUNCHER_ORDER.map((kind) => {
            const meta = AUX_TAB_REGISTRY[kind];
            const disabled =
              ((kind === 'chainOverview' || kind === 'tasks') && !chainId) ||
              ((kind === 'files' || kind === 'vcs') && !projectId && !ownerAgentId) ||
              (kind === 'agentPty' && !ownerAgentId) ||
              (kind === 'preview' && previewable.length === 0);
            return (
              <button
                key={kind}
                type="button"
                disabled={disabled}
                data-debug-id={`aux-launcher-card-${kind}`}
                onClick={() => launch(kind)}
                className="flex items-start gap-3 rounded-xl border border-subtle bg-surface p-3 text-left transition-all hover:border-accent/50 hover:bg-surface-raised disabled:cursor-not-allowed disabled:opacity-50"
              >
                <div className="grid h-8 w-8 shrink-0 place-items-center rounded-lg bg-accent/10 text-accent">
                  <Icon name={AUX_TAB_ICONS[kind]} size={16} />
                </div>
                <div className="min-w-0 flex-1">
                  <span className="text-xs font-semibold text-primary">{meta.label}</span>
                  <p className="mt-0.5 line-clamp-2 text-[11px] text-muted">{meta.description}</p>
                </div>
              </button>
            );
          })}
        </div>

        {subAgents.length > 0 ? (
          <div className="space-y-2">
            <h4 className="text-[11px] font-semibold uppercase tracking-wider text-muted">
              Sub-agents in this task chain
            </h4>
            <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
              {subAgents.map((m) => {
                const name = m.displayName || m.agentInstanceId;
                return (
                  <button
                    key={m.agentInstanceId}
                    type="button"
                    data-debug-id={`aux-launcher-subagent-${m.agentInstanceId}`}
                    onClick={() =>
                      onSelect({ type: 'subagentChat', agentInstanceId: m.agentInstanceId }, name)
                    }
                    className="flex items-center justify-between gap-2 rounded-lg border border-subtle bg-surface px-3 py-2 text-left hover:border-accent/50"
                  >
                    <span className="truncate text-xs font-medium text-primary" title={name}>
                      {name}
                    </span>
                    {m.role ? <Badge tone="neutral">{m.role}</Badge> : null}
                  </button>
                );
              })}
            </div>
          </div>
        ) : null}

        {previewable.length > 0 ? (
          <div className="space-y-2">
            <h4 className="text-[11px] font-semibold uppercase tracking-wider text-muted">
              Active server previews
            </h4>
            <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
              {previewable.map((srv: any) => (
                <button
                  key={srv.session_id}
                  type="button"
                  data-debug-id={`aux-launcher-preview-${srv.session_id}`}
                  onClick={() =>
                    onSelect(
                      { type: 'preview', sessionId: srv.session_id, port: srv.server_port },
                      `${shellTitle(srv)} :${srv.server_port}`,
                    )
                  }
                  className="flex items-center justify-between rounded-lg border border-subtle bg-surface px-3 py-2 text-left hover:border-accent/50"
                >
                  <span className="truncate text-xs font-medium text-primary">{shellTitle(srv)}</span>
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

export default AuxNewTabLauncher;
