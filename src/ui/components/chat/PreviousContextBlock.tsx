import React from 'react';
import { Icon, Text } from '@ui';

/**
 * previous_context messages (T5/T6 context rollover): the handoff an agent
 * wrote for its own restarted session. The hub stores it inbound
 * (user_to_agent), but it is agent-authored reference material, so the
 * transcript shows it as a full-width block that stays collapsed until opened.
 */
export const PREVIOUS_CONTEXT_MESSAGE_TYPE = 'previous_context';

export function isPreviousContextMessage(message: { messageType?: string; message_type?: string }): boolean {
  return String(message.messageType || message.message_type || '') === PREVIOUS_CONTEXT_MESSAGE_TYPE;
}

function finiteNumber(value: unknown): number | null {
  if (value === null || value === undefined || value === '') return null;
  const n = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(n) && n > 0 ? n : null;
}

/** 200000 -> "200K", 1000000 -> "1M", 475000 -> "475K", 1500000 -> "1.5M". */
export function formatContextWindow(tokens: number): string {
  if (tokens >= 1_000_000) return `${trimDecimal(tokens / 1_000_000)}M`;
  if (tokens >= 1_000) return `${trimDecimal(tokens / 1_000)}K`;
  return String(Math.round(tokens));
}

function trimDecimal(value: number): string {
  return String(Math.round(value * 10) / 10);
}

/**
 * Summary label. Rollover % (`context_pct`, 0-100) and window
 * (`context_window`, or `window`, in tokens) are optional; whatever is
 * missing is left out rather than guessed.
 */
export function previousContextLabel(metadata: any): string {
  const meta = metadata && typeof metadata === 'object' ? metadata : {};
  const pct = finiteNumber(meta.context_pct ?? meta.rollover_pct);
  const windowTokens = finiteNumber(meta.context_window ?? meta.window);
  const pctText = pct !== null ? `${Math.round(pct)}%` : '';
  const windowText = windowTokens !== null ? formatContextWindow(windowTokens) : '';
  if (pctText && windowText) return `Previous context (rollover at ${pctText} of ${windowText})`;
  if (pctText) return `Previous context (rollover at ${pctText})`;
  if (windowText) return `Previous context (${windowText} window)`;
  return 'Previous context';
}

/**
 * Collapsed-by-default <details> block (same pattern as TaskDetails' Block).
 * The native <summary> is focusable and toggles with Enter/Space.
 */
export function PreviousContextBlock({
  messageId,
  metadata,
  children,
}: {
  messageId: string;
  metadata?: any;
  children: React.ReactNode;
}) {
  return (
    <details
      data-debug-id={`conversation-previous-context-${messageId}`}
      className="group w-full rounded-xl border border-subtle bg-surface"
    >
      <summary
        data-debug-id={`conversation-previous-context-toggle-${messageId}`}
        className="flex cursor-pointer list-none items-center gap-1.5 rounded-xl px-3 py-2 outline-none hover:bg-surface-raised focus-visible:shadow-focus [&::-webkit-details-marker]:hidden"
      >
        <Icon name="chevron-right" size={12} className="text-muted transition-transform group-open:rotate-90" />
        <Text as="span" role="overline" tone="muted">
          {previousContextLabel(metadata)}
        </Text>
      </summary>
      <div
        data-debug-id={`conversation-previous-context-body-${messageId}`}
        className="border-t border-subtle px-3 py-2 text-sm text-primary"
      >
        {children}
      </div>
    </details>
  );
}
