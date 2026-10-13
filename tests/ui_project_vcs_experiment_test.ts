// REQ-1, REQ-4: Project/VCS experiment key, Settings toggle, and eligibility resolution.
//
// RUN: node --test tests/ui_project_vcs_experiment_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  PROJECT_VCS_EXPERIMENT_KEY,
  resolveProjectVcsExperiment,
} from '../src/ui/components/chat/projectVcsExperiment.ts';

test('uses the stable project_vcs key in the domain and Settings toggle', () => {
  assert.equal(PROJECT_VCS_EXPERIMENT_KEY, 'project_vcs');
});

test('resolves undefined flags as loading', () => {
  assert.equal(resolveProjectVcsExperiment(undefined), 'loading');
});

test('resolves an absent key as disabled after flags load', () => {
  assert.equal(resolveProjectVcsExperiment([]), 'disabled');
  assert.equal(
    resolveProjectVcsExperiment([{ key: 'another_experiment', enabled: true }]),
    'disabled',
  );
});

test('resolves an explicit false Project/VCS flag as disabled', () => {
  assert.equal(
    resolveProjectVcsExperiment([{ key: PROJECT_VCS_EXPERIMENT_KEY, enabled: false }]),
    'disabled',
  );
});

test('resolves an explicit true Project/VCS flag as enabled', () => {
  assert.equal(
    resolveProjectVcsExperiment([{ key: PROJECT_VCS_EXPERIMENT_KEY, enabled: true }]),
    'enabled',
  );
});

test('ignores unrelated flags when resolving a valid Project/VCS flag', () => {
  assert.equal(
    resolveProjectVcsExperiment([
      { key: 'streaming_terminal_pane', enabled: false },
      { key: PROJECT_VCS_EXPERIMENT_KEY, enabled: true },
      { key: 'lsp', enabled: true },
    ]),
    'enabled',
  );
});

test('fails closed for malformed or duplicate Project/VCS flags', () => {
  assert.equal(
    resolveProjectVcsExperiment([
      { key: PROJECT_VCS_EXPERIMENT_KEY, enabled: 'true' },
    ] as unknown as Array<{ key: string; enabled: boolean }>),
    'disabled',
  );
  assert.equal(
    resolveProjectVcsExperiment([
      { key: PROJECT_VCS_EXPERIMENT_KEY, enabled: true },
      { key: PROJECT_VCS_EXPERIMENT_KEY, enabled: true },
    ]),
    'disabled',
  );
  assert.equal(
    resolveProjectVcsExperiment([
      { key: PROJECT_VCS_EXPERIMENT_KEY, enabled: true },
      { key: PROJECT_VCS_EXPERIMENT_KEY, enabled: false },
    ]),
    'disabled',
  );
});
