-- Passwordless vault: pairing stretch (plan §1 "Pairing"). Pending devices now carry
-- the public pair_salt of the stretched pairing derivation. No backward
-- compatibility: the vault tables are dropped (devices and bridges re-enroll) and
-- upgrade_vault_directory_schema re-creates them from 092.
DROP TABLE IF EXISTS vault_wrapped_keyrings;
DROP TABLE IF EXISTS vault_epochs;
DROP TABLE IF EXISTS vault_log;
DROP TABLE IF EXISTS vault_devices;
DROP TABLE IF EXISTS vault_directories;
DROP TABLE IF EXISTS vault_directory_resets;
