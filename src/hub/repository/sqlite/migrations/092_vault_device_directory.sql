-- Passwordless vault device directory (docs/plans/passwordless-vault.md §2 P2, §1
-- "Directory log"). Idempotent (IF NOT EXISTS throughout) so
-- upgrade_vault_directory_schema can re-run it; 093 dropped the pre-log schema.
-- `kind` is validated in domain code, not by a CHECK, so a new credential kind
-- (passkey, security_key) needs no table rebuild.
--
-- vault_log is the source of truth clients verify: one signed op per directory
-- version, seq 1..version, each naming the previous op's hash. version and
-- head_hash on vault_directories always describe its last entry.
CREATE TABLE IF NOT EXISTS vault_directories (
  user_id           TEXT PRIMARY KEY,
  version           INTEGER NOT NULL,
  current_epoch     INTEGER NOT NULL,
  root_device_id    TEXT NOT NULL,
  head_hash         TEXT NOT NULL,
  genesis_statement TEXT NOT NULL,
  genesis_signature TEXT NOT NULL,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS vault_log (
  user_id    TEXT NOT NULL,
  seq        INTEGER NOT NULL,
  statement  TEXT NOT NULL,
  signature  TEXT NOT NULL,
  entry_hash TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (user_id, seq)
);
CREATE TABLE IF NOT EXISTS vault_devices (
  device_id             TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL,
  kind                  TEXT NOT NULL,
  label                 TEXT NOT NULL,
  sign_alg              TEXT NOT NULL,
  wrap_alg              TEXT NOT NULL DEFAULT '',
  sign_public_key       TEXT NOT NULL,
  ecdh_public_key       TEXT NOT NULL DEFAULT '',
  fingerprint           TEXT NOT NULL,
  bridge_id             TEXT NOT NULL DEFAULT '',
  status                TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'revoked')),
  -- Hub-blind pairing: the pending request is found by pair_lookup (derived from the
  -- code the new device shows; the hub never sees the code), the approver checks
  -- pair_key_mac over register_statement, and pair_mac is stored at approval for the
  -- new device to verify. pair_salt is the public per-request salt of the pairing
  -- stretch (the approver fetches it to derive the lookup), pair_hub_origin the
  -- canonical hub origin the device bound into that stretch (the approver derives
  -- with it; added to existing databases by 100). Pending fields are NULL once approved.
  pair_lookup           TEXT,
  pair_salt             TEXT,
  pair_hub_origin       TEXT,
  pair_key_mac          TEXT,
  register_statement    TEXT,
  pair_mac              TEXT,
  code_expires_at       TEXT,
  approval_statement    TEXT,
  approval_signature    TEXT,
  approved_by_device_id TEXT,
  revocation_statement  TEXT,
  revocation_signature  TEXT,
  revoked_by_device_id  TEXT,
  recovery_blob         TEXT NOT NULL DEFAULT '',
  created_at            TEXT NOT NULL,
  approved_at           TEXT,
  revoked_at            TEXT,
  last_seen_at          TEXT,
  -- Hub retirement HINT (bridge revoked in settings, identity replaced by an attach,
  -- rolled-back enrollment): the identity stays approved in the signed log until an
  -- approved browser signs a real revoke for it. Never consumes a directory version.
  retired_at            TEXT,
  UNIQUE (user_id, sign_public_key)
);
CREATE INDEX IF NOT EXISTS vault_devices_user ON vault_devices(user_id);
CREATE UNIQUE INDEX IF NOT EXISTS vault_devices_pending_lookup ON vault_devices(pair_lookup) WHERE status = 'pending';
-- The log op that introduced each epoch (genesis, revoke or rotate).
CREATE TABLE IF NOT EXISTS vault_epochs (
  user_id    TEXT NOT NULL,
  epoch      INTEGER NOT NULL,
  statement  TEXT NOT NULL,
  signature  TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (user_id, epoch)
);
CREATE TABLE IF NOT EXISTS vault_wrapped_keyrings (
  user_id           TEXT NOT NULL,
  device_id         TEXT NOT NULL,
  directory_version INTEGER NOT NULL,
  current_epoch     INTEGER NOT NULL,
  wrap_json         TEXT NOT NULL,
  updated_at        TEXT NOT NULL,
  PRIMARY KEY (user_id, device_id)
);
-- An owner-requested directory reset (POST /vault/directory/reset): destruction is
-- scheduled for due_at and can be cancelled by any approved device until then.
CREATE TABLE IF NOT EXISTS vault_directory_resets (
  user_id      TEXT PRIMARY KEY,
  requested_at TEXT NOT NULL,
  due_at       TEXT NOT NULL
);
