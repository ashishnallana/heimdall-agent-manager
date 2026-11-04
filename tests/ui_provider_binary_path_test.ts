// Provider settings show where each provider's executable was found.
//
// RUN: node --test tests/ui_provider_binary_path_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { providerBinaryPathView } from '../src/ui/components/providers/providerBinaryPathView.ts';

const read = (p: string) => fs.readFileSync(fileURLToPath(new URL(p, import.meta.url)), 'utf8');

test('a PATH-resolved provider shows its absolute path', () => {
  const v = providerBinaryPathView({ state: 'present', binary_path: '/home/linuxbrew/.linuxbrew/bin/claude' });
  assert.deepEqual(v, { kind: 'path', path: '/home/linuxbrew/.linuxbrew/bin/claude', label: '' });
});

test('an absent provider reads "not found on PATH"', () => {
  assert.equal(providerBinaryPathView({ state: 'absent', binary_path: '' }).label, 'Not found on PATH');
  assert.equal(providerBinaryPathView(undefined).kind, 'missing');
  // Present but no reported path (older hub) is not claimed as found.
  assert.equal(providerBinaryPathView({ state: 'present', binary_path: '' }).kind, 'missing');
});

test('a profile binary_path is labelled as an override and wins over PATH', () => {
  const v = providerBinaryPathView({ state: 'present', binary_path: '/usr/bin/claude' }, ' /opt/claude ');
  assert.deepEqual(v, { kind: 'override', path: '/opt/claude', label: 'Override' });
  assert.equal(providerBinaryPathView({ state: 'absent' }, '/opt/claude').kind, 'override');
});

test('list rows only know has_binary: labelled override without a path, path kept when reported', () => {
  assert.deepEqual(providerBinaryPathView({ state: 'present', binary_path: '' }, '', true), { kind: 'override', path: '', label: 'Override' });
  assert.equal(providerBinaryPathView({ state: 'present', binary_path: '/usr/bin/claude' }, '', true).path, '/usr/bin/claude');
  assert.equal(providerBinaryPathView({ state: 'absent' }, '', false).kind, 'missing');
  const s = read('../src/ui/components/providers/ProviderProfilesSurface.tsx');
  assert.match(s, /hasOverride=\{!!p\.has_binary\}/);
  assert.doesNotMatch(s, /\(p as \{ config/);
});

test('the row component is monospace, truncated, full path in the tooltip, and wired into both views', () => {
  const c = read('../src/ui/components/providers/ProviderBinaryPath.tsx');
  assert.match(c, /role="code"[^>]*truncate[^>]*title=\{view\.path\}/);
  assert.match(c, /view\.kind === 'override' \? <Badge>/);
  const s = read('../src/ui/components/providers/ProviderProfilesSurface.tsx');
  assert.equal((s.match(/<ProviderBinaryPath /g) || []).length, 2, 'profile list row and status section');
});
