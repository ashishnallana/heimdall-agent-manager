package hotpath_writes_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:sync"
import "core:time"
import "core:os"
import domain "odin_test:hub/domain"
import sql "odin_test:hub/repository/sqlite"

NOW :: "2026-10-22T00:00:00Z"
NEXT :: "2026-10-22T00:05:00Z"

must :: proc(ok: bool) { assert(ok) }
good :: proc(e: domain.Domain_Error) { assert(e.code == .None, e.message) }
scalar :: proc(c: ^sql.Conn, query: string) -> i64 {
    st: sql.sqlite3_stmt
    must(sql.sqlite3_prepare_v2(c.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &st, nil) == sql.SQLITE_OK)
    defer sql.sqlite3_finalize(st)
    must(sql.sqlite3_step(st) == sql.SQLITE_ROW)
    return sql.sqlite3_column_int64(st, 0)
}
text :: proc(c: ^sql.Conn, query: string) -> string {
    st: sql.sqlite3_stmt
    must(sql.sqlite3_prepare_v2(c.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &st, nil) == sql.SQLITE_OK)
    defer sql.sqlite3_finalize(st)
    must(sql.sqlite3_step(st) == sql.SQLITE_ROW)
    return sql.column_text(st, 0)
}
fixture :: proc(c: ^sql.Conn, before_103 := false, path := ":memory:") {
    opened, ok, e := sql.open(path, .Main)
    good(e); must(ok); c^ = opened
    must(sql.exec(c, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;"))
    migrated, me := sql.run_migrations(c, stop_before = ("103_guard_chat_fts_updates.sql" if before_103 else ""))
    good(me); must(migrated)
    u: sql.User_Repo_SQLite
    _ = sql.new_user_repository(&u, c)
    _, saved, ue := sql.user_save_sqlite(&u, {user_id="owner",name="owner",status=.Active,created_at=NOW,updated_at=NOW})
    good(ue); must(saved)
    must(sql.exec(c, "CREATE TABLE writes (kind TEXT);"))
}
audit :: proc(c: ^sql.Conn, table, name: string) {
    must(sql.exec(c, fmt.tprintf("CREATE TRIGGER audit_%s AFTER UPDATE ON %s BEGIN INSERT INTO writes VALUES ('%s'); END;", name, table, name)))
}
shell_row :: proc() -> domain.Shell_Session {
    return {session_id="shell",owner_user_id="owner",bridge_id="bridge",kind="run",status="running",cmd="true",created_at=NOW,started_at=NOW}
}
put_shell :: proc(r: ^sql.Shell_Session_Repo_SQLite, row: domain.Shell_Session) {
    ok, e := sql.shell_session_upsert_sqlite(r, row); good(e); must(ok)
}
seed_vault :: proc(c: ^sql.Conn) {
    must(sql.exec(c, `INSERT INTO vault_devices (device_id,user_id,kind,label,sign_alg,sign_public_key,fingerprint,status,created_at)
        VALUES ('device','owner','browser','test','ecdsa','fixture','fixture','approved','2026-10-22T00:00:00Z');`))
    audit(c, "vault_devices", "vault")
}
seed_chat :: proc(c: ^sql.Conn, r: ^sql.Content_Repo_SQLite) {
    _ = sql.new_content_repository(r, c)
    _, ok, e := sql.content_save_conversation_sqlite(r, {conversation_id="chat",owner_user_id="owner",title="beforetitle",created_at=NOW,updated_at=NOW})
    good(e); must(ok)
    _, mok, me := sql.content_save_message_sqlite(r, {message_id="message",conversation_id="chat",owner_user_id="owner",body="beforebody",direction="agent_to_user",created_at=NOW,artifact_ids_json="[]"})
    good(me); must(mok)
}

@(test)
vault_boundary_owner_clock_and_errors :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    c: sql.Conn; fixture(&c); defer sql.close(&c)
    seed_vault(&c)
    r: sql.Vault_Directory_Repo_SQLite
    _ = sql.new_vault_directory_repository(&r, &c)
    good(sql.vault_touch_last_seen_sqlite(&r, "other", "device", NOW))
    testing.expect_value(t, scalar(&c,"SELECT count(*) FROM writes"), i64(0))
    good(sql.vault_touch_last_seen_sqlite(&r, "owner", "missing", NOW))
    good(sql.vault_touch_last_seen_sqlite(&r, "owner", "device", NOW)) // NULL -> first touch
    for ts in ([]string{NOW,"2026-10-22T00:00:01Z","2026-10-22T00:04:59Z"}) {
        good(sql.vault_touch_last_seen_sqlite(&r, "owner", "device", ts))
    }
    testing.expect_value(t, scalar(&c,"SELECT count(*) FROM writes"), i64(1))
    good(sql.vault_touch_last_seen_sqlite(&r, "owner", "device", NEXT)) // inclusive 300s
    testing.expect_value(t, text(&c,"SELECT last_seen_at FROM vault_devices"), NEXT)
    testing.expect_value(t, scalar(&c,"SELECT count(*) FROM writes"), i64(2))
    good(sql.vault_touch_last_seen_sqlite(&r, "owner", "device", "2026-10-22T00:09:59Z"))
    testing.expect_value(t, scalar(&c,"SELECT count(*) FROM writes"), i64(2))
    // Regressing or invalid timestamps retain previous update behavior, never
    // leave a future value suppressing touches until wall time catches up.
    good(sql.vault_touch_last_seen_sqlite(&r, "owner", "device", NOW))
    good(sql.vault_touch_last_seen_sqlite(&r, "owner", "device", "invalid"))
    good(sql.vault_touch_last_seen_sqlite(&r, "owner", "device", NEXT))
    testing.expect_value(t, scalar(&c,"SELECT count(*) FROM writes"), i64(5))
    testing.expect_value(t, text(&c,"SELECT status FROM vault_devices"), "approved")
    must(sql.exec(&c, "CREATE TRIGGER fail_vault BEFORE UPDATE ON vault_devices BEGIN SELECT RAISE(ABORT,'injected'); END;"))
    e := sql.vault_touch_last_seen_sqlite(&r, "owner", "device", "2026-10-22T00:10:00Z")
    testing.expect(t, e.code != .None)
    testing.expect_value(t, text(&c,"SELECT last_seen_at FROM vault_devices"), NEXT)
    must(sql.exec(&c, "DROP TRIGGER fail_vault; DROP TABLE vault_devices;"))
    testing.expect(t, sql.vault_touch_last_seen_sqlite(&r,"owner","device",NOW).code != .None)
}

@(test)
shell_effective_merge_and_failures :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    c: sql.Conn; fixture(&c); defer sql.close(&c)
    r: sql.Shell_Session_Repo_SQLite
    _ = sql.new_shell_session_repository(&r, &c)
    row := shell_row()
    put_shell(&r, row); audit(&c, "shell_sessions", "shell")
    put_shell(&r, row)
    testing.expect_value(t, scalar(&c,"SELECT count(*) FROM writes"), i64(0))
    row.background=true; row.run_seq=4; row.pid=100; row.server_port=1234
    row.label="label"; row.cwd="/fixture"; row.conversation_id="chat"
    row.last_activity_at=NOW; row.kill_requested_at=NOW
    put_shell(&r,row)
    stale:=shell_row()
    put_shell(&r,stale) // defaults must preserve stored values
    testing.expect_value(t, scalar(&c,"SELECT count(*) FROM writes"), i64(1))
    stored, found, e := sql.shell_session_get_sqlite(&r,"owner","shell"); good(e); must(found)
    testing.expect(t, stored.background && stored.run_seq==4 && stored.pid==100 && stored.server_port==1234)
    testing.expect_value(t,stored.kill_requested_at,NOW)
    // Exercise every effective assignment separately; a missing comparison would
    // skip one of these meaningful writes.
    row.status="starting"; put_shell(&r,row)
    row.exit_code_set=true; row.exit_code=0; put_shell(&r,row)
    row.pid=101; put_shell(&r,row)
    row.server_port=1235; put_shell(&r,row)
    row.finished_at=NEXT; put_shell(&r,row)
    row.last_activity_at=NEXT; put_shell(&r,row)
    row.label="new label"; put_shell(&r,row)
    row.cwd="/new"; put_shell(&r,row)
    row.conversation_id="newchat"; put_shell(&r,row)
    row.kill_requested_at=NEXT; put_shell(&r,row)
    row.run_seq=5; put_shell(&r,row)
    testing.expect_value(t, scalar(&c,"SELECT count(*) FROM writes"), i64(12))
    row.exit_code_set=false; put_shell(&r,row) // NULL is different from integer 0
    row.status="exited"; put_shell(&r,row)
    stored,found,e=sql.shell_session_get_sqlite(&r,"owner","shell"); good(e); must(found)
    testing.expect_value(t,stored.kill_requested_at,"")
    testing.expect(t,!stored.exit_code_set)
    put_shell(&r,row) // terminal input still carries kill intent, effective value is empty
    testing.expect_value(t, scalar(&c,"SELECT count(*) FROM writes"), i64(14))
    for status in domain.SHELL_SESSION_TERMINAL_STATUSES {
        row.status="running"; row.kill_requested_at=NEXT; put_shell(&r,row)
        row.status=status; put_shell(&r,row)
        testing.expect_value(t,text(&c,"SELECT kill_requested_at FROM shell_sessions"),"")
    }
    // Restore the state checked by the failure assertion.
    row.status="exited"; put_shell(&r,row)
    must(sql.exec(&c, "CREATE TRIGGER fail_shell BEFORE UPDATE ON shell_sessions BEGIN SELECT RAISE(ABORT,'injected'); END;"))
    row.status="failed"
    ok, err := sql.shell_session_upsert_sqlite(&r,row)
    testing.expect(t,!ok && err.code != .None)
    testing.expect_value(t, text(&c,"SELECT status FROM shell_sessions"),"exited")
    sql.close(&c)
    ok,err=sql.shell_session_upsert_sqlite(&r,row)
    testing.expect(t,!ok && err.code != .None)
}

@(test)
fts_upgrade_latest_read_counts_search_and_repair :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    c: sql.Conn; fixture(&c,true); defer sql.close(&c)
    r: sql.Content_Repo_SQLite; seed_chat(&c,&r)
    // Existing schema/data upgrade through the production migration runner.
    ok,e:=sql.run_migrations(&c); good(e); must(ok)
    ok,e=sql.run_migrations(&c); good(e); must(ok)
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM chat_messages_fts WHERE chat_messages_fts MATCH 'beforebody'"),i64(1))
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM chat_conversations_fts WHERE chat_conversations_fts MATCH 'beforetitle'"),i64(1))
    // Shadow-table audit proves no FTS delete/insert on unchanged text, even
    // when a normal UPSERT explicitly assigns the same body/title.
    audit(&c,"chat_messages","message")
    must(sql.exec(&c, "CREATE TRIGGER fts_body_delete AFTER DELETE ON chat_messages_fts_docsize BEGIN INSERT INTO writes VALUES ('bodyfts'); END;"))
    must(sql.exec(&c, "CREATE TRIGGER fts_title_delete AFTER DELETE ON chat_conversations_fts_docsize BEGIN INSERT INTO writes VALUES ('titlefts'); END;"))
    n,me:=sql.content_mark_messages_read_sqlite(&r,"owner",[]string{"message","message","missing"},NOW)
    good(me); testing.expect_value(t,n,3) // preserve input-count incl duplicates/misses
    n,me=sql.content_mark_messages_read_sqlite(&r,"owner",[]string{"message"},NOW)
    good(me); testing.expect_value(t,n,1)
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM writes WHERE kind='message'"),i64(1))
    n,me=sql.content_mark_messages_read_sqlite(&r,"other",[]string{"message"},NEXT)
    good(me); testing.expect_value(t,n,1)
    testing.expect_value(t,text(&c,"SELECT read_at FROM chat_messages"),NOW)
    n,me=sql.content_mark_messages_read_sqlite(&r,"owner",[]string{"message"},NEXT)
    good(me); testing.expect_value(t,n,1)
    testing.expect_value(t,text(&c,"SELECT read_at FROM chat_messages"),NEXT)
    n,me=sql.content_mark_messages_read_sqlite(&r,"owner",nil,NEXT)
    good(me); testing.expect_value(t,n,0)
    must(sql.exec(&c, "UPDATE chat_messages SET body=body; UPDATE chat_conversations SET title=title, updated_at='later';"))
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM writes WHERE kind IN ('bodyfts','titlefts')"),i64(0))
    must(sql.exec(&c,"UPDATE chat_messages SET body='afterbody'; UPDATE chat_conversations SET title='aftertitle';"))
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM writes WHERE kind IN ('bodyfts','titlefts')"),i64(2))
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM chat_messages_fts WHERE chat_messages_fts MATCH 'beforebody'"),i64(0))
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM chat_messages_fts WHERE chat_messages_fts MATCH 'afterbody'"),i64(1))
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM chat_conversations_fts WHERE chat_conversations_fts MATCH 'beforetitle'"),i64(0))
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM chat_conversations_fts WHERE chat_conversations_fts MATCH 'aftertitle'"),i64(1))
    must(sql.exec(&c,"UPDATE chat_messages SET rowid=rowid+1000; UPDATE chat_conversations SET rowid=rowid+1000;"))
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM chat_messages_fts WHERE chat_messages_fts MATCH 'afterbody'"),i64(1))
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM chat_conversations_fts WHERE chat_conversations_fts MATCH 'aftertitle'"),i64(1))
    testing.expect_value(t,scalar(&c,"SELECT rowid FROM chat_messages_fts WHERE chat_messages_fts MATCH 'afterbody'"),scalar(&c,"SELECT rowid FROM chat_messages"))
    _,repaired,re:=sql.repair_fts_indexes(&c); good(re); must(repaired)
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM chat_messages_fts WHERE chat_messages_fts MATCH 'afterbody'"),i64(1))
    must(sql.exec(&c,"CREATE TRIGGER fail_read BEFORE UPDATE ON chat_messages BEGIN SELECT RAISE(ABORT,'injected'); END;"))
    n,me=sql.content_mark_messages_read_sqlite(&r,"owner",[]string{"message"},"2026-10-22T00:10:00Z")
    testing.expect(t,n==0 && me.code != .None)
    testing.expect_value(t,text(&c,"SELECT read_at FROM chat_messages"),NEXT)
    must(sql.exec(&c,"DROP TRIGGER fail_read; DROP TABLE chat_messages;"))
    n,me=sql.content_mark_messages_read_sqlite(&r,"owner",[]string{"message"},NOW)
    testing.expect(t,n==0 && me.code != .None)
}

Race :: struct {
    shell: ^sql.Shell_Session_Repo_SQLite,
    vault: ^sql.Vault_Directory_Repo_SQLite,
    content: ^sql.Content_Repo_SQLite,
    row: domain.Shell_Session,
    failed: bool,
    start: ^sync.Barrier,
}
race :: proc(r: ^Race) {
    sync.barrier_wait(r.start)
    for _ in 0..<20 {
        ok,e:=sql.shell_session_upsert_sqlite(r.shell,r.row)
        if !ok || e.code != .None do r.failed=true
        if sql.vault_touch_last_seen_sqlite(r.vault,"owner","device",NEXT).code != .None do r.failed=true
        n,me:=sql.content_mark_messages_read_sqlite(r.content,"owner",[]string{"message"},NEXT)
        if n!=1 || me.code != .None do r.failed=true
    }
}
@(test)
concurrent_atomic_guards :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    path:=fmt.tprintf("%s/.cache/heimdall-tests/hotpath-concurrency-%d.db",os.get_env("HOME",context.temp_allocator),time.tick_now())
    defer os.remove(path)
    defer os.remove(strings.concatenate({path,"-wal"},context.temp_allocator))
    defer os.remove(strings.concatenate({path,"-shm"},context.temp_allocator))
    c: sql.Conn; fixture(&c, path=path); defer sql.close(&c)
    sr: sql.Shell_Session_Repo_SQLite; _=sql.new_shell_session_repository(&sr,&c)
    vw: sql.Vault_Directory_Write_Conn
    wok,we:=sql.open_vault_directory_write_conn(&vw,path); good(we); must(wok)
    defer sql.close(&vw.conn)
    vr: sql.Vault_Directory_Repo_SQLite; _=sql.new_vault_directory_repository(&vr,&c,&vw)
    cr: sql.Content_Repo_SQLite; seed_chat(&c,&cr); seed_vault(&c)
    put_shell(&sr,shell_row()); audit(&c,"shell_sessions","shell"); audit(&c,"chat_messages","message")
    start: sync.Barrier; sync.barrier_init(&start,4)
    racers: [4]Race
    threads: [4]^thread.Thread
    for &r,i in racers {
        r.start=&start
        r.shell=&sr; r.vault=&vr; r.content=&cr; r.row=shell_row()
        r.row.run_seq=i+1
        r.row.background=i==3
        threads[i]=thread.create_and_start_with_poly_data(&r,race)
    }
    for th in threads { thread.join(th); thread.destroy(th) }
    for r in racers do testing.expect(t,!r.failed)
    testing.expect_value(t,scalar(&c,"SELECT run_seq FROM shell_sessions"),i64(4))
    testing.expect_value(t,scalar(&c,"SELECT background FROM shell_sessions"),i64(1))
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM writes WHERE kind='vault'"),i64(1))
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM writes WHERE kind='message'"),i64(1))
    testing.expect_value(t,text(&c,"SELECT last_seen_at FROM vault_devices"),NEXT)
    sql.close(&vw.conn); sql.close(&c)
    reopened,rok,re:=sql.open(path,.Main); good(re); must(rok); c=reopened
    testing.expect_value(t,text(&c,"SELECT last_seen_at FROM vault_devices"),NEXT)
    wok,we=sql.open_vault_directory_write_conn(&vw,path); good(we); must(wok)
    good(sql.vault_touch_last_seen_sqlite(&vr,"owner","device","2026-10-22T00:09:59Z"))
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM writes WHERE kind='vault'"),i64(1))
    good(sql.vault_touch_last_seen_sqlite(&vr,"owner","device","2026-10-22T00:10:00Z"))
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM writes WHERE kind='vault'"),i64(2))
}


@(test)
bridge_security_and_presence_are_immediate :: proc(t: ^testing.T) {
    context.allocator=context.temp_allocator
    c: sql.Conn; fixture(&c); defer sql.close(&c)
    r: sql.Bridge_Repo_SQLite; _=sql.new_bridge_repository(&r,&c)
    b:=domain.Bridge{bridge_id="bridge",owner_user_id="owner",status=.Online,bridge_token_hash="fixture-token-hash",last_seen_at=NOW,created_at=NOW,updated_at=NOW}
    _,ok,e:=sql.bridge_save_bridge_sqlite(&r,b); good(e); must(ok)
    audit(&c,"bridges","bridge")
    b.last_seen_at="2026-10-22T00:00:45Z"; b.updated_at=b.last_seen_at
    _,ok,e=sql.bridge_save_bridge_sqlite(&r,b); good(e); must(ok)
    testing.expect_value(t,text(&c,"SELECT last_seen_at FROM bridges"),b.last_seen_at)
    b.bridge_token_hash="fixture-new-token-hash"
    _,ok,e=sql.bridge_save_bridge_sqlite(&r,b); good(e); must(ok)
    testing.expect_value(t,text(&c,"SELECT bridge_token_hash FROM bridges"),b.bridge_token_hash)
    b.status=.Revoked; b.revoked_at=NEXT
    _,ok,e=sql.bridge_save_bridge_sqlite(&r,b); good(e); must(ok)
    testing.expect_value(t,text(&c,"SELECT status FROM bridges"),"revoked")
    testing.expect_value(t,text(&c,"SELECT revoked_at FROM bridges"),NEXT)
    testing.expect_value(t,scalar(&c,"SELECT count(*) FROM writes"),i64(3))
}
