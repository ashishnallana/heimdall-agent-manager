import type { KeyboardEvent, ReactNode, RefObject } from 'react';
import { containsVaultArmored, isVaultArmored } from '../../utils/vaultContent.ts';

export type ChatMessage = {
  key: string;
  messageId: string;
  body: string;
  isUser: boolean;
  createdUnixMs: number;
  deliveredUnixMs: number;
  readUnixMs: number;
  deliveryFailedUnixMs: number;
  deliveryError: string;
  sending: boolean;
  authorLabel: string;
  artifactIds?: string[];
  messageType?: string;
  messageStatus?: string;
  metadata?: any;
};

export type ChatTimestamp = { label: string; iso: string };
export type ChatDeliveryStatus = { glyph: string; label: string; tone: string };

export type ChatComposerNotice = {
  debugId: string;
  message: ReactNode;
  tone?: 'error' | 'info' | 'neutral';
};

export type ChatComposerMention = {
  type: 'agent' | 'task' | 'task-chain' | 'memory' | 'project' | 'artifact';
  id: string;
};

export type ChatComposerMentionSuggestion = ChatComposerMention & {
  label: string;
  metadata?: string;
};

export type ChatComposerSubmitPayload = {
  body: string;
  artifactIds: string[];
  mentions?: ChatComposerMention[];
};

export type ChatComposerUploadResult = string | { artifactId?: string; artifact_id?: string; link?: string; name?: string; kind?: string } | null | undefined;

export type ChatComposerUploadProps = {
  onUploaded?: (link: string) => void;
  uploadFile?: (file: File) => Promise<ChatComposerUploadResult>;
  searchMentions?: (category: ChatComposerMention['type'], query: string) => Promise<ChatComposerMentionSuggestion[]>;
  context?: { projectId?: string; originRef?: string; originKind?: string };
  disabled?: boolean;
  uploading?: boolean;
  debugIdPrefix: string;
  buttonClassName?: string;
  label?: string;
  error?: string;
  clearError?: () => void;
  sendStructuredMentions?: boolean;
};

export type ChatComposerRuntimeControlsProps = {
  debugPrefix: string;
  providers?: any[];
  projects?: any[];
  provider: string;
  model: string;
  projectId: string;
  disabled?: boolean;
  restarting?: boolean;
  showProject?: boolean;
  onRestart: (next: { provider: string; model: string; projectId: string }) => void | Promise<void>;
};

export type ChatComposerProps = {
  shellDebugId: string;
  inputDebugId: string;
  sendButtonDebugId: string;
  sendAriaLabel: string;
  value: string;
  onValueChange: (value: string) => void;
  onSubmit: (payload?: ChatComposerSubmitPayload) => void | Promise<void>;
  onPaste?: (event: any) => void | Promise<void>;
  onKeyDown?: (event: KeyboardEvent<HTMLTextAreaElement>) => void;
  inputRef?: RefObject<HTMLTextAreaElement | null>;
  placeholder: string;
  rows?: number;
  autoFocus?: boolean;
  sendTitle?: string;
  sendDisabled?: boolean;
  sendLabel?: ReactNode;
  sendError?: string;
  sendErrorDebugId?: string;
  uploadErrorDebugId?: string;
  upload?: ChatComposerUploadProps | null;
  runtimeControls?: ChatComposerRuntimeControlsProps | null;
  notices?: ChatComposerNotice[];
  leftAdornment?: ReactNode;
  footer?: ReactNode;
  keyboardHint?: ReactNode;
  shellClassName?: string;
  textareaClassName?: string;
  controlsClassName?: string;
  footerClassName?: string;
  // UI-13: when true, the composer is bottom-pinned on mobile and lifts above
  // the soft keyboard via safe-area + visualViewport insets. No effect on desktop.
  mobileBottomPinned?: boolean;
};

export function extractMessageOptions(message: { metadata?: any; metadata_json?: string }): string[] {
  let meta = message.metadata;
  if (typeof meta === 'string') {
    try {
      meta = JSON.parse(meta);
    } catch {
      meta = null;
    }
  }
  if (!meta && message.metadata_json) {
    try {
      meta = JSON.parse(message.metadata_json);
    } catch {
      meta = null;
    }
  }
  if (meta && Array.isArray(meta.options)) {
    return meta.options.map((opt: any) => String(opt)).filter((opt: string) => opt.trim() !== '');
  }
  return [];
}

/**
 * Quick-reply options to render for a message. While its body is still vault ciphertext
 * (no active key), the options are hidden too: they are not part of the encrypted body,
 * so showing them would print plaintext beside an "Encrypted content" placeholder.
 * Armored options are likewise hidden until they can be read.
 */
export function visibleMessageOptions(
  message: { body?: string; metadata?: any; metadata_json?: string },
  hasVaultKey: boolean,
): string[] {
  if (hasVaultKey) return extractMessageOptions(message);
  const body = message.body || '';
  if (isVaultArmored(body) || containsVaultArmored(body)) return [];
  return extractMessageOptions(message).filter((opt) => !containsVaultArmored(opt));
}

export function extractMessageActionIds(message: { metadata?: any; metadata_json?: string }): string[] {
  let meta = message.metadata;
  if (typeof meta === 'string') {
    try {
      meta = JSON.parse(meta);
    } catch {
      meta = null;
    }
  }
  if (!meta && message.metadata_json) {
    try {
      meta = JSON.parse(message.metadata_json);
    } catch {
      meta = null;
    }
  }
  if (!meta) return [];
  const raw = meta.action_ids ?? meta.actions ?? meta.actionId ?? meta.action_id;
  if (Array.isArray(raw)) {
    return raw.map((a: any) => String(a).trim()).filter((s: string) => s !== '');
  }
  if (typeof raw === 'string' && raw.trim()) {
    return [raw.trim()];
  }
  return [];
}

