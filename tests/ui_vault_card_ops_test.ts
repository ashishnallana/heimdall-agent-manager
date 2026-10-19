// Card operations seal the content the hub only stores (src/ui/utils/vaultCardOps.ts).
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_vault_card_ops_test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { setActiveVaultKey } from '../src/ui/utils/vaultCrypto.ts';
import { openCardOperations, sealCardOperations } from '../src/ui/utils/vaultCardOps.ts';

test('issue/memory content is sealed; executed fields stay in clear; display decrypts', async () => {
  setActiveVaultKey(await keyringFromHex('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'));
  try {
    const ops = [
      { op: 'issue.create', title: 'leak me', description: 'secret', scope: 'global' },
      { op: 'memory.approve', memory_id: 'mem_1' },
      { op: 'memory.create', args: { title: 't', body: 'b', type: 'fact' } },
    ];
    const sealed = (await sealCardOperations(ops))!;
    const wire = JSON.stringify(sealed);
    assert.ok(!wire.includes('leak me') && !wire.includes('"secret"'));
    assert.equal(sealed[0].scope, 'global');
    assert.equal(sealed[1].memory_id, 'mem_1');
    assert.equal((sealed[2].args as any).type, 'fact');
    assert.deepEqual(await openCardOperations(sealed), ops);
  } finally {
    setActiveVaultKey(null);
  }
  await assert.rejects(sealCardOperations([{ op: 'issue.create', title: 'x' }]), /Vault key unavailable/);
});
