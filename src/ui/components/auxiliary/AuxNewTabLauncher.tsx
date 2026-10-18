import React, { useEffect, useMemo, useRef, useState } from 'react';
import { useSelector } from 'react-redux';
import { Badge, Icon } from '@ui';
import { useListShellsQuery, type ShellSession } from '../../api/endpoints/shells';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { useListArtifactsQuery } from '../../api/endpoints/artifacts';
import {
  AUX_TAB_REGISTRY,
  newShellTabContent,
  type AuxContent,
  type AuxTabKind,
} from '../../store/auxTabId';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { decryptVaultText, getActiveVaultKey, isVaultArmored } from '../../utils/vaultContent';
import { bridgeIdOf, bridgeLabel } from '../../utils/bridgeLaunchOptions';
import { composerBridgeIsOnline } from '../../utils/composerBridgeOptions';
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
];

interface BodyProps extends AuxNewTabLauncherProps {
  shellsData?: any;
  bridgesData?: any;
  artifactsData?: any;
}

function AuxNewTabLauncherWithApi(props: AuxNewTabLauncherProps) {
  const { chainId, bridgeId, projectId } = props;
  const { data: shellsData } = useListShellsQuery(
    { chainId: chainId || undefined, bridgeId: chainId ? undefined : bridgeId || undefined, status: 'live' },
    { skip: !chainId && !bridgeId },
  );
  const { data: bridgesData } = useListBridgesQuery();
  const { data: artifactsData } = useListArtifactsQuery(
    { chainId: chainId || undefined, projectId: projectId || undefined, limit: 100 },
    { skip: !chainId && !projectId },
  );
  return (
    <AuxNewTabLauncherBody
      {...props}
      shellsData={shellsData}
      bridgesData={bridgesData}
      artifactsData={artifactsData}
    />
  );
}

/** The `+` (NEW_TAB_ID) launcher of the aux strip. */
export function AuxNewTabLauncher(props: AuxNewTabLauncherProps) {
  const hasApiStore = useSelector((state: any) => Boolean(state?.heimdallApi));
  return hasApiStore ? <AuxNewTabLauncherWithApi {...props} /> : <AuxNewTabLauncherBody {...props} />;
}

function matchesSearch(query: string, ...values: unknown[]): boolean {
  if (!query) return true;
  return values.some((value) => String(value || '').toLocaleLowerCase().includes(query));
}

function ResultGroup({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="space-y-2">
      <h4 className="text-[11px] font-semibold uppercase tracking-wider text-muted">{title}</h4>
      <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">{children}</div>
    </section>
  );
}

function AuxNewTabLauncherBody({
  treeKey,
  ownerAgentId,
  chainId,
  projectId,
  members = [],
  onSelect,
  shellsData,
  bridgesData,
  artifactsData,
}: BodyProps) {
  const [query, setQuery] = useState('');
  const [showBridgePicker, setShowBridgePicker] = useState(false);
  const [artifactTitles, setArtifactTitles] = useState<Record<string, string>>({});
  const searchRef = useRef<HTMLInputElement | null>(null);
  const isVaultUnlocked = useSelector(selectIsVaultUnlocked);
  const normalizedQuery = query.trim().toLocaleLowerCase();

  const sessions = useMemo(
    () => ((shellsData?.sessions || []) as ShellSession[]).filter(
      (session) => session.kind === 'shell' || supportsLivePreview(session),
    ),
    [shellsData],
  );
  const aliveBridges = useMemo(
    () => ((bridgesData?.bridges || []) as any[]).filter(composerBridgeIsOnline),
    [bridgesData],
  );
  const artifacts = useMemo(
    () => ((artifactsData?.artifacts || []) as any[]).filter(
      (artifact) => String(artifact?.artifact_id || artifact?.artifactId || '').trim(),
    ),
    [artifactsData],
  );

  useEffect(() => {
    let cancelled = false;
    const key = isVaultUnlocked ? getActiveVaultKey() : null;
    void Promise.all(artifacts.map(async (artifact) => {
      const id = String(artifact?.artifact_id || artifact?.artifactId || '').trim();
      const raw = String(artifact?.name || '').trim();
      if (!id || !raw) return [id, ''] as const;
      if (!isVaultArmored(raw)) return [id, raw] as const;
      if (!key) return [id, ''] as const;
      try {
        const decrypted = await decryptVaultText(raw, key);
        return [id, isVaultArmored(decrypted) ? '' : decrypted] as const;
      } catch {
        return [id, ''] as const;
      }
    })).then((pairs) => {
      if (!cancelled) setArtifactTitles(Object.fromEntries(pairs.filter(([id, title]) => id && title)));
    });
    return () => {
      cancelled = true;
    };
  }, [artifacts, isVaultUnlocked]);

  useEffect(() => {
    searchRef.current?.focus();
  }, []);

  const filteredSessions = useMemo(
    () => sessions.filter((session) => matchesSearch(
      normalizedQuery,
      shellTitle(session),
      session.cmd,
      session.cwd,
      session.session_id,
      session.kind,
    )),
    [normalizedQuery, sessions],
  );
  const agents = useMemo(() => {
    const rows = [
      ...(ownerAgentId ? [{ agentInstanceId: ownerAgentId, displayName: 'Current agent', role: 'owner' }] : []),
      ...members.filter((member) => member.agentInstanceId && member.agentInstanceId !== ownerAgentId),
    ];
    return rows.filter((member) => matchesSearch(
      normalizedQuery,
      member.displayName,
      member.agentInstanceId,
      member.role,
    ));
  }, [members, normalizedQuery, ownerAgentId]);
  const searchableArtifacts = useMemo(
    () => artifacts.flatMap((artifact) => {
      const artifactId = String(artifact?.artifact_id || artifact?.artifactId || '').trim();
      const title = artifactTitles[artifactId] || '';
      if (!artifactId || !title || !matchesSearch(normalizedQuery, title, artifactId, artifact?.kind)) return [];
      return [{ artifactId, title, kind: String(artifact?.kind || 'artifact') }];
    }),
    [artifactTitles, artifacts, normalizedQuery],
  );

  const selectNewShellBridge = (bridge: any) => {
    const selectedBridgeId = bridgeIdOf(bridge);
    if (!selectedBridgeId) return;
    setShowBridgePicker(false);
    onSelect(newShellTabContent({ bridgeId: selectedBridgeId }), `Shell · ${bridgeLabel(bridge)}`);
  };

  const launch = (kind: AuxTabKind) => {
    switch (kind) {
      case 'shell':
        if (aliveBridges.length === 1) selectNewShellBridge(aliveBridges[0]);
        else if (aliveBridges.length > 1) setShowBridgePicker(true);
        return;
      case 'agentPty':
        onSelect({ type: 'agentPty', agentInstanceId: ownerAgentId });
        return;
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

  const hasSearchResults = filteredSessions.length > 0 || agents.length > 0 || searchableArtifacts.length > 0;

  return (
    <div
      data-debug-id={`aux-new-tab-launcher-${treeKey}`}
      className="flex h-full min-h-0 w-full flex-col items-center justify-start overflow-y-auto bg-canvas p-4 text-primary sm:p-5"
    >
      <div className="w-full max-w-2xl space-y-5">
        <label className="block">
          <span className="sr-only">Search artifacts, shells, and agents</span>
          <span className="flex min-h-11 items-center gap-2 rounded-xl border border-subtle bg-surface px-3 focus-within:border-accent focus-within:shadow-focus">
            <Icon name="search" size={16} className="shrink-0 text-muted" />
            <input
              ref={searchRef}
              type="search"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Search artifacts, shells, and agents"
              data-debug-id="aux-launcher-search"
              className="min-w-0 flex-1 bg-transparent py-2.5 text-sm text-primary outline-none placeholder:text-muted"
            />
          </span>
        </label>

        {showBridgePicker ? (
          <ResultGroup title="Choose a bridge for the interactive shell">
            {aliveBridges.map((bridge) => {
              const id = bridgeIdOf(bridge);
              return (
                <button
                  key={id}
                  type="button"
                  data-debug-id={`aux-launcher-shell-bridge-${id}`}
                  onClick={() => selectNewShellBridge(bridge)}
                  className="flex min-h-12 items-center justify-between gap-3 rounded-xl border border-subtle bg-surface px-3 py-2 text-left hover:border-accent/50 hover:bg-surface-raised"
                >
                  <span className="min-w-0">
                    <span className="block truncate text-sm font-semibold text-primary">{bridgeLabel(bridge)}</span>
                    <span className="block truncate text-[11px] text-muted">{id}</span>
                  </span>
                  <Badge tone="success">Alive</Badge>
                </button>
              );
            })}
          </ResultGroup>
        ) : null}

        <section className="space-y-2">
          <h4 className="text-[11px] font-semibold uppercase tracking-wider text-muted">Open a surface</h4>
          <div data-debug-id="aux-launcher-surface-grid" className="grid grid-cols-1 gap-2 sm:grid-cols-2">
            {LAUNCHER_ORDER.filter((kind) => {
              const meta = AUX_TAB_REGISTRY[kind];
              return matchesSearch(normalizedQuery, meta.label, meta.description);
            }).map((kind) => {
              const meta = AUX_TAB_REGISTRY[kind];
              const disabled =
                ((kind === 'chainOverview' || kind === 'tasks') && !chainId) ||
                ((kind === 'files' || kind === 'vcs') && !projectId && !ownerAgentId) ||
                (kind === 'agentPty' && !ownerAgentId) ||
                (kind === 'shell' && aliveBridges.length === 0);
              const description = kind === 'shell' && aliveBridges.length === 0
                ? 'No alive bridge is available to start an interactive shell.'
                : kind === 'shell' && aliveBridges.length > 1
                  ? `Choose one of ${aliveBridges.length} alive bridges.`
                  : meta.description;
              return (
                <button
                  key={kind}
                  type="button"
                  disabled={disabled}
                  title={disabled ? description : undefined}
                  data-debug-id={`aux-launcher-card-${kind}`}
                  onClick={() => launch(kind)}
                  className="flex min-h-16 items-start gap-3 rounded-xl border border-subtle bg-surface p-3 text-left transition-all hover:border-accent/50 hover:bg-surface-raised disabled:cursor-not-allowed disabled:opacity-50"
                >
                  <div className="grid h-8 w-8 shrink-0 place-items-center rounded-lg bg-accent/10 text-accent">
                    <Icon name={AUX_TAB_ICONS[kind]} size={16} />
                  </div>
                  <div className="min-w-0 flex-1">
                    <span className="text-xs font-semibold text-primary">{meta.label}</span>
                    <p className="mt-0.5 line-clamp-2 text-[11px] text-muted">{description}</p>
                  </div>
                </button>
              );
            })}
          </div>
        </section>

        {searchableArtifacts.length > 0 ? (
          <ResultGroup title="Artifacts">
            {searchableArtifacts.map((artifact) => (
              <button
                key={artifact.artifactId}
                type="button"
                data-debug-id={`aux-launcher-artifact-${artifact.artifactId}`}
                onClick={() => onSelect({ type: 'artifact', artifactId: artifact.artifactId }, artifact.title)}
                className="flex min-h-12 items-center justify-between gap-3 rounded-xl border border-subtle bg-surface px-3 py-2 text-left hover:border-accent/50"
              >
                <span className="min-w-0 truncate text-xs font-medium text-primary" title={artifact.title}>{artifact.title}</span>
                <Badge tone="neutral">{artifact.kind}</Badge>
              </button>
            ))}
          </ResultGroup>
        ) : null}

        {filteredSessions.length > 0 ? (
          <ResultGroup title="Live shells and servers">
            {filteredSessions.map((session) => {
              const isServer = supportsLivePreview(session);
              const title = shellTitle(session);
              return (
                <button
                  key={session.session_id}
                  type="button"
                  data-debug-id={`aux-launcher-session-${session.session_id}`}
                  onClick={() => onSelect(
                    isServer
                      ? { type: 'preview', sessionId: session.session_id, port: session.server_port }
                      : { type: 'shell', sessionId: session.session_id, bridgeId: session.bridge_id },
                    isServer ? `${title} :${session.server_port}` : title,
                  )}
                  className="flex min-h-12 items-center justify-between gap-3 rounded-xl border border-subtle bg-surface px-3 py-2 text-left hover:border-accent/50"
                >
                  <span className="min-w-0">
                    <span className="block truncate text-xs font-medium text-primary">{title}</span>
                    <span className="block truncate text-[11px] text-muted">{session.cwd || session.session_id}</span>
                  </span>
                  <Badge tone={isServer ? 'info' : 'success'}>{isServer ? `:${session.server_port}` : 'Shell'}</Badge>
                </button>
              );
            })}
          </ResultGroup>
        ) : null}

        {agents.length > 0 ? (
          <ResultGroup title={chainId ? 'Agents in this task chain' : 'Agent'}>
            {agents.map((member) => {
              const isOwner = member.agentInstanceId === ownerAgentId;
              const name = member.displayName || member.agentInstanceId;
              return (
                <button
                  key={member.agentInstanceId}
                  type="button"
                  data-debug-id={`aux-launcher-agent-${member.agentInstanceId}`}
                  onClick={() => onSelect(
                    isOwner
                      ? { type: 'agentPty', agentInstanceId: member.agentInstanceId }
                      : { type: 'subagentChat', agentInstanceId: member.agentInstanceId },
                    isOwner ? `${name} terminal` : name,
                  )}
                  className="flex min-h-12 items-center justify-between gap-3 rounded-xl border border-subtle bg-surface px-3 py-2 text-left hover:border-accent/50"
                >
                  <span className="min-w-0 truncate text-xs font-medium text-primary" title={name}>{name}</span>
                  <Badge tone="neutral">{isOwner ? 'PTY' : member.role || 'Agent'}</Badge>
                </button>
              );
            })}
          </ResultGroup>
        ) : null}

        {normalizedQuery && !hasSearchResults ? (
          <p data-debug-id="aux-launcher-no-results" className="rounded-xl border border-subtle bg-surface p-4 text-center text-xs text-muted">
            No matching artifacts, shells, or agents.
          </p>
        ) : null}
      </div>
    </div>
  );
}

export default AuxNewTabLauncher;
