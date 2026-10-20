import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import type { ShellSession } from '../src/ui/api/endpoints/shells.ts';
import {
  openPreviewInNewTab,
  previewBlockedText,
  type PreviewTabHandle,
} from '../src/ui/components/shells/shellModel.ts';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (rel: string) => fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');

function session(over: Partial<ShellSession> = {}): ShellSession {
  return {
    session_id: 'sh_abc',
    kind: 'server',
    status: 'running',
    server_port: 5173,
    preview_url: '',
    ...over,
  } as ShellSession;
}

/** A fake window.open that records the call and returns a tab whose writes are observable. */
function fakeOpen(blocked = false) {
  const calls: Array<{ url: string; target: string }> = [];
  const tab: PreviewTabHandle & { replaced: string[]; openerAtNavigate: unknown } = {
    opener: { parent: 'the heimdall ui' },
    replaced: [],
    openerAtNavigate: 'unset',
    location: {
      replace(url: string) {
        tab.openerAtNavigate = tab.opener;
        tab.replaced.push(url);
      },
    },
  };
  const open = (url: string, target: string) => {
    calls.push({ url, target });
    return blocked ? null : tab;
  };
  return { open, calls, tab };
}

test('openPreviewInNewTab opens the hub-supplied preview_url in a new tab', () => {
  const { open, calls, tab } = fakeOpen();
  const url = 'https://preview.example.test/p/sh_abc/';
  const result = openPreviewInNewTab(session({ preview_url: url }), open);
  assert.deepEqual(result, { opened: true, url });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].target, '_blank');
  assert.deepEqual(tab.replaced, [url]);
});

test('openPreviewInNewTab falls back to /api/v1/preview/<sid>/ without a preview_url', () => {
  const { open, tab } = fakeOpen();
  const result = openPreviewInNewTab(session({ session_id: 'sh_x/y', preview_url: '' }), open);
  assert.equal(result.opened, true);
  // No window in node, so the origin is empty and the path is the whole URL.
  assert.equal(result.url, '/api/v1/preview/sh_x%2Fy/');
  assert.deepEqual(tab.replaced, ['/api/v1/preview/sh_x%2Fy/']);
});

test('openPreviewInNewTab is noopener: the opener is cut before the preview loads', () => {
  const { open, tab } = fakeOpen();
  openPreviewInNewTab(session({ preview_url: 'https://preview.example.test/' }), open);
  assert.equal(tab.opener, null);
  assert.equal(tab.openerAtNavigate, null, 'opener must be null at the moment of navigation');
});

test('openPreviewInNewTab reports a blocked popup and still returns the URL', () => {
  const { open } = fakeOpen(true);
  const url = 'https://preview.example.test/p/sh_abc/';
  const result = openPreviewInNewTab(session({ preview_url: url }), open);
  assert.deepEqual(result, { opened: false, url });
  assert.match(previewBlockedText(url), /blocked/);
  assert.ok(previewBlockedText(url).includes(url), 'the blocked notice carries the URL');
});

const OFF_WORKSPACE_FILES = [
  'src/ui/components/shells/ShellDetail.tsx',
  'src/ui/components/shells/ShellListPage.tsx',
  'src/ui/components/shells/ChainActiveServersPanel.tsx',
];

test('off-workspace surfaces open the preview in a new tab, not the aux dock', () => {
  for (const rel of OFF_WORKSPACE_FILES) {
    const src = read(rel);
    assert.ok(!/\bopenPreviewInAux\b/.test(src), `${rel} must not use openPreviewInAux`);
    assert.ok(/\bopenPreviewInNewTab\(/.test(src), `${rel} must call openPreviewInNewTab`);
  }
  // In-workspace callers still rely on it, so it must stay.
  assert.ok(/export const openPreviewInAux\b|export function openPreviewInAux\b/.test(read('src/ui/store/auxPanesSlice.ts')));
});

