import React, { useState } from 'react';
import { Badge, Icon, IconButton, Select, Text } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { useUpdateTaskPriorityMutation } from '../../api/endpoints/tasks';
import { taskBridgeOptions } from '../../utils/taskBridgePin';
import { actionErrorMessage, type TaskActionsApi } from './useTaskActions';
import { describeEffectivePlacement, taskEffectivePlacement } from './fleetSelection';
import type { TaskNames } from './taskNames';
import { attemptInfo, formatAgo, formatDuration, keyFor, leaseClock, replacementLinks } from './ticketModel';

/* Details ------------------------------------------------------------ */

export function TicketDetailsCard({
  task,
  chainId,
  names,
  keys,
  fleets,
  bridges,
  open,
  onToggle,
  actions,
  now,
  locked,
  onOpenTicket,
  onCopy,
}: {
  task: TaskWire;
  chainId: string;
  names: TaskNames;
  keys: Map<string, string>;
  fleets: any[];
  bridges: any[];
  open: boolean;
  onToggle: () => void;
  actions: TaskActionsApi;
  now: number;
  locked: boolean;
  onOpenTicket: (taskId: string) => void;
  onCopy: (text: string, title: string) => Promise<void>;
}) {
  const [updatePriority, priorityState] = useUpdateTaskPriorityMutation();
  const [priorityError, setPriorityError] = useState('');
  const [moreOpen, setMoreOpen] = useState(false);
  const changePriority = async (value: string) => {
    setPriorityError('');
    try {
      await updatePriority({ chainId, taskId: task.task_id, priority: value }).unwrap();
    } catch (err) {
      setPriorityError(actionErrorMessage(err));
    }
  };
  const attempt = attemptInfo(task);
  const lease = leaseClock(task, now);
  const placement = describeEffectivePlacement(taskEffectivePlacement(task, fleets), names.bridge);
  const unpinned = describeEffectivePlacement(taskEffectivePlacement({ ...task, bridge_id: '' }, fleets), names.bridge);
  const bridgeOptions = [
    { value: '', text: unpinned.bridge ? `Fleet default: ${unpinned.bridge}` : "Fleet default: the worker's fleet row decides" },
    ...taskBridgeOptions(bridges, String(task.bridge_id || '')).slice(1).map((o) => ({ value: o.value, text: o.label })),
  ];
  const links = replacementLinks(String(task.comment_summary?.last_comment_preview || ''));
  const priority = String(task.priority || 'p2').toLowerCase();
  const row = (label: string, value: React.ReactNode, debugId?: string) => (
    <div className="grid grid-cols-[6.5rem_minmax(0,1fr)] items-center gap-3 py-2" data-debug-id={debugId}>
      <dt className="text-body-sm text-muted">{label}</dt>
      <dd className="min-w-0 text-body-sm text-primary">{value}</dd>
    </div>
  );
  return (
    <section data-debug-id="ticket-view-details" className="rounded-lg border border-subtle bg-surface">
      <button
        type="button"
        aria-expanded={open}
        onClick={onToggle}
        data-debug-id="ticket-view-details-toggle"
        className="flex min-h-11 w-full items-center justify-between gap-2 px-4 py-2 text-left focus-visible:outline-none focus-visible:shadow-focus"
      >
        <Text as="h3" role="title" className="text-primary">Details</Text>
        <Icon name={open ? 'chevron-up' : 'chevron-down'} size={14} className="text-muted" />
      </button>
      {open && (
        <dl className="divide-y divide-subtle border-t border-subtle px-4">
          {row(
            'Priority',
            locked ? (
              <Badge tone="neutral">{priority.toUpperCase()}</Badge>
            ) : (
              <>
                <Select
                  size="sm"
                  value={priority}
                  aria-label="Priority"
                  disabled={priorityState.isLoading}
                  onChange={(v) => void changePriority(v)}
                  options={[{ value: 'p0', text: 'P0 urgent' }, { value: 'p1', text: 'P1 high' }, { value: 'p2', text: 'P2 normal' }]}
                  data-debug-id="ticket-view-priority-select"
                />
                {priorityError && (
                  <Text as="p" role="caption" tone="danger" className="mt-1 break-words" data-debug-id="ticket-view-priority-error">
                    {priorityError}
                  </Text>
                )}
              </>
            ),
            'ticket-view-detail-priority',
          )}
          {row(
            'Bridge',
            locked ? (
              <span className="font-mono">{placement.bridge || 'Fleet default'}</span>
            ) : (
              <Select size="sm" value={String(task.bridge_id || '')} onChange={(v) => void actions.pinBridge(v)} options={bridgeOptions} disabled={actions.busy} aria-label="Bridge pin" data-debug-id="ticket-view-bridge-select" />
            ),
            'ticket-view-detail-bridge',
          )}
          {row('Attempt', `${attempt.no}${attempt.exhausted ? ' · budget spent' : ''}${lease?.hardLeftMs != null ? ` · hard limit in ${formatDuration(lease.hardLeftMs)}` : ''}`, 'ticket-view-detail-attempt')}
          {links.replaces && row('Replaces', <button type="button" data-debug-id="ticket-view-replaces-link" className="text-accent hover:underline" onClick={() => onOpenTicket(links.replaces!)}>{keyFor(keys, links.replaces)}</button>, 'ticket-view-detail-replaces')}
          {links.replacedBy && row('Replaced by', <button type="button" data-debug-id="ticket-view-replaced-by-link" className="text-accent hover:underline" onClick={() => onOpenTicket(links.replacedBy!)}>{keyFor(keys, links.replacedBy)}</button>, 'ticket-view-detail-replaced-by')}
          {row(
            'More fields',
            moreOpen ? (
              <dl className="grid grid-cols-[4.5rem_minmax(0,1fr)] gap-x-2 gap-y-1 text-caption">
                <dt className="text-muted">Model</dt>
                <dd className="truncate font-mono">{placement.model || 'fleet default'}</dd>
                <dt className="text-muted">Chain</dt>
                <dd className="truncate font-mono">{chainId}</dd>
                <dt className="text-muted">Kind</dt>
                <dd className="truncate font-mono">{task.kind || 'task'}</dd>
                <dt className="text-muted">Task ID</dt>
                <dd className="flex min-w-0 items-center gap-1">
                  <span className="truncate font-mono">{task.task_id}</span>
                  <IconButton icon="copy" label="Copy ID" size="sm" variant="ghost" onClick={() => void onCopy(task.task_id, 'Ticket id copied')} data-debug-id="ticket-view-copy-id-btn" />
                </dd>
              </dl>
            ) : (
              <button type="button" className="text-muted hover:text-primary" onClick={() => setMoreOpen(true)} data-debug-id="ticket-view-more-fields-btn">
                Model, chain, kind, task ID
              </button>
            ),
            'ticket-view-detail-more',
          )}
          <div className="py-2 text-caption text-faint">
            Created {formatAgo(task.created_at, now)}
            {task.updated_at ? ` · Updated ${formatAgo(task.updated_at, now)}` : ''}
          </div>
        </dl>
      )}
    </section>
  );
}
