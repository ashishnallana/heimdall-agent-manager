import { createSlice, type PayloadAction } from '@reduxjs/toolkit';

export type PlacementDraft = {
  action: 'bridge' | 'identity'; bridgeId: string; agentId: string;
  /** A rejected observation stays unusable even if the deck is closed/reopened. */
  rejectedGuard?: string;
};

const initialState = {
  loading: false,
  error: '',
  lastEventAt: 0,
  placementDrafts: {} as Record<string, PlacementDraft>,
};

const attentionSlice = createSlice({
  name: 'attention',
  initialState,
  reducers: {
    setPlacementDraft(state, action: PayloadAction<{ key: string; draft: PlacementDraft }>) {
      state.placementDrafts[action.payload.key] = action.payload.draft;
    },
    clearPlacementDraft(state, action: PayloadAction<string>) {
      delete state.placementDrafts[action.payload];
    },
    attentionEventReceived(state: any) {
      state.lastEventAt = Date.now();
    },
    setAttentionError(state: any, action) {
      state.error = action.payload || '';
    },
  },
});

export const { attentionEventReceived, setAttentionError, setPlacementDraft, clearPlacementDraft } = attentionSlice.actions;
export default attentionSlice.reducer;
