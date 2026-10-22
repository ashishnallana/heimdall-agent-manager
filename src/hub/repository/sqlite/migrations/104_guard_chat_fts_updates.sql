-- Read metadata must persist without deleting/reinserting unchanged search text.
-- Rowid is included because it is the external-content FTS document identity.
DROP TRIGGER IF EXISTS chat_conversations_fts_au;
CREATE TRIGGER chat_conversations_fts_au AFTER UPDATE ON chat_conversations
WHEN old.rowid IS NOT new.rowid OR old.title IS NOT new.title BEGIN
  INSERT INTO chat_conversations_fts(chat_conversations_fts, rowid, title) VALUES('delete', old.rowid, old.title);
  INSERT INTO chat_conversations_fts(rowid, title) VALUES(new.rowid, new.title);
END;

DROP TRIGGER IF EXISTS chat_messages_fts_au;
CREATE TRIGGER chat_messages_fts_au AFTER UPDATE ON chat_messages
WHEN old.rowid IS NOT new.rowid OR old.body IS NOT new.body BEGIN
  INSERT INTO chat_messages_fts(chat_messages_fts, rowid, body) VALUES('delete', old.rowid, old.body);
  INSERT INTO chat_messages_fts(rowid, body) VALUES(new.rowid, new.body);
END;
