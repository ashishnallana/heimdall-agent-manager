import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import * as daemonApi from '../api/daemonApi';
import { selectCachedTaskById } from '../api/taskCache';
import { tasksApi } from '../api/endpoints/tasks';
import { getRouteSearch } from '../utils/appLocation';

const TASK_LOG_RELOAD_DEDUPE_MS = 1500;

function normalizeChain(chain: any) {
  return {
    id: chain.chain_id,
    chainId: chain.chain_id,
    title: chain.title || '',
    description: chain.description || '',
    status: chain.status || 'active',
    projectId: chain.project_id || chain.projectId || '',
    vcsWorkspaceId: chain.vcs_workspace_id || chain.vcsWorkspaceId || '',
    diffBaseSha: chain.diff_base_sha || chain.diffBaseSha || '',
    repoDiffSupported: Boolean(chain.repo_diff_supported || chain.repoDiffSupported),
    coordinatorAgentInstanceId: chain.coordinator_agent_instance_id || '',
    defaultReviewerAgentInstanceId: chain.default_reviewer_agent_instance_id || '',
    finalSummary: chain.final_summary || '',
    createdAtUnixMs: Number(chain.created_at_unix_ms || 0),
    completedAtUnixMs: Number(chain.completed_at_unix_ms || 0),
    archivePending: Boolean(chain.archive_pending),
    archived: Boolean(chain.archived),
    evaluation: chain.evaluation || 'unreviewed',
  };
}

function getActiveTaskId(payload: any): string {
  if (payload?.taskId) return payload.taskId;
  const params = new URLSearchParams(getRouteSearch());
  return params.get('taskId') || '';
}

function getActiveChainId(payload: any): string {
  if (payload?.chainId) return payload.chainId;
  const params = new URLSearchParams(getRouteSearch());
  return params.get('chainId') || '';
}

function getSelectedTaskFromCache(state: any, payload: any) {
  const activeTaskId = getActiveTaskId(payload);
  const task = selectCachedTaskById(state, activeTaskId);
  if (!task) throw new Error(`Task ${activeTaskId || '(unknown)'} is not loaded in the RTK Query cache`);
  return task;
}

// TODO(rtkq-migration owner=task-19f69e242e4): component compatibility wrapper for unmigrated chain/task-list surfaces. Do not add follow-up refresh chaining around this thunk; prefer RTKQ hooks or endpoint initiate calls.
export const fetchTasksForChain = createAsyncThunk(
  'tasks/fetchTasksForChain',
  async (chainId: string, { dispatch, getState }) => {
    const { session } = (getState() as any).chat;
    if (!session.clientToken || !chainId) return { chainId, tasks: [] };

    return await (dispatch as any)(tasksApi.endpoints.fetchChainTasks.initiate({ chainId })).unwrap();
  },
  {
    condition: (chainId, { getState }) => {
      if (!chainId) return false;
      const queryState = tasksApi.endpoints.fetchChainTasks.select({ chainId })(getState() as any);
      return queryState?.status !== 'pending';
    },
  },
);

// TODO(rtkq-migration owner=task-19f69e242e4): compatibility wrapper for older task-log open/load-more callers. The authoritative recurring cache for live task logs is tasksApi.fetchTaskLog/fetchTaskLogPage.
export const fetchSelectedTaskLog = createAsyncThunk(
  'tasks/fetchSelectedTaskLog',
  async (payload: string | { taskId?: string; limit?: number; cursor?: number; force?: boolean } | undefined, { dispatch, getState }) => {
    const state = getState() as any;
    const { session } = state.chat;
    const selectedTaskId = typeof payload === 'string' ? payload : (payload?.taskId || getActiveTaskId(null));
    const limit = typeof payload === 'object' && payload?.limit !== undefined ? payload.limit : 50;
    const cursor = typeof payload === 'object' && payload?.cursor !== undefined ? payload.cursor : 0;
    if (!selectedTaskId || !session.clientToken) return { taskId: selectedTaskId, events: [], nextCursor: 0, hasMore: false, total: 0, isAppend: false };
    const result = cursor > 0
      ? await (dispatch as any)(tasksApi.endpoints.fetchTaskLogPage.initiate({ taskId: selectedTaskId, cursor, limit })).unwrap()
      : await (dispatch as any)(tasksApi.endpoints.fetchTaskLog.initiate({ taskId: selectedTaskId, limit })).unwrap();
    return { ...result, taskId: selectedTaskId, isAppend: cursor > 0 };
  },
  {
    condition: (payload: string | { taskId?: string; limit?: number; cursor?: number; force?: boolean } | undefined, { getState }) => {
      const state = getState() as any;
      const selectedTaskId = typeof payload === 'string' ? payload : (payload?.taskId || getActiveTaskId(null));
      const cursor = typeof payload === 'object' && payload?.cursor !== undefined ? payload.cursor : 0;
      const force = typeof payload === 'object' && Boolean(payload?.force);
      if (!selectedTaskId) return false;
      if (cursor > 0 || force) return true;
      const queryState = tasksApi.endpoints.fetchTaskLog.select({ taskId: selectedTaskId })(state);
      if (queryState?.status === 'pending') return false;
      const lastLoadedAt = Number(state.tasks?.taskLogLoadedAtByTaskId?.[selectedTaskId] || 0);
      return !lastLoadedAt || Date.now() - lastLoadedAt > TASK_LOG_RELOAD_DEDUPE_MS;
    },
  },
);

function taskMutationAuth(session: any, agentToken: string) {
  return {
    agentToken: agentToken?.trim() || '',
    clientInstanceId: session.clientInstanceId,
    clientToken: session.clientToken,
  };
}

export const createTaskFromBoard = createAsyncThunk('tasks/createTaskFromBoard', async (payload: any, { getState }) => {
  const { session } = (getState() as any).chat;
  const result = await daemonApi.createTask({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), ...payload });
  return result;
});

export const createChainFromBoard = createAsyncThunk('tasks/createChainFromBoard', async (payload: any, { getState }) => {
  const { session } = (getState() as any).chat;
  const result = await daemonApi.createTaskChain({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), ...payload });
  return result;
});

export const addCommentToSelectedTask = createAsyncThunk('tasks/addCommentToSelectedTask', async (payload: any, { dispatch, getState }) => {
  const state = getState() as any;
  const task = getSelectedTaskFromCache(state, payload);
  return await (dispatch as any)(tasksApi.endpoints.addTaskComment.initiate({ taskId: task.taskId, chainId: task.chainId, body: payload.body, agentToken: payload.agentToken, resolveImmediately: payload.resolveImmediately })).unwrap();
});

export const resolveCommentOnSelectedTask = createAsyncThunk('tasks/resolveCommentOnSelectedTask', async (payload: any, { dispatch, getState }) => {
  const task = getSelectedTaskFromCache(getState() as any, payload);
  return await (dispatch as any)(tasksApi.endpoints.resolveTaskComment.initiate({ taskId: task.taskId, chainId: task.chainId, commentId: payload.commentId, agentToken: payload.agentToken })).unwrap();
});

export const updateSelectedTaskStatus = createAsyncThunk('tasks/updateSelectedTaskStatus', async (payload: any) => {
  // Task System v2: manual status setting is disabled; state is a fold over task events.
  return { taskId: payload?.taskId, status: payload?.status };
});

export const updateSelectedTaskMetadata = createAsyncThunk('tasks/updateSelectedTaskMetadata', async (payload: any, { dispatch, getState }) => {
  const task = getSelectedTaskFromCache(getState() as any, payload);
  await (dispatch as any)(tasksApi.endpoints.updateTask.initiate({ taskId: task.taskId, chainId: task.chainId, title: payload.title, description: payload.description, acceptanceCriteria: payload.acceptanceCriteria, dependsOn: payload.dependsOn, agentToken: payload.agentToken })).unwrap();
  const data = await (dispatch as any)(tasksApi.endpoints.fetchTask.initiate({ taskId: task.taskId }, { subscribe: false, forceRefetch: true })).unwrap();
  return data.task || null;
});

export const assignSelectedTask = createAsyncThunk('tasks/assignSelectedTask', async (payload: any, { dispatch, getState }) => {
  const task = getSelectedTaskFromCache(getState() as any, payload);
  return await (dispatch as any)(tasksApi.endpoints.assignTask.initiate({ taskId: task.taskId, chainId: task.chainId, agentInstanceId: payload.agentInstanceId, agentToken: payload.agentToken })).unwrap();
});

export const addParticipantToSelectedTask = createAsyncThunk('tasks/addParticipantToSelectedTask', async (payload: any, { dispatch, getState }) => {
  const task = getSelectedTaskFromCache(getState() as any, payload);
  return await (dispatch as any)(tasksApi.endpoints.addTaskParticipant.initiate({ taskId: task.taskId, chainId: task.chainId, agentInstanceId: payload.agentInstanceId, role: payload.role, agentToken: payload.agentToken })).unwrap();
});

export const removeParticipantFromSelectedTask = createAsyncThunk('tasks/removeParticipantFromSelectedTask', async (payload: any, { dispatch, getState }) => {
  const task = getSelectedTaskFromCache(getState() as any, payload);
  return await (dispatch as any)(tasksApi.endpoints.removeTaskParticipant.initiate({ taskId: task.taskId, chainId: task.chainId, agentInstanceId: payload.agentInstanceId, role: payload.role, agentToken: payload.agentToken })).unwrap();
});

export const voteOnSelectedTask = createAsyncThunk('tasks/voteOnSelectedTask', async (payload: any, { dispatch, getState }) => {
  const task = getSelectedTaskFromCache(getState() as any, payload);
  return await (dispatch as any)(tasksApi.endpoints.userReviewTask.initiate({
    taskId: task.taskId,
    chainId: task.chainId,
    verdict: payload.approved ? 'approve' : 'request_changes',
    findings: payload.comment ? [payload.comment] : undefined,
  })).unwrap();
});

export const voteOnAttentionTask = createAsyncThunk('tasks/voteOnAttentionTask', async (payload: { taskId: string; chainId: string; approved: boolean; comment?: string }, { dispatch }) => {
  await (dispatch as any)(tasksApi.endpoints.userReviewTask.initiate({
    taskId: payload.taskId,
    chainId: payload.chainId,
    verdict: payload.approved ? 'approve' : 'request_changes',
    findings: payload.comment ? [payload.comment] : undefined,
  })).unwrap();
  return { taskId: payload.taskId, chainId: payload.chainId, approved: payload.approved };
});

export const nudgeSelectedTask = createAsyncThunk('tasks/nudgeSelectedTask', async () => {
  // Task System v2: manual nudge is disabled; matching is event and timer driven.
  return { success: true };
});

export const updateSelectedChainMetadata = createAsyncThunk('tasks/updateSelectedChainMetadata', async (payload: any, { getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const chainId = getActiveChainId(payload);
  await daemonApi.updateTaskChain({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), chainId, title: payload.title, description: payload.description, coordinatorAgentInstanceId: payload.coordinatorAgentInstanceId, defaultReviewerAgentInstanceId: payload.defaultReviewerAgentInstanceId, finalSummary: payload.finalSummary });
});

export const updateSelectedChainStatus = createAsyncThunk('tasks/updateSelectedChainStatus', async (payload: any, { getState }) => {
  const state = getState() as any;
  const { session } = state.chat;
  const chainId = getActiveChainId(payload);
  await daemonApi.updateTaskChainStatus({ daemonUrl: session.daemonUrl, ...taskMutationAuth(session, payload.agentToken), chainId, status: payload.status, finalSummary: payload.finalSummary });
});

export const fetchUnreviewedChains = createAsyncThunk(
  'tasks/fetchUnreviewedChains',
  // UI-15: legacy audit-sidebar surface removed (AuditSidebar/AuditCard deleted).
  // Kept as a no-op stub so the slice's public export surface and the rtkq-
  // migration quarantine marker stay intact; no component dispatches this.
  async () => []
);

export const evaluateTaskChain = createAsyncThunk(
  'tasks/evaluateTaskChain',
  // UI-15: legacy audit-sidebar surface removed. No-op stub retained for
  // export-surface compatibility; no component dispatches this.
  async (payload: { chainId: string; evaluation: 'good' | 'bad' }) => ({ chainId: payload.chainId, evaluation: payload.evaluation })
);

const initialState = {
  expandedChainIds: {},
  taskLogLoadedAtByTaskId: {},
  loading: false,
  error: '',
  lastTaskEvent: null,
  unreviewedChains: [] as any[],
};

const taskSlice = createSlice({
  name: 'tasks',
  initialState,
  reducers: {
    toggleChainExpanded(state: any, action) {
      const chainId = action.payload;
      if (!chainId) return;
      state.expandedChainIds[chainId] = !state.expandedChainIds[chainId];
    },
    taskEventReceived(state: any, action) {
      state.lastTaskEvent = action.payload;
      const payload = action.payload;
      if (payload) {
        if (payload.event === 'Chain_Completed' && payload.chain) {
          const normalized = normalizeChain(payload.chain);
          if (!state.unreviewedChains.some((c: any) => c.chainId === normalized.chainId)) {
            state.unreviewedChains.push(normalized);
          }
        } else if (payload.event === 'Chain_Evaluated') {
          state.unreviewedChains = state.unreviewedChains.filter((c: any) => c.chainId !== payload.chain_id);
        }
      }
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(fetchSelectedTaskLog.fulfilled, (state: any, action) => {
        const { taskId, cursor, isAppend } = action.payload;
        if (taskId && !isAppend && Number(cursor || 0) <= 0) {
          state.taskLogLoadedAtByTaskId[taskId] = Date.now();
        }
      })
      .addCase(fetchSelectedTaskLog.rejected, (state: any, action) => {
        state.error = action.error.message || 'Failed to load task log';
      })
      .addCase(fetchUnreviewedChains.fulfilled, (state: any, action) => {
        state.unreviewedChains = action.payload;
      })
      .addCase(evaluateTaskChain.fulfilled, (state: any, action) => {
        const { chainId } = action.payload;
        state.unreviewedChains = state.unreviewedChains.filter((c: any) => c.chainId !== chainId);
      });
  },
});

export const { toggleChainExpanded, taskEventReceived } = taskSlice.actions;
export default taskSlice.reducer;
