import { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import type { MarkdownTextSelection } from '../MarkdownBody';
export default function QuoteSelectionPopover({ selection, onQuote, onDismiss, disabledReason = '' }: {
  selection: MarkdownTextSelection; onQuote: () => void | Promise<void>; onDismiss: () => void; disabledReason?: string;
}) {
  const root = useRef<HTMLDivElement>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => {
    const outside = (event: Event) => { if (!root.current?.contains(event.target as Node)) onDismiss(); };
    const key = (event: KeyboardEvent) => { if (event.key === 'Escape') onDismiss(); };
    document.addEventListener('pointerdown', outside);
    document.addEventListener('keydown', key);
    window.addEventListener('scroll', onDismiss, true);
    window.addEventListener('resize', onDismiss);
    return () => {
      document.removeEventListener('pointerdown', outside); document.removeEventListener('keydown', key);
      window.removeEventListener('scroll', onDismiss, true); window.removeEventListener('resize', onDismiss);
    };
  }, [onDismiss]);
  return createPortal(<div ref={root} data-debug-id="message-quote-popover" role="group" aria-label="Selected message text"
    style={{ position: 'fixed', zIndex: 1000, left: Math.max(8, Math.min(selection.rect?.left || 8, window.innerWidth - 220)), top: Math.max(8, Math.min((selection.rect?.bottom || 8) + 6, window.innerHeight - 90)) }}
    className="max-w-[220px] rounded-lg border border-subtle bg-surface p-1 shadow-lg">
    <button type="button" data-debug-id="message-quote-btn" disabled={busy || Boolean(disabledReason)} title={disabledReason || 'Add selected text to coordinator composer'}
      className="rounded px-3 py-1 text-sm font-semibold text-primary hover:bg-neutral-soft disabled:opacity-50"
      onPointerDown={event => event.preventDefault()}
      onClick={async () => {
        setBusy(true); setError('');
        try { await onQuote(); onDismiss(); } catch (err) { setError(err instanceof Error ? err.message : 'Could not add quote.'); }
        finally { setBusy(false); }
      }}>Quote</button>
    {disabledReason || error ? <div role="status" data-debug-id="message-quote-status" className="px-2 py-1 text-xs text-muted">{disabledReason || error}</div> : null}
  </div>, document.body);
}
