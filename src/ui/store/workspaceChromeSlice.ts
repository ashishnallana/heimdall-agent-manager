import { createSlice, type PayloadAction } from '@reduxjs/toolkit';
import type { SplitDirection } from '../tiling';

/**
 * Workspace window chrome (Jetski `agentWindow/store/layoutStore.ts`
 * equivalent): aux dock width (persisted), aux maximize, and the pending
 * drag-to-split drop target of a Main pane.
 */
export interface WorkspaceChromeState {
  /** Resized aux width in px; null = default width. */
  auxWidth: number | null;
  isAuxMaximized: boolean;
  pendingSplitDrop: { paneId: string; direction: SplitDirection } | null;
}

export const AUX_MIN_WIDTH = 320;
export const AUX_DEFAULT_WIDTH = 520;
export const AUX_MAX_WIDTH = 1600;

const initialState: WorkspaceChromeState = {
  auxWidth: null,
  isAuxMaximized: false,
  pendingSplitDrop: null,
};

export function clampAuxWidth(width: number): number {
  if (!Number.isFinite(width)) return AUX_DEFAULT_WIDTH;
  return Math.round(Math.max(AUX_MIN_WIDTH, Math.min(AUX_MAX_WIDTH, width)));
}

const workspaceChromeSlice = createSlice({
  name: 'workspaceChrome',
  initialState,
  reducers: {
    setAuxWidth(state, action: PayloadAction<number | null>) {
      state.auxWidth = action.payload === null ? null : clampAuxWidth(action.payload);
    },
    setAuxMaximized(state, action: PayloadAction<boolean>) {
      state.isAuxMaximized = action.payload;
    },
    toggleAuxMaximized(state) {
      state.isAuxMaximized = !state.isAuxMaximized;
    },
    setPendingSplitDrop(
      state,
      action: PayloadAction<{ paneId: string; direction: SplitDirection } | null>,
    ) {
      state.pendingSplitDrop = action.payload;
    },
    hydrateWorkspaceChrome(state, action: PayloadAction<unknown>) {
      const raw = action.payload as any;
      if (!raw || typeof raw !== 'object') return;
      if (typeof raw.auxWidth === 'number' && Number.isFinite(raw.auxWidth)) {
        state.auxWidth = clampAuxWidth(raw.auxWidth);
      }
      // Maximize and drag state are session-only, like Jetski.
    },
  },
});

export const {
  setAuxWidth,
  setAuxMaximized,
  toggleAuxMaximized,
  setPendingSplitDrop,
  hydrateWorkspaceChrome,
} = workspaceChromeSlice.actions;

function extract(state: any): WorkspaceChromeState {
  if (state?.workspaceChrome) return state.workspaceChrome as WorkspaceChromeState;
  return initialState;
}

export const selectAuxWidth = (state: any): number | null => extract(state).auxWidth;
export const selectIsAuxMaximized = (state: any): boolean => extract(state).isAuxMaximized;
export const selectPendingSplitDrop = (state: any) => extract(state).pendingSplitDrop;

export default workspaceChromeSlice.reducer;
