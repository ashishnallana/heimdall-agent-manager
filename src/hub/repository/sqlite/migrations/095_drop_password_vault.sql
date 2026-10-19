-- The password-era single-key vault table, replaced by the passwordless device
-- directory (092-094), and the dead plaintext ('disabled') bridge vault status.
-- No backward compatibility.
DROP TABLE IF EXISTS user_vaults;
UPDATE bridges SET vault_status = '' WHERE vault_status NOT IN ('unlocked', 'locked');
