import type { QuoteContext } from '../../utils/quoteContext';
import { quoteLabel } from '../../utils/quoteContext';
export default function ComposerContextChips({ quotes, onRemove, disabled = false }: {
  quotes: QuoteContext[]; onRemove: (id: string) => void; disabled?: boolean;
}) {
  if (!quotes.length) return null;
  return <div data-debug-id="composer-quote-chips" aria-label="Quoted context" className="mb-2 flex flex-wrap gap-2">
    {quotes.map(quote => <span key={quote.id} data-debug-id={`composer-quote-chip-${quote.id}`}
      className="inline-flex max-w-full items-center gap-1 rounded-lg border border-subtle bg-surface-raised px-2 py-1 text-xs text-primary">
      <details className="min-w-0">
        <summary data-debug-id={`composer-quote-details-${quote.id}`} className="cursor-pointer truncate" title={quote.selectedText}>{quoteLabel(quote.selectedText)}</summary>
        <div className="max-h-48 max-w-sm overflow-auto whitespace-pre-wrap py-2">
          <div className="mb-1 font-semibold">{quote.source.author || quote.source.label || quote.source.kind.replaceAll('_', ' ')}</div>
          {quote.source.href.startsWith('#/') ? <a href={quote.source.href} data-debug-id={`composer-quote-source-${quote.id}`} className="mb-1 block text-accent underline">View source</a> : null}
          {quote.selectedText}
        </div>
      </details>
      <button type="button" disabled={disabled} aria-label={`Remove quote: ${quoteLabel(quote.selectedText)}`}
        data-debug-id={`composer-quote-remove-${quote.id}`} onClick={() => onRemove(quote.id)}
        className="shrink-0 rounded px-1 text-muted hover:bg-neutral-soft disabled:opacity-40">×</button>
    </span>)}
  </div>;
}
