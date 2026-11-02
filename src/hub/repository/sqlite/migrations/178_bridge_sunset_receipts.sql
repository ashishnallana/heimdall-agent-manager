-- REQ-3 (setup wizard "register new and sunset one"): the durable receipt of a sunset.
--
-- Approving a new bridge with sunset_bridge_id retires that bridge IN the admission
-- transaction that inserts the pending replacement. The replacement is not enrolled
-- until its vault key is delivered (REQ-EA), and every way a pending enrollment can
-- roll back afterwards -- the approval's own vault-commit failure, the operator's
-- cancel, the bridge's committed:false, the expiry sweep (also at startup, after a
-- crash) -- must give the sunset bridge back. Those paths run long after the
-- approval request, on other threads or another process lifetime, so the receipt
-- lives here and not in memory. It is written in the admission transaction, consumed
-- (restore + delete) in the transaction that deletes the pending replacement, and
-- dropped in the transaction that commits the replacement (the sunset is then final).
--
-- token ids are listed rather than matched by revoked_at: a family that theft
-- detection revoked at the same instant must never be revived.
--
-- No FOREIGN KEY, matching bridge_tokens (057): the repository deletes these rows
-- explicitly, in the same transactions that change the rows they describe.
BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS bridge_sunset_receipts (
  replacement_bridge_id TEXT PRIMARY KEY,   -- the pending bridge whose approval did the sunset
  sunset_bridge_id      TEXT NOT NULL,      -- the bridge it retired
  revoked_at            TEXT NOT NULL       -- the revoked_at the sunset stamped on row and tokens
);
CREATE TABLE IF NOT EXISTS bridge_sunset_receipt_tokens (
  replacement_bridge_id TEXT NOT NULL,
  token_id              TEXT NOT NULL,      -- a bridge_tokens row the sunset revoked
  PRIMARY KEY (replacement_bridge_id, token_id)
);
COMMIT;
