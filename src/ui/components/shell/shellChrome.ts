/**
 * Fixed window chrome (Jetski web): the sidebar toggle + app name live in a
 * FIXED top-left cluster that never moves when the sidebar opens or closes;
 * the side-panel toggle lives in a FIXED top-right cluster that stays in the
 * window's top-right even when the aux dock is open. Content under a cluster
 * reserves its space instead of being overlapped.
 */

/** Width of the fixed top-left cluster (toggle + "Heimdall"), px. */
export const TOP_LEFT_CLUSTER_WIDTH = 132;

/**
 * Controls-only cluster: the sidebar button plus horizontal padding. The vault
 * toggle lives in the bottom status bar (REQ-BAR-3), not here.
 */
export const COMPACT_TOP_LEFT_CLUSTER_WIDTH = 48;

/** Agent conversations trade the wordmark for horizontal workspace chrome. */
export function isAgentConversationRoute(path: string): boolean {
  return (path.startsWith('/conversations/') && path !== '/conversations/new') || path.startsWith('/c/');
}

/** Height of the top chrome row (matches the chat header / aux tab strip), px. */
export const TOP_CHROME_HEIGHT = 48;

/**
 * Mobile (<=767px) chrome: the cluster button is a 44px round touch target
 * (TOUCH_TARGET_CLASS floor), so the row grows to 56px and the compact cluster is
 * one 44px button + 8px padding each side (+ 4px gap + wordmark with the brand).
 */
export const MOBILE_TOP_CHROME_HEIGHT = 56;
export const MOBILE_COMPACT_TOP_LEFT_CLUSTER_WIDTH = 60;
export const MOBILE_TOP_LEFT_CLUSTER_WIDTH = 144;

export function topChromeHeight(isMobile: boolean): number {
  return isMobile ? MOBILE_TOP_CHROME_HEIGHT : TOP_CHROME_HEIGHT;
}

export function topLeftClusterWidth(isMobile: boolean, showBrand: boolean): number {
  if (isMobile) return showBrand ? MOBILE_TOP_LEFT_CLUSTER_WIDTH : MOBILE_COMPACT_TOP_LEFT_CLUSTER_WIDTH;
  return showBrand ? TOP_LEFT_CLUSTER_WIDTH : COMPACT_TOP_LEFT_CLUSTER_WIDTH;
}

/** Window-chrome icon button: 32px rounded square on desktop, 44px circle on mobile. */
export function chromeIconButtonSizeClass(isMobile: boolean): string {
  return isMobile ? 'h-11 w-11 rounded-full' : 'h-8 w-8 rounded-lg';
}

/** Pane / dock / sidebar open-close animation duration, ms. */
export const PANE_ANIMATION_MS = 180;
