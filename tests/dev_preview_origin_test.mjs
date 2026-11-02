// scripts/lib/preview-origin.mjs: the preview relays vouch for the preview origin
// (and nothing else) so ham-dev-proxy attaches its brokered session.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createPreviewOriginGate, originOf, rewritePreviewOrigin } from '../scripts/lib/preview-origin.mjs';

const PREVIEW = 'https://heimdall-preview.example';
const RELAY = 'http://127.0.0.1:45180';

test('originOf keeps scheme, host and port only', () => {
  assert.equal(originOf('https://Heimdall-Preview.example/p/sh_1/#/'), PREVIEW);
  assert.equal(originOf('http://127.0.0.1:8080/x'), 'http://127.0.0.1:8080');
  assert.equal(originOf('not a url'), '');
  assert.equal(originOf(''), '');
});

test('only an exact preview-origin match is rewritten', () => {
  assert.equal(rewritePreviewOrigin({ origin: PREVIEW }, PREVIEW, RELAY).origin, RELAY);
  assert.equal(rewritePreviewOrigin({ Origin: `${PREVIEW}/` }, PREVIEW, RELAY).Origin, RELAY);
  assert.equal(rewritePreviewOrigin({ origin: 'https://evil.example' }, PREVIEW, RELAY).origin, 'https://evil.example');
  assert.equal(rewritePreviewOrigin({ origin: `${PREVIEW}.evil.example` }, PREVIEW, RELAY).origin, `${PREVIEW}.evil.example`);
  assert.equal(rewritePreviewOrigin({ origin: 'null' }, PREVIEW, RELAY).origin, 'null');
  assert.equal(rewritePreviewOrigin({ origin: PREVIEW }, '', RELAY).origin, PREVIEW);
});

test('the gate learns the preview origin from the launcher file once it appears', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'preview-origin-'));
  const file = path.join(dir, 'url');
  const gate = createPreviewOriginGate({ port: 45180, previewUrlFile: file });
  assert.equal(gate.relayOrigin, RELAY);
  // No Origin header: nothing to do, and no lookup is spent.
  assert.deepEqual(gate.rewrite({ accept: '*/*' }), { accept: '*/*' });
  fs.writeFileSync(file, `${PREVIEW}/p/sh_1/\n`);
  assert.equal(gate.rewrite({ origin: PREVIEW }).origin, RELAY);
  assert.equal(gate.rewrite({ origin: 'https://evil.example' }).origin, 'https://evil.example');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('an explicit preview URL wins without any lookup', () => {
  const gate = createPreviewOriginGate({ port: 45180, previewUrl: `${PREVIEW}/p/sh_1/` });
  assert.equal(gate.previewOrigin(), PREVIEW);
  assert.equal(gate.rewrite({ origin: PREVIEW }).origin, RELAY);
});
