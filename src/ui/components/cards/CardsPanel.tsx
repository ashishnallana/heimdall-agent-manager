import React, { useState, useMemo } from 'react';
import { Badge, Button, Checkbox, Icon, IconButton, Input, PageShell, StatusPill } from '@ui';
import {
  Card,
  CardOperation,
  formatOpLabel,
  formatSourceRef,
  toDisplayText,
  cardErrorText,
  useListCardsQuery,
  useAcceptCardMutation,
  useRejectCardMutation,
  useDiscardCardMutation,
  useSnoozeCardMutation,
} from '../../api/endpoints/cards';
import { useListProjectsQuery, Project } from '../../api/endpoints/projects';
import Markdown from '../Markdown';
import { isVaultArmored, maskVaultArmored } from '../../utils/vaultContent';
import { resolveCardTitle, UNTITLED_CARD } from '../../utils/vaultCardOps';
import { VaultText, DecryptedMarkdown } from '../vault/VaultText';

export function isCardExpired(c: { ttl_at?: string } | null | undefined): boolean {
  if (!c?.ttl_at || typeof c.ttl_at !== 'string' || !c.ttl_at.trim()) {
    return false;
  }
  const time = new Date(c.ttl_at).getTime();
  if (Number.isNaN(time)) {
    return false;
  }
  return time <= Date.now();
}

const STATUS_TABS = [
  { id: 'pending', label: 'Pending' },
  { id: 'all', label: 'All Cards' },
  { id: 'accepted', label: 'Accepted' },
  { id: 'rejected', label: 'Rejected' },
  { id: 'discarded', label: 'Discarded' },
  { id: 'snoozed', label: 'Snoozed' },
];

export default function CardsPanel() {
  const { data: cardsData, isLoading: cardsLoading, error: cardsError, refetch } = useListCardsQuery();
  const { data: projectsData, isLoading: projectsLoading } = useListProjectsQuery();

  const [acceptCard] = useAcceptCardMutation();
  const [rejectCard] = useRejectCardMutation();
  const [discardCard] = useDiscardCardMutation();
  const [snoozeCard] = useSnoozeCardMutation();

  const [searchQuery, setSearchQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState('pending');
  const [collapsedProjects, setCollapsedProjects] = useState<Record<string, boolean>>({});
  const [selectedCardIds, setSelectedCardIds] = useState<string[]>([]);
  const [expandedCardIds, setExpandedCardIds] = useState<Record<string, boolean>>({});
  const [processingId, setProcessingId] = useState<string | null>(null);
  const [isBatchProcessing, setIsBatchProcessing] = useState(false);
  const [feedback, setFeedback] = useState<{ type: 'success' | 'error'; message: string } | null>(null);

  const cards: Card[] = cardsData?.cards || [];
  const projects: Project[] = projectsData?.projects || [];

  const projectMap = useMemo(() => {
    const map = new Map<string, Project>();
    for (const p of projects) {
      map.set(p.project_id, p);
    }
    return map;
  }, [projects]);

  // Group cards by project
  const { groupedCards, totalFilteredCount, pendingCount } = useMemo(() => {
    const groups = new Map<string, { project: Project | null; cards: Card[] }>();

    for (const p of projects) {
      groups.set(p.project_id, { project: p, cards: [] });
    }

    const UNASSIGNED_KEY = '__unassigned__';
    groups.set(UNASSIGNED_KEY, { project: null, cards: [] });

    let pending = 0;
    let filteredTotal = 0;

    for (const card of cards) {
      if (card.status === 'pending' && !isCardExpired(card)) {
        pending += 1;
      }

      // Status filter
      if (statusFilter !== 'all') {
        if (card.status !== statusFilter) {
          continue;
        }
        if (statusFilter === 'pending' && isCardExpired(card)) {
          continue;
        }
      }

      // Search query filter
      if (searchQuery.trim()) {
        const q = searchQuery.toLowerCase();
        const project = card.project_id ? projectMap.get(card.project_id) : null;
        const opLabels = (card.operations || []).map((op) => formatOpLabel(op).toLowerCase()).join(' ');
        const safeTitle = !isVaultArmored(card.title) ? card.title : null;
        const safeRationale = !isVaultArmored(card.rationale) ? card.rationale : null;
        const safeProjectName = !isVaultArmored(project?.name) ? project?.name : null;
        const haystack = [
          safeTitle,
          safeRationale,
          card.scope,
          card.provider,
          card.card_id,
          safeProjectName,
          opLabels,
        ].filter(Boolean).join(' ').toLowerCase();

        if (!haystack.includes(q)) {
          continue;
        }
      }

      filteredTotal += 1;
      const pid = card.project_id;
      if (pid && groups.has(pid)) {
        groups.get(pid)!.cards.push(card);
      } else {
        groups.get(UNASSIGNED_KEY)!.cards.push(card);
      }
    }

    const result: Array<{ id: string; name: string; project: Project | null; cards: Card[] }> = [];
    for (const [key, val] of groups.entries()) {
      if (key === UNASSIGNED_KEY) {
        if (val.cards.length > 0) {
          result.push({
            id: UNASSIGNED_KEY,
            name: 'Global / Cross-Project Cards',
            project: null,
            cards: val.cards,
          });
        }
      } else {
        if (val.cards.length > 0 || !searchQuery.trim()) {
          result.push({
            id: key,
            name: val.project?.name || key,
            project: val.project,
            cards: val.cards,
          });
        }
      }
    }

    // Sort: projects with cards first, then alphabetically
    result.sort((a, b) => {
      if (a.cards.length > 0 && b.cards.length === 0) return -1;
      if (b.cards.length > 0 && a.cards.length === 0) return 1;
      return a.name.localeCompare(b.name);
    });

    return { groupedCards: result, totalFilteredCount: filteredTotal, pendingCount: pending };
  }, [cards, projects, projectMap, statusFilter, searchQuery]);

  const toggleProjectCollapse = (projectId: string) => {
    setCollapsedProjects((prev) => ({
      ...prev,
      [projectId]: !prev[projectId],
    }));
  };

  const toggleCardExpand = (cardId: string) => {
    setExpandedCardIds((prev) => ({
      ...prev,
      [cardId]: !prev[cardId],
    }));
  };

  const toggleCardSelect = (cardId: string) => {
    setSelectedCardIds((prev) =>
      prev.includes(cardId) ? prev.filter((id) => id !== cardId) : [...prev, cardId]
    );
  };

  const handleSelectAllInProject = (projectCards: Card[]) => {
    const projectCardIds = projectCards.map((c) => c.card_id);
    const allSelected = projectCardIds.every((id) => selectedCardIds.includes(id));
    if (allSelected) {
      setSelectedCardIds((prev) => prev.filter((id) => !projectCardIds.includes(id)));
    } else {
      setSelectedCardIds((prev) => Array.from(new Set([...prev, ...projectCardIds])));
    }
  };

  // Card Single Actions
  const handleAccept = async (card: Card) => {
    setProcessingId(card.card_id);
    setFeedback(null);
    try {
      await acceptCard({ id: card.card_id }).unwrap();
      setFeedback({
        type: 'success',
        message: `Card accepted: "${await resolveCardTitle(card.title)}". Operations executed atomically.`,
      });
      setSelectedCardIds((prev) => prev.filter((id) => id !== card.card_id));
      setTimeout(() => setFeedback(null), 6000);
    } catch (err: any) {
      const msg = cardErrorText(err, 'Failed to accept card');
      const isConflict = msg.toLowerCase().includes('precondition') || msg.toLowerCase().includes('guard');
      setFeedback({
        type: 'error',
        message: isConflict
          ? `Card no longer valid: ${msg}. Live state was preserved.`
          : `Failed to accept card: ${msg}`,
      });
    } finally {
      setProcessingId(null);
    }
  };

  const handleReject = async (card: Card) => {
    setProcessingId(card.card_id);
    setFeedback(null);
    try {
      await rejectCard({ id: card.card_id }).unwrap();
      setFeedback({
        type: 'success',
        message: `Card rejected: "${await resolveCardTitle(card.title)}".`,
      });
      setSelectedCardIds((prev) => prev.filter((id) => id !== card.card_id));
      setTimeout(() => setFeedback(null), 5000);
    } catch (err: any) {
      setFeedback({
        type: 'error',
        message: `Failed to reject card: ${cardErrorText(err, 'Reject failed')}`,
      });
    } finally {
      setProcessingId(null);
    }
  };

  const handleDiscard = async (card: Card) => {
    setProcessingId(card.card_id);
    setFeedback(null);
    try {
      await discardCard({ id: card.card_id }).unwrap();
      setFeedback({
        type: 'success',
        message: `Card discarded: "${await resolveCardTitle(card.title)}".`,
      });
      setSelectedCardIds((prev) => prev.filter((id) => id !== card.card_id));
      setTimeout(() => setFeedback(null), 5000);
    } catch (err: any) {
      setFeedback({
        type: 'error',
        message: `Failed to discard card: ${cardErrorText(err, 'Discard failed')}`,
      });
    } finally {
      setProcessingId(null);
    }
  };

  const handleSnooze = async (card: Card) => {
    setProcessingId(card.card_id);
    setFeedback(null);
    try {
      // Default snooze: 24 hours from now
      const snoozeUntil = new Date(Date.now() + 24 * 3600 * 1000).toISOString();
      await snoozeCard({ id: card.card_id, snoozeUntil }).unwrap();
      setFeedback({
        type: 'success',
        message: `Card snoozed for 24h: "${await resolveCardTitle(card.title)}".`,
      });
      setSelectedCardIds((prev) => prev.filter((id) => id !== card.card_id));
      setTimeout(() => setFeedback(null), 5000);
    } catch (err: any) {
      setFeedback({
        type: 'error',
        message: `Failed to snooze card: ${cardErrorText(err, 'Snooze failed')}`,
      });
    } finally {
      setProcessingId(null);
    }
  };

  // Batch Actions
  const handleBatchAccept = async () => {
    if (selectedCardIds.length === 0) return;
    setIsBatchProcessing(true);
    setFeedback(null);
    let successCount = 0;
    let failCount = 0;

    for (const id of selectedCardIds) {
      try {
        await acceptCard({ id }).unwrap();
        successCount += 1;
      } catch (_e) {
        failCount += 1;
      }
    }

    setIsBatchProcessing(false);
    setSelectedCardIds([]);
    if (failCount === 0) {
      setFeedback({
        type: 'success',
        message: `Accepted and executed all ${successCount} selected cards.`,
      });
    } else {
      setFeedback({
        type: 'error',
        message: `Accepted ${successCount} cards; ${failCount} failed (possibly due to changed preconditions).`,
      });
    }
    setTimeout(() => setFeedback(null), 6000);
  };

  const handleBatchReject = async () => {
    if (selectedCardIds.length === 0) return;
    setIsBatchProcessing(true);
    setFeedback(null);
    let count = 0;
    for (const id of selectedCardIds) {
      try {
        await rejectCard({ id }).unwrap();
        count += 1;
      } catch (_e) {}
    }
    setIsBatchProcessing(false);
    setSelectedCardIds([]);
    setFeedback({
      type: 'success',
      message: `Rejected ${count} selected cards.`,
    });
    setTimeout(() => setFeedback(null), 5000);
  };

  const handleBatchDiscard = async () => {
    if (selectedCardIds.length === 0) return;
    setIsBatchProcessing(true);
    setFeedback(null);
    let count = 0;
    for (const id of selectedCardIds) {
      try {
        await discardCard({ id }).unwrap();
        count += 1;
      } catch (_e) {}
    }
    setIsBatchProcessing(false);
    setSelectedCardIds([]);
    setFeedback({
      type: 'success',
      message: `Discarded ${count} selected cards.`,
    });
    setTimeout(() => setFeedback(null), 5000);
  };

  const isLoading = cardsLoading || projectsLoading;

  return (
    <PageShell
      width="full"
      title={
        <span className="inline-flex items-center gap-2.5">
          Action Cards
          <Badge data-debug-id="cards-pending-count" tone={pendingCount > 0 ? 'warning' : 'neutral'}>
            {pendingCount} pending
          </Badge>
          <span className="text-xs text-muted font-normal">
            ({cards.length} total)
          </span>
        </span>
      }
      description="Activity-driven maintenance recommendations synthesized by Ninjy Curator. Review, accept, or reject maintenance proposals."
      actions={
        <div className="flex items-center gap-2">
          <Button
            variant="secondary"
            size="sm"
            data-debug-id="cards-refresh-btn"
            onClick={() => refetch()}
            leading={<Icon name="refresh" size={14} className={isLoading ? 'animate-spin' : ''} />}
          >
            Refresh
          </Button>
        </div>
      }
    >
      <div data-debug-id="cards-feed-page" className="space-y-6">
        {/* Feedback Banner */}
        {feedback && (
          <div
            data-debug-id="cards-feedback-banner"
            className={`flex items-center justify-between rounded-xl border p-3.5 text-xs font-medium animate-fade-in ${
              feedback.type === 'success'
                ? 'border-success/30 bg-success-soft text-success'
                : 'border-danger/30 bg-danger-soft text-danger'
            }`}
          >
            <div className="flex items-center gap-2">
              <Icon name={feedback.type === 'success' ? 'check' : 'alert'} size={14} />
              <span>{feedback.message}</span>
            </div>
            <IconButton icon="close" label="Dismiss" size="sm" onClick={() => setFeedback(null)} />
          </div>
        )}

        {/* Status Filter Tabs & Search Bar */}
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex flex-wrap items-center gap-1.5 border-b border-subtle pb-2 sm:border-none sm:pb-0">
            {STATUS_TABS.map((tab) => {
              const active = statusFilter === tab.id;
              return (
                <button
                  key={tab.id}
                  type="button"
                  data-debug-id={`cards-filter-tab-${tab.id}`}
                  onClick={() => setStatusFilter(tab.id)}
                  className={`rounded-lg px-3 py-1.5 text-xs font-medium transition-colors ${
                    active
                      ? 'bg-accent/20 text-accent border border-accent/40'
                      : 'text-muted hover:text-primary hover:bg-neutral-soft border border-transparent'
                  }`}
                >
                  {tab.label}
                  {tab.id === 'pending' && pendingCount > 0 && (
                    <span className="ml-1.5 rounded-full bg-warning/20 px-1.5 py-0.2 text-[10px] text-warning font-semibold">
                      {pendingCount}
                    </span>
                  )}
                </button>
              );
            })}
          </div>

          <div className="w-full sm:w-72">
            <Input
              type="search"
              data-debug-id="cards-search-input"
              value={searchQuery}
              onChange={setSearchQuery}
              placeholder="Filter cards or operations..."
              width="full"
              leading={<Icon name="search" size={14} />}
              trailing={
                searchQuery ? (
                  <IconButton icon="close" label="Clear search" size="sm" onClick={() => setSearchQuery('')} />
                ) : undefined
              }
            />
          </div>
        </div>

        {/* Batch Selection Action Bar */}
        {selectedCardIds.length > 0 && (
          <div
            data-debug-id="cards-batch-toolbar"
            className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-accent/30 bg-accent-soft px-4 py-2.5 text-xs animate-fade-in"
          >
            <div className="flex items-center gap-2 text-accent font-medium">
              <Icon name="check" size={14} />
              <span>{selectedCardIds.length} cards selected</span>
            </div>

            <div className="flex items-center gap-2">
              <Button
                variant="primary"
                size="sm"
                data-debug-id="cards-batch-accept-btn"
                disabled={isBatchProcessing}
                onClick={handleBatchAccept}
                leading={<Icon name="check" size={14} />}
              >
                Accept Selected
              </Button>
              <Button
                variant="secondary"
                size="sm"
                data-debug-id="cards-batch-reject-btn"
                disabled={isBatchProcessing}
                onClick={handleBatchReject}
                leading={<Icon name="close" size={14} />}
              >
                Reject Selected
              </Button>
              <Button
                variant="ghost"
                size="sm"
                data-debug-id="cards-batch-discard-btn"
                disabled={isBatchProcessing}
                onClick={handleBatchDiscard}
                leading={<Icon name="trash" size={14} />}
              >
                Discard Selected
              </Button>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => setSelectedCardIds([])}
              >
                Clear
              </Button>
            </div>
          </div>
        )}

        {/* Loading State */}
        {isLoading && (
          <div data-debug-id="cards-loading-state" className="flex items-center justify-center p-12 text-muted text-sm">
            <div className="flex items-center gap-2">
              <Icon name="refresh" size={14} className="animate-spin text-accent" />
              <span>Loading Action Cards...</span>
            </div>
          </div>
        )}

        {/* Error State */}
        {cardsError && !isLoading && (
          <div data-debug-id="cards-error-state" className="rounded-xl border border-danger/30 bg-danger-soft p-5 text-sm text-danger">
            Failed to load cards: {String((cardsError as any)?.error || (cardsError as any)?.message || cardsError)}
          </div>
        )}

        {/* Empty State */}
        {!isLoading && !cardsError && totalFilteredCount === 0 && (
          <div
            data-debug-id="cards-empty-state"
            className="flex flex-col items-center justify-center rounded-2xl border border-dashed border-subtle bg-surface/50 p-12 text-center"
          >
            <div className="mb-4 grid h-12 w-12 place-items-center rounded-2xl bg-neutral-soft text-muted">
              <Icon name="spark" size={24} />
            </div>
            <h3 className="text-base font-semibold text-primary">
              {searchQuery.trim()
                ? 'No matching cards found'
                : statusFilter === 'pending'
                ? 'No Pending Action Cards'
                : `No ${statusFilter} Cards`}
            </h3>
            <p className="mt-1 max-w-md text-xs leading-relaxed text-muted">
              {searchQuery.trim()
                ? `No action cards match query "${searchQuery}". Try clearing the search filter.`
                : 'Ninjy Curator analyzes project task chains, comments, memories, and agents to synthesize proactive Action Cards. As new activity occurs, recommended actions will appear here.'}
            </p>
          </div>
        )}

        {/* Project Grouped View */}
        {!isLoading && !cardsError && totalFilteredCount > 0 && (
          <div data-debug-id="cards-project-groups" className="space-y-6">
            {groupedCards.map((group) => {
              if (group.cards.length === 0) return null;

              const isCollapsed = Boolean(collapsedProjects[group.id]);
              const cardCount = group.cards.length;
              const allSelected = group.cards.every((c) => selectedCardIds.includes(c.card_id));
              const someSelected = group.cards.some((c) => selectedCardIds.includes(c.card_id));

              return (
                <div
                  key={group.id}
                  data-debug-id={`cards-project-group-${group.id}`}
                  className="rounded-2xl border border-subtle bg-surface overflow-hidden"
                >
                  {/* Collapsible Project Section Header */}
                  <div className="w-full flex items-center justify-between px-4 py-3 bg-surface-raised border-b border-subtle">
                    <div className="flex items-center gap-3">
                      <Checkbox
                        checked={allSelected}
                        onChange={() => handleSelectAllInProject(group.cards)}
                        aria-label={`Select all cards in ${group.name}`}
                      />

                      <button
                        type="button"
                        data-debug-id={`cards-project-toggle-${group.id}`}
                        onClick={() => toggleProjectCollapse(group.id)}
                        className="flex items-center gap-2 hover:text-primary text-muted text-left transition-colors"
                      >
                        <Icon name={isCollapsed ? 'chevron-right' : 'chevron-down'} size={14} className="text-muted" />
                        <Icon name="folder" size={15} className="text-accent" />
                        <span className="text-sm font-semibold"><VaultText value={group.name} /></span>
                      </button>
                    </div>

                    <div className="flex items-center gap-2">
                      <span
                        data-debug-id={`cards-project-count-${group.id}`}
                        className="rounded-md bg-surface border border-subtle px-2 py-0.5 text-xs text-muted"
                      >
                        {cardCount} {cardCount === 1 ? 'card' : 'cards'}
                      </span>
                    </div>
                  </div>

                  {/* Collapsible Cards Content */}
                  {!isCollapsed && (
                    <div className="p-4 space-y-3">
                      <div className="grid gap-3">
                        {group.cards.map((card) => (
                          <CardRow
                            key={card.card_id}
                            card={card}
                            isSelected={selectedCardIds.includes(card.card_id)}
                            isExpanded={Boolean(expandedCardIds[card.card_id])}
                            isProcessing={processingId === card.card_id || isBatchProcessing}
                            onToggleSelect={() => toggleCardSelect(card.card_id)}
                            onToggleExpand={() => toggleCardExpand(card.card_id)}
                            onAccept={() => handleAccept(card)}
                            onReject={() => handleReject(card)}
                            onDiscard={() => handleDiscard(card)}
                            onSnooze={() => handleSnooze(card)}
                          />
                        ))}
                      </div>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>
    </PageShell>
  );
}

// Sub-component: Individual Action Card Row
function CardRow({
  card,
  isSelected,
  isExpanded,
  isProcessing,
  onToggleSelect,
  onToggleExpand,
  onAccept,
  onReject,
  onDiscard,
  onSnooze,
}: {
  card: Card;
  isSelected: boolean;
  isExpanded: boolean;
  isProcessing: boolean;
  onToggleSelect: () => void;
  onToggleExpand: () => void;
  onAccept: () => void;
  onReject: () => void;
  onDiscard: () => void;
  onSnooze: () => void;
}) {
  const isPending = card.status === 'pending';
  const isSnoozed = card.status === 'snoozed';
  const canAct = isPending || isSnoozed;

  const confidencePct = Math.round(card.confidence * 100);
  const confidenceColor =
    confidencePct >= 80 ? 'text-success border-success/30 bg-success-soft' :
    confidencePct >= 50 ? 'text-warning border-warning/30 bg-warning-soft' :
    'text-danger border-danger/30 bg-danger-soft';

  const providerLabel =
    card.provider === 'curator_llm' ? 'Curator' :
    card.provider === 'task_validation' ? 'Task Validation' :
    card.provider === 'memory_proposal' ? 'Memory Proposal' :
    card.provider || 'System';

  const statusTone =
    card.status === 'accepted' ? 'success' :
    card.status === 'rejected' ? 'danger' :
    card.status === 'discarded' ? 'neutral' :
    card.status === 'snoozed' ? 'neutral' :
    'warning';

  const opCount = card.operations?.length || 0;

  return (
    <div
      data-debug-id={`card-row-${card.card_id}`}
      className={`rounded-xl border transition-all p-4 space-y-3 ${
        isSelected
          ? 'border-accent/40 bg-accent/10'
          : 'border-subtle bg-surface-raised hover:border-strong'
      }`}
    >
      {/* Top Header Row */}
      <div className="flex flex-wrap items-start justify-between gap-3">
        {/* Left: Checkbox + Expand Button + Title & Badges */}
        <div className="flex items-start gap-3 flex-1 min-w-[280px]">
          <div className="pt-0.5">
            <Checkbox
              checked={isSelected}
              onChange={onToggleSelect}
              aria-label={`Select card ${maskVaultArmored(card.title ?? '')}`}
            />
          </div>

          <button
            type="button"
            data-debug-id={`card-expand-toggle-${card.card_id}`}
            onClick={onToggleExpand}
            className="pt-1 text-muted hover:text-primary transition-colors"
            aria-label={isExpanded ? 'Collapse card details' : 'Expand card details'}
          >
            <Icon name={isExpanded ? 'chevron-down' : 'chevron-right'} size={15} />
          </button>

          <div className="space-y-1.5 flex-1">
            <div className="flex flex-wrap items-center gap-2">
              <h4
                data-debug-id={`card-title-${card.card_id}`}
                onClick={onToggleExpand}
                className="text-sm font-semibold text-primary cursor-pointer hover:text-accent transition-colors"
              >
                <VaultText value={card.title} fallback={UNTITLED_CARD} as="span" />
              </h4>

              {/* Status Pill */}
              <StatusPill data-debug-id={`card-status-badge-${card.card_id}`} tone={statusTone}>
                {card.status}
              </StatusPill>

              {/* Scope Badge */}
              <span className="rounded-md border border-subtle bg-neutral-soft px-2 py-0.5 text-caption text-muted">
                {card.scope || 'project'}
              </span>

              {/* Provider Badge */}
              <span className="rounded-md border border-accent/30 bg-accent/10 px-2 py-0.5 text-caption text-accent flex items-center gap-1">
                <Icon name="spark" size={11} />
                <span>{providerLabel}</span>
              </span>

              {/* Confidence Badge */}
              <span className={`rounded-md border px-2 py-0.5 text-caption font-medium ${confidenceColor}`}>
                {confidencePct}% conf
              </span>

              {/* Operations Count Badge */}
              <span className="rounded-md border border-subtle bg-surface px-1.5 py-0.5 text-[10px] text-muted">
                {opCount} {opCount === 1 ? 'op' : 'ops'}
              </span>
            </div>

            {/* Rationale Summary (markdown via shared MarkdownBody) */}
            {card.rationale && (
              <div
                data-debug-id={`card-rationale-${card.card_id}`}
                className="text-xs text-muted leading-relaxed max-w-3xl break-words"
              >
                <DecryptedMarkdown source={card.rationale} compact copyAll={false} />
              </div>
            )}
          </div>
        </div>

        {/* Right: Action Buttons */}
        <div className="flex items-center gap-2 self-start">
          {canAct && (
            <>
              <Button
                variant="primary"
                size="sm"
                data-debug-id={`card-accept-btn-${card.card_id}`}
                disabled={isProcessing}
                onClick={onAccept}
                leading={<Icon name="check" size={13} />}
              >
                Accept
              </Button>
              <Button
                variant="secondary"
                size="sm"
                data-debug-id={`card-reject-btn-${card.card_id}`}
                disabled={isProcessing}
                onClick={onReject}
                leading={<Icon name="close" size={13} />}
              >
                Reject
              </Button>
              <Button
                variant="ghost"
                size="sm"
                data-debug-id={`card-discard-btn-${card.card_id}`}
                disabled={isProcessing}
                onClick={onDiscard}
                leading={<Icon name="trash" size={13} />}
              >
                Discard
              </Button>
              {isPending && (
                <IconButton
                  icon="clock"
                  label="Snooze for 24h"
                  size="sm"
                  disabled={isProcessing}
                  onClick={onSnooze}
                />
              )}
            </>
          )}

          {!canAct && (
            <span className="text-xs text-muted italic pr-2">
              Resolved as {card.status}
            </span>
          )}
        </div>
      </div>

      {/* Expanded Operations & Details View (REQ-UX-1) */}
      {isExpanded && (
        <div
          data-debug-id={`card-expanded-details-${card.card_id}`}
          className="mt-3 pt-3 border-t border-subtle space-y-3 text-xs animate-fade-in"
        >
          {/* Operations List */}
          <div className="space-y-2">
            <h5 className="font-semibold text-primary flex items-center gap-1.5">
              <Icon name="tasks" size={13} className="text-accent" />
              <span>Operations Preview ({opCount})</span>
            </h5>

            {opCount === 0 ? (
              <p className="text-faint italic">No automated operations attached.</p>
            ) : (
              <div className="space-y-2">
                {card.operations.map((op, idx) => (
                  <OperationPreviewRow key={idx} op={op} index={idx} />
                ))}
              </div>
            )}
          </div>

          {/* Evidence Source References */}
          {card.source_refs && card.source_refs.length > 0 && (
            <div className="pt-2 border-t border-subtle flex flex-wrap items-center gap-2">
              <span className="text-muted font-medium">Evidence Sources:</span>
              {card.source_refs.map((refId, i) => (
                <span
                  key={i}
                  className="rounded-md border border-subtle bg-neutral-soft px-2 py-0.5 font-mono text-[11px] text-muted"
                >
                  {formatSourceRef(refId)}
                </span>
              ))}
            </div>
          )}

          {/* Precondition Guard & Expiration */}
          {(card.guard?.target_type || card.ttl_at) && (
            <div className="rounded-lg border border-warning/20 bg-warning-soft p-2.5 space-y-1 text-warning text-[11px]">
              <div className="flex items-center gap-1.5 font-semibold text-warning">
                <Icon name="lock" size={12} />
                <span>Precondition Guard & TTL</span>
              </div>
              {card.guard?.target_type && (
                <p>
                  Target: <span className="font-mono text-primary">{card.guard.target_type}:{card.guard.target_id}</span>
                  {card.guard.field_conditions && (
                    <span> (Conditions: {JSON.stringify(card.guard.field_conditions)})</span>
                  )}
                </p>
              )}
              {card.ttl_at && (
                <p className="text-muted">
                  Expires: <span className="font-mono text-primary">{card.ttl_at}</span>
                </p>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// Sub-component: Human-Friendly Operation Preview (REQ-UX-1)
function OperationPreviewRow({ op, index }: { op: CardOperation; index: number }) {
  // REQ-UX-1: Human-readable label (mandatory)
  const humanLabel = formatOpLabel(op);
  const opName = op.op || 'operation';

  // Badge coloring by op category
  const opBadgeTone =
    opName.startsWith('memory.create') ? 'border-success/30 bg-success-soft text-success' :
    opName.startsWith('memory.delete') || opName.startsWith('memory.archive') ? 'border-danger/30 bg-danger-soft text-danger' :
    opName.startsWith('memory.update') ? 'border-warning/30 bg-warning-soft text-warning' :
    opName.startsWith('task.vote') ? 'border-accent/30 bg-accent/10 text-accent' :
    opName.startsWith('task_chain') ? 'border-accent/30 bg-accent/10 text-accent' :
    'border-subtle bg-surface-raised text-muted';

  const getArg = (k: string) => op.args?.[k] ?? op[k];

  // Specific operation parameters for clean diff preview.
  // Coerce every value to a display-safe string: raw objects/arrays passed as
  // React children throw ("Objects are not valid as a React child") and blank
  // the whole page.
  const memTitle = toDisplayText(getArg('title'));
  const memBody = toDisplayText(getArg('body'));
  const memType = toDisplayText(getArg('type'));
  const memId = toDisplayText(getArg('memory_id') ?? getArg('id'));
  const taskVote = toDisplayText(getArg('result'));
  const taskComment = toDisplayText(getArg('comment'));
  const chainStatus = toDisplayText(getArg('status'));

  return (
    <div
      data-debug-id={`card-op-preview-${index}`}
      className="rounded-lg border border-subtle bg-surface-raised p-2.5 space-y-1.5"
    >
      <div className="flex flex-wrap items-center gap-2">
        <span className={`rounded px-1.5 py-0.5 text-[10px] font-mono border ${opBadgeTone}`}>
          {opName}
        </span>
        {/* REQ-UX-1: Human-readable label prominently shown */}
        <span className="text-xs font-medium text-primary">
          {humanLabel}
        </span>
      </div>

      {/* Structured details for memory/task operations (clean diff style) */}
      <div className="pl-2 border-l border-subtle space-y-1 text-[11px] text-muted">
        {memId && (
          <div>Target ID: <span className="font-mono text-primary">{memId}</span></div>
        )}
        {memTitle && (
          <div>Title: <span className="text-primary font-medium">"<VaultText value={memTitle} />"</span></div>
        )}
        {memType && (
          <div>Type: <span className="capitalize text-primary">{memType}</span></div>
        )}
        {memBody && (
          <div
            data-debug-id={`card-op-body-${index}`}
            className="text-primary bg-neutral-soft p-1.5 rounded break-words"
          >
            <DecryptedMarkdown source={memBody} compact copyAll={false} />
          </div>
        )}
        {taskVote && (
          <div>Vote: <span className="font-semibold text-accent">{String(taskVote).toUpperCase()}</span></div>
        )}
        {taskComment && (
          <div>Comment: <span className="italic text-primary">"<VaultText value={taskComment} />"</span></div>
        )}
        {chainStatus && (
          <div>Target Status: <span className="font-semibold text-accent">{chainStatus}</span></div>
        )}
      </div>
    </div>
  );
}
