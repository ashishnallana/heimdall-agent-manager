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

test('hidden sidebar renders no rail; the top-left toggle + app name reopens it', () => {
  // No icon rail widths or mobile spacer.
  assert.doesNotMatch(source, /'w-12' : 'w-16'/);
  assert.doesNotMatch(source, /w-12 shrink-0 md:hidden/);
  assert.doesNotMatch(source, /shell-left-sidebar-collapsed/);
  // The aside only exists while shown.
  assert.match(source, /\{!isEffectiveCollapsed \? \(\s*<aside\s+data-debug-id="shell-left-sidebar-expanded"/);
  // When hidden, the same toggle + brand render at the top-left of the main area.
  const reopen = source.slice(source.indexOf('shell-sidebar-reopen-bar') - 200, source.indexOf('shell-sidebar-reopen-bar') + 400);
  assert.match(reopen, /\{isEffectiveCollapsed \? \(/);
  assert.match(reopen, /\{sidebarToggleButton\}\s*\{brandLink\}/);
  // The toggle flips the persisted desktop preference / the mobile drawer.
  assert.match(source, /onClick=\{\(\) => \(isMobile \? setDrawerOpen\(!drawerOpen\) : toggleCollapsed\(\)\)\}/);
  assert.match(source, /aria-label=\{isEffectiveCollapsed \? 'Show sidebar' : 'Hide sidebar'\}/);
  assert.match(source, /localStorage\.setItem\('heimdall:shell:sidebar-collapsed'/);
});
