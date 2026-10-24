CREATE TABLE IF NOT EXISTS action_schedule_revision (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    revision INTEGER NOT NULL CHECK (revision >= 0)
);
INSERT OR IGNORE INTO action_schedule_revision(singleton, revision) VALUES (1, 0);
CREATE TRIGGER IF NOT EXISTS action_revision_insert AFTER INSERT ON actions BEGIN UPDATE action_schedule_revision SET revision = revision + 1 WHERE singleton = 1; END;
CREATE TRIGGER IF NOT EXISTS action_revision_update AFTER UPDATE ON actions BEGIN UPDATE action_schedule_revision SET revision = revision + 1 WHERE singleton = 1; END;
CREATE TRIGGER IF NOT EXISTS action_revision_delete AFTER DELETE ON actions BEGIN UPDATE action_schedule_revision SET revision = revision + 1 WHERE singleton = 1; END;
CREATE TRIGGER IF NOT EXISTS action_revision_member_insert AFTER INSERT ON agent_instances BEGIN UPDATE action_schedule_revision SET revision = revision + 1 WHERE singleton = 1; END;
CREATE TRIGGER IF NOT EXISTS action_revision_member_delete AFTER DELETE ON agent_instances BEGIN UPDATE action_schedule_revision SET revision = revision + 1 WHERE singleton = 1; END;
CREATE TRIGGER IF NOT EXISTS action_revision_member_update AFTER UPDATE OF bridge_id, agent_instance_id ON agent_instances WHEN OLD.bridge_id IS NOT NEW.bridge_id OR OLD.agent_instance_id IS NOT NEW.agent_instance_id BEGIN UPDATE action_schedule_revision SET revision = revision + 1 WHERE singleton = 1; END;
