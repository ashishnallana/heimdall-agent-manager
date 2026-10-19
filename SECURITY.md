# Security Policy

## Supported Versions

Use this section to tell people about which versions of your project are
currently being supported with security updates.

| Version | Supported          |
| ------- | ------------------ |
| 5.1.x   | :white_check_mark: |
| 5.0.x   | :x:                |
| 4.0.x   | :white_check_mark: |
| < 4.0   | :x:                |

## Reporting a Vulnerability

Use this section to tell people how to report a vulnerability.

Tell them where to go, how often they can expect to get an update on a
reported vulnerability, what to expect if the vulnerability is accepted or
declined, etc.

## Vault (end-to-end encryption) model

Heimdall content (chat, tasks, memories, files sent to bridges, terminal captures,
search RPCs) is encrypted on the client; the hub stores only ciphertext, public keys
and a signed device log. Full design: `docs/plans/passwordless-vault.md`.

- **No master password.** Each browser and bridge holds its own non-exportable keys;
  the account keyring is ECDH-wrapped to every approved device. Devices are approved
  by typing a one-time pairing code shown by the new device on an approved one.
- **Signed device log.** Every approve / revoke / rotate is a signed, hash-linked log
  op verified from genesis by every client; the hub cannot add, hide or reorder
  devices. Revoking a device rotates to a new epoch key.
- **Last-approver guard.** A device cannot revoke itself, and revoking the only other
  approver-capable device is refused unless a recovery key exists.
- **Recovery key (opt-in).** 12 BIP-39 words (128-bit entropy, HKDF-SHA256 — no
  password stretching needed) seal a `recovery` credential's private keys; the hub
  stores only the sealed blob. The blob is bound to the account, its credential id,
  the account root and its own approval op, so wrong words, another account's words,
  a tampered blob or a revoked recovery key restore nothing.
- **Content tokens** `vault:v2:<vault_id>:e<epoch>:<b64>` bind the vault (SHA-256 of
  the root key) and the epoch in the AEAD; content of a previous (reset) vault is
  shown as such and never decrypted with new keys.
- **Residual risks** are listed in the plan (compromised UI origin, stale-head devices,
  old-epoch content readable by revoked devices).

Report vulnerabilities privately to the maintainers; do not open a public issue.
