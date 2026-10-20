import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import * as daemonApi from '../api/daemonApi';
import { matchesMemoryFilters } from '../api/memoryCatalog';

const initialFilters = {
  targetAgentId: '',
  targetProjectId: '',
  targetTemplateId: '',
  targetBridgeId: '',
  type: '',
  status: '',
  targeting: 'all',
  pendingActiveOnly: false,
  search: '',
};

export { matchesMemoryFilters };

export const triggerMemoryAudit = createAsyncThunk(
  'memory/triggerMemoryAudit',
  async (
    payload: { timeRange?: string; targetChains?: string[]; auditorInstructions?: string },
    { getState }
  ) => {
    const state = getState() as any;
    const { session } = state.chat;
    if (!session.clientToken) throw new Error('Not authenticated');
    const result = await daemonApi.triggerMemoryAudit({
      daemonUrl: session.daemonUrl,
      clientToken: session.clientToken,
      timeRange: payload.timeRange,
      targetChains: payload.targetChains,
      auditorInstructions: payload.auditorInstructions,
    });
    return result;
  }
);

const initialState = {
  filters: { ...initialFilters },
  error: '',
  lastMemoryEvent: null as any,
  activeAudit: null as {
    auditId: string;
    timeRange: string;
    status: string;
    targetChains: string[];
    startedAtUnixMs: number;
    completedAtUnixMs?: number;
    error?: string;
  } | null,
  auditLoading: false,
};

const memorySlice = createSlice({
  name: 'memory',
  initialState,
  reducers: {
    setMemoryFilters(state: any, action) {
      state.filters = { ...state.filters, ...action.payload };
    },
    resetMemoryFilters(state: any) {
      state.filters = { ...initialFilters };
    },
    memoryEventReceived(state: any, action) {
      state.lastMemoryEvent = action.payload;
    },
    auditStartedReceived(state: any, action) {
      state.activeAudit = {
        auditId: action.payload.audit_id || '',
        timeRange: action.payload.time_range || '',
        status: 'started',
        targetChains: action.payload.target_chains || [],
        startedAtUnixMs: Date.now(),
      };
      state.auditLoading = true;
      state.error = '';
    },
    auditEndedReceived(state: any, action) {
      if (state.activeAudit && state.activeAudit.auditId === action.payload.audit_id) {
        state.activeAudit.status = action.payload.status || 'completed';
        state.activeAudit.completedAtUnixMs = action.payload.completed_at_unix_ms || Date.now();
        if (action.payload.status === 'failed') {
          state.activeAudit.error = action.payload.reason || action.payload.failure_reason || 'Unknown audit failure';
        }
      } else {
        state.activeAudit = {
          auditId: action.payload.audit_id || '',
          timeRange: '',
          status: action.payload.status || 'completed',
          targetChains: [],
          startedAtUnixMs: Date.now() - 5000,
          completedAtUnixMs: action.payload.completed_at_unix_ms || Date.now(),
          error: action.payload.status === 'failed' ? (action.payload.reason || action.payload.failure_reason || 'Unknown audit failure') : undefined,
        };
      }
      state.auditLoading = false;
    },
    clearActiveAudit(state: any) {
      state.activeAudit = null;
      state.error = '';
    }
  },
  extraReducers: (builder) => {
    builder
      .addCase(triggerMemoryAudit.pending, (state: any) => {
        state.auditLoading = true;
        state.error = '';
      })
      .addCase(triggerMemoryAudit.fulfilled, (state: any, action) => {
        state.error = '';
        state.auditLoading = false;
        if (action.payload?.audit_id) {
          if (!state.activeAudit || state.activeAudit.auditId !== action.payload.audit_id) {
            state.activeAudit = {
              auditId: action.payload.audit_id || '',
              timeRange: action.meta.arg.timeRange || (action.meta.arg.targetChains?.length ? 'manual' : ''),
              status: 'started',
              targetChains: action.meta.arg.targetChains || [],
              startedAtUnixMs: Date.now(),
            };
          }
          state.auditLoading = state.activeAudit?.status === 'started';
        }
      })
      .addCase(triggerMemoryAudit.rejected, (state: any, action) => {
        state.auditLoading = false;
        state.error = action.error.message || 'Failed to trigger memory audit';
      });
  },
});

export const selectMemoryState = (state: any) => state.memory;

export const { setMemoryFilters, resetMemoryFilters, memoryEventReceived, auditStartedReceived, auditEndedReceived, clearActiveAudit } = memorySlice.actions;
export default memorySlice.reducer;
