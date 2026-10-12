// REQ-SET-1, REQ-SET-2, REQ-SET-3, REQ-SET-4, REQ-SET-5, REQ-SET-6: Unit tests for SettingsModal
//
// RUN: node --test tests/ui_settings_modal_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  SETTINGS_STORAGE_KEY,
  DEFAULT_GENERAL_SETTINGS,
  loadSettings,
  saveSettings,
} from '../src/ui/utils/settingsPersistence.ts';
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

const SETTINGS_MODAL_PATH = path.join(
  REPO_ROOT,
  'src/ui/components/settings/SettingsModal.tsx',
);
const GENERAL_SETTINGS_PATH = path.join(
  REPO_ROOT,
  'src/ui/components/settings/GeneralSettingsPanel.tsx',
);
const APP_SHELL_PATH = path.join(
  REPO_ROOT,
  'src/ui/components/shell/AppShell.tsx',
);
const RESPONSIVE_PATH = path.join(
  REPO_ROOT,
  'src/ui/components/shell/responsive.tsx',
);

// In-memory mock localStorage for settings persistence tests
class MockStorage {
  private store = new Map<string, string>();

  getItem(key: string): string | null {
    return this.store.get(key) ?? null;
  }

  setItem(key: string, value: string): void {
    this.store.set(key, String(value));
  }

  removeItem(key: string): void {
    this.store.delete(key);
  }

  clear(): void {
    this.store.clear();
  }

  get length(): number {
    return this.store.size;
  }

  key(index: number): string | null {
    return Array.from(this.store.keys())[index] ?? null;
  }
}

// ---------------------------------------------------------------------------
// 1. Static Existence and Exports Verification (REQ-SET-6 item 1)
// ---------------------------------------------------------------------------

test('SettingsModal.tsx source file exists and exports SettingsModal', () => {
  assert.ok(fs.existsSync(SETTINGS_MODAL_PATH), 'SettingsModal.tsx must exist');

  const content = fs.readFileSync(SETTINGS_MODAL_PATH, 'utf-8');
  assert.ok(
    content.includes('export function SettingsModal') ||
      content.includes('export const SettingsModal'),
    'Must export SettingsModal as named export',
  );
  assert.ok(
    content.includes('export default SettingsModal'),
    'Must provide default export',
  );
});

test('SettingsModal.tsx defines required props interface', () => {
  const content = fs.readFileSync(SETTINGS_MODAL_PATH, 'utf-8');
  assert.ok(
    content.includes('export interface SettingsModalProps'),
    'Must define SettingsModalProps',
  );
  assert.ok(content.includes('open: boolean'), 'Must include open: boolean');
  assert.ok(
    content.includes('onOpenChange: (open: boolean) => void') ||
      content.includes('onOpenChange: (open: boolean) => unknown'),
    'Must include onOpenChange handler',
  );
  assert.ok(
    content.includes('initialTab?: string'),
    'Must include optional initialTab?: string prop',
  );
});

// ---------------------------------------------------------------------------
// 2. Modal Shell & Accessibility (REQ-SET-1)
// ---------------------------------------------------------------------------

test('SettingsModal implements portal overlay with backdrop blur and focus trapping', () => {
  const content = fs.readFileSync(SETTINGS_MODAL_PATH, 'utf-8');

  // Portal overlay
  assert.ok(content.includes('createPortal'), 'Must render via React createPortal');
  assert.ok(
    // REQ-VIEWPORT-SWEEP-1: `inset-x-0 top-0 app-viewport-height`, NOT `inset-0`. `inset-0`
    // pins the overlay's bottom edge to the layout viewport, which a soft keyboard does not
    // shrink, and this overlay is `items-center` — so the panel centres at layoutHeight/2
    // (406 on the REQ-KBD-1 device) while the visible region ends at 409, putting most of a
    // correctly-capped panel behind the keyboard. Pinned to the literal so a revert fails.
    content.includes('fixed inset-x-0 top-0 app-viewport-height z-modal bg-surface-overlay/80 backdrop-blur-sm'),
    'Overlay must be sized from --app-viewport-height, not inset-0 (REQ-VIEWPORT-SWEEP-1)',
  );

  // Esc key and focus trapping via useDialogA11y
  assert.ok(
    content.includes('useDialogA11y(open, close, panelRef)'),
    'Must invoke useDialogA11y for Esc key handling and focus trapping',
  );

  // Backdrop click handler
  assert.ok(
    content.includes('e.target === e.currentTarget'),
    'Must check e.target === e.currentTarget to close on backdrop click',
  );

  // Modal dialog attributes
  assert.ok(content.includes('role="dialog"'), 'Must have role="dialog"');
  assert.ok(content.includes('aria-modal="true"'), 'Must have aria-modal="true"');
  assert.ok(content.includes('tabIndex={-1}'), 'Must have tabIndex={-1} for focus-in');
});

// ---------------------------------------------------------------------------
// 3. Desktop / Tablet 2-Pane Layout (REQ-SET-2)
// ---------------------------------------------------------------------------

test('SettingsModal implements 2-pane desktop layout with container dimensions', () => {
  const content = fs.readFileSync(SETTINGS_MODAL_PATH, 'utf-8');

  // Desktop container tokens: rounded-2xl border border-subtle bg-surface shadow-overlay overflow-hidden flex w-full max-w-5xl h-[calc(var(--app-viewport-height)*0.85)] max-h-[820px]
  assert.ok(content.includes('max-w-5xl'), 'Must have max-w-5xl');
  // REQ-MODAL-2 (was the literal `h-[85vh]`): REQ-SET-2's intent — 85% of the viewport, capped
  // at 820px — is unchanged; only the viewport it measures moved. `85vh` is 85% of the LAYOUT
  // viewport, which a software keyboard does not shrink, and `md:` starts at 768px so a
  // landscape phone takes this branch. `--app-viewport-height` tracks `visualViewport.height`.
  // Assert the var, not `vh`, so a regression back to a non-shrinking unit fails here.
  assert.ok(
    content.includes('md:h-[calc(var(--app-viewport-height)*0.85)]'),
    'Desktop height must be 85% of --app-viewport-height, not 85vh (REQ-MODAL-2)',
  );
  assert.ok(content.includes('max-h-[820px]'), 'Must have max-h-[820px]');
  assert.ok(content.includes('border-subtle'), 'Must use border-subtle');
  assert.ok(content.includes('bg-surface'), 'Must use bg-surface');
  assert.ok(content.includes('shadow-overlay'), 'Must use shadow-overlay');

  // Left sidebar pane (w-64 border-r border-subtle flex flex-col bg-surface-raised/40)
  assert.ok(content.includes('w-64'), 'Sidebar must have w-64 width');
  assert.ok(content.includes('border-r border-subtle'), 'Sidebar must have border-r border-subtle');
  assert.ok(content.includes('bg-surface-raised/40'), 'Sidebar must use bg-surface-raised/40');
  assert.ok(content.includes('settings-desktop-sidebar'), 'Sidebar must have debug id');

  // Right content pane (flex-1 flex flex-col overflow-hidden bg-surface)
  assert.ok(content.includes('settings-desktop-content'), 'Content pane must have debug id');
  assert.ok(
    content.includes('settings-modal-close-button'),
    'Must have close button in header',
  );
});

test('SettingsModal desktop sidebar renders canonical categories and footer', () => {
  const content = fs.readFileSync(SETTINGS_MODAL_PATH, 'utf-8');

  // Header
  assert.ok(content.includes('Settings'), 'Must have Settings header');

  // Canonical categories (Projects is excluded per user directive: dedicated primary nav; General removed per REQ-SET-FIX-5)
  const categories = [
    'Appearance',
    'Notifications',
    'Models',
    'Workspace Settings',
    'User Vault',
    'Language Servers',
    'User Tokens',
    'Templates',
    'Experimental',
  ];
  for (const cat of categories) {
    assert.ok(content.includes(cat), `Sidebar must include category: ${cat}`);
  }

  // Canonical category IDs present in SETTINGS_CATEGORIES (REQ-SET-FIX-4)
  const canonicalCategoryIds = [
    'vault',
    'lsp',
    'user-tokens',
    'templates',
    'experimental',
  ];
  for (const id of canonicalCategoryIds) {
    assert.ok(
      content.includes(`id: '${id}'`),
      `SETTINGS_CATEGORIES must include id: '${id}'`,
    );
  }

  // Projects must NOT be in SETTINGS_CATEGORIES (dedicated primary navigation view)
  assert.ok(
    !content.includes("id: 'projects'"),
    "SETTINGS_CATEGORIES must not include id: 'projects'",
  );
  assert.ok(
    !content.includes("label: 'Projects'"),
    "SETTINGS_CATEGORIES must not include label: 'Projects'",
  );

  // General must NOT be in SETTINGS_CATEGORIES (REQ-SET-FIX-5)
  assert.ok(
    !content.includes("id: 'general'"),
    "SETTINGS_CATEGORIES must not include id: 'general'",
  );
  assert.ok(
    !content.includes("label: 'General'"),
    "SETTINGS_CATEGORIES must not include label: 'General'",
  );

  // Removed obsolete category IDs and labels (REQ-SET-FIX-4, REQ-SET-FIX-5)
  const removedCategoryIds = [
    'general',
    'best-of-n',
    'jetski-chat',
    'labs',
    'regroup-g3',
    'projects',
  ];
  for (const id of removedCategoryIds) {
    assert.ok(
      !content.includes(`id: '${id}'`),
      `SETTINGS_CATEGORIES must not include id: '${id}'`,
    );
  }

  const removedCategories = [
    'General',
    'Best of N',
    'Jetski Chat',
    'Labs',
    'Regroup Google3 Chats',
    'Projects',
  ];
  for (const cat of removedCategories) {
    assert.ok(!content.includes(`label: '${cat}'`), `Sidebar must not include category: ${cat}`);
  }

  // Assert custom projects list, conversations, and removed placeholders are NOT present in navigation
  assert.ok(!content.includes('NOT IN PROJECT'), 'Must not include NOT IN PROJECT section');
  assert.ok(!content.includes('BestOfNSettingsPlaceholder'), 'Must not include BestOfNSettingsPlaceholder');
  assert.ok(!content.includes('JetskiChatSettingsPlaceholder'), 'Must not include JetskiChatSettingsPlaceholder');
  assert.ok(!content.includes('RegroupG3SettingsPlaceholder'), 'Must not include RegroupG3SettingsPlaceholder');
  assert.ok(!content.includes('ConversationsSettingsPlaceholder'), 'Must not include ConversationsSettingsPlaceholder');
  assert.ok(!content.includes('settings-nav-item-conversations'), 'Must not include conversations nav item');

  // Removed placeholders must not remain in desktop/mobile navigation or page code.
  for (const removed of ['BrowserSettingsPlaceholder', 'ShortcutsSettingsPlaceholder', 'FeedbackSettingsPlaceholder']) {
    assert.ok(!content.includes(removed), `Must remove placeholder page: ${removed}`);
  }
  for (const debugId of ['settings-nav-item-shortcuts', 'settings-nav-item-feedback', 'mobile-nav-item-shortcuts', 'mobile-nav-item-feedback']) {
    assert.ok(!content.includes(debugId), `Must remove settings navigation item: ${debugId}`);
  }
  assert.ok(
    content.includes('settings-user-profile-card'),
    'Must include user profile card',
  );
  assert.ok(
    content.includes('settings-user-display-name'),
    'Must render user display name',
  );
  assert.ok(content.includes('settings-user-email'), 'Must render user email');
});

test('SettingsModal gates Language Servers (LSP) category on experiment flag', () => {
  const content = fs.readFileSync(SETTINGS_MODAL_PATH, 'utf-8');

  // Must import and use useFetchExperimentsQuery
  assert.ok(
    content.includes('useFetchExperimentsQuery'),
    'SettingsModal must import and call useFetchExperimentsQuery',
  );

  // Must derive lspEnabled flag from experiments
  assert.ok(
    content.includes("key === 'lsp'") || content.includes('key === "lsp"'),
    'SettingsModal must check experiment flag for lsp',
  );
  assert.ok(
    content.includes('lspEnabled'),
    'SettingsModal must declare lspEnabled',
  );

  // Must gate lsp in visible categories
  assert.ok(
    content.includes('getVisibleSettingsCategories') ||
      content.includes("category.id !== 'lsp' || lspEnabled") ||
      content.includes("c.id !== 'lsp' || lspEnabled"),
    'SettingsModal must filter lsp category unless lspEnabled is true',
  );
});

// ---------------------------------------------------------------------------
// 4. Mobile Presentation & Master-Detail Navigation (REQ-SET-4, REQ-SET-6 item 4)
// ---------------------------------------------------------------------------

test('SettingsModal implements mobile master-detail navigation with >=44px touch targets', () => {
  const content = fs.readFileSync(SETTINGS_MODAL_PATH, 'utf-8');

  // Full viewport on mobile
  assert.ok(
    content.includes('fixed inset-x-0 top-0 app-viewport-height'),
    'Must cover the VISIBLE viewport — `app-viewport-height`, not `inset-0` (REQ-VIEWPORT-SWEEP-1)',
  );
  assert.ok(
    content.includes('settings-mobile-master-view'),
    'Must have mobile master view',
  );
  assert.ok(
    content.includes('settings-mobile-detail-view'),
    'Must have mobile detail view',
  );

  // Master view: sticky top header with Settings title and close button
  assert.ok(
    content.includes('btn-close-mobile-settings-master'),
    'Master view must have close button',
  );
  assert.ok(
    content.includes('mobile-user-profile-card'),
    'Master view must have user profile card at bottom',
  );

  // Detail view: sticky top header with < Back button, section title, and close button
  assert.ok(
    content.includes('btn-back-mobile-settings'),
    'Detail view must have Back button',
  );
  assert.ok(
    content.includes('btn-close-mobile-settings-detail'),
    'Detail view must have close button',
  );

  // Touch targets >= 44px
  assert.ok(
    content.includes('min-h-[44px]'),
    'Interactive rows must specify min-h-[44px] touch target floor',
  );
  assert.ok(
    content.includes('h-11 w-11'),
    'Close buttons must have 44px (h-11 w-11) touch targets',
  );
});

// ---------------------------------------------------------------------------
// 5. Panel Embedding & Integration (REQ-SET-5)
// ---------------------------------------------------------------------------

test('SettingsModal embeds all required panels', () => {
  const content = fs.readFileSync(SETTINGS_MODAL_PATH, 'utf-8');

  // Verify imports for canonical panels (REQ-SET-FIX-4)
  assert.ok(content.includes("import VaultPanel from './VaultPanel'"), 'Must import VaultPanel');
  assert.ok(content.includes("import LspPanel from './LspPanel'"), 'Must import LspPanel');
  assert.ok(content.includes("import UserTokensPanel from './UserTokensPanel'"), 'Must import UserTokensPanel');
  assert.ok(content.includes("import TemplatesPanel from './TemplatesPanel'"), 'Must import TemplatesPanel');
  assert.ok(!content.includes("import ProjectsPanel from './ProjectsPanel'"), 'ProjectsPanel must not be imported in SettingsModal');
  assert.ok(content.includes("import ExperimentalPanel from './ExperimentalPanel'"), 'Must import ExperimentalPanel');

  // GeneralSettingsPanel must NOT be imported or rendered in SettingsModal (REQ-SET-FIX-5)
  assert.ok(
    !content.includes('GeneralSettingsPanel'),
    'GeneralSettingsPanel must not be imported or rendered in SettingsModal',
  );

  // AppearanceSettings
  assert.ok(
    content.includes('<AppearanceSettings'),
    'Must embed AppearanceSettings',
  );

  // NotificationsPanel
  assert.ok(
    content.includes('<NotificationsPanel'),
    'Must embed NotificationsPanel',
  );

  // ProvidersPanel
  assert.ok(
    content.includes('<ProvidersPanel'),
    'Must embed ProvidersPanel',
  );

  // BridgesPanel
  assert.ok(
    content.includes('<BridgesPanel'),
    'Must embed BridgesPanel',
  );

  // ProjectsPanel must NOT be embedded (Projects has dedicated primary navigation)
  assert.ok(
    !content.includes('<ProjectsPanel'),
    'ProjectsPanel must not be embedded in SettingsModal',
  );

  // ExperimentalPanel
  assert.ok(
    content.includes('<ExperimentalPanel'),
    'Must embed ExperimentalPanel',
  );

  // VaultPanel
  assert.ok(
    content.includes('<VaultPanel'),
    'Must embed VaultPanel',
  );

  // LspPanel
  assert.ok(
    content.includes('<LspPanel'),
    'Must embed LspPanel',
  );

  // UserTokensPanel
  assert.ok(
    content.includes('<UserTokensPanel'),
    'Must embed UserTokensPanel',
  );

  // TemplatesPanel
  assert.ok(
    content.includes('<TemplatesPanel'),
    'Must embed TemplatesPanel',
  );
});

// ---------------------------------------------------------------------------
// 6. SettingsModal Excision of General Section & Default Tab (REQ-SET-FIX-5)
// ---------------------------------------------------------------------------

test('SettingsModal defaults activeTab to appearance when initialTab is not provided', () => {
  const content = fs.readFileSync(SETTINGS_MODAL_PATH, 'utf-8');
  assert.ok(
    content.includes('normalizeSettingsTab(initialTab)'),
    'activeTab state must normalize missing, aliased, and retired tabs to appearance',
  );
});

test('GeneralSettingsPanel is not imported or rendered in SettingsModal.tsx', () => {
  const content = fs.readFileSync(SETTINGS_MODAL_PATH, 'utf-8');
  assert.ok(
    !content.includes('GeneralSettingsPanel'),
    'GeneralSettingsPanel must not be imported or rendered in SettingsModal.tsx',
  );
});

test('SETTINGS_CATEGORIES does not include general section', () => {
  const content = fs.readFileSync(SETTINGS_MODAL_PATH, 'utf-8');
  assert.ok(
    !content.includes("id: 'general'"),
    "SETTINGS_CATEGORIES must not include id: 'general'",
  );
  assert.ok(
    !content.includes("label: 'General'"),
    "SETTINGS_CATEGORIES must not include label: 'General'",
  );
});

// ---------------------------------------------------------------------------
// 7. settingsPersistence Load & Save Round-Trip (REQ-SET-3, REQ-SET-6 item 3)
// ---------------------------------------------------------------------------

test('settingsPersistence correctly loads defaults, serializes, and deserializes to localStorage', () => {
  const mockStorage = new MockStorage();
  (globalThis as any).window = {
    localStorage: mockStorage,
  };

  // 1. Load defaults
  const defaults = loadSettings();
  assert.equal(defaults.queuedMessages, 'queue');
  assert.equal(defaults.permissionPreset, 'default');
  assert.equal(defaults.planReviewPolicy, 'always_ask');
  assert.equal(defaults.browserJsExecutionPolicy, 'request_review');
  assert.equal(defaults.advancedExpanded, true);

  // 2. Save modified settings
  saveSettings({
    queuedMessages: 'send_immediately',
    permissionPreset: 'strict',
    planReviewPolicy: 'never_ask',
    browserJsExecutionPolicy: 'disabled',
    commandSetupScript: 'echo "testing settings roundtrip"',
    advancedExpanded: false,
  });

  const raw = mockStorage.getItem(SETTINGS_STORAGE_KEY);
  assert.ok(raw !== null, 'Item should be written to storage key');
  const parsed = JSON.parse(raw);
  assert.equal(parsed.queuedMessages, 'send_immediately');
  assert.equal(parsed.permissionPreset, 'strict');
  assert.equal(parsed.planReviewPolicy, 'never_ask');
  assert.equal(parsed.browserJsExecutionPolicy, 'disabled');
  assert.equal(parsed.commandSetupScript, 'echo "testing settings roundtrip"');
  assert.equal(parsed.advancedExpanded, false);

  // 3. LoadSettings deserializes accurately
  const loaded = loadSettings();
  assert.equal(loaded.queuedMessages, 'send_immediately');
  assert.equal(loaded.permissionPreset, 'strict');
  assert.equal(loaded.planReviewPolicy, 'never_ask');
  assert.equal(loaded.browserJsExecutionPolicy, 'disabled');
  assert.equal(loaded.commandSetupScript, 'echo "testing settings roundtrip"');
  assert.equal(loaded.advancedExpanded, false);

  // 4. Partial update support
  saveSettings({ queuedMessages: 'queue' });
  const partiallyUpdated = loadSettings();
  assert.equal(partiallyUpdated.queuedMessages, 'queue');
  assert.equal(partiallyUpdated.permissionPreset, 'strict'); // Preserved from previous save
});

// ---------------------------------------------------------------------------
// 8. AppShell Routing Integration (REQ-SET-5, REQ-SET-6 item 5)
// ---------------------------------------------------------------------------

test('AppShell routing integration ensures settings routes resolve without crashing', () => {
  assert.ok(fs.existsSync(APP_SHELL_PATH), 'AppShell.tsx must exist');
  const content = fs.readFileSync(APP_SHELL_PATH, 'utf-8');

  // Mounts SettingsModal with open, onOpenChange, and initialTab
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

  // Deep link route resolution (REQ-SET-FIX-5: /settings and /settings/general default to appearance)
  assert.equal(resolveSettingsTab('/settings'), '');
  assert.equal(resolveSettingsTab('/settings/'), '');
  assert.equal(resolveSettingsTab('/settings/general'), '');
  assert.equal(resolveSettingsTab('/settings/appearance'), 'appearance');
  assert.equal(resolveSettingsTab('/settings/bridges'), 'bridges');
  assert.equal(resolveSettingsTab('/settings/notifications'), 'notifications');
  assert.equal(resolveSettingsTab('/settings/providers'), 'providers');
  assert.equal(resolveSettingsTab('/settings/projects'), 'projects');
  assert.equal(resolveSettingsTab('/settings/experimental'), 'experimental');
  assert.equal(resolveSettingsTab('/settings/vault'), 'vault');
  assert.equal(resolveSettingsTab('/settings/lsp'), 'lsp');
  assert.equal(resolveSettingsTab('/settings/user-tokens'), 'user-tokens');
  assert.equal(resolveSettingsTab('/settings/templates'), 'templates');
  assert.equal(resolveSettingsTab('#/settings/vault'), 'vault');
  assert.equal(resolveSettingsTab('#/settings/lsp'), 'lsp');
  assert.equal(resolveSettingsTab('#/settings/user-tokens'), 'user-tokens');
  assert.equal(resolveSettingsTab('#/settings/templates'), 'templates');
  assert.equal(resolveSettingsTab('#/settings/projects'), 'projects');
  assert.equal(resolveSettingsTab('#/settings/experimental'), 'experimental');

  // Alias normalization (REQ-SET-FIX-5: general and empty normalize to appearance)
  assert.equal(normalizeSettingsTab('bridges'), 'workspace');
  assert.equal(normalizeSettingsTab('providers'), 'models');
  assert.equal(normalizeSettingsTab('labs'), 'experimental');
  assert.equal(normalizeSettingsTab('experimental'), 'experimental');
  assert.equal(normalizeSettingsTab('vault'), 'vault');
  assert.equal(normalizeSettingsTab('lsp'), 'lsp');
  assert.equal(normalizeSettingsTab('user-tokens'), 'user-tokens');
  assert.equal(normalizeSettingsTab('templates'), 'templates');
  assert.equal(normalizeSettingsTab('projects'), 'projects');
  assert.equal(normalizeSettingsTab('general'), 'account');
  assert.equal(normalizeSettingsTab(), 'account');

  // Command palette integration
  const settingsNav = DEFAULT_NAV.find((item) => item.label === 'Settings');
  assert.ok(settingsNav, 'DEFAULT_NAV must include Settings');
  assert.ok(
    settingsNav.route.startsWith('/settings'),
    'Settings nav route must start with /settings',
  );

  // Modal closing restoration
  assert.ok(
    content.includes("currentPath.startsWith('/settings')"),
    'Must check if current path is a settings path on modal close',
  );
  assert.ok(
    content.includes('window.history.back()'),
    'Must call window.history.back() when closing from a settings route',
  );
});

test('palette settings open the landing view, not Appearance (REQ-3)', () => {
  const shell = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx'), 'utf8');
  const modal = fs.readFileSync(SETTINGS_MODAL_PATH, 'utf8');

  // The sidebar Settings nav item was removed; the user row opens Settings instead.
  assert.ok(!shell.includes('data-debug-id="shell-secondary-nav"'), 'sidebar Settings nav entry is removed');

  // Palette: settings/settings-modal open landing; theme actions still go to Appearance.
  assert.match(shell, /case 'settings':\s*case 'settings-modal':\s*setSettingsModalTab\(''\);/);
  assert.match(shell, /case 'settings-appearance':\s*case 'change-theme':\s*setSettingsModalTab\('appearance'\);/);

  // No-tab open: desktop resets to the default category, mobile resets to the category list.
  assert.ok(modal.includes('setActiveTab(normalizeSettingsTab());'), 'no-tab open must reset desktop tab to default');
  assert.equal(normalizeSettingsTab(), 'account');

  // Routing helpers come from the shared module the tests exercise (no private copies).
  assert.ok(!shell.includes('export function resolveSettingsTab'), 'AppShell must not keep a private resolveSettingsTab');
  assert.ok(!modal.includes('export function normalizeSettingsTab'), 'SettingsModal must not keep a private normalizeSettingsTab');
});
