// REQ-T1-3: a document opened at a path-form route with no hash route is folded
// into the hash router (src/ui/utils/appLocation.ts legacyPathRouteHash, called
// by migrateLegacyPathRoute in src/ui/main.tsx).
//
// RUN: node --test tests/ui_legacy_path_route_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { legacyPathRouteHash } from '../src/ui/utils/appLocation.ts';

test('legacy /workspace paths still fold into the hash route', () => {
  assert.equal(legacyPathRouteHash('/workspace/chains/c1/tasks/t2', '?view=x', ''), '#/workspace/chains/c1/tasks/t2?view=x');
  assert.equal(legacyPathRouteHash('/app/workspace', '', ''), '#/workspace');
});

test('/device/add folds with its query so the code reaches the approval page', () => {
  assert.equal(legacyPathRouteHash('/device/add', '?code=ABCD-2345', ''), '#/device/add?code=ABCD-2345');
  assert.equal(legacyPathRouteHash('/device/add', '', ''), '#/device/add');
  assert.equal(legacyPathRouteHash('/device/add/', '', ''), '#/device/add');
  assert.equal(legacyPathRouteHash('/sub/device/add', '?code=ABCD-2345', ''), '#/device/add?code=ABCD-2345');
});

test('/device/providers and /device/providers/<bridge> fold', () => {
  assert.equal(legacyPathRouteHash('/device/providers', '', ''), '#/device/providers');
  assert.equal(legacyPathRouteHash('/device/providers/brg_123', '', ''), '#/device/providers/brg_123');
  assert.equal(legacyPathRouteHash('/device/providers/brg%20x', '?a=1', ''), '#/device/providers/brg%20x?a=1');
});

test('an existing hash route always wins', () => {
  assert.equal(legacyPathRouteHash('/device/add', '?code=ABCD-2345', '#/workspace'), null);
  assert.equal(legacyPathRouteHash('/workspace', '', '#/device/add'), null);
});

test('a lone "#" is not a hash route', () => {
  assert.equal(legacyPathRouteHash('/device/add', '', '#'), '#/device/add');
});

test('non-route paths are left alone', () => {
  for (const pathname of ['/', '', '/index.html', '/device', '/device/added', '/device/add/extra', '/device/providers/a/b', '/devices/add', '/xdevice/add']) {
    assert.equal(legacyPathRouteHash(pathname, '?code=ABCD-2345', ''), null, pathname);
  }
});
