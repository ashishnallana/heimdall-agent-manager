package main

import httpc "odin_test:lib/httpc"

// ctl_task_fetch_request is the user-mode `tasks fetch` route. The ref carries
// `:`, `/`, `#` and `@` (facet:t:1:output, #evt_1, src/a.odin@HEAD), so it
// travels as a query value, encoded by httpc.
ctl_task_fetch_request :: proc(chain_id, task_id, ref: string) -> Ctl_Request {
	query := make([]httpc.Query_Param, 1, context.temp_allocator)
	query[0] = {"ref", ref}
	return {method = .GET, path = ctl_api("task-chains", chain_id, "tasks", task_id, "fetch"), query = query}
}
