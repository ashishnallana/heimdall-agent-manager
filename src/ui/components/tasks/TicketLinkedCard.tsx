import React from 'react';
import { StatusPill, Text } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { VaultText } from '../vault';
import { TASK_STATE_LABELS, TASK_STATE_TONE, normalizeTaskState } from './taskV2Types';
import { dependentsOf, keyFor } from './ticketModel';

/* Linked tickets ----------------------------------------------------- */

export function TicketLinkedCard({ task, tasks, keys, onOpenTicket }: { task: TaskWire; tasks: TaskWire[]; keys: Map<string, string>; onOpenTicket: (taskId: string) => void }) {
  const waits = (task.depends_on || []).map((id) => tasks.find((t) => t.task_id === id) || ({ task_id: id, title: '', state: '' } as TaskWire));
  const unblocks = dependentsOf(tasks, task.task_id);
  if (!waits.length && !unblocks.length) return null;
  return (
    <section data-debug-id="ticket-view-linked" className="flex flex-col gap-2">
      <Text as="h3" role="title" className="text-primary">Linked tickets</Text>
      {waits.length > 0 && (
        <>
          <Text as="span" role="overline" tone="faint">Waits for</Text>
          <ul className="flex flex-col gap-1.5">
            {waits.map((t) => {
              const s = normalizeTaskState(t.state);
              return (
                <li key={t.task_id}>
                  <button
                    type="button"
                    onClick={() => onOpenTicket(t.task_id)}
                    data-debug-id={`ticket-view-linked-${t.task_id}`}
                    className="flex min-h-11 w-full min-w-0 items-center gap-3 rounded-lg border border-subtle bg-surface px-3 py-2 text-left hover:border-strong hover:bg-surface-raised focus-visible:outline-none focus-visible:shadow-focus"
                  >
                    <span className="shrink-0 font-mono text-caption text-faint">{keyFor(keys, t.task_id)}</span>
                    <VaultText value={t.title} fallback="Untitled ticket" className="min-w-0 flex-1 truncate text-body-sm text-primary" />
                    <StatusPill tone={TASK_STATE_TONE[s]}>{TASK_STATE_LABELS[s]}</StatusPill>
                  </button>
                </li>
              );
            })}
          </ul>
        </>
      )}
      {unblocks.length > 0 && (
        <p className="flex flex-wrap items-center gap-x-2 text-caption text-muted">
          Unblocks
          {unblocks.map((t) => (
            <button
              key={t.task_id}
              type="button"
              onClick={() => onOpenTicket(t.task_id)}
              data-debug-id={`ticket-view-unblocks-${t.task_id}`}
              className="rounded-sm text-muted underline decoration-dotted hover:text-primary focus-visible:outline-none focus-visible:shadow-focus"
            >
              {keyFor(keys, t.task_id)} · <VaultText value={t.title} fallback="Untitled ticket" />
            </button>
          ))}
        </p>
      )}
    </section>
  );
}
