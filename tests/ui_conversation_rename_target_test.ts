import { test } from 'node:test';
import assert from 'node:assert/strict';

test('REQ-CR-1: a chain-bound conversation renames the task chain, seeded with the decrypted title', async () => {
  const { resolveRenameTarget } = await import('../src/ui/components/workbench/renameTarget.ts');

  const target = resolveRenameTarget({
    chainId: 'chain_123',
    decryptedChainTitle: '  Composer margin in narrow panes ',
    conversationTitle: 'Coordinator chat',
  });

  assert.equal(target.kind, 'chain');
  assert.equal(target.seed, 'Composer margin in narrow panes');
  assert.equal(target.saveLabel, 'Save chain title');
  assert.equal(target.cancelLabel, 'Cancel chain title edit');
});

test('REQ-CR-1: an unreadable vault chain title never seeds the field with a mask or ciphertext', async () => {
  const { resolveRenameTarget } = await import('../src/ui/components/workbench/renameTarget.ts');

  const target = resolveRenameTarget({
    chainId: 'chain_123',
    decryptedChainTitle: 'vault:v2:abc:e4:ciphertext',
    chainTitleUnreadable: true,
    conversationTitle: 'Coordinator chat',
  });

  assert.equal(target.kind, 'chain');
  assert.equal(target.seed, '');
});

test('REQ-CR-1: a conversation without a chain still renames the conversation', async () => {
  const { resolveRenameTarget } = await import('../src/ui/components/workbench/renameTarget.ts');

  for (const chainId of [undefined, null, '', '   ']) {
    const target = resolveRenameTarget({
      chainId,
      decryptedChainTitle: 'Stale chain title',
      conversationTitle: 'Coordinator chat',
    });
    assert.equal(target.kind, 'conversation');
    assert.equal(target.seed, 'Coordinator chat');
    assert.equal(target.saveLabel, 'Save conversation title');
    assert.equal(target.cancelLabel, 'Cancel title edit');
  }
});
