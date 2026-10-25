package sqlite

// Check columns, key order, uniqueness, foreign ownership and nonce expiry index,
// rather than treating the existence of either table as proof of a complete apply.
native_oidc_schema_complete :: proc(conn: ^Conn) -> bool {
	query :: `
SELECT
 (SELECT group_concat(name || ':' || upper(type) || ':' || "notnull" || ':' || pk, ',')
  FROM (SELECT * FROM pragma_table_info('user_external_identities') ORDER BY cid))
 = 'issuer:TEXT:1:1,subject:TEXT:1:2,user_id:TEXT:1:0,created_at:TEXT:1:0'
 AND
 (SELECT group_concat(name || ':' || upper(type) || ':' || "notnull" || ':' || pk, ',')
  FROM (SELECT * FROM pragma_table_info('vault_request_nonces') ORDER BY cid))
 = 'user_id:TEXT:1:1,device_id:TEXT:1:2,nonce:TEXT:1:3,expires_ms:INTEGER:1:0'
 AND (SELECT count(*) FROM pragma_foreign_key_list('user_external_identities')) = 1
 AND EXISTS (SELECT 1 FROM pragma_foreign_key_list('user_external_identities')
             WHERE "table" = 'users' AND "from" = 'user_id' AND "to" = 'user_id'
               AND on_update = 'NO ACTION' AND on_delete = 'NO ACTION')
 AND EXISTS (SELECT 1 FROM pragma_index_list('user_external_identities') AS i
             WHERE i."unique" = 1 AND i.partial = 0
               AND (SELECT group_concat(name, ',') FROM pragma_index_info(i.name)) = 'user_id')
 AND EXISTS (SELECT 1 FROM pragma_index_list('vault_request_nonces') AS i
             WHERE i.name = 'vault_request_nonces_expiry' AND i.partial = 0
               AND (SELECT group_concat(name, ',') FROM pragma_index_info(i.name)) = 'expires_ms');
`
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(conn.db, query, -1, &stmt, nil) != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int64(stmt, 0) == 1
}
