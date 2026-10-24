package iface

import domain "odin_test:hub/domain"

Action_Save_Proc :: proc(ctx: rawptr, action: domain.Action) -> (domain.Action, bool, domain.Domain_Error)
Action_Get_Proc :: proc(ctx: rawptr, id: domain.Action_ID) -> (domain.Action, bool, domain.Domain_Error)
Action_Delete_Proc :: proc(ctx: rawptr, id: domain.Action_ID) -> (bool, domain.Domain_Error)
Action_List_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Action, domain.Domain_Error)
Action_List_By_Instance_Proc :: proc(ctx: rawptr, instance_id: domain.Agent_Instance_ID) -> ([]domain.Action, domain.Domain_Error)
Action_List_By_Bridge_Proc :: proc(ctx: rawptr, bridge_id: domain.Bridge_ID) -> ([]domain.Action, domain.Domain_Error)
Action_CAS_Lease_Proc :: proc(ctx: rawptr, id: domain.Action_ID, leased_at: string, now: string) -> (bool, domain.Domain_Error)
Action_Max_Updated_Proc :: proc(ctx: rawptr, bridge_id: domain.Bridge_ID) -> (string, domain.Domain_Error)

Action_Repository :: struct {
    ctx: rawptr,
    revision: proc(ctx: rawptr) -> (i64, domain.Domain_Error),
    snapshot: proc(ctx: rawptr, bridge_id: domain.Bridge_ID, known_revision: i64) -> (i64, []domain.Action, bool, domain.Domain_Error),
	save: Action_Save_Proc,
	get: Action_Get_Proc,
	delete_action: Action_Delete_Proc,
	delete_prompt: Action_Delete_Proc, // backward compatibility alias
	list: Action_List_Proc,
	list_by_instance: Action_List_By_Instance_Proc,
	list_by_bridge: Action_List_By_Bridge_Proc,
	cas_lease: Action_CAS_Lease_Proc,
	max_updated_at_for_bridge: Action_Max_Updated_Proc,
}


Scheduled_Prompt_Repository :: Action_Repository

