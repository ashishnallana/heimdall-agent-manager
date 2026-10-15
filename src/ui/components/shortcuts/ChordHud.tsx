import React, { useMemo } from 'react';
import { Kbd } from '@ui';
import { useShortcuts } from '../../services/shortcuts/ShortcutContext';
import { getChordCompletions } from '../../services/shortcuts/shortcutLogic';

export function ChordHud() {
  const { buffer, matchingActions } = useShortcuts();
  const completions = useMemo(
    () => getChordCompletions(buffer, matchingActions),
    [buffer, matchingActions],
  );

  if (buffer.length === 0 || completions.length === 0) return null;

  return (
    <div
      data-debug-id="shortcut-chord-hud"
      aria-live="polite"
      aria-label={`Shortcut prefix ${buffer.join(' ')}`}
      className="pointer-events-none fixed inset-x-0 app-viewport-bottom z-toast hidden justify-center p-5 md:flex"
    >
      <div className="flex max-w-2xl flex-wrap items-center justify-center gap-2 rounded-[var(--radius-lg)] border border-subtle bg-surface-overlay px-3 py-2 text-caption text-muted shadow-overlay backdrop-blur-sm">
        <span className="mr-1 flex items-center gap-1" aria-hidden="true">
          {buffer.map((key, index) => <Kbd key={`${key}-${index}`}>{key}</Kbd>)}
        </span>
        {completions.map((completion) => (
          <span key={completion.key} className="flex items-center gap-1.5">
            <Kbd>{completion.key}</Kbd>
            <span>{completion.titles.join(' / ')}</span>
          </span>
        ))}
      </div>
    </div>
  );
}

export default ChordHud;
