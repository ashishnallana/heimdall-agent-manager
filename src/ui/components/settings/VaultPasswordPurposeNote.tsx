import React from 'react';

/**
 * Shown wherever a user CREATES a vault password (VaultOnboardingModal and the
 * VaultPanel setup wizard), never on unlock: creation is when a user picks the
 * password, and the moment it gets confused with the login password.
 */
export function VaultPasswordPurposeNote(): React.ReactElement {
  return (
    <p data-debug-id="vault-password-purpose-note"
      className="rounded-md border border-subtle px-3 py-2 text-xs text-muted">
      Your vault password is <strong className="font-medium text-primary">different from your login password</strong>.
      It is used for end-to-end encryption of your messages and remote connections, for added security.
    </p>
  );
}
