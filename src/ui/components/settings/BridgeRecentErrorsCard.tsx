import React, { useMemo, useState } from 'react';
import { Button, StatusPill, Spinner } from '@ui';
import {
  type BridgeEvent,
  useListBridgeEventsQuery,
  usePurgeBridgeEventsMutation,
} from '../../api/endpoints/bridgeSupport';
import {
  bridgeEventDisplayTime,
  bridgeEventLevelTone,
  formatBridgeEventFields,
  formatRelativeTime,
} from './bridgeEvents';

export const BRIDGE_RECENT_ERRORS_DEFAULT_LIMIT = 20;

/**
 * Presentational list — no hooks, so it renders under react-dom/server in tests.
 * `now` is injected for deterministic relative times.
 */
export function BridgeRecentErrorsList({ bridgeId, events, now }: { bridgeId: string; events: BridgeEvent[]; now?: number }) {
  const nowMs = now ?? Date.now();
  if (events.length === 0) {
    return (
      <div data-debug-id={`settings-bridge-errors-empty-${bridgeId}`} className="text-xs text-muted">
        No warnings or errors reported.
      </div>
    );
  }
  return (
    <ul data-debug-id={`settings-bridge-errors-list-${bridgeId}`} className="flex flex-col divide-y divide-subtle">
      {events.map((event) => (
        <li
          key={event.id}
          data-debug-id={`settings-bridge-error-${bridgeId}-${event.id}`}
          className="flex flex-wrap items-center gap-x-2 gap-y-1 py-1.5 text-xs"
          title={formatBridgeEventFields(event.fields)}
        >
          <StatusPill tone={bridgeEventLevelTone(event.level)} data-debug-id={`settings-bridge-error-level-${bridgeId}-${event.id}`}>
            {event.level}
          </StatusPill>
          <span className="text-primary">{event.message}</span>
          <span
            data-debug-id={`settings-bridge-error-code-${bridgeId}-${event.id}`}
            className="rounded-full border border-subtle bg-surface-raised/40 px-1.5 py-0.5 font-mono text-[10px] text-muted"
          >
            {event.code}
          </span>
          {event.count > 1 ? (
            <span data-debug-id={`settings-bridge-error-count-${bridgeId}-${event.id}`} className="text-muted">×{event.count}</span>
          ) : null}
          <span className="ml-auto text-muted" data-debug-id={`settings-bridge-error-time-${bridgeId}-${event.id}`}>
            {formatRelativeTime(bridgeEventDisplayTime(event), nowMs)}
          </span>
        </li>
      ))}
    </ul>
  );
}

/**
 * "Recent errors" card for one bridge in Settings → Bridges. Collapsed by
 * default (no request until opened); the hub renders `message`, so nothing
 * here interprets codes.
 */
export default function BridgeRecentErrorsCard({ bridgeId }: { bridgeId: string }) {
  const [open, setOpen] = useState(false);
  const { data, isFetching, error, refetch } = useListBridgeEventsQuery(
    { bridgeId, limit: BRIDGE_RECENT_ERRORS_DEFAULT_LIMIT },
    { skip: !open },
  );
  const [purgeEvents, { isLoading: purging }] = usePurgeBridgeEventsMutation();
  const events = useMemo(() => data?.events ?? [], [data]);

  return (
    <div data-debug-id={`settings-bridge-errors-${bridgeId}`} className="mt-2 rounded-lg border border-subtle bg-surface-raised/30 px-3 py-2">
      <div className="flex items-center gap-2">
        <button
          type="button"
          data-debug-id={`settings-bridge-errors-toggle-${bridgeId}`}
          className="text-xs font-medium text-primary hover:text-accent transition-colors"
          onClick={() => setOpen((v) => !v)}
          aria-expanded={open}
        >
          {open ? '▾' : '▸'} Recent errors
        </button>
        {open && isFetching ? <Spinner size="sm" /> : null}
        {open ? (
          <div className="ml-auto flex items-center gap-1">
            <Button variant="secondary" size="sm" data-debug-id={`settings-bridge-errors-refresh-${bridgeId}`} onClick={() => void refetch()}>
              Refresh
            </Button>
            <Button
              variant="danger"
              size="sm"
              data-debug-id={`settings-bridge-errors-purge-${bridgeId}`}
              disabled={purging || events.length === 0}
              onClick={() => void purgeEvents({ bridgeId })}
            >
              Purge
            </Button>
          </div>
        ) : null}
      </div>
      {open ? (
        <div className="mt-1.5">
          {error ? (
            <div data-debug-id={`settings-bridge-errors-error-${bridgeId}`} className="text-xs text-danger">
              Could not load events{(error as any)?.error ? `: ${String((error as any).error)}` : ''}
            </div>
          ) : (
            <BridgeRecentErrorsList bridgeId={bridgeId} events={events} />
          )}
          {data?.has_more ? (
            <div className="mt-1 text-[10px] text-muted">Showing the newest {events.length}; older events are kept for 7 days.</div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
