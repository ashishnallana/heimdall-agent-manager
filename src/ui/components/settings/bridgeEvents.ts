// Presentation helpers for the "Recent errors" card (bridge error events,
// bridge_logs plan v2 §4.4). Pure so they can be unit-tested without a DOM.

import type { Tone } from '@ui';
import type { BridgeEvent } from '../../api/endpoints/bridgeSupport';

/** Bridge clock vs hub clock: past this skew we show when the hub received it. */
export const BRIDGE_EVENT_SKEW_MS = 5 * 60 * 1000;

export function bridgeEventLevelTone(level: string): Tone {
  return level === 'error' ? 'danger' : 'warning';
}

/** The timestamp to display: the bridge's own clock unless it is implausible. */
export function bridgeEventDisplayTime(event: Pick<BridgeEvent, 'ts_ms' | 'received_at'>): number {
  const ts = Number(event.ts_ms || 0);
  const received = Number(event.received_at || 0);
  if (!ts) return received;
  if (received && Math.abs(received - ts) > BRIDGE_EVENT_SKEW_MS) return received;
  return ts;
}

/** "just now" / "3 m ago" / "2 h ago" / "5 d ago"; future or unknown -> "—". */
export function formatRelativeTime(thenMs: number, nowMs: number = Date.now()): string {
  if (!thenMs || !Number.isFinite(thenMs)) return '—';
  const delta = Math.max(0, nowMs - thenMs);
  const s = Math.floor(delta / 1000);
  if (s < 45) return 'just now';
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} m ago`;
  const h = Math.floor(m / 60);
  if (h < 48) return `${h} h ago`;
  const d = Math.floor(h / 24);
  return `${d} d ago`;
}

/** Compact "key=value, …" rendering of the typed fields for the title tooltip. */
export function formatBridgeEventFields(fields: Record<string, string | number> | undefined): string {
  if (!fields) return '';
  return Object.entries(fields).map(([k, v]) => `${k}=${String(v)}`).join(', ');
}
