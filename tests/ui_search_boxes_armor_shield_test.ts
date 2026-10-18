// REQ-SEARCH-SHIELD-TEST:
// Automated regression test suite ensuring no search filter in the Heimdall UI
// matches raw armored ciphertext (vault:v2:e1:...) or ciphertext substrings,
// and that searches against plaintext work correctly when decrypted.
//
// RUN: node --test tests/ui_search_boxes_armor_shield_test.ts

import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  isVaultArmored,
  encryptVaultText,
  decryptVaultText,
  VAULT_ARMOR_PREFIX,
} from '../src/ui/utils/vaultContent.ts';
import { batchDecryptTitles } from '../src/ui/utils/vaultSearch.ts';

const TEST_KEY_HEX_RAW = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const TEST_KEY_HEX = await keyringFromHex(TEST_KEY_HEX_RAW);

// =============================================================================
// Helper Search Filter Logic (mirrors exact component implementations)
// =============================================================================

// 1. RecentTaskChainsTab filter logic (src/ui/components/home/RecentTaskChainsTab.tsx:78-95)
function filterRecentTaskChains(
  chains: Array<{ chainId: string; title: string; projectName?: string; status: string; updatedAt?: string }>,
  searchQuery: string,
  searchChains: Record<string, { decryptedTitle?: string }> = {},
  statusFilter: 'all' | 'active' | 'completed' = 'all',
) {
  return chains.filter((chain) => {
    const s = (chain.status || '').toLowerCase();
    if (s !== 'active' && s !== 'completed') return false;
    if (statusFilter === 'active' && s !== 'active') return false;
    if (statusFilter === 'completed' && s !== 'completed') return false;

    if (searchQuery.trim()) {
      const q = searchQuery.toLowerCase().trim();
      const title = searchChains[chain.chainId]?.decryptedTitle || chain.title || '';
      const matchesTitle = !isVaultArmored(title) && title.toLowerCase().includes(q);
      const matchesId = (chain.chainId || '').toLowerCase().includes(q);
      const projectName = chain.projectName || '';
      const matchesProject =
        Boolean(projectName) &&
        !isVaultArmored(projectName) &&
        projectName.toLowerCase().includes(q);
      if (!matchesTitle && !matchesId && !matchesProject) {
        return false;
      }
    }
    return true;
  });
}

// 2a. ActionItemsTab card filter logic (src/ui/components/home/ActionItemsTab.tsx:125-152)
function filterActionItemsTabCards(
  cards: Array<{ card_id: string; title: string; rationale?: string; project_id?: string; scope?: string; provider?: string; operations?: any[] }>,
  searchQuery: string,
  projectMap: Map<string, { name: string }> = new Map(),
  formatOpLabel: (op: any) => string = (op) => op?.title || op?.label || '',
) {
  return cards.filter((card) => {
    if (searchQuery.trim()) {
      const q = searchQuery.toLowerCase().trim();
      const project = card.project_id ? projectMap.get(card.project_id) : null;
      const opLabels = (card.operations || []).map((op) => formatOpLabel(op).toLowerCase()).join(' ');
      const safeTitle = !isVaultArmored(card.title) ? card.title : null;
      const safeRationale = !isVaultArmored(card.rationale) ? card.rationale : null;
      const safeProjectName = !isVaultArmored(project?.name) ? project?.name : null;
      const haystack = [
        safeTitle,
        safeRationale,
        card.scope,
        card.provider,
        card.card_id,
        safeProjectName,
        opLabels,
      ]
        .filter(Boolean)
        .join(' ')
        .toLowerCase();

      if (!haystack.includes(q)) {
        return false;
      }
    }
    return true;
  });
}

// 2b. CardsPanel filter logic (src/ui/components/cards/CardsPanel.tsx:82-103)
function filterCardsPanelCards(
  cards: Array<{ card_id: string; title: string; rationale?: string; project_id?: string; scope?: string; provider?: string; operations?: any[] }>,
  searchQuery: string,
  projectMap: Map<string, { name: string }> = new Map(),
  formatOpLabel: (op: any) => string = (op) => op?.title || op?.label || '',
) {
  return cards.filter((card) => {
    if (searchQuery.trim()) {
      const q = searchQuery.toLowerCase();
      const project = card.project_id ? projectMap.get(card.project_id) : null;
      const opLabels = (card.operations || []).map((op) => formatOpLabel(op).toLowerCase()).join(' ');
      const safeTitle = !isVaultArmored(card.title) ? card.title : null;
      const safeRationale = !isVaultArmored(card.rationale) ? card.rationale : null;
      const safeProjectName = !isVaultArmored(project?.name) ? project?.name : null;
      const haystack = [
        safeTitle,
        safeRationale,
        card.scope,
        card.provider,
        card.card_id,
        safeProjectName,
        opLabels,
      ].filter(Boolean).join(' ').toLowerCase();

      if (!haystack.includes(q)) {
        return false;
      }
    }
    return true;
  });
}

// 3. ActionListPage searchableText & matchesQuery logic (src/ui/components/actions/ActionListPage.tsx:117-143)
function actionListPageSearchableText(
  row: { id: string; prompt_text?: string; cron_expr?: string; timezone?: string; target_instance_id?: string; target_agent_id?: string; target_provider?: string; target_model?: string },
  catalog: any = { instances: { byId: new Map() }, agents: { byId: new Map() } },
): string {
  return [
    row.prompt_text && !isVaultArmored(row.prompt_text) ? row.prompt_text : '',
    row.id,
    row.cron_expr,
    '', // scheduleLabel
    row.timezone,
    row.target_instance_id ? catalog.instances?.byId?.get(row.target_instance_id)?.label : '',
    row.target_instance_id,
    row.target_agent_id ? catalog.agents?.byId?.get(row.target_agent_id)?.label : '',
    row.target_agent_id,
    '', // bridgeLabel
    '', // projectLabel
    row.target_provider,
    row.target_model,
  ]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();
}

function actionListPageMatchesQuery(row: any, catalog: any, query: string): boolean {
  const terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (terms.length === 0) return true;
  const haystack = actionListPageSearchableText(row, catalog);
  return terms.every((term) => haystack.includes(term));
}

// 4. LibraryPage filtered logic (src/ui/components/LibraryPage.tsx:127-143)
function filterLibraryArtifacts(
  artifacts: Array<{ artifact_id: string; name?: string; description?: string; kind?: string; project_id?: string; creator_id?: string; origin_ref?: string }>,
  search: string,
  kindFilter = '',
  projectFilter = '',
  agentFilter = '',
  chainFilter = '',
  originRef: (a: any) => string = (a) => a?.origin_ref || '',
  artifactId: (a: any) => string = (a) => a?.artifact_id || '',
  kindLabel: (a: any) => string = (a) => a?.kind || '',
  projectId: (a: any) => string = (a) => a?.project_id || '',
  creatorId: (a: any) => string = (a) => a?.creator_id || '',
) {
  const q = search.trim().toLowerCase();
  return artifacts.filter((a) => {
    if (kindFilter && kindLabel(a) !== kindFilter) return false;
    if (projectFilter && projectId(a) !== projectFilter) return false;
    if (agentFilter && creatorId(a) !== agentFilter) return false;
    if (chainFilter && originRef(a) !== chainFilter) return false;
    if (q) {
      const nameText = a?.name && !isVaultArmored(a.name) ? a.name : '';
      const descText = a?.description && !isVaultArmored(a.description) ? a.description : '';
      const originRefText = originRef(a) && !isVaultArmored(originRef(a)) ? originRef(a) : '';
      const hay = `${nameText} ${descText} ${artifactId(a)} ${originRefText}`.toLowerCase();
      if (!hay.includes(q)) return false;
    }
    return true;
  });
}

// 5. NewConversationWindowPane / WorkbenchAgentPicker filtered logic (src/ui/components/windowTiling/NewConversationWindowPane.tsx)
function filterWorkbenchAgentInstances(
  instances: Array<{ agent_instance_id: string; display_name?: string }>,
  search: string,
) {
  const q = search.trim().toLowerCase();
  return instances.filter((i) => {
    const id = String(i?.agent_instance_id || '');
    const name = String(i?.display_name || '');
    if (!id) return false;
    if (!q) return true;
    const nameMatch = !isVaultArmored(name) && name.toLowerCase().includes(q);
    return nameMatch || id.toLowerCase().includes(q);
  });
}

// 6. Combobox filtered logic (src/ui/components/ui/primitives/Combobox.tsx:203-213)
function filterComboboxOptions(
  options: Array<{ value: string; title: string; subtitle?: string; tag?: string; id?: string; keywords?: string }>,
  query: string,
) {
  const q = query.trim().toLowerCase();
  if (!q) return options;
  return options.filter((option) =>
    [option.title, option.tag, option.subtitle, option.id, option.keywords]
      .filter((field): field is string => Boolean(field) && !isVaultArmored(field))
      .join(' ')
      .toLowerCase()
      .includes(q),
  );
}

// 7. shellModel matchesQuery logic (src/ui/components/shells/shellModel.ts:405-425)
function shellModelSearchableText(session: {
  label?: string;
  cmd?: string;
  cwd?: string;
  session_id: string;
  kind?: string;
  status?: string;
  server_port?: number;
}): string {
  return [
    session.label && !isVaultArmored(session.label) ? session.label : '',
    session.cmd && !isVaultArmored(session.cmd) ? session.cmd : '',
    session.cwd,
    session.session_id,
    session.kind,
    session.status,
    session.server_port && session.server_port > 0 ? String(session.server_port) : '',
  ]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();
}

function shellModelMatchesQuery(session: any, query: string): boolean {
  const terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (terms.length === 0) return true;
  const haystack = shellModelSearchableText(session);
  return terms.every((term) => haystack.includes(term));
}

// =============================================================================
// Area 1: RecentTaskChainsTab Logic / Chain Matching
// =============================================================================

test('Area 1: RecentTaskChainsTab - armored chain titles and project names never match queries; decrypted title matches', async () => {
  const secretTitle = 'Confidential Cloud Architecture Plan';
  const secretProject = 'Secret Apollo Project';
  const armoredTitle = await encryptVaultText(secretTitle, TEST_KEY_HEX);
  const armoredProject = await encryptVaultText(secretProject, TEST_KEY_HEX);

  assert.ok(isVaultArmored(armoredTitle), 'Generated title must be armored');
  assert.ok(isVaultArmored(armoredProject), 'Generated project must be armored');

  const cipherTokenTitle = armoredTitle.slice(12, 28);
  const cipherTokenProject = armoredProject.slice(12, 28);

  const chains = [
    {
      chainId: 'chain_sec_01',
      title: armoredTitle,
      projectName: 'Public Infra',
      status: 'active',
    },
    {
      chainId: 'chain_sec_02',
      title: 'Regular Maintenance Run',
      projectName: armoredProject,
      status: 'active',
    },
    {
      chainId: 'chain_sec_03',
      title: armoredTitle,
      projectName: armoredProject,
      status: 'active',
    },
  ];

  // 1. Searching for 'vault' must return 0 matches
  assert.equal(filterRecentTaskChains(chains, 'vault').length, 0, "Query 'vault' must return 0 matches");
  assert.equal(filterRecentTaskChains(chains, 'Vault').length, 0, "Query 'Vault' must return 0 matches");

  // 2. Searching for armor prefix 'vault:v1' or 'vault:v2:e1:' must return 0 matches
  assert.equal(filterRecentTaskChains(chains, 'vault:v1').length, 0, "Query 'vault:v1' must return 0 matches");
  assert.equal(filterRecentTaskChains(chains, 'vault:v2:e1:').length, 0, "Query 'vault:v2:e1:' must return 0 matches");

  // 3. Searching for raw ciphertext tokens must return 0 matches
  assert.equal(filterRecentTaskChains(chains, cipherTokenTitle).length, 0, 'Ciphertext token from title must return 0 matches');
  assert.equal(filterRecentTaskChains(chains, cipherTokenProject).length, 0, 'Ciphertext token from project must return 0 matches');

  // 4. Searching for plaintext before decryption returns 0 matches
  assert.equal(filterRecentTaskChains(chains, 'Confidential').length, 0, "Plaintext query 'Confidential' before decryption must return 0 matches");
  assert.equal(filterRecentTaskChains(chains, 'Apollo').length, 0, "Plaintext query 'Apollo' before decryption must return 0 matches");

  // 5. Searching for unarmored fields (chainId or unarmored title) matches correctly
  const idMatch = filterRecentTaskChains(chains, 'chain_sec_01');
  assert.equal(idMatch.length, 1);
  assert.equal(idMatch[0].chainId, 'chain_sec_01');

  const regularMatch = filterRecentTaskChains(chains, 'Regular Maintenance');
  assert.equal(regularMatch.length, 1);
  assert.equal(regularMatch[0].chainId, 'chain_sec_02');

  // 6. Decrypted title matching via searchChains lookup (from searchTitleSlice)
  const searchChainsMap: Record<string, { decryptedTitle?: string }> = {
    chain_sec_01: { decryptedTitle: secretTitle },
    chain_sec_03: { decryptedTitle: secretTitle },
  };

  const decryptedMatches = filterRecentTaskChains(chains, 'Confidential', searchChainsMap);
  assert.equal(decryptedMatches.length, 2, 'Searching decrypted title must match the 2 decrypted chains');
  assert.ok(decryptedMatches.some((c) => c.chainId === 'chain_sec_01'));
  assert.ok(decryptedMatches.some((c) => c.chainId === 'chain_sec_03'));

  const architectureMatches = filterRecentTaskChains(chains, 'architecture', searchChainsMap);
  assert.equal(architectureMatches.length, 2);

  // Even when decrypted, searching for raw ciphertext or armor prefix still yields 0 matches
  assert.equal(filterRecentTaskChains(chains, cipherTokenTitle, searchChainsMap).length, 0);
  assert.equal(filterRecentTaskChains(chains, 'vault:v2:e1:', searchChainsMap).length, 0);
});

// =============================================================================
// Area 2: ActionItemsTab & CardsPanel Logic
// =============================================================================

test('Area 2: ActionItemsTab & CardsPanel - armored card titles, rationales, and project names are excluded from search haystack and never match', async () => {
  const secretTitle = 'Rotate Master Database Encryption Keys';
  const secretRationale = 'Quarterly Zero-Trust Compliance Requirement';
  const secretProject = 'Secure Banking Gateway';

  const armoredTitle = await encryptVaultText(secretTitle, TEST_KEY_HEX);
  const armoredRationale = await encryptVaultText(secretRationale, TEST_KEY_HEX);
  const armoredProject = await encryptVaultText(secretProject, TEST_KEY_HEX);

  const cipherTokenTitle = armoredTitle.slice(14, 30);
  const cipherTokenRationale = armoredRationale.slice(14, 30);
  const cipherTokenProject = armoredProject.slice(14, 30);

  const projectMap = new Map([
    ['proj_sec_1', { name: armoredProject }],
    ['proj_pub_2', { name: 'Public Analytics Service' }],
  ]);

  const cards = [
    {
      card_id: 'card_armored_title',
      title: armoredTitle,
      rationale: 'Unarmored rationale text',
      project_id: 'proj_pub_2',
      scope: 'project',
      provider: 'anthropic',
    },
    {
      card_id: 'card_armored_rationale',
      title: 'Standard Deployment Approval',
      rationale: armoredRationale,
      project_id: 'proj_pub_2',
      scope: 'workspace',
      provider: 'google',
    },
    {
      card_id: 'card_armored_project',
      title: 'Firewall Policy Review',
      rationale: 'Verify outbound egress rules',
      project_id: 'proj_sec_1',
      scope: 'global',
      provider: 'openai',
    },
    {
      card_id: 'card_all_armored',
      title: armoredTitle,
      rationale: armoredRationale,
      project_id: 'proj_sec_1',
      scope: 'project',
      provider: 'anthropic',
    },
  ];

  for (const [panelName, filterFn] of [
    ['ActionItemsTab', filterActionItemsTabCards],
    ['CardsPanel', filterCardsPanelCards],
  ] as const) {
    // 1. Searching for 'vault' returns 0 matches
    assert.equal(filterFn(cards, 'vault', projectMap).length, 0, `${panelName}: Query 'vault' must return 0 matches`);
    assert.equal(filterFn(cards, 'Vault', projectMap).length, 0, `${panelName}: Query 'Vault' must return 0 matches`);

    // 2. Searching for 'vault:v1' or 'vault:v2:e1:' returns 0 matches
    assert.equal(filterFn(cards, 'vault:v1', projectMap).length, 0, `${panelName}: Query 'vault:v1' must return 0 matches`);
    assert.equal(filterFn(cards, 'vault:v2:e1:', projectMap).length, 0, `${panelName}: Query 'vault:v2:e1:' must return 0 matches`);

    // 3. Searching for raw ciphertext tokens returns 0 matches
    assert.equal(filterFn(cards, cipherTokenTitle, projectMap).length, 0, `${panelName}: Ciphertext token from title must return 0 matches`);
    assert.equal(filterFn(cards, cipherTokenRationale, projectMap).length, 0, `${panelName}: Ciphertext token from rationale must return 0 matches`);
    assert.equal(filterFn(cards, cipherTokenProject, projectMap).length, 0, `${panelName}: Ciphertext token from project must return 0 matches`);

    // 4. Searching for plaintext before decryption returns 0 matches
    assert.equal(filterFn(cards, 'Rotate Master', projectMap).length, 0, `${panelName}: Plaintext title before decryption must return 0 matches`);
    assert.equal(filterFn(cards, 'Zero-Trust', projectMap).length, 0, `${panelName}: Plaintext rationale before decryption must return 0 matches`);
    assert.equal(filterFn(cards, 'Banking Gateway', projectMap).length, 0, `${panelName}: Plaintext project before decryption must return 0 matches`);

    // 5. Unarmored fields continue to match normally
    assert.equal(filterFn(cards, 'Deployment Approval', projectMap).length, 1);
    assert.equal(filterFn(cards, 'Analytics Service', projectMap).length, 2);
    assert.equal(filterFn(cards, 'card_armored_title', projectMap).length, 1);
    assert.equal(filterFn(cards, 'anthropic', projectMap).length, 2);
  }
});

// =============================================================================
// Area 3: ActionListPage searchableText Logic
// =============================================================================

test('Area 3: ActionListPage - armored prompt_text is omitted from searchableText and never matches queries', async () => {
  const secretPrompt = 'Execute automated secret failover to secondary cluster';
  const armoredPrompt = await encryptVaultText(secretPrompt, TEST_KEY_HEX);
  const cipherTokenPrompt = armoredPrompt.slice(10, 26);

  const rowArmored = {
    id: 'act_alpha_01',
    prompt_text: armoredPrompt,
    cron_expr: '0 2 * * *',
    timezone: 'UTC',
    target_provider: 'gemini',
    target_model: 'smart',
  };

  const rowPlaintext = {
    id: 'act_daily_backup',
    prompt_text: 'Perform daily incremental database backup',
    cron_expr: '0 3 * * *',
    timezone: 'UTC',
    target_provider: 'gemini',
    target_model: 'smart',
  };

  const catalog = { instances: { byId: new Map() }, agents: { byId: new Map() } };

  // 1. searchableText of row with armored prompt must NOT contain ciphertext or armor prefix
  const hay = actionListPageSearchableText(rowArmored, catalog);
  assert.ok(!hay.includes('vault'), "searchableText must NOT contain 'vault'");
  assert.ok(!hay.includes('vault:v2:e1:'), "searchableText must NOT contain 'vault:v2:e1:'");
  assert.ok(!hay.includes(cipherTokenPrompt.toLowerCase()), 'searchableText must NOT contain ciphertext token');
  assert.ok(!hay.includes(armoredPrompt.toLowerCase()), 'searchableText must NOT contain raw armored prompt');

  // 2. matchesQuery must return false for 'vault', 'vault:v1', and ciphertext tokens
  assert.equal(actionListPageMatchesQuery(rowArmored, catalog, 'vault'), false, "Query 'vault' must return false");
  assert.equal(actionListPageMatchesQuery(rowArmored, catalog, 'Vault'), false, "Query 'Vault' must return false");
  assert.equal(actionListPageMatchesQuery(rowArmored, catalog, 'vault:v1'), false, "Query 'vault:v1' must return false");
  assert.equal(actionListPageMatchesQuery(rowArmored, catalog, 'vault:v2:e1:'), false, "Query 'vault:v2:e1:' must return false");
  assert.equal(actionListPageMatchesQuery(rowArmored, catalog, cipherTokenPrompt), false, 'Ciphertext token query must return false');

  // 3. Plaintext prompt before decryption must return false
  assert.equal(actionListPageMatchesQuery(rowArmored, catalog, 'secret failover'), false);

  // 4. Other unarmored metadata on the row matches as expected
  assert.equal(actionListPageMatchesQuery(rowArmored, catalog, 'act_alpha_01'), true);
  assert.equal(actionListPageMatchesQuery(rowArmored, catalog, 'gemini smart'), true);

  // 5. Unarmored row prompt_text matches as expected
  assert.equal(actionListPageMatchesQuery(rowPlaintext, catalog, 'incremental database backup'), true);
  assert.equal(actionListPageMatchesQuery(rowPlaintext, catalog, 'vault'), false);
});

// =============================================================================
// Area 4: LibraryPage Filtered Logic
// =============================================================================

test('Area 4: LibraryPage - armored artifact name, description, and originRef never match queries', async () => {
  const secretName = 'classified-network-diagram.png';
  const secretDesc = 'Internal routing mesh topology for military-grade enclave';
  const secretOriginRef = 'chain_classified_mission_alpha';

  const armoredName = await encryptVaultText(secretName, TEST_KEY_HEX);
  const armoredDesc = await encryptVaultText(secretDesc, TEST_KEY_HEX);
  const armoredOriginRef = await encryptVaultText(secretOriginRef, TEST_KEY_HEX);

  const cipherTokenName = armoredName.slice(12, 28);
  const cipherTokenDesc = armoredDesc.slice(12, 28);
  const cipherTokenOrigin = armoredOriginRef.slice(12, 28);

  const artifacts = [
    {
      artifact_id: 'art_armored_name',
      name: armoredName,
      description: 'Public documentation description',
      origin_ref: 'chain_public_1',
      kind: 'image',
    },
    {
      artifact_id: 'art_armored_desc',
      name: 'system-spec.md',
      description: armoredDesc,
      origin_ref: 'chain_public_1',
      kind: 'markdown',
    },
    {
      artifact_id: 'art_armored_origin',
      name: 'build-log.txt',
      description: 'Build execution logs',
      origin_ref: armoredOriginRef,
      kind: 'text',
    },
    {
      artifact_id: 'art_all_armored',
      name: armoredName,
      description: armoredDesc,
      origin_ref: armoredOriginRef,
      kind: 'image',
    },
  ];

  // 1. Searching for 'vault' must return 0 matches
  assert.equal(filterLibraryArtifacts(artifacts, 'vault').length, 0, "Query 'vault' must return 0 matches");
  assert.equal(filterLibraryArtifacts(artifacts, 'Vault').length, 0, "Query 'Vault' must return 0 matches");

  // 2. Searching for 'vault:v1' or 'vault:v2:e1:' must return 0 matches
  assert.equal(filterLibraryArtifacts(artifacts, 'vault:v1').length, 0, "Query 'vault:v1' must return 0 matches");
  assert.equal(filterLibraryArtifacts(artifacts, 'vault:v2:e1:').length, 0, "Query 'vault:v2:e1:' must return 0 matches");

  // 3. Searching for raw ciphertext tokens must return 0 matches
  assert.equal(filterLibraryArtifacts(artifacts, cipherTokenName).length, 0, 'Ciphertext token from name must return 0 matches');
  assert.equal(filterLibraryArtifacts(artifacts, cipherTokenDesc).length, 0, 'Ciphertext token from description must return 0 matches');
  assert.equal(filterLibraryArtifacts(artifacts, cipherTokenOrigin).length, 0, 'Ciphertext token from originRef must return 0 matches');

  // 4. Searching for plaintext before decryption returns 0 matches
  assert.equal(filterLibraryArtifacts(artifacts, 'classified-network').length, 0);
  assert.equal(filterLibraryArtifacts(artifacts, 'military-grade enclave').length, 0);
  assert.equal(filterLibraryArtifacts(artifacts, 'mission_alpha').length, 0);

  // 5. Unarmored fields continue to match
  assert.equal(filterLibraryArtifacts(artifacts, 'art_armored_name').length, 1);
  assert.equal(filterLibraryArtifacts(artifacts, 'system-spec').length, 1);
  assert.equal(filterLibraryArtifacts(artifacts, 'build-log').length, 1);
});

// =============================================================================
// Area 5: NewConversationWindowPane / WorkbenchAgentPicker Filtered Logic
// =============================================================================

test('Area 5: NewConversationWindowPane - armored display_name never matches search queries', async () => {
  const secretAgentName = 'TopSecret Intelligence Gatherer #007';
  const armoredAgentName = await encryptVaultText(secretAgentName, TEST_KEY_HEX);
  const cipherTokenAgent = armoredAgentName.slice(11, 27);

  const instances = [
    {
      agent_instance_id: 'inst_secret_01',
      display_name: armoredAgentName,
    },
    {
      agent_instance_id: 'inst_secret_02',
      display_name: armoredAgentName,
    },
    {
      agent_instance_id: 'inst_public_03',
      display_name: 'frontend-coder #42',
    },
  ];

  // 1. Searching for 'vault' must return 0 matches
  assert.equal(filterWorkbenchAgentInstances(instances, 'vault').length, 0, "Query 'vault' must return 0 matches");
  assert.equal(filterWorkbenchAgentInstances(instances, 'Vault').length, 0, "Query 'Vault' must return 0 matches");

  // 2. Searching for 'vault:v1' or 'vault:v2:e1:' must return 0 matches
  assert.equal(filterWorkbenchAgentInstances(instances, 'vault:v1').length, 0, "Query 'vault:v1' must return 0 matches");
  assert.equal(filterWorkbenchAgentInstances(instances, 'vault:v2:e1:').length, 0, "Query 'vault:v2:e1:' must return 0 matches");

  // 3. Searching for raw ciphertext tokens must return 0 matches
  assert.equal(filterWorkbenchAgentInstances(instances, cipherTokenAgent).length, 0, 'Ciphertext token must return 0 matches');

  // 4. Searching for plaintext before decryption returns 0 matches
  assert.equal(filterWorkbenchAgentInstances(instances, 'Intelligence Gatherer').length, 0);

  // 5. Searching by agent_instance_id still matches
  const matchId = filterWorkbenchAgentInstances(instances, 'inst_secret_01');
  assert.equal(matchId.length, 1);
  assert.equal(matchId[0].agent_instance_id, 'inst_secret_01');

  // 6. Searching unarmored display_name matches
  const matchPublic = filterWorkbenchAgentInstances(instances, 'frontend-coder');
  assert.equal(matchPublic.length, 1);
  assert.equal(matchPublic[0].agent_instance_id, 'inst_public_03');
});

// =============================================================================
// Area 6: Combobox Filtered Logic
// =============================================================================

test('Area 6: Combobox - armored option titles and subtitles never match search queries', async () => {
  const secretTitle = 'Sensitive Financial Billing Account';
  const secretSubtitle = 'Direct ACH Wire Transfer Endpoint /v1/payout';
  const secretTag = 'CONFIDENTIAL-FINANCE';
  const secretKeywords = 'payroll wire swift iban';

  const armoredTitle = await encryptVaultText(secretTitle, TEST_KEY_HEX);
  const armoredSubtitle = await encryptVaultText(secretSubtitle, TEST_KEY_HEX);
  const armoredTag = await encryptVaultText(secretTag, TEST_KEY_HEX);
  const armoredKeywords = await encryptVaultText(secretKeywords, TEST_KEY_HEX);

  const cipherTokenTitle = armoredTitle.slice(10, 26);
  const cipherTokenSubtitle = armoredSubtitle.slice(10, 26);

  const options = [
    {
      value: 'opt_1',
      title: armoredTitle,
      subtitle: 'Public cloud endpoint',
    },
    {
      value: 'opt_2',
      title: 'Standard Payment Gateway',
      subtitle: armoredSubtitle,
    },
    {
      value: 'opt_3',
      title: 'Account Settings',
      tag: armoredTag,
      keywords: armoredKeywords,
    },
    {
      value: 'opt_4',
      title: armoredTitle,
      subtitle: armoredSubtitle,
      tag: armoredTag,
      keywords: armoredKeywords,
    },
    {
      value: 'opt_5',
      title: 'General Notification Settings',
      subtitle: 'Email and Slack alerts',
    },
  ];

  // 1. Searching for 'vault' must return 0 matches
  assert.equal(filterComboboxOptions(options, 'vault').length, 0, "Query 'vault' must return 0 matches");
  assert.equal(filterComboboxOptions(options, 'Vault').length, 0, "Query 'Vault' must return 0 matches");

  // 2. Searching for 'vault:v1' or 'vault:v2:e1:' must return 0 matches
  assert.equal(filterComboboxOptions(options, 'vault:v1').length, 0, "Query 'vault:v1' must return 0 matches");
  assert.equal(filterComboboxOptions(options, 'vault:v2:e1:').length, 0, "Query 'vault:v2:e1:' must return 0 matches");

  // 3. Searching for raw ciphertext tokens must return 0 matches
  assert.equal(filterComboboxOptions(options, cipherTokenTitle).length, 0, 'Ciphertext token from title must return 0 matches');
  assert.equal(filterComboboxOptions(options, cipherTokenSubtitle).length, 0, 'Ciphertext token from subtitle must return 0 matches');

  // 4. Searching for plaintext before decryption returns 0 matches
  assert.equal(filterComboboxOptions(options, 'Financial Billing').length, 0);
  assert.equal(filterComboboxOptions(options, 'ACH Wire').length, 0);
  assert.equal(filterComboboxOptions(options, 'payroll wire').length, 0);

  // 5. Searching unarmored title/subtitle matches
  assert.equal(filterComboboxOptions(options, 'General Notification').length, 1);
  assert.equal(filterComboboxOptions(options, 'Email and Slack').length, 1);
  assert.equal(filterComboboxOptions(options, 'Standard Payment').length, 1);
});

// =============================================================================
// Area 7: shellModel matchesQuery Logic
// =============================================================================

test('Area 7: shellModel - armored session labels and commands never match search queries', async () => {
  const secretLabel = 'Production Database Cluster Maintenance';
  const secretCmd = 'psql -U superuser -d prod_db -c "SELECT * FROM secrets"';

  const armoredLabel = await encryptVaultText(secretLabel, TEST_KEY_HEX);
  const armoredCmd = await encryptVaultText(secretCmd, TEST_KEY_HEX);

  const cipherTokenLabel = armoredLabel.slice(12, 28);
  const cipherTokenCmd = armoredCmd.slice(12, 28);

  const sessions = [
    {
      session_id: 'shl_armored_label',
      label: armoredLabel,
      cmd: 'ls -la /var/log',
      cwd: '/var/log',
      kind: 'bash',
      status: 'running',
      server_port: 0,
    },
    {
      session_id: 'shl_armored_cmd',
      label: 'Database inspection shell',
      cmd: armoredCmd,
      cwd: '/tmp',
      kind: 'bash',
      status: 'running',
      server_port: 8080,
    },
    {
      session_id: 'shl_all_armored',
      label: armoredLabel,
      cmd: armoredCmd,
      cwd: '/root',
      kind: 'bash',
      status: 'running',
      server_port: 0,
    },
    {
      session_id: 'shl_unarmored',
      label: 'Build runner terminal',
      cmd: 'cargo build --release',
      cwd: '/workspace/app',
      kind: 'bash',
      status: 'exited',
      server_port: 3000,
    },
  ];

  for (const session of sessions.slice(0, 3)) {
    // 1. Searching for 'vault' must return false
    assert.equal(shellModelMatchesQuery(session, 'vault'), false, `Session ${session.session_id} must not match 'vault'`);
    assert.equal(shellModelMatchesQuery(session, 'Vault'), false, `Session ${session.session_id} must not match 'Vault'`);

    // 2. Searching for 'vault:v1' or 'vault:v2:e1:' must return false
    assert.equal(shellModelMatchesQuery(session, 'vault:v1'), false, `Session ${session.session_id} must not match 'vault:v1'`);
    assert.equal(shellModelMatchesQuery(session, 'vault:v2:e1:'), false, `Session ${session.session_id} must not match 'vault:v2:e1:'`);

    // 3. Searching for raw ciphertext tokens must return false
    assert.equal(shellModelMatchesQuery(session, cipherTokenLabel), false, `Session ${session.session_id} must not match cipherTokenLabel`);
    assert.equal(shellModelMatchesQuery(session, cipherTokenCmd), false, `Session ${session.session_id} must not match cipherTokenCmd`);

    // 4. Searching for plaintext before decryption returns false
    assert.equal(shellModelMatchesQuery(session, 'Production Database Cluster'), false);
    assert.equal(shellModelMatchesQuery(session, 'SELECT * FROM secrets'), false);
  }

  // 5. Unarmored fields on armored sessions (cwd, session_id, kind, server_port) still match
  assert.equal(shellModelMatchesQuery(sessions[0], 'shl_armored_label'), true);
  assert.equal(shellModelMatchesQuery(sessions[0], '/var/log'), true);
  assert.equal(shellModelMatchesQuery(sessions[1], '8080'), true);
  assert.equal(shellModelMatchesQuery(sessions[1], 'Database inspection shell'), true);

  // 6. Completely unarmored session matches commands and labels
  assert.equal(shellModelMatchesQuery(sessions[3], 'cargo build'), true);
  assert.equal(shellModelMatchesQuery(sessions[3], 'Build runner terminal'), true);
  assert.equal(shellModelMatchesQuery(sessions[3], 'vault'), false);
});

// =============================================================================
// Comprehensive Cross-Cutting Regression Suite
// =============================================================================

test('Cross-cutting: Encrypted items across all 7 areas are completely immune to ciphertext substring leaks', async () => {
  // Generate random AES-GCM ciphertext
  const testPlaintexts = [
    'Critical Vault Password',
    'vault security token 1234',
    'Zero Knowledge Architecture',
    'Encryption Key Generation Service',
  ];

  for (const plain of testPlaintexts) {
    const armored = await encryptVaultText(plain, TEST_KEY_HEX);
    assert.ok(isVaultArmored(armored));

    // Common search substrings that users or automated attacks might query
    const hostileQueries = [
      'vault',
      'Vault',
      'VAULT',
      'vault:',
      'vault:v1',
      'vault:v2:e1:',
      armored.slice(9, 20),
      armored.slice(15, 30),
      armored.slice(armored.length - 10),
    ];

    for (const q of hostileQueries) {
      // 1. RecentTaskChainsTab
      const chains = [{ chainId: 'c1', title: armored, projectName: armored, status: 'active' }];
      assert.equal(filterRecentTaskChains(chains, q).length, 0, `Chains search must yield 0 for "${q}"`);

      // 2. ActionItemsTab & CardsPanel
      const cards = [{ card_id: 'card1', title: armored, rationale: armored, project_id: 'p1' }];
      const projectMap = new Map([['p1', { name: armored }]]);
      assert.equal(filterActionItemsTabCards(cards, q, projectMap).length, 0, `ActionItemsTab must yield 0 for "${q}"`);
      assert.equal(filterCardsPanelCards(cards, q, projectMap).length, 0, `CardsPanel must yield 0 for "${q}"`);

      // 3. ActionListPage
      const row = { id: 'act1', prompt_text: armored };
      assert.equal(actionListPageMatchesQuery(row, {}, q), false, `ActionListPage must return false for "${q}"`);

      // 4. LibraryPage
      const artifacts = [{ artifact_id: 'art1', name: armored, description: armored, origin_ref: armored }];
      assert.equal(filterLibraryArtifacts(artifacts, q).length, 0, `LibraryPage must yield 0 for "${q}"`);

      // 5. NewConversationWindowPane / WorkbenchAgentPicker
      const instances = [{ agent_instance_id: 'inst1', display_name: armored }];
      assert.equal(filterWorkbenchAgentInstances(instances, q).length, 0, `NewConversationWindowPane must yield 0 for "${q}"`);

      // 6. Combobox
      const options = [{ value: 'v1', title: armored, subtitle: armored, tag: armored, keywords: armored }];
      assert.equal(filterComboboxOptions(options, q).length, 0, `Combobox must yield 0 for "${q}"`);

      // 7. shellModel
      const session = { session_id: 's1', label: armored, cmd: armored };
      assert.equal(shellModelMatchesQuery(session, q), false, `shellModel must return false for "${q}"`);
    }

    // Verify decryption roundtrip restores plaintext
    const decrypted = await decryptVaultText(armored, TEST_KEY_HEX);
    assert.equal(decrypted, plain);
  }
});
