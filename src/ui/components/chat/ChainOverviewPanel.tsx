import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { useSelector } from 'react-redux';
import { selectActiveVaultKey } from '../../store/vaultSlice';
import { VaultText } from '../vault/VaultText';
import { useAuthUser } from '../auth/AuthUserContext';
import { isVaultArmored, decryptVaultText } from '../../utils/vaultContent';
import {
  Avatar,
  Badge,
  Button,
  Icon,
  IconButton,
  Spinner,
  StatusDot,
  StatusPill,
  Text,
  type Tone,
} from '@ui';
import {
  useFetchChainTaskDetailQuery,
  useFetchTaskChainDetailQuery,
  useVoteTaskMutation,
} from '../../api/endpoints/tasks';
import {
  useGetProjectVcsStatusQuery,
  useListVcsFilesQuery,
  type VcsChangedFile,
} from '../../api/endpoints/projectVcs';
import { useListArtifactsQuery } from '../../api/endpoints/artifacts';
import {
  useStartInstanceMutation,
  useStopAgentInstanceMutation,
  useRestartAgentInstanceMutation,
  useListAgentIdentitiesQuery,
} from '../../api/endpoints/agents';
import {
  getQueuedWaitingSlotName,
  formatFleetRoleName,
} from '../tasks/FleetManagementDrawer';
import ArtifactViewer from '../ArtifactViewer';
import Markdown from '../Markdown';
import AgentPaneComposerPanel from './AgentPaneComposerPanel';
import { buildRouteHash } from '../../utils/appLocation';
import {
  readChainOverviewCollapsedState,
  writeChainOverviewCollapsedState,
  writeRightSidebarOpen,
  writeRightSidebarTab,
  readPinnedMonitorAgents,
  addPinnedMonitorAgent,
  removePinnedMonitorAgent,
} from '../../utils/clientPersistence';

function canUseAmbientApiAuth(): boolean {
  if (typeof window === 'undefined') return false;
  return Boolean((window as any).odinApi?.deviceAuth) || window.location.protocol === 'http:' || window.location.protocol === 'https:';
}

function getArtifactViewerSession(session: any) {
  if (canUseAmbientApiAuth()) return { daemonUrl: '', clientToken: 'v1' };
  return { daemonUrl: String(session?.daemonUrl || ''), clientToken: String(session?.clientToken || 'v1') };
}

export interface ChainOverviewPanelProps {
  chainId: string;
  projectId: string;
  bridgeId?: string;
  agentInstanceId?: string;
  projectVcsEnabled: boolean;
  onClose?: () => void;
  onSelectTask?: (taskId: string) => void;
  onOpenFileDiff?: (filePath: string) => void;
  onOpenVcsFiles?: () => void;
  isMobile?: boolean;
}

// Format bytes into human-readable string (KB, MB, etc.)
function formatBytes(bytes: number): string {
  if (!bytes || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  const i = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const size = (bytes / Math.pow(1024, i)).toFixed(i === 0 ? 0 : 1);
  return `${size} ${units[i]}`;
}

// Format relative time (e.g. 5m ago, 2h ago)
function formatRelativeTime(timestamp: number | string | undefined): string {
  if (!timestamp) return '';
  const time = typeof timestamp === 'string' ? new Date(timestamp).getTime() : timestamp;
  if (isNaN(time) || time <= 0) return '';
  const now = Date.now();
  const diffSec = Math.max(0, Math.floor((now - time) / 1000));
  if (diffSec < 60) return 'just now';
  const diffMin = Math.floor(diffSec / 60);
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHours = Math.floor(diffMin / 60);
  if (diffHours < 24) return `${diffHours}h ago`;
  const diffDays = Math.floor(diffHours / 24);
  return `${diffDays}d ago`;
}

// Priority tone helper
function priorityTone(priority: string): Tone {
  const p = String(priority || '').toLowerCase();
  if (p === 'p0') return 'danger';
  if (p === 'p1') return 'warning';
  if (p === 'p2') return 'info';
  return 'neutral';
}

// Status tone helper
function statusTone(status: string): Tone {
  const s = String(status || '').toLowerCase();
  if (s === 'running' || s === 'live' || s === 'validated_good' || s === 'completed') return 'success';
  if (s === 'in_progress' || s === 'in_validation' || s === 'starting') return 'info';
  if (s === 'queued' || s === 'warning') return 'warning';
  if (s === 'stopped' || s === 'failed' || s === 'validated_not_good' || s === 'cancelled') return 'danger';
  return 'neutral';
}

// Role badge styling
function roleTone(role: string): Tone {
  const r = String(role || '').toLowerCase();
  if (r === 'coordinator') return 'warning';
  if (r === 'reviewer') return 'info';
  return 'neutral';
}

// Helper to determine if a task needs attention
function isAttentionNeeded(task: any): boolean {
  const status = String(task.status || '').toLowerCase();
  if (status === 'validated_not_good') return true;
  if (status === 'in_validation') {
    const reviewerRefs = task.reviewer_refs || task.reviewerRefs || [];
    const reviewers = task.reviewers || [];
    const noReviewer = reviewerRefs.length === 0 && reviewers.length === 0;
    const isUserReviewer = Boolean(task.requiresUserApproval ?? task.requires_user_approval) ||
      reviewerRefs.some((r: any) => r.type === 'user');
    return noReviewer || isUserReviewer;
  }
  return false;
}

function attentionReason(task: any): string {
  const status = String(task.status || '').toLowerCase();
  if (status === 'validated_not_good') return 'Validation rejected (needs fixes)';
  const reviewerRefs = task.reviewer_refs || task.reviewerRefs || [];
  const reviewers = task.reviewers || [];
  if (reviewerRefs.length === 0 && reviewers.length === 0) return 'No reviewer assigned';
  return 'Review required by user';
}

// Sub-component for an Attention Task's review action panel
function AttentionTaskReviewCard({
  chainId,
  task,
  onVoteSuccess,
}: {
  chainId: string;
  task: any;
  onVoteSuccess?: () => void;
}) {
  const taskId = String(task.taskId || task.id || '');
  const { data: detailData, isLoading: isDetailLoading } = useFetchChainTaskDetailQuery(
    { chainId, taskId },
    { skip: !chainId || !taskId }
  );
  const [voteTask, { isLoading: isVoting }] = useVoteTaskMutation();
  const [voteComment, setVoteComment] = useState('');
  const [voteError, setVoteError] = useState('');

  // Key material lives only as a non-extractable CryptoKey (REQ-VAULT-HARDEN-1), so both
  // the decryption effect and the locked-state render branch below test the real key
  // rather than the permanently-null state.vault.rawVaultKeyHex.
  const activeKey = useSelector(selectActiveVaultKey);
  const [decryptedDescription, setDecryptedDescription] = useState<string | null>(null);

  const fullTask = detailData?.task || task;
  const rawDescription = String(fullTask.description || '').trim();

  useEffect(() => {
    let active = true;
    if (isVaultArmored(rawDescription) && activeKey) {
      decryptVaultText(rawDescription, activeKey)
        .then((decrypted) => {
          if (active) setDecryptedDescription(decrypted);
        })
        .catch(() => {
          if (active) setDecryptedDescription(null);
        });
    } else {
      setDecryptedDescription(null);
    }
    return () => {
      active = false;
    };
  }, [rawDescription, activeKey]);

  const effectiveDescription = isVaultArmored(rawDescription)
    ? (decryptedDescription || '')
    : rawDescription;

  // Extract checklist items from description
  const checklistItems = useMemo(() => {
    if (!effectiveDescription) return [];
    const lines = effectiveDescription.split('\n');
    return lines
      .map((l) => l.trim())
      .filter((l) => /^(\[[\sxX]\]|-\s*\[[\sxX]\])/.test(l))
      .map((l) => ({
        checked: /\[[xX]\]/.test(l),
        text: l.replace(/^[-*]?\s*\[[\sxX]\]\s*/, ''),
      }));
  }, [effectiveDescription]);

  const handleVote = async (result: 'lgtm' | 'ngtm') => {
    try {
      setVoteError('');
      await voteTask({
        chainId,
        taskId,
        result,
        comment: voteComment.trim() || undefined,
      }).unwrap();
      onVoteSuccess?.();
    } catch (err: any) {
      setVoteError(err?.message || 'Vote failed. Please try again.');
    }
  };

  return (
    <div
      data-debug-id={`chain-overview-attention-review-${taskId}`}
      className="mt-3 rounded-lg border border-subtle bg-surface p-3 space-y-3"
    >
      <div className="flex items-center justify-between">
        <span className="text-xs font-semibold text-primary">Review Action Gate</span>
        <span className="text-[11px] font-mono text-muted">{taskId}</span>
      </div>

      {isDetailLoading ? (
        <div className="flex items-center gap-2 text-xs text-muted py-2">
          <Spinner size="sm" />
          <span>Loading task details & acceptance criteria…</span>
        </div>
      ) : (
        <>
          {checklistItems.length > 0 ? (
            <div className="space-y-1.5 rounded bg-surface-secondary/50 p-2.5">
              <span className="text-[11px] font-semibold text-muted uppercase tracking-wider">
                Acceptance Criteria Checklist
              </span>
              <ul className="space-y-1 text-xs">
                {checklistItems.map((item, idx) => (
                  <li key={idx} className="flex items-start gap-2">
                    <span className={item.checked ? 'text-success' : 'text-muted'}>
                      <Icon name={item.checked ? 'check' : 'alert'} size={14} />
                    </span>
                    <span className={item.checked ? 'line-through text-muted' : 'text-primary'}>
                      {item.text}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          ) : isVaultArmored(rawDescription) && !activeKey ? (
            <div className="max-h-48 overflow-y-auto rounded bg-surface-secondary/40 p-2 text-xs">
              <VaultText value={rawDescription} as="div" fallback="[🔒 Encrypted description]" />
            </div>
          ) : effectiveDescription ? (
            <div className="max-h-48 overflow-y-auto rounded bg-surface-secondary/40 p-2 text-xs">
              <Markdown source={effectiveDescription} compact copyAll={false} />
            </div>
          ) : (
            <p className="text-xs italic text-muted">No description provided for this task.</p>
          )}
        </>
      )}

      {/* Review feedback textarea */}
      <div>
        <label className="block text-[11px] font-medium text-muted mb-1">
          Review Feedback / Justification
        </label>
        <textarea
          value={voteComment}
          onChange={(e) => setVoteComment(e.target.value)}
          placeholder="Add comments or required fixes before voting…"
          rows={2}
          className="w-full rounded border border-subtle bg-canvas px-2.5 py-1.5 text-xs text-primary placeholder:text-muted focus:border-accent focus:outline-none"
        />
      </div>

      {voteError && <p className="text-xs text-danger">{voteError}</p>}

      {/* Vote Action Buttons */}
      <div className="flex items-center gap-2 pt-1">
        <Button
          type="button"
          tone="success"
          size="sm"
          disabled={isVoting}
          data-debug-id={`chain-overview-vote-lgtm-${taskId}`}
          onClick={() => handleVote('lgtm')}
          className="flex-1"
        >
          {isVoting ? <Spinner size="sm" /> : <Icon name="check" size={14} />}
          <span>LGTM (Approve)</span>
        </Button>
        <Button
          type="button"
          tone="danger"
          size="sm"
          disabled={isVoting}
          data-debug-id={`chain-overview-vote-ngtm-${taskId}`}
          onClick={() => handleVote('ngtm')}
          className="flex-1"
        >
          {isVoting ? <Spinner size="sm" /> : <Icon name="close" size={14} />}
          <span>NGTM (Reject)</span>
        </Button>
      </div>
    </div>
  );
}

export default function ChainOverviewPanel({
  chainId,
  projectId,
  bridgeId = '',
  agentInstanceId,
  projectVcsEnabled,
  onClose,
  onSelectTask,
  onOpenFileDiff,
  onOpenVcsFiles,
  isMobile = false,
}: ChainOverviewPanelProps) {
  const authUser = useAuthUser();
  const username = String(authUser?.user_id || '').trim();
  const session = useSelector((state: any) => state.chat?.session || {});
  const viewerSession = getArtifactViewerSession(session);

  // Collapsed sections state with client persistence (default open)
  const [collapsedSections, setCollapsedSections] = useState<Record<string, boolean>>(() =>
    readChainOverviewCollapsedState(agentInstanceId)
  );

  React.useEffect(() => {
    setCollapsedSections(readChainOverviewCollapsedState(agentInstanceId));
  }, [agentInstanceId]);

  const toggleSection = useCallback(
    (sectionKey: string) => {
      setCollapsedSections((prev) => {
        const next = {
          ...prev,
          [sectionKey]: !prev[sectionKey],
        };
        writeChainOverviewCollapsedState(next, agentInstanceId);
        return next;
      });
    },
    [agentInstanceId]
  );

  const isCollapsed = useCallback((key: string) => Boolean(collapsedSections[key]), [collapsedSections]);

  // Queries
  const { data: chainData, isLoading: isChainLoading, refetch: refetchChain } = useFetchTaskChainDetailQuery(
    { chainId },
    { skip: !chainId, pollingInterval: 15000 }
  );

  const { data: artifactsData, isLoading: isArtifactsLoading } = useListArtifactsQuery(
    { chainId, limit: 50 },
    { skip: !chainId, pollingInterval: 30000 }
  );

  const vcsStatusQuery = useGetProjectVcsStatusQuery(projectId, {
    skip: !projectVcsEnabled || !projectId,
    pollingInterval: 30000,
  });

  const vcsFilesQuery = useListVcsFilesQuery(
    { projectId, bridgeId, limit: 100 },
    { skip: !projectVcsEnabled || !projectId, pollingInterval: 30000 }
  );

  const [startInstanceMutation] = useStartInstanceMutation();
  const [stopInstanceMutation] = useStopAgentInstanceMutation();
  const [restartInstanceMutation] = useRestartAgentInstanceMutation();

  // Local interaction state
  const [startingInstanceId, setStartingInstanceId] = useState<string | null>(null);
  const [stoppingInstanceId, setStoppingInstanceId] = useState<string | null>(null);
  const [restartingInstanceId, setRestartingInstanceId] = useState<string | null>(null);
  const [activeArtifactId, setActiveArtifactId] = useState<string>('');
  const [expandedAttentionTaskId, setExpandedAttentionTaskId] = useState<string | null>(null);
  const [openTerminalIds, setOpenTerminalIds] = useState<Record<string, boolean>>({});
  const [capturedTerminalIds, setCapturedTerminalIds] = useState<Record<string, boolean>>({});
  const [maximizedTerminalInstanceId, setMaximizedTerminalInstanceId] = useState<string | null>(null);
  const [pinnedAgentIds, setPinnedAgentIds] = useState<string[]>(() => readPinnedMonitorAgents());

  const agentIdentitiesQuery = useListAgentIdentitiesQuery();
  const agentIdentities = agentIdentitiesQuery.data?.agents || [];

  React.useEffect(() => {
    setPinnedAgentIds(readPinnedMonitorAgents());
  }, []);

  const handleTogglePinAgent = useCallback(
    (instId: string, e?: React.MouseEvent) => {
      e?.stopPropagation();
      if (!instId) return;
      const isPinned = pinnedAgentIds.includes(instId);
      if (isPinned) {
        removePinnedMonitorAgent(instId);
        setPinnedAgentIds((prev) => prev.filter((id) => id !== instId));
      } else {
        addPinnedMonitorAgent(instId);
        setPinnedAgentIds((prev) => (prev.includes(instId) ? prev : [...prev, instId]));
        // On first pin, surface the monitor grid so the user sees where it went.
        if (typeof window !== 'undefined') {
          window.open(window.location.origin + '/#/agent-monitor', 'agent-monitor');
        }
      }
    },
    [pinnedAgentIds]
  );

  const chain = chainData?.chain;
  const members: any[] = useMemo(() => chain?.members || [], [chain?.members]);
  const capturedMembers = useMemo(() => {
    return members.filter((member) => {
      const instId = member.agentInstanceId || member.agent_instance_id;
      return Boolean(capturedTerminalIds[instId]);
    });
  }, [members, capturedTerminalIds]);
  const tasks: any[] = useMemo(() => chain?.tasks || [], [chain?.tasks]);
  const artifacts: any[] = useMemo(() => artifactsData?.artifacts || [], [artifactsData?.artifacts]);
  const vcsFiles: VcsChangedFile[] = useMemo(() => vcsFilesQuery.data?.files || [], [vcsFilesQuery.data?.files]);

  // VCS counts
  const vcsModifiedCount = useMemo(() => vcsFiles.filter((f) => f.status === 'modified').length, [vcsFiles]);
  const vcsStagedCount = useMemo(() => vcsFiles.filter((f) => f.staged).length, [vcsFiles]);
  const vcsUntrackedCount = useMemo(() => vcsFiles.filter((f) => f.status === 'untracked').length, [vcsFiles]);

  // Tasks sections
  const ongoingTasks = useMemo(() => {
    return tasks.filter((t) => {
      const s = String(t.status || '').toLowerCase();
      return s === 'in_progress' || s === 'in_validation';
    });
  }, [tasks]);

  const attentionTasks = useMemo(() => {
    return tasks.filter(isAttentionNeeded);
  }, [tasks]);

  // Member current tasks map
  const memberCurrentTaskMap = useMemo(() => {
    const map = new Map<string, any>();
    for (const t of tasks) {
      const s = String(t.status || '').toLowerCase();
      if (s === 'in_progress') {
        const instId = t.assignee_ref?.agent_instance_id || t.assigneeRef?.agentInstanceId;
        if (instId) map.set(instId, t);
      }
    }
    return map;
  }, [tasks]);

  // Memoized member display name map (instanceId -> displayName)
  const memberNameMap = useMemo(() => {
    const map = new Map<string, string>();
    for (const m of members) {
      const instId = m.agentInstanceId || m.agent_instance_id;
      const name = m.displayName || m.display_name;
      if (instId && name) {
        map.set(instId, name);
      }
    }
    return map;
  }, [members]);

  // Resolve human-friendly agent/user display name
  const resolveAgentName = useCallback(
    (ref: any, fallback: string): string => {
      if (!ref) return fallback;
      if (typeof ref === 'string') {
        if (ref === 'user' || ref.toLowerCase() === 'user') return 'User';
        return memberNameMap.get(ref) || ref || fallback;
      }
      if (ref.type === 'user') {
        const reviewerUsername = String(ref.username || ref.user_id || ref.userId || username);
        return reviewerUsername ? `You (@${reviewerUsername})` : 'You';
      }
      if (ref.displayName || ref.display_name) {
        return ref.displayName || ref.display_name;
      }
      const instanceId = ref.agentInstanceId || ref.agent_instance_id;
      if (instanceId) {
        return memberNameMap.get(instanceId) || instanceId;
      }
      const agentId = ref.agentId || ref.agent_id;
      if (agentId) {
        return formatFleetRoleName(agentId, agentIdentities);
      }
      return fallback;
    },
    [memberNameMap, agentIdentities, username]
  );

  // Toggle terminal accordion
  const toggleTerminal = useCallback((instId: string) => {
    setOpenTerminalIds((prev) => ({
      ...prev,
      [instId]: !prev[instId],
    }));
  }, []);

  // Toggle terminal capture
  const toggleCaptureTerminal = useCallback((instId: string, e?: React.MouseEvent) => {
    e?.stopPropagation();
    setCapturedTerminalIds((prev) => {
      const willCapture = !prev[instId];
      if (willCapture) {
        setOpenTerminalIds((openPrev) => ({
          ...openPrev,
          [instId]: true,
        }));
      }
      return {
        ...prev,
        [instId]: willCapture,
      };
    });
  }, []);

  // Handle start agent instance
  const handleStartAgent = useCallback(
    async (instanceId: string, e?: React.MouseEvent) => {
      e?.stopPropagation();
      try {
        setStartingInstanceId(instanceId);
        await startInstanceMutation(instanceId);
        refetchChain();
      } catch (err) {
        console.error('Failed to start agent:', err);
      } finally {
        setStartingInstanceId(null);
      }
    },
    [startInstanceMutation, refetchChain]
  );

  // Handle stop agent instance
  const handleStopAgent = useCallback(
    async (instanceId: string, agentId?: string, e?: React.MouseEvent) => {
      e?.stopPropagation();
      try {
        setStoppingInstanceId(instanceId);
        await stopInstanceMutation({ instanceId, agentId: agentId || '' });
        refetchChain();
      } catch (err) {
        console.error('Failed to stop agent:', err);
      } finally {
        setStoppingInstanceId(null);
      }
    },
    [stopInstanceMutation, refetchChain]
  );

  // Handle restart agent instance
  const handleRestartAgent = useCallback(
    async (instanceId: string, agentId?: string, e?: React.MouseEvent) => {
      e?.stopPropagation();
      try {
        setRestartingInstanceId(instanceId);
        await restartInstanceMutation({ instanceId, agentId });
        refetchChain();
      } catch (err) {
        console.error('Failed to restart agent:', err);
      } finally {
        setRestartingInstanceId(null);
      }
    },
    [restartInstanceMutation, refetchChain]
  );

  // Navigate to conversation thread
  const handleNavigateToAgent = useCallback(
    (agentInstanceId: string) => {
      if (!agentInstanceId) return;
      if (!isMobile) {
        writeRightSidebarOpen(true, agentInstanceId);
        writeRightSidebarTab('chain', agentInstanceId);
        window.location.hash = buildRouteHash(`/conversations/${encodeURIComponent(agentInstanceId)}`, '?panel=chain');
      } else {
        window.location.hash = buildRouteHash(`/conversations/${encodeURIComponent(agentInstanceId)}`, '');
      }
    },
    [isMobile]
  );

  return (
    <div
      data-debug-id="chain-overview-panel"
      className="flex h-full min-h-0 flex-col overflow-y-auto bg-surface text-primary p-3 sm:p-4 space-y-6"
    >
      {isChainLoading && (
        <div className="flex items-center justify-center py-8 text-xs text-muted gap-2">
          <Spinner size="sm" /> Loading chain overview…
        </div>
      )}

      {/* Chain Header Toolbar */}
      <div
        data-debug-id="chain-overview-header-toolbar"
        className="rounded-xl border border-subtle bg-surface-secondary/40 p-3"
      >
        <div className="flex items-center justify-between gap-2">
          <div className="min-w-0 flex-1">
            <h2 className="text-xs font-bold text-primary truncate">
              <VaultText value={chain?.title} fallback="Task Chain Overview" />
            </h2>
            <div className="flex items-center gap-2 mt-0.5">
              <span className="font-mono text-[10px] text-muted">{chainId}</span>
              {chain?.status && (
                <StatusPill tone={statusTone(chain.status)}>
                  {chain.status}
                </StatusPill>
              )}
            </div>
          </div>
          {onClose && (
            <IconButton
              icon="close"
              label="Close panel"
              size="sm"
              onClick={onClose}
            />
          )}
        </div>
      </div>

      {/* SECTION 1: Chain Agents */}
      <section data-debug-id="chain-overview-section-agents" className="space-y-2.5">
        <button
          type="button"
          data-debug-id="chain-overview-section-toggle-agents"
          onClick={() => toggleSection('agents')}
          aria-expanded={!isCollapsed('agents')}
          className="flex w-full items-center justify-between text-left group cursor-pointer"
        >
          <div className="flex items-center gap-1.5">
            <Icon
              name={isCollapsed('agents') ? 'chevron-right' : 'chevron-down'}
              size={14}
              className="text-muted group-hover:text-primary transition-colors"
            />
            <Icon name="bot" size={14} className="text-muted" />
            <h3 className="text-xs font-semibold uppercase tracking-wider text-muted group-hover:text-primary transition-colors">
              Chain Agents ({members.length})
            </h3>
          </div>
        </button>

        {!isCollapsed('agents') && (
          members.length === 0 ? (
            <p className="text-xs text-muted py-1">No agents assigned to this chain.</p>
          ) : (
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-2.5">
              {members.map((member) => {
                const instId = member.agentInstanceId || member.agent_instance_id;
                const agentId = member.agentId || member.agent_id || '';
                const name = member.displayName || member.display_name || instId;
                const role = member.role || 'worker';
                const rawStatus = String(member.runtimeStatus || member.runtime_status || 'stopped').toLowerCase();
                const isStopped = rawStatus === 'stopped' || rawStatus === 'failed';
                const isRunning = rawStatus === 'running' || rawStatus === 'idle' || rawStatus === 'ready';
                const isStarting = startingInstanceId === instId || rawStatus === 'starting';
                const isStopping = stoppingInstanceId === instId;
                const isRestarting = restartingInstanceId === instId;
                const currentTask = memberCurrentTaskMap.get(instId);
                const isCoordinator =
                  String(role).toLowerCase() === 'coordinator' ||
                  instId === chain?.coordinatorInstanceId ||
                  instId === chain?.coordinator_instance_id;

                const isSelected = Boolean(agentInstanceId && instId === agentInstanceId);
                const cardClasses = isSelected
                  ? 'border-accent/50 bg-gradient-to-br from-accent/10 to-accent/5 ring-1 ring-accent/20'
                  : 'border-subtle bg-surface-secondary/30';
                const isCapturing = Boolean(capturedTerminalIds[instId]);

                return (
                  <div
                    key={instId}
                    data-debug-id={`chain-overview-agent-row-${instId}`}
                    onClick={() => handleNavigateToAgent(instId)}
                    className={`flex flex-col justify-between gap-2 rounded-lg border p-2.5 transition-colors hover:bg-neutral-soft/50 cursor-pointer ${cardClasses}`}
                  >
                    <div className="flex items-center gap-2.5 min-w-0">
                      <div className="relative shrink-0">
                        <Avatar name={name} size="sm" />
                        <div className="absolute -bottom-0.5 -right-0.5">
                          <StatusDot tone={statusTone(rawStatus)} label={rawStatus} size="sm" />
                        </div>
                      </div>
                      <div className="min-w-0">
                        <div className="flex items-center gap-1.5 flex-wrap">
                          <span className="font-semibold text-xs text-primary truncate max-w-[140px] sm:max-w-[180px]">
                            {name}
                          </span>
                          <Badge tone={roleTone(role)}>
                            {role}
                          </Badge>
                          <StatusPill tone={statusTone(rawStatus)}>
                            {rawStatus}
                          </StatusPill>
                        </div>
                        <div className="text-[11px] text-muted truncate max-w-[240px] mt-0.5">
                          {currentTask ? (
                            <span className="flex items-center gap-1 text-accent">
                              <Icon name="tasks" size={10} />
                              <VaultText value={currentTask.title} as="span" className="truncate" />
                            </span>
                          ) : (
                            <span className="text-faint">Idle / No active task</span>
                          )}
                        </div>
                      </div>
                    </div>

                    <div className="shrink-0 flex items-center gap-1 justify-end" onClick={(e) => e.stopPropagation()}>
                      <button
                        type="button"
                        data-debug-id={`chain-overview-toggle-capture-${instId}`}
                        onClick={(e) => toggleCaptureTerminal(instId, e)}
                        title={isCapturing ? 'Stop capturing terminal' : 'Capture terminal output'}
                        aria-label={isCapturing ? 'Stop capturing terminal' : 'Capture terminal output'}
                        aria-pressed={isCapturing}
                        className={`grid h-7 w-7 place-items-center rounded-md border border-subtle transition-colors ${
                          isCapturing
                            ? 'bg-accent/20 text-accent font-semibold hover:bg-accent/30'
                            : 'text-muted hover:bg-neutral-soft hover:text-primary'
                        }`}
                      >
                        <Icon name="terminal" size={13} />
                      </button>
                      {isStopped ? (
                        <button
                          type="button"
                          disabled={isStarting}
                          data-debug-id={`chain-overview-start-agent-${instId}`}
                          onClick={(e) => handleStartAgent(instId, e)}
                          title="Start Agent"
                          aria-label="Start Agent"
                          className="grid h-7 w-7 place-items-center rounded-md bg-accent text-accent-fg hover:opacity-90 disabled:opacity-50 transition-opacity shadow-xs"
                        >
                          {isStarting ? (
                            <Spinner size="sm" />
                          ) : (
                            <Icon name="play" size={14} />
                          )}
                        </button>
                      ) : isRunning ? (
                        <>
                          <button
                            type="button"
                            disabled={isStopping || isRestarting}
                            data-debug-id={`chain-overview-stop-agent-${instId}`}
                            onClick={(e) => handleStopAgent(instId, agentId, e)}
                            title="Stop Agent"
                            aria-label="Stop Agent"
                            className="grid h-7 w-7 place-items-center rounded-md border border-subtle bg-surface-raised hover:bg-neutral-soft text-muted hover:text-danger transition-colors disabled:opacity-50"
                          >
                            {isStopping ? (
                              <Spinner size="sm" />
                            ) : (
                              <Icon name="stop" size={12} />
                            )}
                          </button>
                          <button
                            type="button"
                            disabled={isStopping || isRestarting}
                            data-debug-id={`chain-overview-restart-agent-${instId}`}
                            onClick={(e) => handleRestartAgent(instId, agentId, e)}
                            title="Restart Agent"
                            aria-label="Restart Agent"
                            className="grid h-7 w-7 place-items-center rounded-md border border-subtle bg-surface-raised hover:bg-neutral-soft text-muted hover:text-primary transition-colors disabled:opacity-50"
                          >
                            {isRestarting ? (
                              <Spinner size="sm" />
                            ) : (
                              <Icon name="refresh" size={13} />
                            )}
                          </button>
                        </>
                      ) : null}
                    </div>
                  </div>
                );
              })}
            </div>
          )
        )}
      </section>

      {/* SECTION 5: Attention Needed (Placed high for urgent visibility) */}
      {attentionTasks.length > 0 && (
        <section data-debug-id="chain-overview-section-attention" className="space-y-2.5">
          <button
            type="button"
            data-debug-id="chain-overview-section-toggle-attention"
            onClick={() => toggleSection('attention')}
            aria-expanded={!isCollapsed('attention')}
            className="flex w-full items-center justify-between text-left group cursor-pointer"
          >
            <div className="flex items-center gap-1.5">
              <Icon
                name={isCollapsed('attention') ? 'chevron-right' : 'chevron-down'}
                size={14}
                className="text-warning group-hover:text-warning/80 transition-colors"
              />
              <Icon name="alert" size={14} className="text-warning" />
              <h3 className="text-xs font-semibold uppercase tracking-wider text-warning group-hover:text-warning/80 transition-colors">
                Attention Needed ({attentionTasks.length})
              </h3>
            </div>
          </button>

          {!isCollapsed('attention') && (
            <div className="grid gap-2">
              {attentionTasks.map((task) => {
                const taskId = task.taskId || task.id;
                const isExpanded = expandedAttentionTaskId === taskId;
                const reason = attentionReason(task);
                const assignee = resolveAgentName(
                  task.assigneeRef || task.assignee_ref || task.assigneeAgentInstanceId || task.assignee_agent_instance_id,
                  'Unassigned'
                );
                const reviewerRef =
                  task.reviewerRefs?.[0] ||
                  task.reviewer_refs?.[0] ||
                  task.reviewerAgentInstanceId ||
                  task.reviewer_agent_instance_id ||
                  (task.reviewers?.[0] ? String(task.reviewers[0]) : null);
                const reviewer = resolveAgentName(reviewerRef, 'None');

                return (
                  <div
                    key={taskId}
                    data-debug-id={`chain-overview-attention-task-${taskId}`}
                    className="rounded-lg border border-warning/30 bg-warning-soft/20 p-2.5 transition-colors"
                  >
                    <div
                      onClick={() => setExpandedAttentionTaskId((prev) => (prev === taskId ? null : taskId))}
                      className="flex items-start justify-between gap-2 cursor-pointer"
                    >
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-1.5 flex-wrap">
                          <Badge tone={priorityTone(task.priority)}>
                            {task.priority || 'P2'}
                          </Badge>
                          <StatusPill tone={statusTone(task.status)}>
                            {task.status}
                          </StatusPill>
                          {task.status === 'queued' && (
                            <span
                              data-debug-id={`chain-overview-attention-queued-slot-${taskId}`}
                              className="rounded bg-warning-soft px-1.5 py-0.5 text-[11px] font-semibold text-warning"
                            >
                              Queued (Waiting for {getQueuedWaitingSlotName(task, agentIdentities)} slot)
                            </span>
                          )}
                          <span className="text-[11px] font-medium text-warning truncate">
                            {reason}
                          </span>
                        </div>
                        <h4 className="text-xs font-semibold text-primary mt-1 line-clamp-2">
                          <VaultText value={task.title} as="span" />
                        </h4>
                        <div className="mt-1 flex items-center justify-between text-[11px] text-muted">
                          <span className="truncate max-w-[140px]">
                            Worker: <strong className="text-primary font-normal">{assignee}</strong>
                          </span>
                          <span className="truncate max-w-[140px]">
                            Reviewer: <strong className="text-primary font-normal">{reviewer}</strong>
                          </span>
                        </div>
                      </div>
                      <button
                        type="button"
                        aria-label="Toggle review panel"
                        className="text-muted hover:text-primary mt-0.5 shrink-0"
                      >
                        <Icon name={isExpanded ? 'chevron-down' : 'chevron-right'} size={14} />
                      </button>
                    </div>

                    {isExpanded && (
                      <AttentionTaskReviewCard
                        chainId={chainId}
                        task={task}
                        onVoteSuccess={() => {
                          refetchChain();
                          setExpandedAttentionTaskId(null);
                        }}
                      />
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </section>
      )}

      {/* SECTION 4: Ongoing Tasks */}
      <section data-debug-id="chain-overview-section-ongoing-tasks" className="space-y-2.5">
        <div className="flex items-center justify-between">
          <button
            type="button"
            data-debug-id="chain-overview-section-toggle-ongoingTasks"
            onClick={() => toggleSection('ongoingTasks')}
            aria-expanded={!isCollapsed('ongoingTasks')}
            className="flex items-center gap-1.5 text-left group cursor-pointer"
          >
            <Icon
              name={isCollapsed('ongoingTasks') ? 'chevron-right' : 'chevron-down'}
              size={14}
              className="text-muted group-hover:text-primary transition-colors"
            />
            <Icon name="tasks" size={14} className="text-muted" />
            <h3 className="text-xs font-semibold uppercase tracking-wider text-muted group-hover:text-primary transition-colors">
              Ongoing Tasks ({ongoingTasks.length})
            </h3>
          </button>
          {onSelectTask && tasks.length > 0 && (
            <button
              type="button"
              onClick={() => onSelectTask('')}
              className="text-[11px] font-medium text-accent hover:underline"
            >
              All Tasks ({tasks.length})
            </button>
          )}
        </div>

        {!isCollapsed('ongoingTasks') && (
          ongoingTasks.length === 0 ? (
            <p className="text-xs text-muted py-1">No active in_progress or in_validation tasks.</p>
          ) : (
            <div className="grid gap-2">
              {ongoingTasks.map((task) => {
                const taskId = task.taskId || task.id;
                const assignee = resolveAgentName(
                  task.assigneeRef || task.assignee_ref || task.assigneeAgentInstanceId || task.assignee_agent_instance_id,
                  'Unassigned'
                );
                const reviewerRef =
                  task.reviewerRefs?.[0] ||
                  task.reviewer_refs?.[0] ||
                  task.reviewerAgentInstanceId ||
                  task.reviewer_agent_instance_id ||
                  (task.reviewers?.[0] ? String(task.reviewers[0]) : null);
                const reviewer = resolveAgentName(reviewerRef, 'None');

                return (
                  <div
                    key={taskId}
                    data-debug-id={`chain-overview-ongoing-task-${taskId}`}
                    onClick={() => onSelectTask?.(taskId)}
                    className="rounded-lg border border-subtle bg-surface-secondary/30 p-2.5 transition-colors hover:bg-neutral-soft/50 cursor-pointer"
                  >
                    <div className="flex items-center justify-between gap-2">
                      <div className="flex items-center gap-1.5">
                        <Badge tone={priorityTone(task.priority)}>
                          {task.priority || 'P2'}
                        </Badge>
                        <StatusPill tone={statusTone(task.status)}>
                          {task.status}
                        </StatusPill>
                        {task.status === 'queued' && (
                          <span
                            data-debug-id={`chain-overview-queued-slot-${taskId}`}
                            className="rounded bg-warning-soft px-1.5 py-0.5 text-[11px] font-semibold text-warning"
                          >
                            Queued (Waiting for {getQueuedWaitingSlotName(task, agentIdentities)} slot)
                          </span>
                        )}
                      </div>
                      <span className="font-mono text-[10px] text-muted">{taskId}</span>
                    </div>

                    <h4 className="text-xs font-semibold text-primary mt-1 line-clamp-1">
                      <VaultText value={task.title} as="span" />
                    </h4>

                    <div className="mt-1.5 flex items-center justify-between text-[11px] text-muted">
                      <span className="truncate max-w-[140px]">
                        Worker: <strong className="text-primary font-normal">{assignee}</strong>
                      </span>
                      <span className="truncate max-w-[140px]">
                        Reviewer: <strong className="text-primary font-normal">{reviewer}</strong>
                      </span>
                    </div>
                  </div>
                );
              })}
            </div>
          )
        )}
      </section>

      {/* SECTION 2: Chain Artifacts */}
      <section data-debug-id="chain-overview-section-artifacts" className="space-y-2.5">
        <button
          type="button"
          data-debug-id="chain-overview-section-toggle-artifacts"
          onClick={() => toggleSection('artifacts')}
          aria-expanded={!isCollapsed('artifacts')}
          className="flex w-full items-center justify-between text-left group cursor-pointer"
        >
          <div className="flex items-center gap-1.5">
            <Icon
              name={isCollapsed('artifacts') ? 'chevron-right' : 'chevron-down'}
              size={14}
              className="text-muted group-hover:text-primary transition-colors"
            />
            <Icon name="file" size={14} className="text-muted" />
            <h3 className="text-xs font-semibold uppercase tracking-wider text-muted group-hover:text-primary transition-colors">
              Chain Artifacts ({artifacts.length})
            </h3>
          </div>
        </button>

        {!isCollapsed('artifacts') && (
          isArtifactsLoading ? (
            <div className="flex items-center gap-2 text-xs text-muted py-2">
              <Spinner size="sm" /> Loading artifacts…
            </div>
          ) : artifacts.length === 0 ? (
            <p className="text-xs text-muted py-1">No artifacts produced in this chain yet.</p>
          ) : (
            <div className="grid gap-1.5 max-h-56 overflow-y-auto pr-1">
              {artifacts.map((artifact) => {
                const artId = artifact.artifact_id || artifact.artifactId || artifact.id;
                const name = artifact.name || artId;
                const kind = String(artifact.kind || 'file').toLowerCase();
                const size = formatBytes(artifact.size_bytes || artifact.sizeBytes || 0);
                const time = formatRelativeTime(artifact.created_unix_ms || artifact.createdAt || artifact.created_at);

                let iconName: any = 'file';
                if (kind === 'image' || kind.startsWith('image/')) iconName = 'eye';
                else if (kind === 'log' || kind === 'terminal') iconName = 'terminal';
                else if (kind === 'diff' || kind === 'code') iconName = 'spark';

                return (
                  <div
                    key={artId}
                    data-debug-id={`chain-overview-artifact-${artId}`}
                    onClick={() => setActiveArtifactId(artId)}
                    className="flex items-center justify-between gap-2 rounded-lg border border-subtle bg-surface-secondary/20 px-2.5 py-1.5 transition-colors hover:bg-neutral-soft/60 cursor-pointer"
                  >
                    <div className="flex items-center gap-2 min-w-0">
                      <Icon name={iconName} size={14} className="text-accent shrink-0" />
                      <span className="text-xs font-medium text-primary truncate" title={typeof name === 'string' && !isVaultArmored(name) ? name : undefined}>
                        <VaultText value={name} fallback={artId} />
                      </span>
                    </div>
                    <div className="flex items-center gap-2 text-[10px] text-muted shrink-0">
                      <span>{size}</span>
                      {time && <span>· {time}</span>}
                    </div>
                  </div>
                );
              })}
            </div>
          )
        )}
      </section>

      {/* SECTION 3: VCS Changes */}
      {projectVcsEnabled ? (
      <section data-debug-id="chain-overview-section-vcs" className="space-y-2.5">
        <div className="flex items-center justify-between">
          <button
            type="button"
            data-debug-id="chain-overview-section-toggle-vcs"
            onClick={() => toggleSection('vcs')}
            aria-expanded={!isCollapsed('vcs')}
            className="flex items-center gap-1.5 text-left group cursor-pointer"
          >
            <Icon
              name={isCollapsed('vcs') ? 'chevron-right' : 'chevron-down'}
              size={14}
              className="text-muted group-hover:text-primary transition-colors"
            />
            <Icon name="layers" size={14} className="text-muted" />
            <h3 className="text-xs font-semibold uppercase tracking-wider text-muted group-hover:text-primary transition-colors">
              VCS Changes
            </h3>
          </button>
          {onOpenVcsFiles && (
            <button
              type="button"
              data-debug-id="chain-overview-vcs-all-changes-btn"
              onClick={onOpenVcsFiles}
              className="text-[11px] font-medium text-accent hover:underline"
            >
              All Changes
            </button>
          )}
        </div>

        {!isCollapsed('vcs') && (
          <div className="rounded-lg border border-subtle bg-surface-secondary/30 p-2.5 space-y-2">
            {/* Status summary chips */}
            <div className="flex items-center gap-2 flex-wrap text-xs">
              <span className="rounded bg-warning-soft px-2 py-0.5 text-[11px] font-semibold text-warning">
                {vcsModifiedCount} Modified
              </span>
              <span className="rounded bg-success-soft px-2 py-0.5 text-[11px] font-semibold text-success">
                {vcsStagedCount} Staged
              </span>
              <span className="rounded bg-neutral-soft px-2 py-0.5 text-[11px] font-semibold text-muted">
                {vcsUntrackedCount} Untracked
              </span>
              {vcsStatusQuery.data?.branch && (
                <span className="ml-auto text-[11px] font-mono text-muted truncate max-w-[120px]">
                  {vcsStatusQuery.data.branch}
                </span>
              )}
            </div>

            {/* Changed files preview list */}
            {vcsFiles.length === 0 ? (
              <p className="text-xs text-muted pt-1">Working tree is clean.</p>
            ) : (
              <div className="space-y-1 pt-1 max-h-48 overflow-y-auto">
                {vcsFiles.slice(0, 10).map((file) => {
                  const statusChar =
                    file.status === 'modified' ? 'M'
                    : file.status === 'added' ? 'A'
                    : file.status === 'deleted' ? 'D'
                    : file.status === 'renamed' ? 'R'
                    : 'U';
                  const statusColor =
                    file.status === 'modified' ? 'text-warning bg-warning-soft'
                    : file.status === 'added' ? 'text-success bg-success-soft'
                    : file.status === 'deleted' ? 'text-danger bg-danger-soft'
                    : 'text-muted bg-neutral-soft';

                  return (
                    <div
                      key={file.path}
                      data-debug-id={`chain-overview-vcs-file-${file.path}`}
                      onClick={() => {
                        if (onOpenFileDiff) {
                          onOpenFileDiff(file.path);
                        }
                      }}
                      className="flex items-center justify-between gap-2 rounded px-2 py-1 text-xs transition-colors hover:bg-neutral-soft cursor-pointer"
                    >
                      <div className="flex items-center gap-2 min-w-0">
                        <span className={`grid h-4 w-4 place-items-center rounded text-[10px] font-bold ${statusColor}`}>
                          {statusChar}
                        </span>
                        <span className="font-mono text-[11px] text-primary truncate" title={file.path}>
                          {file.path}
                        </span>
                      </div>
                      {(file.additions > 0 || file.deletions > 0) && (
                        <div className="flex items-center gap-1.5 shrink-0">
                          <div className="font-mono text-[10px]">
                            {file.additions > 0 && <span className="text-success">+{file.additions} </span>}
                            {file.deletions > 0 && <span className="text-danger">-{file.deletions}</span>}
                          </div>
                        </div>
                      )}
                    </div>
                  );
                })}
                {vcsFiles.length > 10 && (
                  <div className="text-center pt-1">
                    <button
                      type="button"
                      onClick={onOpenVcsFiles}
                      className="text-[11px] text-accent hover:underline"
                    >
                      + {vcsFiles.length - 10} more files
                    </button>
                  </div>
                )}
              </div>
            )}
          </div>
        )}
      </section>
      ) : null}

      {/* SECTION 6: Fleet Terminals */}
      <section data-debug-id="chain-overview-section-fleet-terminals" className="space-y-2.5">
        <button
          type="button"
          data-debug-id="chain-overview-section-toggle-terminals"
          onClick={() => toggleSection('terminals')}
          aria-expanded={!isCollapsed('terminals')}
          className="flex w-full items-center justify-between text-left group cursor-pointer"
        >
          <div className="flex items-center gap-1.5">
            <Icon
              name={isCollapsed('terminals') ? 'chevron-right' : 'chevron-down'}
              size={14}
              className="text-muted group-hover:text-primary transition-colors"
            />
            <Icon name="terminal" size={14} className="text-muted" />
            <h3 className="text-xs font-semibold uppercase tracking-wider text-muted group-hover:text-primary transition-colors">
              Fleet Terminals ({capturedMembers.length})
            </h3>
          </div>
        </button>

        {!isCollapsed('terminals') && (
          capturedMembers.length === 0 ? (
            <p className="text-xs text-muted py-1">
              No active terminal captures. Click the terminal icon on an agent card in Chain Agents to capture and monitor its output.
            </p>
          ) : (
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 items-start">
              {capturedMembers.map((member) => {
                const instId = member.agentInstanceId || member.agent_instance_id;
                const name = member.displayName || member.display_name || instId;
                const role = member.role || 'worker';
                const rawStatus = String(member.runtimeStatus || member.runtime_status || 'stopped').toLowerCase();
                const isStopped = rawStatus === 'stopped' || rawStatus === 'failed';
                const isOpen = Boolean(openTerminalIds[instId]);
                const isPinned = pinnedAgentIds.includes(instId);

                return (
                  <div
                    key={instId}
                    data-debug-id={`chain-overview-terminal-accordion-${instId}`}
                    className="rounded-lg border border-subtle bg-surface-secondary/20 overflow-hidden"
                  >
                    {/* Accordion Header */}
                    <div
                      onClick={() => toggleTerminal(instId)}
                      className="flex items-center justify-between p-2.5 transition-colors hover:bg-neutral-soft/40 cursor-pointer"
                    >
                      <div className="flex items-center gap-2 min-w-0">
                        <Icon name={isOpen ? 'chevron-down' : 'chevron-right'} size={14} className="text-muted shrink-0" />
                        <StatusDot tone={statusTone(rawStatus)} label={rawStatus} size="sm" />
                        <span className="text-xs font-semibold text-primary truncate max-w-[160px]">
                          {name}
                        </span>
                        <Badge tone={roleTone(role)}>
                          {role}
                        </Badge>
                      </div>

                      <div className="flex items-center gap-2 shrink-0">
                        <span className="text-[11px] text-muted">
                          {rawStatus}
                        </span>
                        {/* Pin to Agent Monitor */}
                        <button
                          type="button"
                          title={isPinned ? 'Unpin from monitor' : 'Pin to Agent Monitor'}
                          aria-label={isPinned ? 'Unpin from monitor' : 'Pin to Agent Monitor'}
                          aria-pressed={isPinned}
                          data-debug-id={`chain-overview-terminal-pin-${instId}`}
                          onClick={(e) => handleTogglePinAgent(instId, e)}
                          className={`grid h-6 w-6 place-items-center rounded hover:bg-neutral-soft ${
                            isPinned ? 'text-accent' : 'text-muted hover:text-primary'
                          }`}
                        >
                          <Icon name="grid" size={12} />
                        </button>
                        {/* Maximize / Pop out button */}
                        <button
                          type="button"
                          title="Maximize terminal"
                          aria-label="Maximize terminal"
                          onClick={(e) => {
                            e.stopPropagation();
                            setMaximizedTerminalInstanceId(instId);
                          }}
                          className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
                        >
                          <Icon name="maximize" size={12} />
                        </button>
                      </div>
                    </div>

                    {/* STRICT Lazy Rendering: only mounted when accordion is OPEN */}
                    {isOpen && (
                      <div className="border-t border-subtle bg-canvas p-2">
                        {isStopped ? (
                          <div
                            data-debug-id={`chain-overview-stopped-terminal-${instId}`}
                            className="flex flex-col items-center justify-center h-44 rounded border border-subtle bg-surface-secondary/40 p-4 text-center space-y-2.5"
                          >
                            <div className="flex items-center gap-2 text-muted">
                              <Icon name="terminal" size={18} />
                              <span className="font-mono text-xs font-medium">Agent instance is stopped</span>
                            </div>
                            <p className="text-[11px] text-muted max-w-xs">
                              Start this agent to launch its container and subscribe to its interactive terminal pane feed.
                            </p>
                            <button
                              type="button"
                              disabled={startingInstanceId === instId}
                              onClick={(e) => handleStartAgent(instId, e)}
                              title="Start Agent"
                              aria-label="Start Agent"
                              className="grid h-8 w-8 place-items-center rounded-lg bg-accent text-accent-fg hover:opacity-90 disabled:opacity-50 transition-opacity shadow-xs"
                            >
                              {startingInstanceId === instId ? (
                                <Spinner size="sm" />
                              ) : (
                                <Icon name="play" size={14} />
                              )}
                            </button>
                          </div>
                        ) : (
                          <AgentPaneComposerPanel
                            agentInstanceId={instId}
                            isExpanded={true}
                            isActiveTab={true}
                            runtimeStatus={rawStatus}
                            hideHeader={true}
                          />
                        )}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          )
        )}
      </section>

      {/* ArtifactViewer Modal Overlay */}
      {activeArtifactId && (
        <ArtifactViewer
          artifactId={activeArtifactId}
          daemonUrl={viewerSession.daemonUrl}
          clientToken={viewerSession.clientToken || 'v1'}
          onClose={() => setActiveArtifactId('')}
        />
      )}

      {/* Maximized Terminal Modal Overlay */}
      {maximizedTerminalInstanceId && (
        <div
          data-debug-id="chain-overview-maximized-terminal-modal"
          className="fixed inset-x-0 top-0 app-viewport-height z-50 flex flex-col bg-canvas/95 backdrop-blur-md p-4 sm:p-6"
        >
          <div className="flex items-center justify-between border-b border-subtle pb-3">
            <div className="flex items-center gap-2">
              <Icon name="terminal" size={18} className="text-accent" />
              <span className="font-semibold text-sm text-primary">
                Fleet Terminal —{' '}
                {members.find((m) => (m.agentInstanceId || m.agent_instance_id) === maximizedTerminalInstanceId)?.displayName ||
                  maximizedTerminalInstanceId}
              </span>
            </div>
            <div className="flex items-center gap-2">
              <button
                type="button"
                data-debug-id={`chain-overview-maximized-terminal-pin-${maximizedTerminalInstanceId}`}
                title={
                  maximizedTerminalInstanceId && pinnedAgentIds.includes(maximizedTerminalInstanceId)
                    ? 'Unpin from monitor'
                    : 'Pin to Agent Monitor'
                }
                aria-label={
                  maximizedTerminalInstanceId && pinnedAgentIds.includes(maximizedTerminalInstanceId)
                    ? 'Unpin from monitor'
                    : 'Pin to Agent Monitor'
                }
                aria-pressed={Boolean(maximizedTerminalInstanceId && pinnedAgentIds.includes(maximizedTerminalInstanceId))}
                onClick={(e) => handleTogglePinAgent(maximizedTerminalInstanceId, e)}
                className={`grid h-8 w-8 place-items-center rounded-lg hover:bg-neutral-soft ${
                  maximizedTerminalInstanceId && pinnedAgentIds.includes(maximizedTerminalInstanceId)
                    ? 'text-accent'
                    : 'text-muted hover:text-primary'
                }`}
              >
                <Icon name="grid" size={14} />
              </button>
              <button
                type="button"
                data-debug-id="chain-overview-maximized-terminal-close"
                aria-label="Restore terminal"
                onClick={() => setMaximizedTerminalInstanceId(null)}
                className="grid h-8 w-8 place-items-center rounded-lg text-muted hover:bg-neutral-soft hover:text-primary"
              >
                <Icon name="minimize" size={16} />
              </button>
            </div>
          </div>
          <div className="flex-1 min-h-0 pt-3">
            <AgentPaneComposerPanel
              agentInstanceId={maximizedTerminalInstanceId}
              isExpanded={true}
              isActiveTab={true}
              className="h-full !max-h-full"
              hideHeader={true}
            />
          </div>
        </div>
      )}
    </div>
  );
}
