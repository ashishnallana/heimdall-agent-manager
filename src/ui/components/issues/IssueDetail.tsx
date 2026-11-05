import React, { useState, useEffect } from 'react';
import {
  ActionButton,
  Alert,
  Badge,
  Button,
  Icon,
  Panel,
  ResourceDetailHeader,
  ResourceSectionCard,
  Select,
  StatusPill,
  Text,
  Textarea,
  useViewport,
} from '@ui';
import type { Issue } from '../../api/endpoints/issues';
import {
  useAddIssueCommentMutation,
  useDeleteIssueCommentMutation,
  useDeleteIssueMutation,
  useGetIssueQuery,
  useListIssueCommentsQuery,
  useUpdateIssueMutation,
  useVoteIssueMutation,
  useUnvoteIssueMutation,
} from '../../api/endpoints/issues';
import MarkdownBody from '../MarkdownBody';
import { useSelector } from 'react-redux';
import { selectActiveVaultKey } from '../../store/vaultSlice';
import { isVaultArmored } from '../../utils/vaultContent';
import { VaultText, DecryptedMarkdown } from '../vault/VaultText';
import {
  absoluteTime,
  issueEditHref,
  issueSnippet,
  issueStatus,
  issueTitle,
  navigateTo,
  relativeTime,
  scopeLabel,
  scopeTone,
  statusLabel,
  statusTone,
} from './issueModel';

export interface IssueDetailProps {
  issueId: string;
  onBack?: () => void;
  onEdit?: (issue: Issue) => void;
  onDelete?: (issue: Issue) => void;
}

// DecryptedMarkdown resolves the active CryptoKey itself and passes unarmored text
// through untouched, so this needs no key or lock props of its own.
function IssueCommentContent({ body }: { body: string }) {
  return <DecryptedMarkdown source={body} />;
}

export function IssueDetail({ issueId, onBack, onEdit, onDelete }: IssueDetailProps) {
  const viewport = useViewport();
  const isMobile = viewport === 'mobile';

  // Key material lives only as a non-extractable CryptoKey (REQ-VAULT-HARDEN-1):
  // state.vault.rawVaultKeyHex is never assigned, so the old selectRawVaultKeyHex
  // always returned null. The comment gate below tests the real key, so a vault that
  // reports unlocked without a key now shows the unlock placeholder, not ciphertext.
  const activeKey = useSelector(selectActiveVaultKey);

  const { data: issue, isLoading, error } = useGetIssueQuery({ issueId }, { skip: !issueId });
  const embeddedComments = issue?.comments || [];
  const { data: fetchedComments, isLoading: commentsQueryLoading } = useListIssueCommentsQuery({ issueId }, { skip: !issueId });
  const comments = fetchedComments !== undefined ? fetchedComments : embeddedComments;
  const commentsLoading = commentsQueryLoading && embeddedComments.length === 0;


  const [updateIssue, { isLoading: isUpdatingStatus }] = useUpdateIssueMutation();
  const [deleteIssue, { isLoading: isDeleting }] = useDeleteIssueMutation();
  const [voteIssue, { isLoading: isVoting }] = useVoteIssueMutation();
  const [unvoteIssue, { isLoading: isUnvoting }] = useUnvoteIssueMutation();
  const [addComment, { isLoading: isAddingComment }] = useAddIssueCommentMutation();
  const [deleteComment] = useDeleteIssueCommentMutation();

  const [commentText, setCommentText] = useState('');
  const [commentError, setCommentError] = useState('');
  const [actionError, setActionError] = useState('');

  if (isLoading) {
    return (
      <div className="flex h-full items-center justify-center p-8 text-muted">
        <Icon name="refresh" className="animate-spin mr-2" size={18} />
        <span>Loading issue details...</span>
      </div>
    );
  }

  if (error || !issue) {
    return (
      <div className="p-6">
        <Alert tone="danger" title="Issue not found">
          {error ? String((error as any)?.error || error) : `Issue ${issueId} could not be loaded.`}
        </Alert>
        {onBack ? (
          <Button variant="secondary" className="mt-4" onClick={onBack}>
            Back to list
          </Button>
        ) : null}
      </div>
    );
  }

  const status = issueStatus(issue);
  const title = issueTitle(issue);
  const scopeType = String(issue.scope_type || issue.scopeType || 'global');
  const targetId = String(issue.target_id || issue.targetId || '');
  const chainId = String(issue.chain_id || issue.chainId || '');
  const createdBy = String(issue.created_by || issue.createdBy || '');
  const voteCount = Number(issue.vote_count ?? issue.voteCount ?? 0);
  const hasVoted = Boolean(issue.has_voted ?? issue.hasVoted);
  const createdAt = String(issue.created_at || issue.createdAt || '');
  const updatedAt = String(issue.updated_at || issue.updatedAt || '');
  const closedAt = String(issue.closed_at || issue.closedAt || '');

  const handleStatusChange = async (newStatus: string) => {
    setActionError('');
    try {
      await updateIssue({ issueId, status: newStatus }).unwrap();
    } catch (err: any) {
      setActionError(String(err?.data?.message || err?.message || 'Failed to update status'));
    }
  };

  const handleVoteToggle = async () => {
    setActionError('');
    try {
      if (hasVoted) {
        await unvoteIssue({ issueId }).unwrap();
      } else {
        await voteIssue({ issueId }).unwrap();
      }
    } catch (err: any) {
      setActionError(String(err?.data?.message || err?.message || 'Failed to update vote'));
    }
  };

  const handleDelete = async () => {
    if (!window.confirm(`Are you sure you want to delete issue "${title}"?`)) return;
    setActionError('');
    try {
      await deleteIssue({ issueId }).unwrap();
      if (onDelete) {
        onDelete(issue);
      } else {
        navigateTo('#/issues');
      }
    } catch (err: any) {
      setActionError(String(err?.data?.message || err?.message || 'Failed to delete issue'));
    }
  };

  const handleEdit = () => {
    if (onEdit) {
      onEdit(issue);
    } else {
      navigateTo(issueEditHref(issueId));
    }
  };

  const handleAddComment = async (e?: React.FormEvent) => {
    if (e) e.preventDefault();
    const text = commentText.trim();
    if (!text) return;
    setCommentError('');
    try {
      await addComment({ issueId, body: text }).unwrap();
      setCommentText('');
    } catch (err: any) {
      setCommentError(String(err?.data?.message || err?.message || 'Failed to post comment'));
    }
  };

  const handleDeleteComment = async (commentId: string) => {
    if (!window.confirm('Delete this comment?')) return;
    try {
      await deleteComment({ issueId, commentId }).unwrap();
    } catch (err: any) {
      alert(String(err?.data?.message || err?.message || 'Failed to delete comment'));
    }
  };

  return (
    <div className="flex flex-col h-full overflow-y-auto p-4 sm:p-6 space-y-6" data-debug-id={`issue-detail-${issueId}`}>
      {/* Header section: Title, badges, and primary action controls */}
      <ResourceDetailHeader
        dataDebugId={`issue-detail-header-${issueId}`}
        onBack={isMobile && onBack ? onBack : undefined}
        backLabel="All issues"
        alert={
          actionError ? (
            <Alert tone="danger" title="Action Error">
              {actionError}
            </Alert>
          ) : null
        }
        title={<VaultText value={title} as="span" />}
        id={issueId}
        status={<StatusPill tone={statusTone(status)}>{statusLabel(status)}</StatusPill>}
        badges={
          <Badge tone={scopeTone(scopeType)}>
            {scopeLabel(scopeType)}{targetId ? `: ${targetId}` : ''}
          </Badge>
        }
        timestamp={`Reported ${relativeTime(createdAt)} ${createdBy ? `by ${createdBy}` : ''}`}
        timestampTooltip={absoluteTime(createdAt)}
        actions={
          <div className="flex flex-wrap items-center gap-2 shrink-0">
            {/* Vote Toggle Button */}
            <Button
              variant={hasVoted ? 'primary' : 'secondary'}
              size="sm"
              onClick={handleVoteToggle}
              disabled={isVoting || isUnvoting}
              title={hasVoted ? 'Click to unvote' : 'Click to upvote'}
              data-debug-id="issue-detail-vote-button"
              className="gap-2"
            >
              <Icon name="arrow-up" size={14} className={hasVoted ? 'text-white' : 'text-accent'} />
              <span>{hasVoted ? 'Upvoted' : 'Upvote'}</span>
              <span className="rounded-full bg-neutral-soft px-1.5 py-0.2 text-xs font-mono font-bold">
                {voteCount}
              </span>
            </Button>

            {/* Status Select dropdown */}
            <div className="w-32">
              <Select
                value={status}
                disabled={isUpdatingStatus}
                onChange={handleStatusChange}
                size="sm"
                aria-label="Change issue status"
                options={[
                  { value: 'new', label: 'New' },
                  { value: 'fixed', label: 'Fixed' },
                  { value: 'obsolete', label: 'Obsolete' },
                ]}
              />
            </div>

            <Button variant="secondary" size="sm" onClick={handleEdit} data-debug-id="issue-detail-edit-button">
              <Icon name="pencil" size={14} className="mr-1.5" />
              <span>Edit</span>
            </Button>

            <ActionButton
              label="Delete Issue"
              variant="danger"
              loading={isDeleting}
              disabled={isDeleting}
              data-debug-id="issue-detail-delete-item"
              onClick={handleDelete}
            />
          </div>
        }
      />

      {/* Task chain context link card (if chain_id is set) */}
      {chainId ? (
        <Panel data-debug-id="issue-chain-context" className="p-4 rounded-xl border border-accent/20 bg-accent/5">
          <div className="flex items-start gap-3">
            <div className="p-2 rounded-lg bg-accent/10 text-accent shrink-0">
              <Icon name="tasks" size={20} />
            </div>
            <div className="min-w-0 flex-1">
              <div className="flex items-center gap-2">
                <h4 className="text-sm font-semibold text-primary">Found in Task Chain</h4>
                <Badge tone="info">Context</Badge>
              </div>
              <p className="text-xs text-muted mt-1">
                This issue was discovered while running chain{' '}
                <a
                  href={`#/chains/${encodeURIComponent(chainId)}`}
                  className="font-mono text-accent hover:underline font-semibold"
                >
                  {chainId}
                </a>
                .
              </p>
              <div className="mt-2">
                <a
                  href={`#/chains/${encodeURIComponent(chainId)}`}
                  className="inline-flex items-center gap-1 text-xs text-accent font-medium hover:underline"
                >
                  <span>Open Task Chain</span>
                  <Icon name="arrow-right" size={12} />
                </a>
              </div>
            </div>
          </div>
        </Panel>
      ) : null}

      {/* Description Section */}
      <ResourceSectionCard title="Description" dataDebugId="issue-description-card">
        {issue.description ? (
          <div className="prose prose-invert max-w-none text-sm text-primary">
            <DecryptedMarkdown source={issue.description} />
          </div>
        ) : (
          <p className="italic text-muted text-sm">No description provided.</p>
        )}
      </ResourceSectionCard>

      {/* Metadata / Scope Details */}
      <ResourceSectionCard title="Details & Scope" dataDebugId="issue-metadata-card">
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 text-xs">
          <div>
            <span className="text-muted block mb-0.5">Scope</span>
            <span className="font-medium text-primary capitalize">{scopeLabel(scopeType)}</span>
          </div>
          {targetId ? (
            <div>
              <span className="text-muted block mb-0.5">Target Identifier</span>
              <span className="font-mono text-primary">{targetId}</span>
            </div>
          ) : null}
          <div>
            <span className="text-muted block mb-0.5">Created By</span>
            <span className="font-medium text-primary">{createdBy || 'User'}</span>
          </div>
          <div>
            <span className="text-muted block mb-0.5">Last Updated</span>
            <span className="text-primary">{absoluteTime(updatedAt)}</span>
          </div>
          {closedAt ? (
            <div>
              <span className="text-muted block mb-0.5">Closed At</span>
              <span className="text-primary">{absoluteTime(closedAt)}</span>
            </div>
          ) : null}
        </div>
      </ResourceSectionCard>

      {/* Threaded Comments Section */}
      <ResourceSectionCard
        title={`Discussion (${comments.length})`}
        dataDebugId="issue-comments-section"
      >
        <div className="space-y-4">
          {commentsLoading ? (
            <p className="text-xs text-muted">Loading comments...</p>
          ) : comments.length === 0 ? (
            <p className="text-xs text-muted italic">No comments yet. Be the first to chime in.</p>
          ) : (
            <div className="space-y-3 divide-y divide-subtle">
              {comments.map((comment) => (
                <div key={comment.comment_id || comment.id} className="pt-3 first:pt-0">
                  <div className="flex items-center justify-between gap-2 mb-1.5">
                    <div className="flex items-center gap-2 text-xs">
                      <span className="font-semibold text-primary">
                        {comment.author_name || comment.author_id || 'Participant'}
                      </span>
                      <span className="text-muted">·</span>
                      <span className="text-muted" title={absoluteTime(comment.created_at || comment.createdAt)}>
                        {relativeTime(comment.created_at || comment.createdAt)}
                      </span>
                    </div>
                    <button
                      type="button"
                      title="Delete comment"
                      onClick={() => handleDeleteComment(comment.comment_id || comment.id)}
                      className="text-muted hover:text-danger p-1 rounded transition-colors"
                    >
                      <Icon name="trash" size={13} />
                    </button>
                  </div>
                  <div className="prose prose-invert text-xs max-w-none text-secondary">
                    {isVaultArmored(comment.body) && !activeKey ? (
                      <VaultText value={comment.body} as="div" />
                    ) : (
                      <IssueCommentContent body={comment.body} />
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}

          {/* Comment Composer */}
          <form onSubmit={handleAddComment} className="mt-4 pt-3 border-t border-subtle">
            {commentError ? (
              <Alert tone="danger" title="Error" className="mb-2">
                {commentError}
              </Alert>
            ) : null}
            <div className="space-y-2">
              <Textarea
                value={commentText}
                onChange={setCommentText}
                placeholder="Leave a comment (supports markdown)..."
                rows={3}
                width="full"
                className="w-full"
                onKeyDown={(e) => {
                  if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
                    e.preventDefault();
                    handleAddComment();
                  }
                }}
              />
              <div className="flex items-center justify-between">
                <span className="text-[11px] text-muted">Press Ctrl+Enter to submit</span>
                <Button
                  type="submit"
                  variant="primary"
                  size="sm"
                  disabled={!commentText.trim() || isAddingComment}
                  loading={isAddingComment}
                >
                  <Icon name="chat" size={14} className="mr-1.5" />
                  <span>Comment</span>
                </Button>
              </div>
            </div>
          </form>
        </div>
      </ResourceSectionCard>
    </div>
  );
}

export default IssueDetail;
