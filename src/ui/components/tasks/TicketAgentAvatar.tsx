import React from 'react';
import { Avatar, type Size } from '@ui';
import type { FleetSlotState } from './ticketModel';

/**
 * An agent's avatar with its state animation (REQ-B3): working agents breathe,
 * a blocked one carries a danger ring, a stopped one is dimmed. The animation
 * is `motion-safe:` only, so reduced motion stops it; the state pill next to it
 * always says the state in words.
 */
const STATE_CLASS: Record<FleetSlotState, string> = {
  working: 'ring-2 ring-info/60 motion-safe:animate-pulse',
  reviewing: 'ring-2 ring-info/60 motion-safe:animate-pulse',
  coordinating: 'ring-2 ring-accent/60 motion-safe:animate-pulse',
  idle: 'ring-1 ring-success/50',
  blocked: 'ring-2 ring-danger/70',
  not_running: 'opacity-60 grayscale',
};

export interface TicketAgentAvatarProps {
  name: string;
  state?: FleetSlotState;
  size?: Size;
  className?: string;
}

export function TicketAgentAvatar({ name, state = 'idle', size = 'sm', className = '' }: TicketAgentAvatarProps) {
  return (
    <span data-agent-state={state} className={`inline-flex shrink-0 rounded-md ${STATE_CLASS[state]} ${className}`}>
      <Avatar name={name || 'Agent'} size={size} shape="rounded" />
    </span>
  );
}

export default TicketAgentAvatar;
