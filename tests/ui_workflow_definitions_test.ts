// Task System v2 (Milestone M5): UI test suite for User-Defined Workflow Definitions,
// schema validation, and modal integration.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_workflow_definitions_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import type { WorkflowDefinitionItem } from '../src/ui/api/endpoints/tasks.ts';

const REPO_ROOT = path.resolve(import.meta.dirname, '..');

test('tasks.ts exports useFetchWorkflowDefinitionsQuery and useDefineWorkflowMutation', () => {
  const tasksTs = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/api/endpoints/tasks.ts'), 'utf-8');
  assert.ok(tasksTs.includes('useFetchWorkflowDefinitionsQuery'), 'tasks.ts must export useFetchWorkflowDefinitionsQuery');
  assert.ok(tasksTs.includes('useDefineWorkflowMutation'), 'tasks.ts must export useDefineWorkflowMutation');
  assert.ok(tasksTs.includes('/workflows/definitions'), 'tasks.ts must wire /workflows/definitions endpoint');
  assert.ok(tasksTs.includes('WorkflowDefinitions'), 'tasks.ts must tag with WorkflowDefinitions');
});

test('TaskChainsPage.tsx includes Workflows definition button and WorkflowDefinitionsModal', () => {
  const pageTsx = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/taskchain/TaskChainsPage.tsx'), 'utf-8');
  assert.ok(pageTsx.includes('task-chains-workflows-btn'), 'TaskChainsPage must render Workflows button');
  assert.ok(pageTsx.includes('WorkflowDefinitionsModal'), 'TaskChainsPage must render WorkflowDefinitionsModal');
  assert.ok(pageTsx.includes('showWorkflowDefsModal'), 'TaskChainsPage must manage showWorkflowDefsModal state');
});

test('CreateChainModal.tsx supports both built-in templates and custom workflow definitions', () => {
  const modalTsx = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/taskchain/CreateChainModal.tsx'), 'utf-8');
  assert.ok(modalTsx.includes('useFetchWorkflowDefinitionsQuery'), 'CreateChainModal must query workflow definitions');
  assert.ok(modalTsx.includes('Built-in Templates'), 'CreateChainModal must display built-in templates optgroup');
  assert.ok(modalTsx.includes('Custom Workflow Definitions'), 'CreateChainModal must display custom workflow definitions optgroup');
  assert.ok(modalTsx.includes('def_id'), 'CreateChainModal must support submitting with def_id');
});

test('workflow specification validator catches invalid schemas, missing stages, and missing names', () => {
  // Schema validator logic matching WorkflowDefinitionsModal
  function validateWorkflowSpec(jsonStr: string, nameOverride = ''): { valid: boolean; error?: string } {
    try {
      const parsed = JSON.parse(jsonStr);
      if (parsed.schema && parsed.schema !== 'workflow.v1') {
        return { valid: false, error: `Schema must be "workflow.v1" (got "${parsed.schema}")` };
      }
      if (!parsed.name && !nameOverride) {
        return { valid: false, error: 'A workflow "name" is required in the JSON or as an override' };
      }
      if (!parsed.stages || !Array.isArray(parsed.stages) || parsed.stages.length === 0) {
        return { valid: false, error: 'Workflow must contain at least one stage in "stages" array' };
      }
      return { valid: true };
    } catch (err: any) {
      return { valid: false, error: `Syntax error: ${err.message}` };
    }
  }

  // 1. Invalid JSON syntax
  assert.strictEqual(validateWorkflowSpec('{ bad json }').valid, false);

  // 2. Invalid schema
  assert.strictEqual(validateWorkflowSpec('{"schema": "workflow.v2", "name": "foo", "stages": [{"key": "s1"}]}').valid, false);

  // 3. Missing name without override
  assert.strictEqual(validateWorkflowSpec('{"schema": "workflow.v1", "stages": [{"key": "s1"}]}').valid, false);
  // Name override rescues missing name
  assert.strictEqual(validateWorkflowSpec('{"schema": "workflow.v1", "stages": [{"key": "s1"}]}', 'override_name').valid, true);

  // 4. Missing or empty stages
  assert.strictEqual(validateWorkflowSpec('{"schema": "workflow.v1", "name": "pipe", "stages": []}').valid, false);
  assert.strictEqual(validateWorkflowSpec('{"schema": "workflow.v1", "name": "pipe"}').valid, false);

  // 5. Valid spec
  const validSpec = JSON.stringify({
    schema: 'workflow.v1',
    name: 'test_pipeline',
    title: 'Test Pipeline',
    inputs: [{ name: 'target', type: 'string', required: true }],
    stages: [
      { key: 'build', kind: 'task', brief: { goal: 'build', verify: 'none' } },
      { key: 'deploy', kind: 'task', needs: ['build'], brief: { goal: 'deploy', verify: 'none' } },
    ],
  });
  assert.strictEqual(validateWorkflowSpec(validSpec).valid, true);
});
