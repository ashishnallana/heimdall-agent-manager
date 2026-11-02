import { useCallback, useEffect, useState } from 'react';
import { Button, Text } from '@ui';
import {
  cancelBridgeEnrollment,
  fetchPendingBridgeEnrollments,
  type PendingBridgeEnrollment,
} from '../../api/endpoints/bridges';

/** Detect enrollments started elsewhere, and observe commit or rollback. */
const PENDING_REFRESH_MS = 10_000;

/**
 * REQ-EA-6: bridges approved but not enrolled yet. A bridge is enrolled only once
 * its vault key is delivered; until then it is listed here as "Enrolling…" and
 * nowhere else. Replacements remain usable while their pending attempt is shown.
 * Poll even from an empty list so attempts started elsewhere become visible.
 */
export default function PendingEnrollmentsCard({ refreshKey }: { refreshKey?: unknown }) {
  const [pending, setPending] = useState<PendingBridgeEnrollment[]>([]);
  const [cancelling, setCancelling] = useState('');
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    try {
      setPending(await fetchPendingBridgeEnrollments());
    } catch {
      // Best-effort: the main bridge list reports load failures.
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load, refreshKey]);

  useEffect(() => {
    const timer = setInterval(() => void load(), PENDING_REFRESH_MS);
    return () => clearInterval(timer);
  }, [load]);

  const cancel = useCallback(
    async (bridgeId: string) => {
      setCancelling(bridgeId);
      setError('');
      try {
        await cancelBridgeEnrollment(bridgeId);
        await load();
      } catch (err: any) {
        setError(String(err?.message || 'Could not cancel the enrollment'));
      } finally {
        setCancelling('');
      }
    },
    [load],
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
