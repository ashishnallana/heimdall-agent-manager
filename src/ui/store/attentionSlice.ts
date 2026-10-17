import { createSlice } from '@reduxjs/toolkit';

const initialState = {
  loading: false,
  error: '',
  lastEventAt: 0,
};

const attentionSlice = createSlice({
  name: 'attention',
  initialState,
  reducers: {
    attentionEventReceived(state: any) {
      state.lastEventAt = Date.now();
    },
    setAttentionError(state: any, action) {
      state.error = action.payload || '';
    },
  },
});

export const { attentionEventReceived, setAttentionError } = attentionSlice.actions;
export default attentionSlice.reducer;
