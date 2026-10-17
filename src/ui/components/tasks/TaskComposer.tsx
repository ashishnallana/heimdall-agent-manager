import React, { useRef, useState } from 'react';
import { Badge, Button, IconButton, Spinner, Text, Textarea } from '@ui';
import { useCreateArtifactMutation } from '../../api/endpoints/artifacts';
import { MAX_UPLOAD_BYTES } from '../ArtifactUpload';
import {
  artifactKindForFile,
  artifactLinkFromResponse,
  artifactMimeForFile,
  artifactUploadName,
  clipboardFilesFromEvent,
} from '../../utils/artifactUpload';
import {
  buildComposerBody,
  composerSendState,
  newAttachmentId,
  type ComposerAttachment,
  type ComposerSendState,
} from './taskComposer';

export interface TaskComposerActionsContext extends ComposerSendState {
  /** Text plus artifact:// links of finished uploads. */
  body: string;
  /** Clears text and uploads after a successful send. */
  reset: () => void;
}

export interface TaskComposerProps {
  chainId: string;
  taskId: string;
  placeholder: string;
  /** Words are required on their own (an image alone is not enough). */
  requireText?: boolean;
  disabled?: boolean;
  rows?: number;
  debugId?: string;
  /** The send buttons; they get the composed body and whether Send is allowed. */
  renderActions: (ctx: TaskComposerActionsContext) => React.ReactNode;
}

/**
 * A task text box that takes pasted or attached files, the same flow as the
 * task comments on main: each file is uploaded as an artifact (origin
 * `task_comment`) and its artifact:// link is appended to what is sent, so the
 * hub renders it as a preview. Used for comments, review findings and answers.
 */
export const TaskComposer: React.FC<TaskComposerProps> = ({
  chainId,
  taskId,
  placeholder,
  requireText = false,
  disabled = false,
  rows = 2,
  debugId,
  renderActions,
}) => {
  const [text, setText] = useState('');
  const [attachments, setAttachments] = useState<ComposerAttachment[]>([]);
  const [createArtifact] = useCreateArtifactMutation();
  const fileInput = useRef<HTMLInputElement | null>(null);

  const update = (localId: string, patch: Partial<ComposerAttachment>) =>
    setAttachments((items) => items.map((a) => (a.localId === localId ? { ...a, ...patch } : a)));

  const upload = async (file: File, existingId = '') => {
    const localId = existingId || newAttachmentId();
    const name = artifactUploadName(file, 'task-attachment');
    const tooLarge = file.size > MAX_UPLOAD_BYTES;
    setAttachments((items) => [
      ...items.filter((a) => a.localId !== localId),
      {
        localId,
        name,
        file,
        link: '',
        status: tooLarge ? 'error' : 'uploading',
        error: tooLarge ? `Too large. The limit is ${Math.round(MAX_UPLOAD_BYTES / (1024 * 1024))} MB.` : '',
      },
    ]);
    if (tooLarge) return;
    try {
      const res = await createArtifact({
        file,
        name,
        mime: artifactMimeForFile(file),
        kind: artifactKindForFile(file),
        originKind: 'task_comment',
        originRef: `${chainId}:${taskId}`,
        chainId,
      }).unwrap();
      const link = artifactLinkFromResponse(res);
      if (!link) throw new Error('Upload finished but no artifact link came back.');
      update(localId, { status: 'uploaded', link, error: '' });
    } catch (err: any) {
      update(localId, { status: 'error', error: String(err?.data?.message || err?.message || err || 'Upload failed') });
    }
  };

  const onPaste = (event: React.ClipboardEvent<HTMLTextAreaElement>) => {
    const files = clipboardFilesFromEvent(event);
    if (files.length === 0) return;
    event.preventDefault();
    files.forEach((file) => void upload(file));
  };

  const send = composerSendState(text, attachments, requireText);
  const ctx: TaskComposerActionsContext = {
    ...send,
    canSend: send.canSend && !disabled,
    body: buildComposerBody(text, attachments),
    reset: () => {
      setText('');
      setAttachments([]);
    },
  };

  // One row: <text box> <attach> <send…>; uploads and the send hint sit below.
  return (
    <div data-debug-id={debugId} className="space-y-1.5">
      <div className="flex items-end gap-2">
        <div className="min-w-0 flex-1">
          <Textarea
            value={text}
            onChange={setText}
            onPaste={onPaste}
            placeholder={placeholder}
            rows={rows}
            size="sm"
            width="full"
            disabled={disabled}
          />
        </div>
        <input
          ref={fileInput}
          type="file"
          multiple
          className="hidden"
          aria-hidden="true"
          tabIndex={-1}
          onChange={(e) => {
            const files = Array.from(e.target.files || []) as File[];
            e.target.value = '';
            files.forEach((file) => void upload(file));
          }}
        />
        <div className="flex shrink-0 items-center gap-1.5">
          <IconButton icon="plus" label="Attach a file" variant="ghost" size="sm" disabled={disabled} onClick={() => fileInput.current?.click()} />
          {renderActions(ctx)}
        </div>
      </div>

      {attachments.length > 0 && (
        <ul data-debug-id={debugId ? `${debugId}-attachments` : undefined} className="space-y-1">
          {attachments.map((a) => (
            <li key={a.localId} className="flex min-w-0 flex-wrap items-center gap-2 text-[11px]">
              {a.status === 'uploading' ? (
                <Spinner size="sm" label="Uploading" />
              ) : (
                <Badge tone={a.status === 'uploaded' ? 'success' : 'danger'}>{a.status === 'uploaded' ? 'Attached' : 'Failed'}</Badge>
              )}
              <span className="min-w-0 flex-1 truncate text-primary" title={a.name}>
                {a.name}
              </span>
              {a.status === 'error' && a.file && (
                <Button size="sm" variant="ghost" onClick={() => void upload(a.file!, a.localId)}>
                  Retry
                </Button>
              )}
              <Button size="sm" variant="ghost" onClick={() => setAttachments((items) => items.filter((x) => x.localId !== a.localId))}>
                Remove
              </Button>
              {a.error && (
                <Text role="caption" tone="danger" className="w-full">
                  {a.error}
                </Text>
              )}
            </li>
          ))}
        </ul>
      )}

      {send.hint && (
        <Text role="caption" tone={send.failed ? 'danger' : 'muted'}>
          {send.hint}
        </Text>
      )}
    </div>
  );
};

export default TaskComposer;
