// Sidebar cleanup: no Conversations / Task Chains entries, '+ New conversation'
// instead of Home, no task chain list, and a fully hidden (zero-width) sidebar
// with a top-left "toggle + app name" control that reopens it (Jetski style).
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx'), 'utf8');
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

test('sidebar shows no task chain list (no chain tree, no pinned chains)', () => {
  assert.doesNotMatch(source, /ProjectChainTree|CollapsedPinnedChains/);
  assert.equal(fs.existsSync(path.join(REPO_ROOT, 'src/ui/components/chains/ProjectChainTree.tsx')), false);
});

test('hidden sidebar renders no rail; the toggle + app name are a FIXED top-left cluster that never moves', () => {
  // No icon rail widths or mobile spacer.
  assert.doesNotMatch(source, /'w-12' : 'w-16'/);
  assert.doesNotMatch(source, /w-12 shrink-0 md:hidden/);
  assert.doesNotMatch(source, /shell-left-sidebar-collapsed/);
  // One fixed cluster with the toggle + brand, outside the sidebar (so it does not move).
  const cluster = source.slice(source.indexOf('data-debug-id="shell-top-left-cluster"') - 40, source.indexOf('data-debug-id="shell-top-left-cluster"') + 400);
  assert.match(cluster, /absolute left-0 top-0/);
  assert.match(cluster, /\{sidebarToggleButton\}\s*\{brandLink\}/);
  assert.equal(source.split('{sidebarToggleButton}').length - 1, 1, 'toggle rendered exactly once');
  // The sidebar animates its width (desktop) / slides (mobile) and its header reserves the cluster.
  assert.match(source, /isEffectiveCollapsed \? 'invisible w-0' : 'visible w-80 border-r border-subtle'/);
  assert.match(source, /isEffectiveCollapsed \? 'invisible -translate-x-full' : 'visible translate-x-0'/);
  assert.match(source, /style=\{\{ width: TOP_LEFT_CLUSTER_WIDTH \}\} \/>\s*<SidebarUpdateBadge/);
  // Hidden: the workspace's top-left header / other pages reserve the cluster's space.
  assert.match(source, /workspaceLeading=\{isEffectiveCollapsed \? <div aria-hidden="true" data-debug-id="shell-top-left-cluster-spacer"/);
  assert.match(source, /workspaceTrailing=\{isEffectiveCollapsed \? <SidebarUpdateBadge onOpen=\{openBridgeUpdate\} \/> : null\}/);
  assert.match(source, /\{isEffectiveCollapsed && !isWorkspaceRoute \? \(\s*<div\s+data-debug-id="shell-sidebar-reopen-bar"/);
  // The toggle flips the persisted desktop preference / the mobile drawer.
  assert.match(source, /onClick=\{\(\) => \(isMobile \? setDrawerOpen\(!drawerOpen\) : toggleCollapsed\(\)\)\}/);
  assert.match(source, /localStorage\.setItem\('heimdall:shell:sidebar-collapsed'/);
});
