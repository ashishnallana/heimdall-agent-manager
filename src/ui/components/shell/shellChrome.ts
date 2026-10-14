/**
 * Fixed window chrome (Jetski web): the sidebar toggle + app name live in a
 * FIXED top-left cluster that never moves when the sidebar opens or closes;
 * the side-panel toggle lives in a FIXED top-right cluster that stays in the
 * window's top-right even when the aux dock is open. Content under a cluster
 * reserves its space instead of being overlapped.
 */

/** Width of the fixed top-left cluster (toggle + "Heimdall"), px. */
export const TOP_LEFT_CLUSTER_WIDTH = 132;

/** Height of the top chrome row (matches the chat header / aux tab strip), px. */
export const TOP_CHROME_HEIGHT = 48;

/** Pane / dock / sidebar open-close animation duration, ms. */
export const PANE_ANIMATION_MS = 180;
