import React from 'react';

/** First letters of the first two words, uppercased ("Backend Dev #15" -> "BD"). */
function initialsOf(name: string): string {
  const parts = name.replace(/#\d+/g, '').trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return '?';
  if (parts.length === 1) return parts[0].slice(0, 1).toUpperCase();
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

/**
 * A compact person marker for task cards: a small initials disc plus the name.
 * Smaller than @ui Avatar (whose smallest box is 32px), sized to sit in a
 * caption-height metadata row. `children` replaces the plain name (e.g. a
 * HolderName link) while `name` still drives the initials.
 */
export function PersonChip({
  name,
  tone = 'default',
  title,
  children,
}: {
  name: string;
  tone?: 'default' | 'you' | 'missing';
  title?: string;
  children?: React.ReactNode;
}) {
  const disc =
    tone === 'you'
      ? 'border-accent bg-accent-soft text-accent'
      : tone === 'missing'
        ? 'border-dashed border-warning text-warning'
        : 'border-subtle bg-surface-raised text-muted';
  return (
    <span title={title} className="inline-flex min-w-0 items-center gap-1.5">
      <span
        aria-hidden="true"
        className={`inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full border text-[11px] font-semibold leading-none ${disc}`}
      >
        {tone === 'missing' ? '?' : initialsOf(name)}
      </span>
      <span className={`truncate ${tone === 'missing' ? 'text-warning' : 'text-primary'}`}>{children ?? name}</span>
    </span>
  );
}

export default PersonChip;
