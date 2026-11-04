import { useLayoutEffect, useRef, type RefObject } from 'react';

// Incoming-reply text reveal (phase 3 of the incoming-message spec). The chat has no token
// streaming: a reply reaches the UI whole, and this reveals it word by word so it reads
// like ink soaking in behind a cursor. The markdown is always parsed from the FULL source
// (so a half-finished `**` or list never flashes raw syntax). The revealer then works on
// the rendered DOM. Each run of text becomes `<span class="stream-chunk">` word tokens,
// identified by their character offset in the rendered text. Anything past the revealed
// length is transparent (styles.css `[data-sr="h"]`) but keeps its box, so the reply's
// layout is final from the first frame and nothing reflows (user, 2026-11-04 11:34).
// Each newly revealed word fades 0 -> 1 over STREAM_CHUNK_MS, staggered so the whole
// reveal takes min(length-based, STREAM_MAX_TOTAL_MS). Blocks (bullets, headings, table
// rows, code containers) fade in with their first word. A reply longer than
// STREAM_BLOCK_MODE_WORDS fades in per top-level block instead.
//
// The input is a growing `revealed` length over the rendered text, so real streaming
// deltas can plug in later. A longer source re-renders the HTML, `index()` rebuilds the
// tokens, and everything below the previous length shows at once while only the new
// tail animates. Earlier text never re-animates.

export const STREAM_CHUNK_MS = 350;
/** Stagger between consecutive words (spec: 15–25ms per word); shrinks for long replies. */
export const STREAM_WORD_STAGGER_MS = 20;
/** The whole simulated reveal, last word's fade included, never exceeds this. */
export const STREAM_MAX_TOTAL_MS = 1200;
/** Past this many words the reply fades in per top-level block, not per word. */
export const STREAM_BLOCK_MODE_WORDS = 400;
/** Stagger between top-level blocks in block mode. */
export const STREAM_BLOCK_STAGGER_MS = 60;

// Blocks that fade in as a unit with their first content. Paragraph text needs no block
// fade, since its words fade themselves.
const BLOCK_FADE = new Set(['LI', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'TR', 'BLOCKQUOTE', 'HR', 'IMG']);
const isContainer = (el: Element) => el.matches('[data-code-block="true"], .mermaid-block, .markdown-table');

type Item = { el: HTMLElement; start: number; token: boolean };

/**
 * Per-unit stagger (ms) for `units` words (or blocks), so the length-based reveal
 * (`units * base`) plus the last fade fits in STREAM_MAX_TOTAL_MS.
 */
export function revealStagger(units: number, base = STREAM_WORD_STAGGER_MS): number {
  if (units <= 1) return base;
  return Math.min(base, (STREAM_MAX_TOTAL_MS - STREAM_CHUNK_MS) / (units - 1));
}

export class StreamRevealer {
  readonly root: HTMLElement;
  /** Characters of rendered text revealed so far. */
  revealed = 0;
  total = 0;
  /** End offsets of the tokens holding a word, in order (whitespace-only tokens excluded). */
  wordEnds: number[] = [];
  /** Per-word tokens, or per top-level block for very long replies. */
  readonly mode: 'words' | 'blocks';
  private items: Item[] = [];
  private next = 0;
  private revealedAll = false;

  constructor(root: HTMLElement, mode?: 'words' | 'blocks') {
    this.root = root;
    this.mode = mode ?? ((root.textContent || '').match(/\S+/g)?.length || 0) > STREAM_BLOCK_MODE_WORDS ? 'blocks' : 'words';
  }

  /**
   * (Re)builds the token index from the current DOM and applies the revealed state
   * without animation. It is safe to call after any rewrite of the subtree (a new HTML
   * string, Shiki highlighting, Mermaid). Text that already had tokens keeps them.
   */
  index(): void {
    const doc = this.root.ownerDocument;
    const items: Item[] = [];
    const wordEnds: number[] = [];
    let offset = 0;
    const visit = (node: Node) => {
      for (let child = node.firstChild; child; ) {
        const following = child.nextSibling;
        if (this.mode === 'blocks' && node === this.root) {
          // Block mode: each top-level child is one unit, its text left untouched.
          const text = child.textContent || '';
          if (child.nodeType === 1) {
            items.push({ el: child as HTMLElement, start: offset, token: false });
            if (/\S/.test(text)) wordEnds.push(offset + text.length);
          } else if (child.nodeType === 3 && /\S/.test(text)) {
            const span = doc.createElement('span');
            span.textContent = text;
            node.replaceChild(span, child);
            items.push({ el: span, start: offset, token: false });
            wordEnds.push(offset + text.length);
          }
          offset += text.length;
          child = following;
          continue;
        }
        if (child.nodeType === 3) {
          const text = child.nodeValue || '';
          if (text) {
            const parts = text.match(/\S+\s*|\s+/g) || [text];
            const fragment = doc.createDocumentFragment();
            for (const part of parts) {
              const span = doc.createElement('span');
              span.className = 'stream-chunk';
              span.textContent = part;
              fragment.appendChild(span);
              items.push({ el: span, start: offset, token: true });
              offset += part.length;
              if (/\S/.test(part)) wordEnds.push(offset);
            }
            node.replaceChild(fragment, child);
          }
        } else if (child.nodeType === 1) {
          const el = child as HTMLElement;
          if (el.classList.contains('stream-chunk')) {
            const text = el.textContent || '';
            items.push({ el, start: offset, token: true });
            offset += text.length;
            if (/\S/.test(text)) wordEnds.push(offset);
          } else {
            items.push({ el, start: offset, token: false });
            // SVG (icons, Mermaid output) is a leaf: an HTML span is not valid inside it.
            if (el.namespaceURI === 'http://www.w3.org/1999/xhtml') visit(el);
          }
        }
        child = following;
      }
    };
    visit(this.root);
    this.items = items;
    this.wordEnds = wordEnds;
    this.total = offset;
    this.revealed = Math.min(this.revealed, offset);
    let next = items.length;
    for (let i = 0; i < items.length; i += 1) {
      const item = items[i];
      if (this.isShown(item.start)) {
        if (item.el.getAttribute('data-sr') === 'h') item.el.removeAttribute('data-sr');
      } else {
        if (next === items.length) next = i;
        item.el.setAttribute('data-sr', 'h');
      }
    }
    this.next = next;
  }

  private isShown(start: number): boolean {
    return start < this.revealed || (this.revealed >= this.total && this.total > 0) || this.revealedAll;
  }

  /**
   * Reveals everything below `length` (characters of rendered text). Newly shown words
   * fade with `stagger` ms between them, and a block fades with its first word. In block
   * mode every top-level block is one unit. Returns the delay (ms) of the last unit
   * started, or -1 if none.
   */
  reveal(length: number, animate: boolean, stagger = STREAM_WORD_STAGGER_MS): number {
    this.revealed = Math.max(this.revealed, Math.min(length, this.total));
    if (length >= this.total) this.revealedAll = true;
    let word = -1;
    let lastDelay = -1;
    while (this.next < this.items.length && this.isShown(this.items[this.next].start)) {
      const { el, token } = this.items[this.next];
      this.next += 1;
      if (!animate) { el.removeAttribute('data-sr'); continue; }
      if (this.mode === 'blocks') {
        word += 1;
        const delay = Math.round(word * stagger);
        el.setAttribute('data-sr', 'b');
        el.style.animationDelay = `${delay}ms`;
        lastDelay = delay;
        continue;
      }
      if (token) {
        if (/\S/.test(el.textContent || '')) word += 1;
        const delay = Math.round(Math.max(0, word) * stagger);
        el.setAttribute('data-sr', 'in');
        el.style.animationDelay = `${delay}ms`;
        lastDelay = Math.max(lastDelay, delay);
      } else if (isContainer(el) || BLOCK_FADE.has(el.tagName)) {
        el.setAttribute('data-sr', isContainer(el) ? 'c' : 'b');
        el.style.animationDelay = `${Math.round(Math.max(0, word + 1) * stagger)}ms`;
      } else {
        el.removeAttribute('data-sr');
      }
    }
    return lastDelay;
  }

  get done(): boolean {
    return this.next >= this.items.length;
  }
}

export type StreamRevealOptions = {
  /** Animate this body. False renders it instantly (history, reduced motion). */
  enabled: boolean;
  /** Keep everything hidden (for example while a vault body decrypts). */
  hold?: boolean;
  /** Called once, after the last word has finished fading in. */
  onSettled?: () => void;
};

/**
 * Drives a StreamRevealer over `rootRef`'s rendered markdown. `html` is the rendered
 * string. A new value means the subtree was replaced and is re-indexed, keeping what was
 * already revealed. Runs in a layout effect, so hidden text never paints first.
 */
export function useStreamReveal(rootRef: RefObject<HTMLElement | null>, html: string, options: StreamRevealOptions | undefined) {
  const enabled = Boolean(options?.enabled);
  const hold = Boolean(options?.hold);
  const revealerRef = useRef<StreamRevealer | null>(null);
  const settledRef = useRef(false);
  const onSettledRef = useRef(options?.onSettled);
  onSettledRef.current = options?.onSettled;

  useLayoutEffect(() => {
    const root = rootRef.current;
    if (!root) return undefined;
    if (!enabled || settledRef.current) {
      // Turned off mid-reveal (or already settled): show everything at once.
      const revealer = revealerRef.current;
      if (revealer && revealer.root === root) {
        revealer.index();
        revealer.reveal(Number.MAX_SAFE_INTEGER, false);
      }
      // A live reply rendered without its reveal still settles, so its chrome shows.
      if (options && !settledRef.current) {
        settledRef.current = true;
        onSettledRef.current?.();
      }
      return undefined;
    }
    let revealer = revealerRef.current;
    if (!revealer || revealer.root !== root) revealer = revealerRef.current = new StreamRevealer(root);
    revealer.index();
    if (hold) return undefined;

    // One pass: every word not yet revealed starts now, staggered with CSS delays, so the
    // whole reveal takes min(length-based, STREAM_MAX_TOTAL_MS). A later re-index (a
    // longer source from real streaming) reveals only the new tail the same way.
    let timer = 0;
    const run = () => {
      const r = revealer!;
      const pending = r.wordEnds.filter((end) => end > r.revealed).length;
      const stagger = revealStagger(pending, r.mode === 'blocks' ? STREAM_BLOCK_STAGGER_MS : STREAM_WORD_STAGGER_MS);
      const lastDelay = r.reveal(Number.MAX_SAFE_INTEGER, true, stagger);
      timer = window.setTimeout(() => {
        if (settledRef.current) return;
        settledRef.current = true;
        onSettledRef.current?.();
      }, Math.max(0, lastDelay) + STREAM_CHUNK_MS);
    };
    timer = window.setTimeout(run, 0);

    // Shiki and Mermaid rewrite code containers after the HTML lands. Re-index so the
    // new text nodes get tokens in their current state (shown or hidden), with no fade.
    const Observer = (root.ownerDocument.defaultView as any)?.MutationObserver as typeof MutationObserver | undefined;
    const observer = Observer ? new Observer(() => {
      observer!.disconnect();
      revealer!.index();
      observer!.takeRecords();
      observer!.observe(root, { childList: true, subtree: true, characterData: true });
    }) : null;
    observer?.observe(root, { childList: true, subtree: true, characterData: true });
    return () => {
      window.clearTimeout(timer);
      observer?.disconnect();
    };
    // `html` re-runs the effect on a new rendered subtree.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rootRef, html, enabled, hold]);
}

/**
 * Settles a live reply whose body renders without a reveal (a locked vault's VaultText
 * or redacted Markdown, a failed decrypt), so its action row and meta line still show.
 * Pass `undefined` while the reveal is rendered. Hooks cannot sit behind the body's early returns, so callers pass
 * the reveal only for the branches that drop it.
 */
export function useSettleWithoutReveal(reveal: StreamRevealOptions | undefined): void {
  const onSettledRef = useRef(reveal?.onSettled);
  onSettledRef.current = reveal?.onSettled;
  const dropped = Boolean(reveal);
  useLayoutEffect(() => { if (dropped) onSettledRef.current?.(); }, [dropped]);
}
