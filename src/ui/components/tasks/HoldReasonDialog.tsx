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
  onHold,
  onClose,
}: {
  ticketKey: string;
  open: boolean;
  busy?: boolean;
  onHold: (reason: string) => Promise<unknown> | void;
  onClose: () => void;
}) {
  const [reason, setReason] = useState('');
  const submit = async () => {
    const trimmed = reason.trim();
    if (!trimmed) return;
    await onHold(trimmed);
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
      </ModalBody>
      <ModalFooter>
        <Button variant="secondary" onClick={onClose} data-debug-id="task-hold-cancel-btn">
          Cancel
        </Button>
        <Button variant="primary" disabled={!reason.trim() || busy} onClick={() => void submit()} data-debug-id="task-hold-confirm-btn">
          Hold
        </Button>
      </ModalFooter>
    </Modal>
  );
}
