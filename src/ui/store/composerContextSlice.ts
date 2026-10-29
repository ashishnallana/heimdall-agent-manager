import { createSlice, type PayloadAction } from '@reduxjs/toolkit';
import { EMPTY_QUOTES, quoteLimitError, sameQuote, type QuoteContext } from '../utils/quoteContext';
type ContextState = { byTarget: Record<string, QuoteContext[]>; epoch: number; focusTarget: string; focusRevision: number };
const initialState: ContextState = { byTarget: {}, epoch: 0, focusTarget: '', focusRevision: 0 };
const slice = createSlice({
  name: 'composerContext', initialState,
  reducers: {
    addComposerQuote(state, { payload }: PayloadAction<{ target: string; quote: QuoteContext }>) {
      const list = state.byTarget[payload.target] || [];
      if (quoteLimitError(list, payload.quote)) return;
      if (!list.some(item => sameQuote(item, payload.quote))) state.byTarget[payload.target] = [...list, payload.quote];
      state.focusTarget = payload.target;
      state.focusRevision++;
    },
    removeComposerQuote(state, { payload }: PayloadAction<{ target: string; id: string }>) {
      state.byTarget[payload.target] = (state.byTarget[payload.target] || []).filter(item => item.id !== payload.id);
    },
    consumeComposerQuotes(state, { payload }: PayloadAction<{ target: string; ids: string[]; epoch: number }>) {
      if (payload.epoch !== state.epoch) return;
      state.byTarget[payload.target] = (state.byTarget[payload.target] || []).filter(item => !payload.ids.includes(item.id));
    },
    clearComposerContexts(state) {
      state.byTarget = {}; state.focusTarget = ''; state.epoch++;
    },
  },
});
export const { addComposerQuote, removeComposerQuote, consumeComposerQuotes, clearComposerContexts } = slice.actions;
export const selectComposerQuotes = (state: any, target: string): QuoteContext[] => state.composerContext?.byTarget[target] || EMPTY_QUOTES;
export default slice.reducer;
