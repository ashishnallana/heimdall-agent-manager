import React, { useEffect, useMemo, useState } from 'react';
import {
  Alert,
  Badge,
  Button,
  EmptyState,
  Icon,
  IconButton,
  Input,
  Select,
  Spinner,
  StatusPill,
  Text,
} from '@ui';
import { useIsMobile } from '../shell/responsive';
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
import { isVaultArmored, getActiveVaultKey } from '../../utils/vaultContent';
import { resolveCardTitle, UNTITLED_CARD } from '../../utils/vaultCardOps';
import { useSelector } from 'react-redux';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { decryptProjectList } from '../../utils/vaultProjects';
import { VaultText, DecryptedMarkdown } from '../vault/VaultText';
import { replaceVaultTokens } from '../../utils/vaultCrypto.ts';

const STATUS_TABS = [
  { id: 'pending', label: 'Pending' },
  { id: 'all', label: 'All' },
  { id: 'accepted', label: 'Accepted' },
  { id: 'rejected', label: 'Rejected' },
  { id: 'discarded', label: 'Discarded' },
  { id: 'snoozed', label: 'Snoozed' },
];

function formatRelativeTime(dateString: string): string {
  if (!dateString) return '';
  const date = new Date(dateString);
  if (Number.isNaN(date.getTime())) return dateString;
  const now = Date.now();
  const diffMs = now - date.getTime();
  const diffSec = Math.floor(diffMs / 1000);
  const diffMin = Math.floor(diffSec / 60);
  const diffHour = Math.floor(diffMin / 60);
  const diffDay = Math.floor(diffHour / 24);

  if (diffSec < 60) return 'just now';
  if (diffMin < 60) return `${diffMin}m ago`;
  if (diffHour < 24) return `${diffHour}h ago`;
  if (diffDay < 7) return `${diffDay}d ago`;
  return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

function cardStatusTone(status: string): 'warning' | 'success' | 'danger' | 'neutral' {
  switch (status) {
    case 'accepted':
      return 'success';
    case 'rejected':
      return 'danger';
    case 'discarded':
    case 'snoozed':
      return 'neutral';
    case 'pending':
    default:
      return 'warning';
  }
}

export function ActionItemsTab() {
  const isMobile = useIsMobile();
  const twoPane = !isMobile;

  const { data: cardsData, isLoading: cardsLoading, error: cardsError, refetch } = useListCardsQuery();
  const { data: projectsData } = useListProjectsQuery();

  const [acceptCard] = useAcceptCardMutation();
  const [rejectCard] = useRejectCardMutation();
  const [discardCard] = useDiscardCardMutation();
  const [snoozeCard] = useSnoozeCardMutation();

  const [searchQuery, setSearchQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState('pending');
  const [projectFilter, setProjectFilter] = useState('');
  const [selectedCardId, setSelectedCardId] = useState<string>('');
  const [processingId, setProcessingId] = useState<string | null>(null);
  const [feedback, setFeedback] = useState<{ type: 'success' | 'error'; message: string } | null>(null);

  const cards: Card[] = cardsData?.cards || [];
  const projects: Project[] = projectsData?.projects || [];

  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const [decryptedProjects, setDecryptedProjects] = useState<Project[]>(projects);

  useEffect(() => {
    let active = true;
    // Gate on the real non-extractable key, not the permanently-null raw hex:
    // the old `!rawKey` test was always true, so unlocked users saw ciphertext
    // placeholders for every project name (REQ-RAWKEY-A5).
    const activeKey = getActiveVaultKey();
    if (!isUnlocked || !activeKey) {
      setDecryptedProjects(
        projects.map((p) => ({
          ...p,
          name: p.name && isVaultArmored(p.name) ? replaceVaultTokens(p.name, '[🔒 Encrypted]') : p.name,
        }))
      );
      return;
    }
    decryptProjectList(projects, activeKey).then((res) => {
      if (active) setDecryptedProjects(res);
    }).catch(() => {
      if (active) setDecryptedProjects(projects);
    });
    return () => {
      active = false;
    };
  }, [projects, isUnlocked]);

  const projectMap = useMemo(() => {
    const map = new Map<string, Project>();
    for (const p of decryptedProjects) {
      map.set(p.project_id, p);
    }
    return map;
  }, [decryptedProjects]);

  const projectOptions = useMemo(() => {
    return [
      { value: '', label: 'All Projects' },
      ...decryptedProjects.map((p) => ({ value: p.project_id, label: p.name })),
    ];
  }, [decryptedProjects]);

  // Filter cards by status, project, and search query
  const filteredCards = useMemo(() => {
    return cards.filter((card) => {
      // Status filter
      if (statusFilter !== 'all' && card.status !== statusFilter) {
        return false;
      }

      // Project filter
      if (projectFilter && card.project_id !== projectFilter) {
        return false;
      }

      // Search query filter
      if (searchQuery.trim()) {
        const q = searchQuery.toLowerCase().trim();
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
        ]
          .filter(Boolean)
          .join(' ')
          .toLowerCase();

        if (!haystack.includes(q)) {
          return false;
        }
      }

      return true;
    });
  }, [cards, statusFilter, projectFilter, searchQuery, projectMap]);

  // Auto-select first card in two-pane mode if none selected or if selected is filtered out
  useEffect(() => {
    if (twoPane) {
      if (!selectedCardId && filteredCards.length > 0) {
        setSelectedCardId(filteredCards[0].card_id);
      } else if (selectedCardId && !filteredCards.some((c) => c.card_id === selectedCardId)) {
        setSelectedCardId(filteredCards.length > 0 ? filteredCards[0].card_id : '');
      }
    }
  }, [twoPane, selectedCardId, filteredCards]);

  const selectedCard = useMemo(() => {
    return cards.find((c) => c.card_id === selectedCardId) || null;
  }, [cards, selectedCardId]);

  // Actions
  const handleAccept = async (card: Card) => {
    setProcessingId(card.card_id);
    setFeedback(null);
    try {
      await acceptCard({ id: card.card_id }).unwrap();
      setFeedback({
        type: 'success',
        message: `Action accepted: "${await resolveCardTitle(card.title)}". Operations executed atomically.`,
      });
      setTimeout(() => setFeedback(null), 5000);
    } catch (err: any) {
      const msg = cardErrorText(err, 'Failed to accept card');
      setFeedback({
        type: 'error',
        message: `Failed to accept action: ${msg}`,
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
        message: `Action rejected: "${await resolveCardTitle(card.title)}".`,
      });
      setTimeout(() => setFeedback(null), 5000);
    } catch (err: any) {
      setFeedback({
        type: 'error',
        message: `Failed to reject action: ${cardErrorText(err, 'Reject failed')}`,
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
        message: `Action discarded: "${await resolveCardTitle(card.title)}".`,
      });
      setTimeout(() => setFeedback(null), 5000);
    } catch (err: any) {
      setFeedback({
        type: 'error',
        message: `Failed to discard action: ${cardErrorText(err, 'Discard failed')}`,
      });
    } finally {
      setProcessingId(null);
    }
  };

  const handleSnooze = async (card: Card) => {
    setProcessingId(card.card_id);
    setFeedback(null);
    try {
      const snoozeUntil = new Date(Date.now() + 24 * 3600 * 1000).toISOString();
      await snoozeCard({ id: card.card_id, snoozeUntil }).unwrap();
      setFeedback({
        type: 'success',
        message: `Action snoozed for 24h: "${await resolveCardTitle(card.title)}".`,
      });
      setTimeout(() => setFeedback(null), 5000);
    } catch (err: any) {
      setFeedback({
        type: 'error',
        message: `Failed to snooze action: ${cardErrorText(err, 'Snooze failed')}`,
      });
    } finally {
      setProcessingId(null);
    }
  };

  const listColumn = (
    <div
      data-debug-id="action-items-list-pane"
      className="flex flex-col h-full min-w-0 overflow-hidden"
    >
      {/* Search Input */}
      <div className="p-2 border-b border-subtle shrink-0">
        <Input
          value={searchQuery}
          onChange={setSearchQuery}
          width="full"
          leading={<Icon name="search" size="sm" />}
          placeholder="Search action cards…"
          size="sm"
          data-debug-id="action-items-search-input"
        />
      </div>

      {/* Filter Row: Status Pills & Project Dropdown */}
      <div className="px-2 py-1.5 border-b border-subtle flex flex-col gap-2 shrink-0">
        {/* Status Filter Chips */}
        <div
          data-debug-id="action-items-status-chips"
          className="flex items-center gap-1.5 overflow-x-auto py-0.5"
        >
          {STATUS_TABS.map((tab) => (
            <button
              key={tab.id}
              type="button"
              data-debug-id={`action-items-filter-${tab.id}`}
              onClick={() => setStatusFilter(tab.id)}
              className={`px-2.5 py-0.5 text-xs font-semibold rounded-full border transition-colors shrink-0 ${
                statusFilter === tab.id
                  ? 'bg-accent text-accent-fg border-accent'
                  : 'bg-surface text-muted border-subtle hover:text-primary hover:border-strong'
              }`}
            >
              {tab.label}
            </button>
          ))}
        </div>

        {/* Project Selector using @ui Select */}
        <div className="w-full">
          <Select
            value={projectFilter}
            onChange={setProjectFilter}
            size="sm"
            aria-label="Filter by project"
            data-debug-id="action-items-project-select"
            options={projectOptions}
          />
        </div>
      </div>

      {/* Card Items List */}
      <div className="flex-1 min-h-0 overflow-y-auto divide-y divide-subtle">
        {cardsLoading ? (
          <div className="p-8 text-center text-muted">
            <Spinner size="md" />
            <p className="mt-2 text-xs">Loading action items…</p>
          </div>
        ) : cardsError ? (
          <div className="p-4 text-center text-danger text-xs">
            <p>Failed to load action items</p>
            <button
              type="button"
              onClick={() => refetch()}
              className="mt-2 text-xs text-accent hover:underline"
            >
              Retry
            </button>
          </div>
        ) : filteredCards.length === 0 ? (
          <div className="p-8 text-center">
            <EmptyState
              icon="spark"
              title={
                searchQuery.trim()
                  ? 'No matching action items'
                  : statusFilter === 'pending'
                  ? 'No pending action cards'
                  : `No ${statusFilter} action cards`
              }
              description={
                searchQuery.trim()
                  ? `No action cards match query "${searchQuery}".`
                  : 'Curator synthesizes proactive recommendations as activity occurs across task chains.'
              }
              data-debug-id="action-items-empty-state"
            />
          </div>
        ) : (
          filteredCards.map((card) => {
            const isSelected = card.card_id === selectedCardId;
            const project = card.project_id ? projectMap.get(card.project_id) : null;
            const opCount = card.operations?.length || 0;
            const tone = cardStatusTone(card.status);

            return (
              <div
                key={card.card_id}
                data-debug-id={`action-items-card-row-${card.card_id}`}
                onClick={() => setSelectedCardId(card.card_id)}
                className={`p-3 cursor-pointer transition-colors duration-fast ${
                  isSelected
                    ? 'bg-surface-raised border-l-2 border-accent'
                    : 'hover:bg-surface-raised'
                }`}
              >
                <div className="flex items-start justify-between gap-2">
                  <h4 className="text-sm font-semibold text-primary line-clamp-1 flex-1">
                    <VaultText value={card.title} fallback={UNTITLED_CARD} as="span" />
                  </h4>
                  <StatusPill tone={tone} className="shrink-0 text-[10px]">
                    {card.status}
                  </StatusPill>
                </div>

                <div className="mt-1 flex flex-wrap items-center gap-2 text-caption text-muted">
                  <span className="inline-flex items-center gap-1">
                    <Icon name="folder" size={10} className="text-accent" />
                    <span><VaultText value={project?.name || 'Global'} as="span" /></span>
                  </span>

                  <span className="rounded-md border border-subtle bg-surface px-1.5 py-0.2 text-[10px]">
                    {opCount} {opCount === 1 ? 'op' : 'ops'}
                  </span>

                  <span className="text-[11px] ml-auto">
                    {formatRelativeTime(card.created_at || card.updated_at)}
                  </span>
                </div>
              </div>
            );
          })
        )}
      </div>

      {/* Bottom count indicator */}
      {!cardsLoading && !cardsError && (
        <div className="p-2 border-t border-subtle flex items-center justify-between text-caption text-muted shrink-0">
          <span>{filteredCards.length} {filteredCards.length === 1 ? 'card' : 'cards'}</span>
          <span>{statusFilter === 'all' ? 'All Cards' : `${statusFilter}`}</span>
        </div>
      )}
    </div>
  );

  // Detail View Content
  const detailContent = selectedCard ? (
    <div
      data-debug-id="action-items-detail-pane"
      className="space-y-5"
    >
      {/* Feedback Banner */}
      {feedback && (
        <Alert
          tone={feedback.type === 'success' ? 'success' : 'danger'}
          title={feedback.type === 'success' ? 'Success' : 'Error'}
          onDismiss={() => setFeedback(null)}
        >
          {feedback.message}
        </Alert>
      )}

      {/* Top Header & Actions Bar */}
      <div className="flex flex-col gap-3 border-b border-subtle pb-4">
        <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
          {/* Badges Cluster */}
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            <StatusPill tone={cardStatusTone(selectedCard.status)}>
              {selectedCard.status}
            </StatusPill>

            <Badge tone="neutral">
              {selectedCard.scope || 'project'}
            </Badge>

            <span className="inline-flex items-center gap-1 rounded-md border border-subtle bg-surface-raised px-2 py-0.5 text-caption text-muted">
              <Icon name="folder" size={11} className="text-accent" />
              <span><VaultText value={selectedCard.project_id ? (projectMap.get(selectedCard.project_id)?.name || selectedCard.project_id) : 'Global'} as="span" /></span>
            </span>

            <span className="inline-flex items-center gap-1 rounded-md border border-accent/30 bg-accent/10 px-2 py-0.5 text-caption text-accent font-medium">
              <Icon name="spark" size={11} />
              <span>{selectedCard.provider === 'curator_llm' ? 'Curator' : selectedCard.provider || 'System'}</span>
            </span>

            <span className="rounded-md border border-subtle bg-surface px-2 py-0.5 text-caption font-medium text-muted">
              {Math.round(selectedCard.confidence * 100)}% conf
            </span>
          </div>

          {/* Action Controls */}
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            {(selectedCard.status === 'pending' || selectedCard.status === 'snoozed') ? (
              <>
                <Button
                  variant="primary"
                  size="sm"
                  data-debug-id={`action-accept-btn-${selectedCard.card_id}`}
                  disabled={processingId === selectedCard.card_id}
                  onClick={() => handleAccept(selectedCard)}
                  leading={processingId === selectedCard.card_id ? <Spinner size="sm" /> : <Icon name="check" size={14} />}
                  className="min-h-[44px] sm:min-h-[36px]"
                >
                  Accept
                </Button>
                <Button
                  variant="secondary"
                  size="sm"
                  data-debug-id={`action-reject-btn-${selectedCard.card_id}`}
                  disabled={processingId === selectedCard.card_id}
                  onClick={() => handleReject(selectedCard)}
                  leading={<Icon name="close" size={14} />}
                  className="min-h-[44px] sm:min-h-[36px]"
                >
                  Reject
                </Button>
                <Button
                  variant="secondary"
                  size="sm"
                  data-debug-id={`action-snooze-btn-${selectedCard.card_id}`}
                  disabled={processingId === selectedCard.card_id}
                  onClick={() => handleSnooze(selectedCard)}
                  leading={<Icon name="clock" size={14} />}
                  className="min-h-[44px] sm:min-h-[36px]"
                >
                  Snooze 24h
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  data-debug-id={`action-discard-btn-${selectedCard.card_id}`}
                  disabled={processingId === selectedCard.card_id}
                  onClick={() => handleDiscard(selectedCard)}
                  leading={<Icon name="trash" size={14} />}
                  className="min-h-[44px] sm:min-h-[36px]"
                >
                  Discard
                </Button>
              </>
            ) : (
              <span className="text-xs text-muted italic">
                Card resolved as {selectedCard.status}
              </span>
            )}
          </div>
        </div>

        <div className="min-w-0 space-y-1.5">
          <h2
            data-debug-id="action-item-detail-title"
            className="text-xl sm:text-2xl font-bold tracking-tight text-primary break-words"
          >
            <VaultText value={selectedCard.title} fallback={UNTITLED_CARD} as="span" />
          </h2>
          <p className="text-caption font-mono text-muted">{selectedCard.card_id}</p>
        </div>
      </div>

      {/* Rationale Section */}
      <div
        data-debug-id="action-items-rationale"
        className="rounded-2xl border border-subtle bg-surface-raised p-4 space-y-2"
      >
        <h4 className="text-caption font-semibold uppercase tracking-wider text-muted flex items-center gap-1.5">
          <Icon name="spark" size={12} className="text-accent" />
          <span>Rationale & Summary</span>
        </h4>
        <div className="text-body-sm text-primary leading-relaxed">
          <DecryptedMarkdown source={selectedCard.rationale || '_No rationale provided._'} />
        </div>
      </div>

      {/* Operations Breakdown Section */}
      <div
        data-debug-id="action-items-operations"
        className="rounded-2xl border border-subtle bg-surface-raised p-4 space-y-3"
      >
        <div className="flex items-center justify-between">
          <h4 className="text-caption font-semibold uppercase tracking-wider text-muted flex items-center gap-1.5">
            <Icon name="tasks" size={12} className="text-accent" />
            <span>Operations Breakdown ({selectedCard.operations?.length || 0})</span>
          </h4>
        </div>

        {(!selectedCard.operations || selectedCard.operations.length === 0) ? (
          <p className="text-caption text-muted italic">No automated operations attached.</p>
        ) : (
          <div className="space-y-2">
            {selectedCard.operations.map((op, idx) => (
              <OperationPreviewRow key={idx} op={op} index={idx} />
            ))}
          </div>
        )}
      </div>

      {/* Details & Scope Section */}
      <div className="rounded-2xl border border-subtle bg-surface-raised p-4 space-y-3">
        <h4 className="text-caption font-semibold uppercase tracking-wider text-muted">
          Details & Scope
        </h4>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 text-caption">
          <div>
            <span className="text-muted">Scope:</span>{' '}
            <span className="font-semibold text-primary capitalize">{selectedCard.scope || 'project'}</span>
          </div>

          <div>
            <span className="text-muted">Provider:</span>{' '}
            <span className="font-semibold text-primary">{selectedCard.provider || 'curator_llm'}</span>
          </div>

          <div>
            <span className="text-muted">Created:</span>{' '}
            <span className="text-primary">{formatRelativeTime(selectedCard.created_at)}</span>
          </div>

          <div>
            <span className="text-muted">Updated:</span>{' '}
            <span className="text-primary">{formatRelativeTime(selectedCard.updated_at)}</span>
          </div>

          {selectedCard.snooze_until && (
            <div>
              <span className="text-muted">Snoozed Until:</span>{' '}
              <span className="text-warning font-mono">{selectedCard.snooze_until}</span>
            </div>
          )}

          {selectedCard.ttl_at && (
            <div>
              <span className="text-muted">Expires At:</span>{' '}
              <span className="text-muted font-mono">{selectedCard.ttl_at}</span>
            </div>
          )}
        </div>

        {/* Source References */}
        {selectedCard.source_refs && selectedCard.source_refs.length > 0 && (
          <div className="pt-2 border-t border-subtle flex flex-wrap items-center gap-1.5">
            <span className="text-muted text-caption">Evidence:</span>
            {selectedCard.source_refs.map((refId, i) => (
              <span
                key={i}
                className="rounded-md border border-subtle bg-surface px-2 py-0.5 font-mono text-[11px] text-muted"
              >
                {formatSourceRef(refId)}
              </span>
            ))}
          </div>
        )}
      </div>
    </div>
  ) : (
    <div className="flex h-full items-center justify-center p-6 text-muted">
      <Text role="body-sm" tone="muted">Select an action item to see its details.</Text>
    </div>
  );

  // Mobile View
  if (isMobile) {
    if (selectedCardId && selectedCard) {
      return (
        <div
          data-debug-id="action-items-tab"
          className="flex flex-col h-full min-h-0 w-full overflow-hidden"
          style={{
            paddingBottom: 'calc(max(var(--ui-bottom-chrome, 0px), env(safe-area-inset-bottom, 0px)) + var(--space-2))',
          }}
        >
          <div className="p-2 border-b border-subtle shrink-0">
            <Button
              variant="ghost"
              size="sm"
              data-debug-id="action-items-back-btn"
              onClick={() => setSelectedCardId('')}
              className="gap-1.5 min-h-[44px]"
            >
              <Icon name="chevron-left" size={16} />
              <span>Back to action items</span>
            </Button>
          </div>
          <div className="flex-1 min-h-0 overflow-y-auto p-3">
            {detailContent}
          </div>
        </div>
      );
    }

    return (
      <div
        data-debug-id="action-items-tab"
        className="flex flex-col h-full min-h-0 w-full overflow-hidden rounded-2xl border border-subtle bg-surface"
        style={{
          paddingBottom: 'calc(max(var(--ui-bottom-chrome, 0px), env(safe-area-inset-bottom, 0px)) + var(--space-2))',
        }}
      >
        {listColumn}
      </div>
    );
  }

  // Desktop Two-Pane View
  return (
    <div
      data-debug-id="action-items-tab"
      className="flex min-w-0 items-stretch gap-4 flex-1 min-h-0 h-full overflow-hidden"
    >
      {/* Left Column */}
      <div className="w-full min-w-0 max-w-[420px] shrink-0 flex flex-col min-h-0 h-full overflow-hidden rounded-2xl border border-subtle bg-surface">
        {listColumn}
      </div>

      {/* Right Column */}
      <div
        data-debug-id="action-items-detail-scroll-pane"
        className="min-w-0 flex-1 rounded-2xl border border-subtle bg-surface p-4 flex flex-col min-h-0 h-full overflow-y-auto"
      >
        {detailContent}
      </div>
    </div>
  );
}

// Subcomponent: Operation preview row
function OperationPreviewRow({ op, index }: { op: CardOperation; index: number }) {
  const humanLabel = formatOpLabel(op);
  const opName = op.op || 'operation';

  const opBadgeTone =
    opName.startsWith('memory.create') ? 'border-success/30 bg-success-soft text-success' :
    opName.startsWith('memory.delete') || opName.startsWith('memory.archive') ? 'border-danger/30 bg-danger-soft text-danger' :
    opName.startsWith('memory.update') ? 'border-warning/30 bg-warning-soft text-warning' :
    opName.startsWith('task.vote') ? 'border-accent/30 bg-accent/10 text-accent' :
    opName.startsWith('task_chain') ? 'border-accent/30 bg-accent/10 text-accent' :
    'border-subtle bg-surface-raised text-muted';

  const getArg = (k: string) => op.args?.[k] ?? op[k];

  const memTitle = toDisplayText(getArg('title'));
  const memBody = toDisplayText(getArg('body'));
  const memType = toDisplayText(getArg('type'));
  const memId = toDisplayText(getArg('memory_id') ?? getArg('id'));
  const taskVote = toDisplayText(getArg('result'));
  const taskComment = toDisplayText(getArg('comment'));
  const chainStatus = toDisplayText(getArg('status'));

  return (
    <div
      data-debug-id={`action-op-row-${index}`}
      className="rounded-xl border border-subtle bg-surface p-3 space-y-2"
    >
      <div className="flex flex-wrap items-center gap-2">
        <span className={`rounded px-1.5 py-0.5 text-[10px] font-mono border ${opBadgeTone}`}>
          {opName}
        </span>
        <span className="text-xs font-semibold text-primary">
          {humanLabel}
        </span>
      </div>

      <div className="pl-2 border-l border-subtle space-y-1 text-caption text-muted">
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
          <div className="text-primary bg-neutral-soft p-2 rounded-lg break-words mt-1">
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

export default ActionItemsTab;
