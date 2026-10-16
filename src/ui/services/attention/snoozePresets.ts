// Snooze menu presets for attention cards, computed in the viewer's local time.

export type SnoozePreset = { id: 'hour' | 'tonight' | 'tomorrow' | 'next-week'; label: string; until: Date };

/**
 * - In 1 hour
 * - Tonight: today 20:00 (skipped once it is 19:00 or later -- "1 hour" covers that)
 * - Tomorrow 9:00
 * - Next week: the coming Monday 9:00 (a week from today when today is Monday)
 */
export function snoozePresets(now: Date): SnoozePreset[] {
  const out: SnoozePreset[] = [{ id: 'hour', label: 'In 1 hour', until: new Date(now.getTime() + 60 * 60 * 1000) }];
  if (now.getHours() < 19) {
    const tonight = new Date(now);
    tonight.setHours(20, 0, 0, 0);
    out.push({ id: 'tonight', label: 'Tonight', until: tonight });
  }
  const tomorrow = new Date(now);
  tomorrow.setDate(now.getDate() + 1);
  tomorrow.setHours(9, 0, 0, 0);
  out.push({ id: 'tomorrow', label: 'Tomorrow 9:00', until: tomorrow });
  const monday = new Date(now);
  const daysToMonday = ((8 - now.getDay()) % 7) || 7;
  monday.setDate(now.getDate() + daysToMonday);
  monday.setHours(9, 0, 0, 0);
  out.push({ id: 'next-week', label: 'Next week', until: monday });
  return out;
}

/** Hub timestamps are RFC 3339 UTC without fractional seconds. */
export function toHubTimestamp(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
}
