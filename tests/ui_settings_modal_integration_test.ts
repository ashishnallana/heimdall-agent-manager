// REQ-SET-1, REQ-SET-5: Integration tests for SettingsModal with AppShell navigation and deep link routing
//
// RUN: npx tsx --test tests/ui_settings_modal_integration_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  resolveSettingsTab,
  normalizeSettingsTab,
} from '../src/ui/utils/settingsRouting.ts';
import {
  DEFAULT_NAV,
  DEFAULT_ACTIONS,
} from '../src/ui/components/ui/patterns/commandPaletteLogic.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const APP_SHELL_PATH = path.join(
  REPO_ROOT,
  'src/ui/components/shell/AppShell.tsx',
);
const RESPONSIVE_PATH = path.join(
  REPO_ROOT,
  'src/ui/components/shell/responsive.tsx',
);
const COMMAND_PALETTE_LOGIC_PATH = path.join(
  REPO_ROOT,
  'src/ui/components/ui/patterns/commandPaletteLogic.ts',
);
const SETTINGS_MODAL_PATH = path.join(
  REPO_ROOT,
  'src/ui/components/settings/SettingsModal.tsx',
);

// ---------------------------------------------------------------------------
// 1. Static Contract & Integration Verification (REQ-SET-1, REQ-SET-5)
// ---------------------------------------------------------------------------

test('AppShell.tsx imports SettingsModal and mounts it with required props', () => {
  assert.ok(fs.existsSync(APP_SHELL_PATH), 'AppShell.tsx must exist');
  const content = fs.readFileSync(APP_SHELL_PATH, 'utf-8');

  // 1. Import SettingsModal from ../settings/SettingsModal
  assert.ok(
    content.includes("import SettingsModal from '../settings/SettingsModal'") ||
      content.includes('import SettingsModal from "../settings/SettingsModal"'),
    'AppShell.tsx must import SettingsModal from ../settings/SettingsModal',
  );

  // 2. State definition: settingsModalOpen and settingsModalTab
  assert.ok(
    content.includes('settingsModalOpen') &&
      content.includes('setSettingsModalOpen'),
    'AppShell.tsx must declare settingsModalOpen state and setter',
  );
  assert.ok(
    content.includes('settingsModalTab') &&
      content.includes('setSettingsModalTab'),
    'AppShell.tsx must declare settingsModalTab state and setter',
  );

  // 3. Render <SettingsModal open={settingsModalOpen} onOpenChange={setSettingsModalOpen} initialTab={settingsModalTab} ... />
  assert.ok(
    content.includes('<SettingsModal'),
    'AppShell.tsx must render <SettingsModal',
  );
  assert.ok(
    content.includes('open={settingsModalOpen}'),
    'SettingsModal must receive open={settingsModalOpen}',
  );
  assert.ok(
    content.includes('onOpenChange={setSettingsModalOpen}'),
    'SettingsModal must receive onOpenChange={setSettingsModalOpen}',
  );
  assert.ok(
    content.includes('initialTab={settingsModalTab}'),
    'SettingsModal must receive initialTab={settingsModalTab}',
  );
});

// ---------------------------------------------------------------------------
// 2. Sidebar user-row Settings entry point
// ---------------------------------------------------------------------------

test('Sidebar user row opens SettingsModal without page navigation', () => {
  const content = fs.readFileSync(APP_SHELL_PATH, 'utf-8');

  // NavItem must accept an optional onClick handler
  assert.ok(
    content.includes('function NavItem') && content.includes('onClick'),
    'NavItem component must accept onClick prop',
  );

  // The sidebar has no Settings nav entry: the user row (and its avatar when the
  // sidebar is collapsed) is the entry point and opens the modal on Account.
  assert.ok(
    !content.includes('data-debug-id="shell-secondary-nav"'),
    'Settings nav entry must be removed from the sidebar',
  );
  assert.ok(
    content.includes('data-debug-id="shell-open-account"') && content.includes('data-debug-id="shell-open-account-collapsed"'),
    'User row and collapsed avatar must both open settings',
  );
  assert.ok(
    content.includes("const openAccountSettings = () => { if (isMobile) setDrawerOpen(false); setSettingsModalTab('account'); setSettingsModalOpen(true); };"),
    'User row must open SettingsModal on the Account tab',
  );
});

// ---------------------------------------------------------------------------
// 3. Mobile Slim Sidebar Settings Click Integration
// ---------------------------------------------------------------------------

test('Mobile slim sidebar Settings item click opens SettingsModal and closes drawer', () => {
  const appShellContent = fs.readFileSync(APP_SHELL_PATH, 'utf-8');

  // Mobile settings click closes mobile drawer and opens SettingsModal
  assert.ok(
    appShellContent.includes('setSettingsModalOpen(true)'),
    'AppShell must open SettingsModal when settings is selected',
  );
  assert.ok(
    appShellContent.includes('if (isMobile) setDrawerOpen(false)'),
    'AppShell must close mobile drawer when navigating to settings on mobile',
  );
  assert.ok(
    appShellContent.includes('isEffectiveCollapsed'),
    'AppShell must use isEffectiveCollapsed for slim mobile left sidebar',
  );
});

// ---------------------------------------------------------------------------
// 4. Command Palette Settings Selection Integration
// ---------------------------------------------------------------------------

test('Command Palette includes Settings options and opens SettingsModal directly', () => {
  // CommandPalette navigation list includes Settings and Appearance
  const settingsNav = DEFAULT_NAV.find((item) => item.label === 'Settings');
  assert.ok(settingsNav, 'DEFAULT_NAV must include Settings');
  assert.ok(
    settingsNav.route.startsWith('/settings'),
    'Settings nav route must start with /settings',
  );

  const appearanceNav = DEFAULT_NAV.find((item) => item.label === 'Appearance');
  assert.ok(appearanceNav, 'DEFAULT_NAV must include Appearance');
  assert.equal(appearanceNav.route, '/settings/appearance');

  // CommandPalette actions include settings
  const settingsAction = DEFAULT_ACTIONS.find(
    (action) => action.id === 'settings' || action.id === 'settings-modal',
  );
  assert.ok(settingsAction, 'DEFAULT_ACTIONS must include settings action');

  // AppShell handlePaletteNavigate intercepts /settings routes
  const appShellContent = fs.readFileSync(APP_SHELL_PATH, 'utf-8');
  assert.ok(
    appShellContent.includes('const handlePaletteNavigate = (route: string) => {'),
    'Must define handlePaletteNavigate',
  );
  assert.ok(
    appShellContent.includes("route.startsWith('/settings')"),
    'handlePaletteNavigate must check route.startsWith("/settings")',
  );
  assert.ok(
    appShellContent.includes('setSettingsModalOpenState(true)') ||
      appShellContent.includes('setSettingsModalOpen(true)'),
    'handlePaletteNavigate must open SettingsModal for settings routes',
  );
});

// ---------------------------------------------------------------------------
// 5. Deep Link Routing & URL Hash Resolution
// ---------------------------------------------------------------------------

test('resolveSettingsTab extracts corresponding tabs from deep link routes', () => {
  assert.equal(resolveSettingsTab('/settings'), '');
  assert.equal(resolveSettingsTab('/settings/'), '');
  assert.equal(resolveSettingsTab('/settings/appearance'), 'appearance');
  assert.equal(resolveSettingsTab('/settings/bridges'), 'bridges');
  assert.equal(resolveSettingsTab('/settings/notifications'), 'notifications');
  assert.equal(resolveSettingsTab('/settings/providers'), 'providers');
  assert.equal(resolveSettingsTab('/settings/projects'), 'projects');
  assert.equal(resolveSettingsTab('/settings/experimental'), 'experimental');
  assert.equal(resolveSettingsTab('/settings/general'), '');
  assert.equal(resolveSettingsTab('/settings/browser'), 'browser');
  assert.equal(resolveSettingsTab('/settings/models'), 'models');
  assert.equal(resolveSettingsTab('/settings/workspace'), 'workspace');
  assert.equal(resolveSettingsTab('/settings/labs'), 'labs');
  assert.equal(resolveSettingsTab('/home'), '');

  // Deep link hash routes (REQ-SET-FIX-4)
  assert.equal(resolveSettingsTab('#/settings/vault'), 'vault');
  assert.equal(resolveSettingsTab('#/settings/lsp'), 'lsp');
  assert.equal(resolveSettingsTab('#/settings/user-tokens'), 'user-tokens');
  assert.equal(resolveSettingsTab('#/settings/templates'), 'templates');
  assert.equal(resolveSettingsTab('#/settings/projects'), 'projects');
  assert.equal(resolveSettingsTab('#/settings/experimental'), 'experimental');
});

test('normalizeSettingsTab aliases active routes and retires removed placeholder pages', () => {
  assert.equal(normalizeSettingsTab('bridges'), 'workspace');
  assert.equal(normalizeSettingsTab('workspace'), 'workspace');
  assert.equal(normalizeSettingsTab('providers'), 'models');
  assert.equal(normalizeSettingsTab('models'), 'models');
  assert.equal(normalizeSettingsTab('experimental'), 'experimental');
  assert.equal(normalizeSettingsTab('labs'), 'experimental');
  assert.equal(normalizeSettingsTab('appearance'), 'appearance');
  assert.equal(normalizeSettingsTab('notifications'), 'notifications');
  assert.equal(normalizeSettingsTab('general'), 'account');
  assert.equal(normalizeSettingsTab(), 'account');
  assert.equal(normalizeSettingsTab(undefined), 'account');
  assert.equal(normalizeSettingsTab('vault'), 'vault');
  assert.equal(normalizeSettingsTab('lsp'), 'lsp');
  assert.equal(normalizeSettingsTab('user-tokens'), 'user-tokens');
  assert.equal(normalizeSettingsTab('templates'), 'templates');
  assert.equal(normalizeSettingsTab('projects'), 'projects');
  assert.equal(normalizeSettingsTab('browser'), 'appearance');
  assert.equal(normalizeSettingsTab('shortcuts'), 'appearance');
  assert.equal(normalizeSettingsTab('feedback'), 'appearance');
});

test('SettingsModal renders BridgesPanel for bridges tab and AppearanceSettings for appearance tab', () => {
  const modalContent = fs.readFileSync(SETTINGS_MODAL_PATH, 'utf-8');

  // Bridges / Workspace panel embedding
  assert.ok(
    modalContent.includes("case 'workspace':") &&
      modalContent.includes("case 'bridges':") &&
      modalContent.includes('<BridgesPanel />'),
    'SettingsModal must render BridgesPanel for workspace/bridges tabs',
  );

  // Appearance panel embedding
  assert.ok(
    modalContent.includes("case 'appearance':") &&
      modalContent.includes('<AppearanceSettings />'),
    'SettingsModal must render AppearanceSettings for appearance tab',
  );

  // Providers / Models panel embedding
  assert.ok(
    modalContent.includes("case 'models':") &&
      modalContent.includes("case 'providers':") &&
      modalContent.includes('<ProvidersPanel />'),
    'SettingsModal must render ProvidersPanel for models/providers tabs',
  );

  // Canonical panels embedding (REQ-SET-FIX-4)
  assert.ok(
    modalContent.includes("case 'vault':") &&
      modalContent.includes('<VaultPanel />'),
    'SettingsModal must render VaultPanel for vault tab',
  );
  assert.ok(
    modalContent.includes("case 'lsp':") &&
      modalContent.includes('<LspPanel />'),
    'SettingsModal must render LspPanel for lsp tab',
  );
  assert.ok(
    modalContent.includes("case 'user-tokens':") &&
      modalContent.includes('<UserTokensPanel />'),
    'SettingsModal must render UserTokensPanel for user-tokens tab',
  );
  assert.ok(
    modalContent.includes("case 'templates':") &&
      modalContent.includes('<TemplatesPanel />'),
    'SettingsModal must render TemplatesPanel for templates tab',
  );
  // ProjectsPanel is NOT embedded in SettingsModal (Projects has dedicated primary navigation)
  assert.ok(
    !modalContent.includes('<ProjectsPanel'),
    'SettingsModal must not render ProjectsPanel',
  );
  assert.ok(
    !modalContent.includes("id: 'projects'"),
    'SETTINGS_CATEGORIES must not include projects',
  );
  assert.ok(
    modalContent.includes("case 'experimental':") &&
      modalContent.includes('<ExperimentalPanel />'),
    'SettingsModal must render ExperimentalPanel for experimental tab',
  );
});

// ---------------------------------------------------------------------------
// 6. Modal Close and Context Restoration
// ---------------------------------------------------------------------------

test('Closing modal restores background view or navigates back/home when on settings route', () => {
  const content = fs.readFileSync(APP_SHELL_PATH, 'utf-8');

  // Verify setSettingsModalOpen handles modal closing:
  // If current route is /settings, navigates back or to /home; otherwise preserves page context.
  assert.ok(
    content.includes("currentPath.startsWith('/settings')"),
    'Must check if current path is a settings path on modal close',
  );
  assert.ok(
    content.includes('window.history.back()'),
    'Must call window.history.back() when closing from a settings route',
  );
  assert.ok(
    content.includes("buildRouteHash('/home', '')"),
    'Must fallback navigate to /home if back history is unavailable',
  );

  // RouteOutlet renders HomePage for settings routes so background context is clean
  assert.ok(
    content.includes("path.startsWith('/settings') ? (") &&
      content.includes('<HomePage />'),
    'RouteOutlet must render clean HomePage background context when on settings path',
  );
});
