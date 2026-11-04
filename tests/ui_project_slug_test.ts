// T17: a project's slug is derived from its PLAINTEXT name before the name is
// vault-encrypted, so the hub never falls back to the ciphertext. Slugs are not
// shown or edited anywhere in the UI.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_project_slug_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {
  REPO_ROOT,
  installWindowShim,
  installFetchCapture,
  makeVaultStore,
  unlockVault,
  clearActiveKey,
} from './helpers/vaultEndpointHarness.ts';

const TEST_KEY = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

test('slugify / deriveProjectSlug: plaintext name first, then the folder, then "project"', async () => {
  const { slugify, deriveProjectSlug, lastPathSegment } = await import('../src/ui/utils/slug.ts');
  assert.equal(slugify('  My Cool_App 2!  '), 'my-cool-app-2');
  assert.equal(slugify('--x--'), 'x');
  assert.equal(slugify('プロジェクト'), '');
  assert.equal(lastPathSegment('/home/u/repo/'), 'repo');
  assert.equal(lastPathSegment('C:\\Users\\u\\Heimdall.Hub'), 'Heimdall.Hub');
  assert.equal(lastPathSegment(''), '');
  assert.equal(deriveProjectSlug('Heimdall Hub', '/srv/other'), 'heimdall-hub');
  assert.equal(deriveProjectSlug('プロジェクト', '/home/u/My Repo'), 'my-repo', 'non-Latin name falls back to the folder');
  assert.equal(deriveProjectSlug('プロジェクト', '/'), 'project');
  assert.equal(deriveProjectSlug('', undefined), 'project');
});

test('AgentFormPage reuses the shared slugify instead of a private copy', () => {
  const src = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/agents/AgentFormPage.tsx'), 'utf8');
  assert.match(src, /import \{ slugify \} from '\.\.\/\.\.\/utils\/slug'/);
  assert.doesNotMatch(src, /function slugify\(/);
});

async function createWith(unlocked: boolean, payload: Record<string, unknown>) {
  installWindowShim();
  const capture = installFetchCapture();
  capture.setNextResponse({ data: { project_id: 'proj_t17' } });
  const store = await makeVaultStore();
  if (unlocked) await unlockVault(store, TEST_KEY);
  else await clearActiveKey();
  const { projectsApi } = await import('../src/ui/api/endpoints/projects.ts');
  try {
    const result = await store.dispatch((projectsApi as any).endpoints.createProject.initiate(payload));
    assert.ok(!result.error, `create succeeded: ${JSON.stringify(result.error)}`);
    return capture.find((r) => r.method === 'POST' && /\/projects$/.test(new URL(r.url, 'http://x').pathname)).body;
  } finally {
    await clearActiveKey();
  }
}

test('createProject (vault unlocked): slug derived from the plaintext name, name sealed', async () => {
  const { isVaultArmored } = await import('../src/ui/utils/vaultContent.ts');
  const body = await createWith(true, { name: 'Heimdall Hub', default_path: '/home/u/hub' });
  assert.ok(isVaultArmored(body.name), 'name is encrypted on the wire');
  assert.equal(body.slug, 'heimdall-hub');
  assert.ok(!isVaultArmored(body.slug), 'slug is never ciphertext');
});

test('createProject (vault locked): slug derived the same way', async () => {
  const body = await createWith(false, { name: 'Heimdall Hub', default_path: '/home/u/hub' });
  assert.equal(body.name, 'Heimdall Hub');
  assert.equal(body.slug, 'heimdall-hub');
});

test('createProject keeps a given slug; non-Latin or already-armored names fall back to the folder', async () => {
  const { encryptVaultText, isVaultArmored } = await import('../src/ui/utils/vaultContent.ts');
  const given = await createWith(true, { name: 'Heimdall Hub', slug: 'chosen', default_path: '/home/u/hub' });
  assert.equal(given.slug, 'chosen');
  const nonLatin = await createWith(true, { name: 'プロジェクト', default_path: '/home/u/my-repo' });
  assert.equal(nonLatin.slug, 'my-repo');
  const key = await (await import('./helpers/vaultTestKeyring.ts')).keyringFromHex(TEST_KEY);
  const sealed = await encryptVaultText('Secret', key);
  const armored = await createWith(true, { name: sealed, default_path: '/home/u/secret-repo' });
  assert.equal(armored.slug, 'secret-repo');
  assert.ok(!isVaultArmored(armored.slug));
  const nothing = await createWith(false, { name: 'プロジェクト' });
  assert.equal(nothing.slug, 'project');
});

test('no project slug is shown or edited in the UI', () => {
  const read = (rel: string) => fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');
  const detail = read('src/ui/components/projects/ProjectDetail.tsx');
  assert.doesNotMatch(detail, /label="Slug"/, 'project view has no Slug row');
  assert.doesNotMatch(detail, /record\.slug/);
  const form = read('src/ui/components/projects/ProjectFormPage.tsx');
  assert.doesNotMatch(form, /project-form-slug/, 'project form has no Slug input');
  assert.doesNotMatch(form, /form\.slug|record\.slug/);
  const list = read('src/ui/components/projects/ProjectListPage.tsx');
  assert.doesNotMatch(list, /paths, slugs/, 'search copy does not mention slugs');
});
