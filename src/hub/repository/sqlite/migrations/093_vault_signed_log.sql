-- Passwordless vault: the directory becomes a hash-linked signed log (plan §1
-- "Directory log"). No backward compatibility: the pre-log tables are dropped (dev
-- data is wiped; devices and bridges re-enroll) and upgrade_vault_directory_schema
-- re-creates them from 092 in the new shape right after the migration loop.
DROP TABLE IF EXISTS vault_wrapped_keyrings;
DROP TABLE IF EXISTS vault_epochs;
DROP TABLE IF EXISTS vault_log;
DROP TABLE IF EXISTS vault_devices;
DROP TABLE IF EXISTS vault_directories;
DROP TABLE IF EXISTS vault_directory_resets;
