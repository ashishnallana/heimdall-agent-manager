package mcp

import "core:strings"

// Native explanatory strings can embed encrypted or legacy human prose. Keep
// the operation result as bounded stable codes; private detail stays in get.
control_outcome_codes :: proc(values:[]string,actions:bool)->[]string {
	out:=make([dynamic]string,context.temp_allocator)
	for value in values {
		code:="native_blocker"
		if actions {
			code="events_reevaluated"
			if strings.has_prefix(value,"state:") do code="state_changed"
			if strings.has_prefix(value,"block") do code="block_changed"
			if strings.has_prefix(value,"dispatched:") do code="lease_dispatched"
			if strings.contains(value,"merge") do code="merge_requeued"
		} else {
			if strings.contains(value,"draft") do code="draft"
			if strings.contains(value,"cancelled") do code="cancelled"
			if strings.contains(value,"lease") && strings.contains(value,"live") do code="lease_active"
			if strings.has_prefix(value,"task is held") do code="held"
			if strings.contains(value,"review") do code="review_pending"
			if strings.contains(value,"fleet") do code="fleet_capacity"
			if strings.contains(value,"bridge") && strings.contains(value,"offline") do code="bridge_offline"
			if strings.contains(value,"depend") do code="dependency_pending"
			if strings.contains(value,"merge") do code="merge_pending"
		}
		seen:=false;for item in out do if item==code do seen=true
		if !seen && len(out)<20 do append(&out,code)
	}
	return out[:]
}
