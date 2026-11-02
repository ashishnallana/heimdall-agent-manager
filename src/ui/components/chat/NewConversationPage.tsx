import { useEffect, useMemo, useRef, useState, type FormEvent, type ReactNode } from 'react';
import { useSelector } from 'react-redux';
import { Combobox, Icon, Modal } from '@ui';
import { useCreateAgentMutation, useListAgentIdentitiesQuery, useListAgentTemplatesQuery } from '../../api/endpoints/agents';
import { useListBridgesQuery, useListAgentBridgeSupportQuery, useBridgeProviderStatus } from '../../api/endpoints/bridgeSupport';
import { useCreateLaunchConversationMutation } from '../../api/endpoints/chats';
import { useCreateProjectMutation, useListProjectsQuery } from '../../api/endpoints/projects';
import { useCreateArtifactMutation } from '../../api/endpoints/artifacts';
import { useGetConversationLaunchPreferencesQuery, useSaveConversationLaunchSelectionMutation, useSetAgentFavoriteMutation } from '../../api/endpoints/conversationLaunch';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { buildRouteHash, getRouteSearch, getRoutePathname } from '../../utils/appLocation';
import { apiErrorText } from '../../api/cookieFetch';
import { artifactKindForFile, artifactLinkFromResponse, artifactMimeForFile, artifactUploadName, clipboardFilesFromEvent } from '../../utils/artifactUpload';
import { isVaultArmored, getActiveVaultKey } from '../../utils/vaultContent';
import { MAX_UPLOAD_BYTES } from '../ArtifactUpload';
import { useIsMobile } from '../shell/responsive';
import { useAuthUser } from '../auth/AuthUserContext';
import { VaultText } from '../vault/VaultText';
import { MessageComposerInput, MessageComposerActions } from './MessageComposer';
import RuntimeConfigurationOptions, { type RuntimeSelection } from './RuntimeConfigurationOptions';
import ShellLaunchPanel from './ShellLaunchPanel';
import { selectMainAgentIds, type LauncherIntent } from '../../store/workspaceLayoutSlice';

type Attachment = { localId: string; id?: string; file: File; name: string; status: 'uploading' | 'uploaded' | 'error'; error?: string };
function message(e: any) { return String(e?.error || e?.message || apiErrorText(e)); }
const label = (name: string, fallback: string) => isVaultArmored(name) ? 'Locked name' : name || fallback;
const workflowLabel = (agent: any) => agent?.slug === 'coordinator' ? 'Multi-agent workflow' : agent?.slug === 'soloist' ? 'Single-agent workflow' : '';

const GREETINGS = [
  { text: 'Hello', lang: 'en' }, { text: 'Hey', lang: 'en' },
  { text: 'Hola', lang: 'es' }, { text: 'Bonjour', lang: 'fr' },
  { text: 'Ciao', lang: 'it' }, { text: 'Namaste', lang: 'hi' },
  { text: 'こんにちは', lang: 'ja' }, { text: '안녕하세요', lang: 'ko' },
  { text: 'Olá', lang: 'pt' }, { text: 'Hallo', lang: 'de' },
];
/**
 * `onLaunched`: called with the new agent instance id instead of navigating to
 * it (a Main new-chat pane puts the new conversation into THAT pane).
 */
const PANE_MODE_STORAGE_KEY = 'heimdall:new-pane-mode';

function PaneModeSwitch({ value, onChange, mobile }: { value: 'agent' | 'shell'; onChange: (v: 'agent' | 'shell') => void; mobile: boolean }) {
  const option = (v: 'agent' | 'shell', icon: 'bot' | 'terminal', text: string) => (
    <button
      type="button"
      role="tab"
      data-debug-id={`new-convo-mode-${v}`}
      aria-selected={value === v}
      onClick={() => onChange(v)}
      className={`inline-flex flex-1 items-center justify-center gap-2 rounded-xl font-semibold transition-colors ${mobile ? 'min-h-11 text-[15px]' : 'min-h-9 text-sm'} ${value === v ? 'bg-surface-raised text-primary shadow-sm' : 'text-muted hover:text-primary'}`}
    >
      <Icon name={icon} size={mobile ? 18 : 16} />{text}
    </button>
  );
  return (
    <div role="tablist" aria-label="Open in this pane" data-debug-id="new-convo-mode-switch" className={`mb-6 flex rounded-2xl border border-subtle bg-surface p-1 ${mobile ? 'w-full' : 'w-72'}`}>
      {option('agent', 'bot', 'Agent')}
      {option('shell', 'terminal', 'Shell')}
    </div>
  );
}

export interface NewConversationPageProps {
  embedded?: boolean;
  footer?: ReactNode;
  onLaunched?: (agentInstanceId: string) => void;
  /** Explicit shortcut intent. It selects the initial mode without rewriting the saved preference. */
  launchIntent?: LauncherIntent;
}

export default function NewConversationPage({ footer, onLaunched, launchIntent }: NewConversationPageProps) {
  const user = useAuthUser();
  const userName = String(user?.display_name || user?.name || '').trim();
  const [greeting] = useState(() => GREETINGS[Math.floor(Math.random() * GREETINGS.length)]);
  const mobile = useIsMobile();
  // SH-1: the picker opens an agent conversation OR an interactive shell. The
  // choice is a per-browser convenience, so it lives in localStorage.
  const [paneMode, setPaneModeState] = useState<'agent' | 'shell'>(() => {
    if (launchIntent) return launchIntent;
    try { return localStorage.getItem(PANE_MODE_STORAGE_KEY) === 'shell' ? 'shell' : 'agent'; } catch { return 'agent'; }
  });
  useEffect(() => {
    if (launchIntent) setPaneModeState(launchIntent);
  }, [launchIntent]);
  const setPaneMode = (next: 'agent' | 'shell') => {
    setPaneModeState(next);
    try { localStorage.setItem(PANE_MODE_STORAGE_KEY, next); } catch { /* storage unavailable */ }
  };
  const openPaneIds = useSelector(selectMainAgentIds);
  const preferences = useGetConversationLaunchPreferencesQuery();
  const agentsQuery = useListAgentIdentitiesQuery({ limit: 200 });
  const projectsQuery = useListProjectsQuery();
  const bridgesQuery = useListBridgesQuery(undefined, { refetchOnMountOrArgChange: true });
  const templatesQuery = useListAgentTemplatesQuery();
  const [saveSelection] = useSaveConversationLaunchSelectionMutation();
  const [setFavorite, favoriteState] = useSetAgentFavoriteMutation();
  const [createAgent, createAgentState] = useCreateAgentMutation();
  const [createProject, createProjectState] = useCreateProjectMutation();
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
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [favoritesOpen, setFavoritesOpen] = useState(false);
  const [projectOpen, setProjectOpen] = useState(false);
  const [favoriteSearch, setFavoriteSearch] = useState('');
  const [agentName, setAgentName] = useState('');
  const [agentTemplate, setAgentTemplate] = useState('tmpl_worker');
  const [agentInstructions, setAgentInstructions] = useState('');
  const [projectName, setProjectName] = useState('');
  const [projectDescription, setProjectDescription] = useState('');
  const [managementError, setManagementError] = useState('');
  const [transitioning, setTransitioning] = useState(false);
  const composerRef = useRef<HTMLDivElement>(null);
  const launchAnimation = useRef<Animation | null>(null);
  useEffect(() => () => launchAnimation.current?.cancel(), []);
  const inputRef = useRef<HTMLTextAreaElement>(null);
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
  const favoriteIds = [...(preferences.data?.favorite_agent_ids || [])].sort((a, b) => { const rank = (id: string) => { const slug = agents.find(agent => agent.agent_id === id)?.slug; return slug === 'soloist' ? 0 : slug === 'coordinator' ? 1 : 2; }; return rank(a) - rank(b); });
  const pinnedIds = preferences.data?.pinned_agent_ids || [];
  const favoritesFull = favoriteIds.length >= 6;
  const support = useListAgentBridgeSupportQuery({ agentId }, { skip: !agentId });
  const selectedAgent = agents.find(a => a.agent_id === agentId);
  const selectedProject = projects.find((p: any) => p.project_id === projectId);
  const selectedBridgeRow = useMemo(() => bridges.find((b: any) => b.bridge_id === runtime.bridgeId), [bridges, runtime.bridgeId]);
  // Provider status for the selected bridge only (not every bridge).
  const selectedProviders = useBridgeProviderStatus(selectedBridgeRow);
  const selectedBridge = selectedProviders.bridge;
  const capabilities = selectedProviders.capabilities;

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

  const issues: string[] = [];
  if (!hydrated) issues.push('Loading your favorite agents and launch selections…');
  if (preferences.isError || agentsQuery.isError || projectsQuery.isError || bridgesQuery.isError || support.isError) issues.push('Launch options could not be verified. Refresh before sending.');
  if (hydrated && (!selectedAgent || selectedAgent.state !== 'active' || !favoriteIds.includes(agentId))) issues.push('Choose an active agent from your favorites.');
  if (hydrated && (!selectedProject || selectedProject.state !== 'active')) issues.push('Selected project is unavailable or archived. Choose an active project.');
  if (hydrated && (!selectedBridge || selectedBridge.status !== 'online' || selectedBridge.runtime_connected !== true)) issues.push('Choose a connected bridge in Agent settings.');
  if (selectedBridge?.provider_status_error) issues.push('Provider availability could not be verified on this bridge. Refresh its connection.');
  if (selectedBridge && !selectedProviders.loaded) issues.push('Checking provider availability on the selected bridge…');
  else if (selectedBridge && (!runtime.provider || !capabilities.some(c => c.provider === runtime.provider && (c.profile_id || c.provider) === (runtime.providerProfile || runtime.provider)))) issues.push('Choose a provider available on the selected bridge.');
  else if (selectedBridge && !capabilities.find(c => c.provider === runtime.provider && (c.profile_id || c.provider) === (runtime.providerProfile || runtime.provider))?.models.includes(runtime.model)) issues.push('Choose a model available for this provider on the selected bridge.');
  if (support.data?.entries?.some((row: any) => String(row.bridgeId || row.bridge_id) === runtime.bridgeId && row.enabled === false)) issues.push('This agent is disabled on the selected bridge. Choose another bridge.');
  if (!vaultUnlocked || !getActiveVaultKey()) issues.push("This device's vault keys are not installed yet.");
  const uploading = attachments.some(a => a.status === 'uploading');
  const failedUpload = attachments.some(a => a.status === 'error');
  const sending = launchState.isLoading || transitioning;
  const disabled = sending || issues.length > 0;
  const sendDisabled = disabled || pendingWrites > 0 || Boolean(preferenceError) || support.isLoading || uploading || failedUpload || (!draft.trim() && attachments.length === 0);
  useEffect(() => {
    if (launchIntent !== 'agent' || paneMode !== 'agent' || !hydrated || disabled) return;
    const frame = requestAnimationFrame(() => inputRef.current?.focus());
    return () => cancelAnimationFrame(frame);
  }, [disabled, hydrated, launchIntent, paneMode]);

  async function upload(file: File, localId: string = crypto.randomUUID()) {
    const name = artifactUploadName(file, 'conversation-attachment');
    const tooLarge = file.size > MAX_UPLOAD_BYTES;
    setAttachments(rows => [...rows.filter(a => a.localId !== localId), { localId, file, name, status: tooLarge ? 'error' : 'uploading', error: tooLarge ? 'File exceeds the upload size limit.' : undefined }]);
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
      if (onLaunched) onLaunched(id);
      else window.location.hash = buildRouteHash(`/conversations/${encodeURIComponent(id)}`, '');
    } catch (e) { launchAnimation.current?.cancel(); launchAnimation.current = null; setTransitioning(false); setError(message(e)); submitRef.current = false; }
  }
  async function changeFavorite(id: string, favorite: boolean) {
    setManagementError('');
    try { await setFavorite({ agentId: id, favorite }).unwrap(); if (!favorite && agentId === id) { setAgentId(''); } }
    catch (e) { setManagementError(message(e)); }
  }
  async function addAgent(event: FormEvent) {
    event.preventDefault(); setManagementError('');
    if (favoritesFull) { setManagementError('Remove a favorite before creating another. You can have up to 6 favorites.'); return; }
    try {
      const created = await createAgent({ name: agentName.trim(), templateId: agentTemplate, instructions: agentInstructions, favorite: true }).unwrap();
      await preferences.refetch(); setAgentName(''); setAgentInstructions('');
      chooseAgent(created.agent_id); setFavoritesOpen(false);
    } catch (e) { setManagementError(message(e)); }
  }
  async function addProject(event: FormEvent) {
    event.preventDefault(); setManagementError('');
    try {
      const created = await createProject({ name: projectName.trim(), description: projectDescription }).unwrap();
      await projectsQuery.refetch(); chooseProject(created.project_id); setProjectOpen(false); setProjectName(''); setProjectDescription('');
    } catch (e) { setManagementError(message(e)); }
  }
  const actionProps = { debugPrefix: 'new-convo', mobile, provider: runtime.provider, model: runtime.model, onSettings: () => setSettingsOpen(true), onUpload: () => fileRef.current?.click(), uploadDisabled: disabled, sendDisabled };
  const input = <MessageComposerInput ref={inputRef} mobile={mobile} debugId="new-convo-composer-input" value={draft} disabled={sending} placeholder={mobile ? 'Message the agent…' : 'Message the agent… (Cmd/Ctrl+Enter to send)'} onChange={e => setDraft(e.target.value)} onKeyDown={e => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); void submit(e); } }} onPaste={e => { const files = clipboardFilesFromEvent(e); if (files.length && !disabled) { e.preventDefault(); files.forEach(f => void upload(f)); } }} />;
  return <section data-debug-id="new-conversation-page" className="w-full px-3 sm:px-6">
    <div className="mx-auto grid h-[calc(var(--app-viewport-height)-4rem)] min-h-min w-full max-w-4xl grid-cols-[minmax(0,1fr)] grid-rows-[minmax(min-content,1fr)_auto_minmax(min-content,1fr)] gap-8 py-6">
      <div data-debug-id="new-convo-introduction" className="flex items-center justify-center"><div className="w-full">
      <h1 data-debug-id="new-convo-greeting" className="mb-2 text-left text-2xl font-semibold text-primary"><span lang={greeting.lang}>{greeting.text}</span>{userName ? `, ${userName}` : ''}</h1>
      <p data-debug-id="new-convo-subtitle" className="mb-5 text-left text-sm text-muted">{paneMode === 'shell' ? 'Open a terminal in this pane' : 'Start a conversation'}</p>
      <PaneModeSwitch value={paneMode} onChange={setPaneMode} mobile={mobile} />
      {paneMode === 'agent' ? (<>
      <div className="mb-2 flex items-center justify-between gap-3">
        <span data-debug-id="new-convo-favorite-count" className="text-xs text-muted">{favoriteIds.length} / 6 favorites</span>
        <button type="button" data-debug-id="new-convo-edit-favorites-btn" disabled={!hydrated || sending} onClick={() => { setManagementError(''); setFavoritesOpen(true); }} aria-label="Manage favorite agents" title="Manage favorite agents" className="grid h-10 w-10 place-items-center rounded-xl text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-40"><Icon name="pencil" size={19} /></button>
      </div>
      <div data-debug-id="new-convo-favorite-agents" className="grid grid-cols-3 gap-2 sm:gap-3">{Array.from({ length: favoriteIds.length >= 4 ? 6 : 3 }, (_, index) => {
        const id = favoriteIds[index];
        if (!id) return <button key={`empty-${index}`} type="button" data-debug-id={`new-convo-empty-favorite-${index}`} aria-label="Choose a favorite agent" disabled={!hydrated || sending} onClick={() => { setManagementError(''); setFavoritesOpen(true); }} className="flex min-h-20 min-w-0 flex-col items-center justify-center gap-2 rounded-2xl border border-dashed border-subtle px-2 py-3 text-xs text-muted hover:bg-neutral-soft disabled:opacity-40"><Icon name="star" size={20} /><span>Choose agent</span></button>;
        const agent = agents.find(a => a.agent_id === id); const selected = id === agentId;
        return <button key={id} type="button" data-debug-id={`new-convo-favorite-agent-${id}`} aria-pressed={selected} disabled={!hydrated || sending || !agent || agent.state !== 'active'} onClick={() => chooseAgent(id)} className={`relative flex min-h-20 min-w-0 flex-col items-start justify-center gap-2 rounded-2xl border px-2 py-3 text-left sm:flex-row sm:items-center sm:gap-3 sm:px-4 ${selected ? 'border-accent bg-accent/10' : 'border-subtle bg-surface hover:bg-neutral-soft'} disabled:opacity-50`}>
          <Icon name={agent?.slug === 'coordinator' ? 'tasks' : 'bot'} size={20} className={selected ? 'text-accent' : 'text-muted'} />
          <span className="min-w-0 w-full sm:flex-1"><span className="block truncate text-xs font-medium text-primary sm:text-base"><VaultText value={agent?.name === 'coordinator' ? 'Coordinator' : agent?.name === 'soloist' ? 'Soloist' : agent?.name || id} fallback="Agent" /></span>{workflowLabel(agent) ? <span className="block text-[11px] text-muted sm:text-xs">{workflowLabel(agent)}</span> : null}{agent?.state !== 'active' ? <span className="text-xs text-muted">Unavailable</span> : null}</span>
          {selected ? <Icon name="check" size={14} className="absolute right-2 top-2 text-accent" /> : null}
        </button>;
      })}</div>
      </>) : null}
      </div></div>
      {paneMode === 'shell' ? (
        <ShellLaunchPanel
          projects={projects}
          bridges={bridges}
          projectId={projectId}
          onProjectChange={chooseProject}
          initialBridgeId={runtime.bridgeId}
          openIds={openPaneIds}
          isMobile={mobile}
          disabled={!hydrated}
          autoFocusStart={launchIntent === 'shell'}
          onOpenShell={(sessionId) => {
            if (onLaunched) onLaunched(sessionId);
            else window.location.hash = buildRouteHash(`/conversations/${encodeURIComponent(sessionId)}`, '');
          }}
        />
      ) : (
      <div ref={composerRef} data-debug-id="new-convo-launch-dock" className={`relative w-full ${transitioning ? 'z-20' : ''}`}>
      <div className="flex flex-wrap items-center justify-between gap-2 rounded-t-2xl border border-b-0 border-subtle bg-surface px-4 py-2 sm:max-w-lg">
        <div className="min-w-0 flex-1"><Combobox debugId="new-convo-project-select" options={[...projects.filter((p: any) => p.state === 'active').map((p: any) => ({ value: p.project_id, title: label(p.name, 'Project') }))]} value={projectId} onChange={chooseProject} placeholder="Choose project" searchPlaceholder="Search projects…" disabled={sending || !hydrated} width="full" /></div>
        <button type="button" data-debug-id="new-convo-new-project-btn" disabled={sending || !hydrated || !vaultUnlocked} onClick={() => { setManagementError(''); setProjectOpen(true); }} className="inline-flex min-h-10 items-center gap-1.5 rounded-xl px-2 text-sm text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-40"><Icon name="plus" size={15} />New Project</button>
      </div>
      <form onSubmit={submit} data-debug-id="new-convo-composer-shell" className="rounded-b-2xl border border-subtle bg-surface px-3 py-3 focus-within:border-accent sm:rounded-tr-2xl sm:px-4">
        <button type="button" data-debug-id="new-convo-composer-bridge-btn" aria-haspopup="dialog" aria-expanded={settingsOpen} aria-label="Change bridge, provider or model" disabled={sending} onClick={() => setSettingsOpen(true)} className="mb-2 inline-flex max-w-full items-center gap-1.5 rounded-lg px-1 py-1 text-xs text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-40"><Icon name="device" size={13} /><span className="truncate">{selectedBridge?.label || selectedBridge?.machine_hostname || 'Choose bridge'}</span><Icon name="chevron-down" size={12} /></button>
        {issues.length ? <div role="status" data-debug-id="new-convo-launch-issues" className="mb-3 rounded-xl bg-neutral-soft px-3 py-2 text-xs text-muted">{issues.map(issue => <p key={issue}>{issue}</p>)}</div> : null}
        {error || preferenceError ? <div role="alert" data-debug-id="new-convo-launch-error" className="mb-3 text-sm text-danger">{error || preferenceError}{preferenceError ? <button type="button" data-debug-id="new-convo-retry-preferences-btn" disabled={pendingWrites > 0} onClick={() => { for (const field of Object.keys(preferenceFailures) as ('agent_id' | 'project_id' | 'bridge_id')[]) remember(field, latestSelections.current[field] || ''); }} className="ml-2 rounded-lg border border-danger/30 px-2 py-1 text-xs disabled:opacity-40">Retry saving selections</button> : null}</div> : null}
        {attachments.length ? <div className="mb-3 space-y-2">{attachments.map(a => <div key={a.localId} className="flex flex-wrap items-center gap-2 rounded-xl border border-subtle px-3 py-2 text-xs"><span className="min-w-0 flex-1 truncate text-primary">{a.name}</span><span className={a.status === 'error' ? 'text-danger' : 'text-muted'}>{a.error || (a.status === 'uploading' ? 'Uploading…' : 'Uploaded')}</span>{a.status === 'error' ? <button type="button" data-debug-id={`new-convo-retry-upload-${a.localId}`} disabled={sending || disabled} onClick={() => void upload(a.file, a.localId)} className="text-accent">Retry</button> : null}<button type="button" data-debug-id={`new-convo-remove-upload-${a.localId}`} disabled={sending} aria-label={`Remove ${a.name}`} onClick={() => setAttachments(rows => rows.filter(row => row.localId !== a.localId))} className="text-muted"><Icon name="close" size={15} /></button></div>)}</div> : null}
        <input ref={fileRef} data-debug-id="new-convo-upload-input" type="file" multiple className="hidden" onChange={e => { if (!disabled) Array.from(e.target.files || []).forEach(f => void upload(f)); e.target.value = ''; }} />
        {mobile ? <div className="pl-1 pt-1.5">{input}</div> : input}<MessageComposerActions {...actionProps} />
        {sending ? <p role="status" className="absolute -top-6 left-0 text-xs text-muted">Creating conversation and starting on {selectedBridge?.label || 'selected bridge'}…</p> : null}
      </form>
      </div>
      )}
      <div data-debug-id="new-convo-footer" className={`flex items-center justify-center ${transitioning ? 'pointer-events-none opacity-0' : ''} transition-opacity duration-200`}>{footer}</div>
    </div>
    <Modal open={settingsOpen} onOpenChange={setSettingsOpen} title="Agent settings" size="lg" data-debug-id="new-convo-runtime-modal"><Modal.Body><RuntimeConfigurationOptions bridges={bridges} selection={runtime} onChange={chooseRuntime} disabled={sending} debugPrefix="new-convo" /><p className="mt-4 text-xs text-muted">The agent starts when you send your first message.</p></Modal.Body></Modal>
    <Modal open={favoritesOpen} onOpenChange={setFavoritesOpen} title="Favorite agents" size="lg" data-debug-id="new-convo-favorites-modal"><Modal.Body>
      <p data-debug-id="new-convo-favorite-limit" className="mb-3 text-xs text-muted">{favoriteIds.length} / 6 favorites. Coordinator and Soloist occupy two permanent slots.{favoritesFull ? ' Remove a favorite to add another.' : ''}</p>
      {managementError ? <p role="alert" className="mb-3 text-sm text-danger">{managementError}</p> : null}
      <input data-debug-id="new-convo-favorite-search-input" value={favoriteSearch} onChange={e => setFavoriteSearch(e.target.value)} placeholder="Search existing agents…" className="mb-3 min-h-11 w-full rounded-xl border border-subtle bg-surface px-3 text-base text-primary sm:text-sm" />
      <div className="max-h-64 space-y-2 overflow-auto">{agents.filter(a => (a.state === 'active' || favoriteIds.includes(a.agent_id)) && label(a.name, a.agent_id).toLowerCase().includes(favoriteSearch.toLowerCase())).map(a => {
        const favorite = favoriteIds.includes(a.agent_id); const pinned = pinnedIds.includes(a.agent_id);
        return <div key={a.agent_id} className="flex items-center justify-between gap-3 rounded-xl border border-subtle px-3 py-2"><span className="min-w-0"><span className="block truncate text-sm text-primary"><VaultText value={a.name} fallback="Agent" /></span>{workflowLabel(a) ? <span className="block text-xs text-muted">{workflowLabel(a)}</span> : null}</span><button type="button" data-debug-id={`new-convo-favorite-toggle-${a.agent_id}`} aria-label={pinned ? 'Permanent favorite' : favorite ? 'Remove favorite' : 'Add favorite'} title={pinned ? 'Permanent favorite — cannot be removed' : favorite ? 'Remove favorite' : 'Add favorite'} aria-pressed={favorite} disabled={pinned || favoriteState.isLoading || (!favorite && favoritesFull)} onClick={() => void changeFavorite(a.agent_id, !favorite)} className={`grid h-11 w-11 shrink-0 place-items-center rounded-xl hover:bg-neutral-soft disabled:cursor-default ${favorite ? 'text-accent' : 'text-muted'} ${favoriteState.isLoading ? 'opacity-40' : ''}`}><Icon name={favorite ? 'star-filled' : 'star'} size={20} /></button></div>;
      })}</div>
      <form onSubmit={addAgent} className="mt-5 space-y-3 border-t border-subtle pt-4"><h3 className="font-medium text-primary">Create a favorite agent</h3><input data-debug-id="new-convo-agent-name-input" value={agentName} onChange={e => setAgentName(e.target.value)} placeholder="Agent name" required className="min-h-11 w-full rounded-xl border border-subtle bg-surface px-3 text-base text-primary sm:text-sm" /><Combobox debugId="new-convo-agent-template-select" options={(templatesQuery.data?.templates || []).map((t: any) => ({ value: t.template_id, title: label(t.name, t.template_id) }))} value={agentTemplate} onChange={setAgentTemplate} placeholder="Choose template" width="full" /><textarea data-debug-id="new-convo-agent-instructions-input" value={agentInstructions} onChange={e => setAgentInstructions(e.target.value)} placeholder="Additional instructions (optional)" rows={3} className="w-full rounded-xl border border-subtle bg-surface p-3 text-base text-primary sm:text-sm" /><button type="submit" data-debug-id="new-convo-create-favorite-agent-btn" disabled={favoritesFull || createAgentState.isLoading || !agentName.trim() || !agentTemplate} className="min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-accent-fg disabled:opacity-40">{createAgentState.isLoading ? 'Creating…' : 'Create and favorite'}</button></form>
    </Modal.Body></Modal>
    <Modal open={projectOpen} onOpenChange={setProjectOpen} title="New project" size="md" data-debug-id="new-convo-project-modal"><Modal.Body><form onSubmit={addProject} className="space-y-3">{managementError ? <p role="alert" className="text-sm text-danger">{managementError}</p> : null}<input data-debug-id="new-convo-project-name-input" value={projectName} onChange={e => setProjectName(e.target.value)} placeholder="Project name" required className="min-h-11 w-full rounded-xl border border-subtle bg-surface px-3 text-base text-primary sm:text-sm" /><textarea data-debug-id="new-convo-project-description-input" value={projectDescription} onChange={e => setProjectDescription(e.target.value)} placeholder="Description (optional)" rows={3} className="w-full rounded-xl border border-subtle bg-surface p-3 text-base text-primary sm:text-sm" /><button type="submit" data-debug-id="new-convo-create-project-btn" disabled={createProjectState.isLoading || !projectName.trim()} className="min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-accent-fg disabled:opacity-40">{createProjectState.isLoading ? 'Creating…' : 'Create project'}</button></form></Modal.Body></Modal>
  </section>;
}
