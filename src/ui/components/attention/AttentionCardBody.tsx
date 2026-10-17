import { Icon } from '@ui';
import { DecryptedMarkdown, VaultText } from '../vault';
import type { AttentionItem, AttentionMessageItem, AttentionTaskItem } from '../../api/endpoints/attention';
import { PRIORITY_LABELS, formatAge, reasonLine, urgencyClass } from './attentionModel';

/**
 * The read-only part of an attention card: why it is here, where it comes from,
 * what it is about, and one excerpt. Everything shown is human-readable -- ids are
 * only ever used for actions, never rendered. Text that may be vault ciphertext
 * goes through the vault helpers (masked until decrypted, a lock placeholder when
 * the vault is locked).
 */
export function AttentionCardBody({ item, now, children }: { item: AttentionItem; now: number; children?: React.ReactNode }) {
  return (
    <article data-debug-id={`attention-card-${item.kind}`} aria-label={item.kind === 'task' ? 'Task waiting on your review' : 'Agent question'} className="flex h-full min-h-0 flex-col">
      <p data-debug-id="attention-card-reason" className={`text-[13px] font-semibold ${urgencyClass(item.urgency)}`}>
        {reasonLine(item, now)}
      </p>
      <p data-debug-id="attention-card-source" className="mt-1 flex min-w-0 items-center gap-1.5 text-[12px] text-muted">
        <Icon name={item.kind === 'task' ? 'tasks' : 'chat'} size={14} />
        {item.context.chain_title ? <VaultText value={item.context.chain_title} className="truncate" /> : null}
        {item.context.chain_title && item.context.agent_name ? <span aria-hidden="true" className="text-faint">›</span> : null}
        {item.context.agent_name ? <span className="truncate">{item.context.agent_name}</span> : null}
      </p>
      {/* touch-pan-y: this is its own scroll container, so it must also leave
          horizontal gestures to the deck's swipe (or the browser claims them). */}
      <div className="mt-3 min-h-0 flex-1 touch-pan-y overflow-y-auto pr-1">
        {item.kind === 'task' ? <TaskBody item={item} now={now} /> : <MessageBody item={item} now={now} />}
        {children}
      </div>
    </article>
  );
}

function TaskBody({ item, now }: { item: AttentionTaskItem; now: number }) {
  const d = item.details;
  return (
    <>
      <h3 data-debug-id="attention-card-title" className="text-[17px] font-semibold leading-snug text-primary">
        <VaultText value={item.title} fallback="Untitled task" />
      </h3>
      <ul data-debug-id="attention-card-facts" className="mt-2 flex flex-wrap gap-1.5">
        <li className="rounded-[var(--radius-sm)] bg-surface-raised px-1.5 py-0.5 text-[11px] text-muted">{PRIORITY_LABELS[d.priority] || 'Normal priority'}</li>
        <li className="rounded-[var(--radius-sm)] bg-info-soft px-1.5 py-0.5 text-[11px] text-info">Waiting on review</li>
        {d.assignee_name ? <li className="rounded-[var(--radius-sm)] bg-surface-raised px-1.5 py-0.5 text-[11px] text-muted">by {d.assignee_name}</li> : null}
      </ul>
      {d.excerpt ? (
        <blockquote data-debug-id="attention-card-excerpt" className="mt-3 border-l-2 border-subtle pl-3 text-[13px] text-primary">
          <span className="mb-1 block text-[11px] text-faint">
            {d.excerpt.author_name || 'Latest comment'}
            {d.excerpt.at ? ` · ${formatAge(d.excerpt.at, now)} ago` : ''}
          </span>
          <DecryptedMarkdown source={d.excerpt.body} compact copyAll={false} data-debug-id="attention-card-excerpt-body" />
        </blockquote>
      ) : (
        <p className="mt-3 text-[12px] text-faint">No comments yet.</p>
      )}
    </>
  );
}

function MessageBody({ item, now }: { item: AttentionMessageItem; now: number }) {
  const d = item.details;
  return (
    <>
      <div data-debug-id="attention-card-message" className="rounded-[var(--radius-md)] rounded-bl-sm border border-subtle bg-surface-raised px-3 py-2 text-[13px] text-primary">
        <span className="mb-1 block text-[11px] text-faint">
          {d.excerpt.author_name || item.context.agent_name || 'Agent'}
          {d.excerpt.at ? ` · ${formatAge(d.excerpt.at, now)} ago` : ''}
        </span>
        <DecryptedMarkdown source={d.excerpt.body} compact copyAll={false} data-debug-id="attention-card-message-body" />
      </div>
      {d.other_unread > 0 ? (
        <p data-debug-id="attention-card-other-unread" className="mt-2 text-[12px] text-faint">
          +{d.other_unread} more unread {d.other_unread === 1 ? 'message' : 'messages'} in this conversation
        </p>
      ) : null}
    </>
  );
}
