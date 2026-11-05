// Detail headers put their verbs in direct buttons beside the primary one, with
// no `…` menu: Projects and Agents (Archive / Unarchive), Actions (Run now /
// Delete) and Memory (Edit / Archive / Restore).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_detail_header_actions_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeProject } from '../src/ui/api/endpoints/projects.ts';
import { normalizeAgent } from '../src/ui/api/endpoints/agents.ts';
import { VERB_LABEL, archiveConfirmBody, verbsForState } from '../src/ui/components/projects/projectModel.ts';
import * as agentModel from '../src/ui/components/agents/agentModel.ts';

async function render(element: (React: any) => any) {
  const React = (await import('react')).default;
  const { Provider } = await import('react-redux');
  const { renderToStaticMarkup } = await import('react-dom/server');
  const { makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
  const store = await makeVaultStore();
  return renderToStaticMarkup(React.createElement(Provider, { store, children: element(React) }));
}

const NO_MENU = /data-debug-id="[a-z]+-view-menu"/;
const button = (id: string, label: string) => new RegExp(`data-debug-id="${id}"[^>]*>[\\s\\S]*?${label}`);

/* Projects ------------------------------------------------------------- */

async function renderProject(state: 'active' | 'archived') {
  const { ProjectDetailActions } = await import('../src/ui/components/projects/ProjectDetail.tsx');
  const record = normalizeProject({ project_id: 'proj_1', name: 'ninjy dev', state, updated_at: '2026-11-05T10:00:00Z' });
  return render((React) => React.createElement(ProjectDetailActions, { record, busy: '', onVerb: () => {} }));
}

test('projects: an archived project offers Edit and Unarchive; an active one Edit and Archive', () => {
  assert.deepEqual(verbsForState('archived'), ['edit', 'unarchive']);
  assert.deepEqual(verbsForState('active'), ['edit', 'archive']);
  assert.equal(VERB_LABEL.unarchive, 'Unarchive');
  assert.doesNotMatch(archiveConfirmBody(['ninjy dev']), /can't un-archive/);
  assert.match(archiveConfirmBody(['ninjy dev']), /unarchive it later/);
});

test('projects: Archive / Unarchive are buttons beside Edit, with no "…" menu', async () => {
  const active = await renderProject('active');
  assert.match(active, /data-debug-id="project-view-edit"/);
  assert.match(active, button('project-view-archive', 'Archive'));
  assert.doesNotMatch(active, /project-view-unarchive/);
  assert.doesNotMatch(active, NO_MENU);
  const archived = await renderProject('archived');
  assert.match(archived, button('project-view-unarchive', 'Unarchive'));
  assert.doesNotMatch(archived, /project-view-archive"/);
  assert.doesNotMatch(archived, NO_MENU);
});

/* Agents --------------------------------------------------------------- */

async function renderAgent(state: 'active' | 'archived') {
  const { AgentDetailActions } = await import('../src/ui/components/agents/AgentDetail.tsx');
  const record = normalizeAgent({ agent_id: 'agt_1', name: 'coder', state, updated_at: '2026-11-05T10:00:00Z' });
  return render((React) => React.createElement(AgentDetailActions, { record, busy: '', onVerb: () => {} }));
}

test('agents: an archived agent offers Edit and Unarchive; an active one Edit and Archive', () => {
  assert.deepEqual(agentModel.verbsForState('archived'), ['edit', 'unarchive']);
  assert.deepEqual(agentModel.verbsForState('active'), ['edit', 'archive']);
  assert.match(agentModel.archiveConfirmBody(['coder']), /unarchive it later/);
});

test('agents: Archive / Unarchive are buttons beside Edit, with no "…" menu', async () => {
  const active = await renderAgent('active');
  assert.match(active, /data-debug-id="agent-view-edit"/);
  assert.match(active, button('agent-view-archive', 'Archive'));
  assert.doesNotMatch(active, NO_MENU);
  const archived = await renderAgent('archived');
  assert.match(archived, button('agent-view-unarchive', 'Unarchive'));
  assert.doesNotMatch(archived, NO_MENU);
});

/* Actions and Memory --------------------------------------------------- */

test('actions: Run now and Delete are buttons beside Edit, with no "…" menu', async () => {
  const { ActionDetailActions } = await import('../src/ui/components/actions/ActionDetail.tsx');
  const html = await render((React) =>
    React.createElement(ActionDetailActions, { record: { id: 'act_1', prompt_text: 'Nightly report', state: 'active' } as any, busy: '', onVerb: () => {} }),
  );
  assert.match(html, button('action-view-run', 'Run now'));
  assert.match(html, button('action-view-delete', 'Delete'));
  assert.doesNotMatch(html, NO_MENU);
});

test('memory: Edit / Archive and Restore are direct buttons, with no "…" menu', async () => {
  const { MemoryDetailActions } = await import('../src/ui/components/memory/MemoryDetail.tsx');
  const renderMemory = (status: string) =>
    render((React) => React.createElement(MemoryDetailActions, { record: { memory_id: 'mem_1', status }, busy: '', onVerb: () => {} }));
  const active = await renderMemory('active');
  assert.match(active, button('memory-view-edit', 'Edit'));
  assert.match(active, button('memory-view-archive', 'Archive'));
  assert.doesNotMatch(active, NO_MENU);
  const archived = await renderMemory('archived');
  assert.match(archived, button('memory-view-restore', 'Restore'));
  assert.doesNotMatch(archived, NO_MENU);
});
