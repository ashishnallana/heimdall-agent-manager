import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
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
        state.error = action.error.message || 'Failed to load ticket log';
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
