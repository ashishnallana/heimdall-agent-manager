import React from 'react';
import { StatusPill } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { getTaskPeople, normalizeTaskState, reviewLeaseHolders } from './taskV2Types';
import { isSupersededReview } from './taskActions';
import { TicketAgentAvatar } from './TicketAgentAvatar';
import type { TaskNames } from './taskNames';
import { FLEET_STATE_LABELS, FLEET_STATE_TONE, formatDuration, leaseClock, type FleetMachine, type FleetSlot, type FleetSlotState } from './ticketModel';
import { TicketCard } from './TicketCard';

/* Agents (REQ-T3) ---------------------------------------------------- */

export function TicketAgentsCard({
  task,
  names,
  machines,
  people,
  now,
  onOpenAgent,
}: {
  task: TaskWire;
  names: TaskNames;
  machines: FleetMachine[];
  people: ReturnType<typeof getTaskPeople>;
  now: number;
  onOpenAgent: (instanceId: string, name: string) => void;
}) {
  const state = normalizeTaskState(task.state);
  const slots = machines.flatMap((m) => m.slots);
  const slotForAgent = (agentId: string) => slots.find((s) => s.agentId === agentId && s.instanceId) || slots.find((s) => s.agentId === agentId) || null;
  const offlineSlots = new Set(machines.filter((m) => !m.online).flatMap((m) => m.slots));
  const offline = (slot: FleetSlot | null | undefined) => (slot && offlineSlots.has(slot) ? ' · machine offline' : '');
  const lease = leaseClock(task, now);
  const rows: { id: string; name: string; sub: string; state: FleetSlotState; instanceId: string }[] = [];

  if (lease) {
    rows.push({
      id: `holder-${lease.holderInstanceId}`,
      name: names.instance(lease.holderInstanceId) || names.agent(people.assignee) || 'Worker',
      sub: `Assignee · has the lease · ${formatDuration(lease.leftMs)} left${offline(slots.find((s) => s.instanceId === lease.holderInstanceId))}`,
      state: 'working',
      instanceId: lease.holderInstanceId,
    });
  } else {
    const agentId = people.assignee || people.workers[0] || '';
    const slot = agentId ? slotForAgent(agentId) : null;
    rows.push({
      id: `assignee-${agentId || 'any'}`,
      name: people.assignee ? names.agent(people.assignee) : 'Any worker',
      sub: (state === 'done' ? 'Assignee · finished' : state === 'in_review' ? 'Assignee · handed off' : 'Assignee · waiting for the lease') + offline(slot),
      state: slot ? (slot.state === 'working' || slot.state === 'reviewing' ? 'working' : slot.state) : 'not_running',
      instanceId: slot?.instanceId || '',
    });
  }
  const holders = reviewLeaseHolders(task, now);
  const votes = new Map<string, string>();
  for (const r of task.reviews || []) if (!isSupersededReview(r)) votes.set(names.durableId(r.reviewer || r.reviewer_instance_id), r.verdict);
  for (const agentId of people.reviewers) {
    const holder = holders.find((h) => names.durableId(h.instanceId) === agentId);
    const slot = slotForAgent(agentId);
    const verdict = votes.get(agentId);
    rows.push({
      id: `reviewer-${agentId}`,
      name: names.agent(agentId),
      sub: (holder
        ? `Reviewer · reviewing, ${holder.leftMins}m left`
        : verdict
          ? `Reviewer · ${verdict === 'approve' ? 'approved' : 'requested changes'}`
          : state === 'in_review'
            ? 'Reviewer · up to review'
            : 'Reviewer · next, after handoff') + offline(slot),
      state: holder ? 'working' : slot ? (slot.state === 'working' || slot.state === 'reviewing' ? 'working' : slot.state) : 'not_running',
      instanceId: holder?.instanceId || slot?.instanceId || '',
    });
  }
  if (people.userApproval) {
    rows.push({ id: 'user', name: 'You', sub: votes.get('user') === 'approve' ? 'Reviewer · approved' : 'Reviewer · final approval', state: 'idle', instanceId: '' });
  }
  return (
    <TicketCard debugId="ticket-view-agents" className="overflow-hidden">
      <ul className="-m-4 divide-y divide-subtle">
        {rows.map((r) => {
          const clickable = Boolean(r.instanceId);
          return (
            <li key={r.id}>
              <button
                type="button"
                disabled={!clickable}
                onClick={() => clickable && onOpenAgent(r.instanceId, r.name)}
                data-debug-id={`ticket-view-agent-${r.id}`}
                title={clickable ? `Open ${r.name}'s conversation` : r.state === 'not_running' ? 'Hub starts it when needed' : undefined}
                className="flex min-h-11 w-full min-w-0 items-center gap-3 px-4 py-2.5 text-left enabled:hover:bg-surface-raised focus-visible:outline-none focus-visible:shadow-focus disabled:cursor-default"
              >
                <TicketAgentAvatar name={r.name} state={r.state} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-body-sm font-semibold text-primary">{r.name}</span>
                  <span className="block truncate text-caption text-muted">{r.sub}</span>
                </span>
                {r.id !== 'user' && <StatusPill tone={FLEET_STATE_TONE[r.state]}>{FLEET_STATE_LABELS[r.state]}</StatusPill>}
              </button>
            </li>
          );
        })}
      </ul>
    </TicketCard>
  );
}
