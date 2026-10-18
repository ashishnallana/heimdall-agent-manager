import TaskChainsPage from '../taskchain/TaskChainsPage';
import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import NewConversationPage from '../chat/NewConversationPage';
import ConversationsHomePage from '../chat/ConversationsHomePage';
import ConversationSelectorModal from '../chat/ConversationSelectorModal';
import RunningShellSelectorModal from '../chat/RunningShellSelectorModal';
import Icon, { type IconName } from '../Icon';
import {
  Badge,
  Breadcrumbs as UiBreadcrumbs,
  CommandPalette,
  DEFAULT_ACTIONS,
  PageShell,
  StatusDot,
  mergePaletteActions,
} from '@ui';
import { useIsMobile, useViewport } from './responsive';
import { AuthUserProvider, type AuthUserIdentity } from '../auth/AuthUserContext';
import { isAgentWorking } from './agentWorking';
import { heimdallApi } from '../../api/heimdallApi';
import { withApiBase } from '../../api/apiBase';
import { useUserWebSocket } from '../../api/useUserWebSocket';
import { cookieJsonFetch, cookieMutation } from '../../api/cookieFetch';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { useListSidebarConversationsQuery, type SidebarConversation } from '../../api/endpoints/sidebar';
import { useGetAgentsLiveQuery, type LiveProject } from '../../api/endpoints/agentsLive';
import { useFetchTaskChainGroupsQuery } from '../../api/endpoints/tasks';
import { useListBridgesQuery, type Bridge } from '../../api/endpoints/bridgeSupport';
import { useListShellsQuery } from '../../api/endpoints/shells';
import { StatusBar } from './statusBar/StatusBar';
import { STATUS_BAR_MODULES } from './statusBar/modules';
import { countRunningInstances, countShells } from './statusBar/statusBarModel';
import { AttentionDeck, AttentionUndoToast } from '../attention';
import { attentionApi, useGetAttentionSummaryQuery, type AttentionRange } from '../../api/endpoints/attention';
import { readAttentionRange, writeAttentionRange } from '../../services/attention/attentionPrefs';
import { useGetAccountBillingQuery } from '../../api/endpoints/accountBilling';
import SidebarUpdateBadge from './SidebarUpdateBadge';
import {
  chromeIconButtonSizeClass,
  topChromeHeight,
  topLeftClusterWidth as computeTopLeftClusterWidth,
  isAgentConversationRoute,
} from './shellChrome';
import type { PendingBridgeUpdate } from '../settings/bridgeUpdate';
import {
  lockAllConnectedBridges,
  reconcileLockedBridges,
  type BridgeVaultReconciliationResult,
} from '../../api/endpoints/bridges';
import { buildRouteHash, getRoutePathname, getRouteSearch } from '../../utils/appLocation';
import {
  readLastSeenUserId,
  removeAppOwnedClientStorage,
  writeLastSeenUserId,
} from '../../utils/clientPersistence';
import { Workspace } from '../mainWorkspace/Workspace';
import BridgeEnrollmentApprovalPage from '../enrollment/BridgeEnrollmentApprovalPage';
import ProviderEnrollmentSetupPage from '../providers/ProviderEnrollmentSetupPage';
import BridgesPanel from '../settings/BridgesPanel';
import ProjectsPanel from '../settings/ProjectsPanel';
import TemplatesPanel from '../settings/TemplatesPanel';
import AppearanceSettings from '../settings/AppearanceSettings';
import { setTheme } from '../../store/themeSlice';
import ProjectListPage from '../projects/ProjectListPage';
import ProjectViewPage from '../projects/ProjectViewPage';
import ProjectFormPage from '../projects/ProjectFormPage';
import ProjectLaunchModal from '../projects/ProjectLaunchModal';
import CardsPanel from '../cards/CardsPanel';
import HomePage from '../home/HomePage';
import ErrorBoundary from './ErrorBoundary';
import ActionListPage from '../actions/ActionListPage';
import ActionViewPage from '../actions/ActionViewPage';
import ActionFormPage from '../actions/ActionFormPage';
import ShellListPage from '../shells/ShellListPage';
import ShellViewPage from '../shells/ShellViewPage';
import AgentListPage from '../agents/AgentListPage';
import AgentViewPage from '../agents/AgentViewPage';
import AgentFormPage from '../agents/AgentFormPage';
import { ProviderEditorPage, ProvidersPanel } from '../settings/ProvidersPanel';
import UserTokensPanel from '../settings/UserTokensPanel';
import MemoryListPage from '../memory/MemoryListPage';
import MemoryViewPage from '../memory/MemoryViewPage';
import MemoryFormPage from '../memory/MemoryFormPage';
import IssueListPage from '../issues/IssueListPage';
import IssueFormPage from '../issues/IssueFormPage';
import SkillViewerPage from '../skills/SkillViewerPage';
import NotificationsPanel from '../settings/NotificationsPanel';
import ExperimentalPanel from '../settings/ExperimentalPanel';
import VaultPanel from '../settings/VaultPanel';
import { VaultOnboardingHost } from '../settings/VaultOnboardingHost';
import SettingsModal from '../settings/SettingsModal';
import { resolveSettingsTab } from '../../utils/settingsRouting';
import { useShortcuts } from '../../services/shortcuts/ShortcutContext';
import { useRegisterActions } from '../../services/shortcuts/useRegisterActions';
import {
  selectIsVaultConfigured,
  selectIsVaultUnlocked,
  setUnlockModalOpen,
  readOnboardingDismissed,
  shouldOpenVaultOnboarding,
  getActiveVaultKey,
  getActiveBridgeVaultKeyMaterial,
  setActiveBridgeVaultKeyMaterial,
  setActiveVaultUserId,
  lockVault,
} from '../../store/vaultSlice';
import { isVaultSupported } from '../../utils/vaultCrypto';
import {
  setBulkChainTitles,
  selectSearchChains,
} from '../../store/searchTitleSlice';
import { isVaultArmored } from '../../utils/vaultContent';
import { VaultText } from '../vault/VaultText';
import { batchDecryptTitles, type RawSearchItemInput } from '../../utils/vaultSearch';
import LspPanel from '../settings/LspPanel';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import LibraryPage from '../LibraryPage';
import ArtifactViewer from '../ArtifactViewer';
import { clearUserClientState } from '../../store/chatSlice';
import { priorUserClientStateCleared } from '../../store/store';
import { selectAuxOpen, selectCurrentAuxTreeId } from '../../store/auxPanesSlice';
import { selectOnlineLockedBridgeIds } from '../../utils/bridgeVaultStatus';
import TaskChainSelectorModal from '../chains/TaskChainSelectorModal';
import type { LauncherIntent } from '../../store/workspaceLayoutSlice';

type ShellRoute = {
  path: string;
  label: string;
  icon: IconName;
  description: string;
  group: 'primary' | 'secondary';
};

type AuthUser = AuthUserIdentity;

type AuthStatus = 'checking' | 'authenticated' | 'unauthenticated' | 'forbidden' | 'error';

type AuthState = {
  status: AuthStatus;
  user: AuthUser | null;
  loginUrl: string;
  logoutUrl: string;
  error: string;
};


type ConversationSummary = {
  conversationId: string;
  agentId: string;
  agentInstanceId: string;
  agentName: string;
  // True when THIS agent instance is a coordinator of its chain (per
  // /api/v1/agents/live). Renders the agent's own name gold in the rail/palette.
  isCoordinator?: boolean;
  // True on the first row of a chain-group (except the project's first group), so
  // the rail draws a subtle separator between chain-groups within a project.
  startsNewGroup?: boolean;
  projectId: string;
  title: string;
  unreadCount: number;
  updatedAt: string;
  lastMessageAt?: string;
  lastMessagePreview?: string;
  lastMessageDirection?: string;
  lastMessageUnixMs?: number;
  lastMessage?: any;
  participants?: any[];
  bridgeId?: string;
  runtimeStatus?: string;
  // H13: activity_status so the sidebar dot animates only when working.
  activityStatus?: string;
};

type ProjectSummary = {
  projectId: string;
  name: string;
  isDefaultConversations?: boolean;
  projectType?: string;
  workspaceName?: string;
};

type ProjectGroup = {
  project: ProjectSummary;
  unreadCount: number;
  conversations: ConversationSummary[];
};

type BreadcrumbCrumb = { label: string; href?: string };

const DEFAULT_CONVERSATIONS_PROJECT: ProjectSummary = {
  projectId: 'default-conversations',
  name: 'Conversations',
  isDefaultConversations: true,
};
const NAV_ROUTES: ShellRoute[] = [
  // '+ New conversation' opens the start-conversation page. Conversations and
  // Task Chains are no longer sidebar destinations (their routes still work).
  { path: '/home', label: 'New conversation', icon: 'plus', description: 'Start a new conversation', group: 'primary' },
  { path: '/actions', label: 'Actions', icon: 'clock', description: 'Scheduled and on-demand prompts sent to your agents', group: 'primary' },
  { path: '/projects', label: 'Projects', icon: 'grid', description: 'Projects, their agents, memory and bridge paths', group: 'primary' },
  { path: '/agents', label: 'Agents', icon: 'bot', description: 'Agent identities and sessions', group: 'primary' },
  { path: '/memory', label: 'Memory', icon: 'spark', description: 'Durable facts, habits & skills for your agents', group: 'primary' },
  { path: '/shells', label: 'Shells', icon: 'terminal', description: 'Every shell session your bridges are running', group: 'primary' },
  { path: '/issues', label: 'Issues', icon: 'alert', description: 'Reported issues across projects, agents, and bridges', group: 'primary' },
];

function routeFromLocation(): string {
  let path = getRoutePathname();
  if (path.length > 1 && path.endsWith('/')) {
    path = path.slice(0, -1);
  }
  if (!path || path === '/' || path === '/index.html' || path === '/cards' || path.includes('/preview/') || path.includes('/proxy/')) return '/home';
  if (path.startsWith('/c/')) return `/conversations/${path.slice('/c/'.length)}`;
  return path;
}

// Deep-link focus target for a conversation message: parse `?msg=<message_id>` from
// the hash search so a `message` search hit (/conversations/:id?msg=:mid) can scroll
// to + highlight that message. Empty when absent. Tracked as its own state because
// routeFromLocation() strips the query, so a msg-only change would not re-render.
function focusMessageFromLocation(): string {
  const search = getRouteSearch();
  if (!search) return '';
  try {
    return new URLSearchParams(search.startsWith('?') ? search.slice(1) : search).get('msg') || '';
  } catch {
    return '';
  }
}

function routeSearchFromLocation(): string {
  return getRouteSearch();
}

function launcherIntentFromSearch(search: string): LauncherIntent | undefined {
  const intent = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search).get('intent');
  return intent === 'agent' || intent === 'shell' ? intent : undefined;
}

function isRouteActive(currentPath: string, itemPath: string): boolean {
  if (itemPath === '/home') return currentPath === '/home' || currentPath.startsWith('/home/') || currentPath === '/cards' || currentPath.startsWith('/cards/');
  if (itemPath === '/cards') return currentPath === '/cards' || currentPath.startsWith('/cards/') || currentPath === '/home' || currentPath.startsWith('/home/');
  if (itemPath === '/conversations') return currentPath === '/conversations' || currentPath.startsWith('/conversations/');
  if (itemPath === '/actions') return currentPath === '/actions' || currentPath.startsWith('/actions/');
  if (itemPath === '/settings/bridges') return currentPath.startsWith('/settings');
  if (itemPath === '/memory') return currentPath === '/memory' || currentPath.startsWith('/memory/');
  if (itemPath === '/shells') return currentPath === '/shells' || currentPath.startsWith('/shells/');
  return currentPath === itemPath || currentPath.startsWith(`${itemPath}/`);
}

// Parse '/chains/:chainId(/tasks/:taskId)?' into its decoded parts. taskId is
// undefined for the plain '/chains/:chainId' route. Centralised so the content
// switch, breadcrumb, and any future consumer agree — a naive slice would pass the
// whole 'chain.../tasks/task...' string as the chainId and break the chain lookup.
function parseChainRoute(path: string): { chainId: string; taskId?: string } {
  const rest = path.slice('/chains/'.length);
  const tasksAt = rest.indexOf('/tasks/');
  if (tasksAt >= 0) {
    return {
      chainId: decodeURIComponent(rest.slice(0, tasksAt)),
      taskId: decodeURIComponent(rest.slice(tasksAt + '/tasks/'.length)),
    };
  }
  return { chainId: decodeURIComponent(rest) };
}

function routeTitle(path: string): string {
  if (path === '/home' || path.startsWith('/home') || path === '/cards' || path.startsWith('/cards')) return 'Home';
  if (path === '/conversations/new') return 'New conversation';
  if (path.startsWith('/conversations/')) return 'Conversation';
  if (path === '/actions/new') return 'New action';
  if (path.startsWith('/actions/') && path.endsWith('/edit')) return 'Edit action';
  if (path.startsWith('/actions/')) return 'Action detail';
  if (path.startsWith('/actions')) return 'Actions';
  if (path === '/chains/new') return 'New task chain';
  if (path.startsWith('/chains/') && path.includes('/tasks/')) return 'Task detail';
  if (path.startsWith('/chains/')) return 'Task chain';
  if (path === '/agents/new') return 'New agent';
  if (path.startsWith('/agents/')) return 'Agent detail';
  if (path.startsWith('/library/artifacts/')) return 'Artifact viewer';
  if (path.startsWith('/library')) return 'Library';
  if (path === '/issues/new') return 'New issue';
  if (path.startsWith('/issues/') && path.endsWith('/edit')) return 'Edit issue';
  if (path.startsWith('/issues/')) return 'Issue detail';
  if (path.startsWith('/issues')) return 'Issues';
  if (path === '/projects/new') return 'New project';
  if (path.startsWith('/projects/') && path.endsWith('/edit')) return 'Edit project';
  if (path.startsWith('/projects/')) return 'Project detail';
  if (path === '/memory/new') return 'New memory';
  if (path.startsWith('/memory/') && path.endsWith('/edit')) return 'Edit memory';
  if (path.startsWith('/memory/')) return 'Memory detail';
  if (path.startsWith('/memory')) return 'Memory';
  // Shells are runtime: there is no new/edit route to title (REQ-UI-15).
  if (path.startsWith('/shells/')) return 'Shell session';
  if (path.startsWith('/shells')) return 'Shells';
  if (path.startsWith('/skills/')) return 'Skill';
  if (path.startsWith('/settings/bridges')) return 'Bridge settings';
  if (path.startsWith('/settings/appearance')) return 'Appearance settings';
  if (path.startsWith('/settings/user-tokens')) return 'User token settings';
  if (path.startsWith('/settings/projects')) return 'Project settings';
  if (path.startsWith('/settings/providers')) return 'Provider settings';
  if (path.startsWith('/settings/templates')) return 'Templates';
  if (path.startsWith('/settings/notifications')) return 'Notification settings';
  if (path.startsWith('/settings/vault')) return 'User Vault';
  if (path.startsWith('/settings')) return 'Settings';
  if (path.startsWith('/agents')) return 'Agents';
  if (path.startsWith('/chains')) return 'Task Chains';
  return 'Conversations';
}

function routeDescription(path: string): string {
  if (path === '/home' || path.startsWith('/home') || path === '/cards' || path.startsWith('/cards')) return 'Recent task chains, issues, and action items.';
  if (path === '/conversations/new') return 'Choose a favorite agent and project, then send a message to start a conversation.';
  if (path.startsWith('/conversations/')) return 'Page-owned conversation area. The conversation inspector will be owned by this route, not by global shell chrome.';
  if (path === '/actions/new') return 'Create a scheduled or on-demand prompt targeted to an agent instance.';
  if (path.startsWith('/actions/') && path.endsWith('/edit')) return 'Update the prompt or schedule for this action.';
  if (path.startsWith('/actions/')) return 'One action: its prompt, its schedule and the agent it targets.';
  if (path.startsWith('/actions')) return 'Scheduled and on-demand prompts sent to your agents.';
  if (path.startsWith('/chains/')) return 'Creation-ordered task list and task-detail route outlet. No graph editor or global inspector is present.';
  if (path.startsWith('/agents/')) return 'Agent overview, sessions, Bridges, and memory tabs will attach to this route.';
  if (path.startsWith('/library/artifacts/')) return 'Fullscreen artifact viewer route owned by the Library surface.';
  if (path.startsWith('/library')) return 'Filterable artifact list/grid route.';
  if (path.startsWith('/issues')) return 'Reported issues across projects, agents, and bridges.';
  if (path.startsWith('/projects/')) return 'One project: its description, per-bridge paths, and the chains, agents and memory attached to it.';
  if (path.startsWith('/memory/')) return 'Full memory record with body, scope, and its status actions.';
  if (path.startsWith('/memory')) return 'Durable facts, habits and skills targeted to agents, projects, bridges, and templates. Empty scope applies to all.';
  if (path.startsWith('/shells/')) return "One shell session: its live output, its details, and the preview when it declares a port.";
  if (path.startsWith('/shells')) return 'Every shell session your bridges are running.';
  if (path.startsWith('/settings/vault')) return 'Zero-Knowledge User Vault management, recovery words, and unlock keys.';
  if (path.startsWith('/settings')) return 'Settings surface for Bridges, Providers, Appearance, User tokens, Projects, and Defaults.';
  return 'Chat-first home with the routed main region ready for conversation surfaces.';
}

// Live shells fetched for the status bar's counts; a full page renders as "N+".
const STATUS_BAR_SHELL_LIMIT = 200;

const SETTINGS_NAV = [
  { path: '/settings/bridges', label: 'Bridges' },
  { path: '/settings/providers', label: 'Providers' },
  { path: '/settings/appearance', label: 'Appearance' },
  { path: '/settings/user-tokens', label: 'User tokens' },
  { path: '/settings/vault', label: 'User Vault' },
  { path: '/settings/projects', label: 'Projects' },
  { path: '/settings/templates', label: 'Templates' },
  { path: '/settings/notifications', label: 'Notifications' },
  { path: '/settings/defaults', label: 'Defaults' },
  { path: '/settings/experimental', label: 'Experimental' },
];

export { resolveSettingsTab };

function decodeSegment(value: string): string {
  try { return decodeURIComponent(value); } catch (_err) { return value; }
}

function routeBreadcrumbs(path: string, conversations: ConversationSummary[] = []): BreadcrumbCrumb[] {
  if (path === '/home' || path.startsWith('/home') || path === '/cards' || path.startsWith('/cards')) return [{ label: 'Home' }];
  if (path === '/conversations/new') return [{ label: 'Conversations', href: '/conversations' }, { label: 'New Conversation' }];
  if (path.startsWith('/conversations/')) {
    const agentInstanceId = decodeSegment(path.slice('/conversations/'.length));
    const convo = conversations.find((item) => item.agentInstanceId === agentInstanceId);
    return [{ label: 'Conversations', href: '/conversations' }, { label: convo?.agentId || 'Conversation' }, { label: convo?.agentInstanceId || agentInstanceId }];
  }
  if (path === '/agents/new') return [{ label: 'Agents', href: '/agents' }, { label: 'New Agent' }];
  if (path.startsWith('/agents/')) return [{ label: 'Agents', href: '/agents' }, { label: decodeSegment(path.slice('/agents/'.length)) }];
  if (path === '/settings') return [{ label: 'Settings' }];
  if (path.startsWith('/settings/providers/')) {
    const rest = path.slice('/settings/providers/'.length);
    if (rest === 'new') return [{ label: 'Settings', href: '/settings/bridges' }, { label: 'Providers', href: '/settings/providers' }, { label: 'New Provider' }];
    if (rest.endsWith('/edit')) return [{ label: 'Settings', href: '/settings/bridges' }, { label: 'Providers', href: '/settings/providers' }, { label: decodeSegment(rest.slice(0, -'/edit'.length)) }, { label: 'Edit' }];
  }
  if (path.startsWith('/settings/')) {
    const key = path.slice('/settings/'.length).split('/')[0] || 'bridges';
    const match = SETTINGS_NAV.find((item) => item.path.endsWith(`/${key}`));
    return [{ label: 'Settings', href: '/settings/bridges' }, { label: match?.label || decodeSegment(key) }];
  }
  if (path.startsWith('/chains/')) return [{ label: 'Task Chains', href: '/chains' }, { label: parseChainRoute(path).chainId || 'Chain' }];
  if (path === '/actions/new') return [{ label: 'Actions', href: '/actions' }, { label: 'New Action' }];
  if (path.startsWith('/actions/') && path.endsWith('/edit')) return [{ label: 'Actions', href: '/actions' }, { label: 'Edit Action' }];
  if (path.startsWith('/actions')) return [{ label: 'Actions' }];
  if (path.startsWith('/library')) return [{ label: 'Library' }];
  if (path.startsWith('/issues')) return [{ label: 'Issues' }];
  if (path.startsWith('/agents')) return [{ label: 'Agents' }];
  return [{ label: 'Conversations' }];
}

// The trail itself is now `@ui`'s `Breadcrumbs` composite (REQ-UI-14 makes it every
// resource page's contract, so it belongs in the library rather than private to the
// shell). This wrapper keeps the shell's two local concerns: the `shell-breadcrumbs`
// debug id, and turning an app path into the hash route the shell navigates by.
function Breadcrumbs({ crumbs }: { crumbs: BreadcrumbCrumb[] }) {
  const linked = crumbs.map((crumb) => ({ ...crumb, href: crumb.href ? shellHash(crumb.href) : undefined }));
  return <UiBreadcrumbs data-debug-id="shell-breadcrumbs" crumbs={linked} />;
}

function SettingsSubNav({ path }: { path: string }) {
  const experimentsQuery = useFetchExperimentsQuery();
  const lspEnabled = Boolean(experimentsQuery.data?.flags?.find((f) => f.key === 'lsp')?.enabled);
  const nav = lspEnabled
    ? [...SETTINGS_NAV, { path: '/settings/lsp', label: 'Language Servers' }]
    : SETTINGS_NAV;
  return <nav data-debug-id="settings-sub-nav" className="mb-5 -mx-1 flex w-full max-w-full flex-nowrap gap-2 overflow-x-auto overscroll-x-contain rounded-2xl border border-subtle bg-surface p-2 [-webkit-overflow-scrolling:touch] sm:mx-0 sm:flex-wrap">{nav.map((item) => {
    const active = path === item.path || path.startsWith(`${item.path}/`) || (path === '/settings' && item.path === '/settings/bridges');
    const debugKey = item.label.toLowerCase().replace(/\s+/g, '-');
    return <a key={item.path} data-debug-id={`settings-sub-nav-${debugKey}`} href={shellHash(item.path)} className={`inline-flex min-h-[44px] shrink-0 items-center rounded-xl px-4 py-2 text-sm font-semibold ${active ? 'bg-accent text-accent-fg' : 'text-muted hover:bg-surface-raised hover:text-primary'}`}>{item.label}</a>;
  })}</nav>;
}

function shellHash(path: string): string {
  return buildRouteHash(path, '');
}

// Same rule as `api/cookieFetch.ts`: absolute in every normal build, rooted at the
// document when a preview build serves the app under a path prefix.
function apiUrl(path: string): string {
  return withApiBase(path.startsWith('/api/v1') ? path : `/api/v1${path.startsWith('/') ? path : `/${path}`}`);
}

function authRuntimeConfig(): Record<string, any> {
  if (typeof window === 'undefined') return {};
  return (window as any).__HEIMDALL_AUTH_CONFIG__ || (window as any).__HEIMDALL_UI_CONFIG__?.auth || {};
}

function metaContent(name: string): string {
  if (typeof document === 'undefined') return '';
  return document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content || '';
}

function usableAuthUrl(value: string): string {
  const trimmed = String(value || '').trim();
  if (!trimmed || (trimmed.startsWith('%') && trimmed.endsWith('%'))) return '';
  return trimmed;
}

function configuredAuthUrl(kind: 'login' | 'logout'): string {
  const cfg = authRuntimeConfig();
  const snake = `${kind}_url`;
  const camel = `${kind}Url`;
  const fromConfig = usableAuthUrl(String(cfg?.[snake] || cfg?.[camel] || ''));
  if (fromConfig) return fromConfig;
  return usableAuthUrl(metaContent(`heimdall-${kind}-url`));
}

async function fetchPublicAuthConfig(): Promise<{ loginUrl: string; logoutUrl: string }> {
  let loginUrl = configuredAuthUrl('login');
  let logoutUrl = configuredAuthUrl('logout');
  try {
    const response = await fetch(apiUrl('/auth/config'), { credentials: 'include' });
    if (response.ok) {
      const body = await response.json();
      const data = body?.data || body || {};
      loginUrl = usableAuthUrl(data.login_url || data.loginUrl || loginUrl) || loginUrl;
      logoutUrl = usableAuthUrl(data.logout_url || data.logoutUrl || logoutUrl) || logoutUrl;
    }
  } catch (_err) {}
  return { loginUrl, logoutUrl };
}

function loginUrlWithReturn(loginUrl: string): string {
  if (!loginUrl || typeof window === 'undefined') return loginUrl;
  if (loginUrl.includes('{return_to}')) return loginUrl.replace('{return_to}', encodeURIComponent(window.location.href));
  if (loginUrl.includes('{returnTo}')) return loginUrl.replace('{returnTo}', encodeURIComponent(window.location.href));
  return loginUrl;
}

function isApiV1Url(input: RequestInfo | URL): boolean {
  const value = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
  try {
    const url = new URL(value, window.location.href);
    return url.pathname.startsWith('/api/v1/');
  } catch (_err) {
    return String(value).startsWith('/api/v1/');
  }
}

function installApiAuthObserver() {
  if (typeof window === 'undefined' || !(window as any).fetch || (window as any).__heimdallApiAuthObserverInstalled) return;
  const originalFetch = window.fetch.bind(window);
  (window as any).__heimdallApiAuthObserverInstalled = true;
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const response = await originalFetch(input, init);
    if (isApiV1Url(input)) {
      if (response.status === 401) window.dispatchEvent(new CustomEvent('heimdall:api-unauthenticated'));
      if (response.status === 403) window.dispatchEvent(new CustomEvent('heimdall:api-forbidden'));
    }
    return response;
  };
}

async function bootstrapAuth(): Promise<AuthState> {
  const authConfig = await fetchPublicAuthConfig();
  const loginUrl = authConfig.loginUrl;
  try {
    const me = await fetch(apiUrl('/me'), { credentials: 'include' });
    if (me.status === 401) return { status: 'unauthenticated', user: null, loginUrl, logoutUrl: authConfig.logoutUrl, error: '' };
    if (me.status === 403) return { status: 'forbidden', user: null, loginUrl, logoutUrl: authConfig.logoutUrl, error: 'Access denied' };
    if (!me.ok) return { status: 'error', user: null, loginUrl, logoutUrl: authConfig.logoutUrl, error: `Auth check failed (${me.status})` };
    const meBody = await me.json();
    return { status: 'authenticated', user: meBody?.data || {}, loginUrl, logoutUrl: authConfig.logoutUrl, error: '' };
  } catch (error: any) {
    return { status: 'error', user: null, loginUrl, logoutUrl: configuredAuthUrl('logout'), error: String(error?.message || error || 'Auth check failed') };
  }
}


function normalizeProject(raw: any): ProjectSummary {
  const name = String(raw?.name || raw?.title || 'Untitled project');
  const projectId = String(raw?.project_id || raw?.projectId || raw?.id || '');
  // UI-3 requires default-project semantics to survive rename. Do not infer the
  // protected default project from the display name; use only a durable backend
  // marker (or the synthetic fallback project id when no backend project exists).
  const hasDefaultMarker = raw?.is_default_conversations === true || raw?.isDefaultConversations === true;
  const isSyntheticFallback = projectId === DEFAULT_CONVERSATIONS_PROJECT.projectId;
  const isDefault = hasDefaultMarker || isSyntheticFallback;
  const projectType = String(raw?.project_type || raw?.projectType || '').trim() || (isDefault ? undefined : 'local');
  const workspaceName = String(raw?.workspace_name || raw?.workspaceName || '').trim() || undefined;
  return { projectId: projectId || (isDefault ? DEFAULT_CONVERSATIONS_PROJECT.projectId : name), name, isDefaultConversations: isDefault, projectType, workspaceName };
}

// UI-14: adapt cookie-auth RTK Query sidebar data into the local tree types so
// server state lives in RTK Query (and is WS-invalidated) while the tree builder
// keeps its existing typed contract.
function sidebarConversationToSummary(c: SidebarConversation, agentNamesById: Map<string, string>): ConversationSummary {
  const agentId = c.agentId || 'unknown-agent';
  return {
    conversationId: c.conversationId,
    agentId,
    agentInstanceId: c.agentInstanceId,
    agentName: displayAgentName(agentId, c.agentName || agentNamesById.get(agentId)),
    projectId: c.projectId || DEFAULT_CONVERSATIONS_PROJECT.projectId,
    title: c.title,
    unreadCount: c.unreadCount,
    updatedAt: c.updatedAt,
    lastMessageAt: c.lastMessageAt,
    lastMessagePreview: c.lastMessagePreview,
    lastMessageDirection: c.lastMessageDirection,
    lastMessageUnixMs: c.lastMessageUnixMs,
    lastMessage: c.lastMessage,
    participants: c.participants,
    bridgeId: c.bridgeId,
    runtimeStatus: c.runtimeStatus,
    activityStatus: c.activityStatus,
  };
}

function looksLikeInternalId(value: string): boolean {
  return /^(agt|inst|chat|conv|usr|brg|task|chain|proj|art)_[a-z0-9]/i.test(String(value || '').trim());
}

function displayAgentName(agentId: string, name?: string): string {
  const trimmed = String(name || '').trim();
  if (trimmed && trimmed !== agentId && !looksLikeInternalId(trimmed)) return trimmed;
  return 'Unnamed agent';
}

function displayConversationTitle(conversation: ConversationSummary): string {
  const title = String(conversation.title || '').trim();
  if (!title || title === conversation.agentId || title === conversation.agentInstanceId || title === conversation.conversationId || looksLikeInternalId(title)) {
    return conversation.agentName;
  }
  return title;
}

function displayConversationMeta(conversation: ConversationSummary): string {
  if (!conversation.updatedAt) return '';
  const date = new Date(conversation.updatedAt);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

// buildProjectConversationTree renders the rail strictly in /api/v1/agents/live
// order (NO client-side re-sort): EVERY project the endpoint returns, in its
// FIXED order (alphabetical by name, then the '' Unassigned bucket), even when it
// has no live conversation. Within a project, conversation rows are CHAIN-GROUPED
// in the endpoint's chain order, and agents within a chain follow the endpoint's
// (creation-time) order. Each row carries isCoordinator (own-name gold) and
// startsNewGroup (the first row of a chain-group, except the very first group in
// the project — the renderer draws a subtle separator before it). Live
// conversations not represented in the endpoint (e.g. an agent in no chain) are
// appended as a trailing group in their own project bucket. The endpoint's ''
// bucket and the UI's implicit "no project" share the default-conversations bucket.
function buildProjectConversationTree(conversations: ConversationSummary[], liveProjects: LiveProject[]): ProjectGroup[] {
  const defaultProjectId = DEFAULT_CONVERSATIONS_PROJECT.projectId;
  const bucketId = (raw?: string) => {
    const id = String(raw || '').trim();
    return id === '' || id === defaultProjectId ? defaultProjectId : id;
  };

  const order: string[] = [];
  const descById = new Map<string, ProjectSummary>();
  const rowsByBucket = new Map<string, ConversationSummary[]>();
  const ensureBucket = (rawId: string, name: string, projectType?: string, workspaceName?: string) => {
    const id = bucketId(rawId);
    if (!descById.has(id)) {
      const isDefault = id === defaultProjectId;
      descById.set(id, {
        projectId: id,
        name: isDefault ? DEFAULT_CONVERSATIONS_PROJECT.name : name,
        isDefaultConversations: isDefault,
        projectType,
        workspaceName,
      });
      order.push(id);
      rowsByBucket.set(id, []);
    }
    return id;
  };

  // Only live conversations appear in the rail; index them by instance so the
  // endpoint's ordered agent list can pull each row's live state/unread.
  const byInstance = new Map<string, ConversationSummary>();
  conversations.forEach((c) => { if (isLiveConversation(c)) byInstance.set(c.agentInstanceId, c); });
  const placed = new Set<string>();

  // API order: project -> chain-group -> agent. Mark the first row of each group
  // (after the first) so the renderer inserts a separator between groups.
  liveProjects.forEach((project) => {
    const id = ensureBucket(project.projectId, project.name, (project as any).projectType, (project as any).workspaceName);
    const rows = rowsByBucket.get(id)!;
    project.chains.forEach((chain) => {
      let firstInGroup = true;
      chain.liveAgents.forEach((agent) => {
        const conv = byInstance.get(agent.agentInstanceId);
        if (!conv || placed.has(agent.agentInstanceId)) return;
        placed.add(agent.agentInstanceId);
        rows.push({ ...conv, isCoordinator: agent.isCoordinator, startsNewGroup: firstInGroup && rows.length > 0 });
        firstInGroup = false;
      });
    });
  });

  // Trailing group per project for live conversations the endpoint didn't list.
  const recency = (c: ConversationSummary) => Number(c.lastMessageUnixMs || Date.parse(c.lastMessageAt || c.updatedAt || '') || 0);
  const leftoverByBucket = new Map<string, ConversationSummary[]>();
  conversations.forEach((c) => {
    if (!isLiveConversation(c) || placed.has(c.agentInstanceId)) return;
    const id = ensureBucket(c.projectId, c.projectId);
    if (!leftoverByBucket.has(id)) leftoverByBucket.set(id, []);
    leftoverByBucket.get(id)!.push(c);
  });
  leftoverByBucket.forEach((list, id) => {
    const rows = rowsByBucket.get(id)!;
    list.sort((a, b) => recency(b) - recency(a)).forEach((c, i) => {
      rows.push({ ...c, isCoordinator: false, startsNewGroup: i === 0 && rows.length > 0 });
    });
  });

  // Every project renders (all-projects rule), in the endpoint's fixed order.
  return order.map((projectId) => {
    const rows = rowsByBucket.get(projectId) || [];
    return { project: descById.get(projectId) || { projectId, name: projectId }, conversations: rows, unreadCount: rows.reduce((sum, c) => sum + c.unreadCount, 0) };
  });
}

function UnreadBadge({ count, debugId }: { count: number; debugId: string }) {
  if (count <= 0) return null;
  return (
    <Badge
      data-debug-id={debugId}
      tone="info"
      emphasis="solid"
      className="ml-auto min-w-5 justify-center font-bold"
    >
      {count > 99 ? '99+' : count}
    </Badge>
  );
}

const BRIDGE_PALETTE = ['accent', 'success', 'warning', 'info', 'danger'] as const;

function bridgeColorSlot(bridgeId?: string): string {
  if (!bridgeId) return 'neutral';
  let h = 0;
  for (let i = 0; i < bridgeId.length; i++) {
    h = (h * 31 + bridgeId.charCodeAt(i)) >>> 0;
  }
  return BRIDGE_PALETTE[h % BRIDGE_PALETTE.length];
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function bridgeIsRevoked(bridge: any): boolean {
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const status = String(bridge?.status || bridge?.runtime_status || bridge?.runtimeStatus || bridge?.state || '').trim().toLowerCase();
  return status === 'revoked' || Boolean(bridge?.revoked_at || bridge?.revokedAt);
}

type LiveState = 'live' | 'starting' | 'stopping' | 'off' | 'stale' | 'error' | 'none';

function liveStateFromRuntime(runtimeStatus?: string): LiveState {
  switch (String(runtimeStatus || '').toLowerCase()) {
    case 'running': case 'idle': case 'busy': return 'live';
    case 'launching': case 'starting': return 'starting';
    case 'stopping': return 'stopping';
    case 'stopped': return 'off';
    case 'unreachable': return 'stale';
    case 'failed': return 'error';
    default: return 'none';
  }
}

// The rail only lists currently-running conversations. "Live" = the runtime is
// connected or actively coming up/going down (live/starting/stopping).
function isLiveConversation(conversation: ConversationSummary): boolean {
  const state = liveStateFromRuntime(conversation.runtimeStatus);
  return state === 'live' || state === 'starting' || state === 'stopping';
}

const DOT_COLOR_CLASSES: Record<string, { solid: string; half: string }> = {
  accent: { solid: 'bg-accent', half: 'bg-accent/60 border border-accent' },
  success: { solid: 'bg-success', half: 'bg-success/60 border border-success' },
  warning: { solid: 'bg-warning', half: 'bg-warning/60 border border-warning' },
  info: { solid: 'bg-info', half: 'bg-info/60 border border-info' },
  danger: { solid: 'bg-danger', half: 'bg-danger/60 border border-danger' },
  neutral: { solid: 'bg-muted', half: 'bg-muted/60' },
};

/**
 * BridgeLiveDot — the sidebar rail's per-conversation liveness dot.
 * ------------------------------------------------------------------
 * DELIBERATE EXCEPTION to the @ui `StatusDot` primitive (EL-050): its color
 * encodes WHICH bridge a running session is on (bridgeColorSlot's identity
 * palette), not a health tone, and it carries a running/working animation
 * (bounce) the primitive intentionally doesn't. Health-tone dots elsewhere use
 * `@ui` StatusDot + `runtimeStatusToTone`; this one stays bespoke because the
 * bridge-identity coloring is load-bearing in the rail. Renamed off "StatusDot"
 * to remove the name collision with the primitive.
 */
function BridgeLiveDot({
  bridgeId,
  runtimeStatus,
  activityStatus,
  debugId,
  label,
}: {
  bridgeId?: string;
  runtimeStatus?: string;
  activityStatus?: string;
  debugId?: string;
  label?: string;
}) {
  const state = liveStateFromRuntime(runtimeStatus);
  const isLive = state === 'live';
  const isStarting = state === 'starting' || state === 'stopping';
  const isRunning = isLive || isStarting;
  const working = isAgentWorking(state, activityStatus);
  const colorKey = isRunning ? bridgeColorSlot(bridgeId) : 'neutral';
  const colorStyle = DOT_COLOR_CLASSES[colorKey] || DOT_COLOR_CLASSES.neutral;

  let tooltip = label ? `${label} · ` : '';
  tooltip += isRunning ? `running on ${bridgeId || 'unknown bridge'}` : 'not running';
  if (runtimeStatus) tooltip += ` (${runtimeStatus}${working ? ', working' : ''})`;

  let dot;
  if (isLive) {
    if (working) {
      dot = (
        <span className="flex items-center gap-[2px]">
          <span className={`h-1.5 w-1.5 animate-bounce rounded-full ${colorStyle.solid}`} style={{ animationDelay: '0ms' }} />
          <span className={`h-1.5 w-1.5 animate-bounce rounded-full ${colorStyle.solid}`} style={{ animationDelay: '150ms' }} />
          <span className={`h-1.5 w-1.5 animate-bounce rounded-full ${colorStyle.solid}`} style={{ animationDelay: '300ms' }} />
        </span>
      );
    } else {
      dot = <span className={`h-2 w-2 rounded-full ${colorStyle.solid}`} />;
    }
  } else if (isStarting) {
    dot = <span className={`h-2 w-2 rounded-full ${colorStyle.half} animate-pulse`} />;
  } else {
    dot = <span className="h-2 w-2 rounded-full border border-subtle bg-transparent" />;
  }

  return (
    <span
      data-debug-id={debugId}
      data-bridge-color={colorKey}
      data-live-state={state}
      data-working={working ? 'true' : 'false'}
      title={tooltip}
      aria-label={tooltip}
      className="inline-flex items-center justify-center shrink-0"
    >
      {dot}
    </span>
  );
}

function ProjectGroupItem({
  projectGroup,
  currentPath = '',
  onLaunchProject,
}: {
  projectGroup: ProjectGroup;
  currentPath?: string;
  onLaunchProject?: (project: { projectId: string; name: string }) => void;
}) {
  const isMobile = useIsMobile();
  const projectId = projectGroup.project.projectId;
  const storageKey = `heimdall:project-collapsed:${projectId}`;
  const [collapsed, setCollapsed] = useState<boolean>(() => {
    try {
      return localStorage.getItem(storageKey) === 'true';
    } catch (_err) {
      return false;
    }
  });

  const toggleCollapsed = () => {
    setCollapsed((prev) => {
      const next = !prev;
      try {
        localStorage.setItem(storageKey, String(next));
      } catch (_err) {}
      return next;
    });
  };

  return (
    <div data-debug-id={`sidebar-project-group-${projectId}`} className="px-0.5">
      <div className={`flex items-center justify-between gap-2 rounded-lg px-2 hover:bg-neutral-soft ${isMobile ? 'min-h-11' : 'py-1.5'}`}>
        <button
          type="button"
          data-debug-id={`sidebar-project-toggle-btn-${projectId}`}
          onClick={toggleCollapsed}
          aria-expanded={!collapsed}
          aria-controls={`sidebar-project-body-${projectId}`}
          className={`flex min-w-0 flex-1 items-center gap-1.5 self-stretch text-left font-semibold text-primary hover:text-primary ${isMobile ? 'text-[15px]' : 'text-[13px]'}`}
        >
          <span
            data-debug-id={`sidebar-project-chevron-${projectId}`}
            className={`inline-flex w-4 items-center justify-center ${
              projectGroup.project.projectType === 'fig' ? 'text-warning' : 'text-accent'
            }`}
          >
            <Icon name={collapsed ? 'folder' : 'folder-open'} size={15} />
          </span>
          <span className="truncate">
            <VaultText value={projectGroup.project.name} fallback="Project" />
          </span>
          {projectGroup.project.projectType === 'fig' && projectGroup.project.workspaceName ? (
            <Badge
              data-debug-id={`sidebar-project-workspace-${projectId}`}
              tone="warning"
              emphasis="soft"
              className="shrink-0 font-mono text-[10px] truncate"
              title={`CitC Workspace: ${projectGroup.project.workspaceName}`}
            >
              {projectGroup.project.workspaceName}
            </Badge>
          ) : null}
        </button>
        <button
          type="button"
          data-debug-id={`sidebar-project-launch-btn-${projectId}`}
          onClick={(e) => {
            e.stopPropagation();
            onLaunchProject?.(projectGroup.project);
          }}
          title={
            projectGroup.project.name && isVaultArmored(projectGroup.project.name)
              ? 'Launch agent for project'
              : `Launch agent for ${projectGroup.project.name || 'project'}`
          }
          aria-label={
            projectGroup.project.name && isVaultArmored(projectGroup.project.name)
              ? 'Launch agent for project'
              : `Launch agent for ${projectGroup.project.name || 'project'}`
          }
          className={`flex items-center justify-center text-muted hover:bg-neutral-soft hover:text-primary transition-colors ${isMobile ? 'h-11 w-11 rounded-full' : 'h-5 w-5 rounded-md'}`}
        >
          <Icon name="plus" size={isMobile ? 18 : 13} />
        </button>
      </div>
      {!collapsed && (
        <div id={`sidebar-project-body-${projectId}`} data-debug-id={`sidebar-project-body-${projectId}`}>
          {projectGroup.conversations.length === 0 ? (
            <div data-debug-id={`sidebar-project-empty-${projectId}`} className="px-2 py-1.5 pl-8 text-[11.5px] text-faint">No conversations yet.</div>
          ) : (
            <div className="space-y-0.5">
              {projectGroup.conversations.map((conversation) => {
                const isSelected = Boolean(
                  currentPath &&
                  (currentPath === `/conversations/${conversation.agentInstanceId}` ||
                   currentPath.startsWith(`/conversations/${conversation.agentInstanceId}/`))
                );
                return (
                  <Fragment key={conversation.conversationId}>
                  {conversation.startsNewGroup ? <div data-debug-id={`sidebar-session-group-separator-${conversation.conversationId}`} role="separator" className="mx-6 my-1 border-t border-subtle" /> : null}
                  <a
                    data-debug-id={`sidebar-session-row-${conversation.conversationId}`}
                    href={shellHash(`/conversations/${encodeURIComponent(conversation.agentInstanceId)}`)}
                    className={`flex items-center gap-2 rounded-lg pl-6 pr-2 transition ${isMobile ? 'min-h-11 text-[15px]' : 'py-1.5 text-[12.5px]'} ${isSelected ? 'bg-neutral-soft text-primary font-semibold' : 'text-muted hover:bg-neutral-soft hover:text-primary'}`}
                  >
                    <BridgeLiveDot
                      bridgeId={conversation.bridgeId}
                      runtimeStatus={conversation.runtimeStatus}
                      activityStatus={conversation.activityStatus}
                      debugId={`sidebar-session-status-dot-${conversation.conversationId}`}
                      label={conversation.agentName}
                    />
                    <span data-debug-id={conversation.isCoordinator ? `sidebar-session-coordinator-name-${conversation.conversationId}` : undefined} className={`min-w-0 flex-1 truncate ${conversation.isCoordinator ? 'text-warning' : ''}`} title={conversation.isCoordinator ? 'Coordinator' : undefined}>{conversation.agentName}</span>
                    {displayConversationMeta(conversation) ? <span className={`shrink-0 text-faint ${isMobile ? 'text-[12px]' : 'text-[10px]'}`}>{displayConversationMeta(conversation)}</span> : null}
                    <UnreadBadge count={conversation.unreadCount} debugId={`sidebar-session-unread-${conversation.conversationId}`} />
                  </a>
                  </Fragment>
                );
              })}
            </div>
          )}
        </div>
      )}
    </div>
  );
}


function NavItem({ item, active, collapsed, badge = 0, onClick }: { item: ShellRoute; active: boolean; collapsed: boolean; badge?: number; onClick?: (e: React.MouseEvent<HTMLAnchorElement>) => void }) {
  const activeClass = active
    ? 'bg-neutral-soft text-primary font-semibold'
    : 'text-muted hover:bg-neutral-soft hover:text-primary';
  return (
    <a
      data-debug-id={`shell-nav-${item.label.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`}
      href={shellHash(item.path)}
      onClick={onClick}
      aria-label={collapsed ? item.label : undefined}
      title={collapsed ? item.label : item.description}
      className={`group flex min-h-11 items-center gap-3 rounded-xl px-2.5 py-2 text-[13px] font-medium transition ${activeClass} ${collapsed ? 'justify-center' : ''}`}
    >
      <span aria-hidden="true" className={`grid h-5 w-5 shrink-0 place-items-center ${active ? 'text-accent' : ''}`}><Icon name={item.icon} size={17} /></span>
      {!collapsed && <span className="min-w-0 flex-1 truncate">{item.label}</span>}
      {!collapsed && <UnreadBadge count={badge} debugId={`shell-nav-unread-${item.label.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`} />}
    </a>
  );
}

function authUserId(user: AuthUser | null | undefined): string {
  return String(user?.user_id || '').trim();
}

function clearPriorUserClientState(dispatch: any, nextUserId: string) {
  dispatch(heimdallApi.util.resetApiState());
  removeAppOwnedClientStorage();
  dispatch(priorUserClientStateCleared());
  dispatch(clearUserClientState({ userId: nextUserId }));
}

function AuthGate() {
  const dispatch = useDispatch<any>();
  const [auth, setAuth] = useState<AuthState>({ status: 'checking', user: null, loginUrl: configuredAuthUrl('login'), logoutUrl: configuredAuthUrl('logout'), error: '' });
  const lastSeenUserRef = useRef(readLastSeenUserId());

  useEffect(() => {
    let cancelled = false;
    let refreshing = false;
    installApiAuthObserver();

    async function refreshIdentity(reason: string) {
      if (refreshing) return;
      refreshing = true;
      try {
        const next = await bootstrapAuth();
        if (cancelled) return;
        if (next.status === 'authenticated') {
          const nextUserId = authUserId(next.user);
          const previousUserId = lastSeenUserRef.current || readLastSeenUserId();
          if (nextUserId && previousUserId && previousUserId !== nextUserId) {
            clearPriorUserClientState(dispatch, nextUserId);
          }
          if (nextUserId) {
            writeLastSeenUserId(nextUserId);
            lastSeenUserRef.current = nextUserId;
          }
          // P1 vault adapter: the keyring belongs to the authenticated user.
          setActiveVaultUserId(nextUserId);
        }
        setAuth(next);
      } catch (err: any) {
        if (!cancelled) setAuth({ status: 'error', user: null, loginUrl: configuredAuthUrl('login'), logoutUrl: configuredAuthUrl('logout'), error: String(err?.message || err || 'The app could not reach /api/v1/me.') });
      } finally {
        refreshing = false;
        void reason;
      }
    }

    const onUnauthenticated = () => setAuth((prev) => ({ ...prev, status: 'unauthenticated', user: null, loginUrl: prev.loginUrl || configuredAuthUrl('login') }));
    const onForbidden = () => setAuth((prev) => ({ ...prev, status: 'forbidden', error: 'Access denied' }));
    const onFocus = () => { void refreshIdentity('focus'); };
    const onVisibility = () => { if (document.visibilityState === 'visible') void refreshIdentity('visibilitychange'); };
    const onUserWsReconnect = () => { void refreshIdentity('user-ws-reconnect'); };

    void refreshIdentity('initial');
    window.addEventListener('heimdall:api-unauthenticated', onUnauthenticated);
    window.addEventListener('heimdall:api-forbidden', onForbidden);
    window.addEventListener('focus', onFocus);
    document.addEventListener('visibilitychange', onVisibility);
    window.addEventListener('heimdall:user-ws-reconnected', onUserWsReconnect);
    return () => {
      cancelled = true;
      refreshing = false;
      window.removeEventListener('heimdall:api-unauthenticated', onUnauthenticated);
      window.removeEventListener('heimdall:api-forbidden', onForbidden);
      window.removeEventListener('focus', onFocus);
      document.removeEventListener('visibilitychange', onVisibility);
      window.removeEventListener('heimdall:user-ws-reconnected', onUserWsReconnect);
    };
  }, [dispatch]);

  if (auth.status === 'checking') return <AuthStatusScreen debugId="auth-checking" title="Checking session…" body="Verifying trusted-proxy identity with /api/v1/me." />;
  if (auth.status === 'unauthenticated') return <UnauthenticatedLanding loginUrl={auth.loginUrl} />;
  if (auth.status === 'forbidden') return <AccessDenied />;
  if (auth.status === 'error') return <AuthStatusScreen debugId="auth-error" title="Unable to verify session" body={auth.error || 'The app could not reach /api/v1/me.'} />;
  return (
    <AuthUserProvider value={auth.user}>
      <AuthenticatedShell key={authUserId(auth.user) || 'authenticated'} user={auth.user || {}} logoutUrl={auth.logoutUrl} />
    </AuthUserProvider>
  );
}

function AuthStatusScreen({ debugId, title, body }: { debugId: string; title: string; body: string }) {
  return (
    <main data-debug-id={debugId} className="grid app-viewport-min-height place-items-center bg-canvas px-6 text-primary">
      <section className="w-full max-w-md rounded-[2rem] border border-subtle bg-surface p-8 text-center shadow-2xl">
        <div className="mx-auto mb-4 grid h-12 w-12 place-items-center rounded-2xl bg-neutral-soft text-muted"><Icon name="search" size={22} /></div>
        <h1 className="text-2xl font-semibold">{title}</h1>
        <p className="mt-3 text-sm leading-6 text-muted">{body}</p>
      </section>
    </main>
  );
}

function UnauthenticatedLanding({ loginUrl }: { loginUrl: string }) {
  const target = loginUrlWithReturn(loginUrl);
  useEffect(() => {
    if (!target) return;
    const timer = window.setTimeout(() => window.location.assign(target), 350);
    return () => window.clearTimeout(timer);
  }, [target]);
  return (
    <main data-debug-id="unauthenticated-landing" className="grid app-viewport-min-height place-items-center bg-canvas px-6 text-primary">
      <section className="w-full max-w-lg rounded-[2rem] border border-subtle bg-surface p-8 text-center shadow-2xl">
        <p className="text-xs font-semibold uppercase tracking-[0.22em] text-accent">Trusted-proxy sign in</p>
        <h1 className="mt-3 text-3xl font-semibold tracking-tight">Redirecting to sign in…</h1>
        <p className="mt-3 text-sm leading-6 text-muted">Your session is unauthenticated. Heimdall uses the configured external identity provider; no local credentials are collected.</p>
        {target ? (
          <a data-debug-id="auth-login-link" href={target} className="mt-6 inline-flex rounded-2xl bg-accent px-5 py-3 text-sm font-bold text-accent-fg hover:opacity-90">Sign in</a>
        ) : (
          <div data-debug-id="auth-login-missing-config" className="mt-6 rounded-2xl border border-warning/30 bg-warning-soft px-4 py-3 text-sm text-warning">Login URL is missing from UI auth config.</div>
        )}
      </section>
    </main>
  );
}

function AccessDenied() {
  return (
    <main data-debug-id="access-denied" className="grid app-viewport-min-height place-items-center bg-canvas px-6 text-primary">
      <section className="w-full max-w-md rounded-[2rem] border border-danger/30 bg-danger-soft p-8 text-center shadow-2xl">
        <p className="text-xs font-semibold uppercase tracking-[0.22em] text-danger">403 forbidden</p>
        <h1 className="mt-3 text-3xl font-semibold tracking-tight">Access denied</h1>
        <p className="mt-3 text-sm leading-6 text-muted">You are authenticated, but this resource is not available to your account. Heimdall will not redirect to login for 403 responses.</p>
        <a data-debug-id="access-denied-home-link" href={shellHash('/home')} className="mt-6 inline-flex rounded-2xl border border-subtle bg-surface px-5 py-3 text-sm font-bold text-primary hover:bg-surface-raised">Back to home</a>
      </section>
    </main>
  );
}



function DefaultsSettingsPanel() {
  const agentsQuery = useListAgentIdentitiesQuery();
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const agents = agentsQuery.data?.agents || [];
  return (
    <PageShell
      title="Defaults"
      description="Default-agent choices are managed from available durable identities."
    >
      <div data-debug-id="settings-defaults-panel" className="space-y-4 text-left">
      {agentsQuery.isLoading ? (
        <div className="text-sm text-muted">Loading agents…</div>
      ) : (
        <div className="space-y-2">
          {/* TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema */}
          {agents.map((agent: any) => {
            // TODO(FIX): Replace loose fallback chain with canonical typed schema property
            const agentKey = agent.agent_id || agent.agentId;
            return (
              <div key={agentKey} data-debug-id={`settings-default-agent-row-${agentKey}`} className="rounded-xl border border-subtle bg-surface p-3">
                {/* TODO(FIX): Replace loose fallback chain with canonical typed schema property */}
                <div className="break-words font-semibold text-primary">{agent.name || agent.agent_id}</div>
                {/* TODO(FIX): Replace loose fallback chain with canonical typed schema property */}
                <div className="mt-1 break-all text-xs text-muted">{agent.agent_id || agent.agentId} · template {agent.template_id || '—'}</div>
              </div>
            );
          })}
        </div>
      )}
      </div>
    </PageShell>
  );
}

function RouteOutlet({
  path,
  routeSearch,
  focusMessageId,
  conversations = [],
  liveProjects = [],
  workspaceLeading,
  workspaceLeadingWidth,
  workspaceTrailing,
}: {
  path: string;
  routeSearch?: string;
  focusMessageId?: string;
  conversations?: ConversationSummary[];
  liveProjects?: LiveProject[];
  /** Hidden sidebar: spacer reserving the fixed top-left cluster in the top-left chat header. */
  workspaceLeading?: React.ReactNode;
  workspaceLeadingWidth?: number;
  /** Update-available badge, inline beside the top-right ⋮ (both sidebar states). */
  workspaceTrailing?: React.ReactNode;
}) {
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
  const description = routeDescription(path);
  const crumbs = routeBreadcrumbs(path, conversations);
  const isConversationThreadRoute = isAgentConversationRoute(path);
  const agentInstanceId = isConversationThreadRoute
    ? decodeSegment(path.startsWith('/c/') ? path.slice('/c/'.length) : path.slice('/conversations/'.length))
    : '';

  // REQ-LSP-CFG-2: the LSP route is gated on the 'lsp' experiment flag HERE, not only in
  // SettingsSubNav — hiding the nav entry does nothing for a direct visit or a bookmark.
  // Nav and route read the same flag so they can never disagree.
  const experimentsQuery = useFetchExperimentsQuery();
  const lspEnabled = Boolean(experimentsQuery.data?.flags?.find((f) => f.key === 'lsp')?.enabled);
  const isLspRoute = path === '/settings/lsp' || path.startsWith('/settings/lsp/');
  // Until the flags have actually arrived we know nothing, so we must not answer either
  // way: rendering the panel would leak it to a flag-off user, and rendering not-found
  // would flash a wrong answer at a flag-on user deep-linking in. Hold instead.
  const lspFlagPending = isLspRoute && experimentsQuery.data === undefined && !experimentsQuery.isError;
  const isMappedRoute = useMemo(() => {
    return [
      '/home', '/cards', '/conversations', '/conversations/new', '/actions', '/projects', '/chains', '/chains/new', '/agents', '/agents/new', '/library', '/memory', '/shells', '/settings', '/issues',
    ].some((known) => path === known || path.startsWith(`${known}/`)) ||
      path.startsWith('/c/') ||
      path.startsWith('/settings/bridges') ||
      path.startsWith('/settings/appearance') ||
      path.startsWith('/settings/user-tokens') ||
      path.startsWith('/projects/') ||
      path.startsWith('/settings/projects') ||
      path.startsWith('/settings/providers') ||
      path.startsWith('/settings/templates') ||
      path.startsWith('/settings/notifications') ||
      path.startsWith('/settings/defaults') ||
      path === '/agents/new';
  }, [path]);
  // A flag-off /settings/lsp is not a known route at all: the '/settings' entry above
  // matches every /settings/* path, so without this it would render as a known-route
  // placeholder (breadcrumbs and a description for a page the user cannot have) rather
  // than as the plain not-found it is. No redirect — a bounce would imply the route
  // moved, when the truth is that it is not enabled here.
  const isKnownRoute = isMappedRoute && !(isLspRoute && !lspEnabled);

  if (isConversationThreadRoute) {
    return (
      <main data-debug-id="shell-main-route-outlet" className="min-w-0 min-h-0 flex-1 overflow-hidden bg-canvas">
        <ErrorBoundary resetKey="workspace" label="Conversation">
          {/* Workspace: Main split tree of agent chats + ONE aux dock. The URL
              (`/conversations/<id1>+<id2>?focused=<id>`) carries the pane set. */}
          <Workspace
            leading={workspaceLeading}
            leadingWidth={workspaceLeadingWidth}
            trailing={workspaceTrailing}
            focusMessageId={focusMessageId}
            isMobile={isMobile}
          />
        </ErrorBoundary>
      </main>
    );
  }

  const isDesktopTwoPaneRoute =
    viewport === 'desktop' &&
    ['/projects', '/actions', '/agents', '/shells', '/memory', '/issues'].some(
      (prefix) => path === prefix || path.startsWith(`${prefix}/`)
    ) &&
    !path.endsWith('/new') &&
    !path.endsWith('/edit');

  return (
    <main
      data-debug-id="shell-main-route-outlet"
      className={
        isDesktopTwoPaneRoute
          ? 'h-full min-h-0 min-w-0 flex-1 flex flex-col overflow-hidden bg-canvas'
          : 'min-w-0 min-h-0 flex-1 overflow-auto overflow-x-hidden bg-canvas'
      }
    >
      <section
        className={
          isDesktopTwoPaneRoute
            ? 'mx-auto flex h-full min-h-0 w-full max-w-6xl min-w-0 flex-1 flex-col overflow-hidden px-0 py-2 sm:px-4 sm:py-4 lg:px-5 lg:py-5 [&>*]:max-w-full [&>*]:h-full [&>*]:min-h-0 [&>*]:flex-1'
            : 'mx-auto flex min-h-full w-full max-w-6xl min-w-0 flex-col items-start overflow-x-hidden px-0 py-2 sm:px-4 sm:py-4 lg:px-5 lg:py-5 [&>*]:max-w-full'
        }
      >
        {/* Do not render SettingsSubNav when SettingsModal is active */}
        {!path.startsWith('/settings') && path.startsWith('/settings') ? <SettingsSubNav path={path} /> : null}
        <ErrorBoundary resetKey={path} label={routeTitle(path)}>
        {lspFlagPending ? (
          <p data-debug-id="settings-lsp-gate-pending" className="text-sm text-muted">Loading…</p>
        ) : path.startsWith('/settings') ? (
          <HomePage />
        ) : path === '/home' || path.startsWith('/home') || path === '/cards' || path.startsWith('/cards') ? (
          <HomePage />
        ) : path === '/conversations' ? (
          <ConversationsHomePage />
        ) : path === '/actions' ? (
          <ActionListPage />
        ) : path === '/actions/new' ? (
          <ActionFormPage />
        ) : path.startsWith('/actions/') && path.endsWith('/edit') ? (
          <ActionFormPage actionId={decodeURIComponent(path.slice('/actions/'.length, -'/edit'.length))} />
        ) : path.startsWith('/actions/') ? (
          <ActionViewPage actionId={decodeURIComponent(path.slice('/actions/'.length))} />
        ) : path === '/shells' ? (
          <ShellListPage />
        ) : path.startsWith('/shells/') ? (
          <ShellViewPage sessionId={decodeURIComponent(path.slice('/shells/'.length))} />
        ) : path === '/projects' ? (
          <ProjectListPage />
        ) : path === '/projects/new' ? (
          <ProjectFormPage />
        ) : path.startsWith('/projects/') && path.endsWith('/edit') ? (
          <ProjectFormPage projectId={decodeURIComponent(path.slice('/projects/'.length, -'/edit'.length))} />
        ) : path.startsWith('/projects/') ? (
          <ProjectViewPage projectId={decodeURIComponent(path.slice('/projects/'.length))} />
        ) : path === '/device/add' ? (
          // Authenticated bridge-enrollment approval. The operator enters the
          // short code and confirms the terminal fingerprint before approval.
          <BridgeEnrollmentApprovalPage />
        ) : path === '/conversations/new' ? (
          <NewConversationPage key={routeSearch || 'default'} launchIntent={launcherIntentFromSearch(routeSearch || '')} />
        ) : path === '/settings' || path === '/settings/bridges' ? (
          <BridgesPanel />
        ) : path === '/settings/appearance' ? (
          <AppearanceSettings />
        ) : path === '/settings/providers' ? (
          <ProvidersPanel />
        ) : path === '/settings/user-tokens' ? (
          <UserTokensPanel />
        ) : path === '/settings/vault' || path.startsWith('/settings/vault/') ? (
          <VaultPanel />
        ) : path === '/settings/providers/new' ? (
          <ProviderEditorPage />
        ) : path.startsWith('/settings/providers/') && path.endsWith('/edit') ? (
          <ProviderEditorPage providerName={decodeSegment(path.slice('/settings/providers/'.length, -'/edit'.length))} />
        ) : path === '/settings/projects' ? (
          <ProjectsPanel />
        ) : path === '/settings/templates' ? (
          <TemplatesPanel />
        ) : path === '/settings/notifications' ? (
          <NotificationsPanel />
        ) : path === '/settings/defaults' ? (
          <DefaultsSettingsPanel />
        ) : path === '/settings/experimental' ? (
          <ExperimentalPanel />
        ) : isLspRoute && lspEnabled ? (
          <LspPanel />
        ) : path === '/chains' ? (
          <TaskChainsPage isMobile={isMobile} />
        ) : path.startsWith('/chains/') ? (
          <TaskChainsPage {...parseChainRoute(path)} isMobile={isMobile} />
        ) : path === '/agents' ? (
          <AgentListPage />
        ) : path === '/agents/new' ? (
          <AgentFormPage />
        ) : path.startsWith('/agents/') && path.endsWith('/edit') ? (
          <AgentFormPage agentId={decodeURIComponent(path.slice('/agents/'.length, -'/edit'.length))} />
        ) : path.startsWith('/agents/') ? (
          <AgentViewPage agentId={decodeURIComponent(path.slice('/agents/'.length))} />
        ) : path === '/memory' ? (
          <MemoryListPage />
        ) : path === '/memory/new' ? (
          <MemoryFormPage />
        ) : path.startsWith('/memory/') && path.endsWith('/edit') ? (
          <MemoryFormPage memoryId={decodeURIComponent(path.slice('/memory/'.length, -'/edit'.length))} />
        ) : path.startsWith('/memory/') ? (
          <MemoryViewPage memoryId={decodeURIComponent(path.slice('/memory/'.length))} />
        ) : path.startsWith('/skills/') ? (
          <SkillViewerPage slug={decodeURIComponent(path.slice('/skills/'.length))} />
        ) : path === '/library' ? (
          <LibraryPage session={{ clientToken: 'v1', daemonUrl: '' }} />
        ) : path.startsWith('/library/artifacts/') ? (
          <ArtifactViewer artifactId={decodeURIComponent(path.slice('/library/artifacts/'.length))} daemonUrl="" clientToken="v1" onClose={() => window.history.back()} />
        ) : path === '/issues' ? (
          <IssueListPage />
        ) : path === '/issues/new' ? (
          <IssueFormPage />
        ) : path.startsWith('/issues/') && path.endsWith('/edit') ? (
          <IssueFormPage issueId={decodeURIComponent(path.slice('/issues/'.length, -'/edit'.length))} />
        ) : path.startsWith('/issues/') ? (
          <IssueListPage selectedIssueId={decodeURIComponent(path.slice('/issues/'.length))} />
        ) : (
          <div className="w-full max-w-2xl rounded-2xl border border-subtle bg-surface p-5 text-left">
            <div data-debug-id="shell-page-placeholder-icon" className="mb-4 grid h-12 w-12 place-items-center rounded-2xl bg-neutral-soft text-muted"><Icon name="search" size={22} /></div>
            {isKnownRoute ? <Breadcrumbs crumbs={crumbs} /> : <h1 data-debug-id="shell-route-title" className="text-2xl font-semibold tracking-tight text-primary">Route not found</h1>}
            <p data-debug-id="shell-route-path" className="mt-1 text-xs text-faint">{path}</p>
            <h2 className="mt-4 text-xl font-semibold text-primary">{isKnownRoute ? (crumbs[crumbs.length - 1]?.label || 'Route') : 'This route is not part of the v1 shell map'}</h2>
            <p className="mt-3 text-sm leading-6 text-muted">{isKnownRoute ? description : 'Use the left sidebar to navigate to a v1 route. Legacy workspace, guide, attention-badge, and inspector routes are intentionally not mounted in this shell.'}</p>
          </div>
        )}
        </ErrorBoundary>
      </section>
    </main>
  );
}

function AuthenticatedShell({ user, logoutUrl }: { user: AuthUser; logoutUrl: string }) {
  // REQ-UI-SIDEBAR-PERSISTENCE: Left sidebar collapsed state persisted in localStorage ('heimdall:shell:sidebar-collapsed')
  const [collapsed, setCollapsed] = useState<boolean>(() => {
    try {
      return localStorage.getItem('heimdall:shell:sidebar-collapsed') === 'true';
    } catch (_err) {
      return false;
    }
  });

  const toggleCollapsed = () => {
    setCollapsed((prev) => {
      const next = !prev;
      try {
        localStorage.setItem('heimdall:shell:sidebar-collapsed', String(next));
      } catch (_err) {}
      return next;
    });
  };
  const [path, setPath] = useState(routeFromLocation);
  const [routeSearch, setRouteSearch] = useState(routeSearchFromLocation);
  const [focusMessageId, setFocusMessageId] = useState(focusMessageFromLocation);
  const [resourcePicker, setResourcePicker] = useState<'conversation' | 'task-chain' | 'shell' | null>(null);
  const [paletteOpen, setPaletteOpen] = useState(false);
  // Attention deck: the bar pill counts what needs the user in the chosen range.
  // The hub's attention_changed hint refetches it; nothing polls. While the deck
  // is open its own query is the only one fetching and it upserts its counts into
  // this cache, so the pill reads the cache directly (lastAttentionTotal bridges
  // the moment an invalidation drops the unsubscribed entry).
  const [attentionOpen, setAttentionOpen] = useState(false);
  const [attentionRange, setAttentionRangeState] = useState<AttentionRange>(() => readAttentionRange());
  const setAttentionRange = useCallback((range: AttentionRange) => {
    setAttentionRangeState(range);
    writeAttentionRange(range);
  }, []);
  useGetAttentionSummaryQuery({ since: attentionRange }, { skip: attentionOpen });
  const selectAttentionSummary = useMemo(() => attentionApi.endpoints.getAttentionSummary.select({ since: attentionRange }), [attentionRange]);
  const attentionSummaryData = useSelector(selectAttentionSummary).data;
  const lastAttentionTotal = useRef<{ range: AttentionRange; total: number } | null>(null);
  if (attentionSummaryData) lastAttentionTotal.current = { range: attentionRange, total: attentionSummaryData.counts.total };
  const attentionTotal = lastAttentionTotal.current?.range === attentionRange ? lastAttentionTotal.current.total : null;
  // The ring spins only for what the user has not seen: opening the deck marks
  // the current count seen (and keeps it seen while open); a later rise spins it again.
  const [attentionSeenTotal, setAttentionSeenTotal] = useState(0);
  useEffect(() => {
    // Items going away lower the mark too, so the next new one spins the ring.
    if (attentionTotal !== null && (attentionOpen || attentionTotal < attentionSeenTotal)) setAttentionSeenTotal(attentionTotal);
  }, [attentionOpen, attentionTotal]); // eslint-disable-line react-hooks/exhaustive-deps
  const attentionUnseen = attentionTotal !== null && attentionTotal > attentionSeenTotal;
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [launchModalProject, setLaunchModalProject] = useState<{ projectId: string; name: string } | null>(null);
  const [settingsModalOpen, setSettingsModalOpenState] = useState<boolean>(() => routeFromLocation().startsWith('/settings'));
  const [settingsModalTab, setSettingsModalTab] = useState<string>(() => resolveSettingsTab(routeFromLocation()));
  // Opens Workspace Settings and scrolls to the Bridge's Update button once the
  // modal has rendered it (the modal mounts asynchronously after opening).
  const openBridgeUpdate = (update: PendingBridgeUpdate) => {
    if (isMobile) setDrawerOpen(false);
    setSettingsModalTab('bridges');
    setSettingsModalOpen(true);
    const target = `[data-debug-id="settings-bridge-update-btn-${CSS.escape(update.bridgeId)}"]`;
    const deadline = Date.now() + 3000;
    const seek = () => {
      const el = document.querySelector<HTMLElement>(target);
      if (el) { el.scrollIntoView({ behavior: 'smooth', block: 'center' }); el.focus({ preventScroll: true }); return; }
      if (Date.now() < deadline) window.requestAnimationFrame(seek);
    };
    window.requestAnimationFrame(seek);
  };

  const setSettingsModalOpen = useCallback((open: boolean) => {
    setSettingsModalOpenState(open);
    if (!open) {
      const currentPath = routeFromLocation();
      if (currentPath.startsWith('/settings')) {
        if (window.history.length > 1) {
          window.history.back();
          setTimeout(() => {
            if (routeFromLocation().startsWith('/settings')) {
              window.location.hash = buildRouteHash('/home', '');
            }
          }, 150);
        } else {
          window.location.hash = buildRouteHash('/home', '');
        }
      }
    }
  }, []);
  const displayName = user.display_name || user.name || user.user_id || 'Current user';

  const dispatch = useDispatch();
  const { actions: shortcutActions, runAction, mode: shortcutMode } = useShortcuts();
  const isCurrentAuxPaneOpen = useSelector((state: any) => {
    // The dock state is global; it only shows where there is an agent tree.
    return Boolean(selectCurrentAuxTreeId(state) && selectAuxOpen(state));
  });

  // Vault state & onboarding modal
  const isVaultUnlocked = useSelector(selectIsVaultUnlocked);
  const activeVaultKey = useMemo(() => {
    if (isVaultUnlocked) {
      return getActiveVaultKey();
    }
    return null;
  }, [isVaultUnlocked]);
  const [isOnboardingModalOpen, setIsOnboardingModalOpen] = useState(false);
  const [isVaultLocking, setIsVaultLocking] = useState(false);
  const [isVaultReconciling, setIsVaultReconciling] = useState(false);
  const [isBridgeReauthenticationOpen, setIsBridgeReauthenticationOpen] = useState(false);
  const {
    data: bridgesData,
    fulfilledTimeStamp: bridgesFulfilledTimeStamp,
    refetch: refetchBridges,
  } = useListBridgesQuery(undefined);
  const bridges = useMemo<Bridge[]>(() => bridgesData?.bridges || [], [bridgesData]);
  const onlineLockedBridgeIds = useMemo(
    () => selectOnlineLockedBridgeIds(bridges),
    [bridges],
  );
  const onlineLockedBridgeSignature = onlineLockedBridgeIds.join('\u0000');
  const hasOnlineLockedBridge = isVaultUnlocked && onlineLockedBridgeIds.length > 0;
  const bridgeReconciliationRef = useRef<Promise<BridgeVaultReconciliationResult> | null>(null);
  const lastAutomaticReconciliationRef = useRef<number | undefined>(undefined);

  const reconcileOnlineLockedBridges = useCallback((providedKey?: string) => {
    if (bridgeReconciliationRef.current) return bridgeReconciliationRef.current;

    const targetBridgeIds = selectOnlineLockedBridgeIds(bridges);
    const key = providedKey || getActiveBridgeVaultKeyMaterial();
    if (targetBridgeIds.length > 0 && !key) {
      setIsBridgeReauthenticationOpen(true);
      return Promise.resolve({
        targetBridgeIds,
        attemptedBridgeIds: [],
        succeededBridgeIds: [],
        failedBridgeIds: [],
        needsReauthentication: true,
      });
    }

    setIsVaultReconciling(true);
    const run = reconcileLockedBridges(bridges, key)
      .then(async (result) => {
        if (result.attemptedBridgeIds.length > 0) {
          await refetchBridges();
        }
        return result;
      })
      .finally(() => {
        bridgeReconciliationRef.current = null;
        setIsVaultReconciling(false);
      });
    bridgeReconciliationRef.current = run;
    return run;
  }, [bridges, refetchBridges]);

  // Auto-pop onboarding modal on first visit if vault is unconfigured or locked and not
  // dismissed. Suppressed entirely when SubtleCrypto is unavailable (REQ-VAULT-UNSUP-2).
  useEffect(() => {
    const dismissed = readOnboardingDismissed();
    if (shouldOpenVaultOnboarding({ isVaultUnlocked, dismissed })) {
      setIsOnboardingModalOpen(true);
    }
  }, [isVaultUnlocked]);

  // Reconcile every and only online bridges that explicitly report Locked. A raw key
  // derived in this browser session can run silently; a cold-restored non-extractable
  // key opens the existing secure credential ceremony instead.
  useEffect(() => {
    if (!isVaultUnlocked || !onlineLockedBridgeSignature || !bridgesFulfilledTimeStamp) return;
    if (lastAutomaticReconciliationRef.current === bridgesFulfilledTimeStamp) return;
    lastAutomaticReconciliationRef.current = bridgesFulfilledTimeStamp;
    void reconcileOnlineLockedBridges();
  }, [
    isVaultUnlocked,
    onlineLockedBridgeSignature,
    bridgesFulfilledTimeStamp,
    reconcileOnlineLockedBridges,
  ]);

  // Invalidate decrypted content when vault unlocks (REQ-VAULT-TAGS-INVALIDATE).
  useEffect(() => {
    if (isVaultUnlocked) {
      dispatch(
        heimdallApi.util.invalidateTags([
          'Projects',
          'Project',
          'SidebarProjects',
          'SidebarConversations',
          'Cards',
          'ChainList',
          'Chain',
          'ChainTasks',
          'Task',
          'TaskComments',
          'ConversationSummaries',
          'Chat',
          'Issue',
        ]),
      );
    }
  }, [isVaultUnlocked, dispatch]);

  // UI-14: server state for the sidebar lives in RTK Query (cookie-auth), not
  // component-local state. The single user-WS connection invalidates the
  // SidebarConversations tag on chat/unread events so badges refresh live.
  // The rail shows live agents + unread counts; the hub doesn't push all of these
  // over the user WS, so poll periodically (paused when the tab is unfocused) so a
  // just-started/stopped agent appears/disappears without a manual refresh.
  const conversationsQuery = useListSidebarConversationsQuery({ limit: 30 }, { pollingInterval: 10000, skipPollingIfUnfocused: true });
  // Consolidated project -> live-chains -> agents tree. Drives the rail's project
  // list/order (ALL projects, endpoint-fixed alphabetical) and the coordinator set
  // used to gold-highlight a coordinator agent's own name.
  const agentsLiveQuery = useGetAgentsLiveQuery(undefined, { pollingInterval: 10000, skipPollingIfUnfocused: true });
  const agentIdentitiesQuery = useListAgentIdentitiesQuery();
  const agentNamesById = useMemo(() => {
    const map = new Map<string, string>();
    for (const agent of (agentIdentitiesQuery.data?.agents || [])) {
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      const id = String(agent?.agent_id || agent?.agentId || agent?.id || '').trim();
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      const name = String(agent?.name || agent?.display_name || agent?.displayName || '').trim();
      if (id && name) map.set(id, name);
    }
    return map;
  }, [agentIdentitiesQuery.data]);
  const conversations = useMemo(
    () => (conversationsQuery.data || []).map((conversation) => sidebarConversationToSummary(conversation, agentNamesById)),
    [agentNamesById, conversationsQuery.data],
  );
  const liveProjects = useMemo(() => agentsLiveQuery.data || [], [agentsLiveQuery.data]);
  // REQ-BAR-2: status bar counts. Instances reuse the agents-live poll above; live
  // shells are kept fresh by the user-WS shell events that invalidate this list.
  const liveShellsQuery = useListShellsQuery({ status: 'live', limit: STATUS_BAR_SHELL_LIMIT });
  const runningInstanceCount = useMemo(() => countRunningInstances(liveProjects), [liveProjects]);
  const shellCounts = useMemo(
    () => countShells(liveShellsQuery.data?.sessions, liveShellsQuery.data?.has_more),
    [liveShellsQuery.data],
  );
  const chainGroupsQuery = useFetchTaskChainGroupsQuery();
  const searchChains = useSelector(selectSearchChains);

  // Background pre-warm decryption of task chains when groups load or vault unlocks (REQ-SEARCH-DECRYPT-RUNTIME-1)
  useEffect(() => {
    if (!activeVaultKey) return;
    const groups = chainGroupsQuery.data?.groups;
    if (!groups || groups.length === 0) return;

    const toDecrypt: RawSearchItemInput[] = [];
    for (const g of groups) {
      for (const ch of g.chains) {
        const id = ch.chainId;
        const rawTitle = ch.title || '';
        const searchItem = searchChains[id];
        const isArmored = isVaultArmored(rawTitle);
        const needsDecryption =
          isArmored &&
          (!searchItem ||
            !searchItem.decryptedTitle ||
            isVaultArmored(searchItem.decryptedTitle));

        if (needsDecryption) {
          toDecrypt.push({
            id,
            type: 'chain',
            rawTitle,
            projectId: ch.projectId || g.projectId,
            status: ch.status,
            updatedAt: ch.updatedAt,
          });
        }
      }
    }

    if (toDecrypt.length === 0) return;

    let canceled = false;
    batchDecryptTitles(toDecrypt, activeVaultKey)
      .then((decryptedItems) => {
        if (!canceled && decryptedItems.length > 0) {
          dispatch(setBulkChainTitles(decryptedItems));
        }
      })
      .catch((err) => {
        console.error('Failed to pre-warm decrypt task chain titles in AppShell:', err);
      });

    return () => {
      canceled = true;
    };
  }, [chainGroupsQuery.data?.groups, activeVaultKey, searchChains, dispatch]);

  // UI-14: the shell owns exactly one user WebSocket connection (cookie-auth
  // `/api/v1/user-ws`). Its events flow through the single `handleUserWsEvent`
  // invalidation path. ctxRef supplies focus state read at event time — kept in
  // sync with the live route below so an event for the chain the user is viewing
  // triggers an extra chain-view refresh. (AppShell re-renders on hashchange.)
  const wsCtxRef = useRef<{ focusedChainId?: string }>({});
  {
    const routePath = getRoutePathname();
    wsCtxRef.current.focusedChainId = routePath.startsWith('/chains/')
      ? decodeSegment(routePath.split('/')[2] || '')
      : '';
  }
  const { status: wsStatus, connected: wsConnected } = useUserWebSocket(wsCtxRef);

  // UI-13: viewport-aware shell. On mobile the sidebar is an off-canvas drawer
  // (toggled), main is full-width, and a bottom tab bar replaces sidebar chrome.
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';
  // Subscription tier shown under the account row. Hubs without billing answer
  // with an error, so the row simply stays hidden there.
  const billingQuery = useGetAccountBillingQuery(user?.user_id || '', { skip: !user?.user_id });
  const planLabel = billingQuery.data?.plan_label || '';
  // The user row (and its avatar when collapsed) is the sidebar's only Settings entry point.
  const openAccountSettings = () => { if (isMobile) setDrawerOpen(false); setSettingsModalTab('account'); setSettingsModalOpen(true); };
  // Close the mobile drawer whenever the route changes.
  useEffect(() => { setDrawerOpen(false); }, [path]);

  // Handle mobile drawer open/close events.
  useEffect(() => {
    const handleCloseSidebar = () => {
      setDrawerOpen(false);
    };
    const handleOpenSidebar = () => {
      setDrawerOpen(true);
    };
    window.addEventListener('heimdall:close-sidebar', handleCloseSidebar);
    window.addEventListener('heimdall:open-sidebar', handleOpenSidebar);
    return () => {
      window.removeEventListener('heimdall:close-sidebar', handleCloseSidebar);
      window.removeEventListener('heimdall:open-sidebar', handleOpenSidebar);
    };
  }, []);

  // UI-12: Cmd/Ctrl-K opens the command palette (desktop). Also the sidebar
  // Search button and the mobile bottom-tab center button open the same surface.
  useEffect(() => {
    function handler(event: KeyboardEvent) {
      if ((event.metaKey || event.ctrlKey) && (event.key === 'k' || event.key === 'K')) {
        event.preventDefault();
        setPaletteOpen((open) => !open);
      }
    }
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, []);

  // Palette navigation: convert a logical route into a hash location.
  const handlePaletteNavigate = (route: string) => {
    if (route.startsWith('/settings')) {
      const tab = resolveSettingsTab(route);
      setSettingsModalTab(tab);
      setSettingsModalOpenState(true);
      return;
    }
    window.location.hash = buildRouteHash(route, '');
  };

  const openNewLauncher = (intent: LauncherIntent) => {
    const search = new URLSearchParams({ intent, request: String(Date.now()) });
    window.location.hash = buildRouteHash('/conversations/new', search.toString());
  };

  const openWorkspaceResource = (resourceId: string) => {
    window.location.hash = buildRouteHash(`/conversations/${encodeURIComponent(resourceId)}`, '');
  };

  useRegisterActions([
    {
      id: 'attention.open',
      title: 'Open what needs you',
      category: 'Navigation',
      sequence: ['g', 'a'],
      run: () => setAttentionOpen(true),
    },
    {
      id: 'navigation.home',
      title: 'Go to Home',
      category: 'Navigation',
      sequence: ['g', 'h'],
      run: () => handlePaletteNavigate('/'),
    },
    {
      id: 'resource.open-conversation.global',
      title: 'Open existing conversation',
      category: 'Navigation',
      sequence: ['g', 'o', 'c'],
      run: () => setResourcePicker('conversation'),
    },
    {
      id: 'resource.open-task-chain.global',
      title: 'Open task-chain coordinator',
      category: 'Navigation',
      sequence: ['g', 'o', 't'],
      run: () => setResourcePicker('task-chain'),
    },
    {
      id: 'resource.open-shell.global',
      title: 'Open running shell',
      category: 'Navigation',
      sequence: ['g', 'o', 's'],
      run: () => setResourcePicker('shell'),
    },
    {
      id: 'resource.new-conversation.global',
      title: 'New conversation',
      category: 'Navigation',
      sequence: ['g', 'n', 'c'],
      run: () => openNewLauncher('agent'),
    },
    {
      id: 'resource.new-shell.global',
      title: 'New shell',
      category: 'Navigation',
      sequence: ['g', 'n', 's'],
      run: () => openNewLauncher('shell'),
    },
    {
      id: 'navigation.settings',
      title: 'Open Settings',
      category: 'Navigation',
      sequence: ['g', 's'],
      run: () => {
        setSettingsModalTab('');
        setSettingsModalOpenState(true);
      },
    },
  ]);

  const paletteActions = useMemo(
    () => mergePaletteActions(DEFAULT_ACTIONS, shortcutActions),
    [shortcutActions],
  );

  const handlePaletteAction = (actionId: string) => {
    switch (actionId) {
      case 'new-conversation':
        handlePaletteNavigate('/conversations/new');
        break;
      case 'new-agent':
        handlePaletteNavigate('/agents/new');
        break;
      case 'new-chain':
        handlePaletteNavigate('/chains');
        break;
      case 'new-project':
        handlePaletteNavigate('/projects');
        break;
      case 'settings':
      case 'settings-modal':
        setSettingsModalTab('');
        setSettingsModalOpenState(true);
        break;
      case 'settings-appearance':
      case 'change-theme':
        setSettingsModalTab('appearance');
        setSettingsModalOpenState(true);
        break;
      default:
        if (actionId.startsWith('set-theme-')) {
          const themeId = actionId.slice('set-theme-'.length);
          dispatch(setTheme(themeId));
        } else {
          runAction(actionId);
        }
        break;
    }
  };

  useEffect(() => {
    const update = () => {
      const current = routeFromLocation();
      setPath(current);
      setRouteSearch(routeSearchFromLocation());
      setFocusMessageId(focusMessageFromLocation());
      if (current.startsWith('/settings')) {
        const tab = resolveSettingsTab(current);
        setSettingsModalTab(tab);
        setSettingsModalOpenState(true);
      }
    };
    window.addEventListener('hashchange', update);
    window.addEventListener('popstate', update);
    update();
    return () => {
      window.removeEventListener('hashchange', update);
      window.removeEventListener('popstate', update);
    };
  }, []);

  // Clamp any rogue window scroll back to the origin. The app owns the full viewport
  // (body is position: fixed), so a non-zero window offset can only come from a browser
  // heuristic -- e.g. mobile WebKit scrolling the document to reveal a focused element or
  // a control under the keyboard accessory bar -- and it permanently hides the top chrome.
  useEffect(() => {
    const clampWindowScroll = () => {
      if (window.scrollY !== 0 || window.scrollX !== 0) {
        window.scrollTo(0, 0);
      }
    };
    window.addEventListener('scroll', clampWindowScroll, { passive: true });
    clampWindowScroll();
    return () => {
      window.removeEventListener('scroll', clampWindowScroll);
    };
  }, []);

  const primary = NAV_ROUTES.filter((item) => item.group === 'primary');
  const conversationTree = useMemo(() => buildProjectConversationTree(conversations, liveProjects), [conversations, liveProjects]);
  const isEffectiveCollapsed = isMobile ? !drawerOpen : collapsed;
  const isWorkspaceRoute = isAgentConversationRoute(path);
  const hideTopLeftCluster = isMobile && isWorkspaceRoute && isCurrentAuxPaneOpen;
  const showBrand = !isWorkspaceRoute;
  const topLeftClusterWidth = computeTopLeftClusterWidth(isMobile, showBrand);
  const chromeHeight = topChromeHeight(isMobile);
  const chromeIconButtonClass = chromeIconButtonSizeClass(isMobile);
  // Fixed window controls: sidebar + vault everywhere, plus the wordmark on
  // every route except an agent conversation. They do not move with the sidebar.
  const sidebarToggleButton = (
    <button
      data-debug-id="shell-sidebar-collapse-toggle"
      type="button"
      onClick={() => (isMobile ? setDrawerOpen(!drawerOpen) : toggleCollapsed())}
      aria-label={isEffectiveCollapsed ? 'Show sidebar' : 'Hide sidebar'}
      title={isEffectiveCollapsed ? 'Show sidebar' : 'Hide sidebar'}
      aria-expanded={!isEffectiveCollapsed}
      className={`grid ${chromeIconButtonClass} shrink-0 place-items-center text-muted hover:bg-neutral-soft hover:text-primary`}
    >
      <Icon name="panel-left" size={isMobile ? 20 : 16} />
    </button>
  );
  const vaultSupported = isVaultSupported();
  // Rendered by the status bar's vault module, which supplies `compact` (mobile).
  const renderVaultStatusButton = (compact: boolean) => (
    <button
      data-debug-id="shell-vault-status-toggle"
      type="button"
      disabled={!vaultSupported || isVaultLocking || isVaultReconciling}
      onClick={() => {
        if (!vaultSupported || isVaultLocking || isVaultReconciling) return;
        if (!isVaultUnlocked) {
          dispatch(setUnlockModalOpen(true));
          return;
        }
        if (hasOnlineLockedBridge) {
          void reconcileOnlineLockedBridges();
          return;
        }
        setIsVaultLocking(true);
        void lockAllConnectedBridges()
          .finally(() => {
            dispatch(lockVault());
            setIsVaultLocking(false);
          });
      }}
      aria-label={hasOnlineLockedBridge ? 'Unlock locked bridges' : isVaultUnlocked ? 'Lock vault' : 'Unlock vault'}
      aria-pressed={isVaultUnlocked && !hasOnlineLockedBridge}
      title={!vaultSupported
        ? 'Vault unavailable in this browser context'
        : hasOnlineLockedBridge
          ? `${onlineLockedBridgeIds.length} connected bridge${onlineLockedBridgeIds.length === 1 ? '' : 's'} locked — click to unlock`
          : isVaultUnlocked
            ? 'Vault unlocked — click to lock'
            : 'Vault locked — click to unlock'}
      className={`inline-flex shrink-0 items-center gap-1 px-1.5 font-bold transition-[filter] hover:brightness-125 disabled:cursor-not-allowed disabled:opacity-50 ${compact ? 'h-8 text-[13px]' : 'h-6 text-[11px]'} ${
        hasOnlineLockedBridge ? 'text-warning' : isVaultUnlocked ? 'text-success' : 'text-danger'
      }`}
    >
      <Icon name={isVaultUnlocked && !hasOnlineLockedBridge ? 'lock-open' : 'lock'} size={compact ? 14 : 12} />
      <span>{hasOnlineLockedBridge ? `${onlineLockedBridgeIds.length} locked` : isVaultUnlocked ? 'Unlocked' : 'Locked'}</span>
    </button>
  );
  const brandLink = (
    <a href={shellHash('/home')} data-debug-id="shell-brand" className="min-w-0 rounded-lg px-1.5 py-1 hover:bg-neutral-soft">
      <span className="block truncate text-sm font-black tracking-tight text-primary">Heimdall</span>
    </a>
  );
  const sidebarError = String((conversationsQuery.error as any)?.error || (agentsLiveQuery.error as any)?.error || '');
  const sidebarLoading = conversationsQuery.isLoading || agentsLiveQuery.isLoading;

  // Device approval and initial provider selection are focused setup ceremonies,
  // not application workspaces.
  // Keep navigation, command palette, and vault onboarding
  // out of this route so the operator sees only the machine asking for access and the
  // decision in front of them.
  if (path === '/device/add') {
    return (
      <main
        data-debug-id="enrollment-standalone-page"
        className="fixed inset-x-0 top-0 app-viewport-height w-full overflow-auto bg-canvas text-primary"
      >
        <BridgeEnrollmentApprovalPage />
      </main>
    );
  }

  if (path === '/device/providers' || path.startsWith('/device/providers/')) {
    const encodedBridgeId = path.slice('/device/providers/'.length);
    const providerBridgeId = encodedBridgeId
      ? decodeURIComponent(encodedBridgeId)
      : 'brg_mock_dawnstar';
    return (
      <main
        data-debug-id="provider-enrollment-standalone-page"
        className="fixed inset-x-0 top-0 app-viewport-height w-full overflow-auto bg-canvas text-primary"
      >
        <ProviderEnrollmentSetupPage bridgeId={providerBridgeId} />
      </main>
    );
  }

  const userAvatar = (
    <span data-debug-id="shell-user-ws-owner" data-ws-status={wsStatus} title={wsConnected ? 'User WS · live' : wsStatus === 'error' ? 'User WS · error' : 'User WS · connecting'} className={`grid h-7 w-7 shrink-0 place-items-center rounded-full bg-neutral-soft text-caption font-bold text-muted`}>
      {(displayName || 'U').slice(0, 1).toUpperCase()}
      <span className="absolute ml-5 mt-5">
        <StatusDot
          className="ring-2 ring-surface"
          tone={wsConnected ? 'success' : wsStatus === 'error' ? 'danger' : 'pending'}
          pulse={!wsConnected && wsStatus !== 'error'}
          label={wsConnected ? 'User WS live' : wsStatus === 'error' ? 'User WS error' : 'User WS connecting'}
        />
      </span>
    </span>
  );
  return (
    /* REQ-KBD-2: was `fixed inset-0 … h-full`. `inset-0` pinned this box's BOTTOM edge to
       the layout viewport, which iOS never shrinks for a soft keyboard, and `h-full` on a
       fixed element resolves against that same layout viewport rather than `#root` — so
       the shell stayed 812px tall while only the top 409px were visible, leaving the
       composer at 540..776 inside the invisible 403px (REQ-KBD-1 §1). Pinning only the top
       and taking the height from `--app-viewport-height` (= `visualViewport.height`) makes
       the shell end where the keyboard begins. Keep `inset-x-0 top-0`, NOT `inset-0`. */
    <div
      data-debug-id="app-shell"
      className="fixed inset-x-0 top-0 app-viewport-height flex w-full max-w-full flex-col overflow-hidden bg-canvas text-primary"
    >
      {/* REQ-BAR-4: the shell is a column — the app row, then the in-flow status
          bar. In-flow (not fixed) so it ends where the soft keyboard begins. */}
      <div data-debug-id="app-shell-row" className="relative flex min-h-0 w-full flex-1 overflow-hidden">
      {/* UI-13: mobile drawer scrim. Closes the expanded sidebar on tap. */}
      {isMobile && drawerOpen ? (
        <div
          data-debug-id="shell-mobile-drawer-scrim"
          onClick={() => setDrawerOpen(false)}
          className="fixed inset-0 z-40 bg-surface-overlay/80 backdrop-blur-sm md:hidden"
          aria-hidden="true"
        />
      ) : null}
      {/* Jetski web: the sidebar toggle + app name are a FIXED top-left cluster
          that never moves; the sidebar slides open underneath it (its header
          reserves the cluster's space) and a hidden sidebar takes ZERO width. */}
      {!hideTopLeftCluster ? (
        <div
          data-debug-id="shell-top-left-cluster"
          className="absolute left-0 top-0 z-[60] flex items-center gap-1 px-2"
          style={{ width: topLeftClusterWidth, height: chromeHeight }}
        >
          {sidebarToggleButton}
          {showBrand ? brandLink : null}
        </div>
      ) : null}
      <aside
        data-debug-id={isEffectiveCollapsed ? 'shell-left-sidebar-hidden' : 'shell-left-sidebar-expanded'}
        aria-hidden={isEffectiveCollapsed}
        className={`flex shrink-0 flex-col overflow-hidden bg-surface motion-reduce:transition-none ${
          isMobile
            ? `fixed top-0 left-0 z-50 app-viewport-height w-80 max-w-[calc(100vw-1rem)] border-r border-subtle transition-[transform,visibility] duration-200 ease-out ${
                isEffectiveCollapsed ? 'invisible -translate-x-full' : 'visible translate-x-0'
              }`
            : `transition-[width,visibility] duration-200 ease-out ${
                isEffectiveCollapsed ? 'invisible w-0' : 'visible w-80 border-r border-subtle'
              }`
        }`}
        aria-label="Primary navigation"
      >
        <div className="flex w-80 max-w-[calc(100vw-1rem)] min-h-0 flex-1 flex-col">
        {/* Reserves the fixed top-left cluster's row; the update badge lives in the top bar. */}
        <div aria-hidden="true" className="shrink-0" style={{ height: chromeHeight }} />

        <div className="flex-1 overflow-y-auto p-3">
          {/* Primary action: open the command palette (search + jump + new chat).
              The palette is the canonical entry point (also Cmd/Ctrl-K on desktop). */}
          <button
            data-debug-id="shell-sidebar-search-button"
            type="button"
            onClick={() => {
              if (isMobile) setDrawerOpen(false);
              setPaletteOpen(true);
            }}
            title="Search (⌘K)"
            aria-label="Search"
            aria-keyshortcuts="Meta+K Control+K"
            className="mb-2 flex min-h-11 w-full items-center gap-2 rounded-2xl border border-subtle bg-surface-raised px-3 py-2 text-sm text-muted hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name="search" size={18} />
            <span className="flex-1 text-left">Search</span>
            <kbd className="rounded border border-subtle bg-surface px-1.5 py-0.5 text-[10px] font-medium text-faint">⌘K</kbd>
          </button>
          <nav data-debug-id="shell-primary-nav" className="mt-2 space-y-0.5" aria-label="Primary destinations">
            {primary.map((item) => (
              <NavItem
                key={item.path}
                item={item}
                active={isRouteActive(path, item.path)}
                collapsed={false}
                onClick={isMobile ? () => setDrawerOpen(false) : undefined}
              />
            ))}
          </nav>
        </div>

        <div className={`border-t border-subtle p-3`}>
          <div data-debug-id="shell-global-ownership-points" className={`flex items-center gap-2 rounded-xl px-2 py-1.5`}>
            {userAvatar}
            {(
              <button type="button" data-debug-id="shell-open-account" aria-label="Open account settings" onClick={openAccountSettings} className="min-w-0 flex-1 rounded-lg text-left focus-visible:outline-none focus-visible:shadow-focus hover:bg-neutral-soft">
                <div data-debug-id="shell-current-user-owner" className={`truncate font-semibold text-primary ${isMobile ? 'text-[14px]' : 'text-[12px]'}`}>{displayName}</div>
                <div className={`truncate text-muted ${isMobile ? 'text-[12px]' : 'text-[10.5px]'}`}>{user.email || user.user_id || ''}</div>
              </button>
            )}
            {logoutUrl && <a data-debug-id="auth-logout-link" href={logoutUrl} title="Sign out" className={`grid shrink-0 place-items-center text-muted hover:bg-neutral-soft hover:text-primary ${isMobile ? 'h-11 w-11 rounded-full' : 'rounded-lg p-1.5'}`}><Icon name="close" size={isMobile ? 18 : 14} /></a>}
          </div>
          {planLabel ? (
            <button type="button" data-debug-id="shell-subscription-tier" aria-label={`Subscription: ${planLabel}. Open account settings`} onClick={openAccountSettings} className="mt-1 flex w-full items-center gap-2 rounded-lg px-2 py-1 text-left text-[11px] text-muted hover:bg-neutral-soft hover:text-primary focus-visible:outline-none focus-visible:shadow-focus">
              <Icon name="sparkle" size={12} className="shrink-0 text-accent" />
              <span className="truncate">Plan · <span className="font-semibold text-primary">{planLabel}</span></span>
            </button>
          ) : null}
        </div>
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col h-full min-h-0 overflow-hidden">
        {/* The fixed top-left cluster floats over the content. On the conversation
            workspace the top-left chat header reserves its space; other pages get a
            top bar in BOTH sidebar states (so the page never shifts when the sidebar
            toggles), holding the update badge on its right. */}
        {!isWorkspaceRoute ? (
          <div
            data-debug-id="shell-top-bar"
            className="flex shrink-0 items-center justify-end gap-2 border-b border-subtle bg-canvas px-3"
            style={{ height: chromeHeight }}
          >
            <SidebarUpdateBadge onOpen={openBridgeUpdate} />
          </div>
        ) : null}
        <RouteOutlet
          path={path}
          routeSearch={routeSearch}
          focusMessageId={focusMessageId}
          conversations={conversations}
          liveProjects={liveProjects}
          workspaceLeading={isEffectiveCollapsed ? <div aria-hidden="true" data-debug-id="shell-top-left-cluster-spacer" className="shrink-0" style={{ width: topLeftClusterWidth - 12 }} /> : null}
          workspaceLeadingWidth={isEffectiveCollapsed ? topLeftClusterWidth : 0}
          workspaceTrailing={<SidebarUpdateBadge onOpen={openBridgeUpdate} />}
        />
      </div>
      </div>

      <StatusBar
        modules={STATUS_BAR_MODULES}
        compact={isMobile}
        data={{
          runningInstances: runningInstanceCount,
          shells: shellCounts,
          shortcutMode,
          renderVaultToggle: renderVaultStatusButton,
          attention: {
            total: attentionTotal,
            unseen: attentionUnseen,
            onOpen: () => setAttentionOpen(true),
          },
        }}
      />
      <AttentionDeck open={attentionOpen} onClose={() => setAttentionOpen(false)} range={attentionRange} onRangeChange={setAttentionRange} />
      <AttentionUndoToast />

      <CommandPalette open={paletteOpen} onClose={() => setPaletteOpen(false)} onNavigate={handlePaletteNavigate} onAction={handlePaletteAction} actions={paletteActions} currentPath={path} conversationGroups={conversationTree.map((group) => ({ projectId: group.project.projectId, projectName: group.project.name, conversations: group.conversations.map((c) => ({ conversationId: c.conversationId, agentInstanceId: c.agentInstanceId, title: displayConversationTitle(c), agentName: c.agentName, isCoordinator: c.isCoordinator, runtimeStatus: c.runtimeStatus, activityStatus: c.activityStatus, unreadCount: c.unreadCount })) }))} chainGroups={chainGroupsQuery.data?.groups ?? []} />
      <ConversationSelectorModal
        open={resourcePicker === 'conversation'}
        onClose={() => setResourcePicker(null)}
        onSelectConversation={openWorkspaceResource}
      />
      <TaskChainSelectorModal
        open={resourcePicker === 'task-chain'}
        onClose={() => setResourcePicker(null)}
        onSelectChain={(chain) => {
          if (chain.coordinatorAgentInstanceId) openWorkspaceResource(chain.coordinatorAgentInstanceId);
          setResourcePicker(null);
        }}
      />
      <RunningShellSelectorModal
        open={resourcePicker === 'shell'}
        onClose={() => setResourcePicker(null)}
        onSelectShell={openWorkspaceResource}
      />
      <ProjectLaunchModal
        isOpen={Boolean(launchModalProject)}
        project={launchModalProject}
        onClose={() => setLaunchModalProject(null)}
        onLaunched={(instanceId) => {
          setLaunchModalProject(null);
          window.location.hash = buildRouteHash('/conversations/' + encodeURIComponent(instanceId), '');
        }}
      />
      <VaultOnboardingHost
        onboardingOpen={isOnboardingModalOpen}
        onOnboardingOpenChange={setIsOnboardingModalOpen}
        bridgeReauthenticationOpen={isBridgeReauthenticationOpen}
        onBridgeReauthenticationOpenChange={setIsBridgeReauthenticationOpen}
        onBridgeReauthenticate={async (rawVaultKeyHex) => {
          setActiveBridgeVaultKeyMaterial(rawVaultKeyHex);
          await reconcileOnlineLockedBridges(rawVaultKeyHex);
        }}
      />
      <SettingsModal
        open={settingsModalOpen}
        onOpenChange={setSettingsModalOpen}
        initialTab={settingsModalTab}
        user={user}
      />
    </div>
  );
}

export default function AppShell() {
  return <AuthGate />;
}
