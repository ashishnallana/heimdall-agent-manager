// Sidebar cleanup: no Conversations / Task Chains entries, '+ New conversation'
// instead of Home, a shared scrolling task-chain list, and a fully hidden (zero-width) sidebar
// with a top-left "toggle + app name" control that reopens it (Jetski style).
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  COMPACT_TOP_LEFT_CLUSTER_WIDTH,
  MOBILE_COMPACT_TOP_LEFT_CLUSTER_WIDTH,
  MOBILE_TOP_CHROME_HEIGHT,
  MOBILE_TOP_LEFT_CLUSTER_WIDTH,
  TOP_CHROME_HEIGHT,
  TOP_LEFT_CLUSTER_WIDTH,
  chromeIconButtonSizeClass,
  isAgentConversationRoute,
  topChromeHeight,
  topLeftClusterWidth,
} from '../src/ui/components/shell/shellChrome.ts';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx'), 'utf8');
const chatSource = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/workbench/AgentChatPane.tsx'), 'utf8');
const navBlock = source.slice(source.indexOf('const NAV_ROUTES'), source.indexOf('];', source.indexOf('const NAV_ROUTES')));

test('primary nav: "+ New conversation" replaces Home; Conversations and Task Chains are gone', () => {
  assert.match(navBlock, /path: '\/home', label: 'New conversation', icon: 'plus'/);
  assert.doesNotMatch(navBlock, /label: 'Home'/);
  assert.doesNotMatch(navBlock, /path: '\/conversations'/);
  assert.doesNotMatch(navBlock, /path: '\/chains'/);
  // Routes still resolve when deep-linked.
  assert.match(source, /'\/conversations', '\/conversations\/new'/);
  assert.match(source, /'\/chains', '\/chains\/new'/);
});

test('sidebar chains share the navigation scroller; legacy chain tree and pinned rail stay removed', () => {
  assert.doesNotMatch(source, /ProjectChainTree|CollapsedPinnedChains/);
  assert.match(source, /data-debug-id="shell-sidebar-scroll" className="min-h-0 flex-1 overflow-y-auto p-3"/);
  assert.match(source, /<\/nav>\s*<SidebarTaskChains/);
  assert.match(source, /data-debug-id="shell-sidebar-account" className={`shrink-0 border-t/);
  assert.doesNotMatch(source, /useFetchTaskChainGroupsQuery/);
  assert.equal(fs.existsSync(path.join(REPO_ROOT, 'src/ui/components/chains/ProjectChainTree.tsx')), false);
});

test('hidden sidebar renders no rail; the fixed top-left cluster compacts on agent conversations', () => {
  // No icon rail widths or mobile spacer.
  assert.doesNotMatch(source, /'w-12' : 'w-16'/);
  assert.doesNotMatch(source, /w-12 shrink-0 md:hidden/);
  assert.doesNotMatch(source, /shell-left-sidebar-collapsed/);
  // One fixed cluster with the toggle + brand, outside the sidebar (so it does not move).
  const cluster = source.slice(source.indexOf('data-debug-id="shell-top-left-cluster"') - 40, source.indexOf('data-debug-id="shell-top-left-cluster"') + 400);
  assert.match(cluster, /absolute left-0 top-0/);
  assert.match(cluster, /\{sidebarToggleButton\}\s*\{showBrand \? brandLink : null\}/);
  assert.doesNotMatch(cluster, /vaultStatusButton/);
  assert.equal(source.split('{sidebarToggleButton}').length - 1, 1, 'toggle rendered exactly once');
  assert.match(source, /const showBrand = !isWorkspaceRoute/);
  assert.match(source, /const topLeftClusterWidth = computeTopLeftClusterWidth\(isMobile, showBrand, controlsInset\)/);
  // The sidebar animates its width (desktop) / slides (mobile) and its header reserves the cluster.
  assert.match(source, /isEffectiveCollapsed \? 'invisible w-0' : 'visible w-80 border-r border-subtle'/);
  assert.match(source, /isEffectiveCollapsed \? 'invisible -translate-x-full' : 'visible translate-x-0'/);
  // The bridge status chip was removed from the shell (Settings > Bridges manages bridges).
  assert.doesNotMatch(source, /SidebarUpdateBadge/);
  // Hidden: the workspace's top-left header / other pages reserve the cluster's space.
  assert.match(source, /workspaceLeading=\{isEffectiveCollapsed \? <div aria-hidden="true" data-debug-id="shell-top-left-cluster-spacer"/);
  assert.match(source, /workspaceLeadingWidth=\{isEffectiveCollapsed \? topLeftClusterWidth : 0\}/);
  // Other pages keep their top bar whether or not the sidebar is open.
  assert.match(source, /\{!isWorkspaceRoute \? \(\s*<div\s+data-debug-id="shell-top-bar"/);
  assert.doesNotMatch(source, /shell-sidebar-reopen-bar/);
  // Chromium applies -webkit-app-region in DOM order: the top-left cluster (with the
  // no-drag toggle) must come after every drag strip it overlaps, or a macOS
  // hidden-inset window swallows the toggle's clicks.
  const clusterAt = source.indexOf('data-debug-id="shell-top-left-cluster"');
  for (const strip of ['<aside', 'data-debug-id="shell-top-bar"', '<RouteOutlet']) {
    assert.ok(source.indexOf(strip) > 0 && clusterAt > source.indexOf(strip), `top-left cluster renders after ${strip}`);
  }
  // The toggle flips the persisted desktop preference / the mobile drawer.
  assert.match(source, /onClick=\{\(\) => \(isMobile \? setDrawerOpen\(!drawerOpen\) : toggleCollapsed\(\)\)\}/);
  assert.match(source, /localStorage\.setItem\('heimdall:shell:sidebar-collapsed'/);
});

test('Ninjy wordmark is visible on Home and hidden only on agent conversations', () => {
  assert.equal(isAgentConversationRoute('/home'), false);
  assert.equal(isAgentConversationRoute('/cards'), false);
  assert.equal(isAgentConversationRoute('/conversations'), false);
  assert.equal(isAgentConversationRoute('/conversations/new'), false);
  assert.equal(isAgentConversationRoute('/conversations/inst_123'), true);
  assert.equal(isAgentConversationRoute('/c/inst_123'), true);
  assert.ok(TOP_LEFT_CLUSTER_WIDTH > COMPACT_TOP_LEFT_CLUSTER_WIDTH);
});

test('REQ-MOB-1: mobile window chrome uses 44px round buttons in a 56px row; desktop is unchanged', () => {
  assert.equal(topChromeHeight(false), TOP_CHROME_HEIGHT);
  assert.equal(topChromeHeight(true), MOBILE_TOP_CHROME_HEIGHT);
  assert.equal(topLeftClusterWidth(false, true), TOP_LEFT_CLUSTER_WIDTH);
  assert.equal(topLeftClusterWidth(false, false), COMPACT_TOP_LEFT_CLUSTER_WIDTH);
  assert.equal(topLeftClusterWidth(true, true), MOBILE_TOP_LEFT_CLUSTER_WIDTH);
  assert.equal(topLeftClusterWidth(true, false), MOBILE_COMPACT_TOP_LEFT_CLUSTER_WIDTH);
  // REQ-MAC-CHROME-1: the macOS traffic-light inset widens desktop clusters only.
  assert.equal(topLeftClusterWidth(false, true, 78), 78 + TOP_LEFT_CLUSTER_WIDTH);
  assert.equal(topLeftClusterWidth(false, false, 78), 78 + COMPACT_TOP_LEFT_CLUSTER_WIDTH);
  assert.equal(topLeftClusterWidth(true, false, 78), MOBILE_COMPACT_TOP_LEFT_CLUSTER_WIDTH);
  // One 44px button + 8px padding each side must fit the compact cluster.
  assert.ok(MOBILE_COMPACT_TOP_LEFT_CLUSTER_WIDTH >= 44 + 16);
  assert.ok(MOBILE_TOP_CHROME_HEIGHT >= 44);
  assert.equal(chromeIconButtonSizeClass(false), 'h-8 w-8 rounded-lg');
  assert.equal(chromeIconButtonSizeClass(true), 'h-11 w-11 rounded-full');
  assert.equal(source.split('height: chromeHeight').length - 1, 3, 'cluster, sidebar header and top bar share the chrome height');
});

test('mobile conversation header omits the project breadcrumb segment and first separator', () => {
  const breadcrumb = chatSource.slice(
    chatSource.indexOf('data-debug-id="conversation-thread-breadcrumb"'),
    chatSource.indexOf('data-debug-id="conversation-chain-agent-switcher-btn"'),
  );
  assert.match(breadcrumb, /\{!isMobile \? \(/);
  assert.match(breadcrumb, /data-debug-id="conversation-breadcrumb-project"/);
  assert.match(breadcrumb, /<VaultText value=\{projectName\} fallback="Project" \/>/);
  assert.match(breadcrumb, /<span className="shrink-0 text-faint">\/<\/span>[\s\S]*\) : null\}/);
});

test('mobile aux hides the fixed Ninjy and sidebar controls', () => {
  assert.match(source, /const hideTopLeftCluster = isMobile && isWorkspaceRoute && isCurrentAuxPaneOpen/);
  assert.match(source, /\{!hideTopLeftCluster \? \(\s*<div\s+data-debug-id="shell-top-left-cluster"/);
});

test('REQ-BAR-3: vault status module lives in the bottom status bar; no lock/unlock, only key delivery', () => {
  assert.match(source, /renderVaultToggle: renderVaultStatusButton/);
  assert.match(source, /data-debug-id="shell-vault-status-toggle"/);
  assert.match(source, /Icon name=\{hasOnlineLockedBridge \? 'lock' : 'lock-open'\}/);
  // REQ-SB-2: plain colored text, no background pill.
  assert.match(source, /hasOnlineLockedBridge \? 'text-warning' : 'text-success'/);
  assert.doesNotMatch(source, /bg-(warning|success|danger)-soft text-(warning|success|danger) hover:bg-/);
  // A click delivers the key to waiting bridges, otherwise opens Settings -> Devices.
  assert.match(source, /if \(hasOnlineLockedBridge\) \{\s*void reconcileOnlineLockedBridges\(\);/);
  assert.match(source, /window\.location\.hash = buildRouteHash\('\/settings\/devices', ''\)/);
  assert.match(source, /if \(bridgeReconciliationRef\.current\) return bridgeReconciliationRef\.current/);
  // The password-era lock surfaces are gone.
  assert.doesNotMatch(source, /setUnlockModalOpen|lockAllConnectedBridges|lockVault\(/);
});
