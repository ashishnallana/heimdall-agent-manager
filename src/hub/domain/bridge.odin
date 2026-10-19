package domain

Bridge_Status :: enum {
	Online,
	Offline,
	Revoked,
}


Bridge :: struct {
	bridge_id: string,
	owner_user_id: User_ID,
	label: string,
	label_is_user_customized: bool,
	machine_hostname: string,
	machine_os: string,
	machine_arch: string,
	capabilities_json: string,
	hub_url: string,
	status: Bridge_Status,
	bridge_token_hash: string,
	created_at: string,
	updated_at: string,
	last_seen_at: string,
	revoked_at: string,
	version: string,
	commit_sha: string,
	build_timestamp: string,
	update_status: string,
	update_message: string,
	update_progress: int,
	update_error: string,
	telemetry_enabled: string,
	// vault_status is the bridge's SELF-REPORTED vault tri-state (REQ-BVS-1):
	// "unlocked" | "locked", or "" for a bridge that has never reported
	// one (an older build, or one not yet heard from since the hub started).
	//
	// IT IS A UX AND LIVENESS INDICATOR ONLY. Nothing may gate on it. The
	// authoritative authorization check is the bridge-side enc_spec guard, which runs
	// on the machine that actually holds the key; a value that travelled over the wire
	// from the party being authorized cannot be the basis for authorizing it.
	vault_status: string,
	// enrollment_pending_until is "" for an ENROLLED bridge and the RFC 3339 deadline
	// for one that is still PENDING (REQ-EA-1): approved, but its vault key not yet
	// delivered. Unlike vault_status this IS authoritative and gates use: it is set
	// and cleared only by the hub itself — cleared when the hub relays an unseal and
	// observes ok:true (REQ-EA-2), never from a bridge self-report — and a pending
	// bridge that misses the deadline is rolled back (REQ-EA-3).
	enrollment_pending_until: string,
}

// bridge_is_pending reports whether a bridge is still awaiting its vault key and
// therefore does not yet count as enrolled (REQ-EA-1).
bridge_is_pending :: proc(b: Bridge) -> bool {
	return b.enrollment_pending_until != ""
}

// bridge_destroy frees every heap string on a Bridge read from a repository.
//
// It exists because the REQ-SHELL-14 sweep reads bridges on the reaper's
// process-scoped thread, which has no per-request arena: anything allocated there
// stays allocated. The repository's row reader hands back an owned string for every text
// column, so a caller that wanted one field and dropped the value leaked all the rest,
// every sweep, forever. Mirrors domain.agent_instance_destroy, which exists for the same
// reason on the same thread.
bridge_destroy :: proc(b: ^Bridge) {
	if b == nil do return
	if len(b.bridge_id) > 0 do delete(b.bridge_id)
	if len(string(b.owner_user_id)) > 0 do delete(string(b.owner_user_id))
	if len(b.label) > 0 do delete(b.label)
	if len(b.machine_hostname) > 0 do delete(b.machine_hostname)
	if len(b.machine_os) > 0 do delete(b.machine_os)
	if len(b.machine_arch) > 0 do delete(b.machine_arch)
	if len(b.capabilities_json) > 0 do delete(b.capabilities_json)
	if len(b.hub_url) > 0 do delete(b.hub_url)
	if len(b.bridge_token_hash) > 0 do delete(b.bridge_token_hash)
	if len(b.created_at) > 0 do delete(b.created_at)
	if len(b.updated_at) > 0 do delete(b.updated_at)
	if len(b.last_seen_at) > 0 do delete(b.last_seen_at)
	if len(b.revoked_at) > 0 do delete(b.revoked_at)
	if len(b.version) > 0 do delete(b.version)
	if len(b.commit_sha) > 0 do delete(b.commit_sha)
	if len(b.build_timestamp) > 0 do delete(b.build_timestamp)
	if len(b.update_status) > 0 do delete(b.update_status)
	if len(b.update_message) > 0 do delete(b.update_message)
	if len(b.update_error) > 0 do delete(b.update_error)
	if len(b.telemetry_enabled) > 0 do delete(b.telemetry_enabled)
	if len(b.vault_status) > 0 do delete(b.vault_status)
	if len(b.enrollment_pending_until) > 0 do delete(b.enrollment_pending_until)
	b^ = Bridge{}
}


bridge_status_string :: proc(status: Bridge_Status) -> string {
	switch status {
	case .Online: return "online"
	case .Offline: return "offline"
	case .Revoked: return "revoked"
	}
	return "offline"
}
