// Heartbeat instance inventory (plan T2): what a bridge_heartbeat says about the
// Bridge's instances is applied ONLY when it is provably complete.
//
// Absence reconciliation (reconcile_bridge_heartbeat, runtime_reconcile_digest) turns
// "not listed" into "unreachable", so it must never run on an inventory the Hub could
// not read. The decoder therefore distinguishes three cases instead of collapsing
// them all into "empty":
//
//   - Complete: every inventory member that is present parsed with the right types.
//     An empty complete inventory is authoritative: the Bridge runs nothing.
//   - Absent: the frame carries none of active_instance_ids / instances / digest.
//     Nothing is known about the instances, so nothing about them changes.
//   - Malformed: the frame is not exactly one JSON object (truncated, trailing bytes,
//     invalid UTF-8), a present member has the wrong type, an entry lacks its id, or
//     the legacy digest alias and instances disagree. The whole inventory is rejected:
//     no status repair and no absence mutation.
//
// Absent and malformed beats are counted in heimdall_bridge_frames_rejected_total
// under a fixed reason. Bridge liveness is refreshed by the heartbeat arm before the
// inventory is looked at, so a rejected inventory never ages the Bridge itself out.
package http

import "base:runtime"
import "core:encoding/json"
import "core:mem/virtual"
import "core:unicode/utf8"
import agent_service "odin_test:hub/service/agent"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import domain "odin_test:hub/domain"
import metrics "odin_test:lib/metrics"
import project_service "odin_test:hub/service/project"
import shell_session_svc "odin_test:hub/service/shell_session"

Bridge_Heartbeat_Inventory_State :: enum {
	Malformed,
	Absent,
	Complete,
}

// Bounded bridge_frames_rejected{reason} labels.
HEARTBEAT_INVENTORY_REJECT_ABSENT    :: "inventory_absent"
HEARTBEAT_INVENTORY_REJECT_MALFORMED :: "inventory_malformed"
HEARTBEAT_INVENTORY_REJECT_CONFLICT  :: "inventory_digest_conflict"

// Everything the decoder allocates (parse tree, active_ids, reports and the strings
// they borrow) lives in its own arena: core's parse_value does not free the partial
// tree of a truncated frame (and frees some of it through context.allocator), so
// per-value destroys would leak or bad-free exactly the rejects.
Bridge_Heartbeat_Inventory :: struct {
	state:          Bridge_Heartbeat_Inventory_State,
	reason:         string, // static rejection label; "" when Complete
	active_ids:     []string,
	reports:        []Bridge_Agent_Status_Report,
	arena:          virtual.Arena,
	arena_ok:       bool,
}

bridge_heartbeat_inventory_destroy :: proc(inv: ^Bridge_Heartbeat_Inventory) {
	if inv.arena_ok do virtual.arena_destroy(&inv.arena)
	inv^ = {}
}

// inv must be zero (or destroyed); the caller destroys it whatever the state.
bridge_decode_heartbeat_inventory :: proc(inv: ^Bridge_Heartbeat_Inventory, text: string) {
	inv.state = .Malformed
	inv.reason = HEARTBEAT_INVENTORY_REJECT_MALFORMED
	// Core's string decoder assumes valid UTF-8, and its convenience parsers accept
	// trailing bytes, so parse exactly one value and require EOF after it.
	if !utf8.valid_string(text) do return
	inv.arena_ok = virtual.arena_init_growing(&inv.arena) == nil
	if !inv.arena_ok do return
	allocator := virtual.arena_allocator(&inv.arena)
	// parse_value's error paths free through context.allocator, not the parser's.
	context.allocator = allocator
	parser := json.make_parser_from_string(text, .JSON, true, allocator)
	value, parse_err := json.parse_value(&parser)
	object, is_object := value.(json.Object)
	if parse_err != nil || !is_object || parser.curr_token.kind != .EOF do return

	active_value, active_present := object["active_instance_ids"]
	instances_value, instances_present := object["instances"]
	digest_value, digest_present := object["digest"]
	if !active_present && !instances_present && !digest_present {
		inv.state = .Absent
		inv.reason = HEARTBEAT_INVENTORY_REJECT_ABSENT
		return
	}
	if active_present {
		ids, ok := heartbeat_inventory_ids(active_value, allocator)
		inv.active_ids = ids
		if !ok do return
	}
	if instances_present {
		reports, ok := heartbeat_inventory_reports(instances_value, allocator)
		inv.reports = reports
		if !ok do return
	}
	if digest_present {
		// Legacy alias (D6): no current Bridge sends it, but an old one may. The same
		// presence rules apply, and a frame carrying both must say the same thing.
		digest, ok := heartbeat_inventory_reports(digest_value, allocator)
		if !ok do return
		if instances_present {
			if !heartbeat_inventory_reports_equal(inv.reports, digest) {
				inv.reason = HEARTBEAT_INVENTORY_REJECT_CONFLICT
				return
			}
		} else {
			inv.reports = digest
		}
	}
	inv.state = .Complete
	inv.reason = ""
}

@(private = "file")
heartbeat_inventory_ids :: proc(value: json.Value, allocator: runtime.Allocator) -> ([]string, bool) {
	array, is_array := value.(json.Array)
	if !is_array do return nil, false
	ids := make([]string, len(array), allocator)
	for element, i in array {
		id, is_string := element.(json.String)
		if !is_string || id == "" do return ids, false
		ids[i] = string(id)
	}
	return ids, true
}

@(private = "file")
heartbeat_inventory_reports :: proc(value: json.Value, allocator: runtime.Allocator) -> ([]Bridge_Agent_Status_Report, bool) {
	array, is_array := value.(json.Array)
	if !is_array do return nil, false
	reports := make([]Bridge_Agent_Status_Report, len(array), allocator)
	for element, i in array {
		entry, is_object := element.(json.Object)
		if !is_object do return reports, false
		id, id_ok := entry["agent_instance_id"].(json.String)
		if !id_ok || id == "" do return reports, false
		report := Bridge_Agent_Status_Report{agent_instance_id = string(id)}
		// Optional members default to zero values, but a present one must be typed.
		if seq_value, present := entry["state_seq"]; present {
			seq, seq_ok := seq_value.(json.Integer)
			if !seq_ok do return reports, false
			report.state_seq = int(seq)
		}
		ok := true
		report.runtime_status, ok = heartbeat_inventory_optional_string(entry, "runtime_status")
		if !ok do return reports, false
		report.activity_status, ok = heartbeat_inventory_optional_string(entry, "activity_status")
		if !ok do return reports, false
		report.launch_epoch, ok = heartbeat_inventory_optional_string(entry, "launch_epoch")
		if !ok do return reports, false
		reports[i] = report
	}
	return reports, true
}

@(private = "file")
heartbeat_inventory_optional_string :: proc(entry: json.Object, key: string) -> (string, bool) {
	value, present := entry[key]
	if !present do return "", true
	s, is_string := value.(json.String)
	return string(s), is_string
}

@(private = "file")
heartbeat_inventory_reports_equal :: proc(a, b: []Bridge_Agent_Status_Report) -> bool {
	if len(a) != len(b) do return false
	for i in 0 ..< len(a) {
		if a[i] != b[i] do return false
	}
	return true
}

// The positive liveness set. A non-empty active_instance_ids is authoritative; an
// empty or absent one falls back to the reports, but ONLY to those whose status is
// active: terminal rows recur so a dropped terminal push is repaired, and must never
// refresh liveness. The returned slice is the caller's; its strings borrow from inv.
bridge_heartbeat_inventory_active_ids :: proc(inv: ^Bridge_Heartbeat_Inventory, allocator := context.allocator) -> []string {
	if len(inv.active_ids) > 0 {
		out := make([]string, len(inv.active_ids), allocator)
		copy(out, inv.active_ids)
		return out
	}
	out := make([dynamic]string, 0, len(inv.reports), allocator)
	for report in inv.reports {
		if agent_service.runtime_expected_active(report.runtime_status) do append(&out, report.agent_instance_id)
	}
	return out[:]
}

// Repairs durable and registry status from every report, active or terminal. Epoch
// and state_seq fencing live in apply_bridge_status_report / the registry.
bridge_apply_heartbeat_reports :: proc(h: ^Bridge_Handlers, bridge_id: string, generation: int, reports: []Bridge_Agent_Status_Report) {
	if h == nil do return
	current_generation := generation
	if current_generation == 0 do current_generation = project_service.bridge_runtime_registry_generation(h.bridge_runtime_registry, bridge_id)
	for report in reports {
		if h.agents == nil {
			_ = bridge_runtime_service.runtime_apply_state_report(h.bridge_runtime_registry, bridge_id, current_generation, report.agent_instance_id, report.state_seq, report.runtime_status, report.activity_status, "")
			continue
		}
		status_moved := false
		if inst, applied, _ := bridge_apply_validated_status(h, bridge_id, current_generation, report.agent_instance_id, report.state_seq, report.runtime_status, report.activity_status, report.launch_epoch, changed = &status_moved); applied {
			// A beat that only refreshed last_seen_at is not news (REQ-2).
			if status_moved do publish_instance_changed(h.event_bus, inst, "status_changed")
			domain.agent_instance_destroy(&inst)
		}
	}
}

// Everything a bridge_heartbeat does to instance state: inventory repair, absence
// reconciliation, superseded detection and the opportunistic stale reap. Returns the
// unreachable count and superseded ids (caller owns) for the ack. A non-complete
// inventory leaves every instance of this Bridge untouched and reports no superseded
// ids; the ack still goes out so schedule freshness is unaffected.
bridge_reconcile_heartbeat_inventory :: proc(h: ^Bridge_Handlers, bridge_id: string, generation: int, text: string) -> (reconciled: int, superseded: []string, state: Bridge_Heartbeat_Inventory_State) {
	inventory: Bridge_Heartbeat_Inventory
	bridge_decode_heartbeat_inventory(&inventory, text)
	defer bridge_heartbeat_inventory_destroy(&inventory)
	state = inventory.state
	if state == .Complete {
		bridge_apply_heartbeat_reports(h, bridge_id, generation, inventory.reports)
	} else {
		metrics.counter_inc(metrics.with(project_service.fleet_metrics.bridge_frames_rejected, inventory.reason))
	}
	if h.agents != nil do agent_service.reconcile_instance_reconfigurations(h.agents, bridge_id)
	if state == .Complete {
		active := bridge_heartbeat_inventory_active_ids(&inventory)
		defer delete(active)
		reconciled = bridge_runtime_service.runtime_reconcile_digest(h.bridge_runtime_registry, bridge_id, generation, active)
		if h.agents != nil {
			// H7 cross-bridge reap: any instance this bridge reports active whose
			// canonical bridge_id is now a DIFFERENT bridge has been relaunched
			// elsewhere. Tell this bridge to invalidate those instances' local tokens
			// (via the ack) so the stale old ham-wrapper self-terminates.
			superseded = agent_service.detect_superseded_instances(h.agents, bridge_id, active)
			// The per-instance unreachability signal: the bridge is still connected and
			// reporting, and these instances are simply no longer among the ones it
			// reports active. Their foreground runs get the same treatment as on a
			// bridge-wide disconnect — converted, not killed — deliberately, so there
			// is no "which signal fired?" branch whose wrong answer destroys work.
			gone := agent_service.reconcile_bridge_heartbeat(h.agents, bridge_id, active)
			defer domain.agent_instances_destroy(gone)
			agent_service.notify_instances_terminal(h.agents, gone)
			metrics.counter_add(project_service.fleet_metrics.agent_instances_reconciled_gone, u64(len(gone)))
			for inst in gone {
				publish_instance_changed(h.event_bus, inst, "status_changed")
				shell_session_svc.shell_session_background_runs_for_agent(h.shell_sessions, string(inst.owner_user_id), inst.agent_instance_id)
				reconciled += 1
			}
		}
	}
	// Opportunistic time-based reap: catches instances stranded by a disconnect the
	// hub never observed (hub restart with persisted DB, or a lost WS close). It is
	// driven by last_seen_at age, not by this beat's inventory, so it runs either way:
	// one unreadable beat cannot age an instance past BRIDGE_INSTANCE_STALE_MS, while a
	// Bridge that never sends a readable inventory again does not keep zombies forever.
	if h.agents != nil {
		reaped := agent_service.reap_stale_instances(h.agents, BRIDGE_INSTANCE_STALE_MS)
		agent_service.notify_instances_terminal(h.agents, reaped)
		for inst in reaped {
			shell_session_svc.shell_session_background_runs_for_agent(h.shell_sessions, string(inst.owner_user_id), inst.agent_instance_id)
			publish_instance_changed(h.event_bus, inst, "status_changed")
			reconciled += 1
		}
		domain.agent_instances_destroy(reaped)
	}
	return
}
