// migrated: ui-audit W2
import React, { useEffect, useRef, useState } from 'react';
import { useCreateArtifactMutation } from '../../api/endpoints/artifacts';
import { ArtifactAttachmentPreview } from '../ArtifactAttachmentPreview';
import { TaskCommentsThread } from './TaskCommentsThread';
import { MAX_UPLOAD_BYTES } from '../ArtifactUpload';
import Markdown from '../Markdown';

import { Checkbox, Icon, PageShell, ResourceDetailHeader, Select, StatusDot, runtimeStateFromStatus, runtimeStateLabel, runtimeStatusToTone, useViewport } from '@ui';
import {
  FleetSlotChips,
  FleetManagementDrawer,
  getQueuedWaitingSlotName,
  formatFleetRoleName,
  isRoleAssignedWithoutLiveInstance,
  hasLiveNudgeTarget,
} from '../tasks/FleetManagementDrawer';
import {
  appendArtifactLinks,
  artifactIdFromLink,
  artifactIdsFromText,
  artifactKindForFile,
  artifactLinkFromResponse,
  artifactMimeForFile,
  artifactUploadName,
  clipboardFilesFromEvent,
} from '../../utils/artifactUpload';
import {
  useFetchTaskChainDetailQuery,
  useFetchChainTaskDetailQuery,
  useCreateTaskMutation,
  useUpdateTaskDetailMutation,
  useSetTaskStatusMutation,
  useCancelTaskDetailMutation,
  useAddTaskCommentMutation,
  useVoteTaskMutation,
  useNudgeTaskMutation,
  useAddChainMemberMutation,
  useRemoveChainMemberMutation,
  useReconcileTaskChainMutation,
  useUpdateTaskChainMutation,
} from '../../api/endpoints/tasks';
import { useDispatch, useSelector } from 'react-redux';
import { VaultText } from '../vault/VaultText';
import { isVaultArmored, decryptVaultText } from '../../utils/vaultContent';
import { selectIsVaultUnlocked, getActiveVaultKey } from '../../store/vaultSlice';
import {
  upsertAgentInCaches,
  useCreateAgentInstanceInChainMutation,
  useFetchAgentInstanceQuery,
  useFetchAgentIdentityQuery,
  useListAgentIdentitiesQuery,
  useListAgentInstancesQuery,
} from '../../api/endpoints/agents';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { useListAllAgentInstancesQuery } from '../../api/endpoints/actions';
import {
  bridgeLabel,
  launchProvidersFor,
  launchModelsFor,
  launchableBridgeRows,
} from '../../utils/bridgeLaunchOptions';
import { effectiveChainBridgeId, taskBridgeDisplay, taskBridgeOptions } from '../../utils/taskBridgePin';
import { useIsMobile } from '../shell/responsive';
import ChainActiveServersPanel from '../shells/ChainActiveServersPanel';
import { useAuthUser } from '../auth/AuthUserContext';
import { useOpenAgentChat } from '../aux/openAgentChatContext';

interface TaskChainOverviewProps {
  chainId: string;
  // Optional deep-link target: when set (from '/chains/:chainId/tasks/:taskId'),
  // the matching task row is expanded and scrolled into view once it has loaded.
  focusTaskId?: string;
  onClose?: () => void;
  isMobile?: boolean;
  /**
   * Render for a `ResourceContainer` detail pane instead of as a standalone page.
   *
   * When set, the outer `PageShell` is replaced by a plain scroll container and the chain
   * title / status / fleet chips move into a `ResourceDetailHeader` (REQ-TCUI-3). The page
   * body is identical either way — both branches render the same `body` node, so the
   * standalone rendering cannot drift from the embedded one.
   */
  embedded?: boolean;
  /**
   * Aux tab mode (embedded only): drop the title / id / back bar, which the aux
   * tab strip already provides, keeping only the in-content chain controls.
   */
  hideTitleBar?: boolean;
}

// Label formatters for instance / member <Select> options (EL-025). Names are
// resolved upfront by the caller (from the selected agent, or the batched
// instance-name map) and passed in, so these stay pure — the custom @ui Select
// builds its listbox from option DATA, not from option-returning components.
export function agentInstanceOptionLabel(name: string, instanceId: string, suffix = '', runtimeStatus?: string): string {
  const trimmed = String(instanceId || '').trim();
  const resolved = name || trimmed;
  const base = resolved !== trimmed ? `${resolved} (${trimmed})${suffix}` : `${trimmed}${suffix}`;
  return runtimeStatus ? `${base} · ${runtimeStatus}` : base;
}

export function memberInstanceOptionLabel(role: string, name: string, instanceId: string): string {
  const trimmed = String(instanceId || '').trim();
  const resolved = name || trimmed;
  return resolved !== trimmed ? `${role}: ${resolved} (${trimmed})` : `${role}: ${trimmed}`;
}

type CommentAttachmentStatus = 'uploading' | 'uploaded' | 'error';

type CommentAttachment = {
  localId: string;
  id: string;
  link: string;
  name: string;
  file: File;
  status: CommentAttachmentStatus;
  error: string;
};

// Lazily fetches + renders a task's Markdown description. The task-list payload
// omits description to stay light; this component only mounts when a task row is
// expanded, so the single-task GET happens on demand. `fallback` is any
// description already present on the list row (usually empty now).
const TaskDescription: React.FC<{ chainId: string; taskId: string; fallback?: string }> = ({ chainId, taskId, fallback }) => {
  const { data, isFetching } = useFetchChainTaskDetailQuery(
    { chainId, taskId },
    { skip: !chainId || !taskId },
  );
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const rawDescription = String(data?.task?.description ?? fallback ?? '').trim();
  const isArmored = isVaultArmored(rawDescription);

  const [decryptedText, setDecryptedText] = useState<string | null>(null);

  useEffect(() => {
    let mounted = true;
    const activeKey = getActiveVaultKey();
    if (!isArmored || !isUnlocked || !activeKey) {
      setDecryptedText(null);
      return;
    }
    decryptVaultText(rawDescription, activeKey)
      .then((decrypted) => {
        if (mounted) setDecryptedText(decrypted);
      })
      .catch((err) => {
        if (mounted) {
          console.error('Failed to decrypt task description:', err);
          setDecryptedText(rawDescription);
        }
      });
    return () => {
      mounted = false;
    };
  }, [rawDescription, isArmored, isUnlocked]);

  if (isFetching && !rawDescription) {
    return (
      <div data-debug-id={`taskchain-task-description-${taskId}`} className="flex items-center gap-1.5 text-caption text-muted">
        <Icon name="refresh" size={12} className="animate-spin" /> Loading description…
      </div>
    );
  }
  if (!rawDescription) return null;

  if (isArmored && !isUnlocked) {
    return (
      <div data-debug-id={`taskchain-task-description-${taskId}`} className="py-1">
        <VaultText value={rawDescription} as="div" />
      </div>
    );
  }

  const displayText = decryptedText ?? rawDescription;
  const description = displayText;

  return (
    <div data-debug-id={`taskchain-task-description-${taskId}`} className="text-[11.5px] leading-5 text-primary">
      <Markdown source={description} compact copyAll={false} />
    </div>
  );
};

export const TaskChainOverview: React.FC<TaskChainOverviewProps> = ({
  chainId,
  focusTaskId,
  onClose,
  isMobile,
  embedded,
  hideTitleBar,
}) => {
  const authUser = useAuthUser();
  const username = String(authUser?.user_id || '').trim();
  // Read the viewport the same way `ResourceContainer`/`ResourceDetailHeader` do, so the
  // embedded panes and their container can never disagree about the desktop boundary. The
  // `isMobile` prop is mobile-only (<=767px) while the container two-panes only on desktop
  // (>1023px), which would otherwise leave the 768-1023px tablet band with no back button.
  const viewport = useViewport();
  const { data, isLoading, error, refetch } = useFetchTaskChainDetailQuery(
    { chainId },
    { skip: !chainId }
  );

  // Batched instance-name lookup for member/instance <Select> options — one list
  // fetch instead of a per-option identity fetch (replaces the old per-<option>
  // AgentInstanceOption/MemberInstanceOption components; EL-025).
  const allInstancesQuery = useListAllAgentInstancesQuery();
  const instanceNameById = React.useMemo(() => {
    const map = new Map<string, string>();
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    for (const inst of (allInstancesQuery.data?.instances || []) as any[]) {
      const id = String(inst.agent_instance_id || inst.agentInstanceId || inst.id || '');
      const name = String(inst.display_name || inst.displayName || inst.agent_id || inst.agentId || '');
      if (id) map.set(id, name);
    }
    return map;
  }, [allInstancesQuery.data]);

  const allInstances = React.useMemo(
    () => (allInstancesQuery.data?.instances || []) as any[],
    [allInstancesQuery.data]
  );

  const [createTask] = useCreateTaskMutation();
  const [updateTask] = useUpdateTaskDetailMutation();
  const [setStatus] = useSetTaskStatusMutation();
  const [cancelTask] = useCancelTaskDetailMutation();
  const [addComment] = useAddTaskCommentMutation();
  const [createArtifact] = useCreateArtifactMutation();
  const [voteTask] = useVoteTaskMutation();
  const [nudgeTask] = useNudgeTaskMutation();
  const [addMember] = useAddChainMemberMutation();
  const [removeMember] = useRemoveChainMemberMutation();
  const [createInstanceInChain, { isLoading: addingAgent }] = useCreateAgentInstanceInChainMutation();
  const [reconcileChain, reconcileState] = useReconcileTaskChainMutation();
  const [updateTaskChain, { isLoading: isUpdatingChain }] = useUpdateTaskChainMutation();
  const [reconcileMsg, setReconcileMsg] = useState('');

  const handleReconcile = async () => {
    if (reconcileState.isLoading || !chainId) return;
    setReconcileMsg('');
    try {
      const res: any = await reconcileChain({ chainId }).unwrap();
      const promoted = Number(res?.promoted ?? res?.data?.promoted ?? 0);
      setReconcileMsg(`Reconciled — ${promoted} task${promoted === 1 ? '' : 's'} promoted. Reconcile is an automatic self-healing background guarantee.`);
      refetch();
    } catch (e: any) {
      setReconcileMsg(String(e?.error || e?.message || 'Reconcile failed'));
    }
  };
  const dispatch = useDispatch();

  // Data sources for the Add-Agent popup's dependent selects.
  const agentIdentitiesQuery = useListAgentIdentitiesQuery();
  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: 120000, refetchOnMountOrArgChange: true });

  // Local state
  // H12: chain description collapsed by default so the chain view is scannable.
  const [descExpanded, setDescExpanded] = useState(false);
  const [completedTasksExpanded, setCompletedTasksExpanded] = useState(false);
  const [cancelledTasksExpanded, setCancelledTasksExpanded] = useState(false);
  const [expandedTaskIds, setExpandedTaskIds] = useState<Record<string, boolean>>({});
  // Tracks the focusTaskId we've already auto-opened so a deep-link scroll happens
  // exactly once (background refetches replace the tasks array but must not yank the
  // user back to the task on every poll).
  const focusedTaskRef = useRef<string | null>(null);
  const [commentInputs, setCommentInputs] = useState<Record<string, string>>({});
  const [commentAttachments, setCommentAttachments] = useState<Record<string, CommentAttachment[]>>({});

  // Modal state
  const [showNewTaskModal, setShowNewTaskModal] = useState(false);
  const [newTaskTitle, setNewTaskTitle] = useState('');
  const [newTaskDesc, setNewTaskDesc] = useState('');
  const [newTaskAssigneeMode, setNewTaskAssigneeMode] = useState<'agent' | 'unassigned' | 'user'>('agent');
  const [newTaskAssigneeMemberInstanceId, setNewTaskAssigneeMemberInstanceId] = useState('');
  const [newTaskAssigneeAgentId, setNewTaskAssigneeAgentId] = useState('');
  const [newTaskAssigneeInstanceId, setNewTaskAssigneeInstanceId] = useState('');
  const [newTaskAssigneeUserId, setNewTaskAssigneeUserId] = useState('');
  const [newTaskStagedReviewerRefs, setNewTaskStagedReviewerRefs] = useState<any[]>([]);
  const [newTaskRequiresUserApproval, setNewTaskRequiresUserApproval] = useState(false);
  const [newTaskAddReviewerMode, setNewTaskAddReviewerMode] = useState<'agent'>('agent');
  const [newTaskAddReviewerMemberInstanceId, setNewTaskAddReviewerMemberInstanceId] = useState('');
  const [newTaskAddReviewerAgentId, setNewTaskAddReviewerAgentId] = useState('');
  const [newTaskAddReviewerInstanceId, setNewTaskAddReviewerInstanceId] = useState('');
  const [newTaskDependsOnIds, setNewTaskDependsOnIds] = useState<string[]>([]);
  // REQ-TB-5: '' = Inherit (coordinator bridge) — the default create pins nothing.
  const [newTaskBridgeId, setNewTaskBridgeId] = useState('');
  const [newTaskError, setNewTaskError] = useState('');
  const [creatingTask, setCreatingTask] = useState(false);
  const [isFleetDrawerOpen, setIsFleetDrawerOpen] = useState(false);
  const [showAddMemberModal, setShowAddMemberModal] = useState(false);
  const [newMemberRole, setNewMemberRole] = useState('worker');
  // H14: two modes — add an EXISTING agent instance (default; the user's mental
  // model of 'add a member'), or LAUNCH a new instance. The existing path uses
  // addChainMember (cookieMutation) directly and avoids the session-token launch
  // transport that silently no-ops in the cookie-authenticated shell.
  const [addMode, setAddMode] = useState<'existing' | 'launch'>('existing');
  const [addExistingInstanceId, setAddExistingInstanceId] = useState('');
  const [addingExisting, setAddingExisting] = useState(false);
  // Add-Agent popup selection state (identity -> bridge -> provider -> model).
  const [addAgentId, setAddAgentId] = useState('');
  const [addBridgeId, setAddBridgeId] = useState('');
  const [addProvider, setAddProvider] = useState('');
  const [addModel, setAddModel] = useState('');
  const [addAgentError, setAddAgentError] = useState('');

  // Edit Assignee Modal State
  const [editingAssigneeTask, setEditingAssigneeTask] = useState<any | null>(null);
  const [editAssigneeMode, setEditAssigneeMode] = useState<'role' | 'user' | 'unassigned'>('role');
  const [editAssigneeAgentId, setEditAssigneeAgentId] = useState('');
  const [editAssigneeUserId, setEditAssigneeUserId] = useState('');
  const [savingAssignee, setSavingAssignee] = useState(false);
  const [assigneeError, setAssigneeError] = useState('');

  // Edit Reviewers Modal State
  const [editingReviewersTask, setEditingReviewersTask] = useState<any | null>(null);
  const [stagedReviewerRefs, setStagedReviewerRefs] = useState<any[]>([]);
  const [editRequiresUserApproval, setEditRequiresUserApproval] = useState(false);
  const [addReviewerMode, setAddReviewerMode] = useState<'member' | 'existing'>('member');
  const [addReviewerMemberInstanceId, setAddReviewerMemberInstanceId] = useState('');
  const [addReviewerAgentId, setAddReviewerAgentId] = useState('');
  const [addReviewerInstanceId, setAddReviewerInstanceId] = useState('');
  const [savingReviewers, setSavingReviewers] = useState(false);
  const [reviewersError, setReviewersError] = useState('');

  // Edit Dependencies Modal State
  const [editingDependenciesTask, setEditingDependenciesTask] = useState<any | null>(null);
  const [stagedDependsOnIds, setStagedDependsOnIds] = useState<string[]>([]);
  const [savingDependencies, setSavingDependencies] = useState(false);
  const [dependenciesError, setDependenciesError] = useState('');

  // Edit Bridge Modal State (REQ-TB-5)
  const [editingBridgeTask, setEditingBridgeTask] = useState<any | null>(null);
  const [editBridgeId, setEditBridgeId] = useState('');
  const [savingBridge, setSavingBridge] = useState(false);
  const [bridgeError, setBridgeError] = useState('');

  const chain = data?.chain;
  const tasks: any[] = chain?.tasks || [];
  const members: any[] = chain?.members || [];

  const isVaultUnlocked = useSelector(selectIsVaultUnlocked);
  const [decryptedDescription, setDecryptedDescription] = useState<string>('');

  useEffect(() => {
    let active = true;
    const chainDesc = chain?.description;
    if (!chainDesc || !isVaultArmored(chainDesc)) {
      setDecryptedDescription(chainDesc || '');
      return;
    }
    const activeKey = getActiveVaultKey();
    if (!isVaultUnlocked || !activeKey) {
      setDecryptedDescription('');
      return;
    }
    decryptVaultText(chainDesc, activeKey)
      .then((t) => {
        if (active) setDecryptedDescription(t);
      })
      .catch(() => {
        if (active) setDecryptedDescription(chainDesc);
      });
    return () => {
      active = false;
    };
  }, [chain?.description, isVaultUnlocked]);

  const [decryptedTitle, setDecryptedTitle] = useState<string>('');

  useEffect(() => {
    let active = true;
    const chainTitle = chain?.title;
    if (!chainTitle || !isVaultArmored(chainTitle)) {
      setDecryptedTitle(chainTitle || '');
      return;
    }
    const activeKey = getActiveVaultKey();
    if (!isVaultUnlocked || !activeKey) {
      setDecryptedTitle('');
      return;
    }
    decryptVaultText(chainTitle, activeKey)
      .then((t) => {
        if (active) setDecryptedTitle(t);
      })
      .catch(() => {
        if (active) setDecryptedTitle(chainTitle);
      });
    return () => {
      active = false;
    };
  }, [chain?.title, isVaultUnlocked]);

  // Inline title editing state
  const [isEditingTitle, setIsEditingTitle] = useState(false);
  const [editTitleValue, setEditTitleValue] = useState('');
  const [isSavingTitle, setIsSavingTitle] = useState(false);
  const titleInputRef = useRef<HTMLInputElement>(null);

  const startEditingTitle = async () => {
    let currentTitle = decryptedTitle || chain?.title || '';
    if (chain?.title && isVaultArmored(chain.title) && (!decryptedTitle || isVaultArmored(decryptedTitle))) {
      const activeKey = getActiveVaultKey();
      if (isVaultUnlocked && activeKey) {
        try {
          currentTitle = await decryptVaultText(chain.title, activeKey);
        } catch (e) {
          console.error('Failed to decrypt chain title for editing:', e);
        }
      }
    }
    setEditTitleValue(currentTitle);
    setIsEditingTitle(true);
  };

  useEffect(() => {
    if (isEditingTitle) {
      titleInputRef.current?.focus();
      titleInputRef.current?.select();
    }
  }, [isEditingTitle]);

  const handleSaveTitle = async () => {
    const trimmed = editTitleValue.trim();
    if (!trimmed || !chainId) return;
    setIsSavingTitle(true);
    try {
      await updateTaskChain({ chainId, title: trimmed }).unwrap();
      setIsEditingTitle(false);
    } catch (err: any) {
      console.error('Failed to update task chain title:', err);
    } finally {
      setIsSavingTitle(false);
    }
  };

  const handleCancelEditTitle = () => {
    setIsEditingTitle(false);
    setEditTitleValue('');
  };

  const handleTitleKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    e.stopPropagation();
    if (e.key === 'Enter') {
      e.preventDefault();
      void handleSaveTitle();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      handleCancelEditTitle();
    }
  };

  const handleChainStatusChange = async (newStatus: string) => {
    if (!chainId || newStatus === chain?.status) return;
    try {
      await updateTaskChain({ chainId, status: newStatus }).unwrap();
    } catch (err: any) {
      console.error('Failed to update task chain status:', err);
    }
  };

  // Separate active, completed, and cancelled tasks.
  // Completed/cancelled tasks are sorted chronologically by completion time (updated_at / created_at).
  const isTaskCompleted = (t: any) => t.status === 'completed' || t.status === 'validated_good';
  const isTaskCancelled = (t: any) => t.status === 'cancelled';
  const activeTasks = tasks.filter((t: any) => !isTaskCompleted(t) && !isTaskCancelled(t));
  const completedTasks = tasks
    .filter((t: any) => isTaskCompleted(t))
    .sort((a: any, b: any) => {
      const timeA = new Date(a.updated_at || a.updatedAt || a.created_at || a.createdAt || 0).getTime();
      const timeB = new Date(b.updated_at || b.updatedAt || b.created_at || b.createdAt || 0).getTime();
      return timeA - timeB;
    });
  const cancelledTasks = tasks
    .filter((t: any) => isTaskCancelled(t))
    .sort((a: any, b: any) => {
      const timeA = new Date(a.updated_at || a.updatedAt || a.created_at || a.createdAt || 0).getTime();
      const timeB = new Date(b.updated_at || b.updatedAt || b.created_at || b.createdAt || 0).getTime();
      return timeA - timeB;
    });

  // Deep-link focus (UI: '/chains/:chainId/tasks/:taskId'): once the task list has
  // loaded, expand the referenced task (and its collapsed Completed/Cancelled
  // section, if any) and scroll it into view — exactly ONCE per focusTaskId so we
  // never fight the user's manual scroll on a background refetch. A bogus taskId
  // just renders the chain (no crash, no scroll).
  useEffect(() => {
    if (!focusTaskId || focusedTaskRef.current === focusTaskId) return;
    if (isLoading) return; // wait for the async task list before deciding
    const target = tasks.find((t: any) => (t.taskId || t.id) === focusTaskId);
    if (!target) {
      focusedTaskRef.current = focusTaskId; // loaded but absent (bogus id): give up
      return;
    }
    focusedTaskRef.current = focusTaskId;
    setExpandedTaskIds((prev) => ({ ...prev, [focusTaskId]: true }));
    if (isTaskCompleted(target)) setCompletedTasksExpanded(true);
    else if (isTaskCancelled(target)) setCancelledTasksExpanded(true);
    // Scroll after the row (and any just-expanded section) has committed to the DOM.
    const raf = requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        const el = document.querySelector(`[data-debug-id="taskchain-task-row-${focusTaskId}"]`);
        el?.scrollIntoView({ block: 'center' });
      });
    });
    return () => cancelAnimationFrame(raf);
  }, [focusTaskId, tasks, isLoading]);

  // Add-Agent popup dependent option lists (identity -> bridge -> provider -> model).
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const agentIdentities: any[] = agentIdentitiesQuery.data?.agents || [];
  const addBridgeRows = launchableBridgeRows(bridgesQuery.data?.bridges || []);
  // REQ-TB-5: options + name resolution for the per-task bridge pin (create-task
  // select, task-detail chip, and the change-bridge modal share this list).
  const bridgePinOptions = React.useMemo(
    () => {
      const bridges = bridgesQuery.data?.bridges || [];
      const options = taskBridgeOptions(bridges);
      const effective = taskBridgeDisplay(effectiveChainBridgeId(chain, allInstances, bridges), bridges);
      options[0] = { value: '', label: effective.inherited ? 'Unavailable' : effective.label };
      return options;
    },
    [bridgesQuery.data, chain, allInstances],
  );
  const selectedAddBridge = addBridgeRows.find((row) => row.bridgeId === addBridgeId)?.bridge;
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const selectedAddAgent = agentIdentities.find((a: any) => String(a.agent_id || a.agentId || a.id || '') === addAgentId);
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const selectedReviewerAgent = agentIdentities.find((a: any) => String(a.agent_id || a.agentId || a.id || '') === addReviewerAgentId);
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const selectedNewTaskAssigneeAgent = agentIdentities.find((a: any) => String(a.agent_id || a.agentId || a.id || '') === newTaskAssigneeAgentId);
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const selectedNewTaskReviewerAgent = agentIdentities.find((a: any) => String(a.agent_id || a.agentId || a.id || '') === newTaskAddReviewerAgentId);
  // H14: existing instances of the chosen identity (cookieJsonFetch — works in the
  // shell). Only offered in 'existing' mode; skip the fetch otherwise.
  const existingInstancesQuery = useListAgentInstancesQuery(
    { agentId: addAgentId },
    { skip: !addAgentId || addMode !== 'existing' },
  );
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const existingInstances: any[] = existingInstancesQuery.data?.instances || [];
  const reviewerInstancesQuery = useListAgentInstancesQuery(
    { agentId: addReviewerAgentId },
    { skip: !addReviewerAgentId || addReviewerMode !== 'existing' },
  );
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const reviewerExistingInstances: any[] = reviewerInstancesQuery.data?.instances || [];

  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const memberInstanceIds = new Set(members.map((m: any) => String(m.agentInstanceId || m.agent_instance_id || '')));
  const addProviderOptions = selectedAddBridge ? launchProvidersFor(selectedAddBridge) : [];
  const addModelOptions = selectedAddBridge ? launchModelsFor(selectedAddBridge, addProvider) : [];

  const toggleTaskExpanded = (id: string) => {
    setExpandedTaskIds((prev) => ({ ...prev, [id]: !prev[id] }));
  };

  const handleAddNewTaskStagedReviewer = () => {
    let ref: any = null;
    if (newTaskAddReviewerMode === 'agent') {
      if (!newTaskAddReviewerAgentId) return;
      ref = {
        type: 'agent_id',
        agent_id: newTaskAddReviewerAgentId,
        display_name: formatFleetRoleName(newTaskAddReviewerAgentId, agentIdentities),
      };
    }
    if (!ref) return;
    const exists = newTaskStagedReviewerRefs.some((r) =>
      r.type === ref.type && (
        (ref.agent_id && (r.agent_id === ref.agent_id || r.agentId === ref.agent_id)) ||
        (ref.agent_instance_id && r.agent_instance_id === ref.agent_instance_id) ||
        (ref.user_id && r.user_id === ref.user_id)
      )
    );
    if (!exists) {
      setNewTaskStagedReviewerRefs((prev) => [...prev, ref]);
    }
  };

  const handleRemoveNewTaskStagedReviewer = (index: number) => {
    setNewTaskStagedReviewerRefs((prev) => prev.filter((_, i) => i !== index));
  };

  const resetNewTaskForm = () => {
    setNewTaskTitle('');
    setNewTaskDesc('');
    setNewTaskAssigneeMode('agent');
    setNewTaskAssigneeMemberInstanceId('');
    setNewTaskAssigneeAgentId('');
    setNewTaskAssigneeInstanceId('');
    setNewTaskAssigneeUserId('');
    setNewTaskStagedReviewerRefs([]);
    setNewTaskRequiresUserApproval(false);
    setNewTaskAddReviewerMode('agent');
    setNewTaskAddReviewerMemberInstanceId('');
    setNewTaskAddReviewerAgentId('');
    setNewTaskAddReviewerInstanceId('');
    setNewTaskDependsOnIds([]);
    setNewTaskBridgeId('');
    setNewTaskError('');
    setCreatingTask(false);
  };

  const handleCreateTask = async (e: React.FormEvent) => {
    e.preventDefault();
    setNewTaskError('');
    if (!newTaskTitle.trim()) return;

    let assigneeRef: any = undefined;
    if (newTaskAssigneeMode === 'agent') {
      if (!newTaskAssigneeAgentId) {
        setNewTaskError('Please select an agent role.');
        return;
      }
      assigneeRef = {
        type: 'agent_id',
        agent_id: newTaskAssigneeAgentId,
        display_name: formatFleetRoleName(newTaskAssigneeAgentId, agentIdentities),
      };
    } else if (newTaskAssigneeMode === 'user') {
      const uid = newTaskAssigneeUserId.trim();
      if (!uid) {
        setNewTaskError('Please enter a user ID.');
        return;
      }
      assigneeRef = { type: 'user', user_id: uid };
    }

    setCreatingTask(true);
    try {
      const payload: any = {
        chainId,
        title: newTaskTitle.trim(),
        description: newTaskDesc.trim(),
        // '' is dropped by the createTask serialization (absent = inherit).
        bridgeId: newTaskBridgeId,
        requiresUserApproval: newTaskRequiresUserApproval,
      };
      if (assigneeRef !== undefined) {
        payload.assigneeRef = assigneeRef;
      }
      if (newTaskStagedReviewerRefs.length > 0) {
        payload.reviewerRefs = newTaskStagedReviewerRefs;
      }
      if (newTaskDependsOnIds.length > 0) {
        payload.dependsOn = newTaskDependsOnIds;
      }

      await createTask(payload).unwrap();
      resetNewTaskForm();
      setShowNewTaskModal(false);
      refetch();
    } catch (err: any) {
      console.error('Failed to create task:', err);
      setNewTaskError(String(err?.data?.message || err?.message || 'Failed to create task'));
    } finally {
      setCreatingTask(false);
    }
  };

  // Add-Agent popup: LAUNCH a new instance of the chosen agent-id on the chosen
  // bridge/provider/model bound to THIS chain, then add it as a member with the
  // selected role. bridge_id/chain_id/provider/model are honored by the hub's
  // POST /api/v1/agent-instances handler (instance_input_from_body), so this is a
  // pure UI plumb through createAgentInstanceInChain.
  // H14: add an EXISTING agent instance as a member via addChainMember directly
  // (cookieMutation) — no launch, no session token. This is the reliable path in
  // the cookie-authenticated shell and matches the user's 'add a member' model.
  const handleAddExistingMember = async () => {
    setAddAgentError('');
    if (!addExistingInstanceId) { setAddAgentError('Choose an existing agent instance to add.'); return; }
    setAddingExisting(true);
    try {
      const res: any = await addMember({ chainId, agentInstanceId: addExistingInstanceId, role: newMemberRole });
      // RTK Query returns { data } on success or { error } on failure; surface it.
      if (res?.error) {
        setAddAgentError(String(res.error?.error || res.error?.message || 'Failed to add member.'));
        return;
      }
      setShowAddMemberModal(false);
      setAddAgentId(''); setAddExistingInstanceId('');
      refetch();
    } catch (err: any) {
      setAddAgentError(String(err?.message || err || 'Failed to add member.'));
    } finally {
      setAddingExisting(false);
    }
  };

  const handleAddMember = async (e: React.FormEvent) => {
    e.preventDefault();
    setAddAgentError('');
    // H14: route to the reliable existing-instance path when in that mode.
    if (addMode === 'existing') { await handleAddExistingMember(); return; }
    if (!addAgentId) { setAddAgentError('Choose an agent identity to launch.'); return; }
    if (addProvider && !addProviderOptions.includes(addProvider)) { setAddAgentError('Selected provider is not supported by the chosen bridge.'); return; }
    if (addModel && !addModelOptions.includes(addModel)) { setAddAgentError('Selected model is not supported by the chosen bridge/provider.'); return; }
    try {
      const result: any = await createInstanceInChain({
        agentId: addAgentId,
        chainId,
        ...(addBridgeId ? { bridgeId: addBridgeId } : {}),
        ...(addProvider ? { providerProfile: addProvider } : {}),
        ...(addModel ? { model: addModel } : {}),
      }).unwrap();
      // H14: the launch mutation RESOLVES { ok:false } (it does not reject) when the
      // shell has no session token. Do NOT swallow that — surface it instead of a
      // silent no-op.
      // The cookie path (POST /agent-instances) returns the instance object
      // FLAT (agent_instance_id at top level); the older token path nested it under
      // agent_instance/agent. Accept both shapes.
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      const newInstance = result?.agent_instance || result?.agentInstance || result?.agent
        || ((result?.agent_instance_id || result?.agentInstanceId) ? result : undefined);
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      const newInstanceId = String(newInstance?.agent_instance_id || newInstance?.agentInstanceId || '');
      if (result?.ok === false || !newInstanceId) {
        setAddAgentError(String(result?.message || 'Could not launch a new instance in this app session. Use “Add existing instance” instead.'));
        return;
      }
      upsertAgentInCaches(dispatch, newInstance);
      // Ensure the new instance is a chain member with the chosen role (create may
      // not attach the role). Skip if it already landed as a member.
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      const alreadyMember = members.some((m: any) => String(m.agentInstanceId || m.agent_instance_id || '') === newInstanceId);
      if (!alreadyMember) {
        // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
        const memberRes: any = await addMember({ chainId, agentInstanceId: newInstanceId, role: newMemberRole });
        if (memberRes?.error) {
          setAddAgentError(String(memberRes.error?.error || memberRes.error?.message || 'Instance launched but adding it as a member failed.'));
          refetch();
          return;
        }
      }
      setShowAddMemberModal(false);
      setAddAgentId(''); setAddBridgeId(''); setAddProvider(''); setAddModel('');
      refetch();
    } catch (err: any) {
      setAddAgentError(String(err?.message || err || 'Failed to launch and add agent'));
    }
  };

  const handleRemoveMember = async (agentInstanceId: string) => {
    try {
      await removeMember({ chainId, agentInstanceId }).unwrap();
      refetch();
    } catch (err) {
      console.error('Failed to remove member:', err);
    }
  };

  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const openEditAssigneeModal = (task: any) => {
    setEditingAssigneeTask(task);
    setAssigneeError('');
    const ref = task.assigneeRef || task.assignee_ref;
    if (ref?.agent_id) {
      setEditAssigneeMode('role');
      setEditAssigneeAgentId(ref.agent_id);
      setEditAssigneeUserId('');
    } else if (ref?.agent_instance_id) {
      const instId = ref.agent_instance_id;
      let resolvedAgentId = ref.agent_id || '';
      if (!resolvedAgentId) {
        const chainInst = (chain?.chain_instances || []).find(
          (ci: any) => (ci.agent_instance_id || ci.agentInstanceId) === instId
        );
        if (chainInst?.agent_id || chainInst?.agentId) {
          resolvedAgentId = chainInst.agent_id || chainInst.agentId;
        }
      }
      if (!resolvedAgentId) {
        const member = members.find(
          (m: any) => (m.agentInstanceId || m.agent_instance_id) === instId
        );
        if (member?.agent_id || member?.agentId) {
          resolvedAgentId = member.agent_id || member.agentId;
        }
      }
      if (!resolvedAgentId) {
        const inst = allInstances.find(
          (i: any) => (i.agent_instance_id || i.agentInstanceId || i.id) === instId
        );
        if (inst?.agent_id || inst?.agentId) {
          resolvedAgentId = inst.agent_id || inst.agentId;
        }
      }
      // REQ-AUTO-4: no first-identity guess — when the instance's durable agent
      // cannot be resolved, the user picks a real identity explicitly.
      setEditAssigneeMode('role');
      setEditAssigneeAgentId(resolvedAgentId);
      setEditAssigneeUserId('');
    } else if (ref?.user_id) {
      setEditAssigneeMode('user');
      setEditAssigneeUserId(ref.user_id);
      setEditAssigneeAgentId('');
    } else {
      // No assignee: open unassigned rather than pre-selecting an identity the
      // user never chose.
      setEditAssigneeMode('unassigned');
      setEditAssigneeAgentId('');
      setEditAssigneeUserId('');
    }
  };

  const handleSaveAssignee = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingAssigneeTask) return;
    setSavingAssignee(true);
    setAssigneeError('');
    try {
      let assigneeRef: any = null;
      if (editAssigneeMode === 'role') {
        if (!editAssigneeAgentId) throw new Error('Please select an agent role.');
        assigneeRef = { type: 'agent_id', agent_id: editAssigneeAgentId };
      } else if (editAssigneeMode === 'user') {
        if (!editAssigneeUserId.trim()) throw new Error('Please enter a user ID.');
        assigneeRef = { type: 'user', user_id: editAssigneeUserId.trim() };
      } else if (editAssigneeMode === 'unassigned') {
        assigneeRef = null;
      }
      await updateTask({
        chainId,
        taskId: editingAssigneeTask.taskId,
        assigneeRef,
      }).unwrap();
      setEditingAssigneeTask(null);
      await refetch();
    } catch (err: any) {
      setAssigneeError(String(err?.data?.error?.message || err?.message || 'Failed to update assignee'));
    } finally {
      setSavingAssignee(false);
    }
  };

  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const openEditReviewersModal = (task: any) => {
    setEditingReviewersTask(task);
    setStagedReviewerRefs((task.reviewerRefs || []).filter((ref: any) => ref.type !== 'user' && !ref.user_id));
    setEditRequiresUserApproval(Boolean(task.requiresUserApproval ?? task.requires_user_approval));
    setReviewersError('');
    setAddReviewerMode('member');
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    setAddReviewerMemberInstanceId(members[0]?.agentInstanceId || members[0]?.agent_instance_id || '');
    setAddReviewerAgentId('');
    setAddReviewerInstanceId('');
  };

  const handleAddStagedReviewer = () => {
    setReviewersError('');
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    let refToAdd: any = null;
    if (addReviewerMode === 'member') {
      if (!addReviewerMemberInstanceId) {
        setReviewersError('Select a chain member to add as reviewer.');
        return;
      }
      refToAdd = { type: 'agent_instance', agent_instance_id: addReviewerMemberInstanceId };
    } else if (addReviewerMode === 'existing') {
      if (!addReviewerInstanceId) {
        setReviewersError('Select an agent instance to add as reviewer.');
        return;
      }
      refToAdd = { type: 'agent_instance', agent_instance_id: addReviewerInstanceId };
    }
    if (refToAdd) {
      const exists = stagedReviewerRefs.some((r) =>
        (r.agent_instance_id && r.agent_instance_id === refToAdd.agent_instance_id) ||
        (r.user_id && r.user_id === refToAdd.user_id)
      );
      if (exists) {
        setReviewersError('This reviewer is already added.');
        return;
      }
      setStagedReviewerRefs([...stagedReviewerRefs, refToAdd]);
    }
  };

  const handleRemoveStagedReviewer = (index: number) => {
    setStagedReviewerRefs(stagedReviewerRefs.filter((_, i) => i !== index));
  };

  const handleSaveReviewers = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingReviewersTask) return;
    setSavingReviewers(true);
    setReviewersError('');
    try {
      await updateTask({
        chainId,
        taskId: editingReviewersTask.taskId,
        reviewerRefs: stagedReviewerRefs,
        requiresUserApproval: editRequiresUserApproval,
      }).unwrap();
      setEditingReviewersTask(null);
      await refetch();
    } catch (err: any) {
      setReviewersError(String(err?.data?.error?.message || err?.message || 'Failed to update reviewers'));
    } finally {
      setSavingReviewers(false);
    }
  };

  const openEditDependenciesModal = (task: any) => {
    setEditingDependenciesTask(task);
    setStagedDependsOnIds(task.dependsOn ? [...task.dependsOn] : []);
    setDependenciesError('');
  };

  const handleSaveDependencies = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingDependenciesTask) return;
    setSavingDependencies(true);
    setDependenciesError('');
    try {
      await updateTask({
        chainId,
        taskId: editingDependenciesTask.taskId,
        dependsOn: stagedDependsOnIds,
      }).unwrap();
      setEditingDependenciesTask(null);
      await refetch();
    } catch (err: any) {
      setDependenciesError(String(err?.data?.error?.message || err?.data?.message || err?.message || 'Failed to update dependencies'));
    } finally {
      setSavingDependencies(false);
    }
  };

  // REQ-TB-5: change or clear a task's bridge pin. The PATCH is presence-checked
  // hub-side, so the modal always sends bridgeId — '' is the explicit clear back
  // to inheriting the coordinator's bridge.
  const openEditBridgeModal = (task: any) => {
    setEditingBridgeTask(task);
    setEditBridgeId(String(task?.bridgeId || ''));
    setBridgeError('');
  };

  const handleSaveBridge = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!editingBridgeTask) return;
    setSavingBridge(true);
    setBridgeError('');
    try {
      await updateTask({
        chainId,
        taskId: editingBridgeTask.taskId,
        bridgeId: editBridgeId,
      }).unwrap();
      setEditingBridgeTask(null);
      await refetch();
    } catch (err: any) {
      setBridgeError(String(err?.data?.error?.message || err?.message || 'Failed to update bridge'));
    } finally {
      setSavingBridge(false);
    }
  };

  const updateCommentAttachments = (taskId: string, updater: (items: CommentAttachment[]) => CommentAttachment[]) => {
    setCommentAttachments((prev) => ({
      ...prev,
      [taskId]: updater(prev[taskId] || []),
    }));
  };

  const uploadCommentAttachment = async (taskId: string, file: File, existingLocalId = '') => {
    const localId = existingLocalId || `task_att_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const name = artifactUploadName(file, 'task-comment-attachment');
    const tooLarge = file.size > MAX_UPLOAD_BYTES;
    updateCommentAttachments(taskId, (items) => [
      ...items.filter((item) => item.localId !== localId),
      {
        localId,
        id: '',
        link: '',
        name,
        file,
        status: tooLarge ? 'error' : 'uploading',
        error: tooLarge ? `File is too large. Maximum upload size is ${Math.round(MAX_UPLOAD_BYTES / (1024 * 1024))} MB.` : '',
      },
    ]);
    if (tooLarge) return;
    try {
      const res = await createArtifact({
        file,
        name,
        mime: artifactMimeForFile(file),
        kind: artifactKindForFile(file),
        originKind: 'task_comment',
        originRef: `${chainId}:${taskId}`,
      }).unwrap();
      const link = artifactLinkFromResponse(res);
      const id = artifactIdFromLink(link);
      if (!id) throw new Error('Upload failed: Hub did not return an artifact id.');
      updateCommentAttachments(taskId, (items) => items.map((item) => (
        item.localId === localId ? { ...item, id, link, status: 'uploaded', error: '' } : item
      )));
    } catch (err: any) {
      const message = String(err?.data?.message || err?.message || err || 'Upload failed');
      updateCommentAttachments(taskId, (items) => items.map((item) => (
        item.localId === localId ? { ...item, status: 'error', error: message } : item
      )));
    }
  };

  const handleCommentPaste = (event: React.ClipboardEvent<HTMLInputElement>, taskId: string) => {
    const files = clipboardFilesFromEvent(event);
    if (files.length === 0) return;
    event.preventDefault();
    files.forEach((file) => void uploadCommentAttachment(taskId, file));
  };

  const handleAddComment = async (taskId: string) => {
    const text = commentInputs[taskId]?.trim() || '';
    const attachments = commentAttachments[taskId] || [];
    if (attachments.some((item) => item.status === 'uploading' || item.status === 'error')) return;
    const body = appendArtifactLinks(text, attachments.filter((item) => item.status === 'uploaded' && item.link).map((item) => item.link)).trim();
    if (!body) return;
    try {
      await addComment({ chainId, taskId, body }).unwrap();
      setCommentInputs((prev) => ({ ...prev, [taskId]: '' }));
      setCommentAttachments((prev) => ({ ...prev, [taskId]: [] }));
      refetch();
    } catch (err) {
      console.error('Failed to add comment:', err);
    }
  };

  const handleVote = async (taskId: string, result: 'lgtm' | 'ngtm') => {
    try {
      await voteTask({ chainId, taskId, result }).unwrap();
      refetch();
    } catch (err) {
      console.error('Failed to vote:', err);
    }
  };

  const handleStatusChange = async (taskId: string, status: string) => {
    try {
      await setStatus({ chainId, taskId, status, body: '' }).unwrap();
      refetch();
    } catch (err) {
      console.error('Failed to update status:', err);
    }
  };

  const handleCancelTask = async (taskId: string) => {
    try {
      await cancelTask({ chainId, taskId }).unwrap();
      refetch();
    } catch (err) {
      console.error('Failed to cancel task:', err);
    }
  };

  const handleNudge = async (taskId: string) => {
    try {
      await nudgeTask({ chainId, taskId, message: 'Nudge: please check task status' }).unwrap();
    } catch (err) {
      console.error('Failed to nudge:', err);
    }
  };

  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const renderTaskCard = (task: any) => {
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    const taskId = task.taskId || task.id;
    const isExpanded = Boolean(expandedTaskIds[taskId]);
    const taskBridge = taskBridgeDisplay(
      task.bridgeId || task.bridge_id || effectiveChainBridgeId(chain, allInstances, bridgesQuery.data?.bridges || []),
      bridgesQuery.data?.bridges || []
    );
    const taskCommentAttachments = commentAttachments[taskId] || [];
    const taskCommentUploading = taskCommentAttachments.some((item) => item.status === 'uploading');
    const taskCommentFailed = taskCommentAttachments.some((item) => item.status === 'error');
    const taskCommentReady = taskCommentAttachments.filter((item) => item.status === 'uploaded' && item.link);
    const taskCommentCanSend = !taskCommentUploading && !taskCommentFailed && (Boolean((commentInputs[taskId] || '').trim()) || taskCommentReady.length > 0);

    return (
      <div
        key={taskId}
        data-debug-id={`taskchain-task-row-${taskId}`}
        className="rounded-lg border border-subtle bg-surface text-xs"
      >
        {/* Task Card Header (Row 1 + Row 2) */}
        <div
          data-debug-id={`taskchain-task-header-${taskId}`}
          className={`p-3 ${
            isExpanded
              ? 'sticky top-0 z-10 bg-surface border-b border-subtle rounded-t-lg'
              : 'rounded-lg'
          }`}
        >
          {/* Row 1: Expand/collapse chevron + 1-line Task Title */}
          <div
            className="flex items-center gap-2 cursor-pointer select-none"
            onClick={() => toggleTaskExpanded(taskId)}
          >
            <button
              type="button"
              data-debug-id={`taskchain-task-expand-btn-${taskId}`}
              onClick={(e) => {
                e.stopPropagation();
                toggleTaskExpanded(taskId);
              }}
              className="text-muted hover:text-primary"
            >
              {isExpanded ? '▾' : '▸'}
            </button>
            <div
              data-debug-id={`taskchain-task-title-${taskId}`}
              className="min-w-0 flex-1 truncate font-semibold text-primary cursor-pointer select-none"
            >
              <VaultText value={task.title} as="span" />
            </div>
          </div>

          {/* Row 2: Left metadata chips + Right contextual action buttons */}
          <div className="mt-2 flex flex-wrap items-center justify-between gap-2 min-w-0">
            {/* Left: Metadata chips */}
            <div className="flex flex-wrap items-center gap-2 text-caption text-muted min-w-0">
              <span data-debug-id={`taskchain-task-assignee-${taskId}`} className="inline-flex items-center gap-1">
                {task.assigneeRef ? (
                  <>
                    assignee: {task.assigneeRef.agent_instance_id ? (
                      <InstanceIdLink instanceId={task.assigneeRef.agent_instance_id} />
                    ) : task.assigneeRef.agent_id || task.assigneeRef.agentId ? (
                      <span className="font-semibold text-primary">{formatFleetRoleName(task.assigneeRef.agent_id || task.assigneeRef.agentId, agentIdentities)}</span>
                    ) : (
                      <span className="text-primary">{task.assigneeRef.user_id}</span>
                    )}
                  </>
                ) : (
                  <span>assignee: <span className="text-faint">unassigned</span></span>
                )}
                <button
                  type="button"
                  data-debug-id={`taskchain-task-edit-assignee-btn-${taskId}`}
                  title="Change assignee"
                  onClick={(e) => { e.stopPropagation(); openEditAssigneeModal(task); }}
                  className="ml-0.5 text-muted hover:text-primary"
                >
                  <Icon name="pencil" size={11} />
                </button>
              </span>

              <span data-debug-id={`taskchain-task-reviewers-${taskId}`} className="inline-flex items-center gap-1">
                reviewers: {task.reviewerRefs && task.reviewerRefs.length > 0 ? (
                  <span>
                    {/* TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema */}
                    {task.reviewerRefs.map((r: any, ri: number) => (
                      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                      <React.Fragment key={r.agent_instance_id || r.agent_id || r.agentId || r.user_id || ri}>
                        {ri > 0 ? ', ' : ''}
                        {r.agent_instance_id ? (
                          <InstanceIdLink instanceId={r.agent_instance_id} />
                        ) : r.agent_id || r.agentId ? (
                          <span className="font-semibold text-primary">{formatFleetRoleName(r.agent_id || r.agentId, agentIdentities)}</span>
                        ) : (
                          <span data-debug-id={`taskchain-task-user-reviewer-${taskId}`} className="text-primary">
                            You (@{r.username || r.user_id})
                          </span>
                        )}
                      </React.Fragment>
                    ))}
                  </span>
                ) : (
                  <span className="text-faint">none</span>
                )}
                <button
                  type="button"
                  data-debug-id={`taskchain-task-edit-reviewers-btn-${taskId}`}
                  title="Edit reviewers"
                  onClick={(e) => { e.stopPropagation(); openEditReviewersModal(task); }}
                  className="ml-0.5 text-muted hover:text-primary"
                >
                  <Icon name="pencil" size={11} />
                </button>
              </span>

              <span data-debug-id={`taskchain-task-depends-on-${taskId}`} className="inline-flex items-center gap-1">
                <span>depends on: <span className={task.dependsOn && task.dependsOn.length > 0 ? 'text-primary' : 'text-faint'}>{task.dependsOn ? task.dependsOn.length : 0}</span></span>
                <button
                  type="button"
                  data-debug-id={`taskchain-task-edit-dependencies-btn-${taskId}`}
                  title="Edit dependencies"
                  onClick={(e) => { e.stopPropagation(); openEditDependenciesModal(task); }}
                  className="ml-0.5 text-muted hover:text-primary"
                >
                  <Icon name="pencil" size={11} />
                </button>
              </span>

              <span data-debug-id={`taskchain-task-bridge-${taskId}`} className="inline-flex items-center gap-1">
                bridge:{' '}
                <span className="font-semibold text-primary">{taskBridge.inherited ? 'Unavailable' : taskBridge.label}</span>
                <button
                  type="button"
                  data-debug-id={`taskchain-task-edit-bridge-btn-${taskId}`}
                  title="Change bridge"
                  onClick={(e) => { e.stopPropagation(); openEditBridgeModal(task); }}
                  className="ml-0.5 text-muted hover:text-primary"
                >
                  <Icon name="pencil" size={11} />
                </button>
              </span>

              {(() => {
                const p = String(task.priority || '').toLowerCase();
                if (p !== 'p0' && p !== 'p1' && p !== 'p2') return null;
                const cls = p === 'p0' ? 'bg-danger-soft text-danger' : p === 'p1' ? 'bg-warning-soft text-warning' : 'bg-neutral-soft text-muted';
                return (
                  <span data-debug-id={`taskchain-task-priority-${taskId}`} title={`Priority ${p.toUpperCase()}`} className={`rounded px-1.5 py-0.5 font-mono uppercase ${cls}`}>
                    {p}
                  </span>
                );
              })()}

              {(() => {
                const s = String(task.status || '').toLowerCase();
                const badgeCls =
                  s === 'finishing'
                    ? 'bg-warning-soft text-warning border border-warning/30 font-semibold'
                    : s === 'pausing'
                      ? 'bg-info-soft text-info border border-info/30 font-semibold'
                      : 'bg-neutral-soft text-muted';
                return (
                  <span
                    data-debug-id={`taskchain-task-status-${taskId}`}
                    className={`rounded px-1.5 py-0.5 font-mono uppercase ${badgeCls}`}
                  >
                    {task.status}
                  </span>
                );
              })()}

              {task.status === 'queued' && (
                <span
                  data-debug-id={`taskchain-task-queued-slot-${taskId}`}
                  className="rounded bg-warning-soft px-1.5 py-0.5 font-semibold text-warning"
                >
                  Queued (Waiting for {getQueuedWaitingSlotName(task, agentIdentities)} slot)
                </span>
              )}

              {task.blocked && (
                <span
                  data-debug-id={`taskchain-task-blocked-${taskId}`}
                  className="rounded bg-warning-soft px-1.5 py-0.5 font-semibold text-warning"
                >
                  ⛔ blocked
                </span>
              )}
            </div>

            {/* Right: Contextual Action Buttons / Menu strictly implementing the validated Action Matrix */}
            <div className="flex flex-wrap items-center gap-1.5">
              {(() => {
                const status = String(task.status || '').toLowerCase();
                const rawAllowedActions: string[] = Array.isArray(task.allowedActions) && task.allowedActions.length > 0
                  ? task.allowedActions
                  : Array.isArray(task.allowed_actions) && task.allowed_actions.length > 0
                    ? task.allowed_actions
                    : [];
                const allowedTransitions: string[] = Array.isArray(task.allowedTransitions) && task.allowedTransitions.length > 0
                  ? task.allowedTransitions
                  : Array.isArray(task.allowed_transitions) && task.allowed_transitions.length > 0
                    ? task.allowed_transitions
                    : [];
                const allowedActions: string[] = rawAllowedActions.length > 0
                  ? (status === 'finishing' && !rawAllowedActions.includes('force_finish')
                      ? [...rawAllowedActions, 'force_finish']
                      : status === 'pausing' && !rawAllowedActions.includes('force_pause')
                        ? [...rawAllowedActions, 'force_pause']
                        : rawAllowedActions)
                  : status === 'cancelled'
                    ? ['uncancel']
                    : status === 'paused'
                      ? ['unpause', 'cancel']
                      : status === 'completed' || status === 'validated_good'
                        ? ['not_complete', 'revalidate']
                        : status === 'finishing'
                          ? ['complete', 'force_finish', 'revalidate', 'pause', 'cancel', 'nudge']
                          : status === 'pausing'
                            ? ['pause', 'force_pause', 'start', 'cancel', 'nudge']
                            : status === 'in_progress'
                              ? ['validate', 'pause', 'cancel', 'nudge']
                              : status === 'in_validation'
                                ? ['lgtm', 'ngtm', 'pause', 'cancel', 'nudge']
                                : ['start', 'pause', 'cancel', 'nudge'];
                void allowedTransitions;

                return (
                  <>
                    {allowedActions.includes('uncancel') && (
                      <button
                        type="button"
                        data-debug-id={`taskchain-task-uncancel-btn-${taskId}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleStatusChange(taskId, 'assigned');
                        }}
                        className="rounded bg-accent/20 px-2 py-0.5 text-xs font-semibold text-accent hover:bg-accent/30"
                      >
                        Uncancel
                      </button>
                    )}
                    {allowedActions.includes('unpause') && (
                      <button
                        type="button"
                        data-debug-id={`taskchain-task-unpause-btn-${taskId}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          if (isRoleAssignedWithoutLiveInstance(task, allInstances)) {
                            void handleStatusChange(taskId, 'queued');
                          } else {
                            void handleStatusChange(taskId, 'in_progress');
                          }
                        }}
                        className="rounded bg-warning-soft px-2 py-0.5 text-xs font-semibold text-warning hover:opacity-80"
                      >
                        Unpause
                      </button>
                    )}
                    {allowedActions.includes('not_complete') && (
                      <button
                        type="button"
                        data-debug-id={`taskchain-task-not-complete-btn-${taskId}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleStatusChange(taskId, 'assigned');
                        }}
                        className="rounded bg-neutral-soft px-2 py-0.5 text-xs text-primary hover:bg-surface-raised"
                      >
                        Not Complete
                      </button>
                    )}
                    {allowedActions.includes('revalidate') && (
                      <button
                        type="button"
                        data-debug-id={`taskchain-task-revalidate-btn-${taskId}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleStatusChange(taskId, 'in_validation');
                        }}
                        className="rounded bg-accent-soft px-2 py-0.5 text-xs font-semibold text-accent hover:opacity-80"
                      >
                        Re-validate
                      </button>
                    )}
                    {allowedActions.includes('start') && (
                      <button
                        type="button"
                        data-debug-id={`taskchain-task-start-btn-${taskId}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleStatusChange(taskId, 'in_progress');
                        }}
                        className="rounded bg-accent px-2 py-0.5 text-xs font-semibold text-accent-fg hover:opacity-90"
                      >
                        Start
                      </button>
                    )}
                    {allowedActions.includes('validate') && (
                      <button
                        type="button"
                        data-debug-id={`taskchain-task-validate-btn-${taskId}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleStatusChange(taskId, 'in_validation');
                        }}
                        className="rounded bg-accent px-2 py-0.5 text-xs font-semibold text-accent-fg hover:opacity-90"
                      >
                        Validate
                      </button>
                    )}
                    {allowedActions.includes('complete') && (
                      <button
                        type="button"
                        data-debug-id={`taskchain-task-complete-btn-${taskId}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleStatusChange(taskId, 'completed');
                        }}
                        className="rounded bg-success px-2 py-0.5 text-xs font-semibold text-accent-fg hover:opacity-90"
                      >
                        Complete
                      </button>
                    )}
                    {allowedActions.includes('force_finish') && (
                      <button
                        type="button"
                        data-debug-id={`taskchain-task-force-finish-btn-${taskId}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleStatusChange(taskId, 'completed');
                        }}
                        className="rounded bg-warning-soft px-2 py-0.5 text-xs font-semibold text-warning hover:opacity-80"
                      >
                        Force Finish
                      </button>
                    )}
                    {allowedActions.includes('lgtm') && (
                      <button
                        type="button"
                        data-debug-id={`taskchain-task-lgtm-btn-${taskId}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleVote(taskId, 'lgtm');
                        }}
                        className="rounded bg-success px-2 py-0.5 text-xs font-semibold text-accent-fg hover:opacity-90"
                      >
                        LGTM
                      </button>
                    )}
                    {allowedActions.includes('ngtm') && (
                      <button
                        type="button"
                        data-debug-id={`taskchain-task-ngtm-btn-${taskId}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleVote(taskId, 'ngtm');
                        }}
                        className="rounded bg-danger-soft px-2 py-0.5 text-xs font-semibold text-danger hover:opacity-80"
                      >
                        NGTM
                      </button>
                    )}
                    {allowedActions.includes('pause') && (
                      <button
                        type="button"
                        data-debug-id={`taskchain-task-pause-btn-${taskId}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleStatusChange(taskId, 'paused');
                        }}
                        className="rounded bg-neutral-soft px-2 py-0.5 text-xs text-primary hover:bg-surface-raised"
                      >
                        Pause
                      </button>
                    )}
                    {allowedActions.includes('force_pause') && (
                      <button
                        type="button"
                        data-debug-id={`taskchain-task-force-pause-btn-${taskId}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleStatusChange(taskId, 'paused');
                        }}
                        className="rounded bg-warning-soft px-2 py-0.5 text-xs font-semibold text-warning hover:opacity-80"
                      >
                        Force Pause
                      </button>
                    )}
                    {allowedActions.includes('cancel') && (
                      <button
                        type="button"
                        data-debug-id={`taskchain-task-cancel-btn-${taskId}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleCancelTask(taskId);
                        }}
                        className="rounded bg-neutral-soft px-2 py-0.5 text-xs text-muted hover:bg-danger-soft hover:text-danger"
                      >
                        Cancel
                      </button>
                    )}
                    {allowedActions.includes('nudge') && hasLiveNudgeTarget(task, allInstances) && (
                      <button
                        type="button"
                        data-debug-id={`taskchain-task-nudge-btn-${taskId}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          void handleNudge(taskId);
                        }}
                        className="rounded bg-neutral-soft px-2 py-0.5 text-xs text-primary hover:bg-surface-raised"
                      >
                        Nudge
                      </button>
                    )}
                  </>
                );
              })()}
            </div>
          </div>
        </div>

        {/* Expanded Card Details (Description, Dependencies & Comments) */}
        {isExpanded && (
          <div className="p-3 space-y-3">
            {/* Description is lazy-fetched here (the task list omits it); this block
                only mounts when the row is expanded, so the fetch is on-demand. */}
            <TaskDescription chainId={chainId} taskId={taskId} fallback={task.description} />
            {/* end description */}
            {/* Dependencies in expanded view */}
            <div data-debug-id={`taskchain-task-dependencies-section-${taskId}`} className="rounded border border-subtle bg-surface-raised/40 p-2 text-caption">
              <div className="flex items-center justify-between">
                <span className="font-semibold text-muted">
                  Blocked on ({task.dependsOn ? task.dependsOn.length : 0}):
                </span>
                <button
                  type="button"
                  data-debug-id={`taskchain-task-manage-dependencies-btn-${taskId}`}
                  onClick={() => openEditDependenciesModal(task)}
                  className="rounded bg-neutral-soft px-2 py-0.5 text-accent hover:opacity-80"
                >
                  Manage dependencies
                </button>
              </div>
              {task.dependsOn && task.dependsOn.length > 0 ? (
                <div data-debug-id={`taskchain-task-dependencies-list-${taskId}`} className="mt-1.5 space-y-1">
                  {task.dependsOn.map((depId: string) => {
                    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
                    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                    const depTask = tasks.find((t: any) => String(t.taskId || t.id) === String(depId));
                    return (
                      <div
                        key={depId}
                        data-debug-id={`taskchain-task-dependency-item-${taskId}-${depId}`}
                        className="flex items-center justify-between rounded bg-surface px-2 py-1"
                      >
                        <div className="flex items-center gap-2 min-w-0">
                          <span className="font-mono text-muted text-[10px]">{depId}</span>
                          <span className="truncate font-medium text-primary">
                            {depTask ? <VaultText value={depTask.title} as="span" /> : depId}
                          </span>
                        </div>
                        {depTask ? (
                          <span className="shrink-0 rounded bg-neutral-soft px-1.5 py-0.5 text-[10px] uppercase font-mono text-muted">
                            {depTask.status}
                          </span>
                        ) : null}
                      </div>
                    );
                  })}
                </div>
              ) : (
                <p className="mt-1 text-caption text-faint italic">No dependencies configured.</p>
              )}
            </div>

            {/* Comments Thread — bodies lazy-loaded on expand; list ships only a summary. */}
            <TaskCommentsThread
              chainId={chainId}
              taskId={taskId}
              summary={task.commentSummary}
              enabled={isExpanded}
            />
            <div className="space-y-2">
              {/* Comment Composer */}
              <div className="space-y-2 pt-1">
                {taskCommentAttachments.length > 0 ? (
                  <div data-debug-id={`taskchain-task-comment-attachment-tray-${taskId}`} className="space-y-1 rounded border border-subtle bg-surface-raised p-2">
                    {taskCommentAttachments.map((attachment) => (
                      <div key={attachment.localId} data-debug-id={`taskchain-task-comment-attachment-${taskId}-${attachment.localId}`} className="rounded bg-surface px-2 py-1.5">
                        <div className="flex min-w-0 items-center gap-2">
                          <span className={attachment.status === 'uploaded' ? 'text-success' : attachment.status === 'error' ? 'text-danger' : 'text-accent'}>{attachment.status === 'uploading' ? '⇧' : attachment.status === 'uploaded' ? '✓' : '!'}</span>
                          <span className="min-w-0 flex-1 truncate" title={attachment.name}>{attachment.name}</span>
                          <span className={attachment.status === 'uploaded' ? 'text-success' : attachment.status === 'error' ? 'text-danger' : 'text-accent'}>{attachment.status === 'uploading' ? 'Uploading…' : attachment.status === 'uploaded' ? 'Uploaded' : 'Failed'}</span>
                          {attachment.status === 'error' ? (
                            <button type="button" data-debug-id={`taskchain-task-comment-attachment-retry-${taskId}-${attachment.localId}`} onClick={() => void uploadCommentAttachment(taskId, attachment.file, attachment.localId)} className="rounded border border-subtle px-2 py-0.5 text-primary hover:bg-surface-raised">
                              Retry
                            </button>
                          ) : null}
                          <button type="button" data-debug-id={`taskchain-task-comment-attachment-remove-${taskId}-${attachment.localId}`} onClick={() => updateCommentAttachments(taskId, (items) => items.filter((item) => item.localId !== attachment.localId))} className="rounded border border-subtle px-2 py-0.5 text-muted hover:bg-surface-raised">
                            Remove
                          </button>
                        </div>
                        {attachment.status === 'uploading' ? <div data-debug-id={`taskchain-task-comment-attachment-progress-${taskId}-${attachment.localId}`} className="mt-1 h-1 overflow-hidden rounded-full bg-surface-raised"><div className="h-full w-1/2 animate-pulse rounded-full bg-accent" /></div> : null}
                        {attachment.error ? <div data-debug-id={`taskchain-task-comment-attachment-error-${taskId}-${attachment.localId}`} className="mt-1 text-danger">{attachment.error}</div> : null}
                      </div>
                    ))}
                    {taskCommentUploading ? <div data-debug-id={`taskchain-task-comment-uploading-hint-${taskId}`} className="text-caption text-muted">You can keep typing. Send unlocks when uploads finish.</div> : null}
                    {taskCommentFailed ? <div data-debug-id={`taskchain-task-comment-failed-hint-${taskId}`} className="text-caption text-danger">Retry or remove failed uploads before sending.</div> : null}
                  </div>
                ) : null}
                <div className="flex min-w-0 gap-2">
                  <label data-debug-id={`taskchain-task-comment-attach-btn-${taskId}`} className="grid h-8 w-8 shrink-0 cursor-pointer place-items-center rounded border border-subtle bg-surface-raised text-sm font-semibold text-muted hover:border-accent hover:text-primary" title="Upload attachment">
                    <input
                      type="file"
                      multiple
                      data-debug-id={`taskchain-task-comment-attach-input-${taskId}`}
                      className="hidden"
                      onChange={(e) => {
                        const files = Array.from(e.target.files || []) as File[];
                        e.target.value = '';
                        files.forEach((file) => void uploadCommentAttachment(taskId, file));
                      }}
                    />
                    ＋
                  </label>
                  <input
                    type="text"
                    data-debug-id={`taskchain-task-comment-input-${taskId}`}
                    placeholder="Write a comment, paste an image/file, or attach one..."
                    value={commentInputs[taskId] || ''}
                    onChange={(e) => setCommentInputs({ ...commentInputs, [taskId]: e.target.value })}
                    onPaste={(e) => handleCommentPaste(e, taskId)}
                    className="min-w-0 flex-1 rounded border border-subtle bg-surface-raised px-2 py-1 text-base text-primary placeholder:text-muted focus:border-accent focus:outline-none sm:text-sm"
                  />
                  <button
                    type="button"
                    data-debug-id={`taskchain-task-comment-submit-btn-${taskId}`}
                    disabled={!taskCommentCanSend}
                    onClick={() => handleAddComment(taskId)}
                    title={taskCommentUploading ? 'Wait for uploads to finish before sending' : taskCommentFailed ? 'Retry or remove failed uploads before sending' : 'Send comment'}
                    className="rounded bg-accent px-3 py-1 font-semibold text-accent-fg hover:opacity-90 disabled:cursor-not-allowed disabled:bg-neutral-soft disabled:text-muted"
                  >
                    {taskCommentUploading ? 'Uploading…' : 'Send'}
                  </button>
                </div>
              </div>
            </div>
          </div>
        )}
      </div>
    );
  };

  if (!chainId) {
    return (
      <div data-debug-id="taskchain-overview" className="p-4 text-muted">
        No task chain ID provided.
      </div>
    );
  }

  if (isLoading) {
    return (
      <div data-debug-id="taskchain-overview" className="p-4 text-muted">
        Loading Task Chain overview...
      </div>
    );
  }

  if (error || !chain) {
    return (
      <div data-debug-id="taskchain-overview" className="p-4 text-danger">
        Failed to load Task Chain details.
      </div>
    );
  }

  // The chain title, the action cluster and the page body are built ONCE and rendered by
  // both branches below. Criterion 7 (no regression for non-embedded callers, e.g. the
  // conversation right panel at ConversationThreadPage.tsx) then holds by construction
  // rather than by inspection: there is no code path on which the two can diverge.
  const titleNode = (
          isEditingTitle ? (
            <div data-debug-id="taskchain-overview-title-edit" className="flex flex-wrap items-center gap-2 max-w-xl">
              <input
                ref={titleInputRef}
                type="text"
                data-debug-id="taskchain-overview-title-input"
                value={editTitleValue}
                onChange={(e) => setEditTitleValue(e.target.value)}
                onKeyDown={handleTitleKeyDown}
                disabled={isSavingTitle}
                className="flex-1 min-w-[200px] rounded-lg border border-accent bg-surface px-2.5 py-1 text-base font-normal text-primary outline-none focus:ring-1 focus:ring-accent"
                placeholder="Task chain title"
                autoFocus
              />
              <button
                type="button"
                data-debug-id="taskchain-overview-title-save-btn"
                onClick={() => void handleSaveTitle()}
                disabled={isSavingTitle || !editTitleValue.trim()}
                title="Save title (Enter)"
                className="inline-flex items-center justify-center rounded-lg border border-subtle bg-surface px-2.5 py-1 text-xs font-semibold text-primary hover:bg-surface-raised disabled:opacity-50"
              >
                Save
              </button>
              <button
                type="button"
                data-debug-id="taskchain-overview-title-cancel-btn"
                onClick={handleCancelEditTitle}
                disabled={isSavingTitle}
                title="Cancel (Esc)"
                className="inline-flex items-center justify-center rounded-lg border border-subtle bg-surface px-2.5 py-1 text-xs text-muted hover:bg-surface-raised"
              >
                Cancel
              </button>
            </div>
          ) : (
            <span className="inline-flex items-center gap-2 max-w-full">
              <span data-debug-id="taskchain-overview-title">
                <VaultText value={chain.title} fallback="Untitled Chain" />
              </span>
              <button
                type="button"
                data-debug-id="taskchain-overview-title-edit-btn"
                onClick={() => void startEditingTitle()}
                title="Edit chain title"
                aria-label="Edit chain title"
                className="inline-flex h-7 w-7 items-center justify-center rounded-lg border border-transparent text-muted transition-colors hover:border-subtle hover:bg-surface-raised hover:text-primary"
              >
                <Icon name="pencil" size={14} />
              </button>
            </span>
          )
  );

  const actionsNode = (
          <div className="flex flex-wrap items-center gap-2 max-w-full">
            <FleetSlotChips
              chainId={chainId}
              onOpenDrawer={() => setIsFleetDrawerOpen(true)}
            />
            <div data-debug-id="taskchain-overview-status" className="shrink-0">
              <Select
                data-debug-id="taskchain-overview-status-select"
                size="sm"
                value={chain.status || 'active'}
                onChange={(val) => void handleChainStatusChange(val)}
                disabled={isUpdatingChain}
                options={[
                  { value: 'active', label: 'Active' },
                  { value: 'completed', label: 'Completed' },
                  { value: 'archived', label: 'Archived' },
                  ...(chain.status === 'cancelled' ? [{ value: 'cancelled', label: 'Cancelled' }] : []),
                ]}
              />
            </div>
          </div>
  );

  const pageBody = (
    <>
        <FleetManagementDrawer
          chainId={chainId}
          isOpen={isFleetDrawerOpen}
          onClose={() => setIsFleetDrawerOpen(false)}
        />
        {/* Prominent amber banner when chain is archived */}
        {chain.status === 'archived' && (
          <div
            data-debug-id="taskchain-overview-archived-banner"
            className="flex flex-wrap items-center justify-between gap-3 border-b border-warning/40 bg-warning-soft px-4 py-3 text-warning sm:px-6"
          >
            <div className="flex items-center gap-2.5 text-sm font-medium">
              <Icon name="alert" size={16} />
              <span>This task chain is archived. It is hidden from active workflows.</span>
            </div>
            <button
              type="button"
              data-debug-id="taskchain-overview-restore-btn"
              onClick={() => void handleChainStatusChange('active')}
              disabled={isUpdatingChain}
              className="inline-flex items-center gap-1.5 rounded-lg border border-warning/50 bg-surface px-3 py-1 text-xs font-semibold text-primary transition-colors hover:bg-surface-raised disabled:opacity-50"
            >
              Restore to Active
            </button>
          </div>
        )}
        {/* Chain meta band (description, progress, members) — unchanged markup,
            regrouped directly under the PageShell header. */}
        <div className="border-b border-subtle px-4 pb-4 sm:px-6 sm:pb-6">

        {/* Collapsible Description */}
        {chain.description && (
          <div className="mt-2">
            <button
              type="button"
              data-debug-id="taskchain-overview-description-toggle-btn"
              onClick={() => setDescExpanded(!descExpanded)}
              className="flex items-center gap-1 text-xs font-semibold text-muted hover:text-primary"
            >
              <span>{descExpanded ? '▾' : '▸'}</span> description
            </button>
            {descExpanded && (
              <div
                data-debug-id="taskchain-overview-description"
                className="mt-1 text-sm text-primary"
              >
                {isVaultArmored(chain.description) && !isVaultUnlocked ? (
                  <div className="py-1">
                    <VaultText value={chain.description} as="div" />
                  </div>
                ) : (
                  <Markdown source={decryptedDescription || chain.description} compact copyAll={false} />
                )}
              </div>
            )}
          </div>
        )}

        {/* Members Strip */}
        <div
          data-debug-id="taskchain-overview-members"
          className="mt-4 flex flex-wrap items-center gap-3 border-t border-subtle pt-3 text-xs"
        >
          <span className="font-semibold text-muted">Members:</span>
          {/* TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema */}
          {members.map((m: any) => {
            // TODO(FIX): Replace loose fallback chain with canonical typed schema property
            const memberId = m.agentInstanceId || m.agent_instance_id;
            return (
              <div
                key={memberId}
                data-debug-id={`taskchain-overview-member-${memberId}`}
                className="flex items-center gap-1 rounded bg-surface-raised px-2 py-0.5"
              >
                <StatusDot size="sm" tone={runtimeStatusToTone(m.runtimeStatus || 'running')} label={runtimeStateLabel(runtimeStateFromStatus(m.runtimeStatus || 'running'))} />
                <span className="font-mono text-primary">
                  {m.role}: <InstanceIdLink instanceId={memberId} displayName={m.displayName} />
                </span>
                <button
                  type="button"
                  data-debug-id={`taskchain-overview-member-remove-btn-${memberId}`}
                  onClick={() => handleRemoveMember(memberId)}
                  className="ml-1 text-faint hover:text-danger"
                  title="Remove member"
                >
                  ×
                </button>
              </div>
            );
          })}
          <button
            type="button"
            data-debug-id="taskchain-overview-add-member-btn"
            onClick={() => setShowAddMemberModal(true)}
            className="rounded bg-neutral-soft px-2 py-0.5 font-semibold text-primary hover:opacity-80"
          >
            + Add member
          </button>
        </div>
      </div>

      {/* REQ-SHELL-6 §4 — ACTIVE SERVERS for this chain, whoever started them.
          Placed in the chain summary because `server` is CHAIN + BRIDGE scoped and chain
          appears in no other kind's scope key (shell_session.odin:87-91), making this the
          only mounted surface whose scope matches the content. This deliberately
          revisits REQ-UI-REMOVE-SHELLS-FROM-CHAIN-VIEW, which removed the GENERIC
          all-kinds session table from this page; see the note in
          tests/test_ui_chain_overview_no_shells_static.py for where the line now sits. */}
      <div className="px-4 pb-4 sm:px-6">
        <ChainActiveServersPanel chainId={chainId} />
      </div>

      {/* Task List Header */}
      <div className="flex flex-wrap items-center justify-between gap-2 px-4 py-3 sm:px-6">
        <h3 className="text-sm font-bold uppercase tracking-wider text-muted min-w-0">
          Tasks ({tasks.length})
        </h3>
        <div className="flex flex-wrap items-center gap-2">
          <button
            type="button"
            data-debug-id="taskchain-new-task-btn"
            onClick={() => setShowNewTaskModal(true)}
            className="rounded bg-accent px-3 py-1 text-xs font-semibold text-accent-fg hover:opacity-90"
          >
            + New task
          </button>
          <button
            type="button"
            data-debug-id="taskchain-overview-reconcile-btn"
            disabled={reconcileState.isLoading || !chainId}
            onClick={handleReconcile}
            className="rounded border border-warning/40 bg-warning/10 px-2.5 py-1 text-xs font-semibold text-warning hover:bg-warning/20 disabled:opacity-50"
            title="Manual reconcile (reconcile is an automatic self-healing background guarantee)"
          >
            {reconcileState.isLoading ? 'Reconciling…' : '↻ Reconcile chain'}
          </button>
        </div>
      </div>
      {reconcileMsg ? (
        <div data-debug-id="taskchain-overview-reconcile-banner" className="mx-4 mb-2 rounded border border-warning/30 bg-warning/10 px-3 py-2 text-caption text-warning break-words sm:mx-6">
          {reconcileMsg}
        </div>
      ) : null}

      {/* Tasks List */}
      <div className="flex-1 space-y-3 px-4 pb-6 sm:px-6">
        {tasks.length === 0 ? (
          <div className="rounded-lg border border-dashed border-subtle p-6 text-center text-xs text-muted">
            No tasks in this chain yet. Click "+ New task" to get started.
          </div>
        ) : (
          <>
            {/* Active Tasks */}
            {activeTasks.length === 0 && completedTasks.length > 0 ? (
              <div className="rounded-lg border border-dashed border-subtle p-4 text-center text-xs text-muted">
                All tasks in this chain are completed.
              </div>
            ) : (
              activeTasks.map((task: any) => renderTaskCard(task))
            )}

            {/* Collapsible Completed Tasks Section */}
            {completedTasks.length > 0 && (
              <div
                data-debug-id="taskchain-overview-completed-section"
                className="mt-6 border-t border-subtle pt-4"
              >
                <button
                  type="button"
                  data-debug-id="taskchain-overview-completed-toggle-btn"
                  onClick={() => setCompletedTasksExpanded(!completedTasksExpanded)}
                  className="flex w-full items-center justify-between rounded-lg bg-surface px-3 py-2 text-xs font-semibold text-muted hover:bg-surface-raised hover:text-primary"
                >
                  <div className="flex items-center gap-2">
                    <span>{completedTasksExpanded ? '▾' : '▸'}</span>
                    <span>Completed Tasks</span>
                    <span
                      data-debug-id="taskchain-overview-completed-count"
                      className="rounded bg-success-soft px-1.5 py-0.5 text-[10px] text-success"
                    >
                      {completedTasks.length}
                    </span>
                  </div>
                  <span className="text-caption font-normal text-faint">
                    {completedTasksExpanded ? 'Click to collapse' : 'Click to expand'}
                  </span>
                </button>

                {completedTasksExpanded && (
                  <div
                    data-debug-id="taskchain-overview-completed-list"
                    className="mt-3 space-y-3"
                  >
                    {completedTasks.map((task: any) => renderTaskCard(task))}
                  </div>
                )}
              </div>
            )}
            
            {/* Collapsible Cancelled Tasks Section */}
            {cancelledTasks.length > 0 && (
              <div
                data-debug-id="taskchain-overview-cancelled-section"
                className="mt-6 border-t border-subtle pt-4"
              >
                <button
                  type="button"
                  data-debug-id="taskchain-overview-cancelled-toggle-btn"
                  onClick={() => setCancelledTasksExpanded(!cancelledTasksExpanded)}
                  className="flex w-full items-center justify-between rounded-lg bg-surface px-3 py-2 text-xs font-semibold text-muted hover:bg-surface-raised hover:text-primary"
                >
                  <div className="flex items-center gap-2">
                    <span>{cancelledTasksExpanded ? '▾' : '▸'}</span>
                    <span>Cancelled Tasks</span>
                    <span
                      data-debug-id="taskchain-overview-cancelled-count"
                      className="rounded bg-neutral-soft px-1.5 py-0.5 text-[10px] text-muted"
                    >
                      {cancelledTasks.length}
                    </span>
                  </div>
                  <span className="text-caption font-normal text-faint">
                    {cancelledTasksExpanded ? 'Click to collapse' : 'Click to expand'}
                  </span>
                </button>

                {cancelledTasksExpanded && (
                  <div
                    data-debug-id="taskchain-overview-cancelled-list"
                    className="mt-3 space-y-3"
                  >
                    {cancelledTasks.map((task: any) => renderTaskCard(task))}
                  </div>
                )}
              </div>
            )}
          </>
        )}
      </div>

      {/* New Task Modal */}
      {showNewTaskModal && (
        // REQ-MODAL-2: `app-viewport-height`, not `inset-0` — see the OVERLAYS note in `src/ui/styles.css`.
        <div
          data-debug-id="taskchain-new-task-modal"
          className="fixed inset-x-0 top-0 app-viewport-height z-50 flex items-center justify-center bg-surface-overlay/80 backdrop-blur-sm p-4"
        >
          <form
            onSubmit={handleCreateTask}
            className="w-full max-w-lg max-h-[calc(var(--app-viewport-height)*0.9)] overflow-y-auto rounded-xl border border-subtle bg-surface p-5 text-xs text-primary shadow-panel"
          >
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-bold text-primary">Create New Task</h3>
              <button
                type="button"
                onClick={() => { resetNewTaskForm(); setShowNewTaskModal(false); }}
                className="text-muted hover:text-primary"
              >
                ✕
              </button>
            </div>

            <div className="mt-4 space-y-4">
              <div>
                <label className="block text-muted">Title</label>
                <input
                  type="text"
                  data-debug-id="taskchain-new-task-title-input"
                  required
                  value={newTaskTitle}
                  onChange={(e) => setNewTaskTitle(e.target.value)}
                  className="mt-1 w-full rounded border border-subtle bg-surface-raised p-2 text-primary placeholder:text-muted focus:outline-none focus:border-accent"
                  placeholder="Task title..."
                />
              </div>

              <div>
                <label className="block text-muted">Description</label>
                <textarea
                  data-debug-id="taskchain-new-task-desc-input"
                  value={newTaskDesc}
                  onChange={(e) => setNewTaskDesc(e.target.value)}
                  className="mt-1 w-full rounded border border-subtle bg-surface-raised p-2 text-primary placeholder:text-muted focus:outline-none focus:border-accent"
                  placeholder="Task description (optional)..."
                  rows={2}
                />
              </div>

              {/* Bridge (REQ-TB-5) */}
              <div>
                <label className="block text-muted">Bridge</label>
                <Select
                  data-debug-id="taskchain-new-task-bridge-select"
                  className="mt-1"
                  width="full"
                  value={newTaskBridgeId}
                  onChange={setNewTaskBridgeId}
                  options={bridgePinOptions}
                />
                <p className="mt-1 text-caption text-muted">
                  Pin this task to a specific bridge, or leave it on the coordinator&apos;s bridge.
                </p>
              </div>

              {/* Assignee Section */}
              <div className="rounded border border-subtle bg-surface-raised/40 p-3 space-y-2.5">
                <label className="block font-semibold text-primary">Initial Assignee</label>
                <div data-debug-id="taskchain-new-task-assignee-mode" className="flex gap-1 rounded bg-surface p-1">
                  <button
                    type="button"
                    data-debug-id="taskchain-new-task-assignee-mode-agent"
                    onClick={() => setNewTaskAssigneeMode('agent')}
                    className={`rounded px-2.5 py-1 font-semibold transition-colors cursor-pointer ${
                      newTaskAssigneeMode === 'agent' ? 'bg-accent text-accent-fg' : 'text-muted hover:text-primary'
                    }`}
                  >
                    Agent Role
                  </button>
                  <button
                    type="button"
                    data-debug-id="taskchain-new-task-assignee-mode-unassigned"
                    onClick={() => setNewTaskAssigneeMode('unassigned')}
                    className={`rounded px-2.5 py-1 font-semibold transition-colors cursor-pointer ${
                      newTaskAssigneeMode === 'unassigned' ? 'bg-accent text-accent-fg' : 'text-muted hover:text-primary'
                    }`}
                  >
                    Unassigned
                  </button>
                  <button
                    type="button"
                    data-debug-id="taskchain-new-task-assignee-mode-user"
                    onClick={() => setNewTaskAssigneeMode('user')}
                    className={`rounded px-2.5 py-1 font-semibold transition-colors cursor-pointer ${
                      newTaskAssigneeMode === 'user' ? 'bg-accent text-accent-fg' : 'text-muted hover:text-primary'
                    }`}
                  >
                    User
                  </button>
                </div>

                {newTaskAssigneeMode === 'agent' && (
                  <div>
                    <Select
                      data-debug-id="taskchain-new-task-assignee-agentid-select"
                      width="full"
                      value={newTaskAssigneeAgentId}
                      onChange={setNewTaskAssigneeAgentId}
                      options={[
                        { value: '', label: 'Select agent role…' },
                        ...agentIdentities.map((a: any) => {
                          const id = String(a.agent_id || a.agentId || a.id || '');
                          const displayName = a.name || a.display_name || formatFleetRoleName(id, agentIdentities);
                          return { value: id, label: displayName };
                        }),
                      ]}
                    />
                    <p className="text-[11px] text-muted mt-1">
                      The task will automatically dispatch to an idle warm instance or JIT-provision up to fleet capacity.
                    </p>
                  </div>
                )}

                {newTaskAssigneeMode === 'user' && (
                  <div>
                    <input
                      data-debug-id="taskchain-new-task-assignee-userid-input"
                      type="text"
                      value={newTaskAssigneeUserId}
                      onChange={(e) => setNewTaskAssigneeUserId(e.target.value)}
                      placeholder="e.g. user"
                      className="w-full rounded border border-subtle bg-surface-raised p-2 text-primary focus:outline-none focus:border-accent"
                    />
                  </div>
                )}
              </div>

              {/* Reviewers Section */}
              <div className="rounded border border-subtle bg-surface-raised/40 p-3 space-y-2.5">
                <label className="block font-semibold text-primary">Reviewers ({newTaskStagedReviewerRefs.length})</label>
                <Checkbox
                  data-debug-id="taskchain-new-task-require-user-approval-checkbox"
                  checked={newTaskRequiresUserApproval}
                  onChange={setNewTaskRequiresUserApproval}
                  disabled={!username}
                  label={username ? `Require approval from You (@${username})` : 'Loading your identity…'}
                />
                {newTaskStagedReviewerRefs.length > 0 && (
                  <div data-debug-id="taskchain-new-task-reviewers-list" className="mb-2 flex flex-wrap gap-1.5 rounded border border-subtle bg-surface p-2">
                    {newTaskStagedReviewerRefs.map((r, idx) => (
                      <span
                        key={r.agent_id || r.agentInstanceId || r.agent_instance_id || r.user_id || idx}
                        data-debug-id={`taskchain-new-task-reviewer-chip-${idx}`}
                        className="inline-flex items-center gap-1.5 rounded bg-neutral-soft px-2 py-1 text-xs text-primary"
                      >
                        {r.agent_id || r.agentId ? (
                          <span className="font-semibold">{r.display_name || formatFleetRoleName(r.agent_id || r.agentId, agentIdentities)}</span>
                        ) : r.agent_instance_id ? (
                          <InstanceIdLink instanceId={r.agent_instance_id} />
                        ) : (
                          <span>{r.user_id}</span>
                        )}
                        <button
                          type="button"
                          data-debug-id={`taskchain-new-task-reviewer-remove-btn-${idx}`}
                          onClick={() => handleRemoveNewTaskStagedReviewer(idx)}
                          className="text-muted hover:text-danger cursor-pointer"
                          title="Remove reviewer"
                        >
                          ×
                        </button>
                      </span>
                    ))}
                  </div>
                )}

                <div className="border-t border-subtle pt-2 space-y-2">
                  <span className="text-caption text-muted">Add a reviewer:</span>
                  {newTaskAddReviewerMode === 'agent' && (
                    <div className="space-y-2">
                      <Select
                        data-debug-id="taskchain-new-task-add-reviewer-agentid-select"
                        width="full"
                        value={newTaskAddReviewerAgentId}
                        onChange={setNewTaskAddReviewerAgentId}
                        options={[
                          { value: '', label: 'Select reviewer role…' },
                          ...agentIdentities.map((a: any) => {
                            const id = String(a.agent_id || a.agentId || a.id || '');
                            const displayName = a.name || a.display_name || formatFleetRoleName(id, agentIdentities);
                            return { value: id, label: displayName };
                          }),
                        ]}
                      />
                    </div>
                  )}

                  <div className="flex justify-end">
                    <button
                      type="button"
                      data-debug-id="taskchain-new-task-add-reviewer-btn"
                      onClick={handleAddNewTaskStagedReviewer}
                      className="rounded bg-neutral-soft px-3 py-1 font-semibold text-accent hover:opacity-80 cursor-pointer"
                    >
                      + Add reviewer
                    </button>
                  </div>
                </div>
              </div>

              {/* Blocked-On (Depends-On) Section */}
              <div className="rounded border border-subtle bg-surface-raised/40 p-3">
                <label className="block font-semibold text-primary mb-1">
                  Blocked On (Depends On) {newTaskDependsOnIds.length > 0 && `(${newTaskDependsOnIds.length})`}
                </label>
                <p className="text-caption text-faint mb-2">Select existing tasks that must complete before this task can begin.</p>
                {tasks.length === 0 ? (
                  <p className="text-caption text-faint italic">No existing tasks in this chain yet.</p>
                ) : (
                  <div
                    data-debug-id="taskchain-new-task-depends-on-list"
                    className="max-h-40 overflow-y-auto space-y-1.5 rounded border border-subtle bg-surface p-2"
                  >
                    {tasks.map((t: any) => {
                      const tid = String(t.taskId || t.id);
                      const isSelected = newTaskDependsOnIds.includes(tid);
                      return (
                        <label
                          key={tid}
                          data-debug-id={`taskchain-new-task-depends-on-option-${tid}`}
                          className={`flex items-center gap-2 rounded px-2 py-1.5 cursor-pointer text-xs select-none transition-colors ${
                            isSelected ? 'bg-accent/20 border border-accent/40 text-primary' : 'hover:bg-surface-raised text-muted'
                          }`}
                        >
                          <Checkbox
                            checked={isSelected}
                            onChange={(checked) => {
                              if (checked) {
                                setNewTaskDependsOnIds((prev) => [...prev, tid]);
                              } else {
                                setNewTaskDependsOnIds((prev) => prev.filter((id) => id !== tid));
                              }
                            }}
                          />
                          <span className="font-mono text-muted text-caption">{tid}</span>
                          <span className="truncate flex-1 font-medium"><VaultText value={t.title} as="span" /></span>
                          <span className="text-[10px] text-faint uppercase">{t.status}</span>
                        </label>
                      );
                    })}
                  </div>
                )}
              </div>

              {newTaskError && (
                <p data-debug-id="taskchain-new-task-error" className="text-caption text-danger">{newTaskError}</p>
              )}
            </div>

            <div className="mt-5 flex justify-end gap-2">
              <button
                type="button"
                onClick={() => { resetNewTaskForm(); setShowNewTaskModal(false); }}
                className="rounded bg-neutral-soft px-3 py-1.5 text-primary hover:bg-surface-raised"
              >
                Cancel
              </button>
              <button
                type="submit"
                data-debug-id="taskchain-new-task-submit-btn"
                disabled={creatingTask || !username}
                className="rounded bg-accent px-3 py-1.5 font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50"
              >
                {creatingTask ? 'Creating…' : 'Create Task'}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* Add Agent to Chain popup: launch a new instance (identity + bridge +
          provider + model) and add it to this chain with the chosen role. */}
      {showAddMemberModal && (
        <div className="fixed inset-x-0 top-0 app-viewport-height z-50 flex items-center justify-center bg-surface-overlay/80 backdrop-blur-sm p-4">
          <form
            onSubmit={handleAddMember}
            className="w-full max-w-md rounded-xl border border-subtle bg-surface p-5 text-xs text-primary shadow-panel"
          >
            <h3 className="text-sm font-bold text-primary">Add Member to Task Chain</h3>
            <p className="mt-1 text-caption text-muted">Add an existing agent instance to this chain, or launch a new one.</p>
            {/* H14: mode toggle — existing instance (reliable) vs launch new. */}
            <div data-debug-id="taskchain-add-member-mode" className="mt-3 inline-flex rounded border border-subtle p-0.5 text-caption">
              <button
                type="button"
                data-debug-id="taskchain-add-member-mode-existing"
                onClick={() => { setAddMode('existing'); setAddAgentError(''); }}
                className={`rounded px-2 py-1 font-semibold ${addMode === 'existing' ? 'bg-accent text-accent-fg' : 'text-muted hover:text-primary'}`}
              >
                Add existing instance
              </button>
              <button
                type="button"
                data-debug-id="taskchain-add-member-mode-launch"
                onClick={() => { setAddMode('launch'); setAddAgentError(''); }}
                className={`rounded px-2 py-1 font-semibold ${addMode === 'launch' ? 'bg-accent text-accent-fg' : 'text-muted hover:text-primary'}`}
              >
                Launch new
              </button>
            </div>
            <div className="mt-4 space-y-3">
              <div>
                <label className="block text-muted">Agent identity</label>
                <Select
                  data-debug-id="taskchain-add-agent-agentid-select"
                  className="mt-1"
                  width="full"
                  value={addAgentId}
                  onChange={(v) => { setAddAgentId(v); setAddExistingInstanceId(''); }}
                >
                  <option value="">Choose agent…</option>
                  {/* TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema */}
                  {agentIdentities.map((a: any) => {
                    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                    const id = String(a.agent_id || a.agentId || a.id || '');
                    return <option key={id} value={id}>{a.name || a.display_name || id}</option>;
                  })}
                </Select>
              </div>
              {/* H14: existing-instance picker (only in 'existing' mode). */}
              {addMode === 'existing' && (
                <div>
                  <label className="block text-muted">Existing instance</label>
                  <Select
                    data-debug-id="taskchain-add-member-existing-instance-select"
                    className="mt-1"
                    width="full"
                    value={addExistingInstanceId}
                    onChange={setAddExistingInstanceId}
                    disabled={!addAgentId || existingInstancesQuery.isFetching}
                    options={[
                      { value: '', label: !addAgentId ? 'Choose an agent first…' : existingInstancesQuery.isFetching ? 'Loading instances…' : 'Choose an instance…' },
                      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
                      ...existingInstances.map((inst: any) => {
                        const iid = String(inst.agent_instance_id || inst.agentInstanceId || inst.id || '');
                        const already = memberInstanceIds.has(iid);
                        const name = selectedAddAgent?.name || selectedAddAgent?.display_name || selectedAddAgent?.agent_id || '';
                        return {
                          value: iid,
                          label: agentInstanceOptionLabel(name, iid, already ? ' (already a member)' : '', inst.runtime_status),
                          disabled: already,
                        };
                      }),
                    ]}
                  />
                  {addAgentId && !existingInstancesQuery.isFetching && existingInstances.length === 0 && (
                    <p className="mt-1 text-caption text-warning">No existing instances for this agent. Switch to “Launch new” to create one.</p>
                  )}
                </div>
              )}
              {addMode === 'launch' && (
              <>
              <div>
                <label className="block text-muted">Bridge</label>
                <Select
                  data-debug-id="taskchain-add-agent-bridge-select"
                  className="mt-1"
                  width="full"
                  value={addBridgeId}
                  onChange={(v) => { setAddBridgeId(v); setAddProvider(''); setAddModel(''); }}
                >
                  <option value="">Choose bridge…</option>
                  {addBridgeRows.map((row) => <option key={row.bridgeId} value={row.bridgeId}>{bridgeLabel(row.bridge)}</option>)}
                </Select>
                {addBridgeRows.length === 0 && <p className="mt-1 text-caption text-warning">No online bridge with provider capabilities is available.</p>}
              </div>
              <div>
                <label className="block text-muted">Provider</label>
                <Select
                  data-debug-id="taskchain-add-agent-provider-select"
                  className="mt-1"
                  width="full"
                  value={addProvider}
                  onChange={(v) => { setAddProvider(v); setAddModel(''); }}
                  disabled={!selectedAddBridge}
                >
                  <option value="">Use bridge default provider</option>
                  {addProviderOptions.map((p) => <option key={p} value={p}>{p}</option>)}
                </Select>
              </div>
              <div>
                <label className="block text-muted">Model</label>
                <Select
                  data-debug-id="taskchain-add-agent-model-select"
                  className="mt-1"
                  width="full"
                  value={addModel}
                  onChange={setAddModel}
                  disabled={!selectedAddBridge}
                >
                  <option value="">Use bridge default model</option>
                  {addModelOptions.map((model) => <option key={model} value={model}>{model}</option>)}
                </Select>
              </div>
              </>
              )}
              <div>
                <label className="block text-muted">Role</label>
                <Select
                  data-debug-id="taskchain-add-agent-role-select"
                  className="mt-1"
                  width="full"
                  value={newMemberRole}
                  onChange={setNewMemberRole}
                >
                  <option value="worker">worker</option>
                  <option value="reviewer">reviewer</option>
                  <option value="coordinator">coordinator</option>
                </Select>
              </div>
              {addAgentError && <p data-debug-id="taskchain-add-agent-error" className="text-caption text-danger">{addAgentError}</p>}
            </div>
            <div className="mt-5 flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setShowAddMemberModal(false)}
                className="rounded bg-neutral-soft px-3 py-1.5 text-primary hover:bg-surface-raised"
              >
                Cancel
              </button>
              <button
                data-debug-id="taskchain-add-agent-submit"
                type="submit"
                disabled={addMode === 'existing'
                  ? (addingExisting || !addExistingInstanceId)
                  : (addingAgent || !addAgentId)}
                className="rounded bg-accent px-3 py-1.5 font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50"
              >
                {addMode === 'existing'
                  ? (addingExisting ? 'Adding…' : 'Add member')
                  : (addingAgent ? 'Launching…' : 'Launch & Add')}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* Edit Assignee Modal */}
      {editingAssigneeTask && (
        <div
          data-debug-id="taskchain-edit-assignee-modal"
          className="fixed inset-x-0 top-0 app-viewport-height z-50 flex items-center justify-center bg-surface-overlay/80 backdrop-blur-sm p-4"
        >
          <form
            onSubmit={handleSaveAssignee}
            data-debug-id="taskchain-edit-assignee-form"
            className="w-full max-w-md rounded-xl border border-subtle bg-surface p-5 text-primary shadow-panel"
          >
            <div className="flex items-center justify-between">
              <h3 className="font-semibold text-primary">Change Assignee</h3>
              <button
                type="button"
                onClick={() => setEditingAssigneeTask(null)}
                className="text-muted hover:text-primary"
              >
                ✕
              </button>
            </div>
            <p className="mt-1 text-xs text-muted">
              Task: <span className="text-primary"><VaultText value={editingAssigneeTask.title} as="span" /></span>
            </p>

            <div className="mt-3 flex gap-2 border-b border-subtle pb-2 text-xs">
              <button
                type="button"
                data-debug-id="taskchain-edit-assignee-mode-role"
                onClick={() => setEditAssigneeMode('role')}
                className={`rounded px-2 py-1 font-semibold ${editAssigneeMode === 'role' ? 'bg-accent text-accent-fg' : 'text-muted hover:text-primary'}`}
              >
                Agent Role
              </button>
              <button
                type="button"
                data-debug-id="taskchain-edit-assignee-mode-user"
                onClick={() => setEditAssigneeMode('user')}
                className={`rounded px-2 py-1 font-semibold ${editAssigneeMode === 'user' ? 'bg-accent text-accent-fg' : 'text-muted hover:text-primary'}`}
              >
                User
              </button>
              <button
                type="button"
                data-debug-id="taskchain-edit-assignee-mode-unassigned"
                onClick={() => setEditAssigneeMode('unassigned')}
                className={`rounded px-2 py-1 font-semibold ${editAssigneeMode === 'unassigned' ? 'bg-accent text-accent-fg' : 'text-muted hover:text-primary'}`}
              >
                Unassigned
              </button>
            </div>

            <div className="mt-4 space-y-3 text-xs">
              {editAssigneeMode === 'role' && (
                <div>
                  <label className="block text-muted">Choose agent role</label>
                  <Select
                    data-debug-id="taskchain-edit-assignee-role-select"
                    className="mt-1"
                    width="full"
                    value={editAssigneeAgentId}
                    onChange={setEditAssigneeAgentId}
                    options={[
                      { value: '', label: 'Select agent role…' },
                      ...agentIdentities.map((a: any) => {
                        const id = String(a.agent_id || a.agentId || a.id || '');
                        return { value: id, label: a.name || a.display_name || id };
                      }),
                    ]}
                  />
                  <p className="mt-1 text-caption text-muted">
                    The fleet mechanism will convert this role into an actual instance JIT.
                  </p>
                </div>
              )}

              {editAssigneeMode === 'user' && (
                <div>
                  <label className="block text-muted">User ID</label>
                  <input
                    data-debug-id="taskchain-edit-assignee-userid-input"
                    type="text"
                    value={editAssigneeUserId}
                    onChange={(e) => setEditAssigneeUserId(e.target.value)}
                    placeholder="e.g. user"
                    className="mt-1 w-full rounded border border-subtle bg-surface-raised p-2 text-primary focus:outline-none focus:border-accent"
                  />
                </div>
              )}

              {editAssigneeMode === 'unassigned' && (
                <p className="text-muted">The task will have no assignee.</p>
              )}

              {assigneeError && <p data-debug-id="taskchain-edit-assignee-error" className="text-caption text-danger">{assigneeError}</p>}
            </div>

            <div className="mt-5 flex justify-end gap-2 text-xs">
              <button
                type="button"
                onClick={() => setEditingAssigneeTask(null)}
                className="rounded bg-neutral-soft px-3 py-1.5 text-primary hover:bg-surface-raised"
              >
                Cancel
              </button>
              <button
                data-debug-id="taskchain-edit-assignee-submit"
                type="submit"
                disabled={savingAssignee}
                className="rounded bg-accent px-3 py-1.5 font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50"
              >
                {savingAssignee ? 'Saving…' : 'Save Assignee'}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* Edit Reviewers Modal */}
      {editingReviewersTask && (
        <div
          data-debug-id="taskchain-edit-reviewers-modal"
          className="fixed inset-x-0 top-0 app-viewport-height z-50 flex items-center justify-center bg-surface-overlay/80 backdrop-blur-sm p-4"
        >
          <form
            onSubmit={handleSaveReviewers}
            data-debug-id="taskchain-edit-reviewers-form"
            className="w-full max-w-lg rounded-xl border border-subtle bg-surface p-5 text-primary shadow-panel"
          >
            <div className="flex items-center justify-between">
              <h3 className="font-semibold text-primary">Edit Reviewers</h3>
              <button
                type="button"
                onClick={() => setEditingReviewersTask(null)}
                className="text-muted hover:text-primary"
              >
                ✕
              </button>
            </div>
            <p className="mt-1 text-xs text-muted">
              Task: <span className="text-primary"><VaultText value={editingReviewersTask.title} as="span" /></span>
            </p>

            <div className="mt-3 rounded border border-subtle bg-surface-raised/40 p-3 text-xs">
              <Checkbox
                data-debug-id="taskchain-edit-reviewers-require-user-approval-checkbox"
                checked={editRequiresUserApproval}
                onChange={setEditRequiresUserApproval}
                disabled={!username}
                label={username ? `Require approval from You (@${username})` : 'Loading your identity…'}
              />
              {editRequiresUserApproval && username && (
                <span data-debug-id="taskchain-edit-user-reviewer-chip" className="mt-2 inline-flex rounded bg-neutral-soft px-2 py-1">
                  You (@{username})
                </span>
              )}
            </div>

            {/* Current Reviewers List */}
            <div className="mt-3">
              <label className="block text-xs font-semibold text-muted">Current Reviewers ({stagedReviewerRefs.length})</label>
              <div data-debug-id="taskchain-edit-reviewers-list" className="mt-1.5 flex flex-wrap gap-2 min-h-[36px] rounded border border-subtle bg-surface-raised/40 p-2">
                {stagedReviewerRefs.map((r: any, idx: number) => (
                  <span
                    key={r.agent_instance_id || r.user_id || idx}
                    data-debug-id={`taskchain-edit-reviewer-chip-${idx}`}
                    className="inline-flex items-center gap-1.5 rounded bg-neutral-soft px-2 py-1 text-xs text-primary"
                  >
                    {r.agent_instance_id ? (
                      <InstanceIdLink instanceId={r.agent_instance_id} />
                    ) : (
                      <span>{formatFleetRoleName(r.agent_id || r.agentId, agentIdentities)}</span>
                    )}
                    <button
                      type="button"
                      data-debug-id={`taskchain-edit-reviewer-remove-btn-${idx}`}
                      onClick={() => handleRemoveStagedReviewer(idx)}
                      className="text-muted hover:text-danger"
                      title="Remove reviewer"
                    >
                      ×
                    </button>
                  </span>
                ))}
                {stagedReviewerRefs.length === 0 && (
                  <span className="text-xs text-faint">No reviewers selected</span>
                )}
              </div>
            </div>

            {/* Add Reviewer Section */}
            <div className="mt-4 rounded border border-subtle bg-surface-raised/40 p-3 text-xs">
              <span className="font-semibold text-primary">Add Reviewer</span>
              <div className="mt-2 flex gap-2 border-b border-subtle pb-2">
                <button
                  type="button"
                  data-debug-id="taskchain-add-reviewer-mode-member"
                  onClick={() => setAddReviewerMode('member')}
                  className={`rounded px-2 py-1 font-semibold ${addReviewerMode === 'member' ? 'bg-accent text-accent-fg' : 'text-muted hover:text-primary'}`}
                >
                  Chain member
                </button>
                <button
                  type="button"
                  data-debug-id="taskchain-add-reviewer-mode-existing"
                  onClick={() => setAddReviewerMode('existing')}
                  className={`rounded px-2 py-1 font-semibold ${addReviewerMode === 'existing' ? 'bg-accent text-accent-fg' : 'text-muted hover:text-primary'}`}
                >
                  Other instance
                </button>
              </div>

              <div className="mt-3 space-y-2">
                {addReviewerMode === 'member' && (
                  <div>
                    <Select
                      data-debug-id="taskchain-add-reviewer-member-select"
                      width="full"
                      value={addReviewerMemberInstanceId}
                      onChange={setAddReviewerMemberInstanceId}
                      options={[
                        { value: '', label: 'Select member…' },
                        // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
                        ...members.map((m: any) => {
                          const id = String(m.agentInstanceId || m.agent_instance_id || '');
                          return { value: id, label: memberInstanceOptionLabel(m.role, instanceNameById.get(id) || '', id) };
                        }),
                      ]}
                    />
                  </div>
                )}

                {addReviewerMode === 'existing' && (
                  <div className="space-y-2">
                    <Select
                      data-debug-id="taskchain-add-reviewer-agentid-select"
                      width="full"
                      value={addReviewerAgentId}
                      onChange={(v) => { setAddReviewerAgentId(v); setAddReviewerInstanceId(''); }}
                    >
                      <option value="">Choose agent…</option>
                      {/* TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema */}
                      {agentIdentities.map((a: any) => {
                        // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                        const id = String(a.agent_id || a.agentId || a.id || '');
                        return <option key={id} value={id}>{a.name || a.display_name || id}</option>;
                      })}
                    </Select>
                    <Select
                      data-debug-id="taskchain-add-reviewer-existing-instance-select"
                      width="full"
                      value={addReviewerInstanceId}
                      onChange={setAddReviewerInstanceId}
                      disabled={!addReviewerAgentId || reviewerInstancesQuery.isFetching}
                      options={[
                        { value: '', label: !addReviewerAgentId ? 'Choose an agent first…' : reviewerInstancesQuery.isFetching ? 'Loading instances…' : 'Choose an instance…' },
                        // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
                        ...reviewerExistingInstances.map((inst: any) => {
                          const iid = String(inst.agent_instance_id || inst.agentInstanceId || inst.id || '');
                          const name = selectedReviewerAgent?.name || selectedReviewerAgent?.display_name || selectedReviewerAgent?.agent_id || '';
                          return { value: iid, label: agentInstanceOptionLabel(name, iid, '', inst.runtime_status) };
                        }),
                      ]}
                    />
                  </div>
                )}

                <div className="flex justify-end">
                  <button
                    type="button"
                    data-debug-id="taskchain-add-reviewer-btn"
                    onClick={handleAddStagedReviewer}
                    className="rounded bg-neutral-soft px-3 py-1 font-semibold text-accent hover:opacity-80"
                  >
                    + Add to list
                  </button>
                </div>
              </div>
            </div>

            {reviewersError && <p data-debug-id="taskchain-edit-reviewers-error" className="mt-2 text-caption text-danger">{reviewersError}</p>}

            <div className="mt-5 flex justify-end gap-2 text-xs">
              <button
                type="button"
                onClick={() => setEditingReviewersTask(null)}
                className="rounded bg-neutral-soft px-3 py-1.5 text-primary hover:bg-surface-raised"
              >
                Cancel
              </button>
              <button
                data-debug-id="taskchain-edit-reviewers-submit"
                type="submit"
                disabled={savingReviewers || !username}
                className="rounded bg-accent px-3 py-1.5 font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50"
              >
                {savingReviewers ? 'Saving…' : 'Save Reviewers'}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* Edit Dependencies Modal */}
      {editingDependenciesTask && (
        <div
          data-debug-id="taskchain-edit-dependencies-modal"
          className="fixed inset-x-0 top-0 app-viewport-height z-50 flex items-center justify-center bg-surface-overlay/80 backdrop-blur-sm p-4"
        >
          <form
            onSubmit={handleSaveDependencies}
            data-debug-id="taskchain-edit-dependencies-form"
            className="w-full max-w-md rounded-xl border border-subtle bg-surface p-5 text-primary shadow-panel"
          >
            <div className="flex items-center justify-between">
              <h3 className="font-semibold text-primary">Manage Dependencies</h3>
              <button
                type="button"
                onClick={() => setEditingDependenciesTask(null)}
                className="text-muted hover:text-primary"
              >
                ✕
              </button>
            </div>
            <p className="mt-1 text-xs text-muted">
              Task: <span className="text-primary"><VaultText value={editingDependenciesTask.title} as="span" /></span>
            </p>

            <div className="mt-4">
              <label className="block text-xs font-semibold text-muted">
                Blocked On (Depends On) {stagedDependsOnIds.length > 0 && `(${stagedDependsOnIds.length})`}
              </label>
              <p className="mt-0.5 text-caption text-faint">
                Select tasks that must be completed before this task can start.
              </p>

              {/* TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema */}
              {/* TODO(FIX): Replace loose fallback chain with canonical typed schema property */}
              {tasks.filter((t: any) => String(t.taskId || t.id) !== String(editingDependenciesTask.taskId || editingDependenciesTask.id)).length === 0 ? (
                <div className="mt-2 rounded border border-subtle bg-surface p-3 text-center text-xs text-faint italic">
                  No other tasks in this chain.
                </div>
              ) : (
                <div
                  data-debug-id="taskchain-edit-dependencies-list"
                  className="mt-2 max-h-56 overflow-y-auto space-y-1.5 rounded border border-subtle bg-surface p-2"
                >
                  {/* TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema */}
                  {tasks
                    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                    .filter((t: any) => String(t.taskId || t.id) !== String(editingDependenciesTask.taskId || editingDependenciesTask.id))
                    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
                    .map((t: any) => {
                      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                      const tid = String(t.taskId || t.id);
                      const isSelected = stagedDependsOnIds.includes(tid);
                      return (
                        <label
                          key={tid}
                          data-debug-id={`taskchain-edit-dependency-option-${tid}`}
                          className={`flex items-center gap-2 rounded px-2 py-1.5 cursor-pointer text-xs select-none transition-colors ${
                            isSelected ? 'bg-accent/20 border border-accent/40 text-primary' : 'hover:bg-surface-raised text-muted'
                          }`}
                        >
                          <Checkbox
                            checked={isSelected}
                            onChange={(checked) => {
                              if (checked) {
                                setStagedDependsOnIds((prev) => [...prev, tid]);
                              } else {
                                setStagedDependsOnIds((prev) => prev.filter((id) => id !== tid));
                              }
                            }}
                          />
                          <span className="font-mono text-muted text-caption">{tid}</span>
                          <span className="truncate flex-1 font-medium"><VaultText value={t.title} as="span" /></span>
                          <span className="text-[10px] text-faint uppercase">{t.status}</span>
                        </label>
                      );
                    })}
                </div>
              )}
            </div>

            {dependenciesError && (
              <p data-debug-id="taskchain-edit-dependencies-error" className="mt-2 text-caption text-danger">
                {dependenciesError}
              </p>
            )}

            <div className="mt-5 flex justify-end gap-2 text-xs">
              <button
                type="button"
                onClick={() => setEditingDependenciesTask(null)}
                className="rounded bg-neutral-soft px-3 py-1.5 text-primary hover:bg-surface-raised"
              >
                Cancel
              </button>
              <button
                data-debug-id="taskchain-edit-dependencies-submit"
                type="submit"
                disabled={savingDependencies}
                className="rounded bg-accent px-3 py-1.5 font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50"
              >
                {savingDependencies ? 'Saving…' : 'Save Dependencies'}
              </button>
            </div>
          </form>
        </div>
      )}

      {/* Edit Bridge Modal (REQ-TB-5) */}
      {editingBridgeTask && (
        <div
          data-debug-id="taskchain-edit-bridge-modal"
          className="fixed inset-x-0 top-0 app-viewport-height z-50 flex items-center justify-center bg-surface-overlay/80 backdrop-blur-sm p-4"
        >
          <form
            onSubmit={handleSaveBridge}
            data-debug-id="taskchain-edit-bridge-form"
            className="w-full max-w-md rounded-xl border border-subtle bg-surface p-5 text-primary shadow-panel"
          >
            <div className="flex items-center justify-between">
              <h3 className="font-semibold text-primary">Change Bridge</h3>
              <button
                type="button"
                onClick={() => setEditingBridgeTask(null)}
                className="text-muted hover:text-primary"
              >
                ✕
              </button>
            </div>
            <p className="mt-1 text-xs text-muted">
              Task: <span className="text-primary"><VaultText value={editingBridgeTask.title} as="span" /></span>
            </p>

            <div className="mt-4 text-xs">
              <label className="block text-muted">Bridge</label>
              <Select
                data-debug-id="taskchain-edit-bridge-select"
                className="mt-1"
                width="full"
                value={editBridgeId}
                onChange={setEditBridgeId}
                options={
                  editBridgeId && !bridgePinOptions.some((o) => o.value === editBridgeId)
                    ? [...bridgePinOptions, { value: editBridgeId, label: `${editBridgeId} (unavailable)` }]
                    : bridgePinOptions
                }
              />
              <p className="mt-1 text-caption text-muted">
                Pin this task to a specific bridge, or inherit the coordinator&apos;s bridge.
              </p>

              {bridgeError && <p data-debug-id="taskchain-edit-bridge-error" className="mt-2 text-caption text-danger">{bridgeError}</p>}
            </div>

            <div className="mt-5 flex justify-end gap-2 text-xs">
              <button
                type="button"
                onClick={() => setEditingBridgeTask(null)}
                className="rounded bg-neutral-soft px-3 py-1.5 text-primary hover:bg-surface-raised"
              >
                Cancel
              </button>
              <button
                data-debug-id="taskchain-edit-bridge-submit"
                type="submit"
                disabled={savingBridge}
                className="rounded bg-accent px-3 py-1.5 font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50"
              >
                {savingBridge ? 'Saving…' : 'Save Bridge'}
              </button>
            </div>
          </form>
        </div>
      )}
    </>
  );

  // Embedded: the container owns the page frame (and its single <h1>), so the chain title
  // renders as an <h2> via headingLevel and the scrolling is ours to provide.
  if (embedded) {
    return (
      <div
        data-debug-id="taskchain-overview"
        className="flex h-full min-h-0 w-full max-w-full min-w-0 flex-col overflow-hidden bg-canvas text-primary"
      >
        {hideTitleBar ? (
          <div
            data-debug-id="taskchain-overview-aux-controls"
            className="flex shrink-0 justify-end px-4 pt-3 sm:px-6"
          >
            {actionsNode}
          </div>
        ) : (
        <ResourceDetailHeader
          dataDebugId="taskchain-overview-detail-header"
          title={titleNode}
          id={chainId}
          actions={actionsNode}
          onBack={onClose}
          backLabel="All chains"
          alwaysShowBack={viewport !== 'desktop'}
          headingLevel="h2"
          className="shrink-0 px-4 pt-4 sm:px-6"
        />
        )}
        <div
          data-debug-id="taskchain-overview-embedded-scroll"
          className="min-h-0 flex-1 overflow-y-auto overflow-x-hidden pb-28 sm:pb-12"
        >
          {pageBody}
        </div>
      </div>
    );
  }

  return (
    <div
      data-debug-id="taskchain-overview"
      className="flex h-full w-full max-w-full min-w-0 flex-col overflow-y-auto overflow-x-hidden bg-canvas text-primary pb-28 sm:pb-12"
    >
      {/* Page frame + single <h1> — migrated to PageShell (ui-audit W2). Fixes the
          h2-as-page-title heading-hierarchy defect (finding #7): the chain title is
          now the page's one real <h1>. The chain status pill moves into PageShell's
          `actions` slot with its exact prior styling/behaviour. width="full" keeps
          the task board full-bleed (no visual regression). */}
      <PageShell width="full" title={titleNode} actions={actionsNode}>
        {pageBody}
      </PageShell>
    </div>
  );
};

// H10: shellHash builds the routed-shell hash link the dashboard uses for
// navigation (mirrors the helper in AgentDetailPanel).
function shellHash(path: string): string { return `#${path.startsWith('/') ? path : `/${path}`}`; }

// H10: InstanceIdLink renders an agent instance id as a clickable control that
// opens that agent's chat. Conversation routing is instance-id-only
// (#/conversations/{agentInstanceId}), so the link needs no instance->conversation
// resolution — the thread page resolves the conversation from the instance id.
// When the caller already knows the display name (e.g. chain members carry it from
// the hub) NO fetch happens at all; otherwise the (cached) instance/identity
// queries are used only to label the link. user_id refs are NOT agent instances
// and must be rendered with plain text by callers.
export function InstanceIdLink({ instanceId, displayName }: { instanceId: string; displayName?: string }) {
  const trimmed = String(instanceId || '').trim();
  // Inside the aux dock, an agent link opens its chat as an aux tab instead of
  // replacing the Main pane's conversation.
  const openAgentChat = useOpenAgentChat();
  const known = Boolean(String(displayName || '').trim());
  const isMobile = useIsMobile();
  // Only fetch when we need a label; the href never depends on the fetch.
  const { data } = useFetchAgentInstanceQuery({ instanceId: trimmed }, { skip: !trimmed || known });
  const inst = data?.instance || null;
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const agentId = String(inst?.agent_id || inst?.agentId || '');
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const instName = String(displayName || '').trim() || inst?.display_name || inst?.displayName || '';

  const { data: agentData } = useFetchAgentIdentityQuery({ agentId }, { skip: !agentId || known || Boolean(instName) });
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
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

export default TaskChainOverview;
