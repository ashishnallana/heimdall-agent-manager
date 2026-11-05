import { useEffect, useMemo, useRef, useState, type FormEvent, type ReactNode } from 'react';
import { useSelector } from 'react-redux';
import { Button, IconButton, Text } from '@ui';
import { useCreateAgentMutation, useListAgentIdentitiesQuery, useListAgentTemplatesQuery } from '../../api/endpoints/agents';
import { useListBridgesQuery, useListAgentBridgeSupportQuery, useBridgeProviderStatus } from '../../api/endpoints/bridgeSupport';
import { useCreateLaunchConversationMutation } from '../../api/endpoints/chats';
import { useListProjectsQuery } from '../../api/endpoints/projects';
import { useGetProjectVcsStatusQuery } from '../../api/endpoints/projectVcs';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { useCreateArtifactMutation } from '../../api/endpoints/artifacts';
import { useGetConversationLaunchPreferencesQuery, useSaveConversationLaunchSelectionMutation, useSetAgentFavoriteMutation } from '../../api/endpoints/conversationLaunch';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { buildRouteHash, getRouteSearch, getRoutePathname } from '../../utils/appLocation';
import { apiErrorText } from '../../api/cookieFetch';
import { artifactKindForFile, artifactLinkFromResponse, artifactMimeForFile, artifactUploadName, clipboardFilesFromEvent } from '../../utils/artifactUpload';
import { composerBridgeIsOnline } from '../../utils/composerBridgeOptions';
import { getActiveVaultKey } from '../../utils/vaultContent';
import { MAX_UPLOAD_BYTES, UPLOAD_TOO_LARGE_ERROR } from '../ArtifactUpload';
import UpgradePrompt from '../billing/UpgradePrompt';
import ModelCatalogRefresh from '../providers/ModelCatalogRefresh';
import { useIsMobile } from '../shell/responsive';
import { resolveProjectBridgeShellCwd } from '../shells/interactiveShellLaunch';
import { useShellLaunch } from '../shells/useShellLaunch';
import { resolveProjectExplorerAccess } from './projectVcsExperiment';
import type { RuntimeSelection } from './RuntimeConfigurationOptions';
import { AgentMenu, type NewFavoriteAgent } from './launcher/AgentMenu';
import { bridgeDisplayName } from './launcher/BridgeMenu';
import { ConversationComposerBody, LaunchComposer, ShellComposerBody } from './launcher/LaunchComposer';
import { LaunchHeadline, shouldShowBridgeClause, type LaunchHeadlineMenu } from './launcher/LaunchHeadline';
import { NewProjectModal } from './launcher/NewProjectModal';
import { NoBridgeBanner, NoBridgeOnline, noBridgeOnline, noBridgeRows } from './launcher/NoBridgeOnline';
import type { LauncherMode } from './launcher/ModeMenu';
import { isDefaultConversationProject } from './launcher/ProjectMenu';
import { RuntimeMenu } from './launcher/RuntimeMenu';
import type { LauncherIntent } from '../../store/workspaceLayoutSlice';

type Attachment = { localId: string; id?: string; file: File; name: string; status: 'uploading' | 'uploaded' | 'error'; error?: string };
function message(e: any) { return String(e?.error || e?.message || apiErrorText(e)); }

/** localStorage key of the last chosen mode (SH-1; a per-browser convenience). */
export const PANE_MODE_STORAGE_KEY = 'heimdall:new-pane-mode';

/**
 * Where a bridge problem points the user. With the headline's `on [bridge]` clause
 * shown, at that token; without it (one bridge, or none online) there is nothing to
 * pick, so say what is wrong.
 */
export function bridgeIssueText(mode: LauncherMode, bridgeClauseShown: boolean): string {
  if (bridgeClauseShown) return 'Choose a connected bridge above.';
  return mode === 'shell' ? 'No bridge is online. Start a bridge to launch a shell.' : 'No bridge is online. Start a bridge to start a conversation.';
}

/** Spec §4 #19: the no-bridge screen fades out at --duration-fast before the launcher swaps in. */
export const NO_BRIDGE_EXIT_MS = 120;

/**
 * Spec §3.7: below 768px the composer docks to the bottom of the scroll area,
 * lifted clear of the bottom tab bar (`--ui-bottom-chrome`) or the safe area.
 * The page fills the height below md and the dock has `max-md:mt-auto`, so at
 * rest the composer sits near the bottom instead of under the headline.
 * The canvas backdrop and top padding keep scrolled content from showing behind it.
 * The page drops these classes while a launcher menu is open.
 */
export const LAUNCH_DOCK_MOBILE = 'max-md:sticky max-md:bottom-[max(var(--ui-bottom-chrome,0px),env(safe-area-inset-bottom,0px))] max-md:z-sticky max-md:bg-canvas max-md:pb-3 max-md:pt-2';

/**
 * Which no-bridge state the page shows (spec §3.5 / §3.6, user-confirmed rule):
 *  - `full`: the full-screen NoBridgeOnline, only decided once, on the first
 *    bridge list of a cold start, when zero non-revoked bridges are online and the
 *    page is not `embedded`;
 *  - `banner`: the launcher with the inline banner and a disabled composer, when
 *    no bridge is online later in the session (the chosen bridge dropped while the
 *    user was here, so a typed message is kept), or on an embedded cold start;
 *  - `none`: the launcher as usual.
 */
export type NoBridgeScreen = 'pending' | 'full' | 'launcher';
export function initialNoBridgeScreen(bridges: ReadonlyArray<any> | null | undefined, embedded: boolean): Exclude<NoBridgeScreen, 'pending'> {
  return !embedded && noBridgeOnline(bridges) ? 'full' : 'launcher';
}

export interface NewConversationPageProps {
  embedded?: boolean;
  footer?: ReactNode;
  /**
   * Called with the new agent instance id (or shell session id) instead of
   * navigating to it (a Main new-chat pane puts the new conversation into THAT pane).
   */
  onLaunched?: (agentInstanceId: string) => void;
  /** Explicit shortcut intent. It selects the initial mode without rewriting the saved preference. */
  launchIntent?: LauncherIntent;
}

/**
 * The new conversation page (spec §3): a sentence headline whose nouns are the
 * mode / project / bridge controls, the meta line, the shared composer (agent and
 * provider chips in its footer), and a quiet issues line under it.
 */
export default function NewConversationPage({ embedded = false, footer, onLaunched, launchIntent }: NewConversationPageProps) {
  const mobile = useIsMobile();
  // SH-1: the page opens an agent conversation OR an interactive shell. The
  // choice is a per-browser convenience, so it lives in localStorage.
  const [paneMode, setPaneModeState] = useState<LauncherMode>(() => {
    if (launchIntent) return launchIntent;
    try { return localStorage.getItem(PANE_MODE_STORAGE_KEY) === 'shell' ? 'shell' : 'agent'; } catch { return 'agent'; }
  });
  useEffect(() => {
    if (launchIntent) setPaneModeState(launchIntent);
  }, [launchIntent]);
  const setPaneMode = (next: LauncherMode) => {
    setPaneModeState(next);
    try { localStorage.setItem(PANE_MODE_STORAGE_KEY, next); } catch { /* storage unavailable */ }
  };
  const preferences = useGetConversationLaunchPreferencesQuery();
  const agentsQuery = useListAgentIdentitiesQuery({ limit: 200 });
  const projectsQuery = useListProjectsQuery();
  const bridgesQuery = useListBridgesQuery(undefined, { refetchOnMountOrArgChange: true });
  const templatesQuery = useListAgentTemplatesQuery();
  const experimentsQuery = useFetchExperimentsQuery();
  const [saveSelection] = useSaveConversationLaunchSelectionMutation();
  const [setFavorite, favoriteState] = useSetAgentFavoriteMutation();
  const [createAgent, createAgentState] = useCreateAgentMutation();
  const [launch, launchState] = useCreateLaunchConversationMutation();
  const [createArtifact] = useCreateArtifactMutation();
  const vaultUnlocked = useSelector(selectIsVaultUnlocked);
  const [hydrated, setHydrated] = useState(false);
  const [agentId, setAgentId] = useState('');
  const [projectId, setProjectId] = useState('');
  const [runtime, setRuntime] = useState<RuntimeSelection>({ bridgeId: '', provider: '', model: '' });
  const [draft, setDraft] = useState('');
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [error, setError] = useState('');
  const [preferenceFailures, setPreferenceFailures] = useState<Record<string, string>>({});
  const preferenceError = Object.values(preferenceFailures).join(' ');
  const [pendingWrites, setPendingWrites] = useState(0);
  const [projectOpen, setProjectOpen] = useState(false);
  const [runtimeMenuOpen, setRuntimeMenuOpen] = useState(false);
  const [headlineMenu, setHeadlineMenu] = useState<LaunchHeadlineMenu | null>(null);
  const [agentMenuOpen, setAgentMenuOpen] = useState(false);
  // Spec §3.7: while any launcher menu is open (a bottom sheet on mobile) the
  // composer drops out of its sticky dock, so it never sits above the scrim.
  const menuOpen = Boolean(headlineMenu) || runtimeMenuOpen || agentMenuOpen;
  const [managementError, setManagementError] = useState('');
  const [transitioning, setTransitioning] = useState(false);
  const composerRef = useRef<HTMLDivElement>(null);
  const launchAnimation = useRef<Animation | null>(null);
  useEffect(() => () => launchAnimation.current?.cancel(), []);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const openShellRef = useRef<HTMLButtonElement>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const submitRef = useRef(false);
  const writeTail = useRef<Promise<unknown>>(Promise.resolve());
  const latestSelections = useRef<Record<string, string>>({});
  const [routeProject, setRouteProject] = useState(() => new URLSearchParams(getRouteSearch()).get('project_id') || '');
  useEffect(() => {
    const syncRoute = () => setRouteProject(new URLSearchParams(getRouteSearch()).get('project_id') || '');
    window.addEventListener('hashchange', syncRoute);
    return () => window.removeEventListener('hashchange', syncRoute);
  }, []);
  function consumeProjectPreselection() {
    if (!routeProject) return;
    const params = new URLSearchParams(getRouteSearch()); params.delete('project_id');
    window.history.replaceState(window.history.state, '', buildRouteHash(getRoutePathname(), params.toString()));
    setRouteProject('');
  }
  const agents = agentsQuery.data?.agents || [];
  const projects = projectsQuery.data?.projects || [];
  const bridges = bridgesQuery.data?.bridges || [];
  // No-bridge states (spec §3.5/§3.6). The cold-start decision is made once, on the
  // first bridge list; a later drop shows the banner instead of the full screen.
  const [screen, setScreen] = useState<NoBridgeScreen>('pending');
  const [leavingNoBridge, setLeavingNoBridge] = useState(false);
  const [swapInLauncher, setSwapInLauncher] = useState(false);
  const recoveredFromFull = useRef(false);
  const zeroOnline = Boolean(bridgesQuery.data) && noBridgeOnline(bridges);
  useEffect(() => {
    if (screen === 'pending') {
      if (bridgesQuery.data) setScreen(initialNoBridgeScreen(bridges, embedded));
      else if (bridgesQuery.isError) setScreen('launcher');
      return;
    }
    if (screen !== 'full' || zeroOnline) { setLeavingNoBridge(false); return; }
    // A bridge came online: fade the empty state out (fast), then swap the launcher in.
    setLeavingNoBridge(true);
    const reduced = typeof window.matchMedia === 'function' && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const timer = window.setTimeout(() => { setLeavingNoBridge(false); setSwapInLauncher(true); recoveredFromFull.current = true; setScreen('launcher'); }, reduced ? 0 : NO_BRIDGE_EXIT_MS);
    return () => window.clearTimeout(timer);
  }, [screen, bridgesQuery.data, bridgesQuery.isError, zeroOnline, embedded]);
  const showBanner = screen === 'launcher' && zeroOnline;
  const favoriteIds = [...(preferences.data?.favorite_agent_ids || [])].sort((a, b) => { const rank = (id: string) => { const slug = agents.find(agent => agent.agent_id === id)?.slug; return slug === 'soloist' ? 0 : slug === 'coordinator' ? 1 : 2; }; return rank(a) - rank(b); });
  const pinnedIds = preferences.data?.pinned_agent_ids || [];
  const favoritesFull = favoriteIds.length >= 6;
  const support = useListAgentBridgeSupportQuery({ agentId }, { skip: !agentId });
  const selectedAgent = agents.find(a => a.agent_id === agentId);
  const selectedProject = projects.find((p: any) => p.project_id === projectId);
  const selectedBridgeRow = useMemo(() => bridges.find((b: any) => b.bridge_id === runtime.bridgeId), [bridges, runtime.bridgeId]);
  // Provider status for the selected bridge only (not every bridge); polled live
  // while the provider menu is open so a sign-in elsewhere shows up.
  const selectedProviders = useBridgeProviderStatus(selectedBridgeRow, { live: runtimeMenuOpen });
  const selectedBridge = selectedProviders.bridge;
  const capabilities = selectedProviders.capabilities;
  const bridgeClauseShown = useMemo(() => shouldShowBridgeClause(bridges), [bridges]);

  // The meta line's branch: only with the project VCS experiment on, for a real
  // project on an online bridge. Unknown -> omitted.
  const vcsEnabled = resolveProjectExplorerAccess(experimentsQuery.data?.flags, experimentsQuery.isError) === 'enabled';
  const branchProjectId = selectedProject && !isDefaultConversationProject(selectedProject) ? projectId : '';
  const vcsStatus = useGetProjectVcsStatusQuery(
    { projectId: branchProjectId, bridgeId: runtime.bridgeId },
    { skip: !vcsEnabled || !branchProjectId || !selectedBridgeRow || !composerBridgeIsOnline(selectedBridgeRow) },
  );
  const branch = vcsStatus.data?.ok ? vcsStatus.data.branch : '';

  // Writes only originate in this page. One field per PATCH plus a serial client
  // queue preserves rapid selections without replacing unrelated preferences.
  function remember(field: 'agent_id' | 'project_id' | 'bridge_id', value: string) {
    latestSelections.current[field] = value;
    setPendingWrites(n => n + 1);
    const work = writeTail.current.catch(() => {}).then(async () => {
      if (latestSelections.current[field] !== value) return;
      await saveSelection({ field, value }).unwrap();
    });
    writeTail.current = work;
    void work.then(() => setPreferenceFailures(rows => { const next = { ...rows }; delete next[field]; return next; }), e => setPreferenceFailures(rows => ({ ...rows, [field]: message(e) }))).finally(() => setPendingWrites(n => n - 1));
  }
  function chooseAgent(id: string) { setAgentId(id); remember('agent_id', id); }
  function chooseProject(id: string) { setProjectId(id); remember('project_id', id); }
  function chooseRuntime(next: RuntimeSelection) { setRuntime(next); if (next.bridgeId !== runtime.bridgeId) remember('bridge_id', next.bridgeId); }

  useEffect(() => {
    if (hydrated || !preferences.data || !agentsQuery.data || !projectsQuery.data || !bridgesQuery.data) return;
    const prefs = preferences.data;
    const initialAgent = prefs.agent_id || agents.find(agent => agent.slug === 'coordinator' && prefs.favorite_agent_ids.includes(agent.agent_id))?.agent_id || prefs.favorite_agent_ids?.[0] || '';
    const initialProject = routeProject || prefs.project_id || projects.find((p: any) => p.state === 'active' && (p.is_default_conversations || p.slug === 'conversation'))?.project_id || projects.find((p: any) => p.state === 'active')?.project_id || '';
    // Provider status is fetched per selected bridge, so the default is the first
    // connected bridge; the issues list below catches one without usable providers.
    // Bridges disabled for being over the plan limit are never a default.
    const preferredBridge = bridges.find((b: any) => b.bridge_id === prefs.bridge_id && !b.plan_disabled_at);
    const initialBridge = preferredBridge?.bridge_id || bridges.find((b: any) => !b.plan_disabled_at && b.runtime_connected && b.status === 'online')?.bridge_id || '';
    setAgentId(initialAgent); setProjectId(initialProject); setRuntime({ bridgeId: initialBridge, provider: '', model: '' });
    consumeProjectPreselection(); setHydrated(true);
    if (initialAgent !== prefs.agent_id) remember('agent_id', initialAgent);
    if (initialProject !== prefs.project_id) remember('project_id', initialProject);
    if (initialBridge !== prefs.bridge_id) remember('bridge_id', initialBridge);
  }, [preferences.data, agentsQuery.data, projectsQuery.data, bridgesQuery.data, hydrated, routeProject]);
  // Recovery: hydrating with no bridge online leaves no bridge chosen (or the saved,
  // offline one). When a bridge comes online, fill an empty choice; after the full
  // screen hands back to the launcher, also replace an offline choice, so the page
  // the user returns to is usable without a pick. Otherwise a saved choice stays
  // (the issues line points at the headline token).
  const firstOnlineId = useMemo(() => String(noBridgeRows(bridges).find(composerBridgeIsOnline)?.bridge_id || ''), [bridges]);
  const chosenOnline = Boolean(selectedBridgeRow && composerBridgeIsOnline(selectedBridgeRow));
  useEffect(() => {
    if (!hydrated || !firstOnlineId || chosenOnline) { if (chosenOnline) recoveredFromFull.current = false; return; }
    if (runtime.bridgeId && !recoveredFromFull.current) return;
    recoveredFromFull.current = false;
    chooseRuntime({ bridgeId: firstOnlineId, provider: '', model: '' });
  }, [hydrated, firstOnlineId, chosenOnline, screen]);
  useEffect(() => {
    if (!hydrated || !routeProject) return;
    chooseProject(routeProject); consumeProjectPreselection();
  }, [routeProject, hydrated]);
  useEffect(() => {
    if (!capabilities.length) return;
    setRuntime(current => {
      const provider = current.provider || capabilities[0].provider;
      const model = current.model || capabilities.find(c => c.provider === provider)?.models[0] || '';
      return provider === current.provider && model === current.model ? current : { ...current, provider, model };
    });
  }, [capabilities]);

  function openLaunched(id: string) {
    if (onLaunched) onLaunched(id);
    else window.location.hash = buildRouteHash(`/conversations/${encodeURIComponent(id)}`, '');
  }

  // Shell mode (SH-1): the launch logic lives in useShellLaunch; the bridge is the
  // headline's bridge token whenever that bridge is online.
  const shell = useShellLaunch({ projects, bridges, projectId, initialBridgeId: runtime.bridgeId, onStarted: openLaunched, enabled: paneMode === 'shell' });
  const { bridgeId: shellBridgeId, setBridgeId: setShellBridgeId, onlineBridges: shellOnlineBridges } = shell;
  useEffect(() => {
    if (runtime.bridgeId && runtime.bridgeId !== shellBridgeId && shellOnlineBridges.some(b => b.bridge_id === runtime.bridgeId)) setShellBridgeId(runtime.bridgeId);
  }, [runtime.bridgeId, shellBridgeId, shellOnlineBridges, setShellBridgeId]);
  const shellInProjectFolder = Boolean(shell.project && !isDefaultConversationProject(shell.project) && resolveProjectBridgeShellCwd(shell.project, shell.bridgeId));

  const issues: string[] = [];
  if (!hydrated) issues.push('Loading your favorite agents and launch selections…');
  if (preferences.isError || agentsQuery.isError || projectsQuery.isError || bridgesQuery.isError || support.isError) issues.push('Launch options could not be verified. Refresh before sending.');
  if (hydrated && (!selectedAgent || selectedAgent.state !== 'active' || !favoriteIds.includes(agentId))) issues.push('Choose an active agent from your favorites.');
  if (hydrated && (!selectedProject || selectedProject.state !== 'active')) issues.push('Selected project is unavailable or archived. Choose an active project.');
  if (hydrated && (!selectedBridge || selectedBridge.status !== 'online' || selectedBridge.runtime_connected !== true)) issues.push(bridgeIssueText('agent', bridgeClauseShown));
  if (selectedBridge?.provider_status_error) issues.push('Provider availability could not be verified on this bridge. Refresh its connection.');
  if (selectedBridge && !selectedProviders.loaded) issues.push('Checking provider availability on the selected bridge…');
  else if (selectedBridge && (!runtime.provider || !capabilities.some(c => c.provider === runtime.provider && (c.profile_id || c.provider) === (runtime.providerProfile || runtime.provider)))) issues.push('Choose a provider available on the selected bridge.');
  else if (selectedBridge && !capabilities.find(c => c.provider === runtime.provider && (c.profile_id || c.provider) === (runtime.providerProfile || runtime.provider))?.models.includes(runtime.model)) issues.push('Choose a model available for this provider on the selected bridge.');
  if (support.data?.entries?.some((row: any) => String(row.bridgeId || row.bridge_id) === runtime.bridgeId && row.enabled === false)) issues.push('This agent is disabled on the selected bridge. Choose another bridge.');
  if (!vaultUnlocked || !getActiveVaultKey()) issues.push("This device's vault keys are not installed yet.");

  // Shell mode has its own, shorter list (no agent/provider); the plan limit shows
  // the upgrade prompt instead of a line.
  const shellIssues: string[] = [];
  if (!hydrated) shellIssues.push('Loading your launch selections…');
  if (shell.blocked === 'vault') shellIssues.push("This device's vault keys are not installed yet. Shell commands are encrypted.");
  if (shell.blocked === 'bridge') shellIssues.push(bridgeIssueText('shell', bridgeClauseShown));

  const uploading = attachments.some(a => a.status === 'uploading');
  const failedUpload = attachments.some(a => a.status === 'error');
  const sending = launchState.isLoading || transitioning;
  const disabled = sending || issues.length > 0;
  const sendDisabled = disabled || pendingWrites > 0 || Boolean(preferenceError) || support.isLoading || uploading || failedUpload || (!draft.trim() && attachments.length === 0);
  const openShellDisabled = shellIssues.length > 0 || Boolean(shell.blocked) || !shell.bridgeId || shell.busy;
  useEffect(() => {
    if (launchIntent !== 'agent' || paneMode !== 'agent' || !hydrated || disabled) return;
    const frame = requestAnimationFrame(() => inputRef.current?.focus());
    return () => cancelAnimationFrame(frame);
  }, [disabled, hydrated, launchIntent, paneMode]);
  // An explicit shell shortcut focuses "Open shell" once it can be pressed.
  useEffect(() => {
    if (launchIntent !== 'shell' || paneMode !== 'shell' || openShellDisabled) return;
    const frame = requestAnimationFrame(() => openShellRef.current?.focus());
    return () => cancelAnimationFrame(frame);
  }, [launchIntent, paneMode, openShellDisabled]);

  async function upload(file: File, localId: string = crypto.randomUUID()) {
    const name = artifactUploadName(file, 'conversation-attachment');
    const tooLarge = file.size > MAX_UPLOAD_BYTES;
    setAttachments(rows => [...rows.filter(a => a.localId !== localId), { localId, file, name, status: tooLarge ? 'error' : 'uploading', error: tooLarge ? UPLOAD_TOO_LARGE_ERROR : undefined }]);
    if (tooLarge) return;
    try {
      const result = await createArtifact({ file, name, mime: artifactMimeForFile(file), kind: artifactKindForFile(file), originKind: 'conversation_chat', projectId, agentId }).unwrap();
      const id = artifactLinkFromResponse(result).replace(/^artifact:\/\//i, ''); if (!id) throw new Error('Upload did not return an artifact ID.');
      setAttachments(rows => rows.map(a => a.localId === localId ? { ...a, id, status: 'uploaded', error: undefined } : a));
    } catch (e) { setAttachments(rows => rows.map(a => a.localId === localId ? { ...a, status: 'error', error: message(e) } : a)); }
  }
  async function submit(event: FormEvent) {
    event.preventDefault(); if (sendDisabled || submitRef.current) return;
    submitRef.current = true; setError(''); setTransitioning(true);
    const composer = composerRef.current;
    if (composer) {
      const bounds = composer.getBoundingClientRect();
      const main = composer.closest('main');
      const bottom = Math.min(main?.getBoundingClientRect().bottom ?? window.innerHeight, window.visualViewport ? window.visualViewport.offsetTop + window.visualViewport.height : window.innerHeight);
      const distance = Math.max(0, bottom - 16 - bounds.bottom);
      launchAnimation.current = composer.animate([{ transform: 'translateY(0)' }, { transform: `translateY(${distance}px)` }], { duration: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : 420, easing: 'cubic-bezier(0.22, 1, 0.36, 1)', fill: 'forwards' });
    }
    try {
      const result = await launch({ agentId, projectId: projectId || undefined, bridgeId: runtime.bridgeId, provider: runtime.provider, providerProfile: runtime.providerProfile, model: runtime.model, body: draft.trim() || 'Please review the attached files.', artifactIds: attachments.map(a => a.id!).filter(Boolean) }).unwrap();
      const id = result.instance?.agent_instance_id || result.conversation?.agent_instance_id;
      if (!id) throw new Error('Launch did not return an agent instance ID.');
      await launchAnimation.current?.finished.catch(() => undefined);
      openLaunched(id);
    } catch (e) { launchAnimation.current?.cancel(); launchAnimation.current = null; setTransitioning(false); setError(message(e)); submitRef.current = false; }
  }
  function openShell() {
    if (openShellDisabled) return;
    void shell.start();
  }
  /** AgentMenu reselects the first remaining favorite itself; `false` leaves the selection alone. */
  async function changeFavorite(id: string, favorite: boolean): Promise<boolean> {
    setManagementError('');
    try { await setFavorite({ agentId: id, favorite }).unwrap(); return true; }
    catch (e) { setManagementError(message(e)); return false; }
  }
  async function addAgent(agent: NewFavoriteAgent): Promise<boolean> {
    setManagementError('');
    if (favoritesFull) { setManagementError('Remove a favorite before creating another. You can have up to 6 favorites.'); return false; }
    try {
      const created = await createAgent({ name: agent.name.trim(), templateId: agent.templateId, instructions: agent.instructions, favorite: true }).unwrap();
      await preferences.refetch();
      chooseAgent(created.agent_id);
      return true;
    } catch (e) { setManagementError(message(e)); return false; }
  }
  async function projectCreated(createdId: string) {
    await projectsQuery.refetch(); if (createdId) chooseProject(createdId); setProjectOpen(false);
  }

  const bridgeName = bridgeDisplayName(selectedBridgeRow, '');
  const profileId = runtime.providerProfile || runtime.provider;
  // With the banner up it carries the bridge problem; the quiet line would repeat it.
  const bannerCovers = (line: string) => showBanner && (line === bridgeIssueText('agent', bridgeClauseShown) || line === bridgeIssueText('shell', bridgeClauseShown));
  const statusLines = (paneMode === 'agent'
    ? (sending ? [`Creating conversation and starting on ${selectedBridge?.label || 'selected bridge'}…`] : issues)
    : shellIssues).filter(line => !bannerCovers(line));
  const alertText = paneMode === 'agent' ? error || preferenceError : shell.errorMessage || preferenceError;

  const attachmentRows = attachments.length ? <ul data-debug-id="new-convo-attachments" className="m-0 flex list-none flex-col gap-2 p-0">{attachments.map(a => (
    <li key={a.localId} className="flex flex-wrap items-center gap-2 rounded-[var(--radius-md)] border border-strong px-3 py-1">
      <Text as="span" role="body-sm" className="m-0 min-w-0 flex-1 truncate">{a.name}</Text>
      <Text as="span" role="body-sm" tone={a.status === 'error' ? 'danger' : 'muted'} className="m-0">{a.error || (a.status === 'uploading' ? 'Uploading…' : 'Uploaded')}</Text>
      {a.status === 'error' ? <Button variant="ghost" size="sm" data-debug-id={`new-convo-retry-upload-${a.localId}`} disabled={sending || disabled} onClick={() => void upload(a.file, a.localId)}>Retry</Button> : null}
      <IconButton icon="close" size="sm" label={`Remove ${a.name}`} data-debug-id={`new-convo-remove-upload-${a.localId}`} disabled={sending} onClick={() => setAttachments(rows => rows.filter(row => row.localId !== a.localId))} />
    </li>
  ))}</ul> : null;

  if (screen === 'full') {
    return <section data-debug-id="new-conversation-page" data-no-bridge="full" className="w-full px-4 sm:px-8">
      <div className="mx-auto w-full pb-8 pt-12 md:pb-16 md:pt-24">
        <NoBridgeOnline bridges={bridges} onCheckAgain={() => void bridgesQuery.refetch()} checking={bridgesQuery.isFetching} leaving={leavingNoBridge} />
      </div>
    </section>;
  }

  return <section data-debug-id="new-conversation-page" data-no-bridge={showBanner ? 'banner' : undefined} className="w-full px-4 sm:px-8 max-md:flex max-md:flex-1 max-md:flex-col">
    <div className={`mx-auto flex w-full max-w-[760px] flex-col gap-6 pb-0 pt-6 max-md:flex-1 md:pb-16 md:pt-[120px] ${swapInLauncher ? 'animate-composer-swap' : ''}`} onAnimationEnd={() => setSwapInLauncher(false)}>
      <LaunchHeadline
        mode={paneMode}
        onModeChange={setPaneMode}
        projects={projects}
        projectId={projectId}
        onProjectChange={chooseProject}
        onNewProject={() => { setManagementError(''); setProjectOpen(true); }}
        newProjectDisabled={sending || !hydrated || !vaultUnlocked}
        bridges={bridges}
        runtime={runtime}
        onRuntimeChange={chooseRuntime}
        branch={branch}
        disabled={sending || !hydrated}
        onMenuOpenChange={setHeadlineMenu}
      />
      {showBanner ? <NoBridgeBanner bridges={bridges} onCheckAgain={() => void bridgesQuery.refetch()} checking={bridgesQuery.isFetching} /> : null}
      <div ref={composerRef} data-debug-id="new-convo-launch-dock" data-docked={menuOpen ? undefined : ''} className={`relative w-full max-md:mt-auto ${menuOpen ? '' : LAUNCH_DOCK_MOBILE} ${transitioning ? 'z-20' : ''}`}>
        <LaunchComposer mode={paneMode} disabled={showBanner} onSubmit={paneMode === 'agent' ? submit : (event) => { event.preventDefault(); openShell(); }}>
          {paneMode === 'agent' ? (
            <ConversationComposerBody
              mobile={mobile}
              inputRef={inputRef}
              draft={draft}
              onDraftChange={setDraft}
              onSubmitShortcut={(event) => void submit(event)}
              onPaste={e => { const files = clipboardFilesFromEvent(e); if (files.length && !disabled) { e.preventDefault(); files.forEach(f => void upload(f)); } }}
              inputDisabled={sending}
              attachments={attachmentRows}
              onAttach={() => fileRef.current?.click()}
              attachDisabled={disabled}
              agentChip={<AgentMenu
                agents={agents}
                favoriteIds={favoriteIds}
                pinnedIds={pinnedIds}
                selectedId={agentId}
                onSelect={chooseAgent}
                onToggleFavorite={changeFavorite}
                toggling={favoriteState.isLoading}
                templates={templatesQuery.data?.templates || []}
                onCreateAgent={addAgent}
                creating={createAgentState.isLoading}
                error={managementError}
                disabled={!hydrated || sending}
                onOpenChange={setAgentMenuOpen}
              />}
              runtimeChip={<RuntimeMenu
                capabilities={capabilities}
                bridgeLabel={bridgeName}
                selection={runtime}
                onChange={chooseRuntime}
                disabled={sending}
                open={runtimeMenuOpen}
                onOpenChange={setRuntimeMenuOpen}
                modelFooter={runtime.bridgeId ? <ModelCatalogRefresh key={runtime.bridgeId} bridgeId={runtime.bridgeId} provider={runtime.provider} profileId={profileId} online={Boolean(selectedBridge && String(selectedBridge.status).toLowerCase() === 'online')} disabled={sending} debugPrefix="new-convo" /> : undefined}
              />}
              sendDisabled={sendDisabled}
            />
          ) : (
            <ShellComposerBody
              mobile={mobile}
              command={shell.command}
              onCommandChange={shell.setCommand}
              inputDisabled={shell.busy}
              inProjectFolder={shellInProjectFolder}
              bridgeName={bridgeDisplayName(shell.bridge, '')}
              onOpen={openShell}
              openDisabled={openShellDisabled}
              busy={shell.busy}
              openRef={openShellRef}
            />
          )}
        </LaunchComposer>
        <input ref={fileRef} data-debug-id="new-convo-upload-input" type="file" multiple className="hidden" onChange={e => { if (!disabled) Array.from(e.target.files || []).forEach(f => void upload(f)); e.target.value = ''; }} />
      </div>
      <div data-debug-id="new-convo-launch-status" className={`-mt-3 flex flex-col gap-2 ${transitioning ? 'pointer-events-none opacity-0' : ''}`}>
        {paneMode === 'shell' && shell.upgradeDetails ? <UpgradePrompt details={shell.upgradeDetails} debugId="shell-launch-upgrade" subtle /> : null}
        <div role="status" data-debug-id="new-convo-launch-issues" className="flex flex-col gap-1 empty:hidden">
          {statusLines.map(line => <Text key={line} role="body-sm" tone="muted" className="m-0">{line}</Text>)}
        </div>
        {alertText ? <div role="alert" data-debug-id="new-convo-launch-error" className="flex flex-wrap items-center gap-2">
          <Text as="span" role="body-sm" tone="danger" className="m-0">{alertText}</Text>
          {preferenceError ? <Button size="sm" tone="danger" className="max-md:min-h-11" data-debug-id="new-convo-retry-preferences-btn" disabled={pendingWrites > 0} onClick={() => { for (const field of Object.keys(preferenceFailures) as ('agent_id' | 'project_id' | 'bridge_id')[]) remember(field, latestSelections.current[field] || ''); }}>Retry saving selections</Button> : null}
        </div> : null}
      </div>
      {/* Only with a footer: an empty one would still take a gap under the docked composer. */}
      {footer ? <div data-debug-id="new-convo-footer" className={`flex items-center justify-center ${transitioning ? 'pointer-events-none opacity-0' : ''} transition-opacity duration-base`}>{footer}</div> : null}
    </div>
    <NewProjectModal
      open={projectOpen}
      onOpenChange={setProjectOpen}
      bridgeId={runtime.bridgeId}
      bridgeLabel={bridgeName || undefined}
      bridgeUsable={chosenOnline}
      onCreated={projectCreated}
    />
  </section>;
}
