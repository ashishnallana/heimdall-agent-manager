/** Shared quote contract. Capture adapters own source resolution; composers only see this model. */
export type QuoteSource = { href: string; label?: string; author?: string; createdUnixMs?: number } & (
  | { kind: 'agent_message'; messageId: string; conversationId: string; agentInstanceId: string; chainId: string; author: string; createdUnixMs: number }
  | { kind: 'task'; taskId: string; chainId: string }
  | { kind: 'task_comment'; taskId: string; commentId: string; chainId: string }
  | { kind: 'preview_selection'; sessionId: string; url: string }
);
export type QuoteContext = { version: 1; id: string; selectedText: string; capturedAt: number; source: QuoteSource };
export const EMPTY_QUOTES: QuoteContext[] = [];
export const QUOTE_LIMIT = 8;
export const QUOTE_TEXT_LIMIT = 8000;
export const QUOTE_TOTAL_LIMIT = 64000;
export function quoteLabel(text: string): string {
  const words = text.trim().split(/\s+/);
  return words.slice(0, 6).join(' ') + (words.length > 6 ? '…' : '');
}
function sourceKey(source: QuoteSource): string {
  switch (source.kind) {
    case 'agent_message': return JSON.stringify([source.kind, source.conversationId, source.messageId]);
    case 'task': return JSON.stringify([source.kind, source.chainId, source.taskId]);
    case 'task_comment': return JSON.stringify([source.kind, source.chainId, source.taskId, source.commentId]);
    case 'preview_selection': return JSON.stringify([source.kind, source.sessionId, source.url]);
  }
}
export function sameQuote(a: QuoteContext, b: QuoteContext): boolean {
  return a.selectedText === b.selectedText && sourceKey(a.source) === sourceKey(b.source);
}
export function quoteLimitError(quotes: QuoteContext[], quote: QuoteContext): string {
  if (!quote.selectedText.trim()) return 'Select some message text to quote.';
  if (quote.selectedText.length > QUOTE_TEXT_LIMIT) return 'Select up to 8,000 characters per quote.';
  if (quotes.some(item => sameQuote(item, quote))) return '';
  if (quotes.length >= QUOTE_LIMIT) return 'Remove a quote before adding another (maximum 8).';
  if (quotes.reduce((n, item) => n + item.selectedText.length, 0) + quote.selectedText.length > QUOTE_TOTAL_LIMIT) return 'Quoted text cannot exceed 64,000 characters.';
  return '';
}
/** This entire string goes through the existing Vault body encryption, never API metadata. */
export function quotedMessageBody(typed: string, quotes: QuoteContext[]): string {
  if (!quotes.length) return typed.trim();
  const payload = JSON.stringify({ version: 1, quoted_context: quotes.map(({ id: _id, ...quote }) => quote) }, null, 2);
  const longest = Math.max(2, ...(payload.match(/`+/g) || []).map(run => run.length));
  const fence = '`'.repeat(longest + 1);
  return [typed.trim(), 'Quoted context (source material):\n' + fence + 'json\n' + payload + '\n' + fence].filter(Boolean).join('\n\n');
}
