// MCP chains.create keeps the native coordinator name "<agent name> #n". For an
// MCP-created agent the name is sealed, so instance labels and the coordinator
// conversation title are "<token> #3": a token followed by plaintext. Every label
// path must open that as embedded text, not as one whole envelope (which throws and
// left ciphertext or a locked mask), and must never paint ciphertext when locked.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_native_coordinator_name_vault_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import {
  installFetchCapture,
  installWindowShim,
  makeVaultStore,
  unlockVault,
  lockVaultFully,
  clearActiveKey,
} from './helpers/vaultEndpointHarness.ts';
import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import {
  encryptVaultText,
  decryptVaultLabel,
  isVaultArmored,
  isWholeVaultArmored,
} from '../src/ui/utils/vaultContent.ts';
import { decryptConversationRecord } from '../src/ui/utils/vaultChats.ts';

const KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const KEYRING = await keyringFromHex(KEY_HEX);
const SEALED_AGENT = await encryptVaultText('planner', KEYRING);
const NATIVE_NAME = `${SEALED_AGENT} #3`;

test('isWholeVaultArmored: exact token or malformed armor only, never "<token> #3"', () => {
  assert.equal(isWholeVaultArmored(SEALED_AGENT), true);
  assert.equal(isWholeVaultArmored('vault:v2:not-a-token'), true, 'malformed armor still fails closed via the whole path');
  assert.equal(isVaultArmored(NATIVE_NAME), true, 'the prefix test alone cannot tell them apart');
  assert.equal(isWholeVaultArmored(NATIVE_NAME), false);
  assert.equal(isWholeVaultArmored(`a ${SEALED_AGENT}`), false);
  assert.equal(isWholeVaultArmored('coordinator #7'), false);
  assert.equal(isWholeVaultArmored(undefined), false);
});

test('decryptVaultLabel opens whole, embedded and plain labels; bad whole token throws', async () => {
  assert.equal(await decryptVaultLabel(SEALED_AGENT, KEYRING), 'planner');
  assert.equal(await decryptVaultLabel(NATIVE_NAME, KEYRING), 'planner #3');
  assert.equal(await decryptVaultLabel('coordinator #7', KEYRING), 'coordinator #7');
  await assert.rejects(decryptVaultLabel('vault:v2:not-a-token', KEYRING));
});

test('conversation title and agent name "<token> #3" decrypt to "planner #3"', async () => {
  const conv = {
    conversationId: 'chat_c',
    title: NATIVE_NAME,
    agentName: NATIVE_NAME,
    agent_display_name: NATIVE_NAME,
    lastMessagePreview: `${SEALED_AGENT} #3: hello`,
  };
  const out = await decryptConversationRecord(conv, KEYRING);
  assert.equal(out.title, 'planner #3');
  assert.equal(out.agentName, 'planner #3');
  assert.equal(out.agent_display_name, 'planner #3');
  assert.equal(out.lastMessagePreview, 'planner #3: hello');
  assert.equal(conv.title, NATIVE_NAME, 'input is not mutated');

  // Whole-token titles (pre-change MCP coordinators, sealed chain titles) still open.
  const whole = await decryptConversationRecord({ title: SEALED_AGENT }, KEYRING);
  assert.equal(whole.title, 'planner');
  assert.equal('agentName' in whole, false, 'absent agent fields are not invented');
});

test('agents live tree opens chain titles and agent/member names', async () => {
  const { decryptLiveProjects } = await import('../src/ui/api/endpoints/agentsLive.ts');
  const sealedTitle = await encryptVaultText('Redesign', KEYRING);
  const [p] = await decryptLiveProjects([{
    projectId: 'proj_a', name: 'plain project',
    chains: [{
      chainId: 'chain_a', title: sealedTitle, coordinatorAgentInstanceId: 'inst_c',
      liveAgents: [{ agentInstanceId: 'inst_c', displayName: NATIVE_NAME, isCoordinator: true, runtimeStatus: 'running', activityStatus: '', projectId: 'proj_a', createdAt: '' }],
      members: [{ agentInstanceId: 'inst_c', displayName: NATIVE_NAME, role: 'coordinator', isCoordinator: true, isLive: true, runtimeStatus: 'running', projectId: 'proj_a', createdAt: '' }],
    }],
  }], KEYRING);
  assert.equal(p.name, 'plain project');
  assert.equal(p.chains[0].title, 'Redesign');
  assert.equal(p.chains[0].liveAgents[0].displayName, 'planner #3');
  assert.equal(p.chains[0].members[0].displayName, 'planner #3');
  assert.equal(p.chains[0].liveAgents[0].isCoordinator, true);
});

test('agents live query decrypts sealed native names when unlocked', async () => {
  const cap = installFetchCapture();
  installWindowShim();
  const store = await makeVaultStore();
  const { agentsLiveApi } = await import('../src/ui/api/endpoints/agentsLive.ts');
  try {
    await unlockVault(store, KEY_HEX);
    cap.setNextResponse({
      projects: [{ project_id: 'proj_a', name: 'p', chains: [{ chain_id: 'chain_a', title: 't', live_agents: [{ agent_instance_id: 'inst_c', display_name: NATIVE_NAME }], members: [] }] }],
    });
    const res: any = await store.dispatch(agentsLiveApi.endpoints.getAgentsLive.initiate(undefined, { subscribe: false, forceRefetch: true }));
    assert.ok(!res?.error, `getAgentsLive failed: ${JSON.stringify(res?.error)}`);
    assert.equal(res.data[0].chains[0].liveAgents[0].displayName, 'planner #3');
  } finally {
    await lockVaultFully(store);
  }
});

async function withDom<T>(fn: (doc: Document) => Promise<T>): Promise<T> {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/' });
  const prev = { window: (globalThis as any).window, document: (globalThis as any).document, HTMLElement: (globalThis as any).HTMLElement };
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  try {
    return await fn(dom.window.document);
  } finally {
    dom.window.close();
    (globalThis as any).window = prev.window;
    (globalThis as any).document = prev.document;
    (globalThis as any).HTMLElement = prev.HTMLElement;
  }
}

async function renderVaultText(store: any, value: string): Promise<string> {
  const { createRoot } = await import('react-dom/client');
  const { Provider } = await import('react-redux');
  const { VaultText } = await import('../src/ui/components/vault/VaultText.tsx');
  return withDom(async (doc) => {
    const root = createRoot(doc.getElementById('root')!);
    await React.act(async () => {
      root.render(React.createElement(Provider, { store, children: React.createElement(VaultText, { value }) }));
    });
    // Let the decrypt promise resolve and its state update commit.
    for (let i = 0; i < 20 && /Decrypting|vault:v2:/.test(doc.body.textContent || ''); i++) {
      await React.act(async () => { await new Promise((r) => setTimeout(r, 5)); });
    }
    const text = doc.getElementById('root')!.innerHTML;
    await React.act(async () => root.unmount());
    return text;
  });
}

test('VaultText renders "<token> #3" as "planner #3" when unlocked (not a locked mask)', async () => {
  installFetchCapture();
  installWindowShim();
  const store = await makeVaultStore();
  try {
    await unlockVault(store, KEY_HEX);
    const html = await renderVaultText(store, NATIVE_NAME);
    assert.match(html, /planner #3/);
    assert.doesNotMatch(html, /vault:v2:/);
    assert.doesNotMatch(html, /Encrypted/);
    assert.match(await renderVaultText(store, SEALED_AGENT), /planner/, 'whole token still opens');
  } finally {
    await lockVaultFully(store);
  }
});

test('VaultText masks "<token> #3" when the vault is locked, never ciphertext', async () => {
  installFetchCapture();
  installWindowShim();
  await clearActiveKey();
  const store = await makeVaultStore();
  const html = await renderVaultText(store, NATIVE_NAME);
  assert.doesNotMatch(html, /vault:v2:/);
  assert.match(html, /Encrypted/);
  assert.match(html, /#3/, 'the plaintext counter stays visible');
});
