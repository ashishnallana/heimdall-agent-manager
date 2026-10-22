-- Provider extension permission relay (REQ-EXT-PERM-1). One row per blocking
-- permission prompt an extension forwarded through the bridge. The id is the
-- bridge-generated relay request id, so the hub's decision push can resolve the
-- exact pending relay entry. status moves pending -> allowed|denied (a user
-- decision) or pending -> expired|cancelled (timeout / instance stop); a closed
-- row is never reopened.
CREATE TABLE permission_requests (
    id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL,
    instance_id TEXT NOT NULL,
    chain_id TEXT NOT NULL DEFAULT '',
    agent_id TEXT NOT NULL DEFAULT '',
    provider TEXT NOT NULL DEFAULT '',
    tool_name TEXT NOT NULL DEFAULT '',
    tool_use_id TEXT NOT NULL DEFAULT '',
    input TEXT NOT NULL DEFAULT '{}',
    suggestions TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'allowed', 'denied', 'expired', 'cancelled')),
    decided_by TEXT NOT NULL DEFAULT '',
    message TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL DEFAULT '',
    decided_at TEXT NOT NULL DEFAULT ''
);
CREATE INDEX permission_requests_instance_status ON permission_requests(instance_id, status, created_at);
CREATE INDEX permission_requests_owner_status ON permission_requests(owner_user_id, status, created_at);
