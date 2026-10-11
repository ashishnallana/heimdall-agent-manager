// REQ-1, REQ-4: Project/VCS experiment key, Settings toggle, and eligibility resolution.
//
// RUN: node --test tests/ui_project_vcs_experiment_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  PROJECT_VCS_EXPERIMENT_KEY,
  resolveProjectVcsExperiment,
} from '../src/ui/components/chat/projectVcsExperiment.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');
const CONVERSATION_THREAD = path.join(
  REPO_ROOT,
  'src/ui/components/chat/ConversationThreadPage.tsx',
);
const CHAIN_OVERVIEW = path.join(
  REPO_ROOT,
  'src/ui/components/chat/ChainOverviewPanel.tsx',
);
const PROJECT_VCS_PANEL = path.join(
  REPO_ROOT,
  'src/ui/components/chat/ProjectVcsPanel.tsx',
);

test('uses the stable project_vcs key in the domain and Settings toggle', () => {
  assert.equal(PROJECT_VCS_EXPERIMENT_KEY, 'project_vcs');

  const domain = fs.readFileSync(
    path.join(REPO_ROOT, 'src/hub/domain/experiment.odin'),
    'utf8',
  );
  assert.ok(
    domain.includes('PROJECT_VCS_EXPERIMENT_KEY :: "project_vcs"'),
    'the Odin domain must use the same stable experiment key',
  );

  const settings = fs.readFileSync(
    path.join(REPO_ROOT, 'src/ui/components/settings/ExperimentalPanel.tsx'),
    'utf8',
  );
  assert.ok(
    settings.includes('key: PROJECT_VCS_EXPERIMENT_KEY'),
    'Settings must expose the canonical Project/VCS experiment key',
  );
  assert.ok(settings.includes("label: 'Project/VCS'"), 'Settings must name the toggle clearly');
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

test('conversation VCS tab, mount, and both panel render paths use canonical eligibility', () => {
  const source = fs.readFileSync(CONVERSATION_THREAD, 'utf8');

  assert.ok(source.includes('useFetchExperimentsQuery()'), 'conversation must fetch per-user flags');
  assert.ok(
    source.includes('resolveProjectVcsExperiment('),
    'conversation must use the canonical three-state resolver',
  );
  assert.ok(
    source.includes("const projectVcsEnabled = projectVcsExperimentState === 'enabled';"),
    'only the enabled state may grant eligibility',
  );
  assert.ok(
    source.includes('const hasVcs = Boolean(projectId) && projectVcsEnabled;'),
    'VCS availability must require both project context and eligibility',
  );
  assert.ok(source.includes('{hasVcs ? ('), 'the VCS tab button must be gated');
  assert.ok(
    source.includes("active === 'vcs' && hasVcs ? ("),
    'ProjectVcsPanel mounting must be gated',
  );
  assert.ok(
    source.includes('projectVcsEnabled={projectVcsEnabled}'),
    'chain overview must receive the resolved eligibility',
  );
  assert.ok(
    source.includes('experimentEnabled={projectVcsEnabled}'),
    'ProjectVcsPanel must receive the resolved eligibility for defence in depth',
  );
  assert.equal(
    source.match(/\{renderRightPanel\((?:true|false)\)\}/g)?.length,
    2,
    'the shared gated renderer must remain wired to mobile and desktop paths',
  );
});

test('stale VCS URL or persisted selection waits for flags then coerces safely', () => {
  const source = fs.readFileSync(CONVERSATION_THREAD, 'utf8');

  assert.ok(
    source.includes("projectVcsExperimentState !== 'disabled' || rightPanel !== 'vcs'"),
    'coercion must run for a loaded disabled VCS selection, not during loading',
  );
  assert.ok(
    source.includes("const fallback: RightSidebarTab = chainId ? 'tasks' : (projectId || agentInstanceId) ? 'files' : 'tasks';"),
    'stale VCS selection must use the established Tasks/Files fallback',
  );
  assert.ok(source.includes('writeRightSidebarTab(fallback'), 'the persisted tab must be repaired');
  assert.ok(source.includes('syncUrlPanel(fallback)'), 'the stale panel=vcs URL must be repaired');
});

test('Files/Project stays outside the experiment gate while VCS jump-outs are gated', () => {
  const source = fs.readFileSync(CONVERSATION_THREAD, 'utf8');

  assert.ok(
    source.includes('const hasFiles = Boolean(projectId || chainId || agentInstanceId);'),
    'Files availability must remain independent of the experiment',
  );
  assert.ok(source.includes('{hasFiles ? ('), 'the Files tab must remain available');
  assert.ok(
    source.includes("active === 'files' && hasFiles ? ("),
    'ProjectFilesPanel mounting must remain outside the VCS gate',
  );
  assert.ok(
    source.includes('onOpenFileDiff={projectVcsEnabled ? (filePath) => {'),
    'chain file jump-out must be absent when disabled',
  );
  assert.ok(
    source.includes('onOpenVcsFiles={projectVcsEnabled ? () => {'),
    'chain all-changes jump-out must be absent when disabled',
  );
});

test('chain overview gates its VCS section, counts, actions, and both polling queries', () => {
  const source = fs.readFileSync(CHAIN_OVERVIEW, 'utf8');

  assert.ok(source.includes('projectVcsEnabled: boolean;'), 'eligibility must be an explicit prop');
  assert.equal(
    source.match(/skip: !projectVcsEnabled \|\| !projectId/g)?.length,
    2,
    'both 30-second VCS queries must skip while disabled',
  );
  assert.ok(
    source.includes('{projectVcsEnabled ? (\n      <section data-debug-id="chain-overview-section-vcs"'),
    'the entire VCS section must be gated',
  );
  assert.ok(source.includes('{vcsModifiedCount} Modified'), 'enabled modified count must be preserved');
  assert.ok(source.includes('{vcsStagedCount} Staged'), 'enabled staged count must be preserved');
  assert.ok(source.includes('{vcsUntrackedCount} Untracked'), 'enabled untracked count must be preserved');
  assert.ok(source.includes('onOpenFileDiff(file.path)'), 'enabled file jump-out must be preserved');
  assert.ok(source.includes('onClick={onOpenVcsFiles}'), 'enabled all-changes jump-out must be preserved');
});

test('ProjectVcsPanel applies defence-in-depth skips to every automatic query path', () => {
  const source = fs.readFileSync(PROJECT_VCS_PANEL, 'utf8');

  assert.ok(source.includes('experimentEnabled: boolean;'), 'the panel must require eligibility');
  assert.ok(
    source.includes('{ skip: !experimentEnabled || !projectId }'),
    'capabilities query must skip while disabled',
  );
  assert.ok(
    source.includes('{ skip: !experimentEnabled || !projectId || !hasVcs }'),
    'changed-files query must skip while disabled',
  );
  assert.ok(
    source.includes('{ skip: !experimentEnabled || !projectId || !hasVcs || !can(\'workspaces\') }'),
    'workspaces query must skip while disabled',
  );
  assert.ok(
    source.includes("if (!experimentEnabled || !projectId || !can('log')) return;"),
    'lazy log query must be guarded',
  );
  assert.equal(
    source.match(/if \(!experimentEnabled \|\| !projectId \|\| !diffBaseRef\) return;/g)?.length,
    2,
    'both lazy commit-diff query paths must be guarded',
  );
  assert.ok(
    source.includes('{ skip: !experimentEnabled || isDeleted }'),
    'file-content query must skip while disabled',
  );
  assert.ok(
    source.includes('{ skip: !experimentEnabled || !file.path }'),
    'file-diff query must skip while disabled',
  );
  assert.ok(source.includes('if (!experimentEnabled) return null;'), 'disabled panel must render nothing');
});
