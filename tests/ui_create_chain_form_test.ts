// Create Chain modal: a ticket chain's project comes from its coordinator, so the
// modal must not send project_id without coordinator_agent_id (the hub answers 400),
// and a rejected create must be shown in the modal, not only logged.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_create_chain_form_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {
  PROJECT_NEEDS_COORDINATOR_MESSAGE,
  createChainErrorMessage,
  createChainFormProblem,
} from '../src/ui/components/taskchain/createChainForm.ts';

const REPO_ROOT = path.resolve(import.meta.dirname, '..');

test('ticket chain with a project and no coordinator is blocked with a reason', () => {
  assert.equal(createChainFormProblem('ticket', 'proj_1', ''), PROJECT_NEEDS_COORDINATOR_MESSAGE);
  assert.equal(createChainFormProblem('ticket', 'proj_1', '   '), PROJECT_NEEDS_COORDINATOR_MESSAGE);
});

test('project with coordinator, self-managed without project, and workflows are allowed', () => {
  assert.equal(createChainFormProblem('ticket', 'proj_1', 'agt_1'), '');
  assert.equal(createChainFormProblem('ticket', '', ''), '');
  assert.equal(createChainFormProblem('ticket', '', 'agt_1'), '');
  // Workflow runs take project_id on their own endpoint and have no coordinator field.
  assert.equal(createChainFormProblem('workflow', 'proj_1', ''), '');
});

test('create errors are worded from the hub message', () => {
  assert.equal(
    createChainErrorMessage({ status: 'CUSTOM_ERROR', error: 'project not found' }),
    'project not found',
  );
  assert.equal(createChainErrorMessage({ data: { error: { message: 'project archived' } } }), 'project archived');
  assert.equal(createChainErrorMessage(new Error('network down')), 'network down');
  assert.equal(createChainErrorMessage('plain'), 'plain');
  assert.equal(createChainErrorMessage(undefined), 'Could not create the chain.');
  assert.equal(createChainErrorMessage({ status: 'CUSTOM_ERROR', error: '  ' }), 'Could not create the chain.');
});

test('CreateChainModal blocks the project-without-coordinator submit and shows create errors', () => {
  const src = fs.readFileSync(
    path.join(REPO_ROOT, 'src/ui/components/taskchain/CreateChainModal.tsx'),
    'utf8',
  );
  assert.match(src, /createChainFormProblem\(kind, projectId, coordinatorAgentId\)/);
  assert.match(src, /if \(!title\.trim\(\) \|\| formProblem\) return;/);
  assert.match(src, /disabled=\{isSubmitting \|\| !title\.trim\(\) \|\| Boolean\(formProblem\)\}/);
  assert.match(src, /setSubmitError\(createChainErrorMessage\(err\)\)/);
  assert.match(src, /role="alert" data-debug-id="create-chain-error"/);
});
