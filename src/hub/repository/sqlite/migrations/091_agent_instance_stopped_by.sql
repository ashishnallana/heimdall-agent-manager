-- Task System v2 (F4): who stopped this instance last. 'user' when a person
-- stopped it from the UI/API; the lease matcher never re-wakes or re-grants such
-- an instance (a fresh one takes its task). Cleared on an explicit user
-- start/restart. '' otherwise.
ALTER TABLE agent_instances ADD COLUMN stopped_by TEXT NOT NULL DEFAULT '';
