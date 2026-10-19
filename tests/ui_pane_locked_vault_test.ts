// T10 (REQ-T10-3/4): a pane on a LOCKED bridge shows one shared overlay with an
// "Unlock vault" button, refuses input, and resumes after the unseal. The pure state
// lives in src/ui/utils/vaultLockedError.ts; the React wiring is pinned as source text
// (a .tsx component cannot be rendered under node --test in this repo).
//
// RUN: node --test tests/ui_pane_locked_vault_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  PANE_VAULT_LOCK_INITIAL,
  VAULT_LOCKED_HEADLINE,
  VAULT_LOCKED_OVERLAY_MESSAGE,
  VAULT_LOCKED_SETTINGS_DESCRIPTION,
  VAULT_LOCKED_SHELL_START_MESSAGE,
  VAULT_LOCKED_UNLOCK_LABEL,
  isPaneVaultLocked,
  isVaultLockedError,
  paneVaultLockedDetail,
  reducePaneVaultLock,
  shouldResumeAfterUnseal,
  vaultLockedBridgeId,
  type PaneVaultLockState,
} from '../src/ui/utils/vaultLockedError.ts';
import { isBridgeVaultLockedError } from '../src/ui/utils/bridgeVaultStatus.ts';

// ---------------------------------------------------------------------------
// Classifier: every channel a locked bridge reaches the UI through.
// ---------------------------------------------------------------------------

test('REST: the hub 423 body is vault_locked and names the bridge', () => {
  const rtk = { status: 423, data: { error: { code: 'vault_locked', message: "This bridge's vault is locked. Unseal it to continue.", details: { bridge_id: 'brg_1' } } } };
  assert.equal(isVaultLockedError(rtk), true);
  assert.equal(vaultLockedBridgeId(rtk), 'brg_1');
  assert.equal(isBridgeVaultLockedError(rtk), true, 'T9 dialog helper also recognises the typed 423');
});

test('REST: a queryFn CUSTOM_ERROR that kept code/originalStatus is vault_locked', () => {
  const custom = { status: 'CUSTOM_ERROR', error: "This bridge's vault is locked. Unseal it to continue.", code: 'vault_locked', originalStatus: 423 };
  assert.equal(isVaultLockedError(custom), true);
  assert.equal(isBridgeVaultLockedError(custom), true, 'NewShellDialog keeps working against the new hub message');
  assert.equal(isVaultLockedError({ status: 'CUSTOM_ERROR', error: 'x', originalStatus: 423 }), true);
});

test('stream: the typed error frame relayed by the hub', () => {
  const frame = { type: 'error', code: 'vault_locked', bridge_id: 'brg_2', session_id: 'inst_1', message: '...' };
  assert.equal(isVaultLockedError(frame), true);
  assert.equal(vaultLockedBridgeId(frame), 'brg_2');
});

test('user-WS: the refused-start exit event', () => {
  const evt = { type: 'shell_session_exited', session_id: 'sh_1', status: 'failed', error_code: 'vault_locked', bridge_id: 'brg_3' };
  assert.equal(isVaultLockedError(evt), true);
  assert.equal(vaultLockedBridgeId(evt), 'brg_3');
  assert.equal(isVaultLockedError({ type: 'shell_session_exited', session_id: 'sh_1', status: 'exited', exit_code: 0 }), false);
});

test('stream close reason', () => {
  assert.equal(isVaultLockedError({ code: 1008, reason: 'vault_locked' }), true);
  assert.equal(isVaultLockedError({ code: 4007, reason: 'invalid pane payload' }), false);
});

test('legacy free-text reasons from older hubs', () => {
  assert.equal(isVaultLockedError({ status: 500, data: { error: { message: 'bridge failed to start shell session: unauthorized: vault locked' } } }), true);
  assert.equal(isVaultLockedError('vault_locked'), true);
});

test('other failures are never mistaken for a locked vault', () => {
  assert.equal(isVaultLockedError(undefined), false);
  assert.equal(isVaultLockedError(null), false);
  assert.equal(isVaultLockedError({ type: 'error', message: 'Shell stream connection error' }), false);
  assert.equal(isVaultLockedError({ status: 500, data: { error: { code: 'internal_error', message: 'boom' } } }), false);
  assert.equal(isVaultLockedError({ status: 'CUSTOM_ERROR', error: 'unauthorized: missing or invalid vault enc_spec', code: 'internal_error', originalStatus: 500 }), false);
  assert.equal(isVaultLockedError({ status: 'FETCH_ERROR', error: 'TypeError: Failed to fetch' }), false);
  assert.equal(vaultLockedBridgeId({ type: 'error', code: 'vault_locked' }), undefined);
});

test('paneVaultLockedDetail routes only vault_locked signals with a session', () => {
  assert.deepEqual(paneVaultLockedDetail('sh_1', { code: 'vault_locked', bridge_id: 'brg_9' }), { session_id: 'sh_1', code: 'vault_locked', bridge_id: 'brg_9' });
  assert.equal(paneVaultLockedDetail('', { code: 'vault_locked' }), null);
  assert.equal(paneVaultLockedDetail('sh_1', { code: 'internal_error' }), null);
});

// ---------------------------------------------------------------------------
// Pane lock state.
// ---------------------------------------------------------------------------

const after = (...events: Parameters<typeof reducePaneVaultLock>[1][]): PaneVaultLockState =>
  events.reduce(reducePaneVaultLock, PANE_VAULT_LOCK_INITIAL);

test('a bridge row reporting Locked locks the pane on its own (late joiner / opened while locked)', () => {
  assert.equal(isPaneVaultLocked(PANE_VAULT_LOCK_INITIAL, 'Locked'), true);
  for (const s of ['Unlocked', 'NotRunning', 'Unknown', undefined] as const) {
    assert.equal(isPaneVaultLocked(PANE_VAULT_LOCK_INITIAL, s), false, `no signal + ${s}`);
  }
});

test('a signal on a Locked row stays locked until the row reports the vault open', () => {
  const st = after({ type: 'signal', bridgeStatus: 'Locked' });
  assert.equal(isPaneVaultLocked(st, 'Locked'), true);
  assert.equal(isPaneVaultLocked(st, 'NotRunning'), true, 'offline says nothing about the key');
  assert.equal(isPaneVaultLocked(st, 'Unknown'), true);
  assert.equal(isPaneVaultLocked(st, 'Unlocked'), false, 'unsealed -> overlay clears');
});

test('race: a signal before the row hears Locked is not hidden by the stale Unlocked row', () => {
  let st = after({ type: 'signal', bridgeStatus: 'Unlocked' });
  assert.equal(isPaneVaultLocked(st, 'Unlocked'), true, 'stale open row must not clear a fresh signal');
  st = reducePaneVaultLock(st, { type: 'status', bridgeStatus: 'Locked' });
  assert.equal(isPaneVaultLocked(st, 'Locked'), true);
  st = reducePaneVaultLock(st, { type: 'status', bridgeStatus: 'Unlocked' });
  assert.equal(isPaneVaultLocked(st, 'Unlocked'), false, 'seen Locked, then open -> clears');
});

test('a signal with no known row yet behaves like the stale-open race', () => {
  const st = after({ type: 'signal', bridgeStatus: undefined });
  assert.equal(isPaneVaultLocked(st, undefined), true);
  assert.equal(isPaneVaultLocked(st, 'Unlocked'), true);
});

test('completing the unseal from the overlay clears the signal', () => {
  const st = after({ type: 'signal', bridgeStatus: 'Unlocked' }, { type: 'unsealed' });
  assert.equal(isPaneVaultLocked(st, 'Unlocked'), false);
  assert.equal(isPaneVaultLocked(st, 'Locked'), true, 'the row still wins until the bridge reports');
});

test('resume fires only on the locked -> unlocked edge', () => {
  assert.equal(shouldResumeAfterUnseal(true, false), true);
  assert.equal(shouldResumeAfterUnseal(false, false), false);
  assert.equal(shouldResumeAfterUnseal(true, true), false);
  assert.equal(shouldResumeAfterUnseal(false, true), false);
});

// ---------------------------------------------------------------------------
// REQ-T10-4: one wording.
// ---------------------------------------------------------------------------

test('every locked surface opens with the same headline, including the hub 423 message', () => {
  assert.equal(VAULT_LOCKED_OVERLAY_MESSAGE, "This bridge's vault is locked. Input is disabled until it is unsealed.");
  assert.equal(VAULT_LOCKED_UNLOCK_LABEL, 'Unlock vault');
  for (const m of [VAULT_LOCKED_OVERLAY_MESSAGE, VAULT_LOCKED_SHELL_START_MESSAGE, VAULT_LOCKED_SETTINGS_DESCRIPTION]) {
    assert.ok(m.startsWith(VAULT_LOCKED_HEADLINE), m);
  }
});

