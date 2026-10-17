// Task System v2 UI: no emojis or decorative glyphs in the task screens.
//
// The v2 views use text labels and the @ui Icon primitive instead of pictographs
// (user requirement, plan REQ-UI-3). This gate scans the in-scope files with
// comments stripped and fails on any non-ASCII character outside a small
// typographic allowlist, so a reintroduced ✓ / ⏱ / ▸ / emoji fails loudly.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_task_v2_glyph_gate_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const REPO_ROOT = path.resolve(import.meta.dirname, '..');

export const GATE_FILES = [
  'src/ui/components/tasks/TicketBoardView.tsx',
  'src/ui/components/tasks/TaskSummaryBar.tsx',
  'src/ui/components/tasks/TaskCard.tsx',
  'src/ui/components/tasks/TaskDetails.tsx',
  'src/ui/components/tasks/HolderName.tsx',
  'src/ui/components/tasks/taskActions.ts',
  'src/ui/components/tasks/useTaskActions.ts',
  'src/ui/components/tasks/taskNames.ts',
  'src/ui/components/tasks/taskEvents.ts',
  'src/ui/components/tasks/WorkflowPipelineView.tsx',
  'src/ui/components/tasks/CreateTaskModal.tsx',
  'src/ui/components/tasks/FleetManagementDrawer.tsx',
  'src/ui/components/tasks/taskV2Types.ts',
  'src/ui/components/taskchain/TaskChainOverview.tsx',
  'src/ui/components/taskchain/TaskChainsPage.tsx',
];

// Typographic punctuation and math that read as text, not as pictographs.
export const ALLOWED_NON_ASCII = new Set(['·', '—', '–', '…', '≤', '≥', '’', '“', '”']);

/**
 * Removes `//` and `/* *\/` comments while leaving string and template literal
 * contents intact (so `'https://…'` is not mistaken for a comment). Newlines are
 * kept so reported line numbers match the source.
 */
export function stripComments(src: string): string {
  let out = '';
  let i = 0;
  let quote: string | null = null;
  while (i < src.length) {
    const c = src[i];
    const next = src[i + 1];
    if (quote) {
      out += c;
      if (c === '\\') {
        out += next ?? '';
        i += 2;
        continue;
      }
      if (c === quote) quote = null;
      i += 1;
      continue;
    }
    if (c === '"' || c === "'" || c === '`') {
      quote = c;
      out += c;
      i += 1;
      continue;
    }
    if (c === '/' && next === '/') {
      while (i < src.length && src[i] !== '\n') i += 1;
      continue;
    }
    if (c === '/' && next === '*') {
      i += 2;
      while (i < src.length && !(src[i] === '*' && src[i + 1] === '/')) {
        if (src[i] === '\n') out += '\n';
        i += 1;
      }
      i += 2;
      continue;
    }
    out += c;
    i += 1;
  }
  return out;
}

export function findForbiddenGlyphs(src: string): { line: number; char: string }[] {
  const hits: { line: number; char: string }[] = [];
  stripComments(src)
    .split('\n')
    .forEach((text, idx) => {
      for (const ch of text) {
        if (ch.codePointAt(0)! > 0x7f && !ALLOWED_NON_ASCII.has(ch)) hits.push({ line: idx + 1, char: ch });
      }
    });
  return hits;
}

test('stripComments keeps // inside string literals and drops real comments', () => {
  const src = [
    "const url = 'https://example.com'; // ✓ trailing comment",
    'const t = `a // b ${x}`;',
    '/* block ✓',
    '   comment */ const y = "x";',
  ].join('\n');
  const stripped = stripComments(src);
  assert.ok(stripped.includes("'https://example.com'"));
  assert.ok(stripped.includes('`a // b ${x}`'));
  assert.ok(!stripped.includes('✓'));
  assert.equal(stripped.split('\n').length, 4, 'line count preserved');
});

test('findForbiddenGlyphs flags pictographs and allows typographic punctuation', () => {
  assert.deepEqual(findForbiddenGlyphs("const a = 'Run complete — 3 of 5 …';"), []);
  assert.deepEqual(findForbiddenGlyphs("const a = '✓ verified';").map((h) => h.char), ['✓']);
  assert.deepEqual(findForbiddenGlyphs('<span>👤</span>').map((h) => h.char), ['👤']);
});

test('Task v2 screens contain no emojis or decorative glyphs', () => {
  const offenders: string[] = [];
  for (const rel of GATE_FILES) {
    const src = fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');
    for (const hit of findForbiddenGlyphs(src)) offenders.push(`${rel}:${hit.line} ${JSON.stringify(hit.char)}`);
  }
  assert.deepEqual(offenders, [], `use text labels or @ui Icon instead:\n${offenders.join('\n')}`);
});
