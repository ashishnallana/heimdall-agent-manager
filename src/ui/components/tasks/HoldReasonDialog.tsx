import React, { useState } from 'react';
import { Button, Input, Modal, ModalBody, ModalFooter, Text } from '@ui';

/**
 * Asks for a hold reason, then holds the ticket. Replaces window.prompt, which
 * throws in the desktop app ("prompt() is not supported").
 */
export function HoldReasonDialog({
  ticketKey,
  open,
  busy,
  error,
  onHold,
  onClose,
}: {
  ticketKey: string;
  open: boolean;
  busy?: boolean;
  /** Why the last hold failed; shown in the dialog, which stays open. */
  error?: string;
  /** Resolves true once the hold is placed; false keeps the dialog open with the reason. */
  onHold: (reason: string) => Promise<boolean>;
  onClose: () => void;
}) {
  const [reason, setReason] = useState('');
  const [sending, setSending] = useState(false);
  const submit = async () => {
    const trimmed = reason.trim();
    // Enter must not send a second hold while one is in flight.
    if (!trimmed || busy || sending) return;
    setSending(true);
    const held = await onHold(trimmed).finally(() => setSending(false));
    if (!held) return;
    setReason('');
    onClose();
  };
  return (
    <Modal open={open} onOpenChange={(next) => !next && onClose()} title={`Hold ${ticketKey}?`} size="sm" data-debug-id="task-hold-dialog">
      <ModalBody className="space-y-3">
        <Text as="p" role="body-sm" tone="muted">
          No new lease until it is released.
        </Text>
        <Input
          value={reason}
          onChange={setReason}
          width="full"
          placeholder="Reason"
          aria-label="Hold reason"
          autoFocus
          onKeyDown={(e) => e.key === 'Enter' && void submit()}
          data-debug-id="task-hold-reason-input"
        />
        {error && (
          <Text as="p" role="caption" tone="danger" className="whitespace-pre-line break-words" data-debug-id="task-hold-error">
            {error}
          </Text>
        )}
      </ModalBody>
      <ModalFooter>
        <Button variant="secondary" onClick={onClose} data-debug-id="task-hold-cancel-btn">
          Cancel
        </Button>
        <Button variant="primary" disabled={!reason.trim() || busy || sending} onClick={() => void submit()} data-debug-id="task-hold-confirm-btn">
          Hold
        </Button>
      </ModalFooter>
    </Modal>
  );
}
