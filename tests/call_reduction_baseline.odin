// Standalone deterministic repository/service replay, never connects to a Hub.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:encoding/json"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import dbt "odin_test:hub/platform/dbtelemetry"
import metrics "odin_test:lib/metrics"
import sql "odin_test:hub/repository/sqlite"
import iface "odin_test:hub/repository/iface"
import content "odin_test:hub/service/content"
import taskchain "odin_test:hub/service/taskchain"
import taskv2 "odin_test:hub/service/taskv2"
import bridge_service "odin_test:hub/service/bridge"
import http "odin_test:hub/transport/http"

NOW :: "2026-10-22T00:00:00Z"
OWNER :: "baseline-owner"

Counts :: struct { select, insert, update, delete, begin, commit, vm, fullscan, hits, misses, page_writes, main_locks, vault_locks, vault_mutex: i64 }

snapshot :: proc(reg: ^metrics.Registry) -> Counts {
    b := strings.builder_make()
    defer strings.builder_destroy(&b)
    metrics.gather(reg, &b)
    result: Counts
    for line in strings.split_lines(strings.to_string(b)) {
        fields := strings.fields(line)
        if len(fields) != 2 do continue
        value, ok := strconv.parse_i64(fields[1])
        if !ok do continue
        if strings.has_prefix(line, "heimdall_sqlite_statements_total{") {
            if strings.contains(line, `op="select"`) do result.select += value
            if strings.contains(line, `op="insert"`) do result.insert += value
            if strings.contains(line, `op="update"`) do result.update += value
            if strings.contains(line, `op="delete"`) do result.delete += value
            if strings.contains(line, `op="begin"`) do result.begin += value
            if strings.contains(line, `op="commit"`) do result.commit += value
        }
        if strings.has_prefix(line, "heimdall_db_lock_wait_seconds_count{") {
            if strings.contains(line, `lock="conn_main"`) do result.main_locks += value
            if strings.contains(line, `lock="conn_vault"`) do result.vault_locks += value
            if strings.contains(line, `lock="vault"`) do result.vault_mutex += value
        }
        if strings.has_prefix(line, "heimdall_sqlite_vm_steps_total{") do result.vm += value
        if strings.has_prefix(line, "heimdall_sqlite_fullscan_steps_total{") do result.fullscan += value
        if strings.has_prefix(line,"heimdall_sqlite_cache_events_total{") {
            if strings.contains(line,`kind="hit"`) do result.hits += value
            if strings.contains(line,`kind="miss"`) do result.misses += value
            if strings.contains(line,`kind="write"`) do result.page_writes += value
        }
    }
    return result
}

show :: proc(reg: ^metrics.Registry, name: string, modeled_http: int, before: Counts) {
    after := snapshot(reg)
    fmt.printf("Lock acquisitions [%s]: conn_main=%d conn_vault=%d vault_mutex=%d\n", name,
        after.main_locks-before.main_locks, after.vault_locks-before.vault_locks, after.vault_mutex-before.vault_mutex)
    s := after.select-before.select
    i := after.insert-before.insert
    u := after.update-before.update
    d := after.delete-before.delete
    fmt.printf("| %s | %d | %d | %d | %d | %d | %d | %d | %d | %d | %d | %d | %d | %d |\n", name, modeled_http,
        s, i, u, d, after.begin-before.begin, after.commit-before.commit, i+u+d,
        after.vm-before.vm, after.fullscan-before.fullscan, after.hits-before.hits,after.misses-before.misses,after.page_writes-before.page_writes)
}

check :: proc(err: domain.Domain_Error) { if err.code != .None { fmt.eprintln(err); os.exit(1) } }
require :: proc(ok: bool) { if !ok { fmt.eprintln("baseline assertion failed"); os.exit(1) } }
fixed_now :: proc(_: rawptr) -> string { return NOW }
next_id :: proc(ctx: rawptr, prefix: string) -> string { n := (^int)(ctx); n^ += 1; return fmt.tprintf("%sfixture-%d",prefix,n^) }
same :: proc(a,b: $T) { x,xe:=json.marshal(a);y,ye:=json.marshal(b);require(xe==nil && ye==nil && string(x)==string(y)) }

// Checkpoint probes are outside scenario snapshots. TRUNCATE starts a fresh WAL;
// PASSIVE returns appended frame count, not inferred physical-device writes.
wal_frames :: proc(conn: ^sql.Conn, reset: bool) -> i64 {
    query := "PRAGMA wal_checkpoint(PASSIVE);"
    if reset do query = "PRAGMA wal_checkpoint(TRUNCATE);"
    stmt: sql.sqlite3_stmt
    require(sql.sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query), -1, &stmt, nil) == sql.SQLITE_OK)
    defer sql.sqlite3_finalize(stmt)
    require(sql.sqlite3_step(stmt) == sql.SQLITE_ROW)
    require(sql.sqlite3_column_int64(stmt, 0) == 0)
    frames := sql.sqlite3_column_int64(stmt, 1)
    require(sql.sqlite3_step(stmt) == sql.SQLITE_DONE)
    return frames
}
advancing_now :: proc(ctx: rawptr) -> string {
    seconds := (^int)(ctx)^
    return fmt.tprintf("2026-10-22T%02d:%02d:%02dZ", seconds/3600, (seconds/60)%60, seconds%60)
}

main :: proc() {
    context.allocator = context.temp_allocator
    require(len(os.args) == 2)
    dbt.set_mode(.Basic)
    reg := metrics.init_global()
    dbt.init(reg)
    sql.sqlite_metrics_init(reg)
    conn, ok, err := sql.open(os.args[1], .Main)
    check(err); require(ok)
    defer sql.close(&conn)
    // Production durability is retained; this is a scratch file only.
    require(sql.exec(&conn, "PRAGMA journal_mode=WAL;"))
    require(sql.exec(&conn, "PRAGMA synchronous=NORMAL;"))
    require(sql.exec(&conn, "PRAGMA busy_timeout=5000;"))
    migrated, migration_err := sql.run_migrations(&conn)
    check(migration_err); require(migrated)
    user_impl: sql.User_Repo_SQLite
    _ = sql.new_user_repository(&user_impl,&conn)
    _,user_ok,user_err := sql.user_save_sqlite(&user_impl,domain.User{user_id=OWNER,name=OWNER,status=.Active,created_at=NOW,updated_at=NOW})
    check(user_err); require(user_ok)
    shell_impl: sql.Shell_Session_Repo_SQLite
    _ = sql.new_shell_session_repository(&shell_impl, &conn)
    bridge_impl: sql.Bridge_Repo_SQLite
    bridge_repo := sql.new_bridge_repository(&bridge_impl, &conn)
    content_impl: sql.Content_Repo_SQLite
    content_repo := sql.new_content_repository(&content_impl, &conn)
    task_impl: sql.Taskchain_Repo_SQLite
    task_repo := sql.new_taskchain_repository(&task_impl, &conn)
    card_impl: sql.Card_Repo_SQLite
    _=sql.new_card_repository(&card_impl,&conn)
    _,card_ok,card_err := sql.card_create_sqlite(&card_impl,domain.Card{card_id="fixture-card",owner_user_id=OWNER,
        title="fixture",provider="fixture",status="pending",scope="task",created_at=NOW,updated_at=NOW})
    check(card_err);require(card_ok)
    agent_impl: sql.Agent_Repo_SQLite
    _=sql.new_agent_repository(&agent_impl,&conn)
    _,agent_ok,agent_err := sql.agent_save_sqlite(&agent_impl,domain.Agent{agent_id="fixture-agent",owner_user_id=OWNER,name="fixture",slug="fixture",created_at=NOW,updated_at=NOW})
    check(agent_err);require(agent_ok)
    vault_impl: sql.Vault_Directory_Repo_SQLite
    _ = sql.new_vault_directory_repository(&vault_impl, &conn)

    // All workload data is generated; migrations provide the actual schema/indexes.
    require(sql.exec(&conn, "BEGIN;"))
    kinds := []string{"run","shell","server"}
    for n in 0..<600 {
        session := domain.Shell_Session{session_id=fmt.tprintf("sh_%04d", n), owner_user_id=OWNER,
            bridge_id=fmt.tprintf("bridge_%d", (n/20)%20), kind=kinds[n%3], status="exited", cmd="true",
            agent_instance_id="fixture-instance",chain_id="chain_0",
            started_at=NOW, created_at=NOW, finished_at=NOW}
        if n%20 == 0 { session.status="running"; session.finished_at="" }
        saved, e := sql.shell_session_upsert_sqlite(&shell_impl, session)
        check(e); require(saved)
    }
    for n in 0..<60 {
        _, saved, e := sql.content_save_conversation_sqlite(&content_impl, domain.Chat_Conversation{
            conversation_id=fmt.tprintf("chat_%d", n), owner_user_id=OWNER, agent_id="agent", agent_instance_id="instance",
            title="fixture",unread_count=100, created_at=NOW, updated_at=NOW})
        check(e); require(saved)
        for m in 0..<100 {
            _, saved, e := sql.content_save_message_sqlite(&content_impl, domain.Chat_Message{
                message_id=fmt.tprintf("msg_%d_%d", n,m), conversation_id=fmt.tprintf("chat_%d", n),
                owner_user_id=OWNER, direction="agent_to_user", body="fixture", artifact_ids_json="[]", created_at=NOW})
            check(e); require(saved)
        }
    }
    for n in 0..<30 {
        cid := domain.Task_Chain_ID(fmt.tprintf("chain_%d", n))
        _, saved, e := sql.taskchain_save_chain_sqlite(&task_impl, domain.Task_Chain{
            chain_id=cid, owner_user_id=OWNER, title="fixture", kind=domain.CHAIN_KIND_MIXED_WORK, created_at=NOW, updated_at=NOW})
        if !saved do fmt.eprintln(string(sql.sqlite3_errmsg(conn.db)))
        check(e); require(saved)
        rid := domain.Workflow_Run_ID(fmt.tprintf("fixture-run-%d",n))
        _,run_ok,run_err := sql.insert_workflow_run_sqlite(&task_impl,domain.Workflow_Run{
            run_id=rid,chain_id=cid,owner_user_id=OWNER,title="fixture",definition_ref="fixture@1",spec_json="{}",inputs_json="{}",
            current_execution_no=1,request_id=fmt.tprintf("request-%d",n),request_hash="fixture",created_by_kind="hub",created_by_id="fixture",created_at=NOW,updated_at=NOW,revision=1})
        check(run_err);require(run_ok)
        _,execution_ok,execution_err := sql.insert_workflow_execution_sqlite(&task_impl,domain.Workflow_Run_Execution{
            run_id=rid,execution_no=1,chain_id=cid,owner_user_id=OWNER,state="running",resolved_inputs_json="{}",output_manifest_json="{}",revision=1})
        check(execution_err);require(execution_ok)
        for m in 0..<20 {
            _, saved, e := sql.task_save_sqlite(&task_impl, domain.Task{task_id=domain.Task_ID(fmt.tprintf("task_%d_%d",n,m)),
                chain_id=cid, owner_user_id=OWNER, title="fixture",publish_state=.Published, workflow_run_id=rid,workflow_execution_no=1,stage_key="fixture",stage_index=m, created_at=NOW, updated_at=NOW})
            check(e); require(saved)
        }
        for m in 1..<20 {
            _, saved, e := sql.taskchain_save_dependency_sqlite(&task_impl, domain.Task_Dependency{
                task_id=domain.Task_ID(fmt.tprintf("task_%d_%d",n,m)), depends_on_task_id=domain.Task_ID(fmt.tprintf("task_%d_%d",n,m-1)),
                chain_id=cid, owner_user_id=OWNER, created_at=NOW})
            if !saved do fmt.eprintln(string(sql.sqlite3_errmsg(conn.db)))
            check(e); require(saved)
        }
    }
    bridge := domain.Bridge{bridge_id="bridge_0", owner_user_id=OWNER, label="fixture", status=.Online,
        capabilities_json="{}", created_at=NOW, updated_at=NOW, last_seen_at=NOW}
    _, saved, e := sql.bridge_save_bridge_sqlite(&bridge_impl, bridge)
    check(e); require(saved)
    for n in 1..<20 {
        other:=bridge;other.bridge_id=fmt.tprintf("bridge_%d",n)
        _,saved,e:=sql.bridge_save_bridge_sqlite(&bridge_impl,other);check(e);require(saved)
    }
    require(sql.exec(&conn, "COMMIT;"))
    vault_write: sql.Vault_Directory_Write_Conn
    vw_ok, vw_err := sql.open_vault_directory_write_conn(&vault_write, os.args[1])
    check(vw_err); require(vw_ok)
    defer sql.close(&vault_write.conn)
    _ = sql.new_vault_directory_repository(&vault_impl, &conn, &vault_write)
    check(sql.vault_create_genesis_sqlite(&vault_impl, domain.Vault_Genesis{
        directory={user_id=OWNER,version=1,current_epoch=1,root_device_id="fixture-device",head_hash="h",created_at=NOW,updated_at=NOW},
        device={device_id="fixture-device",user_id=OWNER,kind="browser",label="fixture",sign_alg="ecdsa-p256-sha256",wrap_alg="ecdh-p256-hkdf-sha256-aes256gcm",sign_public_key="fixture",ecdh_public_key="fixture",status=.Approved,created_at=NOW,last_seen_at=NOW},
        epoch={user_id=OWNER,epoch=1,created_at=NOW},log={user_id=OWNER,seq=1,entry_hash="h",created_at=NOW},
        wrap={user_id=OWNER,device_id="fixture-device",wrap_json="{}",updated_at=NOW}}))
    require(sql.exec(&conn, "BEGIN;"))
    for n in 0..<400 {
        token := domain.Bridge_Token{token_id=fmt.tprintf("fixture-token-%d",n),bridge_id="bridge_0",kind=.Access,
            token_hash=fmt.tprintf("synthetic-not-a-credential-%d",n),family_id=fmt.tprintf("family-%d",n),
            scope="bridge:enroll",issued_at=NOW,expires_at="2026-10-23T00:00:00Z",family_expires_at="2026-11-22T00:00:00Z"}
        if n%20 != 0 do token.revoked_at=NOW
        _,saved,e := sql.bridge_save_token_sqlite(&bridge_impl,token);check(e);require(saved)
    }
    require(sql.exec(&conn, "COMMIT;"))

    fmt.printf("SQLite library: %s. Scratch DB only; WAL/NORMAL match app/wiring.odin:247-248.\n",string(sql.sqlite3_libversion()))
    fmt.println("Fixture: 600 shells (30 live; 200 each run/shell/server), 20 bridges, 60 conversations / 6000 messages, 30 chains / 600 tasks / 570 dependencies, 400 tokens (20 unrevoked).")
    fmt.println("HTTP column is modeled triggers; SQL and VM/fullscan are measured from real procs. Writes = executed DML statements, not disk writes.")
    fmt.println("| Scenario | HTTP modeled | SELECT | INSERT | UPDATE | DELETE | BEGIN | COMMIT | Writes | VM | Fullscan | Cache hit | Cache miss | Cache page write |")
    fmt.println("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    clock := platform.Clock{now=fixed_now}
    before := snapshot(reg)
    for _ in 0..<30 { check(sql.vault_touch_last_seen_sqlite(&vault_impl,OWNER,"fixture-device",NOW)) }
    show(reg,"vault identical touch x30 dedicated conn",30,before)
    original_shell,shell_found,shell_err:=sql.shell_session_get_sqlite(&shell_impl,OWNER,"sh_0000");check(shell_err);require(shell_found)
    before=snapshot(reg)
    for _ in 0..<92 {
        session := domain.Shell_Session{session_id="sh_0000",owner_user_id=OWNER,bridge_id="bridge_0",kind="run",status="running",cmd="true",started_at=NOW,created_at=NOW,agent_instance_id="fixture-instance",chain_id="chain_0"}
        saved, e := sql.shell_session_upsert_sqlite(&shell_impl,session); check(e); require(saved)
    }
    show(reg,"shell identical registration x92",92,before)
    after_shell,after_shell_found,after_shell_err:=sql.shell_session_get_sqlite(&shell_impl,OWNER,"sh_0000");check(after_shell_err);require(after_shell_found);same(original_shell,after_shell)
    original_bridge,original_bridge_found,original_bridge_err:=sql.bridge_get_bridge_sqlite(&bridge_impl,"bridge_0");check(original_bridge_err);require(original_bridge_found)
    before=snapshot(reg)
    for _ in 0..<120 { _, saved,e := sql.bridge_save_bridge_sqlite(&bridge_impl,bridge);check(e);require(saved) }
    show(reg,"bridge identical save x120",0,before)
    after_bridge,bridge_found,bridge_err:=sql.bridge_get_bridge_sqlite(&bridge_impl,"bridge_0");check(bridge_err);require(bridge_found);same(original_bridge,after_bridge)
    bsvc := bridge_service.new_bridge_service(&bridge_repo,&clock,nil)
    before=snapshot(reg)
    for _ in 0..<120 { _,saved,e:=bridge_service.update_runtime_capabilities(&bsvc,"bridge_0","{}");check(e);require(saved) }
    show(reg,"bridge heartbeat same state x120 service",0,before)
    before=snapshot(reg)
    for iteration in 0..<3 { _,changed,e:=bridge_service.mark_bridge_offline(&bsvc,"bridge_0");check(e);require(changed==(iteration==0)) }
    show(reg,"bridge offline repeated x3 service",0,before)
    before=snapshot(reg)
    for _ in 0..<120 { _,_,e:=bridge_service.update_vault_status(&bsvc,"bridge_0","unlocked");check(e) }
    show(reg,"bridge vault status same x120 service",0,before)
    ids := []string{"msg_0_0","msg_0_1","msg_0_2","msg_0_3","msg_0_4","msg_0_5","msg_0_6","msg_0_7","msg_0_8","msg_0_9"}
    sequence := 0
    generator := platform.ID_Generator{ctx=&sequence,generate=next_id}
    svc := content.Content_Service{content=&content_repo,clock=&clock,ids=&generator}
    auth := contracts.Auth_Context{kind=.User_Token,user_id=OWNER}
    before=snapshot(reg)
    for iteration in 0..<21 {
        _,receipts,saved,e := content.mark_read_with_receipts(&svc,auth,"chat_1");check(e);require(saved)
        require(len(receipts) == (100 if iteration==0 else 0))
    }
    show(reg,"conversation read x21 service",21,before)
    before=snapshot(reg)
    for _ in 0..<20 { _,receipts,saved,e := content.mark_read_with_receipts(&svc,auth,"chat_1");check(e);require(saved && len(receipts)==0) }
    show(reg,"conversation already read x20 service",20,before)
    read_seconds:=4
    read_clock:=platform.Clock{ctx=&read_seconds,now=advancing_now}
    svc.clock=&read_clock
    before=snapshot(reg)
    for _ in 0..<20 { _,receipts,saved,e:=content.mark_read_with_receipts(&svc,auth,"chat_1");check(e);require(saved && len(receipts)==0);read_seconds+=4 }
    show(reg,"conversation already read changing clock x20",20,before)
    svc.clock=&clock
    before=snapshot(reg)
    for _ in 0..<21 { _, e := content.mark_messages_read_by_ids(&svc,auth,ids);check(e) }
    show(reg,"mark read same 10 ids x21 service",21,before)
    before=snapshot(reg)
    for _ in 0..<20 { _,e:=content.mark_messages_read_by_ids(&svc,auth,ids);check(e) }
    show(reg,"agent already read same 10 ids x20 service",20,before)
    before=snapshot(reg)
    factory_impl: sql.SQLite_Unit_Of_Work_Factory
    repos: iface.Repositories
    factory := sql.new_unit_of_work_factory(&factory_impl,&conn,&repos)
    engine := taskv2.new_service(&task_repo,nil,nil,&clock,&generator)
    engine.uow_factory=&factory
    tsvc := taskchain.Taskchain_Service{repo=&task_repo,clock=&clock,ids=&generator,engine=&engine,uow_factory=&factory}
    for _ in 0..<30 { _,_,saved,e := taskchain.comment_task(&tsvc,auth,{task_id="task_0_0",body="fixture comment"});check(e);require(saved) }
    show(reg,"task comments x30 service engine no projector",30,before)
    comments,comments_err := sql.task_comment_list_by_task_sqlite(&task_impl,"task_0_0",OWNER)
    check(comments_err);require(len(comments)==30)
    before=snapshot(reg)
    for _ in 0..<10 { _,found,e:=sql.user_get_by_id_sqlite(&user_impl,OWNER);check(e);require(found) }
    show(reg,"auth user lookup component x10",10,before)
    before=snapshot(reg)
    for _ in 0..<10 { rows,_,e:=sql.shell_session_list_by_owner_sqlite(&shell_impl,OWNER,{},"",50);check(e);require(len(rows)==50) }
    show(reg,"shell owner list component x10",10,before)
    before=snapshot(reg)
    for _ in 0..<10 { _,found,e:=sql.card_get_sqlite(&card_impl,"fixture-card");check(e);require(found) }
    show(reg,"card detail component x10",10,before)
    before=snapshot(reg)
    for _ in 0..<10 { _,found,e:=sql.task_get_sqlite(&task_impl,"task_0_0");check(e);require(found) }
    show(reg,"task detail component x10",10,before)
    before=snapshot(reg)
    for _ in 0..<10 { _,found,e:=sql.agent_get_sqlite(&agent_impl,"fixture-agent");check(e);require(found) }
    show(reg,"agent identity component x10",10,before)
    before=snapshot(reg)
    for _ in 0..<10 { rows,e:=sql.taskchain_list_chains_by_owner_sqlite(&task_impl,OWNER);check(e);require(len(rows)==30) }
    show(reg,"chain list component x10",10,before)
    handlers := http.Taskchain_Handlers{taskchains=&tsvc,content=&svc}
    before=snapshot(reg)
    for _ in 0..<10 { rows:=http.enrich_chain_list_items(&handlers,auth,nil,false,true);require(len(rows)==0) }
    show(reg,"empty search delta enrichment helper x10",10,before)
    // Reopening drops only SQLite's connection page cache, never the host OS cache.
    sql.close(&conn)
    conn,ok,err=sql.open(os.args[1],.Main);check(err);require(ok)
    require(sql.exec(&conn,"PRAGMA synchronous=NORMAL;"))
    require(sql.exec(&conn,"PRAGMA busy_timeout=5000;"))
    for pass in 0..<2 {
        before=snapshot(reg)
        for _ in 0..<10 { _, e := sql.content_list_conversations_sqlite(&content_impl,OWNER,100,"");check(e) }
        show(reg,fmt.tprintf("conversations x10 pass %d",pass),10,before)
        before=snapshot(reg)
        for _ in 0..<10 { _, e := sql.shell_session_list_live_bridge_ids_sqlite(&shell_impl,1024);check(e) }
        show(reg,fmt.tprintf("live bridge ids x10 pass %d",pass),0,before)
        before=snapshot(reg)
        for _ in 0..<10 { _, e := sql.shell_session_list_live_by_kind_sqlite(&shell_impl,"server",100);check(e) }
        show(reg,fmt.tprintf("live by kind x10 pass %d",pass),0,before)
        before=snapshot(reg)
        for _ in 0..<10 { _, e := sql.taskchain_list_dependencies_by_chain_sqlite(&task_impl,"chain_0",OWNER);check(e) }
        show(reg,fmt.tprintf("chain dependencies x10 pass %d",pass),10,before)
        before=snapshot(reg)
        for _ in 0..<10 { _, e := sql.bridge_list_live_tokens_by_scope_sqlite(&bridge_impl,"bridge:enroll");check(e) }
        show(reg,fmt.tprintf("live enroll tokens x10 pass %d",pass),0,before)
    }
    before=snapshot(reg)
    for _ in 0..<10 { _, e := sql.shell_session_delete_terminal_before_owners_sqlite(&shell_impl,"2026-01-01T00:00:00Z");check(e) }
    show(reg,"retention no expired rows x10",0,before)
    // Candidate indexes exist ONLY in this disposable fixture, never a migration.
    // Real repo calls ensure later task changes are reflected automatically.
    require(sql.exec(&conn,"CREATE INDEX baseline_shell_live_kind ON shell_sessions(kind,started_at,session_id,status);"))
    require(sql.exec(&conn,"CREATE INDEX baseline_shell_bridge_status ON shell_sessions(bridge_id,status);"))
    require(sql.exec(&conn,"CREATE INDEX baseline_retention ON shell_sessions(status,COALESCE(NULLIF(finished_at, ''), NULLIF(last_activity_at, ''), started_at));"))
    require(sql.exec(&conn,"CREATE INDEX baseline_tokens_scope_live ON bridge_tokens(scope,revoked_at);"))
    require(sql.exec(&conn,"CREATE INDEX baseline_dependencies_chain ON task_dependencies(chain_id,owner_user_id,created_at);"))
    before=snapshot(reg)
    for _ in 0..<10 { rows,e:=sql.shell_session_list_live_bridge_ids_sqlite(&shell_impl,1024);check(e);require(len(rows)==20) }
    show(reg,"candidate indexes live bridge ids x10",0,before)
    before=snapshot(reg)
    for _ in 0..<10 { rows,e:=sql.shell_session_list_live_by_kind_sqlite(&shell_impl,"server",100);check(e);require(len(rows)==10) }
    show(reg,"candidate indexes live server kind x10",0,before)
    before=snapshot(reg)
    for _ in 0..<10 { rows,e:=sql.taskchain_list_dependencies_by_chain_sqlite(&task_impl,"chain_0",OWNER);check(e);require(len(rows)==19) }
    show(reg,"candidate indexes dependencies x10",0,before)
    before=snapshot(reg)
    for _ in 0..<10 { rows,e:=sql.bridge_list_live_tokens_by_scope_sqlite(&bridge_impl,"bridge:enroll");check(e);require(len(rows)==20) }
    show(reg,"candidate indexes live tokens x10",0,before)
    before=snapshot(reg)
    for _ in 0..<10 { rows,e:=sql.shell_session_delete_terminal_before_owners_sqlite(&shell_impl,"2026-01-01T00:00:00Z");check(e);require(len(rows)==0) }
    show(reg,"candidate indexes retention x10",0,before)
    // Realistic changing timestamps: 30 GET touches at the pending-device 4s
    // cadence and 120 heartbeats at the default 45s cadence. Calls execute without
    // sleeping; the fixture measures work, not production contention or latency.
    require(wal_frames(&conn,true)==0)
    seconds := 4
    before=snapshot(reg)
    for _ in 0..<30 {
        check(sql.vault_touch_last_seen_sqlite(&vault_impl,OWNER,"fixture-device",advancing_now(&seconds)))
        seconds += 4
    }
    show(reg,"vault advancing 4s x30 dedicated conn",30,before)
    fmt.printf("WAL frames [vault advancing 4s x30]: %d\n",wal_frames(&conn,false))
    require(wal_frames(&conn,true)==0)
    advancing_clock := platform.Clock{ctx=&seconds,now=advancing_now}
    bsvc.clock=&advancing_clock
    seconds=45
    before=snapshot(reg)
    for _ in 0..<120 {
        _,saved,e:=bridge_service.update_runtime_capabilities(&bsvc,"bridge_0","{}");check(e);require(saved)
        seconds += 45
    }
    show(reg,"bridge heartbeat advancing 45s x120 service",0,before)
    fmt.printf("WAL frames [bridge heartbeat advancing 45s x120]: %d\n",wal_frames(&conn,false))
    require(snapshot(reg).vm > 0)
}
