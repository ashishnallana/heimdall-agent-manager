import { useCallback, useRef, useState } from 'react';
import { useSelector } from 'react-redux';
import { useCreateArtifactMutation } from '../api/endpoints/artifacts';

// Keep this helper aligned with the daemon artifact allowlist. Rich preview is
// narrower than upload support; unsupported preview kinds still fall back to the
// viewer/download flow after upload.
const ARTIFACT_UPLOAD_SPECS = [
  { kind: 'markdown', mime: 'text/markdown', exts: ['.md'] },
  { kind: 'png', mime: 'image/png', exts: ['.png'] },
  { kind: 'jpeg', mime: 'image/jpeg', exts: ['.jpg', '.jpeg'] },
  { kind: 'csv', mime: 'text/csv', exts: ['.csv'] },
  { kind: 'html', mime: 'text/html', exts: ['.html', '.htm'] },
] as const;
export const ARTIFACT_UPLOAD_ACCEPT = ARTIFACT_UPLOAD_SPECS.flatMap((spec) => [...spec.exts, spec.mime]).join(',');
const SUPPORTED_FILE_ERROR = 'Unsupported file. Upload a supported artifact (.md, .png, .jpg, .jpeg, .csv, .html, or .htm).';
export const MAX_UPLOAD_BYTES = 50 * 1024 * 1024; // Mirror Hub artifact payload guardrail for friendlier client-side errors.

type ArtifactKindMime = { kind: string; mime: string };
export type ClipboardUploadResult = { handled: boolean; link: string | null };

type UploadArtifactParams = {
  file: File;
  name: string;
  kind: string;
  mime: string;
  projectId?: string;
  originKind?: string;
  originRef?: string;
};

function fileExtension(name: string): string {
  const trimmed = String(name || '').trim().toLowerCase();
  const dot = trimmed.lastIndexOf('.');
  if (dot <= 0 || dot === trimmed.length - 1) return '';
  return trimmed.slice(dot);
}

function classifyFile(file: File): ArtifactKindMime | null {
  const name = (file.name || '').toLowerCase();
  const type = (file.type || '').toLowerCase();
  const ext = fileExtension(name);
  if (ext) {
    const byExtension = ARTIFACT_UPLOAD_SPECS.find((spec) => spec.exts.some((candidate) => candidate === ext));
    return byExtension ? { kind: byExtension.kind, mime: byExtension.mime } : null;
  }
  const byMime = ARTIFACT_UPLOAD_SPECS.find((spec) => spec.mime === type);
  if (byMime) return { kind: byMime.kind, mime: byMime.mime };
  return null;
}

function buildClipboardImageName() {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  return `clipboard-image-${stamp}.png`;
}

function clipboardPngFromEvent(event: any): { file: File | null; hasImage: boolean; unsupportedImage: boolean } {
  const items = Array.from(event?.clipboardData?.items || []) as any[];
  let hasImage = false;
  for (const item of items) {
    const type = String(item?.type || '').toLowerCase();
    if (type.startsWith('image/')) {
      hasImage = true;
      if (type === 'image/png') {
        const file = item?.getAsFile?.() || null;
        if (file) return { file, hasImage: true, unsupportedImage: false };
      }
    }
  }
  const files = Array.from(event?.clipboardData?.files || []) as File[];
  for (const file of files) {
    const type = String(file?.type || '').toLowerCase();
    if (type.startsWith('image/')) {
      hasImage = true;
      if (type === 'image/png') return { file, hasImage: true, unsupportedImage: false };
    }
  }
  return { file: null, hasImage, unsupportedImage: hasImage };
}

export type ArtifactUploadContext = {
  projectId?: string;
  originRef?: string;
  originKind?: string;
};

export type UseArtifactUploadResult = {
  uploading: boolean;
  error: string;
  clearError: () => void;
  uploadFile: (file: File | null | undefined) => Promise<string | null>;
  uploadClipboardImage: (event: any, overrides?: Partial<ArtifactUploadContext>) => Promise<ClipboardUploadResult>;
};

function canUseAmbientArtifactAuth(): boolean {
  if (typeof window === 'undefined') return false;
  return window.location.protocol === 'http:' || window.location.protocol === 'https:';
}

function hasArtifactUploadAuth(session: any): boolean {
  return canUseAmbientArtifactAuth() || Boolean(session?.daemonUrl && session?.clientToken);
}

// Reusable upload flow used by the direct/selected-agent composer, the chain
// coordinator composer, and ChainView paste affordances. Returns the created
// `artifact://<id>` link on success or null on failure, setting a human-readable
// `error` for the caller to surface.
export function useArtifactUpload(context: ArtifactUploadContext = {}): UseArtifactUploadResult {
  const session = useSelector((state: any) => state.chat?.session || {});
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState('');
  const [createArtifact] = useCreateArtifactMutation();
  const clearError = useCallback(() => setError(''), []);

  const uploadArtifact = useCallback(async ({ file, name, kind, mime, projectId, originKind, originRef }: UploadArtifactParams): Promise<string | null> => {
    if (!file) return null;
    if (file.size > MAX_UPLOAD_BYTES) {
      setError(`File is too large. Maximum upload size is ${Math.round(MAX_UPLOAD_BYTES / (1024 * 1024))} MB.`);
      return null;
    }
    if (!hasArtifactUploadAuth(session)) {
      setError('Not connected. Reconnect before uploading an artifact.');
      return null;
    }
    setUploading(true);
    try {
      const res = await createArtifact({
        file,
        name,
        kind,
        mime,
        projectId: projectId || '',
        originKind: originKind || context.originKind || 'chat',
        originRef: originRef || context.originRef || '',
      }).unwrap();
      const link = res?.link || (res?.artifact?.artifact_id ? `artifact://${res.artifact.artifact_id}` : '');
      if (!link) {
        setError('Upload failed: daemon did not return an artifact link.');
        return null;
      }
      return link;
    } catch (err: any) {
      setError(String(err?.message || err || 'Failed to upload artifact.'));
      return null;
    } finally {
      setUploading(false);
    }
  }, [session?.daemonUrl, session?.clientToken, context.originKind, context.originRef, createArtifact]);

  const uploadFile = useCallback(async (file: File | null | undefined): Promise<string | null> => {
    if (!file) return null;
    setError('');
    const classified = classifyFile(file);
    if (!classified) {
      setError(SUPPORTED_FILE_ERROR);
      return null;
    }
    const fallbackExt = ARTIFACT_UPLOAD_SPECS.find((spec) => spec.kind === classified.kind)?.exts[0] || '';
    return uploadArtifact({
      file,
      name: file.name || `artifact${fallbackExt}`,
      kind: classified.kind,
      mime: classified.mime,
      projectId: context.projectId || '',
      originKind: context.originKind || 'chat',
      originRef: context.originRef || '',
    });
  }, [uploadArtifact, context.projectId, context.originKind, context.originRef]);

  const uploadClipboardImage = useCallback(async (event: any, overrides: Partial<ArtifactUploadContext> = {}): Promise<ClipboardUploadResult> => {
    const extracted = clipboardPngFromEvent(event);
    if (!extracted.hasImage) return { handled: false, link: null };
    event?.preventDefault?.();
    setError('');
    if (extracted.unsupportedImage || !extracted.file) {
      setError('Unsupported clipboard image. Paste a PNG screenshot or image.');
      return { handled: true, link: null };
    }
    const link = await uploadArtifact({
      file: extracted.file,
      name: extracted.file.name || buildClipboardImageName(),
      kind: 'png',
      mime: 'image/png',
      projectId: overrides.projectId || context.projectId || '',
      originKind: overrides.originKind || context.originKind || 'clipboard_chat',
      originRef: overrides.originRef || context.originRef || '',
    });
    return { handled: true, link };
  }, [uploadArtifact, context.projectId, context.originKind, context.originRef]);

  return { uploading, error, clearError, uploadFile, uploadClipboardImage };
}

export type ArtifactUploadButtonProps = {
  onUploaded: (link: string) => void;
  context?: ArtifactUploadContext;
  disabled?: boolean;
  debugIdPrefix?: string;
  className?: string;
  buttonClassName?: string;
  label?: string;
};

// Self-contained upload affordance: a visible button wired to a hidden native
// file input plus inline validation/error display. `debugIdPrefix` controls the
// data-debug-id namespace so each composer can expose stable, unique IDs.
export default function ArtifactUploadButton({
  onUploaded,
  context,
  disabled,
  debugIdPrefix = 'artifact-upload',
  className,
  buttonClassName,
  label = 'Attach artifact',
}: ArtifactUploadButtonProps) {
  const inputRef = useRef<HTMLInputElement | null>(null);
  const { uploading, error, clearError, uploadFile } = useArtifactUpload(context || {});

  const handleChange = useCallback(async (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    // Reset the input so selecting the same file again re-triggers change.
    event.target.value = '';
    if (!file) return;
    const link = await uploadFile(file);
    if (link) onUploaded(link);
  }, [uploadFile, onUploaded]);

  return (
    <div className={className}>
      <input
        ref={inputRef}
        type="file"
        accept={ARTIFACT_UPLOAD_ACCEPT}
        data-debug-id={`${debugIdPrefix}-input`}
        className="hidden"
        onChange={handleChange}
      />
      <button
        type="button"
        data-debug-id={`${debugIdPrefix}-btn`}
        disabled={disabled || uploading}
        onClick={() => { clearError(); inputRef.current?.click(); }}
        title="Upload a supported artifact"
        className={buttonClassName || 'framer-pill bg-surface-raised text-primary hover:bg-neutral-soft disabled:cursor-not-allowed disabled:opacity-40'}
      >
        {uploading ? <span className="inline-block animate-bounce" aria-label="Uploading artifact">⇧</span> : label}
      </button>
      {error && (
        <div data-debug-id={`${debugIdPrefix}-error`} className="mt-1 text-xs text-danger">{error}</div>
      )}
    </div>
  );
}
