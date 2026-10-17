// Task System v2 UI: task text boxes with pasted/attached files (plan REQ-UI-10).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_task_v2_composer_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildComposerBody, composerSendState, type ComposerAttachment } from '../src/ui/components/tasks/taskComposer.ts';

const att = (status: ComposerAttachment['status'], link = ''): ComposerAttachment => ({
  localId: `a_${status}_${link}`,
  name: 'screenshot.png',
  status,
  link,
  error: status === 'error' ? 'boom' : '',
});

test('the sent body is the text plus one artifact link per finished upload', () => {
  assert.equal(buildComposerBody('  looks off on mobile  ', [att('uploaded', 'artifact://a1'), att('uploaded', 'artifact://a2')]), 'looks off on mobile\nartifact://a1\nartifact://a2');
  // unfinished or failed uploads never leak into the body
  assert.equal(buildComposerBody('note', [att('uploading'), att('error')]), 'note');
  // an image alone is a valid comment
  assert.equal(buildComposerBody('', [att('uploaded', 'artifact://a3')]), 'artifact://a3');
});

test('send is locked while uploading or after a failure, with the reason in words', () => {
  assert.deepEqual(composerSendState('hi', [att('uploading')]), { canSend: false, uploading: true, failed: false, hint: 'Waiting for uploads to finish' });
  assert.deepEqual(composerSendState('hi', [att('error')]), { canSend: false, uploading: false, failed: true, hint: 'Retry or remove the failed upload first' });
  assert.equal(composerSendState('', []).canSend, false);
  assert.equal(composerSendState('', []).hint, '');
  assert.equal(composerSendState('hi', [att('uploaded', 'artifact://x')]).canSend, true);
  assert.equal(composerSendState('', [att('uploaded', 'artifact://x')]).canSend, true);
});

test('request changes needs words, not just a screenshot', () => {
  const s = composerSendState('', [att('uploaded', 'artifact://x')], true);
  assert.equal(s.canSend, false);
  assert.equal(s.hint, 'Write what needs to change first');
  assert.equal(composerSendState('fix the padding', [att('uploaded', 'artifact://x')], true).canSend, true);
});

test('comment text drops artifact links that render as previews below', async () => {
  const { stripArtifactLinks } = await import('../src/ui/utils/artifactUpload.ts');
  assert.equal(stripArtifactLinks('Padding looks off here\nartifact://art_18df41a5518ea501'), 'Padding looks off here');
  assert.equal(stripArtifactLinks('see artifact://art_1 and artifact://art_2.'), 'see  and .');
  assert.equal(stripArtifactLinks('a\n\nartifact://x\n\n\nb'), 'a\n\nb');
  assert.equal(stripArtifactLinks('artifact://only'), '');
});
