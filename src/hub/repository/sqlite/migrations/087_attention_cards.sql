-- Attention deck v1: action cards become the canonical envelope for what needs
-- the user's attention. v1 projects two sources: tasks awaiting the user's
-- review, and the latest unread agent message that offers reply options.
--   kind            canonical attention kind; each provider maps to exactly one
--   attention_since when the source started needing the user (drives the
--                   time-range filter and the age label)
--   source_marker   opaque fingerprint of the source state the card was
--                   projected from; only a CHANGED marker reactivates a card
--                   the user already acted on, or wakes a snoozed one
--   details_json    typed per-provider snapshot the deck renders (vault
--                   ciphertext copied verbatim)
--   action_refs_json typed routing ids for direct-endpoint actions;
--                   source_refs_json stays the free-form evidence array
ALTER TABLE cards ADD COLUMN kind TEXT NOT NULL DEFAULT 'approval';
ALTER TABLE cards ADD COLUMN attention_since TEXT NOT NULL DEFAULT '';
ALTER TABLE cards ADD COLUMN source_marker TEXT NOT NULL DEFAULT '';
ALTER TABLE cards ADD COLUMN details_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE cards ADD COLUMN action_refs_json TEXT NOT NULL DEFAULT '{}';

UPDATE cards SET kind = 'task' WHERE provider = 'task_validation';
UPDATE cards SET kind = 'memory' WHERE provider = 'memory_proposal';
UPDATE cards SET attention_since = created_at WHERE attention_since = '';

CREATE INDEX IF NOT EXISTS idx_cards_attention
  ON cards(owner_user_id, status, kind, attention_since);

-- Per-owner scan of unread incoming messages for the message projector and the
-- reconciliation sweep. The metadata.options test runs on this small unread set
-- at query time instead of being mirrored into a column, so a later metadata
-- update can never leave a stale flag behind.
-- Message cards are deduplicated per agent instance, hence the sender key.
CREATE INDEX IF NOT EXISTS idx_chat_messages_unread_incoming
  ON chat_messages(owner_user_id, sender_agent_instance_id, created_at)
  WHERE direction = 'agent_to_user' AND read_at = '';
