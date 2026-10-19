-- Passwordless vault: a pending device declares the canonical hub origin it bound
-- into its pairing stretch (plan §1 "Pairing"), next to its public pair_salt. The
-- approver derives the lookup with the DECLARED origin, so a UI served on another
-- origin than the hub API base the device enrolled against still pairs. Fresh
-- databases get the column from 092 (re-run by upgrade_vault_directory_schema);
-- run_migrations skips this file when vault_devices is absent or already has it.
ALTER TABLE vault_devices ADD COLUMN pair_hub_origin TEXT;
