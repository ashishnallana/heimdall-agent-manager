// Thin, side-effectful native notification service.
//
// Owns browser delivery and the desktop preload bridge, permission, visibility,
// and focus. The notify-vs-skip policy and content live in the pure
// notificationForWsEvent mapper; this service just gates and renders.
//
// Wiring: fireNotificationForWsEvent is called from the single handleUserWsEvent
// funnel (wsInvalidation.ts) for every user-WS event. It early-returns unless
// notifications are enabled + permission granted, and then applies the focus
// policy: when the window is NOT focused it always notifies; when it IS focused
// it notifies only for a thread other than the one currently open on screen.

import { buildRouteHash, getRoutePathname, getRouteSearch } from '../utils/appLocation.ts';
import { NEW_PANE_URL_ID, parseConversationIdsFromRoute } from '../utils/conversationUrl.ts';
import { chainIdFromTargetId } from '../utils/paneTarget.ts';
import { heimdallApi } from '../api/heimdallApi.ts';
import { notificationForWsEvent, type NotificationMapperCtx, type NotificationPlan } from '../api/notificationMapper.ts';
import {
  categoryEnabled,
  notificationsActive,
  selectNotificationsState,
  type NotificationPermission,
} from '../store/notificationsSlice.ts';
import {
  isVaultArmored,
  containsVaultArmored,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
} from '../utils/vaultContent.ts';
import { selectIsVaultUnlocked, getActiveVaultKey } from '../store/vaultSlice.ts';
import { desktopNotifications } from '../utils/desktopNotifications.ts';
import { desktopCapabilities } from '../bridge/desktopBridge.ts';

export function isNotificationSupported(): boolean {
  try {
    if (typeof window === 'undefined') return false;
    if (isElectronRuntime()) return desktopNotifications()?.supported === true;
    // Supported if EITHER the in-page Notification constructor exists OR the
    // service-worker path is available (iOS PWAs expose only the latter).
    const hasConstructor = 'Notification' in window && Boolean(window.Notification);
    const hasSW = 'serviceWorker' in navigator && 'Notification' in window;
    return hasConstructor || hasSW;
  } catch (_err) {
    return false;
  }
}

// A service worker is REQUIRED for notifications on iOS Safari PWAs and is the
// preferred path everywhere else (it survives tab-close for the click handler
// and is the only future-proof route to Web Push). We register lazily and cache
// the registration. Registration needs a secure context (HTTPS or localhost);
// under Electron (file://) it is skipped — Electron uses its own notifications.
let swRegistrationPromise: Promise<ServiceWorkerRegistration | null> | null = null;
const NOTIFICATION_SW_URL = 'notification-sw.js';

export function registerNotificationServiceWorker(): Promise<ServiceWorkerRegistration | null> {
  if (swRegistrationPromise) return swRegistrationPromise;
  swRegistrationPromise = (async () => {
    try {
      if (typeof window === 'undefined' || isElectronRuntime()) return null;
      if (!('serviceWorker' in navigator)) return null;
      if (!window.isSecureContext) return null;
      // Resolve the SW url against the app base so it works under Vite `base:./`
      // and when served from a sub-path.
      const base = (import.meta as any)?.env?.BASE_URL || '/';
      const url = new URL(NOTIFICATION_SW_URL, new URL(base, window.location.href)).toString();
      const existing = await navigator.serviceWorker.getRegistration();
      const reg = existing || (await navigator.serviceWorker.register(url));
      // Ensure the page listens for click hand-offs from the SW exactly once.
      installServiceWorkerMessageListener();
      return reg || null;
    } catch (_err) {
      return null;
    }
  })();
  return swRegistrationPromise;
}

let swMessageListenerInstalled = false;
function installServiceWorkerMessageListener() {
  if (swMessageListenerInstalled) return;
  if (typeof navigator === 'undefined' || !('serviceWorker' in navigator)) return;
  try {
    navigator.serviceWorker.addEventListener('message', (event: MessageEvent) => {
      const data = (event && event.data) || {};
      if (data && data.type === 'heimdall-notification-click' && data.route) {
        focusAndRoute(String(data.route));
      }
    });
    swMessageListenerInstalled = true;
  } catch (_err) {
    /* ignore */
  }
}

async function activeNotificationRegistration(): Promise<ServiceWorkerRegistration | null> {
  try {
    const reg = await registerNotificationServiceWorker();
    if (!reg) return null;
    // showNotification needs an active worker; wait briefly if it's still
    // installing/waiting (first load), but never block forever.
    if (reg.active) return reg;
    await navigator.serviceWorker.ready.catch(() => null);
    const ready = await navigator.serviceWorker.getRegistration().catch(() => null);
    return (ready && ready.active) ? ready : (reg.active ? reg : null);
  } catch (_err) {
    return null;
  }
}

// Electron uses the same notification policy, with main-process delivery via
// preload IPC instead of the browser/service-worker API.
export function isElectronRuntime(): boolean {
  return desktopCapabilities().desktop;
}

// True when the tab is OPEN but NOT focused (hidden behind another tab, or the
// browser window is behind another app). When focused we may still notify — but
// only for a conversation other than the one on screen (see isViewingPlanThread).
export function isTabBackgrounded(): boolean {
  try {
    if (typeof document === 'undefined') return false;
    if (document.visibilityState && document.visibilityState !== 'visible') return true;
    if (typeof document.hasFocus === 'function' && !document.hasFocus()) return true;
    return false;
  } catch (_err) {
    return false;
  }
}

// Request permission ONLY from an explicit user gesture (the Settings toggle).
// Never called on page load. Returns the resulting permission (or 'unsupported'
// / 'denied' on failure) and never throws or logs to the console.
export async function requestNotificationPermission(): Promise<NotificationPermission> {
  if (!isNotificationSupported()) return 'unsupported';
  if (isElectronRuntime()) return 'granted';
  try {
    const result = await window.Notification.requestPermission();
    if (result === 'granted' || result === 'denied' || result === 'default') return result;
    return 'default';
  } catch (_err) {
    return 'denied';
  }
}

function iconUrl(): string | undefined {
  try {
    // Reuse the app favicon/logo if present; undefined is a valid Notification
    // icon (the browser falls back to its own default).
    if (typeof document === 'undefined') return undefined;
    const link = document.querySelector('link[rel="icon"], link[rel="shortcut icon"]') as HTMLLinkElement | null;
    return link?.href || undefined;
  } catch (_err) {
    return undefined;
  }
}

// Absolute URL for the given in-app hash route, anchored at the current
// document (index.html). Used both for same-window navigation and as the
// new-window fallback target so the deep-link resolves identically.
function routeToHref(route: string): string {
  const hash = buildRouteHash(route, '');
  try {
    if (typeof window !== 'undefined' && window.location) {
      const base = `${window.location.origin}${window.location.pathname}${window.location.search}`;
      return `${base}${hash}`;
    }
  } catch (_err) {
    /* fall through */
  }
  return hash;
}

// Focus the existing Heimdall window and route it to the target chat/chain/task.
// If focusing the existing window isn't possible (e.g. the tab was closed, or
// the browser blocks refocus), fall back to opening the deep-link in a new
// window so the click still lands on the correct conversation (REQ-N4).
function focusAndRoute(route: string) {
  if (typeof window === 'undefined' || !route) return;

  // The notification was raised BY this window, so this window still exists.
  // Navigate it in place FIRST and ask the OS to bring it forward. We must not
  // gate on window.focus() succeeding: from a backgrounded tab focus() is often
  // silently blocked, and gating on document.hasFocus() there would wrongly
  // fall through to window.open() and spawn a duplicate tab (REQ-N4). In-place
  // hash navigation always lands on the correct conversation in the SAME tab.
  try {
    window.location.hash = buildRouteHash(route, '');
    try { window.focus(); } catch (_err) { /* focus may be blocked; navigation already applied */ }
    return;
  } catch (_err) {
    /* fall through to new-window fallback only if in-place nav actually threw */
  }

  // In-place navigation threw (very unusual) — open the deep-link in a named
  // window so repeated clicks reuse the same one instead of stacking tabs.
  try {
    const opened = window.open(routeToHref(route), 'heimdall');
    if (opened) {
      try { opened.focus(); } catch (_err) { /* ignore */ }
    }
  } catch (_err) {
    /* ignore */
  }
}

// Low-level: actually show the OS notification for a resolved plan. Resolves to
// true if a notification was created. No gating here — callers gate first.
//
// Prefers the service-worker path (reg.showNotification) — required on iOS
// Safari PWAs and preferred elsewhere — and falls back to the in-page
// Notification constructor when no active SW is available (e.g. insecure dev
// context or a browser without SW support). The two paths route clicks
// differently: the SW path via `notificationclick` -> postMessage -> the page's
// message listener; the constructor path via the in-page `onclick` below.
export async function showNativeNotification(plan: NotificationPlan): Promise<boolean> {
  if (isElectronRuntime()) {
    try {
      const desktop = desktopNotifications();
      if (!desktop?.supported) return false;
      return await desktop.show({ title: plan.title, body: plan.body, tag: plan.tag, route: plan.route });
    } catch { return false; }
  }
  if (typeof window === 'undefined' || !('Notification' in window)) return false;

  const icon = iconUrl();
  const data = { route: plan.route, href: routeToHref(plan.route) };

  // 1) Service-worker path (preferred; only path on iOS PWAs).
  try {
    const reg = await activeNotificationRegistration();
    if (reg) {
      await reg.showNotification(plan.title, {
        body: plan.body,
        tag: plan.tag,
        icon,
        renotify: true,
        data,
      } as NotificationOptions);
      return true;
    }
  } catch (_err) {
    /* fall through to the constructor path */
  }

  // 2) In-page constructor fallback.
  try {
    const notification = new window.Notification(plan.title, {
      body: plan.body,
      tag: plan.tag,
      icon,
      // renotify keeps a fresh alert when a burst collapses onto the same tag.
      renotify: true,
      data,
    } as NotificationOptions);
    notification.onclick = () => {
      focusAndRoute(plan.route);
      try {
        notification.close();
      } catch (_err) {
        /* ignore */
      }
    };
    return true;
  } catch (_err) {
    // Some browsers throw when constructing Notification directly (e.g. require
    // a ServiceWorkerRegistration). Fail silently — no console noise (REQ-N3).
    return false;
  }
}

// The conversations/threads the user is actively viewing, derived from the live
// hash route and, when supplied, an explicit ctx override. Empty when no
// conversation is open (e.g. a board, settings, or the new-conversation
// composer) — in which case we never suppress. The route holds one pane target
// per visible Main pane ('/conversations/<target>+<target>?focused=<target>'):
// an agent_instance_id, or `chain:<chain_id>` for a chain's coordinator pane
// (REQ-TV2-7). A chain target counts as its RESOLVED coordinator instance and
// conversation (read from the pane's own fetchTaskChainConversation cache), never
// the bare chain id: a plan's chainId key is also set for workers' messages in
// that chain, which are not on screen. An unresolved chain pane suppresses
// nothing. A conversation_id may arrive via the ctx override, so both are kept.
function openConversationKeys(ctx: NotificationMapperCtx, state?: any): string[] {
  const keys: string[] = [];
  try {
    if (ctx && ctx.visibleConversationId) keys.push(String(ctx.visibleConversationId));
    const { ids } = parseConversationIdsFromRoute(getRoutePathname(), getRouteSearch());
    for (const id of ids) {
      const chainId = chainIdFromTargetId(id);
      if (chainId) keys.push(...resolvedChainConversationKeys(state, chainId));
      else if (id !== NEW_PANE_URL_ID) keys.push(id);
    }
  } catch (_err) {
    /* treat as "no conversation open" -> never suppress */
  }
  return keys.filter(Boolean);
}

// The coordinator instance + conversation a `chain:<id>` pane currently shows,
// taken from the RTK Query cache entry that ChainCoordinatorPane subscribes to.
function resolvedChainConversationKeys(state: any, chainId: string): string[] {
  const queries = state?.[heimdallApi.reducerPath]?.queries || {};
  for (const entry of Object.values(queries) as any[]) {
    if (entry?.endpointName !== 'fetchTaskChainConversation') continue;
    if (String(entry?.originalArgs?.chainId || '') !== chainId) continue;
    const data = entry?.data;
    return [String(data?.coordinatorAgentInstanceId || ''), String(data?.conversationId || '')].filter(Boolean);
  }
  return [];
}

// Extract the trailing id from a '/conversations/<id>' or '/chains/<id>' route,
// used as a fallback identity when a plan carries no explicit conversationKeys.
function routeThreadId(route: string): string {
  try {
    const parts = String(route || '').split('?')[0].split('/').filter(Boolean);
    return parts.length >= 2 ? decodeURIComponent(parts[1]) : '';
  } catch (_err) {
    return '';
  }
}

// True when the event targets the exact conversation currently on screen, so a
// focused user is already looking at it and an OS popup would be redundant.
function isViewingPlanThread(plan: NotificationPlan, ctx: NotificationMapperCtx, state?: any): boolean {
  const open = openConversationKeys(ctx, state);
  if (open.length === 0) return false;
  const target = (plan.conversationKeys && plan.conversationKeys.length)
    ? plan.conversationKeys
    : [routeThreadId(plan.route)];
  return target.some((k) => Boolean(k) && open.includes(k));
}

function truncateNotificationText(text: string, max = 140): string {
  const trimmed = text.replace(/\s+/g, ' ').trim();
  if (trimmed.length <= max) return trimmed;
  return `${trimmed.slice(0, max - 1)}…`;
}

// Entry point wired into handleUserWsEvent. `getState` is the redux store's
// getState (dependency-injected to avoid a circular store import). Returns the
// plan that fired (for tests/telemetry) or null when skipped.
export function fireNotificationForWsEvent(
  getState: () => any,
  payload: any,
  ctx: NotificationMapperCtx = {},
): NotificationPlan | null {
  if (!isNotificationSupported()) return null;

  let settings;
  try {
    settings = selectNotificationsState(getState());
  } catch (_err) {
    return null;
  }
  if (!notificationsActive(settings)) return null;

  const plan = notificationForWsEvent(payload, ctx);
  if (!plan) return null;
  // Per-category opt-out.
  if (!categoryEnabled(settings, plan.category)) return null;

  // Focus/visibility policy:
  // - Window NOT focused (behind another app) or tab hidden: ALWAYS notify.
  // - Window focused: notify UNLESS the event targets the conversation the user
  //   is currently viewing — they can already see it (REQ-N2).
  const rawState = typeof getState === 'function' ? getState() : undefined;
  if (!isTabBackgrounded() && isViewingPlanThread(plan, ctx, rawState)) return null;

  const isUnlocked = rawState ? Boolean(selectIsVaultUnlocked(rawState)) : false;
  const activeKey = getActiveVaultKey();

  const hasArmoredBody = isVaultArmored(plan.body) || containsVaultArmored(plan.body);
  const hasArmoredTitle = isVaultArmored(plan.title) || containsVaultArmored(plan.title);

  if (hasArmoredBody || hasArmoredTitle) {
    if (activeKey || isUnlocked) {
      // Fire-and-forget: asynchronously decrypt before invoking showNativeNotification
      void (async () => {
        try {
          if (hasArmoredBody) {
            plan.body = isVaultArmored(plan.body)
              ? await decryptVaultText(plan.body, activeKey)
              : await decryptEmbeddedVaultTokens(plan.body, activeKey);
          }
          if (hasArmoredTitle) {
            plan.title = isVaultArmored(plan.title)
              ? await decryptVaultText(plan.title, activeKey)
              : await decryptEmbeddedVaultTokens(plan.title, activeKey);
          }
          plan.title = truncateNotificationText(plan.title);
          plan.body = truncateNotificationText(plan.body);
        } catch {
          if (hasArmoredBody) {
            plan.body = plan.category === 'attention' ? '[🔒 Encrypted action]' : '[🔒 Encrypted message]';
          }
          if (hasArmoredTitle) {
            plan.title = '[🔒 Encrypted]';
          }
        }
        await showNativeNotification(plan);
      })();
      return plan;
    } else {
      // Vault locked or key unavailable: sanitize to shield OS notification center
      if (hasArmoredBody) {
        plan.body = plan.category === 'attention' ? '[🔒 Encrypted action]' : '[🔒 Encrypted message]';
      }
      if (hasArmoredTitle) {
        plan.title = '[🔒 Encrypted]';
      }
      void showNativeNotification(plan);
      return plan;
    }
  }

  // Fire-and-forget: showing is async (service-worker path), but the WS funnel is
  // synchronous and only uses the returned plan for tests/telemetry.
  void showNativeNotification(plan);
  return plan;
}
