-- REQ-TV2-5: a fleet row can be paused, per role, without touching live
-- leases. '' = not paused; a JSON array of role names = those roles paused;
-- '["*"]' = every role of the row paused. The matcher grants no new lease of a
-- paused role to the row. upgrade_task_v2_schema ensures the same column.
ALTER TABLE task_chain_fleets ADD COLUMN paused_roles_json TEXT NOT NULL DEFAULT '';
