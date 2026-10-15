import { useEffect, useMemo, useRef, useState } from 'react';
import type { KeyboardEvent as ReactKeyboardEvent } from 'react';
import { useSelector } from 'react-redux';
import { useListConversationInboxQuery, useLazyListConversationInboxQuery, type SidebarConversation } from '../../api/endpoints/sidebar';
import { buildRouteHash } from '../../utils/appLocation';

import { Button, Icon, Text } from '@ui';
import { VaultText } from '../vault/VaultText';
import { isVaultArmored } from '../../utils/vaultContent';
import { selectActiveVaultKey } from '../../store/vaultSlice';
import { decryptConversationList } from '../../utils/vaultChats';
import { navigateIndex, selectionDirectionForEvent } from '../chains/taskChainSelectorLogic';
const PAGE_SIZE = 40;

function looksLikeInternalId(value: string): boolean {
  return /^(agt|inst|chat|conv|usr|brg|task|chain|proj|art)_[a-z0-9]/i.test(String(value || '').trim());
}

function conversationTitle(conversation: SidebarConversation): string {
  const title = String(conversation.title || '').trim();
  if (title && title !== conversation.conversationId && title !== conversation.agentInstanceId && !looksLikeInternalId(title)) return title;
  const agent = String(conversation.agentName || '').trim();
  if (agent && !looksLikeInternalId(agent)) return agent;
  return 'Untitled conversation';
}

function timestampLabel(conversation: SidebarConversation): string {
  const unixMs = Number(conversation.lastMessage?.createdUnixMs || conversation.lastMessageUnixMs || 0);
  const raw = conversation.lastMessage?.createdAt || conversation.lastMessageAt || conversation.updatedAt || '';
  const date = unixMs > 0 ? new Date(unixMs) : raw ? new Date(raw) : null;
  if (!date || Number.isNaN(date.getTime())) return '';
  const now = new Date();
  if (date.toDateString() === now.toDateString()) return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  const sameYear = date.getFullYear() === now.getFullYear();
  return date.toLocaleDateString([], sameYear ? { month: 'short', day: 'numeric' } : { month: 'short', day: 'numeric', year: '2-digit' });
}

function lastMessageLabel(conversation: SidebarConversation): { prefix: string; preview: string } {
  const last = conversation.lastMessage;
  const direction = String(last?.direction || conversation.lastMessageDirection || '').toLowerCase();
  const rawDirection = String(last?.rawDirection || '').toLowerCase();
  const sent = direction === 'sent' || rawDirection === 'user_to_agent';
  const sender = String(last?.sender?.displayName || conversation.agentName || '').trim();
  const prefix = sent ? 'You' : (sender && !looksLikeInternalId(sender) ? sender : 'Received');
  const preview = String(last?.bodyPreview || conversation.lastMessagePreview || '').trim();
  return { prefix, preview: preview || 'No messages yet' };
}

function mergeConversations(current: SidebarConversation[], next: SidebarConversation[]): SidebarConversation[] {
  const byId = new Map<string, SidebarConversation>();
  for (const item of current) if (item.conversationId) byId.set(item.conversationId, item);
  for (const item of next) if (item.conversationId) byId.set(item.conversationId, item);
  return Array.from(byId.values()).sort((left, right) => {
    const leftTime = Number(left.lastMessage?.createdUnixMs || left.lastMessageUnixMs || Date.parse(left.lastMessageAt || left.updatedAt || '') || 0);
    const rightTime = Number(right.lastMessage?.createdUnixMs || right.lastMessageUnixMs || Date.parse(right.lastMessageAt || right.updatedAt || '') || 0);
    return rightTime - leftTime || String(right.conversationId).localeCompare(String(left.conversationId));
  });
}

export interface ConversationsHomePageProps {
  /** Select in-place instead of navigating. Used by global and pane shortcut pickers. */
  onSelectConversation?: (agentInstanceId: string) => void;
  compact?: boolean;
  autoFocusSearch?: boolean;
}

export default function ConversationsHomePage({ onSelectConversation, compact = false, autoFocusSearch = false }: ConversationsHomePageProps = {}) {
  const firstPage = useListConversationInboxQuery({ limit: PAGE_SIZE });
  const [fetchPage, fetchPageResult] = useLazyListConversationInboxQuery();
  const [rows, setRows] = useState<SidebarConversation[]>([]);
  const [nextCursor, setNextCursor] = useState('');
  const [hasMore, setHasMore] = useState(false);
  const [loadError, setLoadError] = useState('');
  const [query, setQuery] = useState('');
  const [activeIndex, setActiveIndex] = useState(0);
  const searchRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLElement>(null);

  const activeKey = useSelector(selectActiveVaultKey);
  const [decryptedRows, setDecryptedRows] = useState<SidebarConversation[]>([]);

  useEffect(() => {
    if (!firstPage.data) return;
    setRows(firstPage.data.conversations || []);
    setNextCursor(firstPage.data.nextCursor || '');
    setHasMore(Boolean(firstPage.data.hasMore));
  }, [firstPage.data]);

  useEffect(() => {
    let mounted = true;
    // Key material lives only as a non-extractable CryptoKey (REQ-VAULT-HARDEN-1),
    // so the gate is the real key, not the permanently-null state.vault.rawVaultKeyHex.
    // With no vault configured there is no key and the plaintext rows pass through unchanged.
    if (!activeKey) {
      setDecryptedRows(rows);
      return;
    }
    decryptConversationList(rows, activeKey)
      .then((decrypted) => {
        if (mounted) setDecryptedRows(decrypted);
      })
      .catch(() => {
        if (mounted) setDecryptedRows(rows);
      });
    return () => {
      mounted = false;
    };
  }, [rows, activeKey]);

  const conversations = useMemo(() => mergeConversations([], decryptedRows), [decryptedRows]);
  const filteredConversations = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return conversations;
    return conversations.filter((conversation) => {
      const last = lastMessageLabel(conversation);
      return [conversationTitle(conversation), conversation.agentName, last.prefix, last.preview]
        .some((value) => String(value || '').toLowerCase().includes(needle));
    });
  }, [conversations, query]);
  const unreadTotal = conversations.reduce((sum, conversation) => sum + Number(conversation.unreadCount || 0), 0);

  useEffect(() => {
    if (!autoFocusSearch) return;
    const frame = requestAnimationFrame(() => searchRef.current?.focus());
    return () => cancelAnimationFrame(frame);
  }, [autoFocusSearch]);

  useEffect(() => {
    setActiveIndex((current) => (
      filteredConversations.length === 0 ? 0 : Math.min(current, filteredConversations.length - 1)
    ));
  }, [filteredConversations.length]);

  useEffect(() => {
    const active = listRef.current?.querySelector<HTMLElement>(`[data-conversation-index="${activeIndex}"]`);
    active?.scrollIntoView?.({ block: 'nearest' });
  }, [activeIndex]);

  function selectConversation(conversation: SidebarConversation) {
    if (onSelectConversation) {
      onSelectConversation(conversation.agentInstanceId);
      return;
    }
    window.location.hash = buildRouteHash(`/conversations/${encodeURIComponent(conversation.agentInstanceId)}`, '');
  }

  function handleSearchKeyDown(event: ReactKeyboardEvent<HTMLInputElement>) {
    const direction = selectionDirectionForEvent(event);
    if (direction) {
      event.preventDefault();
      setActiveIndex((current) => navigateIndex(current, filteredConversations.length, direction));
      return;
    }
    if (event.key === 'Enter') {
      const selected = filteredConversations[activeIndex];
      if (!selected) return;
      event.preventDefault();
      selectConversation(selected);
    }
  }

  async function loadMore() {
    if (!nextCursor || fetchPageResult.isFetching) return;
    setLoadError('');
    try {
      const page = await fetchPage({ limit: PAGE_SIZE, cursor: nextCursor }).unwrap();
      setRows((current) => mergeConversations(current, page.conversations || []));
      setNextCursor(page.nextCursor || '');
      setHasMore(Boolean(page.hasMore));
    } catch (error: any) {
      setLoadError(String(error?.message || error || 'Failed to load more conversations'));
    }
  }

  return (
    <div data-debug-id="conversations-home-page" className="flex min-h-full w-full flex-col text-left">
      {/* On mobile the shell top bar already shows the "Conversations" title, so
          keep this header compact (a slim count row + New). Desktop shows the full
          eyebrow/title block. */}
      <header data-debug-id="conversations-home-header" className={compact ? 'sticky top-0 z-10 border-b border-subtle bg-canvas/95 pb-3 backdrop-blur' : 'sticky top-0 z-10 -mx-3 border-b border-subtle bg-canvas/95 px-3 py-2 backdrop-blur sm:-mx-4 sm:px-4 sm:pb-3 sm:pt-2 lg:-mx-5 lg:px-5'}>
        <div className="flex items-center justify-between gap-3">
          <div className="min-w-0">
            <Text as="p" role="overline" tone="accent" className="hidden sm:block">Conversations</Text>
            <h1 className="hidden text-2xl font-semibold tracking-tight text-primary sm:mt-1 sm:block">Inbox</h1>
            <p data-debug-id="conversations-home-subtitle" className="text-[13px] text-muted sm:mt-1 sm:text-sm">{conversations.length} loaded{unreadTotal ? ` · ${unreadTotal} unread` : ''}</p>
          </div>
          {!compact ? <a data-debug-id="conversations-home-new-btn" href={buildRouteHash('/conversations/new', '')} className="inline-flex min-h-10 shrink-0 items-center gap-1.5 rounded-2xl bg-accent px-4 py-2 text-sm font-bold text-accent-fg shadow-panel hover:opacity-90"><Icon name="plus" size={15} /> New</a> : null}
        </div>
        <div className="relative mt-3">
          <Icon name="search" size={15} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-faint" />
          <input
            ref={searchRef}
            data-debug-id="conversation-inbox-search-input"
            role="combobox"
            aria-expanded="true"
            aria-controls="conversation-inbox-listbox"
            aria-activedescendant={filteredConversations.length ? `conversation-inbox-option-${activeIndex}` : undefined}
            value={query}
            onChange={(event) => { setQuery(event.target.value); setActiveIndex(0); }}
            onKeyDown={handleSearchKeyDown}
            placeholder="Search conversations…"
            className="min-h-10 w-full rounded-xl border border-subtle bg-surface px-3 pl-9 text-sm text-primary outline-none focus:border-accent"
          />
        </div>
      </header>

      {firstPage.isError ? (
        <div data-debug-id="conversation-inbox-error" className="mt-4 rounded-2xl border border-danger/30 bg-danger-soft p-4 text-sm text-danger">{String((firstPage.error as any)?.error || 'Failed to load conversations')}</div>
      ) : null}

      <section ref={listRef} id="conversation-inbox-listbox" role="listbox" aria-label="Conversations" data-debug-id="conversation-inbox-list" className="mt-3 w-full divide-y divide-subtle overflow-hidden rounded-3xl border border-subtle bg-surface">
        {firstPage.isLoading && conversations.length === 0 ? (
          <div data-debug-id="conversation-inbox-loading" className="p-5 text-sm text-muted">Loading conversations…</div>
        ) : conversations.length === 0 ? (
          <div data-debug-id="conversation-inbox-empty" className="p-6 text-sm text-muted">No conversations yet. Start a new conversation to see it here.</div>
        ) : filteredConversations.length === 0 ? (
          <div data-debug-id="conversation-inbox-no-results" className="p-6 text-sm text-muted">No conversations match “{query.trim()}”.</div>
        ) : filteredConversations.map((conversation, index) => {
          const title = conversationTitle(conversation);
          const last = lastMessageLabel(conversation);
          const ts = timestampLabel(conversation);
          const content = <>
              <div className="grid h-12 w-12 shrink-0 place-items-center rounded-2xl bg-accent/10 text-base font-bold text-accent ring-1 ring-accent/20 sm:h-14 sm:w-14">
                {isVaultArmored(title) ? '🔒' : (title.slice(0, 1).toUpperCase() || 'C')}
              </div>
              <div className="min-w-0 flex-1">
                <div className="flex min-w-0 items-center gap-2">
                  <h2 data-debug-id={`conversation-inbox-title-${conversation.conversationId}`} className="truncate text-[15px] font-semibold text-primary sm:text-base">
                    <VaultText value={title} as="span" />
                  </h2>
                  {conversation.unreadCount > 0 ? <span data-debug-id={`conversation-inbox-unread-${conversation.conversationId}`} className="inline-flex min-w-5 shrink-0 items-center justify-center rounded-full bg-accent px-1.5 py-0.5 text-[10px] font-bold text-accent-fg">{conversation.unreadCount > 99 ? '99+' : conversation.unreadCount}</span> : null}
                </div>
                <p data-debug-id={`conversation-inbox-last-message-${conversation.conversationId}`} className="mt-1 line-clamp-2 text-[13px] leading-5 text-muted group-hover:text-primary">
                  <span data-debug-id={`conversation-inbox-last-message-label-${conversation.conversationId}`} className="font-semibold text-primary">{last.prefix}: </span>
                  <VaultText value={last.preview} as="span" />
                </p>
              </div>
              <div className="flex h-full shrink-0 flex-col items-end justify-start gap-2 pt-1">
                {ts ? <time data-debug-id={`conversation-inbox-timestamp-${conversation.conversationId}`} className="text-caption font-medium text-muted">{ts}</time> : null}
                <span aria-hidden="true" className="text-lg text-faint group-hover:text-muted">›</span>
              </div>
            </>;
          const active = index === activeIndex;
          const className = `group flex min-h-[76px] w-full touch-manipulation items-center gap-3 px-3 py-3 text-left transition hover:bg-neutral-soft active:bg-neutral-soft/80 sm:min-h-[84px] sm:px-4 ${active ? 'bg-accent/10 ring-1 ring-inset ring-accent/30' : ''}`;
          const optionProps = {
            id: `conversation-inbox-option-${index}`,
            role: 'option',
            'aria-selected': active,
            'data-conversation-index': index,
            onMouseEnter: () => setActiveIndex(index),
          } as const;
          return onSelectConversation ? (
            <button {...optionProps} key={conversation.conversationId} type="button" data-debug-id={`conversation-inbox-row-${conversation.conversationId}`} onClick={() => selectConversation(conversation)} className={className}>{content}</button>
          ) : (
            <a {...optionProps} key={conversation.conversationId} data-debug-id={`conversation-inbox-row-${conversation.conversationId}`} href={buildRouteHash(`/conversations/${encodeURIComponent(conversation.agentInstanceId)}`, '')} className={className}>{content}</a>
          );
        })}
      </section>

      {loadError ? <div data-debug-id="conversation-inbox-load-error" className="mt-3 rounded-2xl border border-danger/30 bg-danger-soft p-3 text-sm text-danger">{loadError}</div> : null}
      {hasMore ? (
        <Button data-debug-id="conversation-inbox-load-more-btn" variant="secondary" onClick={loadMore} disabled={fetchPageResult.isFetching} className="mx-auto mt-4 min-h-11 disabled:cursor-wait">
          {fetchPageResult.isFetching ? 'Loading…' : 'Load more conversations'}
        </Button>
      ) : null}
    </div>
  );
}
