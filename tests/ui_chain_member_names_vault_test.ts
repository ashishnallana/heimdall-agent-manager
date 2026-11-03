// Chain member display names may be vault text: MCP chains.create stores the
// sealed chain title as the coordinator instance's display_name, and an
// MCP-created agent's sealed name prefixes the default "<name> #n". The chain
// detail query must open them and the Chain Agents panel must never render
// ciphertext.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_chain_member_names_vault_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  installFetchCapture,
  installWindowShim,
  makeVaultStore,
  unlockVault,
  lockVaultFully,
  clearActiveKey,
} from './helpers/vaultEndpointHarness.ts';
import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { encryptVaultText } from '../src/ui/utils/vaultContent.ts';
import { decryptChainMembers, decryptChainRecord } from '../src/ui/utils/vaultChains.ts';

const KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const KEYRING = await keyringFromHex(KEY_HEX);
const TITLE = 'Redesign the new conversation page';
const SEALED_TITLE = await encryptVaultText(TITLE, KEYRING);
const SEALED_AGENT = await encryptVaultText('planner', KEYRING);

test('decryptChainMembers opens whole and embedded tokens and keeps plaintext', async () => {
  const members = [
    { agent_instance_id: 'inst_mcp', display_name: SEALED_TITLE },
    { agentInstanceId: 'inst_counter', displayName: `${SEALED_AGENT} #3` },
    { agent_instance_id: 'inst_plain', display_name: 'coordinator #7' },
  ];
  const out = await decryptChainMembers(members, KEYRING);
  assert.equal(out[0].display_name, TITLE);
  assert.equal(out[1].displayName, 'planner #3');
  assert.equal(out[2].display_name, 'coordinator #7');
  assert.equal(members[0].display_name, SEALED_TITLE, 'input is not mutated');

  await clearActiveKey();
  assert.deepEqual(await decryptChainMembers(members, null), members, 'no key: unchanged');
});

test('decryptChainRecord also opens member names (getTaskChain path)', async () => {
  const chain = await decryptChainRecord(
    { title: SEALED_TITLE, members: [{ agent_instance_id: 'inst_mcp', display_name: SEALED_TITLE }] },
    KEYRING,
  );
  assert.equal(chain.title, TITLE);
  assert.equal(chain.members[0].display_name, TITLE);
});

test('fetchTaskChainDetail opens member names before they are copied into task refs', async () => {
  const cap = installFetchCapture();
  installWindowShim();
  const store = await makeVaultStore();
  const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
  try {
    await unlockVault(store, KEY_HEX);
    cap.setNextResponse({
      data: {
        chain_id: 'chain_mcp',
        title: SEALED_TITLE,
        members: [{ agent_instance_id: 'inst_mcp', agent_id: 'agt_c', role: 'coordinator', display_name: SEALED_TITLE }],
        tasks: [{ task_id: 'task_1', title: 'T', assignee_ref: { agent_instance_id: 'inst_mcp' } }],
      },
    });
    const res = await store.dispatch(
      tasksApi.endpoints.fetchTaskChainDetail.initiate({ chainId: 'chain_mcp' }, { subscribe: false, forceRefetch: true }),
    );
    assert.ok(!res?.error, `fetchTaskChainDetail failed: ${JSON.stringify(res?.error)}`);
    const chain = res.data.chain;
    assert.equal(chain.title, TITLE);
    assert.equal(chain.members[0].displayName, TITLE);
    assert.doesNotMatch(JSON.stringify(chain), /vault:v2:/, 'no ciphertext anywhere in the normalized chain');
  } finally {
    await lockVaultFully(store);
  }
});

test('Chain Agents panel masks a member name it cannot open', async () => {
  installWindowShim();
  const React = (await import('react')).default;
  const { Provider } = await import('react-redux');
  const { renderToStaticMarkup } = await import('react-dom/server');
  const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
  const ChainOverviewPanel = (await import('../src/ui/components/chat/ChainOverviewPanel.tsx')).default;
  await clearActiveKey();
  const store = await makeVaultStore();
  await store.dispatch(
    tasksApi.util.upsertQueryData('fetchTaskChainDetail', { chainId: 'chain_mcp' }, {
      chain: {
        chain_id: 'chain_mcp',
        members: [{ agentInstanceId: 'inst_mcp', displayName: SEALED_TITLE, runtimeStatus: 'running' }],
        tasks: [],
      },
    }),
  );
  const html = renderToStaticMarkup(
    React.createElement(Provider, {
      store,
      children: React.createElement(ChainOverviewPanel, { chainId: 'chain_mcp', projectId: '', projectVcsEnabled: false }),
    }),
  );
  store.dispatch(tasksApi.util.resetApiState());
  assert.match(html, /data-debug-id="chain-overview-agent-row-inst_mcp"/);
  assert.doesNotMatch(html, /vault:v2:/, 'ciphertext must not reach the DOM (text or title attribute)');
  assert.match(html, /Encrypted/);
});
