/**
 * Pure markdown -> HTML renderer used by MarkdownBody (no React / DOM), so its
 * parsing rules can be executed directly by tests.
 */
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

/**
 * Some senders deliver a whole message on one line with literal `\n` escapes; only
 * then are those expanded. A message that already has real newlines keeps its
 * literal `\n` (e.g. `printf("a\n")` inside code).
 */
export function normalizeMarkdownSource(source: string): string {
  const text = String(source || '');
  return text.includes('\n') ? text : text.replace(/\\n/g, '\n');
}

function createArtifactButtonHtml(artifactId: string, initialLabelHtml = ''): string {
  const safeArtifactId = escapeHtml(artifactId);
  const initialText = initialLabelHtml || safeArtifactId;
  return `<button type="button" data-artifact-id="${safeArtifactId}" data-artifact-link="true" data-debug-id="artifact-link-chip-${safeArtifactId}" title="Open artifact" class="inline-flex items-center gap-1 rounded-full border border-accent/30 bg-info-soft px-2.5 py-0.5 text-xs font-medium text-accent hover:bg-neutral-soft"><span aria-hidden="true" class="inline-flex"><svg viewBox=\"0 0 24 24\" width=\"12\" height=\"12\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.7\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\"><path d=\"M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z\"></path><path d=\"M14 3v5h5\"></path></svg></span><span data-artifact-label="true">${initialText}</span></button>`;
}

// Inline placeholders: `\u0000<n>\u0000` stands for already-rendered HTML (code
// spans, escapes, links, URLs) so later emphasis/quote rules can never reach
// inside it. Restored at the end of renderInline.
const STASH_RE = /\u0000(\d+)\u0000/g;
const INLINE_TOKEN_RE = /\\([\\`*_{}[\]()#+\-.!~|<>'"])|`([^`\n]+)`/g;
const LINK_CLASS = 'text-accent underline decoration-accent/40 hover:decoration-accent';
const QUOTE_HTML = (inner: string) => `‘<span class="text-accent font-medium">${inner}</span>’`;

/** Trims sentence punctuation and an unbalanced `)` off an autolinked URL. */
function splitUrlTail(url: string): { url: string; tail: string } {
  let end = url.length;
  const entity = url.search(/&(?:lt|gt|quot|#39);/);
  if (entity >= 0) end = entity;
  let core = url.slice(0, end);
  for (;;) {
    const last = core.slice(-1);
    if (/[.,;:!?*_~]/.test(last)) { core = core.slice(0, -1); continue; }
    if (last === ')' && (core.match(/\(/g) || []).length < (core.match(/\)/g) || []).length) { core = core.slice(0, -1); continue; }
    break;
  }
  return { url: core, tail: url.slice(core.length) };
}

function renderEmphasis(text: string): string {
  let s = text;
  s = s.replace(/\*\*\*(?![\s*])([^*\n]*?[^\s*])\*\*\*/g, '<strong><em>$1</em></strong>');
  s = s.replace(/(^|[^A-Za-z0-9_])___(?![\s_])([^_\n]*?[^\s_])___(?![A-Za-z0-9_])/g, '$1<strong><em>$2</em></strong>');
  s = s.replace(/\*\*(?![\s*])([^*\n]*?[^\s*])\*\*/g, '<strong>$1</strong>');
  s = s.replace(/(^|[^A-Za-z0-9_])__(?![\s_])([^_\n]*?[^\s_])__(?![A-Za-z0-9_])/g, '$1<strong>$2</strong>');
  s = s.replace(/(^|[^*])\*(?![\s*])([^*\n]*?[^\s*])\*(?!\*)/g, '$1<em>$2</em>');
  s = s.replace(/(^|[^A-Za-z0-9_])_(?![\s_])([^_\n]*?[^\s_])_(?![A-Za-z0-9_])/g, '$1<em>$2</em>');
  s = s.replace(/~~(?!\s)([^~\n]*?\S)~~/g, '<del>$1</del>');
  return s;
}

function renderInline(text: string): string {
  const stash: string[] = [];
  const keep = (html: string) => `\u0000${stash.push(html) - 1}\u0000`;

  // 1. Backslash escapes and code spans, on the RAW text and in one left-to-right
  //    pass, so a backslash inside code stays literal and `\`` is not a code span.
  let s = text.replace(INLINE_TOKEN_RE, (_m, escapedChar: string | undefined, code: string | undefined) => (
    escapedChar !== undefined
      ? keep(escapeHtml(escapedChar))
      : keep(`<code class="font-mono text-[0.85em] font-medium text-accent">${escapeHtml(code || '')}</code>`)
  ));
  s = escapeHtml(s);

  // 2. Artifact links/tokens, markdown links, then bare URLs — all stashed whole so
  //    `_` / `*` inside a URL can never become emphasis.
  s = s.replace(ARTIFACT_MARKDOWN_LINK_RE, (_m, label, _link, artifactId) => keep(createArtifactButtonHtml(artifactId, renderEmphasis(label))));
  s = s.replace(ARTIFACT_TOKEN_RE, (_m, prefix, _link, artifactId) => `${prefix}${keep(createArtifactButtonHtml(artifactId))}`);
  s = s.replace(/\[([^\]\n]+)\]\(((?:https?:\/\/|#|\/)(?:[^\s()]|\([^\s()]*\))+)\)/g, (_m, label: string, url: string) => {
    const targetRel = /^https?:\/\//i.test(url) ? ' target="_blank" rel="noreferrer"' : '';
    return keep(`<a href="${url}"${targetRel} class="${LINK_CLASS}">${renderEmphasis(label)}</a>`);
  });
  s = s.replace(/(^|[^\w/])(https?:\/\/[^\s\u0000]+)/g, (_m, prefix: string, raw: string) => {
    const { url, tail } = splitUrlTail(raw);
    if (!/^https?:\/\/[^/]/.test(url)) return `${prefix}${raw}`;
    return `${prefix}${keep(`<a href="${url}" target="_blank" rel="noreferrer" class="${LINK_CLASS}">${url}</a>`)}${tail}`;
  });

  // 3. Quotations. Only an OPENING ‘ (U+2018) starts a curly quote and the closing ’
  //    must not run into a letter, so typographic apostrophes (I’m, I’ll, workers’)
  //    are never paired up. Straight quotes need a word boundary on both sides.
  s = s.replace(/(^|[\s([{“"—–-])‘(?!\s)([^‘’\n]+?)(?<!\s)’(?![\p{L}\p{N}])/gu, (_m, prefix, inner) => `${prefix}${QUOTE_HTML(inner)}`);
  s = s.replace(/(^|[\s([{]|&lt;)&#39;(?!\s)((?:(?!&#39;)[^‘’\n])+?)(?<!\s)&#39;(?=[\]})\s.,;:!?]|&gt;|$)/g, (_m, prefix, inner) => `${prefix}${QUOTE_HTML(inner)}`);

  // 4. Emphasis, then restore stashed HTML (stash entries may nest).
  s = renderEmphasis(s);
  for (let guard = 0; guard < 4 && s.includes('\u0000'); guard += 1) {
    s = s.replace(STASH_RE, (_m, index) => stash[Number(index)] ?? '');
  }
  return autolinkResourceIds(s);
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

const LIST_ITEM_RE = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/;
const FENCE_OPEN_RE = /^\s{0,3}(`{3,}|~{3,})\s*([\w+#.-]*)[^`]*$/;
const HR_RE = /^\s{0,3}([-*_])(?:\s*\1){2,}\s*$/;
// A line that starts a new block, so it can't continue a paragraph or list item.
const BLOCK_START_RE = /^(?:#{1,6}\s|\s{0,3}>|\s{0,3}(?:```|~~~)|\s*(?:[-*+]|\d{1,9}[.)])\s)/;

const indentOf = (line: string) => (line.match(/^\s*/)?.[0] || '').replace(/\t/g, '    ').length;
const isOrderedMarker = (marker: string) => /\d/.test(marker);

/** One list (and its nested lists), with blank lines between items allowed. */
function renderList(lines: string[], start: number): { html: string; nextIndex: number } {
  const first = lines[start].match(LIST_ITEM_RE)!;
  const indent = indentOf(lines[start]);
  const ordered = isOrderedMarker(first[2]);
  const startNumber = ordered ? parseInt(first[2], 10) : 1;
  const items: string[] = [];
  let i = start;
  while (i < lines.length) {
    const item = lines[i].match(LIST_ITEM_RE);
    if (!item || Math.abs(indentOf(lines[i]) - indent) > 1 || isOrderedMarker(item[2]) !== ordered) break;
    let text = item[3];
    const children: string[] = [];
    i += 1;
    while (i < lines.length) {
      const line = lines[i];
      if (line.trim() === '') {
        // Blank line: the list continues only into another item or indented content.
        let j = i;
        while (j < lines.length && lines[j].trim() === '') j += 1;
        if (j >= lines.length) { i = j; break; }
        const next = lines[j].match(LIST_ITEM_RE);
        const nextIndent = indentOf(lines[j]);
        const sameList = next && Math.abs(nextIndent - indent) <= 1 && isOrderedMarker(next[2]) === ordered;
        if (sameList || nextIndent > indent + 1) { i = j; continue; }
        break;
      }
      const lineIndent = indentOf(line);
      if (LIST_ITEM_RE.test(line)) {
        if (lineIndent > indent + 1) {
          const nested = renderList(lines, i);
          children.push(nested.html);
          i = nested.nextIndex;
          continue;
        }
        break; // sibling (or a different list) at this level
      }
      if (lineIndent > indent || !BLOCK_START_RE.test(line)) {
        text += ` ${line.trim()}`; // continuation of this item
        i += 1;
        continue;
      }
      break;
    }
    items.push(`<li>${renderInline(text)}${children.join('')}</li>`);
  }
  const html = ordered
    ? `<ol${startNumber !== 1 ? ` start="${startNumber}"` : ''} class="my-1 list-decimal space-y-0.5 pl-5">${items.join('')}</ol>`
    : `<ul class="my-1 list-disc space-y-0.5 pl-5">${items.join('')}</ul>`;
  return { html, nextIndex: i };
}

function renderBlocks(source: string): string {
  const lines = normalizeMarkdownSource(source).replace(/\r\n?/g, '\n').split('\n');
  const out: string[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const fence = line.match(FENCE_OPEN_RE);
    if (fence) {
      const lang = fence[2] || '';
      const closeRe = new RegExp(`^\\s{0,3}${fence[1][0] === '`' ? '`' : '~'}{${fence[1].length},}\\s*$`);
      const body: string[] = [];
      i += 1;
      while (i < lines.length && !closeRe.test(lines[i])) {
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
    const heading = line.match(/^(#{1,6})\s+(.*?)(?:\s+#+)?\s*$/);
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
    if (/^\s{0,3}>/.test(line)) {
      // Consecutive `>` lines form one quote; an empty `>` line is a paragraph break.
      const paragraphs: string[][] = [[]];
      while (i < lines.length && /^\s{0,3}>/.test(lines[i])) {
        const content = lines[i].replace(/^\s{0,3}>\s?/, '');
        if (content.trim() === '') paragraphs.push([]);
        else paragraphs[paragraphs.length - 1].push(content);
        i += 1;
      }
      const body = paragraphs.filter((p) => p.length > 0).map((p) => renderInline(p.join(' '))).join('<br /><br />');
      out.push(`<blockquote class="my-1 border-l-2 border-accent/40 pl-3 text-muted">${body}</blockquote>`);
      continue;
    }
    if (HR_RE.test(line)) {
      out.push('<hr class="my-2 border-subtle" />');
      i += 1;
      continue;
    }
    if (LIST_ITEM_RE.test(line)) {
      const list = renderList(lines, i);
      out.push(list.html);
      i = list.nextIndex;
      continue;
    }
    const paragraph: string[] = [line];
    i += 1;
    while (i < lines.length && lines[i].trim() !== '' && !isLikelyTableHeader(lines[i], lines[i + 1]) && !BLOCK_START_RE.test(lines[i]) && !HR_RE.test(lines[i])) {
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
