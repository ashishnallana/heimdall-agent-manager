export function artifactExtensionForMime(mime: string): string {
  const normalized = String(mime || '').toLowerCase();
  if (normalized === 'image/png') return '.png';
  if (normalized === 'image/jpeg') return '.jpg';
  if (normalized === 'image/gif') return '.gif';
  if (normalized === 'image/webp') return '.webp';
  if (normalized === 'text/markdown') return '.md';
  if (normalized === 'text/csv') return '.csv';
  if (normalized === 'text/html') return '.html';
  if (normalized === 'application/json') return '.json';
  if (normalized.startsWith('text/')) return '.txt';
  return '';
}

export function artifactUploadName(file: File, prefix = 'artifact'): string {
  const explicit = String(file?.name || '').trim();
  if (explicit) return explicit.replace(/[\\/\r\n\t]/g, '_');
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  return `${prefix}-${stamp}${artifactExtensionForMime(String(file?.type || '')) || '.bin'}`;
}

export function artifactKindForFile(file: File): string {
  const name = artifactUploadName(file).toLowerCase();
  const mime = String(file?.type || '').toLowerCase();
  if (mime.startsWith('image/')) return 'image';
  if (mime === 'text/markdown' || name.endsWith('.md') || name.endsWith('.markdown')) return 'markdown';
  if (mime === 'text/csv' || name.endsWith('.csv')) return 'csv';
  if (mime === 'text/html' || name.endsWith('.html') || name.endsWith('.htm')) return 'html';
  if (mime === 'application/json' || name.endsWith('.json')) return 'json';
  if (mime.startsWith('text/')) return 'text';
  return 'file';
}

export function artifactMimeForFile(file: File): string {
  return String(file?.type || '').trim() || 'application/octet-stream';
}

export function clipboardFilesFromEvent(event: any): File[] {
  const data = event?.clipboardData;
  const out: File[] = [];
  const seen = new Set<string>();
  const push = (file: File | null | undefined) => {
    if (!file) return;
    // Dedup WITHOUT lastModified: a pasted screenshot surfaces in both
    // clipboardData.files and clipboardData.items[].getAsFile() with a
    // DIFFERENT lastModified, so including it would defeat the dedup and
    // upload the same image twice. name:type:size identifies a paste uniquely.
    const key = [file.name || '', file.type || '', file.size || 0].join(':');
    if (seen.has(key)) return;
    seen.add(key);
    out.push(file);
  };
  // Prefer clipboardData.files; only fall back to items[] when files is empty
  // (mirrors ChatComposer.clipboardFiles) so a single paste yields each file once.
  const files = Array.from(data?.files || []) as File[];
  if (files.length > 0) {
    files.forEach(push);
    return out;
  }
  Array.from(data?.items || []).forEach((item: any) => {
    if (item?.kind === 'file' || String(item?.type || '').startsWith('image/')) push(item?.getAsFile?.() || null);
  });
  return out;
}

export function artifactLinkFromResponse(response: any): string {
  const artifact = response?.artifact || response?.data?.artifact || response?.data || response || {};
  const explicit = String(response?.link || artifact?.link || '').trim();
  if (explicit) return explicit;
  const id = String(artifact?.artifact_id || artifact?.artifactId || artifact?.id || '').trim();
  return id ? `artifact://${id}` : '';
}

export function artifactIdFromLink(value: string): string {
  return String(value || '').replace(/^artifact:\/\//i, '').trim();
}

export function appendArtifactLinks(body: string, links: string[]): string {
  const cleanLinks = links.map((link) => String(link || '').trim()).filter(Boolean);
  if (!cleanLinks.length) return body;
  const prefix = String(body || '').replace(/\s+$/, '');
  return prefix ? `${prefix}\n${cleanLinks.join('\n')}` : cleanLinks.join('\n');
}

/**
 * The text of a message without its artifact:// links, for places that render
 * each artifact as a preview card below the text (so the raw artifact id does
 * not also show as a link chip). Lines that held only links are dropped.
 */
export function stripArtifactLinks(value: string): string {
  return String(value || '')
    // Same id alphabet as artifactIdsFromText, minus trailing sentence punctuation.
    .replace(/artifact:\/\/[A-Za-z0-9._:-]*[A-Za-z0-9_-]/g, '')
    .split('\n')
    .map((line) => line.replace(/\s+$/, ''))
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}
