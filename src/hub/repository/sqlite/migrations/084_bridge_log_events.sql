-- Bridge error-event relay (bridge_logs plan v2 §4.3): the per-bridge ring of
-- structured warn/error events a bridge shipped over its WebSocket.
--
-- NO owner_user_id COLUMN. Ownership is a join on bridges(bridge_id) at read
-- time (one fewer copy of an identity, and revoke/owner changes stay consistent).
-- NO free text: `code` is an enum name (unknown -> 'other') and `fields_json` is
-- the hub-normalised allow-listed object; human text is rendered per code by the
-- hub. NO FOREIGN KEY, matching every other table here; the revoke path and the
-- writer's per-bridge cap keep it bounded (<= 500 rows/bridge, <= 7 d).
CREATE TABLE IF NOT EXISTS bridge_log_events (
  id          INTEGER PRIMARY KEY,
  bridge_id   TEXT    NOT NULL,
  ts_ms       INTEGER NOT NULL,            -- bridge clock (clamped on ingest)
  received_at INTEGER NOT NULL,            -- hub unix ms
  level       TEXT    NOT NULL,            -- 'warn' | 'error'
  code        TEXT    NOT NULL,
  fields_json TEXT    NOT NULL DEFAULT '{}',
  count       INTEGER NOT NULL DEFAULT 1
);

-- Owner API pagination (newest first by id) and the writer's per-bridge cap.
CREATE INDEX IF NOT EXISTS bridge_log_events_bridge_id_desc ON bridge_log_events(bridge_id, id DESC);
-- The reaper's time prune (received_at < now - 7d) every 15 min.
CREATE INDEX IF NOT EXISTS bridge_log_events_received_at ON bridge_log_events(received_at);
