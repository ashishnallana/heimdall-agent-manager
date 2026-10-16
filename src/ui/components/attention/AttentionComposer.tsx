import { useRef, useState } from 'react';
import { Button, Icon } from '@ui';
import { useCreateArtifactMutation } from '../../api/endpoints';
import { MAX_UPLOAD_BYTES } from '../ArtifactUpload';
import {
  artifactIdFromLink,
  artifactKindForFile,
  artifactLinkFromResponse,
  artifactMimeForFile,
  artifactUploadName,
  clipboardFilesFromEvent,
} from '../../utils/artifactUpload';

export type ComposerAttachment = { localId: string; name: string; status: 'uploading' | 'uploaded' | 'error'; id: string; link: string; error: string };

export type ComposerSubmit = { text: string; attachments: ComposerAttachment[] };

/**
 * Inline composer for an attention card: a reply to an agent question, or a task
 * comment. Images can be pasted or dropped; each is uploaded as an artifact as it
 * arrives (same helpers as the task comment box). The caller decides what Send
 * does with the text and the uploaded attachments.
 */
export function AttentionComposer({
  placeholder,
  originKind,
  originRef,
  submitLabel,
  secondaryLabel,
  onSubmit,
  onSecondary,
  onCancel,
  debugId,
}: {
  placeholder: string;
  originKind: string;
  originRef: string;
  submitLabel: string;
  /** Optional second send button (e.g. "Request changes"). */
  secondaryLabel?: string;
  onSubmit: (value: ComposerSubmit) => Promise<void>;
  onSecondary?: (value: ComposerSubmit) => Promise<void>;
  onCancel: () => void;
  debugId: string;
}) {
  const [text, setText] = useState('');
  const [attachments, setAttachments] = useState<ComposerAttachment[]>([]);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState('');
  const [createArtifact] = useCreateArtifactMutation();
  const counter = useRef(0);

  const upload = async (file: File) => {
    counter.current += 1;
    const localId = `att_${counter.current}`;
    const name = artifactUploadName(file, 'attention-attachment');
    if (file.size > MAX_UPLOAD_BYTES) {
      setAttachments((prev) => [...prev, { localId, name, status: 'error', id: '', link: '', error: 'File is too large' }]);
      return;
    }
    setAttachments((prev) => [...prev, { localId, name, status: 'uploading', id: '', link: '', error: '' }]);
    try {
      const res = await createArtifact({ file, name, mime: artifactMimeForFile(file), kind: artifactKindForFile(file), originKind, originRef } as any).unwrap();
      const link = artifactLinkFromResponse(res);
      const id = artifactIdFromLink(link);
      if (!id) throw new Error('Upload failed');
      setAttachments((prev) => prev.map((a) => (a.localId === localId ? { ...a, status: 'uploaded', id, link } : a)));
    } catch (err: any) {
      setAttachments((prev) => prev.map((a) => (a.localId === localId ? { ...a, status: 'error', error: String(err?.message || 'Upload failed') } : a)));
    }
  };

  const addFiles = (files: File[]) => files.forEach((file) => void upload(file));
  const busy = sending || attachments.some((a) => a.status === 'uploading');
  const ready = (text.trim() !== '' || attachments.some((a) => a.status === 'uploaded')) && !attachments.some((a) => a.status === 'error');

  const send = async (handler: (value: ComposerSubmit) => Promise<void>) => {
    if (!ready || busy) return;
    setSending(true);
    setError('');
    try {
      await handler({ text: text.trim(), attachments: attachments.filter((a) => a.status === 'uploaded') });
      setText('');
      setAttachments([]);
    } catch (err: any) {
      setError(String(err?.data?.error || err?.message || 'Could not send'));
    } finally {
      setSending(false);
    }
  };

  return (
    <div
      data-debug-id={debugId}
      className="mt-2 rounded-[var(--radius-md)] border border-subtle bg-surface p-2"
      onDragOver={(e) => e.preventDefault()}
      onDrop={(e) => {
        e.preventDefault();
        addFiles(Array.from(e.dataTransfer?.files || []).filter((f) => f.type.startsWith('image/')));
      }}
    >
      <textarea
        data-debug-id={`${debugId}-input`}
        autoFocus
        value={text}
        placeholder={placeholder}
        rows={3}
        onChange={(e) => setText(e.target.value)}
        onPaste={(e) => {
          const files = clipboardFilesFromEvent(e);
          if (files.length === 0) return;
          e.preventDefault();
          addFiles(files);
        }}
        onKeyDown={(e) => {
          if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            void send(onSubmit);
          } else if (e.key === 'Escape') {
            e.stopPropagation();
            onCancel();
          }
        }}
        className="w-full resize-y bg-transparent text-[13px] text-primary outline-none placeholder:text-faint"
      />
      {attachments.length > 0 ? (
        <ul data-debug-id={`${debugId}-attachments`} className="mb-1 flex flex-wrap gap-1">
          {attachments.map((a) => (
            <li key={a.localId} className={`inline-flex items-center gap-1 rounded-full border px-2 text-[11px] ${a.status === 'error' ? 'border-danger-soft text-danger' : 'border-subtle text-muted'}`}>
              <Icon name={a.status === 'error' ? 'alert' : 'file'} size={12} />
              <span className="max-w-[160px] truncate">{a.status === 'uploading' ? 'Uploading…' : a.status === 'error' ? a.error : a.name}</span>
              <button type="button" aria-label="Remove attachment" className="text-faint hover:text-primary" onClick={() => setAttachments((prev) => prev.filter((x) => x.localId !== a.localId))}>
                <Icon name="close" size={10} />
              </button>
            </li>
          ))}
        </ul>
      ) : null}
      {error ? <p role="alert" className="mb-1 text-[12px] text-danger">{error}</p> : null}
      <div className="flex flex-wrap items-center justify-end gap-2">
        <span className="mr-auto text-[11px] text-faint">⌘↵ to send · paste or drop images</span>
        <Button size="sm" variant="ghost" onClick={onCancel} data-debug-id={`${debugId}-cancel`}>Cancel</Button>
        {secondaryLabel && onSecondary ? (
          <Button size="sm" tone="danger" disabled={!ready || busy} onClick={() => void send(onSecondary)} data-debug-id={`${debugId}-secondary`}>
            {secondaryLabel}
          </Button>
        ) : null}
        <Button size="sm" variant="primary" disabled={!ready || busy} onClick={() => void send(onSubmit)} data-debug-id={`${debugId}-submit`}>
          {submitLabel}
        </Button>
      </div>
    </div>
  );
}
