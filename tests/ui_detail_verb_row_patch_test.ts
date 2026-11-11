// A verb fired from a list page's detail pane must repaint its list row at once:
// useInfiniteList rows never see RTK tag invalidation (detailVerbRowPatch.ts).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_detail_verb_row_patch_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

const { archivedRowPatch, shellRowPatch } = await import('../src/ui/utils/detailVerbRowPatch.ts');

const row = { agentId: 'agt_1', name: 'Ninjy', state: 'active', updatedAt: '2026-11-01T00:00:00Z' };

test('archive and unarchive flip the row state and take the hub updated_at', () => {
  const archived = archivedRowPatch(row, 'archive', { updated_at: '2026-11-11T10:00:00Z' });
  assert.equal(archived.state, 'archived');
  assert.equal(archived.updatedAt, '2026-11-11T10:00:00Z');
  assert.equal(archived.name, 'Ninjy');

  const restored = archivedRowPatch(archived, 'unarchive', { updated_at: '2026-11-11T11:00:00Z' });
  assert.equal(restored.state, 'active');
  assert.equal(restored.updatedAt, '2026-11-11T11:00:00Z');
});

test('an empty or missing hub response still flips the state and keeps updatedAt', () => {
  for (const saved of [{}, null, undefined, '']) {
    const next = archivedRowPatch(row, 'archive', saved);
    assert.equal(next.state, 'archived');
    assert.equal(next.updatedAt, row.updatedAt);
  }
});

test('the input row is not mutated', () => {
  archivedRowPatch(row, 'archive', {});
  assert.equal(row.state, 'active');
});

const session = { session_id: 'sh_1', status: 'running', command: 'npm run dev' };

test('shell kill repaints its row as killed', () => {
  const patch = shellRowPatch('kill', session, { outcome: 'killed' });
  assert.ok(patch);
  assert.equal(patch.id, 'sh_1');
  assert.equal(typeof patch.next, 'function');
  const next = (patch.next as (p: typeof session) => typeof session)(session);
  assert.equal(next.status, 'killed');
  assert.equal(next.command, 'npm run dev');
});

test('shell restart takes the hub session; interrupt and bad responses patch nothing', () => {
  const fresh = { session_id: 'sh_1', status: 'running', command: 'npm run dev' };
  assert.deepEqual(shellRowPatch('restart', { ...session, status: 'exited' }, fresh), { id: 'sh_1', next: fresh });
  assert.equal(shellRowPatch('restart', session, {}), null);
  assert.equal(shellRowPatch('restart', session, null), null);
  assert.equal(shellRowPatch('interrupt', session, {}), null);
});
