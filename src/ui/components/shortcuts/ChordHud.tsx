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
      className="pointer-events-none fixed inset-x-0 z-toast flex justify-center p-2 sm:p-4"
      style={{
        bottom: 'calc(var(--app-viewport-bottom-offset, 0px) + max(var(--ui-bottom-chrome, 0px), env(safe-area-inset-bottom, 0px)))',
      }}
    >
      <div className="pointer-events-auto max-h-[min(60vh,28rem)] w-full max-w-4xl overflow-y-auto rounded-2xl border border-subtle bg-surface-overlay text-muted shadow-overlay backdrop-blur-sm">
        <div className="sticky top-0 z-10 flex flex-wrap items-center justify-between gap-2 border-b border-subtle bg-surface-overlay px-3 py-2.5 sm:px-4">
          <div className="flex min-w-0 items-center gap-2">
            <span className="shrink-0 text-[11px] font-semibold uppercase tracking-[0.14em] text-faint">Shortcut</span>
            <span className="flex min-w-0 flex-wrap items-center gap-1" aria-hidden="true">
              {buffer.map((key, index) => <Kbd key={`${key}-${index}`}>{key}</Kbd>)}
            </span>
          </div>
          <span className="text-[11px] text-faint"><Kbd>esc</Kbd> close · <Kbd>enter</Kbd> run current</span>
        </div>
        <div className="grid grid-cols-1 gap-px bg-subtle sm:grid-cols-2 lg:grid-cols-3">
          {completions.map((completion) => (
            <div key={completion.key} className="flex min-h-12 items-start gap-3 bg-surface-overlay px-3 py-2.5 sm:px-4">
              <Kbd className="mt-0.5 min-w-7 shrink-0 justify-center">{completion.key}</Kbd>
              <span className="min-w-0 space-y-0.5 text-left text-xs leading-5 text-primary">
                {completion.titles.map((title) => <span key={title} className="block break-words">{title}</span>)}
              </span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

export default ChordHud;
