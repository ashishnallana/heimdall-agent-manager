import { createSlice, type PayloadAction } from '@reduxjs/toolkit';

export const INPUT_PREFERENCES_STORAGE_KEY = 'heimdall:input-preferences:v1';

export interface InputPreferencesState {
  useExternalKeyboard: boolean;
}

function parsePreference(raw: string | null): InputPreferencesState {
  try {
    const saved = raw ? JSON.parse(raw) : null;
    return { useExternalKeyboard: saved?.useExternalKeyboard === true };
  } catch {
    return { useExternalKeyboard: false };
  }
}

function loadPreference(): InputPreferencesState {
  try {
    return parsePreference(typeof window === 'undefined' ? null : window.localStorage.getItem(INPUT_PREFERENCES_STORAGE_KEY));
  } catch {
    return { useExternalKeyboard: false };
  }
}

const inputPreferencesSlice = createSlice({
  name: 'inputPreferences',
  // Read on store creation/reset so the browser-local choice survives user switches.
  initialState: loadPreference,
  reducers: {
    externalKeyboardSet(state, action: PayloadAction<boolean>) {
      state.useExternalKeyboard = action.payload;
      try {
        window.localStorage.setItem(INPUT_PREFERENCES_STORAGE_KEY, JSON.stringify({ useExternalKeyboard: action.payload }));
      } catch {
        // Keep the in-memory choice usable when browser storage is unavailable.
      }
    },
    inputPreferencesLoaded(_state, action: PayloadAction<InputPreferencesState>) {
      return action.payload;
    },
  },
});

export const { externalKeyboardSet, inputPreferencesLoaded } = inputPreferencesSlice.actions;
export const selectUseExternalKeyboard = (state: { inputPreferences?: InputPreferencesState }) =>
  state.inputPreferences?.useExternalKeyboard ?? false;

// Other tabs update Redux without writing back to storage (no echo loop).
export function setupInputPreferencesSync(dispatch: (action: ReturnType<typeof inputPreferencesLoaded>) => unknown) {
  if (typeof window === 'undefined') return () => {};
  const onStorage = (event: StorageEvent) => {
    try {
      if (event.storageArea !== window.localStorage) return;
      if (event.key === INPUT_PREFERENCES_STORAGE_KEY || event.key === null) {
        dispatch(inputPreferencesLoaded(parsePreference(event.newValue)));
      }
    } catch {
      // Accessing localStorage itself can throw in restricted browsers.
    }
  };
  window.addEventListener('storage', onStorage);
  return () => window.removeEventListener('storage', onStorage);
}

export default inputPreferencesSlice.reducer;
