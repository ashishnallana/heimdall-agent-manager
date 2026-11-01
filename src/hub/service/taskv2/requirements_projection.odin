package taskv2

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

// This bounded public projection contains only requirement prose (already
// sealed), public audit identity, and acknowledgement metadata. It is shared
// by native clients and the MCP read projection.
requirements_projection_json :: proc(repo: ^iface.Taskchain_Repository, task: domain.Task, include_history := true) -> (string, domain.Domain_Error) {
    events, err := iface.taskchain_list_events_by_task(repo,task.task_id,task.owner_user_id)
    if err.code!=.None do return "",err
    leases,lerr:=iface.taskchain_list_leases_by_task(repo,task.task_id)
    if lerr.code!=.None do return "",lerr
    state:=requirements_state(events)
    submitted:=requirements_submission(events,task.attempt_no)
    out:=json_begin()
    json_int(&out,"revision",state.revision)
    json_int(&out,"submitted_revision",submitted.revision)
    json_str(&out,"submitted_head",submitted.head)
    json_bool(&out,"checkpoint_required",task.state==.In_Review && submitted.revision!=state.revision)
    ack:=strings.builder_make(context.temp_allocator)
    strings.write_byte(&ack,'[')
    for lease,i in leases {
        if i>0 do strings.write_byte(&ack,',')
        item:=json_begin()
        read:=requirements_lease_revision(events,lease.lease_id,EV_REQUIREMENTS_ACKNOWLEDGED)
        json_str(&item,"lease_id",lease.lease_id)
        json_str(&item,"holder_instance_id",lease.holder_instance_id)
        json_int(&item,"revision",read)
        json_bool(&item,"pending",state.revision>1 && read!=state.revision)
        strings.write_string(&ack,json_end(&item))
    }
    strings.write_byte(&ack,']')
    json_raw(&out,"acknowledgements",strings.to_string(ack))
    history:=strings.builder_make(context.temp_allocator)
    count:=0
    truncated:=false
    for i:=len(events)-1;i>=0;i-=1 {
        if !include_history do break
        event:=events[i]
        if event.kind!=EV_REQUIREMENTS_CHANGED do continue
        if count>=10 {truncated=true;break}
        before,_:=raw_object_field(event.payload_json,"before")
        after,_:=raw_object_field(event.payload_json,"after")
        entry:=strings.builder_make(context.temp_allocator)
        fmt.sbprintf(&entry,"Revision %d — %s %s — %d\nReason: %s\n",
            jsonx.extract_int(event.payload_json,"revision",1,true),event.actor_kind,event.actor_id,event.ts_ms,
            jsonx.extract_string(event.payload_json,"reason","",true,context.temp_allocator))
        for snapshot,j in ([]string{before,after}) {
            fmt.sbprintf(&entry,"%s goal: %s\n","Before" if j==0 else "After",jsonx.extract_string(snapshot,"goal","",true,context.temp_allocator))
            for item in jsonx.extract_string_array(snapshot,"acceptance",true) do fmt.sbprintf(&entry,"- %s\n",item)
        }
        fmt.sbprintf(&entry,"History event: #%d\n\n",event.event_id)
        text:=strings.to_string(entry)
        if len(strings.to_string(history))+len(text)>64*1024 {truncated=true;break}
        strings.write_string(&history,text)
        count+=1
    }
    json_str(&out,"history",strings.to_string(history))
    json_bool(&out,"history_truncated",truncated)
    return json_end(&out),{}
}
