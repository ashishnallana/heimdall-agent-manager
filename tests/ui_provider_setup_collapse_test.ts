// Provider setup (enrollment page and Settings → Providers): each provider card starts
// collapsed; its header keeps status, a model count and the Enable toggle, and expanding
// it shows the model rows and their Test buttons.
//
// RUN: node --test tests/ui_provider_setup_collapse_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const source = fs.readFileSync(
  fileURLToPath(new URL('../src/ui/components/providers/ProviderSetupSurface.tsx', import.meta.url)),
  'utf8',
);

test('provider cards are collapsed by default and toggle from the header', () => {
  // Nothing is expanded until the user asks: the state starts empty, and a missing key is false.
  assert.match(source, /useState<Record<string, boolean>>\(\{\}\)/);
  assert.match(source, /const isExpanded = Boolean\(expanded\[provider\.provider\]\);/);
  assert.match(source, /aria-expanded=\{isExpanded\}[\s\S]*aria-controls=\{detailsId\}/);
  assert.match(source, /onClick=\{\(\) => setExpanded\(\(prev\) => \(\{ \.\.\.prev, \[provider\.provider\]: !isExpanded \}\)\)\}/);
});

test('the model rows render only for an expanded card; Enable and the summary stay in the header', () => {
  assert.match(source, /\{!isExpanded \? null : available \? \(\s*<div id=\{detailsId\}/);
  const header = source.slice(source.indexOf('provider-setup-toggle-'), source.indexOf('{!isExpanded ? null'));
  assert.match(header, /provider-setup-summary-/);
  assert.match(header, /provider-setup-enable-/, 'the Enable toggle is reachable while collapsed');
  assert.doesNotMatch(header, /provider-model-row-/, 'no model row in the always-visible header');
});
