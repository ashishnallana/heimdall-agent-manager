// REQ-CR-1: the conversation header's Rename edits the task chain's title when the
// conversation belongs to a chain, and the conversation's own title otherwise. The
// agent record is never renamed.

export type RenameTargetKind = 'chain' | 'conversation';

export interface RenameTarget {
  kind: RenameTargetKind;
  /** Text the edit field starts with. Never vault ciphertext or a locked mask. */
  seed: string;
  saveLabel: string;
  cancelLabel: string;
  inputLabel: string;
}

export interface RenameTargetInput {
  chainId?: string | null;
  /** The chain title as shown to the user (already decrypted). */
  decryptedChainTitle?: string | null;
  /** True while the chain title is vault-armored and not yet readable. */
  chainTitleUnreadable?: boolean;
  conversationTitle?: string | null;
}

export function resolveRenameTarget(input: RenameTargetInput): RenameTarget {
  const chainId = String(input.chainId || '').trim();
  if (chainId) {
    // An unreadable (locked or still decrypting) chain title starts the field empty:
    // seeding the mask would save the mask as the new title.
    const seed = input.chainTitleUnreadable ? '' : String(input.decryptedChainTitle || '').trim();
    return {
      kind: 'chain',
      seed,
      saveLabel: 'Save chain title',
      cancelLabel: 'Cancel chain title edit',
      inputLabel: 'Task chain title',
    };
  }
  return {
    kind: 'conversation',
    seed: String(input.conversationTitle || '').trim(),
    saveLabel: 'Save conversation title',
    cancelLabel: 'Cancel title edit',
    inputLabel: 'Conversation title',
  };
}
