/**
 * T10 (REQ-T10-3): one classifier for "this bridge's vault is locked", shared by the
 * agent pane and shell panes so the two cannot drift apart.
 *
 * A locked bridge reaches the UI through four channels, and every one of them is
 * matched here:
 *
 *  - REST error bodies — the hub answers HTTP 423 `{error:{code:"vault_locked",
 *    details:{bridge_id}}}` for shell start/restart and REST keystrokes.
 *  - Pane stream error frames — `{type:"error", code:"vault_locked", bridge_id, ...}`,
 *    relayed by the hub from the bridge's typed `shell_pty_vault_locked` signal.
 *  - User-WS events — a refused shell start publishes `shell_session_exited` with
 *    `error_code:"vault_locked"`.
 *  - Stream close reasons — a socket closed with reason `vault_locked`.
 *
 * Older hubs only carried the reason inside a free-text message ("unauthorized: vault
 * locked"); `isBridgeVaultLockedError` keeps matching that so a mixed-version fleet
 * still renders the overlay.
 *
 * Pure (no React/Redux) so `node --test` can import it directly.
 */

import { isBridgeVaultLockedError, type BridgeVaultStatus } from './bridgeVaultStatus.ts';

/** The stable wire code the bridge and hub use for a locked vault. */
export const VAULT_LOCKED_CODE = 'vault_locked';

/** HTTP status the hub answers a vault_locked refusal with (RFC 4918 Locked). */
export const VAULT_LOCKED_HTTP_STATUS = 423;

/**
 * REQ-T10-4: every surface that reports a locked bridge opens with the same sentence
 * (the hub's 423 message does too: domain.VAULT_LOCKED_MESSAGE), and only the second
 * sentence says what is blocked where.
 */
export const VAULT_LOCKED_HEADLINE = "This bridge's vault is locked.";

/** The pane overlay's wording (REQ-T10-3). */
export const VAULT_LOCKED_OVERLAY_MESSAGE = `${VAULT_LOCKED_HEADLINE} Input is disabled until it is unsealed.`;

/** New-shell / restart refusal (T9's dialog copy). */
export const VAULT_LOCKED_SHELL_START_MESSAGE = `${VAULT_LOCKED_HEADLINE} Unseal it from bridge settings to run commands.`;

/** Settings -> User Vault row description for a Locked bridge. */
export const VAULT_LOCKED_SETTINGS_DESCRIPTION = `${VAULT_LOCKED_HEADLINE} Unseal it to resume encrypted file and terminal access.`;

/** Label of the overlay's primary action. */
export const VAULT_LOCKED_UNLOCK_LABEL = 'Unlock vault';

function codeIsLocked(value: unknown): boolean {
  return typeof value === 'string' && value.trim().toLowerCase() === VAULT_LOCKED_CODE;
}

/**
 * True when `input` — an RTK Query / fetch error, a parsed pane stream frame, a
 * user-WS event, a CloseEvent (or anything with a `reason`), an Error, or a bare
 * string — says the bridge's vault is locked.
 */
export function isVaultLockedError(input: unknown): boolean {
  if (input == null) return false;
  if (typeof input === 'string') return codeIsLocked(input) || /vault[_ ]locked/i.test(input);

  const e = input as any;
  // Pane stream frame {type:"error", code} and user-WS event {error_code}.
  if (codeIsLocked(e.code) || codeIsLocked(e.error_code)) return true;
  // REST: RTK Query wraps the body as `data`; a raw body has `error` at the top.
  if (codeIsLocked(e?.data?.error?.code) || codeIsLocked(e?.error?.code)) return true;
  // Stream close reason.
  if (codeIsLocked(e.reason)) return true;
  // A 423 is only ever sent for a locked vault.
  if (e.status === VAULT_LOCKED_HTTP_STATUS || e.originalStatus === VAULT_LOCKED_HTTP_STATUS) return true;
  // Legacy free-text reasons ("unauthorized: vault locked").
  return isBridgeVaultLockedError(input);
}

/** The bridge a vault_locked signal names, when it names one. */
export function vaultLockedBridgeId(input: unknown): string | undefined {
  if (input == null || typeof input !== 'object') return undefined;
  const e = input as any;
  const candidate =
    e.bridge_id ??
    e?.data?.error?.details?.bridge_id ??
    e?.error?.details?.bridge_id ??
    e?.details?.bridge_id;
  return typeof candidate === 'string' && candidate.trim() !== '' ? candidate : undefined;
}

/**
 * Window event that routes a vault_locked signal to the pane showing that session
 * when it arrived somewhere other than the pane's own socket: a REST keystroke or
 * restart answered 423, or the user-WS `shell_session_exited` of a refused start.
 */
export const PANE_VAULT_LOCKED_EVENT = 'heimdall:pane-vault-locked';

export interface PaneVaultLockedDetail {
  /** Shell session id, or the agent instance id for an agent pane. */
  session_id: string;
  bridge_id?: string;
  code: typeof VAULT_LOCKED_CODE;
}

/** The event detail for `signal` about `sessionId`, or null when it is not vault_locked. */
export function paneVaultLockedDetail(sessionId: string | null | undefined, signal: unknown): PaneVaultLockedDetail | null {
  if (!sessionId || !isVaultLockedError(signal)) return null;
  const detail: PaneVaultLockedDetail = { session_id: sessionId, code: VAULT_LOCKED_CODE };
  const bridgeId = vaultLockedBridgeId(signal);
  if (bridgeId) detail.bridge_id = bridgeId;
  return detail;
}

/** Announces a vault_locked signal for a pane session. Returns true when it was one. */
export function announcePaneVaultLocked(sessionId: string | null | undefined, signal: unknown): boolean {
  const detail = paneVaultLockedDetail(sessionId, signal);
  if (!detail) return false;
  if (typeof window !== 'undefined' && typeof CustomEvent !== 'undefined') {
    window.dispatchEvent(new CustomEvent<PaneVaultLockedDetail>(PANE_VAULT_LOCKED_EVENT, { detail }));
  }
  return true;
}

function isOpenStatus(status: BridgeVaultStatus | undefined): boolean {
  return status === 'Unlocked' || status === 'NotConfigured';
}

/**
 * Pane lock state. `awaitingTransition` covers a race: a vault_locked signal can
 * arrive before the bridges list has heard the bridge report Locked, while the row
 * still says Unlocked. That stale "open" row must not hide the overlay; only a row
 * seen Locked and THEN open again (or the operator completing an unseal) clears it.
 */
export interface PaneVaultLockState {
  signalled: boolean;
  awaitingTransition: boolean;
}

export const PANE_VAULT_LOCK_INITIAL: PaneVaultLockState = { signalled: false, awaitingTransition: false };

export type PaneVaultLockEvent =
  /** A vault_locked start error, stream frame, refused input or event arrived. */
  | { type: 'signal'; bridgeStatus: BridgeVaultStatus | undefined }
  /** The bridge row's status changed. */
  | { type: 'status'; bridgeStatus: BridgeVaultStatus | undefined }
  /** The operator completed an unseal from the overlay. */
  | { type: 'unsealed' }
  /** New pane target, or the stream resumed. */
  | { type: 'reset' };

export function reducePaneVaultLock(state: PaneVaultLockState, event: PaneVaultLockEvent): PaneVaultLockState {
  switch (event.type) {
    case 'signal':
      // An unknown row at signal time (bridge id only just learned) is treated like a
      // stale open one: only a row seen Locked, or a completed unseal, may clear it.
      return { signalled: true, awaitingTransition: event.bridgeStatus === undefined || isOpenStatus(event.bridgeStatus) };
    case 'status':
      if (state.signalled && state.awaitingTransition && event.bridgeStatus === 'Locked') {
        return { signalled: true, awaitingTransition: false };
      }
      return state;
    case 'unsealed':
    case 'reset':
      return PANE_VAULT_LOCK_INITIAL;
  }
}

/**
 * Whether the pane shows the locked overlay (and refuses input).
 *
 *  - The bridge row reporting Locked is enough on its own: a pane opened on an
 *    already-locked bridge, or a late joiner that missed the one-shot frame.
 *  - A signal keeps the overlay up until the row reports the vault open again
 *    (Unlocked, or encryption no longer configured). Unknown / NotRunning / a missing
 *    row cannot clear it — none of them says the key is back.
 */
export function isPaneVaultLocked(state: PaneVaultLockState, bridgeStatus: BridgeVaultStatus | undefined): boolean {
  if (bridgeStatus === 'Locked') return true;
  if (!state.signalled) return false;
  if (isOpenStatus(bridgeStatus)) return state.awaitingTransition;
  return true;
}

/**
 * True exactly on the transition out of the locked overlay — the moment the pane
 * should retry its stream start / re-attach so input resumes without a reload.
 */
export function shouldResumeAfterUnseal(wasLocked: boolean, isLocked: boolean): boolean {
  return wasLocked && !isLocked;
}
