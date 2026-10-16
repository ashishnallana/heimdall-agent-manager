import React, { useState, useEffect } from 'react';
import { useSelector } from 'react-redux';
import { VaultText } from '../vault/VaultText';
import {
  isVaultArmored,
  containsVaultArmored,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
} from '../../utils/vaultContent';
import { selectActiveVaultKey } from '../../store/vaultSlice';
import { visibleMessageOptions } from './types';
import Markdown from '../Markdown';
import ChatActionCard from './ChatActionCard';

export interface MessageItemProps {
  message: {
    messageId?: string;
    id?: string;
    body: string;
    author?: string;
    isUser?: boolean;
    createdUnixMs?: number;
    timestamp?: string;
    metadata?: any;
    metadata_json?: string;
    [key: string]: any;
  };
  onReply?: (reply: string) => void;
  className?: string;
}

export const MessageItem: React.FC<MessageItemProps> = ({ message, onReply, className = '' }) => {
  const messageId = String(message.messageId || message.id || '');
  const body = message.body || '';
  const isArmored = isVaultArmored(body);
  const containsArmored = containsVaultArmored(body);
  const hasVault = isArmored || containsArmored;
  // Key material lives only as a non-extractable CryptoKey (REQ-VAULT-HARDEN-1).
  // state.vault.rawVaultKeyHex is never assigned, so the old `rawKey || getActiveVaultKey()`
  // worked solely by its fallback, and the render gates below could show raw ciphertext
  // whenever the vault reported unlocked without a key. Both now test the real key.
  const activeKey = useSelector(selectActiveVaultKey);
  const [decryptedBody, setDecryptedBody] = useState<string | null>(null);
  const options = visibleMessageOptions(message, Boolean(activeKey));

  useEffect(() => {
    let active = true;
    if (!hasVault) {
      setDecryptedBody(body);
      return;
    }
    if (!activeKey) {
      setDecryptedBody(null);
      return;
    }
    const decryptPromise = isArmored
      ? decryptVaultText(body, activeKey)
      : decryptEmbeddedVaultTokens(body, activeKey);
    decryptPromise
      .then((txt) => {
        if (active) setDecryptedBody(txt);
      })
      .catch(() => {
        if (active) setDecryptedBody(body);
      });
    return () => {
      active = false;
    };
  }, [body, hasVault, isArmored, activeKey]);

  return (
    <div
      data-debug-id={`message-item-${messageId}`}
      className={`message-item flex flex-col gap-1 py-1 ${className}`}
    >
      <div data-debug-id={`message-body-${messageId}`} className="text-sm">
        {isArmored && !activeKey ? (
          <VaultText value={body} as="div" />
        ) : containsArmored && !activeKey ? (
          <Markdown
            source={body.replace(/vault:v1:[A-Za-z0-9+/=]+/g, '[🔒 Encrypted]')}
            compact
            copyAll={false}
          />
        ) : (
          <Markdown source={decryptedBody ?? body} compact copyAll={false} />
        )}
      </div>
      <ChatActionCard message={message} conversationId={message.conversationId} onReply={onReply} />
      {options.length > 0 && !message.isUser && (
        <div data-debug-id={`message-options-${messageId}`} className="mt-2 flex flex-wrap gap-1.5">
          {options.map((option, optIdx) => (
            <button
              key={optIdx}
              type="button"
              data-debug-id={`option-chip-${messageId}-${optIdx}`}
              onClick={() => onReply?.(option)}
              className="inline-flex items-center rounded-full border border-accent/40 bg-accent/10 px-3 py-1 text-xs font-medium text-accent hover:bg-accent/20 active:scale-95 transition-all cursor-pointer"
            >
              {option}
            </button>
          ))}
        </div>
      )}
    </div>
  );
};

export default MessageItem;
