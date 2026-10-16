-- REQ-ERR-PROTO-A: why an instance last failed, as the shared wire error object
-- ({"code","class","cause","message"}) its bridge reported. '' while not failed.
-- The hub acts on class (retriable / recoverable / fatal); the UI shows cause.
ALTER TABLE agent_instances ADD COLUMN last_error_json TEXT NOT NULL DEFAULT '';
