import { useEffect, useMemo, useRef } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { artifactsApi } from '../api/endpoints/artifacts';
import { highlightCode, getActiveShikiTheme } from '../utils/codeHighlight';
import { escapeHtml, normalizeMarkdownSource, renderMarkdown } from './markdownRender';

export {
  ARTIFACT_ID_PATTERN,
  RESOURCE_ID_PREFIXES,
  RESOURCE_TYPE_CONFIG,
  artifactIdFromUri,
  autolinkResourceIds,
  escapeHtml,
  renderMarkdown,
} from './markdownRender';
export type { ResourceIdPrefix } from './markdownRender';

export type MermaidRenderer = {
  initialize: (config: Record<string, any>) => void;
  render: (id: string, code: string) => Promise<{ svg: string; bindFunctions?: (element: Element) => void }>;
};

let mermaidInitialized = false;
let mermaidPromise: Promise<MermaidRenderer | null> | null = null;

export async function getMermaid(): Promise<MermaidRenderer | null> {
  if (typeof window === 'undefined') return null;
  const ambient = (globalThis as any).mermaid;
  if (ambient) {
    if (!mermaidInitialized) {
      ambient.initialize({ startOnLoad: false, theme: 'dark', securityLevel: 'loose', suppressErrorRendering: true });
      mermaidInitialized = true;
    }
    return ambient;
  }
  if (!mermaidPromise) {
    mermaidPromise = import('mermaid')
      .then((mod) => {
        const m = (mod.default || mod) as any;
        m.initialize({ startOnLoad: false, theme: 'dark', securityLevel: 'loose', suppressErrorRendering: true });
        mermaidInitialized = true;
        return m as MermaidRenderer;
      })
      .catch((err) => {
        console.warn('Failed to load mermaid:', err);
        return null;
      });
  }
  return mermaidPromise;
}

export type MarkdownTextSelection = {
  selectedText: string;
  rect?: { left: number; bottom: number };
};

export type MarkdownBodyProps = {
  source: string;
  className?: string;
  compact?: boolean;
  copyAll?: boolean;
  'data-debug-id'?: string;
  onArtifactClick?: (artifactId: string) => void;
  onTextSelectionChange?: (selection: MarkdownTextSelection | null) => void;
};

function csvEscape(value: string): string {
  const normalized = String(value || '').replace(/\r?\n/g, ' ').trim();
  if (/[",\n]/.test(normalized)) return `"${normalized.replace(/"/g, '""')}"`;
  return normalized;
}

function tableToCsv(table: HTMLTableElement): string {
  return Array.from(table.querySelectorAll('tr')).map((row) => (
    Array.from(row.querySelectorAll('th,td')).map((cell) => csvEscape(cell.textContent || '')).join(',')
  )).join('\n');
}

export function readMarkdownSelection(root: HTMLElement): MarkdownTextSelection | null {
  const selection = window.getSelection?.() || document.getSelection?.();
  if (!selection || selection.rangeCount !== 1 || selection.isCollapsed) return null;
  const range = selection.getRangeAt(0);
  const commonAncestor = range.commonAncestorContainer;
  if (!root.contains(commonAncestor)) return null;
  if (selection.anchorNode && !root.contains(selection.anchorNode)) return null;
  if (selection.focusNode && !root.contains(selection.focusNode)) return null;
  const excluded = 'button, input, textarea, select, [contenteditable="true"], [data-quote-exclude]';
  const element = (node: Node | null) => node?.nodeType === 1 ? node as Element : node?.parentElement;
  if (element(selection.anchorNode)?.closest(excluded) || element(selection.focusNode)?.closest(excluded)) return null;
  if (Array.from(root.querySelectorAll(excluded)).some(node => range.intersectsNode(node))) return null;
  const selectedText = selection.toString();
  if (!selectedText.trim()) return null;
  const rect = range.getBoundingClientRect?.();
  return { selectedText, rect: rect ? { left: rect.left, bottom: rect.bottom } : undefined };
}

export async function renderMermaidElement(
  container: HTMLElement,
  idx = 0,
  isCancelled: () => boolean = () => false
): Promise<boolean> {
  const mermaid = await getMermaid();
  if (isCancelled()) return false;
  if (!mermaid) {
    container.setAttribute('data-mermaid-rendered', 'unavailable');
    return false;
  }
  const block = container.closest('.mermaid-block') as HTMLElement | null;
  const code = block?.getAttribute('data-mermaid-code') || container.textContent || '';
  if (!code.trim()) return false;

  const uniqueId = `mermaid-svg-${Date.now()}-${idx}-${Math.random().toString(36).substring(2, 8)}`;
  try {
    const { svg, bindFunctions } = await mermaid.render(uniqueId, code);
    if (isCancelled()) return false;
    container.innerHTML = svg;
    container.setAttribute('data-mermaid-rendered', 'true');
    if (bindFunctions && typeof bindFunctions === 'function') {
      bindFunctions(container);
    }
    return true;
  } catch (err) {
    if (isCancelled()) return false;
    console.warn('Mermaid rendering failed:', err);
    container.setAttribute('data-mermaid-rendered', 'error');
    const tempEl = document.getElementById(`d${uniqueId}`) || document.getElementById(uniqueId);
    if (tempEl && tempEl.parentNode) {
      tempEl.parentNode.removeChild(tempEl);
    }
    container.innerHTML = `<div class="mb-2 flex items-center gap-1.5 rounded-md border border-warning/40 bg-warning-soft px-2.5 py-1 text-xs text-warning" data-debug-id="mermaid-syntax-error-indicator"><span>Invalid diagram syntax</span></div><pre class="font-mono text-[12px] leading-relaxed text-primary overflow-x-auto w-full" data-lang="mermaid"><code>${escapeHtml(code)}</code></pre>`;
    return false;
  }
}

export default function MarkdownBody({ source, className, compact, copyAll = true, 'data-debug-id': dataDebugId, onArtifactClick, onTextSelectionChange }: MarkdownBodyProps) {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const html = useMemo(() => renderMarkdown(source || '', copyAll), [source, copyAll]);
  // Compact (chat) spacing lives in `.markdown-compact` (styles.css): a `space-y-*`
  // utility out-specifies the heading/paragraph margins and collapses every gap to 4px.
  const spacing = compact ? 'markdown-compact' : 'space-y-3';
  const dispatch = useDispatch<any>();
  const session = useSelector((state: any) => state.chat?.session || {});
  const clientToken = session?.clientToken || '';

  // Resolve artifact names from metadata and swap them into the rendered chips.
  // Uses textContent (auto-escaped) so no untrusted HTML is injected, and keeps
  // an ID fallback when metadata is unavailable or not yet loaded (UIART-5).
  useEffect(() => {
    const root = rootRef.current;
    if (!root) return undefined;
    const chips = Array.from(root.querySelectorAll('[data-artifact-id]')) as HTMLElement[];
    if (chips.length === 0) return undefined;
    let cancelled = false;
    const applyName = (artifactId: string, name: string) => {
      if (cancelled || !name) return;
      const nodes = Array.from(root.querySelectorAll(`[data-artifact-id="${artifactId}"]`)) as HTMLElement[];
      nodes.forEach((node) => {
        const label = node.querySelector('[data-artifact-label="true"]') as HTMLElement | null;
        if (label) label.textContent = name;
      });
    };
    chips.forEach((chip) => {
      const artifactId = chip.getAttribute('data-artifact-id') || '';
      if (!artifactId) return;
      if (!clientToken) return; // leave ID fallback in place
      const request = dispatch(artifactsApi.endpoints.fetchArtifactMeta.initiate({ artifactId }, { subscribe: false }));
      request.unwrap()
        .then((data: any) => applyName(artifactId, String(data?.artifact?.name || '')))
        .catch(() => undefined)
        .finally(() => { request.unsubscribe?.(); });
    });
    return () => { cancelled = true; };
  }, [html, clientToken, dispatch]);

  useEffect(() => {
    const root = rootRef.current;
    if (!root) return undefined;
    const containers = Array.from(root.querySelectorAll('.mermaid-block [data-mermaid-rendered="false"]')) as HTMLElement[];
    if (containers.length === 0) return undefined;

    let cancelled = false;

    containers.forEach((container, idx) => {
      renderMermaidElement(container, idx, () => cancelled);
    });

    return () => {
      cancelled = true;
    };
  }, [html]);

  useEffect(() => {
    const root = rootRef.current;
    if (!root) return undefined;
    const containers = Array.from(root.querySelectorAll('[data-shiki-rendered="false"]')) as HTMLElement[];
    if (containers.length === 0) return undefined;

    let cancelled = false;
    const activeTheme = getActiveShikiTheme();

    containers.forEach(async (container) => {
      const code = container.getAttribute('data-code-raw') ?? container.querySelector('pre code')?.textContent ?? container.textContent ?? '';
      const lang = container.getAttribute('data-code-lang') || '';
      if (!code.trim() || !lang.trim()) {
        container.setAttribute('data-shiki-rendered', 'fallback');
        return;
      }

      try {
        const highlighted = await highlightCode(code, lang, activeTheme);
        if (cancelled) return;
        if (highlighted) {
          container.innerHTML = highlighted;
          container.setAttribute('data-shiki-rendered', 'true');
        } else {
          container.setAttribute('data-shiki-rendered', 'fallback');
        }
      } catch {
        if (cancelled) return;
        container.setAttribute('data-shiki-rendered', 'fallback');
      }
    });

    return () => {
      cancelled = true;
    };
  }, [html]);

  useEffect(() => {
    const root = rootRef.current;
    if (!root) return undefined;
    const onClick = async (event: MouseEvent) => {
      const target = event.target as HTMLElement | null;
      const artifactButton = target?.closest?.('[data-artifact-id]') as HTMLButtonElement | null;
      if (artifactButton) {
        event.preventDefault();
        const artifactId = String(artifactButton.getAttribute('data-artifact-id') || '');
        if (artifactId && onArtifactClick) onArtifactClick(artifactId);
        return;
      }
      const button = target?.closest?.('[data-markdown-copy-code="true"],[data-markdown-copy-table="true"],[data-markdown-copy-all="true"]') as HTMLButtonElement | null;
      if (button) {
        let text = '';
        if (button.matches('[data-markdown-copy-all="true"]')) {
          text = button.getAttribute('data-markdown-source') || normalizeMarkdownSource(source || '');
        } else if (button.matches('[data-markdown-copy-code="true"]')) {
          const wrapper = button.closest('.group');
          text = wrapper?.getAttribute('data-mermaid-code')
            || wrapper?.querySelector('[data-code-raw]')?.getAttribute('data-code-raw')
            || wrapper?.getAttribute('data-code-raw')
            || wrapper?.querySelector('pre code')?.textContent
            || wrapper?.querySelector('pre')?.textContent
            || '';
        } else {
          const wrapper = button.closest('.markdown-table');
          const table = wrapper?.querySelector('table') as HTMLTableElement | null;
          text = table ? tableToCsv(table) : '';
        }
        if (!text) return;
        await navigator.clipboard?.writeText(text).catch(() => undefined);
        if (button.matches('[data-markdown-copy-all="true"]')) {
          // The glyph is an inline SVG from the icon set, so the "copied" feedback
          // swaps MARKUP, not text — assigning textContent here would wipe the icon.
          const iconSpan = (button.querySelector('span') || button) as HTMLElement;
          const prevMarkup = iconSpan.innerHTML;
          const prevTitle = button.getAttribute('title') || 'Copy entire markdown';
          iconSpan.innerHTML = `<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m5 13 4 4L19 7"></path></svg>`;
          button.setAttribute('title', 'Copied!');
          window.setTimeout(() => {
            iconSpan.innerHTML = prevMarkup;
            button.setAttribute('title', prevTitle);
          }, 1200);
          return;
        }
        const previous = button.getAttribute('data-original-text') || button.textContent || 'Copy';
        if (!button.getAttribute('data-original-text')) {
          button.setAttribute('data-original-text', previous);
        }
        button.textContent = 'Copied';
        window.setTimeout(() => { button.textContent = previous; }, 1200);
        return;
      }

    const resourceAnchor = target?.closest?.('a[data-resource-id],a[href^="#/"]') as HTMLAnchorElement | null;
    if (resourceAnchor) {
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
        return;
      }
      const href = resourceAnchor.getAttribute('href') || '';
      if (href.startsWith('#/')) {
        event.preventDefault();
        const targetHash = href.startsWith('#') ? href.slice(1) : href;
        if (window.location.hash === targetHash || window.location.hash === `#${targetHash}`) {
          window.dispatchEvent(new Event('hashchange'));
        } else {
          window.location.hash = targetHash;
        }
        return;
      }
    }
  };
    root.addEventListener('click', onClick);
    return () => root.removeEventListener('click', onClick);
  }, [html, source, onArtifactClick]);

  useEffect(() => {
    const root = rootRef.current;
    if (!root || !onTextSelectionChange) return undefined;
    const emitSelection = () => onTextSelectionChange(readMarkdownSelection(root));
    root.addEventListener('mouseup', emitSelection);
    root.addEventListener('keyup', emitSelection);
    root.addEventListener('touchend', emitSelection);
    document.addEventListener('selectionchange', emitSelection);
    return () => {
      root.removeEventListener('mouseup', emitSelection);
      root.removeEventListener('keyup', emitSelection);
      root.removeEventListener('touchend', emitSelection);
      document.removeEventListener('selectionchange', emitSelection);
    };
  }, [html, onTextSelectionChange]);

  return (
    <div
      ref={rootRef}
      data-debug-id={dataDebugId}
      className={`markdown min-w-0 max-w-full overflow-hidden break-words [overflow-wrap:anywhere] ${spacing} text-sm text-primary ${className || ''}`}
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}
