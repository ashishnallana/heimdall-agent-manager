import { appendArtifactLinks } from '../../utils/artifactUpload';

/**
 * State rules for the task text boxes that accept pasted or attached files
 * (plan REQ-UI-10). Pure, so the send lock and the body that is sent are
 * unit-tested. The component is TaskComposer.tsx.
 */
export type ComposerAttachmentStatus = 'uploading' | 'uploaded' | 'error';

export interface ComposerAttachment {
  localId: string;
  name: string;
  status: ComposerAttachmentStatus;
  /** artifact://<id>, set once uploaded. */
  link: string;
  error: string;
  /** Kept so a failed upload can be retried. */
  file?: File;
}

export interface ComposerSendState {
  canSend: boolean;
  uploading: boolean;
  failed: boolean;
  /** Why Send is locked, in words, or '' when it is not. */
  hint: string;
}

/** The text plus one artifact:// link per finished upload, as main's task comments do. */
export function buildComposerBody(text: string, attachments: ComposerAttachment[]): string {
  const links = attachments.filter((a) => a.status === 'uploaded' && a.link).map((a) => a.link);
  return appendArtifactLinks(String(text || '').trim(), links).trim();
}

/**
 * Send is locked while an upload is running or has failed (retry or remove it
 * first), and when there is nothing to send. `requireText` is for a box whose
 * words matter on their own (Request changes): an image alone is not enough.
 */
export function composerSendState(text: string, attachments: ComposerAttachment[], requireText = false): ComposerSendState {
  const uploading = attachments.some((a) => a.status === 'uploading');
  const failed = attachments.some((a) => a.status === 'error');
  const hasText = String(text || '').trim().length > 0;
  const hasUploads = attachments.some((a) => a.status === 'uploaded');
  if (uploading) return { canSend: false, uploading, failed, hint: 'Waiting for uploads to finish' };
  if (failed) return { canSend: false, uploading, failed, hint: 'Retry or remove the failed upload first' };
  if (requireText && !hasText) return { canSend: false, uploading, failed, hint: 'Write what needs to change first' };
  if (!hasText && !hasUploads) return { canSend: false, uploading, failed, hint: '' };
  return { canSend: true, uploading, failed, hint: '' };
}

let counter = 0;
export function newAttachmentId(): string {
  counter += 1;
  return `att_${Date.now().toString(36)}_${counter}`;
}
