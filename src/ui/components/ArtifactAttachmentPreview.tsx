import { useEffect, useMemo, useState } from 'react';
import { useSelector } from 'react-redux';
import { VaultText } from './vault/VaultText';
import { Icon } from '@ui';

export type ArtifactPreviewMeta = {
  artifact_id?: string;
  artifactId?: string;
  id?: string;
  name?: string;
  kind?: string;
  mime?: string;
  content_type?: string;
  contentType?: string;
  ext?: string;
  size_bytes?: number;
  sizeBytes?: number;
};

type ArtifactPreviewSession = {
  daemonUrl?: string;
  clientToken?: string;
};

type ArtifactPreviewState = {
  id: string;
  meta: ArtifactPreviewMeta | null;
  isImage: boolean;
  contentUrl: string;
  loadingMeta: boolean;
  loadingContent: boolean;
  error: string;
};

function artifactIdOf(row: ArtifactPreviewMeta | null | undefined, fallback = ''): string {
  return String(row?.artifact_id || row?.artifactId || row?.id || fallback || '');
}

function artifactName(row: ArtifactPreviewMeta | null | undefined, fallback: string): string {
  return String(row?.name || fallback || 'artifact');
}

function artifactMime(row: ArtifactPreviewMeta | null | undefined): string {
  return String(row?.mime || row?.content_type || row?.contentType || '').toLowerCase();
}

function artifactExt(row: ArtifactPreviewMeta | null | undefined): string {
  const explicit = String(row?.ext || '').toLowerCase().replace(/^\./, '');
  if (explicit) return explicit;
  const name = String(row?.name || '').toLowerCase();
  const dot = name.lastIndexOf('.');
  return dot >= 0 ? name.slice(dot + 1) : '';
}

export function isArtifactImage(row: ArtifactPreviewMeta | null | undefined): boolean {
  const kind = String(row?.kind || '').toLowerCase();
  const mime = artifactMime(row);
  const ext = artifactExt(row);
  return kind === 'image' || kind === 'png' || kind === 'jpeg' || kind === 'jpg' || mime.startsWith('image/') || ext === 'png' || ext === 'jpg' || ext === 'jpeg' || ext === 'gif' || ext === 'webp';
}

function normalizeSession(sessionProp: ArtifactPreviewSession | undefined, storeSession: any): ArtifactPreviewSession {
  return sessionProp || storeSession || {};
}

function authToken(session: ArtifactPreviewSession): string {
  const token = String(session?.clientToken || '').trim();
  // The v1 shell passes a sentinel token while relying on Authentik/cookie auth.
  // Do not send it as a bearer token; Hub rejects unsupported Authorization.
  return token && token !== 'v1' ? token : '';
}

function joinArtifactUrl(daemonUrl: string | undefined, path: string): string {
  const base = String(daemonUrl || '').replace(/\/$/, '');
  return base ? `${base}${path}` : path;
}

async function fetchArtifactJson(url: string, token: string): Promise<any> {
  const response = await fetch(url, {
    credentials: 'include',
    headers: token ? { Authorization: `Bearer ${token}` } : undefined,
  });
  if (!response.ok) throw new Error(`Artifact metadata failed (${response.status})`);
  const body = await response.json();
  return body?.artifact || body?.data || body;
}

async function fetchArtifactBlobUrl(url: string, token: string): Promise<string> {
  const response = await fetch(url, {
    credentials: 'include',
    headers: token ? { Authorization: `Bearer ${token}` } : undefined,
  });
  if (!response.ok) throw new Error(`Artifact image failed (${response.status})`);
  return URL.createObjectURL(await response.blob());
}

export function useArtifactPreview({ artifactId = '', artifact = null, session: sessionProp }: { artifactId?: string; artifact?: ArtifactPreviewMeta | null; session?: ArtifactPreviewSession }): ArtifactPreviewState {
  const storeSession = useSelector((state: any) => state.chat?.session || {});
  const session = normalizeSession(sessionProp, storeSession);
  const token = authToken(session);
  const id = artifactId || artifactIdOf(artifact);
  const propMeta = artifact || null;
  const [fetchedMeta, setFetchedMeta] = useState<ArtifactPreviewMeta | null>(null);
  const [loadingMeta, setLoadingMeta] = useState(false);
  const [contentUrl, setContentUrl] = useState('');
  const [loadingContent, setLoadingContent] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    setFetchedMeta(null);
    setError('');
    if (!id || propMeta) return;
    let cancelled = false;
    setLoadingMeta(true);
    fetchArtifactJson(joinArtifactUrl(session.daemonUrl, `/api/v1/artifacts/${encodeURIComponent(id)}`), token)
      .then((meta) => { if (!cancelled) setFetchedMeta(meta || null); })
      .catch((err) => { if (!cancelled) setError(String(err?.message || err || 'Artifact metadata failed')); })
      .finally(() => { if (!cancelled) setLoadingMeta(false); });
    return () => { cancelled = true; };
  }, [id, propMeta, session.daemonUrl, token]);

  const meta = propMeta || fetchedMeta;
  const image = isArtifactImage(meta);

  useEffect(() => {
    setContentUrl('');
    if (!id || !image) return;
    let cancelled = false;
    let nextUrl = '';
    setLoadingContent(true);
    fetchArtifactBlobUrl(joinArtifactUrl(session.daemonUrl, `/api/v1/artifacts/${encodeURIComponent(id)}/content`), token)
      .then((url) => {
        nextUrl = url;
        if (cancelled) URL.revokeObjectURL(nextUrl);
        else setContentUrl(nextUrl);
      })
      .catch((err) => { if (!cancelled) setError(String(err?.message || err || 'Artifact image failed')); })
      .finally(() => { if (!cancelled) setLoadingContent(false); });
    return () => {
      cancelled = true;
      if (nextUrl) URL.revokeObjectURL(nextUrl);
    };
  }, [id, image, session.daemonUrl, token]);

  return useMemo(() => ({
    id,
    meta,
    isImage: image,
    contentUrl,
    loadingMeta,
    loadingContent,
    error,
  }), [id, meta, image, contentUrl, loadingMeta, loadingContent, error]);
}

export function ArtifactImagePreview({
  artifactId,
  artifact,
  session,
  debugId,
  alt,
  className = 'h-full w-full object-cover',
  placeholderClassName = 'grid h-full w-full place-items-center text-xs text-faint',
}: {
  artifactId?: string;
  artifact?: ArtifactPreviewMeta | null;
  session?: ArtifactPreviewSession;
  debugId: string;
  alt?: string;
  className?: string;
  placeholderClassName?: string;
}) {
  const preview = useArtifactPreview({ artifactId, artifact, session });
  if (!preview.isImage) return <span className={placeholderClassName}>No preview</span>;
  if (!preview.contentUrl) return <span className={placeholderClassName}>{preview.loadingContent ? 'Loading image…' : 'Image unavailable'}</span>;
  return <img data-debug-id={debugId} src={preview.contentUrl} alt={alt || artifactName(preview.meta, preview.id)} loading="lazy" className={className} />;
}

export function ArtifactAttachmentPreview({
  artifactId,
  artifact,
  session,
  debugId,
  href,
}: {
  artifactId: string;
  artifact?: ArtifactPreviewMeta | null;
  session?: ArtifactPreviewSession;
  debugId: string;
  href?: string;
}) {
  const preview = useArtifactPreview({ artifactId, artifact, session });
  const id = preview.id || artifactId;
  const label = artifactName(preview.meta, id);
  const target = href || `#/library/artifacts/${encodeURIComponent(id)}`;

  if (preview.isImage) {
    return (
      <a data-debug-id={`${debugId}-link`} href={target} className="group block min-w-0 max-w-[min(320px,100%)] overflow-hidden rounded-xl border border-subtle bg-surface text-left hover:border-accent/40 hover:bg-surface-raised">
        <div className="grid max-h-56 min-h-[120px] place-items-center overflow-hidden bg-surface-raised">
          {preview.contentUrl ? (
            <img data-debug-id={`${debugId}-image`} src={preview.contentUrl} alt={label} loading="lazy" className="max-h-56 w-full object-contain" />
          ) : (
            <div className="px-3 py-8 text-xs text-faint">{preview.loadingContent || preview.loadingMeta ? 'Loading image…' : 'Image unavailable'}</div>
          )}
        </div>
        <div className="flex items-center gap-2 px-2.5 py-1.5 text-caption text-muted">
          <Icon name="file" size={12} className="text-accent" />
          <span className="min-w-0 flex-1 truncate"><VaultText value={label} fallback={id} /></span>
          <span className="text-faint group-hover:text-accent">Open</span>
        </div>
      </a>
    );
  }

  return (
    <a data-debug-id={`${debugId}-link`} href={target} className="flex min-w-0 max-w-full items-center gap-1 rounded bg-info-soft px-2 py-1 text-caption text-accent hover:bg-neutral-soft">
      <span className="opacity-70">▣</span>
      <span className="truncate">{preview.loadingMeta ? id : <VaultText value={label} fallback={id} />}</span>
    </a>
  );
}
