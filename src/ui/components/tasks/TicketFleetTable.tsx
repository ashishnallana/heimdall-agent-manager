import React, { useState } from 'react';
import { Button, Icon, StatusDot, StatusPill, Text } from '@ui';
import { TicketAgentAvatar } from './TicketAgentAvatar';
import { FLEET_STATE_LABELS, FLEET_STATE_TONE, fleetSummary, formatAgo, formatDuration, type FleetMachine, type FleetSlot } from './ticketModel';

export interface TicketFleetTableProps {
  machines: FleetMachine[];
  now: number;
  isMobile?: boolean;
  onManageFleet?: () => void;
  /** A working / reviewing slot opens the ticket it is on. */
  onOpenTicket: (taskId: string) => void;
  /** Coordinator, idle and blocked slots open the agent's conversation in Main. */
  onOpenAgent: (instanceId: string, name: string) => void;
}

/**
 * The board's fleet table (REQ-B3): one table per online machine, a row per
 * agent slot (avatar, role, what it is working on, how long, state pill), and
 * one collapsed row per offline machine.
 */
export const TicketFleetTable: React.FC<TicketFleetTableProps> = ({ machines, now, isMobile = false, onManageFleet, onOpenTicket, onOpenAgent }) => {
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const summary = fleetSummary(machines);
  return (
    <section aria-label="Fleet" data-debug-id="ticket-board-fleet" className="flex flex-col gap-2">
      <div className="flex items-center justify-between gap-2">
        <span className="flex min-w-0 items-baseline gap-3">
          <Text as="span" role="overline" tone="faint">Fleet</Text>
          {summary && (
            <Text as="span" role="overline" tone="faint" data-debug-id="ticket-board-fleet-summary">
              {summary}
            </Text>
          )}
        </span>
        {onManageFleet && (
          <Button size="sm" variant="ghost" onClick={onManageFleet} data-debug-id="ticket-board-manage-fleet-btn">
            Manage fleet
          </Button>
        )}
      </div>
      {machines.length === 0 ? (
        <Text role="caption" tone="faint">No agents in this chain's fleet yet.</Text>
      ) : (
        machines.map((m) => {
          const machineKey = m.bridgeId || 'any';
          if (!m.online) {
            const open = Boolean(expanded[machineKey]);
            return (
              <div key={machineKey} className="rounded-lg border border-subtle bg-surface">
                <button
                  type="button"
                  aria-expanded={open}
                  data-debug-id={`ticket-board-fleet-machine-${machineKey}`}
                  onClick={() => setExpanded((e) => ({ ...e, [machineKey]: !open }))}
                  className="flex min-h-11 w-full items-center gap-2 rounded-lg px-3 py-2 text-left focus-visible:outline-none focus-visible:shadow-focus"
                >
                  <Icon name="device" size={14} className="shrink-0 text-faint" />
                  <span className="min-w-0 truncate font-mono text-body-sm text-muted">{m.label}</span>
                  <span className="min-w-0 flex-1 truncate text-body-sm text-faint">
                    · offline · {m.slots.length} slot{m.slots.length === 1 ? '' : 's'} asleep
                  </span>
                  <Icon name={open ? 'chevron-up' : 'chevron-down'} size={14} className="shrink-0 text-faint" />
                </button>
                {open && <SlotList slots={m.slots} now={now} isMobile={isMobile} onOpenTicket={onOpenTicket} onOpenAgent={onOpenAgent} />}
              </div>
            );
          }
          return (
            <div key={machineKey} data-debug-id={`ticket-board-fleet-machine-${machineKey}`} className="rounded-lg border border-subtle bg-surface">
              <div className="flex min-w-0 items-center gap-2 border-b border-subtle px-3 py-2">
                <Icon name="device" size={14} className="shrink-0 text-faint" />
                <span className="min-w-0 truncate font-mono text-body-sm text-primary">{m.label}</span>
                {m.bridgeId && (
                  <span className="inline-flex shrink-0 items-center gap-1 text-caption text-success">
                    <StatusDot tone="success" label="Machine online" size="sm" />
                    online
                  </span>
                )}
              </div>
              <SlotList slots={m.slots} now={now} isMobile={isMobile} onOpenTicket={onOpenTicket} onOpenAgent={onOpenAgent} />
            </div>
          );
        })
      )}
    </section>
  );
};

function SlotList({
  slots,
  now,
  isMobile,
  onOpenTicket,
  onOpenAgent,
}: {
  slots: FleetSlot[];
  now: number;
  isMobile: boolean;
  onOpenTicket: (taskId: string) => void;
  onOpenAgent: (instanceId: string, name: string) => void;
}) {
  return (
    <ul className="divide-y divide-subtle">
      {slots.map((slot) => (
        <li key={slot.id}>
          <SlotRow slot={slot} now={now} isMobile={isMobile} onOpenTicket={onOpenTicket} onOpenAgent={onOpenAgent} />
        </li>
      ))}
    </ul>
  );
}

function SlotRow({
  slot,
  now,
  isMobile,
  onOpenTicket,
  onOpenAgent,
}: {
  slot: FleetSlot;
  now: number;
  isMobile: boolean;
  onOpenTicket: (taskId: string) => void;
  onOpenAgent: (instanceId: string, name: string) => void;
}) {
  const working = (slot.state === 'working' || slot.state === 'reviewing') && slot.taskId;
  const inert = slot.state === 'not_running' || (!working && !slot.instanceId);
  const since = slot.sinceMs === null ? '' : slot.state === 'blocked' ? ` · stopped ${formatAgo(slot.sinceMs, now)}` : ` · ${formatDuration(now - slot.sinceMs)}`;
  const onClick = () => {
    if (working && slot.taskId) onOpenTicket(slot.taskId);
    else if (!inert && slot.instanceId) onOpenAgent(slot.instanceId, slot.name);
  };
  const pill = <StatusPill tone={FLEET_STATE_TONE[slot.state]}>{FLEET_STATE_LABELS[slot.state]}</StatusPill>;
  return (
    <button
      type="button"
      data-debug-id={`ticket-board-fleet-row-${slot.id}`}
      aria-disabled={inert || undefined}
      title={slot.state === 'not_running' ? 'Hub starts it when needed' : working ? 'Open the ticket it is working on' : `Open ${slot.name}'s conversation`}
      onClick={onClick}
      className={[
        'flex min-h-11 w-full min-w-0 items-center gap-3 px-3 py-2 text-left focus-visible:outline-none focus-visible:shadow-focus',
        inert ? 'cursor-default' : 'hover:bg-surface-raised',
      ].join(' ')}
    >
      <TicketAgentAvatar name={slot.name} state={slot.state} />
      {isMobile ? (
        <span className="min-w-0 flex-1">
          <span className="flex items-start justify-between gap-2">
            <span className="min-w-0">
              <span className="block truncate text-body-sm font-semibold text-primary">{slot.name}</span>
              <span className="block truncate text-caption text-muted">{slot.role}</span>
            </span>
            {pill}
          </span>
          <span className="mt-0.5 block truncate text-body-sm text-muted">
            {slot.detail}
            {since}
          </span>
        </span>
      ) : (
        <>
          <span className="w-32 min-w-0 shrink-0">
            <span className="block truncate text-body-sm font-semibold text-primary">{slot.name}</span>
            <span className="block truncate text-caption text-muted">{slot.role}</span>
          </span>
          <span className="min-w-0 flex-1 truncate text-body-sm text-muted">
            {slot.detail}
            {since}
          </span>
          <span className="shrink-0">{pill}</span>
        </>
      )}
    </button>
  );
}

export default TicketFleetTable;
