// REQ-EXP-GATE-1: Actions experiment key, Settings toggle list, and flag resolution.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_experimental_flags_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  ACTIONS_EXPERIMENT_KEY,
  EXPERIMENTAL_FLAGS,
  PROJECT_VCS_EXPERIMENT_KEY,
  resolveActionsExperiment,
  resolveExperimentFlag,
} from '../src/ui/components/settings/experimentFlags.ts';
import { resolveProjectVcsExperiment } from '../src/ui/components/chat/projectVcsExperiment.ts';

test('uses the stable actions key shared with the hub', () => {
  assert.equal(ACTIONS_EXPERIMENT_KEY, 'actions');
});

test('Settings > Experimental lists an Actions toggle and keeps existing toggles', () => {
  const keys = EXPERIMENTAL_FLAGS.map((f) => f.key);
  assert.deepEqual(keys, ['lsp', 'streaming_terminal_pane', PROJECT_VCS_EXPERIMENT_KEY, ACTIONS_EXPERIMENT_KEY]);
  assert.equal(new Set(keys).size, keys.length, 'toggle keys are unique');
  const actions = EXPERIMENTAL_FLAGS.find((f) => f.key === ACTIONS_EXPERIMENT_KEY);
  assert.equal(actions?.label, 'Actions');
  assert.ok(actions?.description);
});

test('Actions is loading until flags load, then disabled when absent or false', () => {
  assert.equal(resolveActionsExperiment(undefined), 'loading');
  assert.equal(resolveActionsExperiment([]), 'disabled');
  assert.equal(resolveActionsExperiment([{ key: PROJECT_VCS_EXPERIMENT_KEY, enabled: true }]), 'disabled');
  assert.equal(resolveActionsExperiment([{ key: ACTIONS_EXPERIMENT_KEY, enabled: false }]), 'disabled');
  assert.equal(resolveActionsExperiment([{ key: ACTIONS_EXPERIMENT_KEY, enabled: true }]), 'enabled');
});

test('Actions and Project/VCS flags resolve independently', () => {
  const flags = [
    { key: PROJECT_VCS_EXPERIMENT_KEY, enabled: true },
    { key: ACTIONS_EXPERIMENT_KEY, enabled: false },
  ];
  assert.equal(resolveProjectVcsExperiment(flags), 'enabled');
  assert.equal(resolveActionsExperiment(flags), 'disabled');
});

test('fails closed for malformed or duplicate flags', () => {
  assert.equal(
    resolveExperimentFlag(
      [{ key: ACTIONS_EXPERIMENT_KEY, enabled: 'true' }] as unknown as Array<{ key: string; enabled: boolean }>,
      ACTIONS_EXPERIMENT_KEY,
    ),
    'disabled',
  );
  assert.equal(
    resolveActionsExperiment([
      { key: ACTIONS_EXPERIMENT_KEY, enabled: true },
      { key: ACTIONS_EXPERIMENT_KEY, enabled: true },
    ]),
    'disabled',
  );
});
