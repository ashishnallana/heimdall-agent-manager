import { combineReducers, configureStore, createAction } from '@reduxjs/toolkit';
import { heimdallApi, setupHeimdallApiListeners } from '../api/heimdallApi';
import { vaultCacheInvalidationMiddleware } from '../api/vaultCacheInvalidation';
import { paneDeferralResetMiddleware } from '../api/wsInvalidation';
import '../api/endpoints/tasks';
import '../api/endpoints/chats';
import '../api/endpoints/agents';
import '../api/endpoints/sidebar';
import chatReducer from './chatSlice';
import taskReducer from './taskSlice';
import memoryReducer from './memorySlice';
import projectReducer from './projectSlice';
import homeReducer from './homeSlice';
import chainViewReducer from './chainViewSlice';
import attentionReducer from './attentionSlice';
import toastReducer from './toastSlice';
import notificationsReducer from './notificationsSlice';
import agentActivityReducer from './agentActivitySlice';
import cardsReducer from './cardsSlice';
import themeReducer from './themeSlice';
import vaultReducer from './vaultSlice';
import deviceVaultReducer from './deviceVaultSlice';
import searchTitleReducer from './searchTitleSlice';
import shellReducer from './shellSlice';
import workspaceLayoutReducer from './workspaceLayoutSlice';
import auxPanesReducer from './auxPanesSlice';
import workspaceChromeReducer from './workspaceChromeSlice';

export const priorUserClientStateCleared = createAction('heimdall/priorUserClientStateCleared');

const appReducer = combineReducers({
  chat: chatReducer,
  tasks: taskReducer,
  memory: memoryReducer,
  projects: projectReducer,
  home: homeReducer,
  chainView: chainViewReducer,
  attention: attentionReducer,
  toasts: toastReducer,
  notifications: notificationsReducer,
  cards: cardsReducer,
  theme: themeReducer,
  vault: vaultReducer,
  deviceVault: deviceVaultReducer,
  searchTitle: searchTitleReducer,
  // REQ-SHELL-6 §6: a push-only tick for the shell consumers that are not RTK
  // Query caches, so no shell view needs a poller. See shellSlice.ts.
  shells: shellReducer,
  // Global Workspace: Main split tree of agent chats + ONE aux dock (Jetski parity).
  workspaceLayout: workspaceLayoutReducer,
  auxPanes: auxPanesReducer,
  workspaceChrome: workspaceChromeReducer,
  // Ephemeral, non-cache agent activity (push-only bubbles). Reset with the rest
  // of client state on user switch via the priorUserClientStateCleared handling
  // in rootReducer below.
  agentActivity: agentActivityReducer,
  [heimdallApi.reducerPath]: heimdallApi.reducer,
});

const rootReducer = (state: ReturnType<typeof appReducer> | undefined, action: any) => {
  if (action.type === priorUserClientStateCleared.type) {
    state = undefined;
  }
  return appReducer(state, action);
};

const actionLogger = (store: any) => (next: any) => (action: any) => {
  if (import.meta.env.DEV) {
    console.log('[Redux Action]', action.type, action.payload);
  }
  return next(action);
};

export const store = configureStore({
  reducer: rootReducer,
  middleware: (getDefaultMiddleware) =>
    // REQ-CACHE-1: vaultCacheInvalidationMiddleware runs BEFORE heimdallApi.middleware
    // so the reset it dispatches on a lock/unlock transition is handled by the API
    // middleware in the same pass. See api/vaultCacheInvalidation.ts.
    getDefaultMiddleware().concat(
      actionLogger,
      vaultCacheInvalidationMiddleware,
      // Sees the resetApiState that vaultCacheInvalidationMiddleware or a user switch
      // dispatches, and drops owner-specific deferral state with it.
      paneDeferralResetMiddleware,
      heimdallApi.middleware,
    ),
});

setupHeimdallApiListeners(store.dispatch);
