/**
 * Pure settings route resolution and tab normalization logic.
 * Extracted to allow direct execution in native Node.js test runners without bundler alias overhead.
 * AppShell and SettingsModal import these, so the tests exercise the code that actually ships.
 */

/** Default tab for desktop when Settings is opened without a specific tab (mobile shows the category list instead). */
export const DEFAULT_SETTINGS_TAB = 'account';

/**
 * Maps a route to the settings tab it names. Returns '' when no tab is named
 * (`/settings`, `/settings/general`, or a non-settings route) so the modal opens on its landing view.
 */
export function resolveSettingsTab(path: string): string {
  const cleanPath = (path.startsWith('#') ? path.slice(1) : path).split('?')[0];
  if (!cleanPath.startsWith('/settings')) return '';
  const sub = cleanPath.slice('/settings'.length).replace(/^\//, '').split('/')[0] || '';
  if (!sub || sub === 'general') return '';
  return sub;
}

export function normalizeSettingsTab(tab?: string): string {
  if (!tab || tab === 'general') return DEFAULT_SETTINGS_TAB;
  // REQ-ENR-11: Workspace Settings was replaced by Bridges; old links land there.
  if (tab === 'workspace') return 'bridges';
  if (tab === 'providers') return 'models';
  if (tab === 'labs') return 'experimental';
  if (tab === 'browser' || tab === 'shortcuts' || tab === 'feedback') return 'appearance';
  return tab;
}
