-- Memory proposals remember who proposed them and on which task chain, so the
-- attention deck can say "<agent> proposed a fact while working on <chain>".
-- Both are '' for memories created by the user or before this migration.
ALTER TABLE memories ADD COLUMN proposed_by_instance_id TEXT NOT NULL DEFAULT '';
ALTER TABLE memories ADD COLUMN proposed_in_chain_id TEXT NOT NULL DEFAULT '';
-- The projector's reconciliation lists an owner's pending proposals.
CREATE INDEX IF NOT EXISTS idx_memories_owner_status ON memories(owner_user_id, status);
