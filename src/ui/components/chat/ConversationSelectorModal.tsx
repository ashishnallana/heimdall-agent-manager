import { Modal } from '@ui';
import ConversationsHomePage from './ConversationsHomePage';

export interface ConversationSelectorModalProps {
  open: boolean;
  onClose: () => void;
  onSelectConversation: (agentInstanceId: string) => void;
}

/** Reusable existing-conversation chooser for whole-app and pane destinations. */
export function ConversationSelectorModal({ open, onClose, onSelectConversation }: ConversationSelectorModalProps) {
  return (
    <Modal open={open} onOpenChange={(next) => { if (!next) onClose(); }} title="Open conversation" size="lg" data-debug-id="conversation-selector-modal">
      <Modal.Body>
        {open ? (
          <div className="max-h-[min(70vh,44rem)] overflow-y-auto">
            <ConversationsHomePage
              compact
              autoFocusSearch
              onSelectConversation={(agentInstanceId) => {
                onSelectConversation(agentInstanceId);
                onClose();
              }}
            />
          </div>
        ) : null}
      </Modal.Body>
    </Modal>
  );
}

export default ConversationSelectorModal;
