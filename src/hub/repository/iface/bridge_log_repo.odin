package iface

import domain "odin_test:hub/domain"

// Bridge error events (bridge_log relay). Writes come from ONE background
// writer thread (service/bridge_log); reads from the owner API and the reaper.
Bridge_Log_Insert_Batch_Proc :: proc(ctx: rawptr, events: []domain.Bridge_Log_Event) -> (int, domain.Domain_Error)
// cap_bridge deletes everything but the newest `keep` rows of one bridge and
// returns how many rows went.
Bridge_Log_Cap_Bridge_Proc :: proc(ctx: rawptr, bridge_id: string, keep: int) -> (int, domain.Domain_Error)
Bridge_Log_Prune_Before_Proc :: proc(ctx: rawptr, received_at_before_ms: i64) -> (int, domain.Domain_Error)
// list_by_bridge returns newest first; before_id <= 0 means "from the newest".
Bridge_Log_List_By_Bridge_Proc :: proc(ctx: rawptr, bridge_id: string, limit: int, before_id: i64) -> ([]domain.Bridge_Log_Event, domain.Domain_Error)
Bridge_Log_Delete_By_Bridge_Proc :: proc(ctx: rawptr, bridge_id: string) -> (int, domain.Domain_Error)
Bridge_Log_Count_By_Bridge_Proc :: proc(ctx: rawptr, bridge_id: string) -> (int, domain.Domain_Error)

Bridge_Log_Repository :: struct {
	ctx:              rawptr,
	insert_batch:     Bridge_Log_Insert_Batch_Proc,
	cap_bridge:       Bridge_Log_Cap_Bridge_Proc,
	prune_before:     Bridge_Log_Prune_Before_Proc,
	list_by_bridge:   Bridge_Log_List_By_Bridge_Proc,
	delete_by_bridge: Bridge_Log_Delete_By_Bridge_Proc,
	count_by_bridge:  Bridge_Log_Count_By_Bridge_Proc,
}

@(private = "file")
not_configured :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, "bridge log repository is not configured")
}

bridge_log_insert_batch :: proc(repo: ^Bridge_Log_Repository, events: []domain.Bridge_Log_Event) -> (int, domain.Domain_Error) {
	if repo == nil || repo.insert_batch == nil do return 0, not_configured()
	return repo.insert_batch(repo.ctx, events)
}

bridge_log_cap_bridge :: proc(repo: ^Bridge_Log_Repository, bridge_id: string, keep: int) -> (int, domain.Domain_Error) {
	if repo == nil || repo.cap_bridge == nil do return 0, not_configured()
	return repo.cap_bridge(repo.ctx, bridge_id, keep)
}

bridge_log_prune_before :: proc(repo: ^Bridge_Log_Repository, received_at_before_ms: i64) -> (int, domain.Domain_Error) {
	if repo == nil || repo.prune_before == nil do return 0, not_configured()
	return repo.prune_before(repo.ctx, received_at_before_ms)
}

bridge_log_list_by_bridge :: proc(repo: ^Bridge_Log_Repository, bridge_id: string, limit: int, before_id: i64) -> ([]domain.Bridge_Log_Event, domain.Domain_Error) {
	if repo == nil || repo.list_by_bridge == nil do return nil, not_configured()
	return repo.list_by_bridge(repo.ctx, bridge_id, limit, before_id)
}

bridge_log_delete_by_bridge :: proc(repo: ^Bridge_Log_Repository, bridge_id: string) -> (int, domain.Domain_Error) {
	if repo == nil || repo.delete_by_bridge == nil do return 0, not_configured()
	return repo.delete_by_bridge(repo.ctx, bridge_id)
}

bridge_log_count_by_bridge :: proc(repo: ^Bridge_Log_Repository, bridge_id: string) -> (int, domain.Domain_Error) {
	if repo == nil || repo.count_by_bridge == nil do return 0, not_configured()
	return repo.count_by_bridge(repo.ctx, bridge_id)
}
