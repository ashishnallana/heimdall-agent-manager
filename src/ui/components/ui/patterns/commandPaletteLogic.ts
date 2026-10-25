/**
 * Pure logic and contracts for CommandPalette (EL-056 / REQ-SEARCH-PALETTE-UI-1).
 * Extracted to allow unit testing with native Node.js test runner (Node 24 type stripping).
 */
import type { Tone } from '../types';
import type { IconName } from '../primitives';
import { THEMES } from '../../../theme/registry.ts';
import { isVaultArmored } from '../../../utils/vaultContent.ts';
import { chainConversationRoute } from '../../../utils/paneTarget.ts';

export type PaletteConversation = {
  conversationId: string;
  agentInstanceId?: string;
  title: string;
  agentName?: string;
  isCoordinator?: boolean;
  runtimeStatus?: string;
  activityStatus?: string;
  unreadCount?: number;
};

export type PaletteConversationGroup = {
  projectId: string;
  projectName: string;
  conversations: PaletteConversation[];
};

export type PaletteScope = {
  chainId?: string;
  conversationId?: string;
  label?: string;
};

export type PaletteAction = {
  id: string;
  label: string;
  hint?: string;
  badge?: string;
  icon?: IconName;
  route?: string;
};

export type PaletteShortcutSource = {
  id: string;
  title: string;
  sequence: readonly string[];
  isEnabled?: () => boolean;
};

export type PaletteResult =
  | { kind: 'navigate'; label: string; hint?: string; icon?: IconName; route: string; group: string }
  | { kind: 'action'; label: string; hint?: string; badge?: string; icon?: IconName; actionId: string; route?: string; group: 'Actions' }
  | { kind: 'conversation'; label: string; hint?: string; route: string; group: string; convo: PaletteConversation }
  | { kind: 'chain'; label: string; hint?: string; route: string; group: string; chainId: string; status?: string; projectId?: string; projectName?: string };

export function chainStatusDot(status?: string): { tone: Tone; pulse: boolean } {
  const s = String(status || '').toLowerCase();
  switch (s) {
    case 'active':
    case 'in_progress':
      return { tone: 'success', pulse: true };
    case 'completed':
    case 'validated_good':
      return { tone: 'neutral', pulse: false };
    case 'paused':
      return { tone: 'warning', pulse: false };
    case 'cancelled':
    case 'validated_not_good':
      return { tone: 'danger', pulse: false };
    default:
      return { tone: 'neutral', pulse: false };
  }
}

/**
 * A chain with a coordinator opens its chain-addressed conversation
 * (`/conversations/chain:<id>`, REQ-TV2-7); one without opens the chain page.
 */
export function taskChainRoute(chain: { chainId: string; coordinatorAgentInstanceId?: string }): string {
  return chain.coordinatorAgentInstanceId
    ? chainConversationRoute(chain.chainId)
    : `/chains/${encodeURIComponent(chain.chainId)}`;
}

export const optionId = (i: number) => `command-palette-option-${i}`;


export function matchesQuery(haystack: string, q: string): boolean {
  if (isVaultArmored(haystack)) return false;
  return haystack.toLowerCase().includes(q.toLowerCase());
}

export const DEFAULT_NAV: { label: string; icon: IconName; route: string }[] = [
  { label: 'Cards', icon: 'spark', route: '/cards' },
  { label: 'Conversations', icon: 'chat', route: '/conversations' },
  { label: 'Actions', icon: 'clock', route: '/actions' },
  { label: 'Projects', icon: 'grid', route: '/projects' },
  { label: 'Agents', icon: 'bot', route: '/agents' },
  { label: 'Memory', icon: 'spark', route: '/memory' },
  { label: 'Shells', icon: 'terminal', route: '/shells' },
  { label: 'Task Chains', icon: 'tasks', route: '/chains' },
  { label: 'Library', icon: 'device', route: '/library' },
  { label: 'Settings', icon: 'gear', route: '/settings/bridges' },
  { label: 'Appearance', icon: 'spark', route: '/settings/appearance' },
];

/**
 * REQ-EXP-GATE-2: palette navigation entries. The Actions entry is listed only
 * while the Actions experiment is enabled (callers pass false for loading,
 * disabled, absent or failed-to-load flags).
 */
export function paletteNavItems(actionsEnabled: boolean): typeof DEFAULT_NAV {
  return actionsEnabled ? DEFAULT_NAV : DEFAULT_NAV.filter((item) => item.route !== '/actions');
}

export const DEFAULT_ACTIONS: PaletteAction[] = [
  { id: 'new-conversation', label: 'New conversation', icon: 'plus', hint: 'Start a new conversation', route: '/conversations/new' },
  { id: 'new-agent', label: 'New agent', icon: 'bot', hint: 'Create a durable identity', route: '/agents/new' },
  { id: 'new-chain', label: 'New task chain', icon: 'tasks', hint: 'Start a chain', route: '/chains' },
  { id: 'new-project', label: 'New project', icon: 'grid', hint: 'Grouping + paths', route: '/projects' },
  { id: 'settings', label: 'Settings', icon: 'gear', hint: 'Settings & preferences', route: '/settings' },
  { id: 'settings-appearance', label: 'Appearance & Themes', icon: 'spark', hint: 'Theme settings', route: '/settings/appearance' },
  ...THEMES.map((t) => ({
    id: `set-theme-${t.id}`,
    label: `Theme: ${t.label}`,
    hint: `Switch theme`,
    badge: t.appearance === 'light' ? 'Light' : 'Dark',
    icon: 'spark' as IconName,
  })),
];

/** Merge live shortcut actions into the palette without mutating its static defaults. */
export function mergePaletteActions(
  staticActions: readonly PaletteAction[],
  shortcutActions: readonly PaletteShortcutSource[],
): PaletteAction[] {
  const merged = new Map(staticActions.map((action) => [action.id, action]));
  for (const action of shortcutActions) {
    if (action.isEnabled?.() === false) continue;
    const sequence = action.sequence.join(' ');
    merged.set(action.id, {
      id: action.id,
      label: action.title,
      hint: sequence ? `Shortcut: ${sequence}` : undefined,
      badge: sequence || undefined,
    });
  }
  return Array.from(merged.values());
}
