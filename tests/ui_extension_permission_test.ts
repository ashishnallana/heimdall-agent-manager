// Permission prompt input summary (REQ-EXT-PERM-1, UI): command / file path /
// diff extraction and the countdown formatter. The card state model (agent
// blockers) is covered by tests/ui_extension_blockers_test.ts.
//
// RUN: node --test tests/ui_extension_permission_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { formatCountdown, parseTimeMs, summarizePermissionInput } from '../src/ui/components/extension/permissionCardModel.ts';

test('input summary: Bash command with its description', () => {
  const s = summarizePermissionInput('Bash', { command: 'npm test', description: 'Run tests' });
  assert.equal(s.kind, 'command');
  assert.equal(s.text, 'npm test');
  assert.equal(s.detail, 'Run tests');
  assert.equal(s.diff, null);
});

test('input summary: Edit shows the file path and an old/new diff', () => {
  const s = summarizePermissionInput('Edit', { file_path: '/repo/a.ts', old_string: 'let a = 1', new_string: 'let a = 2' });
  assert.equal(s.kind, 'file');
  assert.equal(s.text, '/repo/a.ts');
  assert.deepEqual(s.diff, { filePath: '/repo/a.ts', original: 'let a = 1', modified: 'let a = 2', wholeFile: false });
});

test('input summary: Write is a whole-file diff, MultiEdit joins its edits', () => {
  const w = summarizePermissionInput('Write', { file_path: '/repo/new.md', content: '# hi' });
  assert.equal(w.diff?.wholeFile, true);
  assert.equal(w.diff?.modified, '# hi');
  const m = summarizePermissionInput('MultiEdit', { file_path: '/r/x', edits: [{ old_string: 'a', new_string: 'b' }, { old_string: 'c', new_string: 'd' }] });
  assert.equal(m.diff?.original, 'a\n…\nc');
  assert.equal(m.diff?.modified, 'b\n…\nd');
});

test('input summary: url, pattern and generic JSON fallbacks', () => {
  assert.equal(summarizePermissionInput('WebFetch', { url: 'https://x.dev' }).kind, 'url');
  assert.equal(summarizePermissionInput('Grep', { pattern: 'TODO', path: 'src' }).detail, 'src');
  assert.equal(summarizePermissionInput('mcp__x', { a: 1 }).text, '{"a":1}');
  assert.equal(summarizePermissionInput('Thing', {}).text, 'Thing (no input)');
});

test('countdown formatting and time parsing', () => {
  assert.equal(formatCountdown(61.9), '1:01');
  assert.equal(formatCountdown(-5), '0:00');
  assert.ok(Number.isNaN(parseTimeMs('')));
  assert.equal(parseTimeMs('2026-10-22T07:00:00Z'), Date.parse('2026-10-22T07:00:00Z'));
});
