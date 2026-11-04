import React from 'react';
import { Text } from '@ui';

/** Pieces shared by the ticket tab's sections: the card frame and the loading skeleton. */
export function TicketSkeleton() {
  return (
    <div data-debug-id="ticket-view-loading" className="flex flex-col gap-4 p-5" aria-busy="true" aria-label="Loading ticket">
      <div className="h-11 rounded-md bg-surface motion-safe:animate-pulse" />
      <div className="h-8 w-3/4 rounded-md bg-surface motion-safe:animate-pulse" />
      <div className="h-40 rounded-lg bg-surface motion-safe:animate-pulse" />
      <div className="h-56 rounded-lg bg-surface motion-safe:animate-pulse" />
    </div>
  );
}

export function TicketCard({ title, aside, children, debugId, className = '' }: { title?: React.ReactNode; aside?: React.ReactNode; children: React.ReactNode; debugId?: string; className?: string }) {
  return (
    <section data-debug-id={debugId} className={`rounded-lg border border-subtle bg-surface ${className}`}>
      {title !== undefined && (
        <div className="flex flex-wrap items-center justify-between gap-2 px-4 pt-3">
          <Text as="h3" role="title" className="text-primary">{title}</Text>
          {aside}
        </div>
      )}
      <div className="p-4 pt-3">{children}</div>
    </section>
  );
}
