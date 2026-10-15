import { useEffect, useMemo, useRef } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { artifactsApi } from '../api/endpoints/artifacts';
import { highlightCode, getActiveShikiTheme } from '../utils/codeHighlight';

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

export function resetMermaidForTesting(): void {
  mermaidPromise = null;
  mermaidInitialized = false;
}

export type MarkdownTextSelection = {
  selectedText: string;
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

export const ARTIFACT_ID_PATTERN = 'art_[0-9A-Za-z][0-9A-Za-z_]*';
const ARTIFACT_URI_PATTERN = `artifact://(${ARTIFACT_ID_PATTERN})`;
const ARTIFACT_TOKEN_RE = new RegExp(`(^|[^"'>])(${ARTIFACT_URI_PATTERN})`, 'g');
const ARTIFACT_MARKDOWN_LINK_RE = new RegExp(`\\[([^\\]\\n]+)\\]\\((${ARTIFACT_URI_PATTERN})\\)`, 'g');
const ARTIFACT_URI_ONLY_RE = new RegExp(`^artifact://(${ARTIFACT_ID_PATTERN})$`);

export const RESOURCE_ID_PREFIXES = ['agt_', 'iss_', 'inst_', 'mem_', 'proj_', 'chain_', 'act_', 'sh_'] as const;
export type ResourceIdPrefix = typeof RESOURCE_ID_PREFIXES[number];

export const RESOURCE_TYPE_CONFIG: Record<ResourceIdPrefix, { route: string; type: string }> = {
  agt_: { route: 'agents', type: 'agent' },
  iss_: { route: 'issues', type: 'issue' },
  inst_: { route: 'conversations', type: 'conversation' },
  mem_: { route: 'memory', type: 'memory' },
  proj_: { route: 'projects', type: 'project' },
  chain_: { route: 'chains', type: 'chain' },
  act_: { route: 'actions', type: 'action' },
  sh_: { route: 'shells', type: 'shell' },
};

const RESOURCE_ID_RE = /(^|[^A-Za-z0-9_])((?:agt_|iss_|inst_|mem_|proj_|chain_|act_|sh_)[A-Za-z0-9_-]+)(?=[^A-Za-z0-9_-]|$)/g;

export function autolinkResourceIds(html: string): string {
  if (!html) return '';
  const tokens = html.split(/(<[^>]+>)/g);
  let inAnchor = 0;
  let inButton = 0;
  let inCode = 0;
  let inPre = 0;

  return tokens.map((token) => {
    if (token.startsWith('<') && token.endsWith('>')) {
      const isClosing = token.startsWith('</');
      const isSelfClosing = token.endsWith('/>');
      const tagMatch = token.match(/^<\/?\s*([a-zA-Z0-9]+)/);
      const tag = tagMatch ? tagMatch[1].toLowerCase() : '';

      if (isClosing) {
        if (tag === 'a') inAnchor = Math.max(0, inAnchor - 1);
        else if (tag === 'button') inButton = Math.max(0, inButton - 1);
        else if (tag === 'code') inCode = Math.max(0, inCode - 1);
        else if (tag === 'pre') inPre = Math.max(0, inPre - 1);
      } else if (!isSelfClosing) {
        if (tag === 'a') inAnchor++;
        else if (tag === 'button') inButton++;
        else if (tag === 'code') inCode++;
        else if (tag === 'pre') inPre++;
      }
      return token;
    }

    if (inAnchor > 0 || inButton > 0 || inCode > 0 || inPre > 0) {
      return token;
    }

    return token.replace(RESOURCE_ID_RE, (_full, prefixChar, id) => {
      const prefix = (RESOURCE_ID_PREFIXES as readonly string[]).find((p) => id.startsWith(p)) as ResourceIdPrefix | undefined;
      if (!prefix) return _full;
      const { route, type } = RESOURCE_TYPE_CONFIG[prefix];
      return `${prefixChar}<a href="#/${route}/${id}" data-resource-id="${id}" data-resource-type="${type}" class="font-mono text-accent underline decoration-accent/40 hover:decoration-accent">${id}</a>`;
    });
  }).join('');
}

export function artifactIdFromUri(value: string): string {
  const match = String(value || '').trim().match(ARTIFACT_URI_ONLY_RE);
  return match?.[1] || '';
}

export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function normalizeMarkdownSource(source: string): string {
  return String(source || '').replace(/\\n/g, '\n');
}

function createArtifactButtonHtml(artifactId: string, initialLabelHtml = ''): string {
  const safeArtifactId = escapeHtml(artifactId);
  const initialText = initialLabelHtml || safeArtifactId;
  return `<button type="button" data-artifact-id="${safeArtifactId}" data-artifact-link="true" data-debug-id="artifact-link-chip-${safeArtifactId}" title="Open artifact" class="inline-flex items-center gap-1 rounded-full border border-accent/30 bg-info-soft px-2.5 py-0.5 text-xs font-medium text-accent hover:bg-neutral-soft"><span aria-hidden="true" class="inline-flex"><svg viewBox=\"0 0 24 24\" width=\"12\" height=\"12\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.7\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\"><path d=\"M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z\"></path><path d=\"M14 3v5h5\"></path></svg></span><span data-artifact-label="true">${initialText}</span></button>`;
}

function renderInline(text: string): string {
  let escaped = escapeHtml(text);
  escaped = escaped.replace(/`([^`\n]+)`/g, (_m, code) => `<code class="font-mono text-[0.85em] font-medium text-accent">${code}</code>`);
  escaped = escaped.replace(/(?:‘|’)([^‘’\n]+?)(?:’|‘)/g, '‘<span class="text-accent font-medium">$1</span>’');
  escaped = escaped.replace(/(^|[\s(\[{<])(?:&#39;|')(?![\s])([^'‘’\n]+?)(?<![\s])(?:&#39;|')(?=[\]}>)\s.,;:!?]|$)/g, '$1‘<span class="text-accent font-medium">$2</span>’');
  escaped = escaped.replace(/\*\*\*([^*\n]+)\*\*\*/g, '<strong><em>$1</em></strong>');
  escaped = escaped.replace(/(^|[^A-Za-z0-9_])___([^_\n]+)___(?![A-Za-z0-9_])/g, '$1<strong><em>$2</em></strong>');
  escaped = escaped.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
  escaped = escaped.replace(/(^|[^A-Za-z0-9_])__([^_\n]+)__(?![A-Za-z0-9_])/g, '$1<strong>$2</strong>');
  escaped = escaped.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
  escaped = escaped.replace(/(^|[^A-Za-z0-9_])_([^_\s](?:[^_\n]*?[^_\s])?)_(?![A-Za-z0-9_])/g, '$1<em>$2</em>');
  escaped = escaped.replace(/~~([^~\n]+)~~/g, '<del>$1</del>');
  escaped = escaped.replace(ARTIFACT_MARKDOWN_LINK_RE, (_m, label, _link, artifactId) => createArtifactButtonHtml(artifactId, label));
  escaped = escaped.replace(ARTIFACT_TOKEN_RE, (_m, prefix, _link, artifactId) => {
    // Initial visible text is the artifact ID (safe fallback). A React-side
    // effect asynchronously swaps in the resolved artifact name when available.
    return `${prefix}${createArtifactButtonHtml(artifactId)}`;
  });
  escaped = escaped.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+|#[^\s)]+|\/[^\s)]+)\)/g, (_m, label, url) => {
    const isExternal = /^https?:\/\//i.test(url);
    const targetRel = isExternal ? ' target="_blank" rel="noreferrer"' : '';
    return `<a href="${url}"${targetRel} class="text-accent underline decoration-accent/40 hover:decoration-accent">${label}</a>`;
  });
  escaped = escaped.replace(/(^|[^"'>])((?:https?:\/\/)[\w\-._~:\/?#\[\]@!$&'()*+,;=%]+[\w\-_~:\/?#\[\]@!$&'()*+;=%])/g, (_m, prefix, url) => {
    return `${prefix}<a href="${url}" target="_blank" rel="noreferrer" class="text-accent underline decoration-accent/40 hover:decoration-accent">${url}</a>`;
  });
  return autolinkResourceIds(escaped);
}

function splitTableRow(line: string): string[] {
  let trimmed = line.trim();
  if (trimmed.startsWith('|')) trimmed = trimmed.slice(1);
  if (trimmed.endsWith('|')) trimmed = trimmed.slice(0, -1);
  const cells: string[] = [];
  let current = '';
  let escaped = false;
  for (const ch of trimmed) {
    if (escaped) {
      current += ch;
      escaped = false;
      continue;
    }
    if (ch === '\\') {
      escaped = true;
      continue;
    }
    if (ch === '|') {
      cells.push(current.trim());
      current = '';
    } else {
      current += ch;
    }
  }
  cells.push(current.trim());
  return cells;
}

function isTableSeparator(line: string): boolean {
  const cells = splitTableRow(line);
  return cells.length > 0 && cells.every((cell) => /^:?-{3,}:?$/.test(cell.trim()));
}

function isLikelyTableHeader(line: string, next?: string): boolean {
  return Boolean(next && line.includes('|') && isTableSeparator(next));
}

function renderTable(lines: string[], start: number): { html: string; nextIndex: number } {
  const headers = splitTableRow(lines[start]);
  const aligns = splitTableRow(lines[start + 1]).map((cell) => {
    const trimmed = cell.trim();
    if (trimmed.startsWith(':') && trimmed.endsWith(':')) return 'text-center';
    if (trimmed.endsWith(':')) return 'text-right';
    return 'text-left';
  });
  const rows: string[][] = [];
  let i = start + 2;
  while (i < lines.length && lines[i].trim() !== '' && lines[i].includes('|') && !/^```/.test(lines[i])) {
    rows.push(splitTableRow(lines[i]));
    i += 1;
  }
  const head = headers.map((cell, idx) => `<th class="whitespace-nowrap border-b border-subtle px-3 py-2 ${aligns[idx] || 'text-left'} font-semibold text-primary">${renderInline(cell)}</th>`).join('');
  const body = rows.map((row) => `<tr>${headers.map((_h, idx) => `<td class="whitespace-nowrap border-b border-subtle px-3 py-2 align-top ${aligns[idx] || 'text-left'}">${renderInline(row[idx] || '')}</td>`).join('')}</tr>`).join('');
  return {
    html: `<div class="markdown-table my-2 overflow-hidden rounded-xl border border-subtle"><div class="flex items-center justify-between border-b border-subtle bg-surface-raised px-3 py-1.5 text-caption text-muted"><span>table</span><button type="button" data-markdown-copy-table="true" class="rounded-md bg-neutral-soft px-2 py-1 text-xs text-primary opacity-80 hover:bg-surface-raised hover:opacity-100">Copy CSV</button></div><div class="overflow-x-auto"><table class="min-w-full border-collapse text-left text-sm"><thead class="bg-surface-raised"><tr>${head}</tr></thead><tbody>${body}</tbody></table></div></div>`,
    nextIndex: i,
  };
}

const HEADING_STYLES: Record<number, { tag: string; className: string }> = {
  1: { tag: 'h1', className: 'mt-3 text-xl font-bold text-accent' },
  2: { tag: 'h2', className: 'mt-2.5 text-lg font-semibold text-primary' },
  3: { tag: 'h3', className: 'mt-2 text-base font-medium text-muted' },
  4: { tag: 'h4', className: 'mt-1.5 text-sm font-medium text-muted' },
  5: { tag: 'h5', className: 'mt-1 text-xs font-medium text-muted' },
  6: { tag: 'h6', className: 'mt-1 text-xs font-medium text-muted' },
};

function renderBlocks(source: string): string {
  const lines = normalizeMarkdownSource(source).replace(/\r\n?/g, '\n').split('\n');
  const out: string[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const fence = line.match(/^```([\w+-]*)\s*$/);
    if (fence) {
      const lang = fence[1] || '';
      const body: string[] = [];
      i += 1;
      while (i < lines.length && !/^```\s*$/.test(lines[i])) {
        body.push(lines[i]);
        i += 1;
      }
      if (i < lines.length) i += 1;
      const escapedCode = escapeHtml(body.join('\n'));
      const langLabel = escapeHtml(lang || 'code');
      if (/^(?:mermaid|mermedai)$/i.test((lang || '').trim())) {
        out.push(`<div class="group my-2 overflow-hidden rounded-xl border border-subtle bg-surface mermaid-block" data-mermaid-code="${escapedCode}"><div class="flex items-center justify-between border-b border-subtle px-3 py-1.5 text-caption text-muted"><span class="font-mono">mermaid</span><button type="button" data-markdown-copy-code="true" data-debug-id="markdown-copy-code-btn" class="rounded-md bg-neutral-soft px-2 py-1 text-xs text-primary opacity-80 hover:bg-surface-raised hover:opacity-100">Copy</button></div><div class="mermaid-diagram-container p-3 overflow-x-auto flex flex-col items-center justify-center bg-surface-raised" data-mermaid-rendered="false"><pre class="font-mono text-[12px] leading-relaxed text-primary text-left w-full" data-lang="mermaid"><code>${escapedCode}</code></pre></div></div>`);
        continue;
      }
      out.push(`<div class="group my-2 overflow-hidden rounded-xl border border-subtle bg-surface" data-code-block="true"><div class="flex items-center justify-between border-b border-subtle px-3 py-1.5 text-caption text-muted"><span class="font-mono">${langLabel}</span><button type="button" data-markdown-copy-code="true" data-debug-id="markdown-copy-code-btn" class="rounded-md bg-neutral-soft px-2 py-1 text-xs text-primary opacity-80 hover:bg-surface-raised hover:opacity-100">Copy</button></div><div class="code-container" data-shiki-rendered="false" data-code-raw="${escapedCode}" data-code-lang="${escapeHtml(lang)}"><pre class="overflow-x-auto p-3 font-mono text-[12px] leading-relaxed text-primary" data-lang="${escapeHtml(lang)}"><code>${escapedCode}</code></pre></div></div>`);
      continue;
    }
    if (line.trim() === '') { i += 1; continue; }
    const heading = line.match(/^(#{1,6})\s+(.+?)\s*#*$/);
    if (heading) {
      const level = heading[1].length;
      const headingStyle = HEADING_STYLES[level] || HEADING_STYLES[6];
      out.push(`<${headingStyle.tag} class="${headingStyle.className}">${renderInline(heading[2])}</${headingStyle.tag}>`);
      i += 1;
      continue;
    }
    if (isLikelyTableHeader(line, lines[i + 1])) {
      const table = renderTable(lines, i);
      out.push(table.html);
      i = table.nextIndex;
      continue;
    }
    if (line.startsWith('> ')) {
      const quote: string[] = [];
      while (i < lines.length && lines[i].startsWith('> ')) {
        quote.push(lines[i].slice(2));
        i += 1;
      }
      out.push(`<blockquote class="my-1 border-l-2 border-accent/40 pl-3 text-muted">${renderInline(quote.join(' '))}</blockquote>`);
      continue;
    }
    if (/^[-*+]\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^[-*+]\s+/.test(lines[i])) {
        items.push(`<li>${renderInline(lines[i].replace(/^[-*+]\s+/, ''))}</li>`);
        i += 1;
      }
      out.push(`<ul class="my-1 list-disc space-y-0.5 pl-5">${items.join('')}</ul>`);
      continue;
    }
    if (/^\d+\.\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\d+\.\s+/.test(lines[i])) {
        items.push(`<li>${renderInline(lines[i].replace(/^\d+\.\s+/, ''))}</li>`);
        i += 1;
      }
      out.push(`<ol class="my-1 list-decimal space-y-0.5 pl-5">${items.join('')}</ol>`);
      continue;
    }
    if (/^(---|\*\*\*|___)\s*$/.test(line)) {
      out.push('<hr class="my-2 border-subtle" />');
      i += 1;
      continue;
    }
    const paragraph: string[] = [line];
    i += 1;
    while (i < lines.length && lines[i].trim() !== '' && !isLikelyTableHeader(lines[i], lines[i + 1]) && !/^(?:#{1,6}\s+|>\s+|[-*+]\s+|\d+\.\s+|```)/.test(lines[i])) {
      paragraph.push(lines[i]);
      i += 1;
    }
    out.push(`<p class="my-3 leading-relaxed">${paragraph.map((chunk) => renderInline(chunk)).join('<br />')}</p>`);
  }
  return out.join('');
}

export function renderMarkdown(source: string, copyAll = true): string {
  if (!source) return '';
  const raw = normalizeMarkdownSource(source);
  if (!raw.trim()) return '';
  if (!copyAll) return renderBlocks(source);
  const escapedSource = escapeHtml(raw);
  const copyBtn = `<div class="mb-1 flex items-center justify-end"><button type="button" data-markdown-copy-all="true" data-debug-id="markdown-copy-all-btn" data-markdown-source="${escapedSource}" title="Copy entire markdown" class="inline-flex h-6 w-6 items-center justify-center rounded-md border border-subtle bg-surface text-muted opacity-60 transition hover:bg-surface-raised hover:text-primary hover:opacity-100"><span aria-hidden="true" class="inline-flex"><svg viewBox=\"0 0 24 24\" width=\"14\" height=\"14\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.7\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\"><rect x=\"9\" y=\"9\" width=\"11\" height=\"11\" rx=\"2\"></rect><path d=\"M5 15V6a2 2 0 0 1 2-2h8\"></path></svg></span></button></div>`;
  return copyBtn + renderBlocks(source);
}

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

function readMarkdownSelection(root: HTMLElement): MarkdownTextSelection | null {
  const selection = window.getSelection?.() || document.getSelection?.();
  if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
  const range = selection.getRangeAt(0);
  const commonAncestor = range.commonAncestorContainer;
  if (!root.contains(commonAncestor)) return null;
  if (selection.anchorNode && !root.contains(selection.anchorNode)) return null;
  if (selection.focusNode && !root.contains(selection.focusNode)) return null;
  const selectedText = selection.toString().replace(/\s+/g, ' ').trim();
  if (!selectedText) return null;
  return { selectedText };
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
    return () => {
      root.removeEventListener('mouseup', emitSelection);
      root.removeEventListener('keyup', emitSelection);
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
