import React, { useMemo, useState } from 'react';
import { useSelector } from 'react-redux';
import { Badge, Button, Icon, Input, Modal } from '@ui';
import {
  useListSidebarConversationsQuery,
  type SidebarConversation,
} from '../../api/endpoints/sidebar';
import {
  useGetAgentsLiveQuery,
  type LiveProject,
} from '../../api/endpoints/agentsLive';
import { useFetchTaskChainGroupsQuery } from '../../api/endpoints/tasks';
import { useCreateLaunchConversationMutation } from '../../api/endpoints/chats';
import { buildRouteHash } from '../../utils/appLocation';
import { isVaultArmored } from '../../utils/vaultContent';

export interface SelectedWindowConversation {
  agentInstanceId: string;
  chainId?: string | null;
  projectId?: string | null;
  focusMessageId?: string;
  title?: string;
}

export interface NewConversationModalProps {
  open: boolean;
  onClose: () => void;
  onCreated: (selection: SelectedWindowConversation) => void;
}

export function NewConversationModal({
  open,
  onClose,
  onCreated,
}: NewConversationModalProps) {
  const hasApiStore = useSelector((state: any) => Boolean(state?.heimdallApi));
  const [agentId, setAgentId] = useState('default');
  const [projectId, setProjectId] = useState('');
  const [prompt, setPrompt] = useState('');
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [createLaunchConversation, { isLoading }] = hasApiStore
    ? useCreateLaunchConversationMutation()
    : ([
        async () => ({
          unwrap: async () => ({ conversation: { agent_instance_id: '' } }),
        }),
        { isLoading: false },
      ] as any);

  const handleSubmit = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!prompt.trim()) {
      setErrorMessage('Enter an initial prompt to start a new conversation.');
      return;
    }
    setErrorMessage(null);
    try {
      const response = await createLaunchConversation({
        agentId: agentId.trim() || 'default',
        projectId: projectId.trim() || undefined,
        body: prompt.trim(),
      }).unwrap();

      const conv = response?.conversation || response || {};
      const inst = response?.instance || {};
      const resolvedAgentId = String(
        conv.agent_instance_id ||
          conv.agentInstanceId ||
          inst.agent_instance_id ||
          inst.agentInstanceId ||
          conv.conversation_id ||
          conv.conversationId ||
          '',
      ).trim();

      if (resolvedAgentId) {
        onCreated({
          agentInstanceId: resolvedAgentId,
          projectId:
            String(conv.project_id || conv.projectId || projectId || '').trim() ||
            null,
          title: String(conv.title || prompt.trim().slice(0, 60)),
        });
        onClose();
      } else {
        setErrorMessage('Conversation launched, but no agent instance ID was returned.');
      }
    } catch (err) {
      setErrorMessage(
        err instanceof Error ? err.message : 'Failed to launch conversation.',
      );
    }
  };

  return (
    <Modal
      open={open}
      onOpenChange={(nextOpen) => {
        if (!nextOpen) onClose();
      }}
      title="Start New Conversation in Split Pane"
      size="md"
    >
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div>
            <label className="mb-1 block text-xs font-medium text-muted">
              Agent Identity
            </label>
            <Input
              value={agentId}
              onChange={(value) => setAgentId(value)}
              placeholder="default"
            />
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-muted">
              Project ID (optional)
            </label>
            <Input
              value={projectId}
              onChange={(value) => setProjectId(value)}
              placeholder="default-conversations"
            />
          </div>
        </div>
        <div>
          <label className="mb-1 block text-xs font-medium text-muted">
            Initial Prompt
          </label>
          <textarea
            value={prompt}
            onChange={(e) => setPrompt(e.target.value)}
            rows={4}
            placeholder="Describe what the agent should work on..."
            className="w-full rounded-md border border-subtle bg-canvas px-3 py-2 text-xs text-primary placeholder:text-muted focus:border-accent focus:outline-none"
          />
        </div>
        {errorMessage ? (
          <div className="rounded border border-danger/40 bg-danger-soft px-3 py-2 text-xs text-danger">
            {errorMessage}
          </div>
        ) : null}
        <div className="flex items-center justify-between gap-2 pt-2">
          <a
            href={buildRouteHash('/conversations/new', '')}
            className="inline-flex items-center gap-1 text-xs text-accent hover:underline"
          >
            <span>Open full launcher page</span>
          </a>
          <div className="flex items-center gap-2">
            <Button type="button" variant="ghost" size="sm" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" variant="primary" size="sm" disabled={isLoading}>
              {isLoading ? 'Starting...' : 'Start in Pane'}
            </Button>
          </div>
        </div>
      </form>
    </Modal>
  );
}

export interface NewConversationWindowPaneProps {
  paneId: string;
  openConversationIds?: string[];
  onSelect?: (selection: SelectedWindowConversation) => void;
}

interface CandidateConversationItem {
  key: string;
  agentInstanceId: string;
  chainId?: string | null;
  projectId?: string | null;
  title: string;
  subtitle: string;
  badge: 'Conversation' | 'Task Chain' | 'Live Agent';
  status?: string;
  updatedAt?: string | null;
}

interface NewConversationWindowPaneBodyProps extends NewConversationWindowPaneProps {
  sidebarItems?: SidebarConversation[];
  liveProjects?: LiveProject[];
  chainGroups?: any[];
  isLoading?: boolean;
}

function NewConversationWindowPaneWithApi(props: NewConversationWindowPaneProps) {
  const { data: sidebarItems, isLoading: isLoadingSidebar } =
    useListSidebarConversationsQuery({ limit: 100 });
  const { data: liveProjects, isLoading: isLoadingAgents } =
    useGetAgentsLiveQuery();
  const { data: chainsData, isLoading: isLoadingChains } =
    useFetchTaskChainGroupsQuery({ limit: 50 } as any);

  return (
    <NewConversationWindowPaneBody
      {...props}
      sidebarItems={sidebarItems}
      liveProjects={liveProjects}
      chainGroups={(chainsData as any)?.groups ?? (chainsData as any)?.chains ?? []}
      isLoading={isLoadingSidebar || isLoadingAgents || isLoadingChains}
    />
  );
}

export function NewConversationWindowPane(props: NewConversationWindowPaneProps) {
  const hasApiStore = useSelector((state: any) => Boolean(state?.heimdallApi));
  if (hasApiStore) {
    return <NewConversationWindowPaneWithApi {...props} />;
  }
  return <NewConversationWindowPaneBody {...props} />;
}

function safeSearchableText(text: string | undefined | null): string {
  const str = String(text || '').trim();
  if (!str || isVaultArmored(str)) return '';
  return str;
}

function NewConversationWindowPaneBody({
  paneId,
  openConversationIds = [],
  onSelect,
  sidebarItems = [],
  liveProjects = [],
  chainGroups = [],
  isLoading = false,
}: NewConversationWindowPaneBodyProps) {
  const [search, setSearch] = useState('');
  const [categoryFilter, setCategoryFilter] = useState<
    'all' | 'Conversation' | 'Task Chain' | 'Live Agent'
  >('all');
  const [isLaunchModalOpen, setIsLaunchModalOpen] = useState(false);

  const openSet = useMemo(() => new Set(openConversationIds), [openConversationIds]);

  const candidates = useMemo<CandidateConversationItem[]>(() => {
    const seenAgentIds = new Set<string>();
    const list: CandidateConversationItem[] = [];

    for (const item of sidebarItems) {
      const agentId = (item.agentInstanceId || item.conversationId || '').trim();
      if (!agentId) continue;
      seenAgentIds.add(agentId);
      const safeTitle = safeSearchableText(item.title) || safeSearchableText(item.agentName) || agentId;
      const safePreview = safeSearchableText(item.lastMessagePreview);
      list.push({
        key: `conv:${item.conversationId}:${agentId}`,
        agentInstanceId: agentId,
        chainId: null,
        projectId: item.projectId ?? null,
        title: safeTitle,
        subtitle: safePreview || item.projectId || agentId,
        badge: 'Conversation',
        status: item.runtimeStatus,
        updatedAt: item.updatedAt,
      });
    }

    for (const group of chainGroups) {
      const groupChains = Array.isArray(group?.chains) ? group.chains : [group];
      for (const chain of groupChains) {
        const chainId = String(chain?.chainId || chain?.chain_id || '').trim();
        const rootAgent = String(
          chain?.coordinatorAgentInstanceId ||
            chain?.root_agent_id ||
            chain?.participants?.[0] ||
            chainId,
        ).trim();
        if (!chainId || !rootAgent) continue;
        const safeChainTitle =
          safeSearchableText(chain?.title || chain?.display_title || chain?.latest_subject) ||
          chainId;
        list.push({
          key: `chain:${chainId}:${rootAgent}`,
          agentInstanceId: rootAgent,
          chainId,
          projectId: String(chain?.projectId || chain?.project_id || group?.projectId || '') || null,
          title: safeChainTitle,
          subtitle: `Chain ${chainId} · ${rootAgent}`,
          badge: 'Task Chain',
          updatedAt: chain?.updatedAt || chain?.updated_at,
        });
      }
    }

    for (const proj of liveProjects) {
      for (const chain of proj.chains || []) {
        for (const agent of chain.liveAgents || []) {
          const agentId = (agent.agentInstanceId || '').trim();
          if (!agentId || seenAgentIds.has(agentId)) continue;
          seenAgentIds.add(agentId);
          const safeName = safeSearchableText(agent.displayName) || agentId;
          list.push({
            key: `agent:${agentId}`,
            agentInstanceId: agentId,
            chainId: chain.chainId || null,
            projectId: agent.projectId || proj.projectId || null,
            title: safeName,
            subtitle: `${safeSearchableText(proj.name) || proj.projectId} · ${chain.chainId}`,
            badge: 'Live Agent',
            status: agent.runtimeStatus,
            updatedAt: agent.createdAt,
          });
        }
      }
    }

    return list;
  }, [chainGroups, liveProjects, sidebarItems]);

  const filteredCandidates = useMemo(() => {
    const query = search.trim().toLowerCase();
    return candidates.filter((item) => {
      if (categoryFilter !== 'all' && item.badge !== categoryFilter) {
        return false;
      }
      if (!query) return true;
      return (
        (!isVaultArmored(item.title) && item.title.toLowerCase().includes(query)) ||
        (!isVaultArmored(item.subtitle) && item.subtitle.toLowerCase().includes(query)) ||
        item.agentInstanceId.toLowerCase().includes(query) ||
        Boolean(item.chainId && item.chainId.toLowerCase().includes(query))
      );
    });
  }, [candidates, categoryFilter, search]);

  // The workspace puts the agent into this pane (deduped: an agent already
  // open in another pane is focused instead).
  const handleSelectConversation = (selection: SelectedWindowConversation) => {
    onSelect?.(selection);
  };

  return (
    <div
      data-testid={`new-conversation-window-pane-${paneId}`}
      data-debug-id={`new-conversation-window-pane-${paneId}`}
      className="flex h-full w-full flex-col overflow-hidden bg-canvas p-4 text-primary"
    >
      <div className="mx-auto flex h-full w-full max-w-xl flex-col overflow-hidden">
        {/* Top CTA: Start a brand new conversation in this window pane */}
        <div className="mb-4 flex flex-col gap-2 rounded-xl border border-subtle bg-surface p-3.5">
          <div className="flex items-center justify-between gap-3">
            <div className="min-w-0">
              <h3 className="flex items-center gap-1.5 text-sm font-semibold text-primary">
                <Icon name="spark" size={15} className="text-accent" />
                <span>Open a chat in this pane</span>
              </h3>
              <p className="mt-0.5 text-xs text-muted">
                Select an existing conversation, task chain, or live agent below, or launch a new session.
              </p>
            </div>
            <Button
              type="button"
              variant="primary"
              size="sm"
              onClick={() => setIsLaunchModalOpen(true)}
              data-testid={`start-new-conversation-btn-${paneId}`}
            >
              Start New Conversation
            </Button>
          </div>
        </div>

        {/* Search & Category Filter */}
        <div className="mb-3 flex flex-col gap-2 sm:flex-row sm:items-center">
          <div className="relative flex-1">
            <span className="pointer-events-none absolute left-2.5 top-1/2 -translate-y-1/2 text-muted">
              <Icon name="search" size={13} />
            </span>
            <input
              type="search"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Search conversations, chains, or agents..."
              aria-label="Search conversations, chains, or agents"
              data-testid={`new-window-pane-search-${paneId}`}
              className="h-8 w-full rounded-md border border-subtle bg-surface pl-8 pr-3 text-xs text-primary placeholder:text-muted focus:border-accent focus:outline-none"
            />
          </div>
          <div className="flex items-center gap-1">
            {(['all', 'Conversation', 'Task Chain', 'Live Agent'] as const).map(
              (cat) => (
                <button
                  key={cat}
                  type="button"
                  onClick={() => setCategoryFilter(cat)}
                  className={`rounded px-2 py-1 text-[11px] font-medium transition-colors ${
                    categoryFilter === cat
                      ? 'bg-accent/15 text-accent'
                      : 'text-muted hover:bg-neutral-soft hover:text-primary'
                  }`}
                >
                  {cat === 'all' ? 'All' : cat}
                </button>
              ),
            )}
          </div>
        </div>

        {/* Filtered Conversation / Chain / Agent List */}
        <div className="flex-1 overflow-y-auto rounded-xl border border-subtle bg-surface/50 p-1.5">
          {isLoading && candidates.length === 0 ? (
            <div className="flex h-32 items-center justify-center text-xs text-muted">
              Loading conversations and live agents...
            </div>
          ) : filteredCandidates.length === 0 ? (
            <div className="flex h-32 flex-col items-center justify-center gap-2 text-center text-xs text-muted">
              <span>No matching conversations or agents found.</span>
              <Button
                type="button"
                variant="secondary"
                size="sm"
                onClick={() => setIsLaunchModalOpen(true)}
              >
                Launch a New Conversation
              </Button>
            </div>
          ) : (
            <ul className="space-y-1">
              {filteredCandidates.map((item) => {
                const isAlreadyOpen = openSet.has(item.agentInstanceId);
                return (
                  <li key={item.key}>
                    <button
                      type="button"
                      data-testid={`window-pane-candidate-${item.agentInstanceId}`}
                      onClick={() =>
                        handleSelectConversation({
                          agentInstanceId: item.agentInstanceId,
                          chainId: item.chainId,
                          projectId: item.projectId,
                          title: item.title,
                        })
                      }
                      className="flex w-full items-center justify-between gap-3 rounded-lg px-3 py-2 text-left transition-colors hover:bg-neutral-soft"
                    >
                      <div className="flex min-w-0 flex-1 items-start gap-2.5">
                        <Icon
                          name={
                            item.badge === 'Task Chain'
                              ? 'tasks'
                              : item.badge === 'Live Agent'
                                ? 'bot'
                                : 'chat'
                          }
                          size={15}
                          className="mt-0.5 shrink-0 text-accent"
                        />
                        <div className="min-w-0 flex-1">
                          <div className="flex items-center gap-2">
                            <span className="truncate text-xs font-medium text-primary">
                              {item.title}
                            </span>
                            <Badge tone="neutral">{item.badge}</Badge>
                            {isAlreadyOpen ? (
                              <Badge tone="info">Open in Window</Badge>
                            ) : null}
                          </div>
                          <p className="mt-0.5 truncate text-[11px] text-muted">
                            {item.subtitle}
                          </p>
                        </div>
                      </div>
                      <span className="shrink-0 font-mono text-[10px] text-muted">
                        {item.agentInstanceId}
                      </span>
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </div>

      <NewConversationModal
        open={isLaunchModalOpen}
        onClose={() => setIsLaunchModalOpen(false)}
        onCreated={(selection) => handleSelectConversation(selection)}
      />
    </div>
  );
}

export default NewConversationWindowPane;

/** Main-pane new-chat picker ('_new' leaf). */
export { NewConversationWindowPane as NewChatPanePicker };
