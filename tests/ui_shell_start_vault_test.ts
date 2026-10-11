// T9 (REQ-T9-2): a locked bridge's shell refusal must be recognisable in the UI.
//
// RUN: node --test tests/ui_shell_start_vault_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { describeApiError, isBridgeVaultLockedError } from '../src/ui/utils/bridgeVaultStatus.ts';

test('hub-forwarded locked refusal is recognised', () => {
  const err = { status: 500, data: { error: { message: 'bridge failed to start shell session: unauthorized: vault locked' } } };
  assert.equal(isBridgeVaultLockedError(err), true);
  assert.equal(describeApiError(err), 'bridge failed to start shell session: unauthorized: vault locked');
});

test('stable error code spelling is recognised', () => {
  assert.equal(isBridgeVaultLockedError({ data: { error: { message: 'vault_locked' } } }), true);
});

test('other failures are not mistaken for a locked vault', () => {
  assert.equal(isBridgeVaultLockedError({ data: { error: { message: 'unauthorized: invalid vault encryption' } } }), false);
  assert.equal(isBridgeVaultLockedError({ status: 'FETCH_ERROR', error: 'TypeError: Failed to fetch' }), false);
  assert.equal(isBridgeVaultLockedError(undefined), false);
  assert.equal(describeApiError({ data: { error: { code: 'x' } } }), '');
});
