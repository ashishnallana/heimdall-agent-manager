// List and profile page share one effective enabled state.
//
// RUN: node --test tests/ui_provider_enabled_state_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { providerEnabledView } from '../src/ui/components/providers/providerEnabledState.ts';

const read = (p: string) => fs.readFileSync(fileURLToPath(new URL(p, import.meta.url)), 'utf8');

test('agree: profile and bridge on -> Enabled, no reason, no fix', () => {
  assert.deepEqual(providerEnabledView(true, true), { enabled: true, label: 'Enabled', reason: '', fix: 'none', fixLabel: '' });
});

test('profile off -> Disabled with reason and the enable-profile fix', () => {
  for (const rt of [true, false, undefined]) {
    const v = providerEnabledView(false, rt);
    assert.equal(v.label, 'Disabled');
    assert.equal(v.reason, 'Profile disabled');
    assert.equal(v.fix, 'enable_profile');
  }
});

test('bridge off -> Disabled, says disabled on this bridge, single enable-on-bridge fix', () => {
  const v = providerEnabledView(true, false);
  assert.equal(v.label, 'Disabled');
  assert.equal(v.reason, 'Profile enabled, disabled on this bridge');
  assert.equal(v.fix, 'enable_on_bridge');
  assert.equal(providerEnabledView(true, undefined).fix, 'enable_on_bridge');
});

test('list and profile page both render from providerEnabledView', () => {
  const src = read('../src/ui/components/providers/ProviderProfilesSurface.tsx');
  assert.match(src, /providerEnabledView\(p\.enabled, s\?\.enabled\)/, 'list row');
  assert.match(src, /providerEnabledView\(draft\.enabled, currentStatus\?\.enabled\)/, 'profile page');
  assert.doesNotMatch(src, /p\.enabled && s\?\.enabled \? 'Enabled'/);
  assert.match(src, /data-debug-id="profile-enable-on-bridge"/);
});
