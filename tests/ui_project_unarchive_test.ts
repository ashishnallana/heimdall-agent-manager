// The project header's verbs are direct buttons beside Edit, with no `…` menu:
// Archive for an active project, Unarchive for an archived one.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_project_unarchive_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeProject } from '../src/ui/api/endpoints/projects.ts';
import { VERB_LABEL, archiveConfirmBody, verbsForState } from '../src/ui/components/projects/projectModel.ts';

async function renderActions(state: 'active' | 'archived') {
  const React = (await import('react')).default;
  const { Provider } = await import('react-redux');
  const { renderToStaticMarkup } = await import('react-dom/server');
  const { makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
  const { ProjectDetailActions } = await import('../src/ui/components/projects/ProjectDetail.tsx');
  const store = await makeVaultStore();
  const record = normalizeProject({ project_id: 'proj_1', name: 'ninjy dev', state, updated_at: '2026-11-05T10:00:00Z' });
  return renderToStaticMarkup(
    React.createElement(Provider, { store, children: React.createElement(ProjectDetailActions, { record, busy: '', onVerb: () => {} }) }),
  );
}

test('an archived project offers Edit and Unarchive; an active one Edit and Archive', () => {
  assert.deepEqual(verbsForState('archived'), ['edit', 'unarchive']);
  assert.deepEqual(verbsForState('active'), ['edit', 'archive']);
  assert.equal(VERB_LABEL.unarchive, 'Unarchive');
});

test('the archive confirm no longer says archiving cannot be undone', () => {
  assert.doesNotMatch(archiveConfirmBody(['ninjy dev']), /can't un-archive/);
  assert.match(archiveConfirmBody(['ninjy dev']), /unarchive it later/);
});

test('archived: Unarchive is a button beside Edit and there is no "…" menu', async () => {
  const html = await renderActions('archived');
  assert.match(html, /data-debug-id="project-view-edit"/);
  assert.match(html, /data-debug-id="project-view-unarchive"[^>]*>[\s\S]*?Unarchive/);
  assert.doesNotMatch(html, /data-debug-id="project-view-menu"/);
});

test('active: Archive is a button beside Edit, with no "…" menu and no Unarchive', async () => {
  const html = await renderActions('active');
  assert.match(html, /data-debug-id="project-view-edit"/);
  assert.match(html, /data-debug-id="project-view-archive"[^>]*>[\s\S]*?Archive/);
  assert.doesNotMatch(html, /data-debug-id="project-view-menu"/);
  assert.doesNotMatch(html, /project-view-unarchive/);
});
