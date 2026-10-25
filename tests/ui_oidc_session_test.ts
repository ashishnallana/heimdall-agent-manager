// Browser OIDC sign-in helpers (docs/plans/oidc-only-auth.md, phase 4).
//
// RUN: node --test tests/ui_oidc_session_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  LOGIN_REDIRECT_COOLDOWN_MS,
  authErrorMessage,
  currentReturnTo,
  isTransientAuthStatus,
  loginHref,
  postLogout,
  readAuthError,
  readLastLoginRedirect,
  recordLoginRedirect,
  shouldAutoRedirect,
  stripAuthError,
} from '../src/ui/auth/oidcSession.ts';

test('loginHref returns to the current path, query and hash route', () => {
  assert.equal(loginHref({ pathname: '/', search: '', hash: '#/chains/c1' }), '/api/v1/auth/login?return_to=%2F%23%2Fchains%2Fc1');
  assert.equal(loginHref({ pathname: '/x', search: '?a=1', hash: '' }), '/api/v1/auth/login?return_to=%2Fx%3Fa%3D1');
  // A failed sign-in marker is never carried into the next attempt.
  assert.equal(currentReturnTo({ pathname: '/', search: '?auth_error=1&a=2', hash: '#/home' }), '/?a=2#/home');
  assert.equal(currentReturnTo({ pathname: '//evil.example', search: '', hash: '' }), '/');
  assert.equal(currentReturnTo({ pathname: '', search: '', hash: '' }), '/');
  assert.equal(stripAuthError('?auth_error=forbidden'), '');
});

test('auth_error values map to clear messages', () => {
  assert.equal(readAuthError(''), null);
  assert.equal(readAuthError('?auth_error=1'), 'failed');
  assert.equal(readAuthError('?auth_error=forbidden'), 'forbidden');
  assert.equal(readAuthError('?auth_error=whatever'), 'failed');
  assert.match(authErrorMessage('forbidden'), /ham-hub users link-oidc/);
  assert.match(authErrorMessage('failed'), /did not complete/);
});

test('auto-redirect has loop protection and never follows a failed sign-in', () => {
  assert.equal(shouldAutoRedirect(1_000, null, null), true);
  assert.equal(shouldAutoRedirect(1_000, null, 'failed'), false);
  assert.equal(shouldAutoRedirect(1_000, null, 'forbidden'), false);
  assert.equal(shouldAutoRedirect(10_000, 5_000, null), false);
  assert.equal(shouldAutoRedirect(5_000 + LOGIN_REDIRECT_COOLDOWN_MS, 5_000, null), true);
  assert.equal(shouldAutoRedirect(1_000, 9_999_999, null), true, 'clock went backwards');
  const store = new Map<string, string>();
  const storage = { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => { store.set(k, v); } };
  assert.equal(readLastLoginRedirect(storage), null);
  recordLoginRedirect(storage, 42);
  assert.equal(readLastLoginRedirect(storage), 42);
  const throwing = { getItem: () => { throw new Error('blocked'); }, setItem: () => { throw new Error('blocked'); } };
  assert.equal(readLastLoginRedirect(throwing), null);
  recordLoginRedirect(throwing, 1); // must not throw
});

test('postLogout POSTs same-origin with the cookie and follows logout_url', async () => {
  const calls: Array<{ url: string; init: any }> = [];
  const ok = (async (url: string, init: any) => {
    calls.push({ url, init });
    return new Response(JSON.stringify({ data: { logout_url: 'https://idp.example/end-session/?id_token_hint=x' } }), { status: 200 });
  }) as unknown as typeof fetch;
  assert.equal(await postLogout(ok), 'https://idp.example/end-session/?id_token_hint=x');
  assert.equal(calls[0].url, '/api/v1/auth/logout');
  assert.equal(calls[0].init.method, 'POST');
  assert.equal(calls[0].init.credentials, 'include');
  const failing = (async () => { throw new Error('offline'); }) as unknown as typeof fetch;
  assert.equal(await postLogout(failing), '/');
  const empty = (async () => new Response(JSON.stringify({ data: {} }), { status: 200 })) as unknown as typeof fetch;
  assert.equal(await postLogout(empty), '/');
});

test('429/503 are transient, 401 is not', () => {
  assert.equal(isTransientAuthStatus(429), true);
  assert.equal(isTransientAuthStatus(503), true);
  assert.equal(isTransientAuthStatus(401), false);
  assert.equal(isTransientAuthStatus(500), false);
});
