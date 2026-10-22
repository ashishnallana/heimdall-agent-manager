// Permission approval card (REQ-EXT-PERM-1, UI): request normalisation, the
// input summary (command / file path / diff), the expiry countdown, and the
// reducer that keeps cards live across fetches, realtime frames and the card's
// own Allow / Deny round trip. Source checks cover the API and realtime wiring.
//
// RUN: node --test tests/ui_extension_permission_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

import {
  formatCountdown,
  initialPermissionCardsState,
  normalizePermissionRequest,
  normalizePermissionRequests,
  permissionCardView,
  permissionCardsReducer,
  permissionRealtimeFromSummary,
  summarizePermissionInput,
  visiblePermissionRequests,
  type PermissionRequest,
} from '../src/ui/components/extension/permissionCardModel.ts';

const NOW = Date.parse('2026-10-22T07:00:00Z');

function req(id: string, extra: Record<string, unknown> = {}): PermissionRequest {
  return normalizePermissionRequest({
    id, instance_id: 'inst_1', tool_name: 'Bash', status: 'pending',
    created_at: '2026-10-22T06:59:00Z', expires_at: '2026-10-22T07:05:00Z',
    input: { command: 'rm -rf build', description: 'Clean build' }, ...extra,
  })!;
}

test('normalisation drops rows without an id and sorts by creation time', () => {
  const rows = normalizePermissionRequests({ permission_requests: [
    { id: 'b', created_at: '2026-10-22T06:59:10Z' }, { created_at: 'x' }, { id: 'a', created_at: '2026-10-22T06:59:00Z', status: 'bogus' },
  ] });
  assert.deepEqual(rows.map((r) => r.id), ['a', 'b']);
  assert.equal(rows[0].status, 'pending');
  assert.deepEqual(rows[0].input, {});
});

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

test('countdown ticks down and expires the card', () => {
  const r = req('p1');
  const live = permissionCardView(r, NOW);
  assert.equal(live.phase, 'pending');
  assert.equal(live.secondsLeft, 300);
  assert.equal(live.countdown, '5:00');
  assert.equal(live.canDecide, true);
  const late = permissionCardView(r, Date.parse('2026-10-22T07:05:00Z'));
  assert.equal(late.phase, 'expired');
  assert.equal(late.canDecide, false);
  assert.equal(formatCountdown(61.9), '1:01');
});

test('closed requests show their outcome and cannot be decided', () => {
  const v = permissionCardView(req('p1', { status: 'allowed', decided_by: 'tanmay' }), NOW);
  assert.equal(v.canDecide, false);
  assert.equal(v.statusLabel, 'Allowed by tanmay');
  assert.equal(permissionCardView(req('p2', { status: 'cancelled' }), NOW).statusLabel, 'Cancelled');
});

test('reducer: Allow round trip marks submitting then resolves the card', () => {
  let s = permissionCardsReducer(initialPermissionCardsState, { type: 'loaded', requests: [req('p1')] });
  s = permissionCardsReducer(s, { type: 'decision_started', id: 'p1', decision: 'allow' });
  assert.equal(s.submitting.p1, 'allow');
  s = permissionCardsReducer(s, { type: 'decision_succeeded', id: 'p1', decision: 'allow', request: null });
  assert.equal(s.requests[0].status, 'allowed');
  assert.equal(s.submitting.p1, undefined);
});

test('reducer: a failed decision keeps the card pending with an error', () => {
  let s = permissionCardsReducer(initialPermissionCardsState, { type: 'loaded', requests: [req('p1')] });
  s = permissionCardsReducer(s, { type: 'decision_started', id: 'p1', decision: 'deny' });
  s = permissionCardsReducer(s, { type: 'decision_failed', id: 'p1', error: 'conflict' });
  assert.equal(s.requests[0].status, 'pending');
  assert.equal(s.errors.p1, 'conflict');
  assert.equal(s.submitting.p1, undefined);
});

test('reducer: realtime frames add, resolve and never reopen a request', () => {
  let s = permissionCardsReducer(initialPermissionCardsState, { type: 'realtime', action: 'created', request: req('p1') });
  assert.equal(s.requests.length, 1);
  s = permissionCardsReducer(s, { type: 'decision_started', id: 'p1', decision: 'allow' });
  s = permissionCardsReducer(s, { type: 'realtime', action: 'decided', request: req('p1', { status: 'denied', decided_at: '2026-10-22T07:00:00Z' }) });
  assert.equal(s.requests[0].status, 'denied');
  assert.equal(s.submitting.p1, undefined, 'a decision from elsewhere clears our spinner');
  // A late 'created' replay or stale refetch must not flip it back to pending.
  s = permissionCardsReducer(s, { type: 'realtime', action: 'created', request: req('p1') });
  assert.equal(s.requests[0].status, 'denied');
  s = permissionCardsReducer(s, { type: 'loaded', requests: [req('p1')] });
  assert.equal(s.requests[0].status, 'denied');
});

test('reducer: a pending request missing from a refetch is dropped', () => {
  let s = permissionCardsReducer(initialPermissionCardsState, { type: 'loaded', requests: [req('p1'), req('p2')] });
  s = permissionCardsReducer(s, { type: 'loaded', requests: [req('p2')] });
  assert.deepEqual(s.requests.map((r) => r.id), ['p2']);
});

test('visible cards: pending plus recently closed ones only', () => {
  let s = permissionCardsReducer(initialPermissionCardsState, { type: 'loaded', requests: [req('p1'), req('p2')] });
  s = permissionCardsReducer(s, { type: 'realtime', action: 'decided', request: req('p2', { status: 'allowed', decided_at: '2026-10-22T06:59:58Z' }) });
  assert.deepEqual(visiblePermissionRequests(s, NOW).map((r) => r.id), ['p1', 'p2']);
  assert.deepEqual(visiblePermissionRequests(s, NOW + 60_000).map((r) => r.id), ['p1']);
});

test('realtime summary parsing', () => {
  const parsed = permissionRealtimeFromSummary({ action: 'closed', permission_request: { id: 'p9', status: 'expired' } });
  assert.equal(parsed?.action, 'closed');
  assert.equal(parsed?.request.status, 'expired');
  assert.equal(permissionRealtimeFromSummary({ action: 'x' }), null);
});

const root = fileURLToPath(new URL('..', import.meta.url));
const read = (p: string) => fs.readFileSync(`${root}/${p}`, 'utf8');

test('API posts decisions and realtime frames patch the permission caches', () => {
  const api = read('src/ui/api/endpoints/extension.ts');
  assert.match(api, /\/permission-requests\/\$\{encodeURIComponent\(id\)\}\/decision/);
  assert.match(api, /'PermissionRequests'/);
  const ws = read('src/ui/api/wsInvalidation.ts');
  assert.match(ws, /'permission_requests'/);
  assert.match(ws, /applyPermissionRealtime/);
  assert.match(ws, /'extension_events'/);
});

test('cards render in the conversation and the attention surface', () => {
  assert.match(read('src/ui/components/workbench/AgentChatPane.tsx'), /<InstancePermissionCards/);
  assert.match(read('src/ui/components/attention/AttentionDeck.tsx'), /<PendingPermissionCards/);
});
