import * as daemonApi from '../daemonApi';
import { upsertTaskLogEvent } from '../taskCache';
import { heimdallApi, withSessionQuery } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';
import { isVaultArmored, encryptVaultText, decryptVaultText, getActiveVaultKey } from '../../utils/vaultContent';
import { decryptChainRecord, decryptChainList } from '../../utils/vaultChains';
import { decryptTaskRecord, decryptTaskList, decryptTaskComments } from '../../utils/vaultTasks';
import { taskCreateBridgeFields, taskPatchBridgeFields } from '../../utils/taskBridgePin';
import { publishErrorMessage } from '../../utils/taskBrief';
import type { TaskBriefWire, TaskLeaseWire } from '../taskWire';

export interface WorkflowDefinitionItem {
  def_id: string;
  name: string;
  version: number;
  created_at: string;
  spec: {
    schema?: string;
    name?: string;
    title?: string;
    description?: string;
    inputs?: Array<{ name: string; type?: string; description?: string; required?: boolean; default?: any }>;
    stages?: Array<{
      key: string;
      kind: 'task' | 'gate';
      title?: string;
      needs?: string[];
      brief?: any;
      gate?: any;
    }>;
    [key: string]: any;
  };
}

// The rewrite shell is cookie-authenticated (same session as /api/v1/me), not the
// legacy per-client token session. Task-chain reads/writes below must use
// cookieJsonFetch/cookieMutation against /api/v1/task-chains/... so they work in
// the routed/Electron shell where session.clientToken is not populated.
// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function unwrapData(res: any): any {
  if (res && typeof res === 'object' && 'data' in res && !Array.isArray(res)) return (res as any).data;
  return res;
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function normalizeTask(task: any) {
  // Derive assigneeAgentInstanceId
  const assigneeAgentInstanceId =
    task.assignee_agent_instance_id ||
    task.assignee_ref?.agent_instance_id ||
    task.assigneeRef?.agentInstanceId ||
    task.assignee_ref?.agentInstanceId ||
    task.assigneeRef?.agent_instance_id ||
    '';

  // Raw assignee ref normalization
  const rawAssigneeRef =
    task.assignee_ref ||
    task.assigneeRef ||
    (assigneeAgentInstanceId
      ? { type: 'agent_instance', agent_instance_id: assigneeAgentInstanceId, agentInstanceId: assigneeAgentInstanceId }
      : null);
  let normalizedAssigneeRef = rawAssigneeRef ? { ...rawAssigneeRef } : null;
  if (normalizedAssigneeRef) {
    if (normalizedAssigneeRef.agent_instance_id && !normalizedAssigneeRef.agentInstanceId) {
      normalizedAssigneeRef.agentInstanceId = normalizedAssigneeRef.agent_instance_id;
    }
    if (normalizedAssigneeRef.agentInstanceId && !normalizedAssigneeRef.agent_instance_id) {
      normalizedAssigneeRef.agent_instance_id = normalizedAssigneeRef.agentInstanceId;
    }
    if (normalizedAssigneeRef.agent_id && !normalizedAssigneeRef.agentId) {
      normalizedAssigneeRef.agentId = normalizedAssigneeRef.agent_id;
    }
    if (normalizedAssigneeRef.agentId && !normalizedAssigneeRef.agent_id) {
      normalizedAssigneeRef.agent_id = normalizedAssigneeRef.agentId;
    }
    if (normalizedAssigneeRef.display_name && !normalizedAssigneeRef.displayName) {
      normalizedAssigneeRef.displayName = normalizedAssigneeRef.display_name;
    }
    if (normalizedAssigneeRef.displayName && !normalizedAssigneeRef.display_name) {
      normalizedAssigneeRef.display_name = normalizedAssigneeRef.displayName;
    }
    if (!normalizedAssigneeRef.displayName && !normalizedAssigneeRef.display_name && (normalizedAssigneeRef.agent_id || normalizedAssigneeRef.agentId)) {
      const aid = normalizedAssigneeRef.agent_id || normalizedAssigneeRef.agentId;
      normalizedAssigneeRef.displayName = aid;
      normalizedAssigneeRef.display_name = aid;
    }
  }

  // Derive reviewerAgentInstanceId
  const reviewerAgentInstanceId =
    task.reviewer_agent_instance_id ||
    task.reviewer_refs?.[0]?.agent_instance_id ||
    task.reviewerRefs?.[0]?.agentInstanceId ||
    task.reviewer_refs?.[0]?.agentInstanceId ||
    task.reviewerRefs?.[0]?.agent_instance_id ||
    '';

  // Raw reviewer refs normalization
  const rawReviewerRefs =
    task.reviewer_refs ||
    task.reviewerRefs ||
    (reviewerAgentInstanceId
      ? [{ type: 'agent_instance', agent_instance_id: reviewerAgentInstanceId, agentInstanceId: reviewerAgentInstanceId }]
      : []);
  const normalizedReviewerRefs = (Array.isArray(rawReviewerRefs) ? rawReviewerRefs : []).map((r: any) => {
    const item = { ...r };
    if (item.agent_instance_id && !item.agentInstanceId) {
      item.agentInstanceId = item.agent_instance_id;
    }
    if (item.agentInstanceId && !item.agent_instance_id) {
      item.agent_instance_id = item.agentInstanceId;
    }
    if (item.agent_id && !item.agentId) {
      item.agentId = item.agent_id;
    }
    if (item.agentId && !item.agent_id) {
      item.agent_id = item.agentId;
    }
    if (item.display_name && !item.displayName) {
      item.displayName = item.display_name;
    }
    if (item.displayName && !item.display_name) {
      item.display_name = item.displayName;
    }
    if (!item.displayName && !item.display_name && (item.agent_id || item.agentId)) {
      const aid = item.agent_id || item.agentId;
      item.displayName = aid;
      item.display_name = aid;
    }
    return item;
  });

  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const result: any = {
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    id: task.task_id || task.id,
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    taskId: task.task_id || task.id,
    chainId: task.chain_id || '',
    title: task.title || '',
    description: task.description || '',
    priority: task.priority || 'p2',
    // Task System v2: `state` is the five-state projection; the legacy `status`
    // reader falls back to it until the M4 board rework retires `status`.
    status: task.status || task.state || 'pending',
    state: String(task.state || ''),
    kind: String(task.kind || ''),
    attemptNo: Number(task.attempt_no || 0),
    brief: task.brief && typeof task.brief === 'object' ? (task.brief as TaskBriefWire) : null,
    blockedOn: task.blocked_on && typeof task.blocked_on === 'object' ? task.blocked_on : null,
    readySince: String(task.ready_since || ''),
    leases: Array.isArray(task.leases) ? (task.leases as TaskLeaseWire[]) : [],
    publishState: String(task.publish_state || ''),
    // REQ-TB-5: the per-task bridge pin ('' = inherit the coordinator's bridge).
    bridgeId: String(task.bridge_id || task.bridgeId || ''),
    assigneeAgentInstanceId,
    reviewerAgentInstanceId,
    coordinatorAgentInstanceId: task.coordinator_agent_instance_id || '',
    dependsOn: task.depends_on || (task.depends_on_task_ids ? task.depends_on_task_ids : []),
    blocked: Boolean(task.blocked),
    // Dual casing on normalized task
    assigneeRef: normalizedAssigneeRef,
    assignee_ref: normalizedAssigneeRef,
    reviewerRefs: normalizedReviewerRefs,
    reviewer_refs: normalizedReviewerRefs,
    requiresUserApproval: Boolean(task.requires_user_approval ?? task.requiresUserApproval),
    requires_user_approval: Boolean(task.requires_user_approval ?? task.requiresUserApproval),
    comments: (task.comments || []).map(normalizeTaskComments),
    commentSummary: task.comment_summary ? {
      count: Number(task.comment_summary.count || 0),
      lastCommentAt: String(task.comment_summary.last_comment_at || ''),
      lastCommentAuthorAgentInstanceId: String(task.comment_summary.last_comment_author_agent_instance_id || ''),
      lastCommentPreview: String(task.comment_summary.last_comment_preview || ''),
    } : null,
    createdBy: task.created_by || '',
    createdAtUnixMs: Number(task.created_at_unix_ms || 0),
    updatedAtUnixMs: Number(task.updated_at_unix_ms || 0),
    notActionableReason: task.not_actionable_reason || '',
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    votes: (task.votes || []).map((vote: any) => ({
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      reviewerAgentInstanceId: vote.reviewer_agent_instance_id || vote.reviewerAgentInstanceId,
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      vote: vote.vote || (vote.approved ? 'lgtm' : 'ngtm'),
      comment: vote.comment || '',
    })),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    participants: (task.participants || []).map((participant: any) => ({
      agentInstanceId: participant.agent_instance_id,
      role: participant.role,
    })),
    unresolvedCommentCount: Number(task.unresolved_comment_count || 0),
    commentIds: task.comment_ids || [],
    allowedTransitions: task.allowed_transitions || task.allowedTransitions || [],
    allowed_transitions: task.allowed_transitions || task.allowedTransitions || [],
    allowedActions: task.allowed_actions || task.allowedActions || [],
    allowed_actions: task.allowed_actions || task.allowedActions || [],
    nextStates: task.next_states || task.nextStates || [],
    next_states: task.next_states || task.nextStates || [],
  };
  if (task.acceptance_criteria !== undefined) {
    result.acceptanceCriteria = task.acceptance_criteria;
  }
  return result;
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function normalizeTaskLogEvent(event: any) {
  return {
    eventId: event.event_id || '',
    kind: event.kind || '',
    taskId: event.task_id || '',
    chainId: event.chain_id || '',
    status: event.status || '',
    body: event.body || '',
    authorAgentInstanceId: event.author_agent_instance_id || '',
    createdUnixMs: Number(event.created_unix_ms || 0),
    commentId: event.comment_id || '',
  };
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function normalizeTaskComments(comment: any) {
  return {
    commentId: comment.comment_id || '',
    taskId: comment.task_id || '',
    chainId: comment.chain_id || '',
    authorAgentInstanceId: comment.author_agent_instance_id || '',
    // MEM-7: author identity for the comment view — resolved agent display name
    // (clickable) or, for user-authored comments, the owner user id.
    authorDisplayName: comment.author_display_name || '',
    authorUserId: comment.author_user_id || '',
    body: comment.body || '',
    resolved: Boolean(comment.resolved),
    createdUnixMs: Number(comment.created_unix_ms || 0),
  };
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function normalizeTaskLogPage(taskId: string, data: any) {
  return {
    taskId,
    events: (data?.events || []).map(normalizeTaskLogEvent),
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    nextCursor: Number(data?.next_cursor || data?.nextCursor || 0),
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    hasMore: Boolean(data?.has_more || data?.hasMore),
    total: Number(data?.total || 0),
  };
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function taskMutationAuth(session: any, agentToken?: string) {
  return {
    agentToken: String(agentToken || '').trim(),
    clientInstanceId: session?.clientInstanceId || '',
    clientToken: session?.clientToken || '',
  };
}

function preciseTaskTags(taskId?: string, chainId?: string, includeComments = true) {
  const tags: Array<{ type: 'TaskLog' | 'Task' | 'TaskComments' | 'ChainTasks' | 'Chain' | 'ChainList'; id: string }> = [];
  if (taskId) {
    tags.push({ type: 'Task', id: taskId });
    tags.push({ type: 'TaskLog', id: taskId });
    if (includeComments) tags.push({ type: 'TaskComments', id: taskId });
  }
  if (chainId) {
    tags.push({ type: 'ChainTasks', id: chainId });
    tags.push({ type: 'Chain', id: chainId });
  }
  return tags;
}


export type TaskChainDirectory = {
  directoryId: string;
  path: string;
  bridgeId: string;
  vcsKind: string;
  vcs?: Record<string, any>;
};

export function normalizeTaskChainDirectory(d: any): TaskChainDirectory {
  return {
    directoryId: String(d?.directory_id || d?.directoryId || ''),
    path: String(d?.path || ''),
    bridgeId: String(d?.bridge_id || d?.bridgeId || ''),
    vcsKind: String(d?.vcs_kind || d?.vcsKind || ''),
    vcs: typeof d?.vcs === 'object' && d?.vcs !== null ? d.vcs : {},
  };
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function normalizeTaskChainDetail(data: any) {
  if (!data) return null;

  // Build memberNameMap from data.members mapping both agentInstanceId and agent_instance_id to displayName
  const memberNameMap = new Map<string, string>();
  for (const m of data.members || []) {
    const name = m.display_name || m.displayName || '';
    if (name) {
      if (m.agent_instance_id) memberNameMap.set(m.agent_instance_id, name);
      if (m.agentInstanceId) memberNameMap.set(m.agentInstanceId, name);
    }
  }

  const tasks = (data.tasks || []).map((rawTask: any) => {
    const task = normalizeTask(rawTask);
    const assigneeId =
      task.assigneeAgentInstanceId ||
      task.assigneeRef?.agentInstanceId ||
      task.assigneeRef?.agent_instance_id ||
      task.assignee_ref?.agentInstanceId ||
      task.assignee_ref?.agent_instance_id;
    if (assigneeId && memberNameMap.has(assigneeId)) {
      const name = memberNameMap.get(assigneeId)!;
      if (task.assigneeRef) {
        task.assigneeRef.displayName = task.assigneeRef.displayName || name;
        task.assigneeRef.display_name = task.assigneeRef.display_name || name;
      }
      if (task.assignee_ref) {
        task.assignee_ref.displayName = task.assignee_ref.displayName || name;
        task.assignee_ref.display_name = task.assignee_ref.display_name || name;
      }
    }

    const enrichReviewer = (rev: any) => {
      const rId = rev?.agentInstanceId || rev?.agent_instance_id;
      if (rId && memberNameMap.has(rId)) {
        const name = memberNameMap.get(rId)!;
        rev.displayName = rev.displayName || name;
        rev.display_name = rev.display_name || name;
      }
      return rev;
    };

    if (Array.isArray(task.reviewerRefs)) {
      task.reviewerRefs.forEach(enrichReviewer);
    }
    if (Array.isArray(task.reviewer_refs)) {
      task.reviewer_refs.forEach(enrichReviewer);
    }

    return task;
  });

  return {
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    chainId: data.chain_id || data.chainId,
    title: data.title || '',
    description: data.description || '',
    publishState: data.publish_state || 'draft',
    status: data.status || 'active',
    kind: data.kind || 'team_work',
    coordinatorAgentInstanceId: data.coordinator_agent_instance_id || '',
    defaultReviewerRefs: data.default_reviewer_refs || [],
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    members: (data.members || []).map((m: any) => ({
      chainId: m.chain_id,
      agentInstanceId: m.agent_instance_id,
      agentId: m.agent_id,
      role: m.role,
      // Hub now embeds the member's display name + live runtime/activity so the
      // UI renders labels + status dots without a per-member instance fetch.
      displayName: m.display_name || '',
      runtimeStatus: m.runtime_status || '',
      activityStatus: m.activity_status || '',
      provider: m.provider || '',
      model: m.model || '',
      bridgeId: m.bridge_id || m.bridgeId || '',
      bridge_id: m.bridge_id || m.bridgeId || '',
      createdAt: m.created_at,
    })),
    tasks,
    directories: (data.directories || []).map(normalizeTaskChainDirectory),
    createdAt: data.created_at || '',
    updatedAt: data.updated_at || '',
  };
}

// TC-API list shapes: a chain row + a project group. The grouped endpoint returns
// an array of groups (each with up to 5 chains); the per-project endpoint returns
// one group with real cursor pagination. Both share the same chain-row shape.
export type ChainListItem = {
  chainId: string;
  title: string;
  status: string;
  kind?: string;
  updatedAt: string;
  coordinatorAgentInstanceId: string;
  projectId: string;
  projectName: string;
  taskCount: number;
  completedTaskCount: number;
  userValidationCount: number;
  hasUserValidation: boolean;
  isPinned: boolean;
  pinnedAt: string;
};
export type ChainProjectGroup = {
  projectId: string;
  projectName: string;
  chains: ChainListItem[];
  chainTotal: number;
  hasMore: boolean;
  nextCursor: string;
};
function normalizeChainListItem(c: any): ChainListItem {
  const userValidationCount = Number(c?.user_validation_count ?? c?.userValidationCount ?? 0);
  return {
    chainId: String(c?.chain_id ?? c?.chainId ?? ''),
    title: String(c?.title ?? ''),
    status: String(c?.status ?? ''),
    kind: String(c?.kind || 'ticket'),
    updatedAt: String(c?.updated_at ?? c?.updatedAt ?? ''),
    coordinatorAgentInstanceId: String(c?.coordinator_agent_instance_id ?? c?.coordinatorAgentInstanceId ?? ''),
    projectId: String(c?.project_id ?? c?.projectId ?? ''),
    projectName: String(c?.project_name ?? c?.projectName ?? ''),
    taskCount: Number(c?.task_count ?? c?.taskCount ?? 0),
    completedTaskCount: Number(c?.completed_task_count ?? c?.completedTaskCount ?? 0),
    userValidationCount,
    hasUserValidation: Boolean((c?.user_validation_count ?? c?.userValidationCount ?? 0) > 0),
    isPinned: Boolean(c?.is_pinned ?? c?.isPinned ?? false),
    pinnedAt: String(c?.pinned_at ?? c?.pinnedAt ?? ''),
  };
}
function normalizeChainProjectGroup(g: any): ChainProjectGroup {
  const chains = Array.isArray(g?.chains) ? g.chains.map(normalizeChainListItem) : [];
  return {
    projectId: String(g?.project_id ?? g?.projectId ?? ''),
    projectName: String(g?.project_name ?? g?.projectName ?? ''),
    chains,
    chainTotal: Number(g?.chain_total ?? g?.chainTotal ?? chains.length),
    hasMore: Boolean(g?.has_more ?? g?.hasMore ?? false),
    nextCursor: String(g?.next_cursor ?? g?.nextCursor ?? ''),
  };
}

async function decryptChainListItem<T extends ChainListItem>(c: T, key: CryptoKey | string): Promise<T> {
  let title = c.title;
  let projectName = c.projectName;
  if (title && isVaultArmored(title)) {
    try {
      title = await decryptVaultText(title, key);
    } catch {}
  }
  if (projectName && isVaultArmored(projectName)) {
    try {
      projectName = await decryptVaultText(projectName, key);
    } catch {}
  }
  return { ...c, title, projectName };
}

async function decryptChainProjectGroup(g: ChainProjectGroup, key: CryptoKey | string): Promise<ChainProjectGroup> {
  let projectName = g.projectName;
  if (projectName && isVaultArmored(projectName)) {
    try {
      projectName = await decryptVaultText(projectName, key);
    } catch {}
  }
  const chains = await Promise.all((g.chains || []).map((c) => decryptChainListItem(c, key)));
  return { ...g, projectName, chains };
}

export const tasksApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    // TC-PAGE: default project-grouped task-chains list (no params) -> array of
    // groups, each previewing up to 5 chains with has_more/next_cursor for paging.
    fetchTaskChainGroups: build.query<{ groups: ChainProjectGroup[] }, void | { hasTasks?: boolean; includeArchived?: boolean }>({
      queryFn: async (arg, api) => {
        try {
          // ?has_tasks=1 drops chains with no tasks server-side, so chain_total and
          // the paging cursors stay consistent with what is displayed.
          const params = new URLSearchParams();
          const options = typeof arg === 'object' && arg !== null ? arg : undefined;
          if (options?.hasTasks) params.set('has_tasks', '1');
          if (options?.includeArchived) params.set('include_archived', '1');
          const qs = params.toString();
          const raw = await cookieJsonFetch(`/task-chains${qs ? `?${qs}` : ''}`);
          const arr = Array.isArray(raw) ? raw : (raw?.groups || []);
          let groups = arr.map(normalizeChainProjectGroup);
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey) {
            groups = await Promise.all(groups.map((g) => decryptChainProjectGroup(g, activeKey)));
          }
          return { data: { groups } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [
        { type: 'Chain' as const, id: 'GROUPED_LIST' },
        { type: 'ChainList' as const, id: 'ALL' },
      ],
    }),
    // TC-PAGE: single-project page with cursor pagination (Load more + project
    // filter). cursor is the composite (updated_at|chain_id) from TC-API.
    fetchTaskChainProjectPage: build.query<ChainProjectGroup, { projectId: string; limit?: number; cursor?: string; hasTasks?: boolean; includeArchived?: boolean }>({
      queryFn: async ({ projectId, limit = 20, cursor = '', hasTasks = false, includeArchived = false }, api) => {
        try {
          const params = new URLSearchParams();
          params.set('project_id', projectId);
          params.set('limit', String(limit));
          if (cursor) params.set('cursor', cursor);
          if (hasTasks) params.set('has_tasks', '1');
          if (includeArchived) params.set('include_archived', '1');
          const raw = await cookieJsonFetch(`/task-chains?${params.toString()}`);
          let group = normalizeChainProjectGroup(raw);
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey) {
            group = await decryptChainProjectGroup(group, activeKey);
          }
          return { data: group };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId }) => [
        { type: 'Chain' as const, id: `PROJECT_LIST:${projectId}` },
        { type: 'ChainList' as const, id: 'ALL' },
      ],
    }),
    listTaskChains: build.query<ChainProjectGroup, { projectId: string; limit?: number; cursor?: string; hasTasks?: boolean; includeArchived?: boolean }>({
      queryFn: async ({ projectId, limit = 20, cursor = '', hasTasks = false, includeArchived = false }, api) => {
        try {
          const params = new URLSearchParams();
          params.set('project_id', projectId);
          params.set('limit', String(limit));
          if (cursor) params.set('cursor', cursor);
          if (hasTasks) params.set('has_tasks', '1');
          if (includeArchived) params.set('include_archived', '1');
          const raw = await cookieJsonFetch(`/task-chains?${params.toString()}`);
          let group = normalizeChainProjectGroup(raw);
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey) {
            group = await decryptChainProjectGroup(group, activeKey);
          }
          return { data: group };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { projectId }) => [
        { type: 'Chain' as const, id: `PROJECT_LIST:${projectId}` },
        { type: 'ChainList' as const, id: 'ALL' },
      ],
    }),
    listPinnedTaskChains: build.query<{ chains: ChainListItem[] }, void>({
      queryFn: async (_arg, api) => {
        try {
          const raw = await cookieJsonFetch('/task-chains?pinned=1');
          const data = unwrapData(raw);
          const arr = Array.isArray(data) ? data : (Array.isArray(raw) ? raw : (raw?.chains || []));
          let chains = arr.map(normalizeChainListItem);
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey) {
            chains = await Promise.all(chains.map((c) => decryptChainListItem(c, activeKey)));
          }
          return { data: { chains } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [
        { type: 'Chain' as const, id: 'PINNED_LIST' },
        { type: 'ChainList' as const, id: 'ALL' },
      ],
    }),
    fetchPinnedTaskChains: build.query<{ chains: ChainListItem[] }, void>({
      queryFn: async (_arg, api) => {
        try {
          const raw = await cookieJsonFetch('/task-chains?pinned=1');
          const data = unwrapData(raw);
          const arr = Array.isArray(data) ? data : (Array.isArray(raw) ? raw : (raw?.chains || []));
          let chains = arr.map(normalizeChainListItem);
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey) {
            chains = await Promise.all(chains.map((c) => decryptChainListItem(c, activeKey)));
          }
          return { data: { chains } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [
        { type: 'Chain' as const, id: 'PINNED_LIST' },
        { type: 'ChainList' as const, id: 'ALL' },
      ],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchTaskChainDetail: build.query<any, { chainId: string }>({
      queryFn: async ({ chainId }, api) => {
        if (!chainId) return { data: { chain: null } };
        try {
          const raw = await cookieJsonFetch(`/task-chains/${encodeURIComponent(chainId)}`);
          const data = unwrapData(raw);
          let chain = data ? normalizeTaskChainDetail(data) : null;
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey && chain) {
            chain = await decryptChainRecord(chain, activeKey);
            if (Array.isArray(chain.tasks)) {
              chain.tasks = await decryptTaskList(chain.tasks, activeKey);
            }
          }
          return { data: { chain } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { chainId }) => [
        { type: 'Chain', id: chainId },
        { type: 'ChainTasks', id: chainId },
      ],
    }),
    // Cookie-auth lazy single-task fetch. The chain/task list ships tasks WITHOUT
    // their description (to keep listings light); the full task — including the
    // Markdown description — is loaded on demand when a task row is expanded.
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchChainTaskDetail: build.query<any, { chainId: string; taskId: string }>({
      queryFn: async ({ chainId, taskId }, api) => {
        if (!chainId || !taskId) return { data: { task: null } };
        try {
          const raw = await cookieJsonFetch(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}`);
          const data = unwrapData(raw);
          let task = data ? normalizeTask(data) : null;
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey && task) {
            task = await decryptTaskRecord(task, activeKey);
          }
          return { data: { task } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { taskId }) => [{ type: 'Task' as const, id: taskId }],
    }),
    // Cookie-auth lazy comment fetch for the live shell. The chain/task list now
    // ships only a comment_summary (count + last), so the comment thread is
    // loaded on demand (task expand) via GET .../comments?last=N.
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchChainTaskComments: build.query<any, { chainId: string; taskId: string; last?: number }>({
      queryFn: async ({ chainId, taskId, last }, api) => {
        if (!chainId || !taskId) return { data: { taskId, comments: [] } };
        try {
          const q = last && last > 0 ? `?last=${last}` : '';
          const raw = await cookieJsonFetch(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/comments${q}`);
          const rows = unwrapData(raw);
          let comments = (Array.isArray(rows) ? rows : (rows?.comments || [])).map(normalizeTaskComments);
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey && comments.length > 0) {
            comments = await decryptTaskComments(comments, activeKey);
          }
          return { data: { taskId, comments } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { taskId }) => [{ type: 'TaskComments' as const, id: taskId }],
    }),
    // H9 U1: the chains an agent instance COORDINATES (single canonical source on
    // the hub: task_chain_members role='coordinator'). An agent can coordinate
    // multiple chains, so this returns a list normalized to { chainId, title,
    // status } for the coordinator-chains dropdown.
    listChainsByCoordinator: build.query<Array<{ chainId: string; title: string; status: string }>, { agentInstanceId: string }>({
      queryFn: async ({ agentInstanceId }, api) => {
        if (!agentInstanceId) return { data: [] };
        try {
          const raw = await cookieJsonFetch(`/task-chains?coordinated_by=${encodeURIComponent(agentInstanceId)}`);
          const data = unwrapData(raw);
          const list = Array.isArray(data) ? data : [];
          let chains = list.map((c: any) => ({
            // TODO(FIX): Replace loose fallback chain with canonical typed schema property
            chainId: c.chain_id || c.chainId || '',
            title: c.title || '',
            status: c.status || 'active',
          }));
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey) {
            chains = await decryptChainList(chains, activeKey);
          }
          return {
            data: chains,
          };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { agentInstanceId }) => [
        { type: 'ChainList', id: `coordinator:${agentInstanceId}` },
        'ChainList',
      ],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    createTaskChain: build.mutation<any, {
      title: string;
      description?: string;
      kind?: string;
      coordinatorAgentId?: string;
      bridgeId?: string;
      provider?: string;
      model?: string;
      projectId?: string;
    }>({
      queryFn: async ({ title, description, kind, coordinatorAgentId, bridgeId, provider, model, projectId }, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();

          let encTitle = title;
          let encDesc = description || '';

          if (isUnlocked && activeKey) {
            if (!isVaultArmored(encTitle)) {
              encTitle = await encryptVaultText(encTitle, activeKey);
            }
            if (encDesc && !isVaultArmored(encDesc)) {
              encDesc = await encryptVaultText(encDesc, activeKey);
            }
          }

          const body: any = {
            title: encTitle,
            description: encDesc,
            kind: kind || 'team_work',
          };
          if (coordinatorAgentId) body.coordinator_agent_id = coordinatorAgentId;
          if (bridgeId) body.bridge_id = bridgeId;
          if (provider) body.provider = provider;
          if (model) body.model = model;
          if (projectId) body.project_id = projectId;
          const data = await cookieMutation('/task-chains', 'POST', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: ['ChainList', { type: 'Chain' as const }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    updateTaskChain: build.mutation<any, { chainId: string; title?: string; description?: string; status?: string; coordinatorAgentInstanceId?: string }>({
      queryFn: async ({ chainId, title, description, status, coordinatorAgentInstanceId }, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();

          // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
          const body: any = {};
          if (title !== undefined) {
            body.title =
              isUnlocked && activeKey && !isVaultArmored(title)
                ? await encryptVaultText(title, activeKey)
                : title;
          }
          if (description !== undefined) {
            body.description =
              isUnlocked && activeKey && description && !isVaultArmored(description)
                ? await encryptVaultText(description, activeKey)
                : description;
          }
          if (status !== undefined) body.status = status;
          if (coordinatorAgentInstanceId !== undefined) body.coordinator_agent_instance_id = coordinatorAgentInstanceId;
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}`, 'PATCH', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [{ type: 'Chain', id: chainId }, 'ChainList', { type: 'Chain' as const }, { type: 'Chain' as const, id: 'GROUPED_LIST' }, { type: 'Chain' as const, id: 'PINNED_LIST' }],
    }),
    togglePinTaskChain: build.mutation<any, { chainId: string; pinned?: boolean }>({
      queryFn: async ({ chainId, pinned }) => {
        try {
          const body = typeof pinned === 'boolean' ? { pinned } : {};
          const raw = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/pin`, 'POST', body);
          const data = unwrapData(raw);
          return { data: { chain: data } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'Chain' as const, id: chainId },
        { type: 'Chain' as const, id: 'GROUPED_LIST' },
        { type: 'Chain' as const, id: 'PINNED_LIST' },
        { type: 'Chain' as const },
      ],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    updateTaskDetail: build.mutation<any, { chainId: string; taskId: string; title?: string; description?: string; assigneeRef?: any; reviewerRefs?: any[]; requiresUserApproval?: boolean; dependsOn?: string[]; bridgeId?: string }>({
      queryFn: async ({ chainId, taskId, title, description, assigneeRef, reviewerRefs, requiresUserApproval, dependsOn, bridgeId }, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();

          let encTitle = title;
          let encDesc = description;
          if (isUnlocked && activeKey) {
            if (encTitle !== undefined && !isVaultArmored(encTitle)) {
              encTitle = await encryptVaultText(encTitle, activeKey);
            }
            if (encDesc !== undefined && !isVaultArmored(encDesc)) {
              encDesc = await encryptVaultText(encDesc, activeKey);
            }
          }

          // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
          const body: any = {};
          if (encTitle !== undefined) body.title = encTitle;
          if (encDesc !== undefined) body.description = encDesc;
          if (assigneeRef !== undefined) body.assignee_ref = assigneeRef;
          if (reviewerRefs !== undefined) body.reviewer_refs = reviewerRefs;
          if (requiresUserApproval !== undefined) body.requires_user_approval = requiresUserApproval;
          if (dependsOn !== undefined) body.depends_on = dependsOn;
          // REQ-TB-5: presence-checked like the hub PATCH — an undefined bridgeId
          // leaves the pin untouched; a defined one (including '') sets or clears it.
          if (bridgeId !== undefined) Object.assign(body, taskPatchBridgeFields(bridgeId));
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}`, 'PATCH', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId, taskId }) => [
        ...preciseTaskTags(taskId, chainId),
        // REQ-AUTO-4: durable actor assignment may create a hub-side capacity-1
        // Fleet row — refetch so an open drawer shows it without a reload.
        { type: 'TaskChainFleets' as const, id: chainId },
      ],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    cancelTaskDetail: build.mutation<any, { chainId: string; taskId: string }>({
      queryFn: async ({ chainId, taskId }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/cancel`, 'POST', {});
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId, taskId }) => preciseTaskTags(taskId, chainId),
    }),
    // CT-3: set a task's priority (P0/P1/P2). The hub recomputes current-task
    // selection so raising priority can preempt a busy assignee.
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    updateTaskPriority: build.mutation<any, { chainId: string; taskId: string; priority: string }>({
      queryFn: async ({ chainId, taskId, priority }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}`, 'PATCH', { priority });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId, taskId }) => preciseTaskTags(taskId, chainId),
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    setInstanceCurrentTask: build.mutation<any, { chainId: string; taskId: string; agentInstanceId: string }>({
      queryFn: async ({ chainId, taskId, agentInstanceId }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/current-task`, 'POST', { agent_instance_id: agentInstanceId });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId, taskId, agentInstanceId }) => [
        ...preciseTaskTags(taskId, chainId),
        ...(agentInstanceId ? [{ type: 'AgentInstances' as const, id: agentInstanceId }] : []),
      ],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    addChainMember: build.mutation<any, { chainId: string; agentInstanceId: string; role?: string }>({
      queryFn: async ({ chainId, agentInstanceId, role }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/members`, 'POST', { agent_instance_id: agentInstanceId, role: role || 'worker' });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [{ type: 'Chain', id: chainId }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    removeChainMember: build.mutation<any, { chainId: string; agentInstanceId: string }>({
      queryFn: async ({ chainId, agentInstanceId }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/members/${encodeURIComponent(agentInstanceId)}`, 'DELETE');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [{ type: 'Chain', id: chainId }],
    }),
    addChainDirectory: build.mutation<any, { chainId: string; path: string; bridgeId?: string; vcsKind?: string }>({
      queryFn: async ({ chainId, path, bridgeId, vcsKind }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/directories`, 'POST', {
            path,
            bridge_id: bridgeId ?? '',
            vcs_kind: vcsKind ?? '',
          });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [{ type: 'Chain', id: chainId }],
    }),

    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchChainTasks: build.query<any, { chainId: string; limit?: number; offset?: number }>({
      queryFn: withSessionQuery(async ({ chainId, limit = 100, offset = 0 }, { session }) => {
        if (!session?.clientToken || !chainId) return { chainId, tasks: [] };
        const data = await daemonApi.listChainTasks({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          chainId,
          limit,
          offset,
        });
        return {
          chainId,
          tasks: (data?.tasks || []).map(normalizeTask),
          total: data?.total || 0,
          limit: data?.limit || limit,
          offset: data?.offset || offset,
          next_offset: data?.next_offset || 0,
          has_more: data?.has_more || false,
        };
      }),
      providesTags: (result, _error, { chainId }) => [
        { type: 'ChainTasks' as const, id: chainId },
        // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
        ...((result?.tasks || []).map((task: any) => ({ type: 'Task' as const, id: task.taskId }))),
      ],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchChainTasksPage: build.query<any, { chainId: string; limit?: number; offset: number }>({
      queryFn: withSessionQuery(async ({ chainId, limit = 100, offset }, { session }) => {
        if (!session?.clientToken || !chainId) return { chainId, tasks: [] };
        const data = await daemonApi.listChainTasks({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          chainId,
          limit,
          offset,
        });
        return {
          chainId,
          tasks: (data?.tasks || []).map(normalizeTask),
          total: data?.total || 0,
          limit: data?.limit || limit,
          offset: data?.offset || offset,
          next_offset: data?.next_offset || 0,
          has_more: data?.has_more || false,
        };
      }),
      async onQueryStarted(arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          const { chainId, limit = 100 } = arg;
          const cacheKeyArgs = { chainId, limit };
          dispatch(
            // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
            tasksApi.util.updateQueryData('fetchChainTasks', cacheKeyArgs as any, (draft) => {
              if (!draft) return;
              draft.has_more = data.has_more;
              draft.next_offset = data.next_offset;
              draft.total = data.total;
              
              // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
              const existingIds = new Set(draft.tasks.map((t: any) => t.taskId));
              for (const task of data.tasks) {
                if (!existingIds.has(task.taskId)) {
                  draft.tasks.push(task);
                }
              }
            })
          );
        } catch {}
      }
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchTask: build.query<any, { taskId: string }>({
      queryFn: withSessionQuery(async ({ taskId }, { session }) => {
        if (!session?.clientToken || !taskId) return { task: null };
        const data = await daemonApi.fetchTask({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          taskId,
        });
        return {
          task: data?.task ? normalizeTask(data.task) : null,
        };
      }),
      providesTags: (_result, _error, { taskId }) => [{ type: 'Task', id: taskId }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchTaskComments: build.query<any, { taskId: string; unresolved?: boolean; limit?: number; offset?: number }>({
      queryFn: withSessionQuery(async ({ taskId, unresolved = false, limit = 20, offset = 0 }, { session }) => {
        if (!session?.clientToken || !taskId) return { taskId, comments: [] };
        const data = await daemonApi.fetchTaskComments({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          taskId,
          unresolved,
          limit,
          offset,
        });
        return {
          taskId,
          comments: (data?.comments || []).map(normalizeTaskComments),
          total: data?.total || 0,
          limit: data?.limit || limit,
          offset: data?.offset || offset,
          next_offset: data?.next_offset || 0,
          has_more: data?.has_more || false,
        };
      }),
      providesTags: (_result, _error, { taskId }) => [{ type: 'TaskComments', id: taskId }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchTaskCommentsPage: build.query<any, { taskId: string; unresolved?: boolean; limit?: number; offset: number }>({
      queryFn: withSessionQuery(async ({ taskId, unresolved = false, limit = 20, offset }, { session }) => {
        if (!session?.clientToken || !taskId) return { taskId, comments: [] };
        const data = await daemonApi.fetchTaskComments({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          taskId,
          unresolved,
          limit,
          offset,
        });
        return {
          taskId,
          comments: (data?.comments || []).map(normalizeTaskComments),
          total: data?.total || 0,
          limit: data?.limit || limit,
          offset: data?.offset || offset,
          next_offset: data?.next_offset || 0,
          has_more: data?.has_more || false,
        };
      }),
      async onQueryStarted(arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          const { taskId, unresolved = false, limit = 20 } = arg;
          const cacheKeyArgs = { taskId, unresolved, limit };
          dispatch(
            // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
            tasksApi.util.updateQueryData('fetchTaskComments', cacheKeyArgs as any, (draft) => {
              if (!draft) return;
              draft.has_more = data.has_more;
              draft.next_offset = data.next_offset;
              draft.total = data.total;
              
              // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
              // TODO(FIX): Replace loose fallback chain with canonical typed schema property
              const existingIds = new Set(draft.comments.map((c: any) => c.comment_id || c.commentId));
              for (const comment of data.comments) {
                // TODO(FIX): Replace loose fallback chain with canonical typed schema property
                const id = comment.comment_id || comment.commentId;
                if (!existingIds.has(id)) {
                  draft.comments.push(comment);
                }
              }
            })
          );
        } catch {}
      }
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchTaskComment: build.query<any, { taskId: string; commentId: string }>({
      queryFn: withSessionQuery(async ({ taskId, commentId }, { session }) => {
        if (!session?.clientToken || !taskId || !commentId) return { comment: null };
        const data = await daemonApi.fetchTaskComment({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          taskId,
          commentId,
        });
        return {
          comment: data?.comment ? normalizeTaskComments(data.comment) : null,
        };
      }),
      providesTags: (_result, _error, { taskId }) => [{ type: 'TaskComments', id: taskId }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchTaskLog: build.query<any, { taskId: string; limit?: number }>({
      queryFn: withSessionQuery(async ({ taskId, limit = 50 }, { session }) => {
        if (!session?.clientToken || !taskId) return normalizeTaskLogPage(taskId, null);
        const data = await daemonApi.fetchTaskLog({
          daemonUrl: session.daemonUrl,
          clientInstanceId: session.clientInstanceId,
          clientToken: session.clientToken,
          taskId,
          limit,
          cursor: 0,
        });
        return normalizeTaskLogPage(taskId, data);
      }),
      providesTags: (_result, _error, { taskId }) => [{ type: 'TaskLog', id: taskId }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchTaskLogPage: build.query<any, { taskId: string; cursor: number; limit?: number }>({
      queryFn: withSessionQuery(async ({ taskId, cursor, limit = 50 }, { session }) => {
        if (!session?.clientToken || !taskId) return normalizeTaskLogPage(taskId, null);
        const data = await daemonApi.fetchTaskLog({
          daemonUrl: session.daemonUrl,
          clientInstanceId: session.clientInstanceId,
          clientToken: session.clientToken,
          taskId,
          limit,
          cursor,
        });
        return normalizeTaskLogPage(taskId, data);
      }),
      async onQueryStarted({ taskId }, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
          dispatch(tasksApi.util.updateQueryData('fetchTaskLog', { taskId }, (draft: any) => {
            if (!draft) return;
            for (const event of data?.events || []) {
              upsertTaskLogEvent(draft.events || (draft.events = []), event);
            }
            draft.nextCursor = Number(data?.nextCursor || 0);
            draft.hasMore = Boolean(data?.hasMore);
            draft.total = Number(data?.total || 0);
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    createTask: build.mutation<any, { chainId: string; title: string; description?: string; status?: string; agentToken?: string; assigneeRef?: any; reviewerRefs?: any[]; requiresUserApproval?: boolean; dependsOn?: string[]; bridgeId?: string; brief?: TaskBriefWire }>({
      queryFn: async ({ chainId, title, description, assigneeRef, reviewerRefs, requiresUserApproval, dependsOn, bridgeId, brief }, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();

          let encTitle = title;
          let encDesc = description || '';
          if (isUnlocked && activeKey) {
            if (encTitle && !isVaultArmored(encTitle)) {
              encTitle = await encryptVaultText(encTitle, activeKey);
            }
            if (encDesc && !isVaultArmored(encDesc)) {
              encDesc = await encryptVaultText(encDesc, activeKey);
            }
          }

          // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
          // REQ-TB-5: bridge_id is only sent when a concrete bridge is chosen —
          // absent and '' both mean inherit on the hub create endpoint.
          const body: any = { title: encTitle, description: encDesc, ...taskCreateBridgeFields(bridgeId) };
          if (assigneeRef !== undefined) body.assignee_ref = assigneeRef;
          if (reviewerRefs !== undefined) body.reviewer_refs = reviewerRefs;
          if (requiresUserApproval !== undefined) body.requires_user_approval = requiresUserApproval;
          if (dependsOn !== undefined) body.depends_on = dependsOn;
          // Task System v2 (M2): the brief travels verbatim; the hub normalises it
          // and validates it at publish (422 brief_incomplete).
          if (brief !== undefined) body.brief = brief;
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks`, 'POST', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => chainId ? [
        { type: 'Chain' as const, id: chainId },
        { type: 'ChainTasks' as const, id: chainId },
        // REQ-AUTO-4: the hub persists a capacity-1 Fleet row for durable task
        // actors — invalidate so the drawer picks the new row up immediately.
        { type: 'TaskChainFleets' as const, id: chainId },
      ] : [],
    }),
    // Task System v2 (M2): POST …/tasks/{t}/publish. A 422 `brief_incomplete`
    // is reworded per task ("Task <title>: missing goal, acceptance") from
    // error.details.tasks[]; `taskTitles` (task_id → title) is optional and the
    // raw task_id is the fallback label. The structured details ride along as
    // `error.data` for callers that want to highlight fields.
    publishTask: build.mutation<any, { chainId: string; taskId: string; taskTitles?: Record<string, string> }>({
      queryFn: async ({ chainId, taskId, taskTitles }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/publish`, 'POST', {});
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: publishErrorMessage(error, taskTitles), data: error?.details } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId, taskId }) => [
        ...preciseTaskTags(taskId, chainId),
        { type: 'ChainList' as const, id: 'ALL' },
      ],
    }),
    // Task System v2 (M2): POST /task-chains/{c}/publish — publishes every draft
    // task; the 422 lists each offending task, surfaced the same way as above.
    publishTaskChain: build.mutation<any, { chainId: string; taskTitles?: Record<string, string> }>({
      queryFn: async ({ chainId, taskTitles }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/publish`, 'POST', {});
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: publishErrorMessage(error, taskTitles), data: error?.details } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'Chain' as const, id: chainId },
        { type: 'ChainTasks' as const, id: chainId },
        { type: 'ChainList' as const, id: 'ALL' },
        { type: 'Chain' as const, id: 'GROUPED_LIST' },
        { type: 'Chain' as const, id: 'PINNED_LIST' },
      ],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    deleteTask: build.mutation<any, { taskId: string; chainId: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, agentToken }, { session }) => {
        return daemonApi.deleteTask({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId, true),
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    addTaskComment: build.mutation<any, { taskId: string; chainId: string; body: string; agentToken?: string; resolveImmediately?: boolean }>({
      queryFn: async ({ taskId, chainId, body }, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();

          let commentBody = body;
          if (isUnlocked && activeKey && commentBody && !isVaultArmored(commentBody)) {
            commentBody = await encryptVaultText(commentBody, activeKey);
          }

          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/comments`, 'POST', { body: commentBody });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { taskId, chainId }) => [...preciseTaskTags(taskId, chainId, true), { type: 'Chain' as const, id: chainId }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    resolveTaskComment: build.mutation<any, { taskId: string; chainId: string; commentId: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, commentId, agentToken }, { session }) => {
        return daemonApi.resolveTaskComment({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          commentId,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId, true),
    }),
    // Task System v2 (M4): human action verbs replacing legacy set-status/vote/nudge.
    userReviewTask: build.mutation<any, { chainId: string; taskId: string; verdict: 'approve' | 'request_changes'; findings?: any }>({
      queryFn: async ({ chainId, taskId, verdict, findings }) => {
        try {
          const body: any = { verdict };
          if (findings !== undefined) body.findings = findings;
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/review`, 'POST', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { taskId, chainId }) => [
        ...preciseTaskTags(taskId, chainId, true),
        { type: 'Chain' as const, id: chainId },
      ],
    }),
    reopenTask: build.mutation<any, { chainId: string; taskId: string }>({
      queryFn: async ({ chainId, taskId }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/reopen`, 'POST', {});
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { taskId, chainId }) => [
        ...preciseTaskTags(taskId, chainId, true),
        { type: 'Chain' as const, id: chainId },
      ],
    }),
    answerTaskBlocker: build.mutation<any, { chainId: string; taskId: string; note?: string }>({
      queryFn: async ({ chainId, taskId, note = '' }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/answer`, 'POST', { note });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { taskId, chainId }) => [
        ...preciseTaskTags(taskId, chainId, true),
        { type: 'Chain' as const, id: chainId },
      ],
    }),
    verifyTask: build.mutation<any, { chainId: string; taskId: string }>({
      queryFn: async ({ chainId, taskId }) => {
        try {
          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/verify`, 'POST', {});
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId, true),
    }),
    fetchTaskEvents: build.query<{ events: any[] }, { chainId: string; taskId: string; beforeId?: number; limit?: number }>({
      queryFn: async ({ chainId, taskId, beforeId, limit = 50 }) => {
        try {
          let url = `/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/events?limit=${limit}`;
          if (beforeId !== undefined) url += `&before_id=${beforeId}`;
          const data = await cookieJsonFetch(url);
          const rawEvents = Array.isArray(data) ? data : data?.data || data?.events || [];
          return { data: { events: rawEvents } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { taskId }) => [{ type: 'TaskLog' as const, id: taskId }],
    }),
    fetchTaskFacet: build.query<{ facet: any }, { chainId: string; taskId: string; attemptNo: number; kind: string }>({
      queryFn: async ({ chainId, taskId, attemptNo, kind }) => {
        try {
          const url = `/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/attempts/${attemptNo}/facets/${encodeURIComponent(kind)}`;
          const data = await cookieJsonFetch(url);
          return { data: { facet: data } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { taskId }) => [{ type: 'Task' as const, id: taskId }],
    }),
    fetchCommitDiff: build.query<any, { chainId: string; directoryId: string; base?: string; head?: string; path?: string; listFiles?: boolean; cursor?: string; limit?: number }>({
      queryFn: async ({ chainId, directoryId, base = '', head = '', path = '', listFiles = false, cursor = '', limit = 50 }) => {
        try {
          const params = new URLSearchParams();
          if (base) params.set('base', base);
          if (head) params.set('head', head);
          if (path) params.set('path', path);
          if (listFiles) params.set('list_files', 'true');
          if (cursor) params.set('cursor', cursor);
          if (limit) params.set('limit', String(limit));
          const data = await cookieJsonFetch(`/task-chains/${encodeURIComponent(chainId)}/directories/${encodeURIComponent(directoryId)}/vcs/commit-diff?${params.toString()}`);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),
    fetchWorkflowTemplates: build.query<{ templates: any[] }, void>({
      queryFn: async () => {
        try {
          const data = await cookieJsonFetch('/workflows/templates');
          return { data: { templates: data?.templates || [] } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),
    fetchWorkflowStatus: build.query<any, { chainId: string }>({
      queryFn: async ({ chainId }) => {
        try {
          const data = await cookieJsonFetch(`/task-chains/${encodeURIComponent(chainId)}/workflow/status`);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { chainId }) => [{ type: 'Chain' as const, id: chainId }],
    }),
    retryWorkflow: build.mutation<any, { chainId: string; stageKey?: string; cascade?: boolean; reason?: string }>({
      queryFn: async ({ chainId, stageKey = '', cascade = false, reason = '' }) => {
        try {
          const data = await cookieMutation(
            `/task-chains/${encodeURIComponent(chainId)}/workflow/retry`,
            'POST',
            { stage_key: stageKey, cascade, reason }
          );
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'Chain' as const, id: chainId },
        { type: 'ChainList' as const, id: 'ALL' },
      ],
    }),
    cancelWorkflow: build.mutation<any, { chainId: string; reason?: string }>({
      queryFn: async ({ chainId, reason = '' }) => {
        try {
          const data = await cookieMutation(
            `/task-chains/${encodeURIComponent(chainId)}/workflow/cancel`,
            'POST',
            { reason }
          );
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'Chain' as const, id: chainId },
        { type: 'ChainList' as const, id: 'ALL' },
      ],
    }),
    runWorkflow: build.mutation<any, { template_id?: string; def_id?: string; name?: string; inputs?: Record<string, any>; project_id?: string }>({
      queryFn: async (payload) => {
        try {
          const data = await cookieMutation('/workflows/run', 'POST', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [
        { type: 'ChainList' as const, id: 'ALL' },
        { type: 'Chain' as const, id: 'GROUPED_LIST' },
      ],
    }),
    fetchWorkflowDefinitions: build.query<{ definitions: WorkflowDefinitionItem[] }, void>({
      queryFn: async () => {
        try {
          const data = await cookieJsonFetch('/workflows/definitions');
          return { data: { definitions: data?.definitions || [] } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [{ type: 'WorkflowDefinitions' as const, id: 'LIST' }],
    }),
    defineWorkflow: build.mutation<WorkflowDefinitionItem, { spec?: any; name?: string; version?: number; spec_json?: string }>({
      queryFn: async (payload) => {
        try {
          const data = await cookieMutation('/workflows/definitions', 'POST', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: 'WorkflowDefinitions' as const, id: 'LIST' }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    updateTask: build.mutation<any, { taskId: string; chainId: string; title?: string; description?: string; acceptanceCriteria?: string; dependsOn?: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, title, description, acceptanceCriteria, dependsOn, agentToken }, { session, state }) => {
        const isUnlocked = Boolean(state?.vault?.isUnlocked);
        const activeKey = getActiveVaultKey();

        let encTitle = title;
        let encDesc = description;
        if (isUnlocked && activeKey) {
          if (encTitle !== undefined && !isVaultArmored(encTitle)) {
            encTitle = await encryptVaultText(encTitle, activeKey);
          }
          if (encDesc !== undefined && !isVaultArmored(encDesc)) {
            encDesc = await encryptVaultText(encDesc, activeKey);
          }
        }

        return daemonApi.updateTask({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          title: encTitle,
          description: encDesc,
          acceptanceCriteria,
          dependsOn,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId),
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    assignTask: build.mutation<any, { taskId: string; chainId: string; agentInstanceId: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, agentInstanceId, agentToken }, { session }) => {
        return daemonApi.assignTask({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          agentInstanceId,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId),
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    addTaskParticipant: build.mutation<any, { taskId: string; chainId: string; agentInstanceId: string; role: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, agentInstanceId, role, agentToken }, { session }) => {
        return daemonApi.addTaskParticipant({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          agentInstanceId,
          role,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId),
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    removeTaskParticipant: build.mutation<any, { taskId: string; chainId: string; agentInstanceId: string; role: string; agentToken?: string }>({
      queryFn: withSessionQuery(async ({ taskId, chainId, agentInstanceId, role, agentToken }, { session }) => {
        return daemonApi.removeTaskParticipant({
          daemonUrl: session.daemonUrl,
          ...taskMutationAuth(session, agentToken),
          taskId,
          chainId,
          agentInstanceId,
          role,
        });
      }),
      invalidatesTags: (_result, _error, { taskId, chainId }) => preciseTaskTags(taskId, chainId),
    }),
  }),
});

export const {
  useFetchChainTasksQuery,
  useLazyFetchChainTasksPageQuery,
  useFetchTaskQuery,
  useLazyFetchTaskQuery,
  useFetchTaskCommentsQuery,
  useLazyFetchTaskCommentsPageQuery,
  useFetchTaskCommentQuery,
  useLazyFetchTaskCommentQuery,
  useFetchTaskLogQuery,
  useLazyFetchTaskLogPageQuery,

  useFetchTaskChainGroupsQuery,
  useFetchTaskChainProjectPageQuery,
  useLazyFetchTaskChainProjectPageQuery,
  useListTaskChainsQuery,
  useLazyListTaskChainsQuery,
  useListPinnedTaskChainsQuery,
  useFetchPinnedTaskChainsQuery,
  useFetchTaskChainDetailQuery,
  useFetchChainTaskDetailQuery,
  useFetchChainTaskCommentsQuery,
  useLazyFetchChainTaskCommentsQuery,
  useListChainsByCoordinatorQuery,
  useCreateTaskChainMutation,
  useUpdateTaskChainMutation,
  useTogglePinTaskChainMutation,
  useUpdateTaskDetailMutation,
  useCancelTaskDetailMutation,
  useUpdateTaskPriorityMutation,
  useAddChainMemberMutation,
  useRemoveChainMemberMutation,
  useAddChainDirectoryMutation,

  useCreateTaskMutation,
  usePublishTaskMutation,
  usePublishTaskChainMutation,
  useDeleteTaskMutation,
  useAddTaskCommentMutation,
  useResolveTaskCommentMutation,
  useUpdateTaskMutation,
  useAssignTaskMutation,
  useAddTaskParticipantMutation,
  useRemoveTaskParticipantMutation,

  // Task System v2 (M4) verbs & queries
  useUserReviewTaskMutation,
  useReopenTaskMutation,
  useAnswerTaskBlockerMutation,
  useVerifyTaskMutation,
  useFetchTaskEventsQuery,
  useLazyFetchTaskEventsQuery,
  useFetchTaskFacetQuery,
  useLazyFetchTaskFacetQuery,
  useFetchCommitDiffQuery,
  useLazyFetchCommitDiffQuery,
  useFetchWorkflowTemplatesQuery,
  useFetchWorkflowDefinitionsQuery,
  useDefineWorkflowMutation,
  useFetchWorkflowStatusQuery,
  useRetryWorkflowMutation,
  useCancelWorkflowMutation,
  useRunWorkflowMutation,
} = tasksApi;

export {
  useGetTaskChainFleetsQuery,
  useLazyGetTaskChainFleetsQuery,
  useUpdateTaskChainFleetMutation,
  useDeleteTaskChainFleetMutation,
  normalizeFleet,
} from './taskChains';
export type { TaskChainFleet } from './taskChains';
