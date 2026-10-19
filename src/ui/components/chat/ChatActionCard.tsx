import React, { useState, useMemo } from 'react';
import {
  useGetCardQuery,
  useAcceptCardMutation,
  useDiscardCardMutation,
  formatOpLabel,
  cardErrorText,
} from '../../api/endpoints/cards';
import type { Card } from '../../api/endpoints/cards';
import { useSendConversationMessageMutation } from '../../api/endpoints/chats';
import { resolveCardTitle, UNTITLED_CARD } from '../../utils/vaultCardOps';
import { VaultText } from '../vault/VaultText';
import { extractMessageActionIds } from './types';
import { buildActionFeedback } from './actionFeedback';

export interface SingleActionCardProps {
  actionId: string;
  card?: Card | null;
  conversationId?: string;
  onReply?: (reply: string) => void;
  onSendFeedback?: (body: string) => Promise<void> | void;
  className?: string;
}

export const SingleActionCard: React.FC<SingleActionCardProps> = ({
  actionId,
  card: initialCard,
  conversationId,
  onReply,
  onSendFeedback,
  className = '',
}) => {
  const [comment, setComment] = useState('');
  const [localStatus, setLocalStatus] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  const { data: cardData, isLoading: isCardLoading } = useGetCardQuery(
    { cardId: actionId, id: actionId },
    { skip: !actionId || Boolean(initialCard) }
  );

  const [acceptCardMutation, { isLoading: isAccepting }] = useAcceptCardMutation();
  const [discardCardMutation, { isLoading: isDiscarding }] = useDiscardCardMutation();
  const [sendMessageMutation, { isLoading: isSending }] = useSendConversationMessageMutation();

  const card = initialCard || cardData?.card;

  const operationsSummary = useMemo(() => {
    if (card?.operations && Array.isArray(card.operations) && card.operations.length > 0) {
      return card.operations.map((op) => formatOpLabel(op, { withIds: false })).join('; ');
    }
    return '';
  }, [card?.operations]);

  const rawStatus = (localStatus || card?.status || 'pending').toLowerCase();
  const status: 'pending' | 'accepted' | 'rejected' =
    rawStatus === 'accepted'
      ? 'accepted'
      : rawStatus === 'rejected' || rawStatus === 'discarded'
      ? 'rejected'
      : 'pending';

  const isResolved = status === 'accepted' || status === 'rejected';
  const isBusy = isAccepting || isDiscarding || isSending;

  const sendFeedback = async (body: string) => {
    if (onSendFeedback) {
      await onSendFeedback(body);
    } else if (onReply) {
      onReply(body);
    } else if (conversationId) {
      await sendMessageMutation({ conversationId, body });
    }
  };

  const handleApprove = async () => {
    if (isResolved || isBusy) return;
    setActionError(null);
    try {
      await acceptCardMutation({ cardId: actionId, id: actionId }).unwrap();
      setLocalStatus('accepted');
      const title = await resolveCardTitle(card?.title);
      await sendFeedback(buildActionFeedback('approved', actionId, title));
    } catch (err: any) {
      setActionError(cardErrorText(err, 'Failed to approve action'));
    }
  };

  const handleReject = async () => {
    if (isResolved || isBusy) return;
    setActionError(null);
    try {
      await discardCardMutation({ cardId: actionId, id: actionId }).unwrap();
      setLocalStatus('rejected');
      const title = await resolveCardTitle(card?.title);
      await sendFeedback(buildActionFeedback('rejected', actionId, title, comment));
    } catch (err: any) {
      setActionError(cardErrorText(err, 'Failed to reject action'));
    }
  };

  return (
    <div
      data-debug-id={`action-card-${actionId}`}
      className={`rounded-lg border border-subtle bg-surface-raised/80 px-3 py-2 my-1.5 shadow-sm flex flex-col gap-1.5 text-left text-sm ${className}`}
    >
      <div className="flex items-center justify-between gap-2">
        <h4 data-debug-id={`action-card-title-${actionId}`} className="min-w-0 font-semibold text-primary break-words text-sm">
          <VaultText value={card?.title} fallback={UNTITLED_CARD} as="span" />
        </h4>
        <span
          data-debug-id={`action-card-status-${actionId}`}
          className={`shrink-0 inline-flex items-center rounded-full px-2 py-px text-[11px] font-medium border capitalize ${
            status === 'accepted'
              ? 'border-success/40 bg-success-soft text-success'
              : status === 'rejected'
              ? 'border-danger/40 bg-danger-soft text-danger'
              : 'border-warning/40 bg-warning/10 text-warning'
          }`}
        >
          {status}
        </span>
      </div>

      {operationsSummary ? (
        <div data-debug-id={`action-card-summary-${actionId}`} className="text-xs text-muted leading-snug break-words">
          {operationsSummary}
        </div>
      ) : isCardLoading ? (
        <div className="text-xs text-muted">Loading…</div>
      ) : null}

      {actionError ? (
        <div className="text-xs text-danger rounded bg-danger/10 border border-danger/30 px-2 py-1">
          {actionError}
        </div>
      ) : null}

      {!isResolved && (
        <div className="flex items-center gap-1.5">
          <input
            type="text"
            data-debug-id={`action-card-comment-input-${actionId}`}
            placeholder="Optional reason…"
            value={comment}
            onChange={(e) => setComment(e.target.value)}
            disabled={isBusy}
            className="min-w-0 flex-1 rounded-md border border-subtle bg-surface px-2 py-1 text-xs text-primary placeholder-muted/60 focus:border-accent focus:outline-none disabled:opacity-50"
          />
          <button
            type="button"
            data-debug-id={`action-card-reject-btn-${actionId}`}
            onClick={handleReject}
            disabled={isBusy}
            className="shrink-0 rounded-md border border-subtle bg-surface px-2.5 py-1 text-xs font-medium text-muted hover:text-danger hover:border-danger/40 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {isDiscarding ? 'Rejecting…' : 'Reject'}
          </button>
          <button
            type="button"
            data-debug-id={`action-card-approve-btn-${actionId}`}
            onClick={handleApprove}
            disabled={isBusy}
            className="shrink-0 rounded-md bg-accent px-2.5 py-1 text-xs font-medium text-white hover:bg-accent/90 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {isAccepting ? 'Approving…' : 'Approve'}
          </button>
        </div>
      )}
    </div>
  );
};

export interface ChatActionCardProps {
  message?: {
    messageId?: string;
    id?: string;
    conversationId?: string;
    metadata?: any;
    metadata_json?: string;
    [key: string]: any;
  };
  actionId?: string;
  card?: Card | null;
  conversationId?: string;
  onReply?: (reply: string) => void;
  onSendFeedback?: (body: string) => Promise<void> | void;
  className?: string;
}

export const ChatActionCard: React.FC<ChatActionCardProps> = ({
  message,
  actionId,
  card,
  conversationId,
  onReply,
  onSendFeedback,
  className = '',
}) => {
  if (actionId) {
    return (
      <SingleActionCard
        actionId={actionId}
        card={card}
        conversationId={conversationId || message?.conversationId}
        onReply={onReply}
        onSendFeedback={onSendFeedback}
        className={className}
      />
    );
  }

  if (!message) return null;

  const actionIds = extractMessageActionIds(message);
  if (actionIds.length === 0) return null;

  const effectiveConvId = conversationId || message.conversationId;

  return (
    <div className={`chat-action-cards flex flex-col gap-2 w-full mt-2 ${className}`}>
      {actionIds.map((actId) => (
        <SingleActionCard
          key={actId}
          actionId={actId}
          conversationId={effectiveConvId}
          onReply={onReply}
          onSendFeedback={onSendFeedback}
        />
      ))}
    </div>
  );
};

export default ChatActionCard;
