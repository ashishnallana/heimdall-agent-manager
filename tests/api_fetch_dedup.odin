// Standalone behavioral checks: real SQLite, auth, service and HTTP handler.
// Generated credentials stay in this disposable process and are never printed.
package main

import "core:fmt"
import "core:os"
import "core:encoding/json"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import sql "odin_test:hub/repository/sqlite"
import iface "odin_test:hub/repository/iface"
import content "odin_test:hub/service/content"
import taskchain "odin_test:hub/service/taskchain"
import bridge "odin_test:hub/service/bridge"
import auth "odin_test:hub/service/auth"
import http "odin_test:hub/transport/http"

NOW :: "2026-10-22T00:00:00Z"
OWNER :: "fetch-owner"
require :: proc(ok: bool, message: string) { if !ok { fmt.eprintln(message); os.exit(1) } }
check :: proc(err: domain.Domain_Error) { require(err.code == .None, err.message) }
clock_now :: proc(_: rawptr) -> string { return NOW }
next_id :: proc(ctx: rawptr, prefix: string) -> string { n := (^int)(ctx); n^ += 1; return fmt.tprintf("%sfetch-%d", prefix, n^) }
Envelope :: struct { data: http.Task_Chain_Search_Feed_Wire }

feed :: proc(h: ^http.Taskchain_Handlers, headers: []contracts.HTTP_Header, query: string) -> http.Task_Chain_Search_Feed_Wire {
    response := http.task_chain_search_documents_handler(h, http.Request{
        method="GET",path="/bridge/task-chain-search/documents",query=query,headers=headers,
        request_id="fixture", remote_addr="127.0.0.1:1234",
    })
    require(response.status==200, "search handler must succeed")
    require(response.content_type=="application/json", "content type preserved")
    require(len(response.headers)==0, "feed currently has no ETag/cache headers")
    result: Envelope
    err := json.unmarshal(transmute([]u8)response.body, &result)
    require(err==nil, "feed envelope parses")
    return result.data
}

main :: proc() {
    context.allocator = context.temp_allocator
    conn, ok, err := sql.open(":memory:")
    check(err); require(ok,"open")
    defer sql.close(&conn)
    migrated, migration_err := sql.run_migrations(&conn)
    check(migration_err); require(migrated,"migrations")
    user_impl: sql.User_Repo_SQLite
    _ = sql.new_user_repository(&user_impl, &conn)
    for owner in ([]string{OWNER,"other-owner"}) {
        _, saved, e := sql.user_save_sqlite(&user_impl, domain.User{user_id=domain.User_ID(owner), name=owner, status=.Active, created_at=NOW,updated_at=NOW})
        check(e); require(saved,"save owner")
    }
    clock := platform.Clock{now=clock_now}
    sequence := 0
    ids := platform.ID_Generator{ctx=&sequence,generate=next_id}
    bridge_impl: sql.Bridge_Repo_SQLite
    bridge_repo := sql.new_bridge_repository(&bridge_impl,&conn)
    bridge_svc := bridge.new_bridge_service(&bridge_repo,&clock,&ids)
    enrolled, enrolled_ok, enrolled_err := bridge.enroll_bridge_from_device_grant(&bridge_svc, {
        owner_user_id=OWNER, bridge_public_key="04aabb",bridge_key_fingerprint="fixture",machine_hostname="fixture",
    })
    check(enrolled_err); require(enrolled_ok,"fixture bridge enrollment")
    auth_svc := auth.Auth_Service{bridges=&bridge_svc,clock=&clock}
    headers := []contracts.HTTP_Header{{name="Authorization", value=fmt.tprintf("Bearer %s",enrolled.bridge_token)}}
    task_impl: sql.Taskchain_Repo_SQLite
    task_repo := sql.new_taskchain_repository(&task_impl,&conn)
    task_svc := taskchain.new_taskchain_service(&task_repo,nil,&clock,&ids)
    content_impl: sql.Content_Repo_SQLite
    content_repo := sql.new_content_repository(&content_impl,&conn)
    content_svc := content.Content_Service{content=&content_repo}
    h := http.Taskchain_Handlers{auth=&auth_svc,taskchains=&task_svc,content=&content_svc}
    empty := feed(&h,headers,"")
    require(empty.snapshot_revision==0 && empty.next_revision==0 && !empty.has_more && len(empty.documents)==0,"empty snapshot")
    // Empty enrichment must not dereference even a non-nil unconfigured service.
    broken := content.Content_Service{}
    h.content=&broken
    items := http.enrich_chain_list_items(&h,{kind=.User_Token,user_id=OWNER},nil,false,true)
    require(len(items)==0,"empty helper")
    h.content=&content_svc

    // Full and narrow projections must have identical owner/order/window semantics,
    // including tied order keys, empty last_message_at and >200 conversations.
    for n in 0..<206 {
        c := domain.Chat_Conversation{conversation_id=fmt.tprintf("chat_%03d",n),owner_user_id=OWNER,
            agent_id="agent",agent_instance_id=fmt.tprintf("instance_%d",n),chain_id=fmt.tprintf("chain_%d",n),
            project_id=domain.Project_ID(fmt.tprintf("project_%d",n)),title="fixture",created_at=NOW,updated_at=NOW}
        if n%3==0 do c.last_message_at="2026-10-23T00:00:00Z"
        if n==205 do c.owner_user_id="other-owner"
        _, saved, e := iface.content_save_conversation(&content_repo,c)
        check(e); require(saved,"save conversation")
    }
    full, full_err := iface.content_list_conversations(&content_repo,OWNER,200,""); check(full_err)
    links, links_err := content.list_conversation_project_links(&content_svc,{kind=.User_Token,user_id=OWNER}); check(links_err)
    require(len(full)==200 && len(links)==200,"projection retains 200 boundary")
    for c,i in full {
        link:=links[i]
        require(c.conversation_id==link.conversation_id && c.agent_instance_id==link.agent_instance_id &&
            c.project_id==link.project_id && c.chain_id==link.chain_id,"projection equivalence")
    }
    other, other_err := content.list_conversation_project_links(&content_svc,{kind=.User_Token,user_id="other-owner"}); check(other_err)
    require(len(other)==1 && other[0].conversation_id=="chat_205","owner isolation")
    _, unauthorized := content.list_conversation_project_links(&content_svc,{})
    require(unauthorized.code!=.None,"projection requires auth")

    // Preserve coordinator lookup precedence, chain fallback and absent mapping.
    chains := []domain.Task_Chain{
        {chain_id="chain_1",owner_user_id=OWNER,kind=domain.CHAIN_KIND_MIXED_WORK,title="title",coordinator_agent_instance_id="instance_3",created_at=NOW,updated_at=NOW},
        {chain_id="chain_3",owner_user_id=OWNER,kind=domain.CHAIN_KIND_MIXED_WORK,title="fallback",created_at=NOW,updated_at=NOW,status=.Archived},
        {chain_id="missing",owner_user_id=OWNER,kind=domain.CHAIN_KIND_MIXED_WORK,title="unassigned",created_at=NOW,updated_at=NOW},
    }
    enriched:=http.enrich_chain_list_items(&h,{kind=.User_Token,user_id=OWNER},chains,false,true)
    require(len(enriched)==3,"all enriched chains")
    require(enriched[0].project_id=="project_3","coordinator mapping wins")
    require(enriched[1].project_id=="project_3" && enriched[1].coordinator_agent_instance_id=="instance_3","chain fallback")
    require(enriched[2].project_id=="","missing mapping remains empty")
    for c in chains {
        _, saved, e:=iface.taskchain_save_chain(&task_repo,c);check(e);require(saved,"save chain")
    }
    snap:=feed(&h,headers,"")
    require(len(snap.documents)==3 && snap.next_revision==snap.snapshot_revision && !snap.has_more,"snapshot revisions")
    for doc in snap.documents {
        if doc.chain_id=="chain_3" do require(doc.project_id=="project_3" && doc.status=="archived","snapshot retains archived project mapping")
    }
    require(sql.exec(&conn,"UPDATE task_chains SET title='fresh-title' WHERE chain_id='chain_3';"),"upsert edit")
    fresh:=feed(&h,headers,fmt.tprintf("after_revision=%d",snap.next_revision))
    require(len(fresh.documents)==1 && fresh.documents[0].operation=="upsert" &&
        fresh.documents[0].title=="fresh-title" && fresh.documents[0].project_id=="project_3","nonempty upsert retains fresh content and project")
    revision:=fresh.next_revision
    delta:=feed(&h,headers,fmt.tprintf("after_revision=%d",revision))
    require(len(delta.documents)==0 && delta.next_revision==revision && delta.snapshot_revision==revision && !delta.has_more,"empty delta keeps cursor")
    // Tombstone-only deltas must emit every deletion and advance the watermark.
    require(sql.exec(&conn,"DELETE FROM task_chains WHERE chain_id='missing';"),"delete chain")
    tomb:=feed(&h,headers,fmt.tprintf("after_revision=%d",revision))
    require(len(tomb.documents)==1 && tomb.documents[0].operation=="delete" && tomb.documents[0].chain_id=="missing","tombstone retained")
    require(tomb.next_revision>revision && tomb.next_revision==tomb.snapshot_revision && !tomb.has_more,"tombstone cursor")
    // A vanished upsert is also a delete; pagination cannot drop the pending tombstone.
    after_delete:=tomb.next_revision
    require(sql.exec(&conn,"UPDATE task_chains SET title='changed' WHERE chain_id='chain_1';"),"edit")
    require(sql.exec(&conn,"DELETE FROM task_chains WHERE chain_id='chain_1';"),"delete after edit")
    page:=feed(&h,headers,fmt.tprintf("after_revision=%d&limit=1",after_delete))
    require(len(page.documents)==1 && page.documents[0].operation=="delete" && page.has_more,"vanished upsert and has_more")
    page2:=feed(&h,headers,fmt.tprintf("after_revision=%d&limit=1",page.next_revision))
    require(len(page2.documents)==1 && page2.documents[0].operation=="delete" && !page2.has_more && page2.next_revision==page2.snapshot_revision,"last tombstone page")
    fmt.println("api-fetch-dedup backend: projection equivalence, owner isolation, 200 boundary, coordinator fallback, empty snapshot/delta, tombstones and pagination PASS")
}
