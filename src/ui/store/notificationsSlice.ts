import { createSlice, type PayloadAction } from '@reduxjs/toolkit';
import type { NotificationCategory } from '../api/notificationMapper';
import { desktopNotifications } from '../utils/desktopNotifications.ts';

// Native OS notification settings for browser and Electron delivery.
//
// v1 scope: a single master enable toggle plus per-category toggles (chat,
// attention). Persistence uses localStorage directly (mirroring the shell's
// existing `heimdall:*` keys) so the setting survives reloads without new
// backend plumbing. Default is OFF until the user explicitly enables it from
// the Settings toggle (which is also the only place we request permission).

export type NotificationPermission = 'default' | 'granted' | 'denied' | 'unsupported';

export type NotificationCategoryPrefs = Record<NotificationCategory, boolean>;

export type NotificationsState = {
  // Master switch. Even when true, notifications only fire if permission is
  // 'granted' and the event passes the current-conversation focus policy.
  enabled: boolean;
  // Per-category opt-outs (both default on when the master switch is enabled).
  categories: NotificationCategoryPrefs;
  // Browser permission, or desktop API capability (OS policy is checked by the
  // native backend). Updated via explicit user gesture / feature detection.
  permission: NotificationPermission;
};

const STORAGE_KEY = 'heimdall:notifications:v1';

const DEFAULT_CATEGORIES: NotificationCategoryPrefs = { chat: true, attention: true };

function detectPermission(): NotificationPermission {
  try {
    if (typeof window !== 'undefined' && (window as any).odinApi) {
      return desktopNotifications()?.supported === true ? 'granted' : 'unsupported';
    }
    if (typeof window === 'undefined' || !('Notification' in window) || !window.Notification) {
      return 'unsupported';
    }
    const current = window.Notification.permission;
    if (current === 'granted' || current === 'denied' || current === 'default') return current;
    return 'default';
  } catch (_err) {
    return 'unsupported';
  }
}

function loadPersisted(): { enabled: boolean; categories: NotificationCategoryPrefs } {
  try {
    if (typeof window === 'undefined' || !window.localStorage) return { enabled: false, categories: { ...DEFAULT_CATEGORIES } };
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return { enabled: false, categories: { ...DEFAULT_CATEGORIES } };
    const parsed = JSON.parse(raw);
    const categories: NotificationCategoryPrefs = {
      chat: parsed?.categories?.chat !== false,
      attention: parsed?.categories?.attention !== false,
    };
    return { enabled: Boolean(parsed?.enabled), categories };
  } catch (_err) {
    return { enabled: false, categories: { ...DEFAULT_CATEGORIES } };
  }
}

function persist(state: NotificationsState) {
  try {
    if (typeof window === 'undefined' || !window.localStorage) return;
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify({ enabled: state.enabled, categories: state.categories }));
  } catch (_err) {
    /* ignore persistence errors (private mode, quota) */
  }
}

function buildInitialState(): NotificationsState {
  const persisted = loadPersisted();
  const permission = detectPermission();
  return {
    // Never leave the master switch "on" if we cannot actually notify.
    enabled: persisted.enabled && permission === 'granted',
    categories: persisted.categories,
    permission,
  };
}

const notificationsSlice = createSlice({
  name: 'notifications',
  initialState: buildInitialState(),
  reducers: {
    // Recompute permission from the live browser state (feature detect only —
    // no requestPermission side effect here).
    notificationPermissionRefreshed(state) {
      state.permission = detectPermission();
      if (state.permission !== 'granted' && state.enabled) {
        state.enabled = false;
        persist(state);
      }
    },
    // Set after an explicit user-gesture requestPermission() resolves.
    notificationPermissionSet(state, action: PayloadAction<NotificationPermission>) {
      state.permission = action.payload;
      if (action.payload !== 'granted' && state.enabled) {
        state.enabled = false;
        persist(state);
      }
    },
    notificationsEnabledSet(state, action: PayloadAction<boolean>) {
      // Only allow enabling when permission is granted; disabling is always ok.
      state.enabled = action.payload && state.permission === 'granted';
      persist(state);
    },
    notificationCategorySet(state, action: PayloadAction<{ category: NotificationCategory; enabled: boolean }>) {
      state.categories[action.payload.category] = action.payload.enabled;
      persist(state);
    },
  },
});

export const {
  notificationPermissionRefreshed,
  notificationPermissionSet,
  notificationsEnabledSet,
  notificationCategorySet,
} = notificationsSlice.actions;

// Selector helpers (kept tiny + framework-agnostic for reuse/testing).
export function selectNotificationsState(root: any): NotificationsState {
  return (root?.notifications as NotificationsState) || buildInitialState();
}

export function notificationsActive(state: NotificationsState): boolean {
  return Boolean(state?.enabled) && state?.permission === 'granted';
}

export function categoryEnabled(state: NotificationsState, category: NotificationCategory): boolean {
  return notificationsActive(state) && state.categories[category] !== false;
}

export default notificationsSlice.reducer;
