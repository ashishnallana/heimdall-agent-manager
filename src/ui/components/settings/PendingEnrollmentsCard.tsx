import { useCallback, useMemo, useState } from 'react';
import { useDispatch } from 'react-redux';
import { Button, Text } from '@ui';
import { heimdallApi } from '../../api/heimdallApi';
import { useListBridgesWithPendingQuery } from '../../api/endpoints/bridgeSupport';
import { cancelBridgeEnrollment, selectPendingBridgeEnrollments } from '../../api/endpoints/bridges';

/**
 * Fallback only: the hub announces every enrollment start, commit and rollback as
 * resource_changed bridge "bridge_enrollment_changed", which refetches this list
 * (wsInvalidation.ts). The poll covers a missed event, and only while the page is
 * visible (skipPollingIfUnfocused).
 */
export const PENDING_FALLBACK_POLL_MS = 60_000;

/**
 * REQ-EA-6: bridges approved but not enrolled yet. A bridge is enrolled only once
 * its vault key is delivered; until then it is listed here as "Enrolling…" and
 * nowhere else. Replacements remain usable while their pending attempt is shown.
 * Subscribed even from an empty list so attempts started elsewhere become visible.
 */
export default function PendingEnrollmentsCard() {
  const dispatch = useDispatch();
  const query = useListBridgesWithPendingQuery(undefined, {
    pollingInterval: PENDING_FALLBACK_POLL_MS,
    skipPollingIfUnfocused: true,
    refetchOnFocus: true,
  });
  // Best-effort: the main bridge list reports load failures.
  const pending = useMemo(() => selectPendingBridgeEnrollments(query.data?.bridges || []), [query.data]);
  const [cancelling, setCancelling] = useState('');
  const [error, setError] = useState('');

  const cancel = useCallback(
    async (bridgeId: string) => {
      setCancelling(bridgeId);
      setError('');
      try {
        await cancelBridgeEnrollment(bridgeId);
        // A rollback removes a row and a committed race adds one: refresh every
        // bridge list now rather than wait for the WebSocket event.
        dispatch(heimdallApi.util.invalidateTags([{ type: 'Bridges', id: 'LIST' }]));
      } catch (err: any) {
        setError(String(err?.message || 'Could not cancel the enrollment'));
      } finally {
        setCancelling('');
      }
    },
    [dispatch],
  );

  if (pending.length === 0) return null;
  return (
    <div data-debug-id="settings-bridges-pending" className="mt-4">
      <Text as="div" role="overline" tone="muted" className="mb-2">
        Enrolling ({pending.length})
      </Text>
      {error ? <div className="mb-2 text-sm text-danger">{error}</div> : null}
      <div className="space-y-2">
        {pending.map((p) => (
          <div
            key={p.bridge_id}
            data-debug-id={`settings-bridge-pending-${p.bridge_id}`}
            className="flex flex-col gap-2 rounded-xl border border-dashed border-subtle bg-surface-raised/30 p-3 sm:flex-row sm:items-center sm:justify-between"
          >
            <div className="min-w-0">
              <div className="truncate text-sm font-medium text-primary">
                {p.label || p.machine_hostname || p.bridge_id} — {p.replacing ? 'Re-enrolling…' : 'Enrolling…'}
              </div>
              <div className="text-xs text-muted">
                Waiting for your vault key to be delivered from the approval page. It is rolled back
                automatically if that does not happen in time.
              </div>
            </div>
            <Button
              data-debug-id={`settings-bridge-pending-cancel-${p.bridge_id}`}
              onClick={() => void cancel(p.bridge_id)}
              disabled={cancelling === p.bridge_id}
            >
              {cancelling === p.bridge_id ? 'Cancelling…' : 'Cancel'}
            </Button>
          </div>
        ))}
      </div>
    </div>
  );
}
