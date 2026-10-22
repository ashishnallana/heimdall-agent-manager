-- Keep schema, catalog and snapshots atomic, including recovery before ledger recording.
BEGIN IMMEDIATE;
ALTER TABLE billing_plans ADD COLUMN terminal_input_enabled INTEGER NOT NULL DEFAULT 0 CHECK (terminal_input_enabled IN (0, 1));
ALTER TABLE billing_plans ADD COLUMN max_concurrent_streams INTEGER NOT NULL DEFAULT 2 CHECK (max_concurrent_streams >= -1);
ALTER TABLE billing_plans ADD COLUMN shells_enabled INTEGER NOT NULL DEFAULT 0 CHECK (shells_enabled IN (0, 1));
ALTER TABLE account_entitlements ADD COLUMN terminal_input_enabled INTEGER NOT NULL DEFAULT 0 CHECK (terminal_input_enabled IN (0, 1));
ALTER TABLE account_entitlements ADD COLUMN max_concurrent_streams INTEGER NOT NULL DEFAULT 2 CHECK (max_concurrent_streams >= -1);
ALTER TABLE account_entitlements ADD COLUMN shells_enabled INTEGER NOT NULL DEFAULT 0 CHECK (shells_enabled IN (0, 1));
ALTER TABLE account_entitlements ADD COLUMN override_terminal_input_enabled INTEGER CHECK (override_terminal_input_enabled IN (0, 1));
ALTER TABLE account_entitlements ADD COLUMN override_max_concurrent_streams INTEGER CHECK (override_max_concurrent_streams >= -1);
ALTER TABLE account_entitlements ADD COLUMN override_shells_enabled INTEGER CHECK (override_shells_enabled IN (0, 1));
ALTER TABLE bridges ADD COLUMN plan_disabled_at TEXT NOT NULL DEFAULT '';

UPDATE billing_plans SET max_bridges = 1, terminal_streaming_enabled = 1, terminal_input_enabled = 0, max_concurrent_streams = 2, shells_enabled = 0 WHERE plan_id = 'free';
UPDATE billing_plans SET terminal_input_enabled = 1, max_concurrent_streams = -1, shells_enabled = 1 WHERE plan_id != 'free';
UPDATE billing_plans SET max_bridges = 2 WHERE plan_id = 'hobbyist';

-- Recompute the effective plan, including expired grace periods; keep all overrides.
UPDATE account_entitlements SET
    max_bridges = COALESCE(override_max_bridges, (SELECT p.max_bridges FROM account_billing b
        JOIN billing_plans p ON p.plan_id = CASE
            WHEN b.status IN ('active', 'trialing', 'custom')
                OR (b.status = 'past_due' AND b.grace_until > strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            THEN b.plan_id ELSE 'free' END
        WHERE b.user_id = account_entitlements.user_id)),
    terminal_streaming_enabled = COALESCE(override_terminal_streaming_enabled, (SELECT p.terminal_streaming_enabled FROM account_billing b
        JOIN billing_plans p ON p.plan_id = CASE
            WHEN b.status IN ('active', 'trialing', 'custom')
                OR (b.status = 'past_due' AND b.grace_until > strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            THEN b.plan_id ELSE 'free' END
        WHERE b.user_id = account_entitlements.user_id)),
    terminal_input_enabled = COALESCE(override_terminal_input_enabled, (SELECT p.terminal_input_enabled FROM account_billing b
        JOIN billing_plans p ON p.plan_id = CASE
            WHEN b.status IN ('active', 'trialing', 'custom')
                OR (b.status = 'past_due' AND b.grace_until > strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            THEN b.plan_id ELSE 'free' END
        WHERE b.user_id = account_entitlements.user_id)),
    max_concurrent_streams = COALESCE(override_max_concurrent_streams, (SELECT p.max_concurrent_streams FROM account_billing b
        JOIN billing_plans p ON p.plan_id = CASE
            WHEN b.status IN ('active', 'trialing', 'custom')
                OR (b.status = 'past_due' AND b.grace_until > strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            THEN b.plan_id ELSE 'free' END
        WHERE b.user_id = account_entitlements.user_id)),
    shells_enabled = COALESCE(override_shells_enabled, (SELECT p.shells_enabled FROM account_billing b
        JOIN billing_plans p ON p.plan_id = CASE
            WHEN b.status IN ('active', 'trialing', 'custom')
                OR (b.status = 'past_due' AND b.grace_until > strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            THEN b.plan_id ELSE 'free' END
        WHERE b.user_id = account_entitlements.user_id));

DROP TRIGGER users_billing_defaults;
CREATE TRIGGER users_billing_defaults AFTER INSERT ON users BEGIN
    INSERT INTO account_billing (user_id, created_at, updated_at)
        VALUES (NEW.user_id, NEW.created_at, NEW.updated_at);
    INSERT INTO account_entitlements (user_id, max_bridges, terminal_streaming_enabled, terminal_input_enabled, max_concurrent_streams, shells_enabled, updated_at)
        SELECT NEW.user_id, max_bridges, terminal_streaming_enabled, terminal_input_enabled, max_concurrent_streams, shells_enabled, NEW.updated_at
        FROM billing_plans WHERE plan_id = 'free';
END;
COMMIT;
