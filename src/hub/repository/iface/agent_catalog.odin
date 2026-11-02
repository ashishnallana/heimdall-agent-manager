package iface

import domain "odin_test:hub/domain"

// Stable owner-scoped keyset paging, separate from legacy timestamp cursors.
Agent_Catalog_Query :: struct {owner:domain.User_ID,after_created,after_id,state,agent_id,bridge_id:string,limit:int}
Agent_Catalog_Ref :: struct {id,created_at:string}
Agent_Catalog_Page_Proc :: proc(ctx:rawptr,query:Agent_Catalog_Query)->([]Agent_Catalog_Ref,domain.Domain_Error)
