import { useEffect, useMemo, useRef, useState } from 'react';
import { Button, Icon, Select, Spinner } from '@ui';
import {
  useArtifactContentState,
  useFetchArtifactMetaQuery,
  useFetchArtifactTextContentQuery,
  useFetchArtifactVersionsQuery,
} from '../api/endpoints/artifacts';
import { copyTextToClipboard } from '../utils/artifactAnnotations';
import MarkdownBody from './MarkdownBody';
import HtmlBundlePreview from './HtmlBundlePreview';
import { HTML_BUNDLE_KIND } from '../utils/htmlBundle';
import { VaultText } from './vault/VaultText';
import { isVaultArmored } from '../utils/vaultContent';

type ArtifactViewerProps = {
  artifactId: string;
  daemonUrl: string;
  clientToken: string;
  onClose?: () => void;
  embedded?: boolean;
};

type ArtifactMeta = {
  artifact_id: string;
  name: string;
  kind: string;
  mime: string;
  content_type?: string;
  contentType?: string;
  ext: string;
  size_bytes: number;
  sha256: string;
  description: string;
  project_id: string;
  creator_type: string;
  creator_id: string;
  origin_kind: string;
  origin_ref: string;
  created_unix_ms: number;
  current_version_no: number;
  updated_unix_ms: number;
  deleted: boolean;
  link: string;
  renderer?: string;
};

type ArtifactVersion = {
  artifact_id: string;
  version_no: number;
  name: string;
  kind: string;
  mime: string;
  content_type?: string;
  contentType?: string;
  ext: string;
  size_bytes: number;
  sha256: string;
  description: string;
  project_id: string;
  origin_kind: string;
  origin_ref: string;
  author_type: string;
  author_id: string;
  change_reason: string;
  created_unix_ms: number;
};

type PreviewKind = 'html-bundle' | 'markdown' | 'text' | 'json' | 'diff' | 'image' | 'unsupported';
type CopyState = 'idle' | 'copied' | 'error';

function formatBytes(value: number) {
  if (!Number.isFinite(value) || value <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  let size = value;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return `${size >= 10 || unit === 0 ? size.toFixed(0) : size.toFixed(1)} ${units[unit]}`;
}

// UI-10: kind-aware rendering. text/markdown -> rendered markdown; json ->
// pretty-printed; diff -> monospace diff; images (including PNG) -> ZoomableImage.
function classifyPreview(meta: ArtifactMeta | null): PreviewKind {
  if (!meta) return 'unsupported';
  const kind = String(meta.kind || '').toLowerCase();
  const mime = String(meta.mime || meta.content_type || meta.contentType || '').toLowerCase();
  const rawExt = String(meta.ext || '').toLowerCase();
  const name = String(meta.name || '').toLowerCase();
  const nameDot = name.lastIndexOf('.');
  const ext = rawExt
    ? (rawExt.startsWith('.') ? rawExt : `.${rawExt}`)
    : (nameDot >= 0 ? name.slice(nameDot) : '');
  const renderer = String(meta.renderer || '').toLowerCase();
  // REQ-BUNDLE-3: only the explicit kind; a generic ZIP stays a downloadable file.
  if (kind === HTML_BUNDLE_KIND) {
    return 'html-bundle';
  }
  if (kind === 'diff' || ext === '.diff' || ext === '.patch' || mime === 'text/x-diff') {
    return 'diff';
  }
  if (kind === 'json' || mime === 'application/json' || mime === 'text/json' || ext === '.json') {
    return 'json';
  }
  if (renderer === 'markdown' || kind === 'markdown' || kind === 'text' || mime === 'text/markdown' || mime === 'text/plain' || ext === '.md' || ext === '.markdown' || ext === '.txt' || name.endsWith('.md') || name.endsWith('.markdown') || name.endsWith('.txt')) {
    return 'markdown';
  }
  if (kind === 'png' || kind === 'image' || kind === 'jpeg' || kind === 'jpg'
      || mime === 'image/png' || mime === 'image/jpeg' || mime === 'image/jpg'
      || ext === '.png' || ext === '.jpg' || ext === '.jpeg'
      || kind === 'gif' || mime === 'image/gif' || ext === '.gif'
      || kind === 'webp' || mime === 'image/webp' || ext === '.webp'
      || mime.startsWith('image/')) {
    return 'image';
  }
  if (mime.startsWith('text/')) {
    return 'text';
  }
  return 'unsupported';
}

// UI-10: image view with wheel/drag zoom on desktop and pinch-zoom/pan on touch.
// Renders all images (including PNG) with transform-based zoom and pan.
function ZoomableImage({ contentUrl, alt }: { contentUrl: string; alt: string }) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [scale, setScale] = useState(1);
  const [tx, setTx] = useState(0);
  const [ty, setTy] = useState(0);
  const dragRef = useRef<{ x: number; y: number; tx: number; ty: number } | null>(null);
  const pinchRef = useRef<{ distance: number; scale: number } | null>(null);

  function clampScale(next: number) {
    return Math.min(8, Math.max(1, next));
  }

  function handleWheel(event: React.WheelEvent<HTMLDivElement>) {
    if (!event.ctrlKey && Math.abs(event.deltaY) < 30) return; // trackpad two-finger = scroll
    event.preventDefault();
    const delta = -event.deltaY * 0.0025;
    setScale((current) => clampScale(current * (1 + delta)));
  }

  function handlePointerDown(event: React.PointerEvent<HTMLDivElement>) {
    if (event.pointerType === 'touch' && event.isPrimary === false) return;
    (event.currentTarget as HTMLDivElement).setPointerCapture?.(event.pointerId);
    dragRef.current = { x: event.clientX, y: event.clientY, tx, ty };
  }

  function handlePointerMove(event: React.PointerEvent<HTMLDivElement>) {
    if (!dragRef.current) return;
    const dx = event.clientX - dragRef.current.x;
    const dy = event.clientY - dragRef.current.y;
    setTx(dragRef.current.tx + dx);
    setTy(dragRef.current.ty + dy);
  }

  function handlePointerUp() {
    dragRef.current = null;
  }

  function handleTouchStart(event: React.TouchEvent<HTMLDivElement>) {
    if (event.touches.length === 2) {
      const a = event.touches[0];
      const b = event.touches[1];
      const distance = Math.hypot(b.clientX - a.clientX, b.clientY - a.clientY);
      pinchRef.current = { distance, scale };
      dragRef.current = null;
    }
  }

  function handleTouchMove(event: React.TouchEvent<HTMLDivElement>) {
    if (event.touches.length === 2 && pinchRef.current) {
      event.preventDefault();
      const a = event.touches[0];
      const b = event.touches[1];
      const distance = Math.hypot(b.clientX - a.clientX, b.clientY - a.clientY);
      const ratio = distance / (pinchRef.current.distance || distance);
      setScale(clampScale(pinchRef.current.scale * ratio));
    }
  }

  function handleTouchEnd(event: React.TouchEvent<HTMLDivElement>) {
    if (event.touches.length < 2) pinchRef.current = null;
  }

  function reset() {
    setScale(1);
    setTx(0);
    setTy(0);
  }

  return (
    <div
      ref={containerRef}
      data-debug-id="artifact-viewer-zoomable-image"
      className="relative flex touch-none select-none items-center justify-center overflow-hidden rounded-2xl border border-subtle bg-surface-raised"
      // REQ-MODAL-2: a MIN-height is the opposite direction from the caps and still belongs on
      // the visible region. Against the layout viewport this floor stayed 325px however short
      // the visible region got, so it forced the capped panel to overflow and scroll with the
      // keyboard up. Tracking the visible region means the floor shrinks with it instead.
      style={{ minHeight: 'calc(var(--app-viewport-height) * 0.4)' }}
      onWheel={handleWheel}
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerUp}
      onTouchStart={handleTouchStart}
      onTouchMove={handleTouchMove}
      onTouchEnd={handleTouchEnd}
    >
      <img
        data-debug-id="artifact-viewer-image-preview"
        src={contentUrl}
        alt={alt}
        draggable={false}
        className="max-h-[calc(var(--app-viewport-height)*0.7)] max-w-full select-none rounded-xl"
        style={{ transform: `translate(${tx}px, ${ty}px) scale(${scale})`, transformOrigin: 'center center', transition: dragRef.current ? 'none' : 'transform 0.08s ease-out' }}
      />
      <div className="pointer-events-none absolute bottom-2 right-2 flex items-center gap-2">
        <span data-debug-id="artifact-viewer-image-zoom-label" className="rounded-full border border-subtle bg-surface/80 px-2 py-0.5 text-[10.5px] text-muted">{Math.round(scale * 100)}%</span>
        <button type="button" data-debug-id="artifact-viewer-image-zoom-reset" onClick={reset} className="pointer-events-auto rounded-full border border-subtle bg-surface/80 px-2 py-0.5 text-[10.5px] text-primary hover:bg-neutral-soft">reset</button>
      </div>
    </div>
  );
}

// UI-10: json/diff/text rendered with monospace. json is pretty-printed; diff
// keeps +/- markers. Both support copy-all. Self-contained content fetch.
function ArtifactCodePreview({ artifactId, versionNo, kind, daemonUrl, clientToken }: { artifactId: string; versionNo: number | null; kind: 'json' | 'diff' | 'text'; daemonUrl: string; clientToken: string }) {
  const textQuery = useFetchArtifactTextContentQuery({ artifactId, versionNo, daemonUrl, clientToken }, { skip: !artifactId || !clientToken });
  const [copyState, setCopyState] = useState<CopyState>('idle');
  const raw = textQuery.data?.text || '';
  const display = useMemo(() => {
    if (kind !== 'json') return raw;
    try {
      return JSON.stringify(JSON.parse(raw), null, 2);
    } catch {
      return raw;
    }
  }, [raw, kind]);

  async function handleCopy() {
    try {
      await copyTextToClipboard(display);
      setCopyState('copied');
      window.setTimeout(() => setCopyState('idle'), 1200);
    } catch {
      setCopyState('error');
      window.setTimeout(() => setCopyState('idle'), 1500);
    }
  }

  if (textQuery.isFetching) return <div className="text-sm text-muted">Loading preview…</div>;
  if (textQuery.error) return <div className="rounded-xl border border-warning/30 bg-warning-soft px-4 py-3 text-sm text-warning">Failed to load artifact content.</div>;
  if (isVaultArmored(raw)) {
    return (
      <div className="rounded-xl border border-subtle bg-surface-raised p-6 text-center">
        <VaultText value={raw} />
      </div>
    );
  }
  return (
    <div data-debug-id={`artifact-viewer-${kind}-preview`} className="relative">
      <button type="button" data-debug-id={`artifact-viewer-${kind}-copy-btn`} onClick={handleCopy} className="absolute right-2 top-2 z-10 rounded-lg border border-subtle bg-surface/80 px-2 py-1 text-caption text-primary hover:bg-neutral-soft">{copyState === 'copied' ? 'Copied' : copyState === 'error' ? 'Copy failed' : 'Copy all'}</button>
      <pre data-debug-id={`artifact-viewer-${kind}-body`} className="max-h-[calc(var(--app-viewport-height)*0.7)] overflow-auto rounded-2xl border border-subtle bg-surface-raised p-4 text-[12.5px] leading-5 text-primary">
        <code>{display || '(empty)'}</code>
      </pre>
    </div>
  );
}

export default function ArtifactViewer({ artifactId, daemonUrl, clientToken, onClose, embedded = false }: ArtifactViewerProps) {
  const artifactRequestAuth = useMemo(() => ({ daemonUrl, clientToken }), [daemonUrl, clientToken]);
  const metaQuery = useFetchArtifactMetaQuery({ artifactId, ...artifactRequestAuth }, { skip: !artifactId || !clientToken });
  const versionsQuery = useFetchArtifactVersionsQuery({ artifactId, ...artifactRequestAuth }, { skip: !artifactId || !clientToken });

  const meta = (metaQuery.data?.artifact || null) as ArtifactMeta | null;
  const currentHeadVersionNo = Number(meta?.current_version_no || 0);
  const versions = useMemo(() => {
    const rows = Array.isArray(versionsQuery.data?.versions) ? versionsQuery.data.versions : [];
    return rows as ArtifactVersion[];
  }, [versionsQuery.data]);

  const [selectedVersionNo, setSelectedVersionNo] = useState<number | null>(null);
  const [copyLinkState, setCopyLinkState] = useState<'idle' | 'copied' | 'error'>('idle');
  const [nestedArtifactId, setNestedArtifactId] = useState('');

  useEffect(() => {
    setSelectedVersionNo(null);
    setCopyLinkState('idle');
    setNestedArtifactId('');
  }, [artifactId]);

  const selectedVersionRecord = useMemo(
    () => versions.find((version) => Number(version.version_no) === Number(selectedVersionNo || currentHeadVersionNo)) || null,
    [versions, selectedVersionNo, currentHeadVersionNo],
  );

  const selectedArtifactMeta = useMemo(() => {
    if (!meta) return null;
    if (!selectedVersionRecord || Number(selectedVersionRecord.version_no) === currentHeadVersionNo) return meta;
    return {
      ...meta,
      name: selectedVersionRecord.name,
      kind: selectedVersionRecord.kind,
      mime: selectedVersionRecord.mime,
      content_type: selectedVersionRecord.content_type,
      contentType: selectedVersionRecord.contentType,
      ext: selectedVersionRecord.ext,
      size_bytes: selectedVersionRecord.size_bytes,
      sha256: selectedVersionRecord.sha256,
      description: selectedVersionRecord.description,
      project_id: selectedVersionRecord.project_id,
      origin_kind: selectedVersionRecord.origin_kind,
      origin_ref: selectedVersionRecord.origin_ref,
      current_version_no: selectedVersionRecord.version_no,
    } as ArtifactMeta;
  }, [meta, selectedVersionRecord, currentHeadVersionNo]);

  const previewKind = useMemo(() => classifyPreview(selectedArtifactMeta), [selectedArtifactMeta]);
  const contentState = useArtifactContentState({ daemonUrl, clientToken, artifactId, versionNo: selectedVersionNo });
  const contentUrl = contentState.url;
  const imagePreviewNeedsContent = previewKind === 'image' || previewKind === 'html-bundle';
  const textQuery = useFetchArtifactTextContentQuery(
    { artifactId, versionNo: selectedVersionNo, ...artifactRequestAuth },
    { skip: !artifactId || !clientToken || previewKind !== 'markdown' },
  );
  const textContent = textQuery.data?.text || '';
  const loading = metaQuery.isFetching;
  const loadingText = textQuery.isFetching;
  const loadingContent = imagePreviewNeedsContent && contentState.loading;
  const contentError = imagePreviewNeedsContent ? contentState.error : '';
  const error = metaQuery.error
    ? 'Failed to load artifact metadata.'
    : textQuery.error
      ? 'Failed to load artifact content.'
      : (!loading && !meta ? 'Artifact metadata is unavailable.' : '');
  const versionHistoryUnavailable = Boolean(versionsQuery.error);

  const title = selectedArtifactMeta?.name || meta?.name || artifactId;
  const versionSelectValue = selectedVersionNo == null ? 'HEAD' : String(selectedVersionNo);
  const selectedVersionLabel = selectedVersionNo == null ? `Head v${currentHeadVersionNo || '?'}` : `v${selectedVersionNo}`;

  async function handleCopyLink() {
    const link = meta?.link || `artifact://${artifactId}`;
    try {
      await copyTextToClipboard(link);
      setCopyLinkState('copied');
      window.setTimeout(() => setCopyLinkState('idle'), 1500);
    } catch {
      setCopyLinkState('error');
      window.setTimeout(() => setCopyLinkState('idle'), 1500);
    }
  }

  function handleDownload() {
    if (!contentUrl) return;
    const anchor = document.createElement('a');
    anchor.href = contentUrl;
    const downloadName = selectedArtifactMeta?.name || artifactId;
    // The html-bundle payload is the decrypted ZIP, byte-identical to what was uploaded.
    anchor.download = previewKind === 'html-bundle' && !downloadName.toLowerCase().endsWith('.zip') ? `${downloadName}.zip` : downloadName;
    document.body.appendChild(anchor);
    anchor.click();
    document.body.removeChild(anchor);
  }

  if (embedded && nestedArtifactId) {
    return (
      <ArtifactViewer
        artifactId={nestedArtifactId}
        daemonUrl={daemonUrl}
        clientToken={clientToken}
        embedded={true}
        onClose={() => setNestedArtifactId('')}
      />
    );
  }

  return (
    // REQ-MODAL-2: `app-viewport-height`, not `inset-0` — see the OVERLAYS note in
    // `src/ui/styles.css`. `items-center` centres the panel in this box, so the panel's
    // `max-h` cap below only reaches the user if this box is the visible region.
    <div
      data-debug-id={embedded ? 'artifact-viewer-embedded-shell' : 'artifact-viewer-modal-shell'}
      className={embedded
        ? 'flex h-full min-h-0 w-full flex-col bg-canvas'
        : 'fixed inset-x-0 top-0 app-viewport-height z-[80] flex items-center justify-center bg-surface-overlay/80 p-2 sm:p-4 backdrop-blur-sm'}
      onClick={embedded ? undefined : onClose}
    >
      <div data-debug-id="artifact-viewer" className={embedded ? 'flex h-full min-h-0 w-full flex-col overflow-hidden bg-surface' : 'flex max-h-[calc(var(--app-viewport-height)*0.96)] sm:max-h-[calc(var(--app-viewport-height)*0.92)] w-full max-w-6xl flex-col overflow-hidden rounded-[22px] border border-subtle bg-surface shadow-panel focus-within:border-accent/40'} onClick={(event) => event.stopPropagation()}>
        <div data-debug-id="artifact-viewer-breadcrumb" className="flex items-center gap-2 border-b border-subtle bg-surface-raised/80 px-4 py-2 sm:px-5 sm:py-2.5 text-[12px] text-faint">
          <span className="text-muted">Artifact</span>
          <span className="text-faint">/</span>
          <span className="truncate text-primary"><VaultText value={title} fallback={artifactId} /></span>
        </div>
        <div className="flex flex-col gap-2.5 sm:gap-3 border-b border-subtle px-4 py-3 sm:px-5 sm:py-3.5">
          {/* Row 1: Title (full width on mobile, truncate, never squashed) and 3 action buttons */}
          <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-2.5 sm:gap-3 min-w-0 w-full">
            <div className="min-w-0 w-full sm:flex-1 truncate text-lg sm:text-xl font-semibold tracking-[-0.01em] text-primary" title={typeof title === 'string' && !isVaultArmored(title) ? title : undefined}>
              <VaultText value={title} fallback={artifactId} />
            </div>
            <div className="flex shrink-0 items-center gap-1.5 sm:gap-2">
              <Button
                data-debug-id="artifact-viewer-copy-link-btn"
                variant="secondary"
                size="sm"
                onClick={handleCopyLink}
                leading={copyLinkState === 'copied' ? <Icon name="check" size="sm" /> : undefined}
              >
                {copyLinkState === 'copied' ? 'Copied' : 'Copy Link'}
              </Button>
              <Button
                data-debug-id="artifact-viewer-download-btn"
                variant="primary"
                size="sm"
                disabled={!contentUrl || contentState.loading || (previewKind === 'html-bundle' && contentState.locked)}
                onClick={handleDownload}
                leading={<Icon name="download" size="sm" />}
              >
                {contentState.loading ? 'Downloading…' : 'Download'}
              </Button>
              {onClose ? (
                <Button
                  data-debug-id="artifact-viewer-close-btn"
                  variant="secondary"
                  size="sm"
                  onClick={onClose}
                  leading={<Icon name="close" size="sm" />}
                >
                  {embedded ? 'Back' : 'Close'}
                </Button>
              ) : null}
            </div>
          </div>

          {/* Row 2: Full-width meta-strip */}
          <div data-debug-id="artifact-viewer-meta-strip" className="flex flex-wrap items-center gap-1.5 sm:gap-2 text-[11.5px] text-muted w-full">
            <span className="rounded-full border border-subtle bg-neutral-soft px-2.5 py-0.5 uppercase tracking-wide text-muted">{selectedArtifactMeta?.kind || 'artifact'}</span>
            {(selectedArtifactMeta?.mime || selectedArtifactMeta?.content_type || selectedArtifactMeta?.contentType) && <span className="rounded-full border border-subtle bg-surface-raised px-2.5 py-0.5 text-muted">{selectedArtifactMeta.mime || selectedArtifactMeta.content_type || selectedArtifactMeta.contentType}</span>}
            {selectedArtifactMeta?.size_bytes != null && <span className="rounded-full border border-subtle bg-surface-raised px-2.5 py-0.5 text-muted">{formatBytes(Number(selectedArtifactMeta.size_bytes))}</span>}
            {(meta?.link || artifactId) && <span className="max-w-full truncate rounded-full border border-subtle bg-surface-raised px-2.5 py-0.5 font-mono text-muted">{meta?.link || `artifact://${artifactId}`}</span>}
            {currentHeadVersionNo > 0 ? <span className="rounded-full border border-success/30 bg-success-soft px-2.5 py-0.5 text-success">{selectedVersionLabel}</span> : null}
          </div>

          {versions.length > 1 ? (
            <div className="flex flex-wrap items-center gap-2 pt-0.5">
              <label className="text-xs uppercase tracking-wide text-faint">Versions</label>
              <Select
                data-debug-id="artifact-viewer-version-select"
                value={versionSelectValue}
                onChange={(nextValue) => {
                  setSelectedVersionNo(nextValue === 'HEAD' ? null : Number(nextValue));
                }}
              >
                <option value="HEAD">Head v{currentHeadVersionNo || '?'}</option>
                {versions.filter((version) => Number(version.version_no) !== currentHeadVersionNo).map((version) => (
                  <option key={version.version_no} value={String(version.version_no)}>v{version.version_no}</option>
                ))}
              </Select>
            </div>
          ) : null}
        </div>
        <div className="overflow-auto p-3 sm:p-5">
          <div className="space-y-4">
            {loading && <div className="text-sm text-muted">Loading artifact…</div>}
            {!loading && error && <div className="rounded-xl border border-warning/30 bg-warning-soft px-4 py-3 text-sm text-warning">{error}</div>}
            {versionHistoryUnavailable ? (
              <div data-debug-id="artifact-viewer-versions-unavailable" className="rounded-xl border border-subtle bg-surface-raised px-4 py-3 text-sm text-muted">
                Version history is unavailable for this artifact. The current artifact preview and download remain available.
              </div>
            ) : null}
            {!loading && !error && selectedArtifactMeta && (
              <div className="space-y-4">
                {selectedArtifactMeta.description && (
                  <div className="text-sm text-secondary"><VaultText value={selectedArtifactMeta.description} /></div>
                )}
                {loadingContent ? (
                  <div data-debug-id="artifact-viewer-content-loading" className="grid min-h-[calc(var(--app-viewport-height)*0.4)] place-items-center rounded-2xl border border-subtle bg-surface-raised px-6 py-10 text-center">
                    <div>
                      <Spinner size="lg" label="Downloading artifact…" className="mx-auto mb-3 text-accent" />
                      <div className="text-sm font-medium text-primary">Downloading artifact…</div>
                      <div className="mt-1 text-xs text-muted">{selectedArtifactMeta.size_bytes ? formatBytes(Number(selectedArtifactMeta.size_bytes)) : 'Preparing preview'}</div>
                    </div>
                  </div>
                ) : contentError ? (
                  <div data-debug-id="artifact-viewer-content-error" className="rounded-xl border border-warning/30 bg-warning-soft px-4 py-3 text-sm text-warning">{contentError}</div>
                ) : previewKind === 'html-bundle' ? (
                  <HtmlBundlePreview blob={contentState.blob} locked={contentState.locked} lockReason={contentState.lockReason} />
                ) : previewKind === 'image' ? (
                  <ZoomableImage contentUrl={contentUrl} alt={selectedArtifactMeta.name || artifactId} />
                ) : previewKind === 'markdown' ? (
                  loadingText ? (
                    <div className="text-sm text-muted">Loading preview…</div>
                  ) : isVaultArmored(textContent) ? (
                    <div className="rounded-xl border border-subtle bg-surface-raised p-6 text-center">
                      <VaultText value={textContent} />
                    </div>
                  ) : (
                    <MarkdownBody
                      data-debug-id="artifact-viewer-markdown-preview"
                      source={textContent}
                      className="text-primary"
                      onArtifactClick={setNestedArtifactId}
                    />
                  )
                ) : previewKind === 'json' || previewKind === 'diff' || previewKind === 'text' ? (
                  <ArtifactCodePreview artifactId={artifactId} versionNo={selectedVersionNo} kind={previewKind} {...artifactRequestAuth} />
                ) : (
                  <div data-debug-id="artifact-viewer-unsupported-preview" className="rounded-xl border border-subtle bg-surface-raised px-4 py-3 text-sm text-muted">
                    Preview is not available for this artifact type{selectedArtifactMeta.kind ? ` (${selectedArtifactMeta.kind}${selectedArtifactMeta.mime || selectedArtifactMeta.content_type || selectedArtifactMeta.contentType ? `, ${selectedArtifactMeta.mime || selectedArtifactMeta.content_type || selectedArtifactMeta.contentType}` : ''})` : ''}. Use Download to open it externally.
                  </div>
                )}
              </div>
            )}
          </div>
        </div>
      </div>
      {!embedded && nestedArtifactId ? <ArtifactViewer artifactId={nestedArtifactId} daemonUrl={daemonUrl} clientToken={clientToken} onClose={() => setNestedArtifactId('')} /> : null}
    </div>
  );
}
