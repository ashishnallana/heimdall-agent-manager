import React from 'react';
import { StatusPill, Text } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { normalizeTaskState } from './taskV2Types';
import type { TaskNames } from './taskNames';
import { attemptInfo, isFinishedTask, isRework, leaseClock } from './ticketModel';

/* Attempts (gap G3: only the latest submission's revision is known) --- */

export function TicketAttemptsCard({ task, names, lease }: { task: TaskWire; names: TaskNames; lease: ReturnType<typeof leaseClock> }) {
  const attempt = attemptInfo(task);
  const state = normalizeTaskState(task.state);
  const submitted = Number(task.requirements?.submitted_revision) || 0;
  const rework = isRework(task);
  const rows = Array.from({ length: attempt.no }, (_, i) => attempt.no - i);
  return (
    <section data-debug-id="ticket-view-attempts" className="flex flex-col gap-2">
      <Text as="h3" role="title" className="text-primary">Attempts</Text>
      <ul className="divide-y divide-subtle overflow-hidden rounded-lg border border-subtle bg-surface">
        {rows.map((n) => {
          const current = n === attempt.no;
          let text = 'Earlier attempt';
          let pill: { tone: 'info' | 'pending' | 'success' | 'neutral' | 'warning'; label: string } = { tone: 'neutral', label: 'Superseded' };
          if (current) {
            if (state === 'in_progress') {
              text = `${(lease && names.instance(lease.holderInstanceId)) || 'The worker'} · ${rework ? `reworking for rev ${task.requirements?.revision}` : 'working'}`;
              pill = { tone: 'info', label: 'Working' };
            } else if (state === 'in_review') {
              text = submitted ? `Submitted for rev ${submitted}` : 'Submitted';
              pill = rework ? { tone: 'warning', label: 'Out of date' } : { tone: 'pending', label: 'In review' };
            } else if (state === 'done') {
              text = submitted ? `Submitted for rev ${submitted} · accepted` : 'Accepted';
              pill = { tone: 'success', label: 'Done' };
            } else if (state === 'cancelled') {
              text = 'Cancelled';
              pill = { tone: 'neutral', label: 'Cancelled' };
            } else {
              text = 'Waiting for a worker';
              pill = { tone: 'neutral', label: 'Not started' };
            }
          }
          return (
            <li key={n} className="flex min-h-11 items-center gap-3 px-3 py-2 text-body-sm" data-debug-id={`ticket-view-attempt-${n}`}>
              <span className="w-20 shrink-0 text-muted">Attempt {n}</span>
              <span className="min-w-0 flex-1 truncate text-primary">{text}</span>
              <StatusPill tone={pill.tone}>{pill.label}</StatusPill>
            </li>
          );
        })}
      </ul>
      {attempt.exhausted && !isFinishedTask(task) && (
        <Text as="p" role="caption" tone="warning">Every attempt in the budget ({attempt.max}) is spent.</Text>
      )}
    </section>
  );
}
