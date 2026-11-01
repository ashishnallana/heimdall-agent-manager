package iface

import domain "odin_test:hub/domain"

Resource_Page_Query :: struct {kind,owner,after_created,after_id,status,type,agent_id,project_id,bridge_id,template_id,scope_type,target_id,chain_id,issue_id:string,limit:int}
Resource_Ref :: struct {id,created_at:string}
Resource_Page_Proc :: proc(ctx:rawptr,q:Resource_Page_Query)->([]Resource_Ref,domain.Domain_Error)
