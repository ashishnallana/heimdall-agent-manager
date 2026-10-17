package main

// Agent API v2 (see docs/agent-api-redesign.md).
//
// One flat `agent.<domain>.<verb>` method namespace, routed by a SINGLE pure
// table (`bridge_agent_route`) instead of the old three near-identical relay
// procs (agent-actions envelope / admin raw-REST / instance-lifecycle raw-REST).
//
// Each method resolves to a Bridge_Agent_Route describing HOW the bridge fulfils
// it:
//   .Envelope  POST /api/v1/agent-actions/... with {method, agent_instance_id,
//              params} (the hub reads the caller from the instance token).
//   .Raw       direct REST call (method+path) with the instance token header;
//              params become the body for writes, query already baked into path.
//   .Local     served by the bridge itself with NO hub round-trip (e.g. the
//              bridge.list self row).
//
// Auth invariant (unchanged): agent token in -> bridge authenticates + strips ->
// forwards to hub with the bridge token + X-Heimdall-Instance-Token. Agents
// never see a hub URL or hub token.

import "core:strconv"
import "core:strings"

Bridge_Agent_Route_Kind :: enum {
	Unknown,     // method not allowed / not found
	Envelope,    // agent-actions envelope POST
	Raw,         // raw REST relay with instance token
	Local,       // bridge-served, no hub call
	Bad_Request, // method known but required params missing -> return `message`
}

Bridge_Agent_Route :: struct {
	kind:        Bridge_Agent_Route_Kind,
	http_method: string, // for .Raw
	path:        string, // for .Raw / .Envelope (envelope path is fixed per method)
	// local_op names the bridge-local handler for .Local routes.
	local_op:    string,
	// send_body: for .Raw, whether params should be forwarded as the request body.
	send_body:   bool,
	// message: for .Bad_Request, the specific "which params are needed" error.
	message:     string,
}

// bridge_agent_route is the ONE place that maps a v2 method + params to its
// fulfilment. Pure (no I/O) so it is unit-testable. Returns .Unknown for any
// method not in the allowlist. Caller owns any concatenated path string.
bridge_agent_route :: proc(method, params: string) -> Bridge_Agent_Route {
	switch method {
	// ---- bridge discovery -------------------------------------------------
	case "agent.bridge.list":
		// scope hub|configured|all (default all) decided bridge-side; the local
		// merge is done in the handler, so this is a Local op.
		return Bridge_Agent_Route{kind = .Local, local_op = "bridge.list"}
	case "agent.bridge.providers":
		bridge_id := bridge_local_extract_json_string(params, "bridge_id", "")
		if strings.trim_space(bridge_id) != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = strings.concatenate({"/api/v1/bridges/", bridge_id, "/providers"})}
		}
		// no bridge_id => list bridges (each carries its provider matrix)
		return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = "/api/v1/bridges"}

	// ---- agents: durable identities --------------------------------------
	case "agent.agents.list":
		return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = "/api/v1/agents"}
	case "agent.agents.create":
		return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = "/api/v1/agents", send_body = true}

	// ---- agents: templates ------------------------------------------------
	case "agent.agents.template_list":
		return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = "/api/v1/templates"}
	case "agent.agents.template_create":
		return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = "/api/v1/templates", send_body = true}

	// ---- agents: instances ------------------------------------------------
	case "agent.agents.instance_list":
		// live filter -> live envelope; else durable instance list (raw GET).
		if bridge_agent_params_bool(params, "live") {
			return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/agents/live"}
		}
		agent_id := bridge_local_extract_json_string(params, "agent_id", "")
		if strings.trim_space(agent_id) != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = strings.concatenate({"/api/v1/agent-instances?agent_id=", agent_id})}
		}
		return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = "/api/v1/agent-instances"}
	case "agent.agents.new_instance":
		return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = "/api/v1/agent-instances", send_body = true}
	case "agent.agents.instance_start":
		if id := bridge_agent_instance_id(params); id != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = strings.concatenate({"/api/v1/agent-instances/", id, "/start"})}
		}
	case "agent.agents.instance_restart":
		if id := bridge_agent_instance_id(params); id != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = strings.concatenate({"/api/v1/agent-instances/", id, "/restart"})}
		}
	case "agent.agents.instance_stop":
		if id := bridge_agent_instance_id(params); id != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = strings.concatenate({"/api/v1/agent-instances/", id, "/stop"}), send_body = true}
		}

	// ---- task-chain -------------------------------------------------------
	case "agent.task_chain.create":
		return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = "/api/v1/task-chains", send_body = true}
	case "agent.task_chain.list":
		// coordinated_by_me -> chains this agent coordinates (hub defaults the
		// coordinator to the caller's own instance from the instance token).
		if bridge_agent_params_bool(params, "coordinated_by_me") {
			return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = "/api/v1/task-chains?coordinated_by="}
		}
		if bridge_agent_params_bool(params, "pinned") {
			return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = "/api/v1/task-chains?pinned=1"}
		}
		if pid := bridge_local_extract_json_string(params, "project_id", ""); strings.trim_space(pid) != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = strings.concatenate({"/api/v1/task-chains?project_id=", pid})}
		}
		return Bridge_Agent_Route{kind = .Raw, http_method = "GET", path = "/api/v1/task-chains"}
	case "agent.task_chain.show":
		// chain_id is optional: the hub defaults to the caller instance's own chain
		// and returns the full chain (incl. description). No context-snapshot fallback.
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/chain/show"}
	case "agent.task_chain.set_title":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/chain/set-title"}
	case "agent.task_chain.set_description":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/chain/set-description"}
	case "agent.task_chain.set_status":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/chain/set-status"}
	case "agent.task_chain.set_summary", "agent.chain.summary":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/chain/summary"}
	case "agent.task_chain.propose", "agent.chain.propose":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/chain/propose"}
	case "agent.task_chain.publish":
		// REQ-CLI-1: draft chains never promote and their tasks cannot be nudged, so a
		// coordinator agent must be able to publish the chain it built. The hub already
		// permits an instance token that is the chain coordinator (publish_chain) and
		// cascades Published to every task; this is purely the missing agent surface.
		// Needs chain_id — publish has no "your own chain" default hub-side.
		if cid := bridge_local_extract_json_string(params, "chain_id", ""); strings.trim_space(cid) != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = strings.concatenate({"/api/v1/task-chains/", cid, "/publish"})}
		}
		return Bridge_Agent_Route{kind = .Bad_Request, message = "task-chain publish requires a chain id: pass <chain-id> (or --chain <id>)"}
	case "agent.task_chain.pin":
		if cid := bridge_local_extract_json_string(params, "chain_id", ""); strings.trim_space(cid) != "" {
			return Bridge_Agent_Route{kind = .Raw, http_method = "POST", path = strings.concatenate({"/api/v1/task-chains/", cid, "/pin"}), send_body = true}
		}
		return Bridge_Agent_Route{kind = .Bad_Request, message = "task-chain pin requires a chain id: pass <chain-id> (or --chain <id>)"}
	// Task System v2: agent.task_chain.subscribe/unsubscribe were removed (the hub
	// answers 410 Gone for their routes); they are deliberately NOT routed here.

	// ---- task -------------------------------------------------------------
	case "agent.task.list":
		// chain_id is optional: the hub defaults to the caller instance's chain.
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/tasks/list"}
	case "agent.task.show":
		// slim task detail by task_id ALONE — the hub derives the chain from the
		// task (task ids are globally unique). No chain_id required.
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/tasks/show"}
	case "agent.task.comments":
		// newest N comments by task_id alone (?last passed as a param). No chain_id.
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/tasks/comments"}
	case "agent.task.create":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/tasks/create"}
	case "agent.task.update":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/tasks/update"}
	case "agent.task.depend":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/tasks/depend"}
	case "agent.task.comment":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/tasks/comment"}
	// Task System v2: agent.task.status / set_current / vote / nudge / subscribe /
	// unsubscribe were removed (hub answers 410 Gone). Lease verbs (M1):
	case "agent.lease.next":
		// .Local (M2): the bridge adds params.vcs_base (git HEAD of the agent's
		// repo) and relays to lease/next (agent_taskv2_vcs.odin).
		return Bridge_Agent_Route{kind = .Local, local_op = "lease.next", path = "/api/v1/agent-actions/lease/next"}
	case "agent.lease.heartbeat":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/lease/heartbeat"}
	case "agent.lease.submit":
		// .Local (M2): adds params.vcs = {head, dirty, files} then relays.
		return Bridge_Agent_Route{kind = .Local, local_op = "lease.submit", path = "/api/v1/agent-actions/lease/submit"}
	case "agent.lease.handoff":
		return Bridge_Agent_Route{kind = .Local, local_op = "lease.handoff", path = "/api/v1/agent-actions/lease/handoff"}
	case "agent.lease.switch":
		// .Local: like lease.next, the response carries a pack → TASK.md + worktree.
		return Bridge_Agent_Route{kind = .Local, local_op = "lease.switch", path = "/api/v1/agent-actions/lease/switch"}
	case "agent.lease.block":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/lease/block"}
	case "agent.review.post":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/review/post"}
	case "agent.task.fetch":
		// {task_id, ref} with ref "#<event_id>" | "facet:<task>:<attempt>:<kind>".
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/task/fetch"}

	// ---- workflow (M3b) ---------------------------------------------------
	case "agent.workflow.templates", "agent.workflow.list":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/workflow/templates"}
	case "agent.workflow.define":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/workflow/define"}
	case "agent.workflow.run":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/workflow/run"}
	case "agent.workflow.status":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/workflow/status"}
	case "agent.workflow.output":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/workflow/output"}
	case "agent.workflow.retry":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/workflow/retry"}
	case "agent.workflow.cancel":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/workflow/cancel"}

	// ---- chat -------------------------------------------------------------
	case "agent.chat.send":
		// to == "user" -> send-to-user; else to is an agent-instance-id.
		to := strings.trim_space(bridge_local_extract_json_string(params, "to", ""))
		if to == "user" {
			return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/chat/send-to-user"}
		}
		if to != "" {
			return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/chat/send-to-agent"}
		}
		return Bridge_Agent_Route{kind = .Bad_Request, message = "chat send requires --to: `user` for the bound user, or an agent-instance-id"}
	case "agent.chat.read":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/chat/read"}

	// ---- instance-self / misc --------------------------------------------
	case "agent.context.get":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/context"}
	case "agent.conversation.set_title":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/conversation/set-title"}
	case "agent.memory.propose":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/memory/propose"}
	case "agent.memory.list":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/memory/list"}
	case "agent.memory.show":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/memory/show"}
	case "agent.memory.content":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/memory/content"}
	case "agent.search":
		// Global entity search (SEARCH-7): same owner scoping + hit shape as REST.
		// Local because the bridge relays it to the hub, then merges its decrypted
		// task-chain hits that the hub's ciphertext FTS cannot match (SRCH-2).
		return Bridge_Agent_Route{kind = .Local, local_op = "search"}
	case "agent.artifact.create":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/artifacts/create"}
	case "agent.artifact.list":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/artifacts/list"}
	case "agent.artifact.show":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/artifacts/show"}
	case "agent.artifact.content":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/artifacts/content"}

	// ---- cards ------------------------------------------------------------
	case "agent.cards.create":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/cards/create"}
	case "agent.cards.list":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/cards/list"}
	case "agent.cards.show":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/cards/show"}
	case "agent.cards.discard":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/cards/discard"}
	case "agent.cards.accept":
		return Bridge_Agent_Route{kind = .Envelope, path = "/api/v1/agent-actions/cards/accept"}

	// ---- shell sessions -------------------------------------------------------
	// agent.shell.wait is LOCAL, unlike every other agent.shell.* verb, which is a
	// REST call relayed to the hub. It has to be: it is the block that makes a
	// FOREGROUND run foreground, and the hub transport cannot carry a call that
	// lasts as long as the run (see shell_run_wait.odin). The bridge that owns the
	// process is the only party that can park on it without a hub round trip or a
	// poller.
	case "agent.shell.wait":
		return Bridge_Agent_Route{kind = .Local, local_op = "shell.wait"}

	// ---- vault commands (bridge-local vault key inspection) --------------------
	case "agent.vault.status":
		return Bridge_Agent_Route{kind = .Local, local_op = "vault.status"}
	case "agent.vault.get":
		return Bridge_Agent_Route{kind = .Local, local_op = "vault.get"}
	case "agent.vault.lock":
		return Bridge_Agent_Route{kind = .Local, local_op = "vault.lock"}
	case "agent.vault.reset":
		return Bridge_Agent_Route{kind = .Local, local_op = "vault.reset"}

	// ---- telemetry -------------------------------------------------------------
	case "agent.telemetry.agents_count":
		return Bridge_Agent_Route{kind = .Local, local_op = "telemetry.agents_count"}
	}
	return Bridge_Agent_Route{kind = .Unknown}
}

// bridge_agent_method_allowed reports whether a v2 method is dispatchable. This
// is a membership check on the METHOD name only (independent of params): a method
// like agent.chat.send is allowed even though its route needs a valid `to` in
// params (a missing/invalid `to` becomes a bad_request at dispatch, not a
// forbidden). The self/bridge-handled methods that never leave the bridge
// (start_success, activity, permission, rest.request) are also allowed.
bridge_agent_method_allowed :: proc(method: string) -> bool {
	switch method {
	case "agent.start_success", "agent.activity.report",
	     "agent.permission.request", "agent.permission.reply",
	     "agent.rest.request",
	     // discovery + agents
	     "agent.bridge.list", "agent.bridge.providers",
	     "agent.agents.list", "agent.agents.create",
	     "agent.agents.template_list", "agent.agents.template_create",
	     "agent.agents.instance_list", "agent.agents.new_instance",
	     "agent.agents.instance_start", "agent.agents.instance_restart",
	     "agent.agents.instance_stop",
	     // task-chain + task
	     "agent.task_chain.create", "agent.task_chain.list", "agent.task_chain.show", "agent.task_chain.set_title",
	     "agent.task_chain.set_description", "agent.task_chain.set_status",
	     "agent.task_chain.set_summary", "agent.chain.summary",
	     "agent.task_chain.propose", "agent.chain.propose",
	     "agent.task_chain.publish", "agent.task_chain.pin",
	     "agent.task.list", "agent.task.show", "agent.task.comments", "agent.task.create",
	     "agent.task.update", "agent.task.depend", "agent.task.comment", "agent.task.fetch",
	     "agent.lease.next", "agent.lease.heartbeat", "agent.lease.submit", "agent.lease.handoff",
	     "agent.lease.block", "agent.lease.switch", "agent.review.post",
	     "agent.workflow.templates", "agent.workflow.list", "agent.workflow.define",
	     "agent.workflow.run", "agent.workflow.status", "agent.workflow.output",
	     "agent.workflow.retry", "agent.workflow.cancel",
	     // chat + self/misc
	     "agent.chat.send", "agent.chat.read",
	     "agent.context.get", "agent.conversation.set_title",
	     "agent.memory.propose", "agent.memory.list", "agent.memory.show", "agent.memory.content",
	     "agent.search",
	     "agent.artifact.create", "agent.artifact.list", "agent.artifact.show",
	     "agent.artifact.content",
	     // cards
	     "agent.cards.create", "agent.cards.list", "agent.cards.show",
	     "agent.cards.discard", "agent.cards.accept",
	     // shell sessions (bridge-local block on a hub-created run)
	     "agent.shell.wait",
	     // vault commands (bridge-local)
	     "agent.vault.status", "agent.vault.get", "agent.vault.lock", "agent.vault.reset",
	     // telemetry (bridge-local)
	     "agent.telemetry.agents_count":
		return true
	}
	return false
}

// ---- small param helpers (pure) -----------------------------------------

bridge_agent_params_bool :: proc(params, key: string) -> bool {
	// accepts "key":true or "key":"true"
	if strings.contains(params, strings.concatenate({"\"", key, "\":true"})) do return true
	if bridge_local_extract_json_string(params, key, "") == "true" do return true
	return false
}

bridge_agent_instance_id :: proc(params: string) -> string {
	id := bridge_local_extract_json_string(params, "instance_id", "")
	if strings.trim_space(id) == "" do id = bridge_local_extract_json_string(params, "agent_instance_id", "")
	return strings.trim_space(id)
}

bridge_agent_task_id :: proc(params: string) -> string {
	id := bridge_local_extract_json_string(params, "task_id", "")
	return strings.trim_space(id)
}

// bridge_agent_rewrite_params adapts v2 params to what a specific hub endpoint
// expects, keeping the CLI/wire surface clean. Currently: agent.chat.send with a
// non-"user" `to` maps `to` -> `to_instance` for /chat/send-to-agent. Returns the
// (possibly rewritten) params; caller uses the result verbatim.
bridge_agent_rewrite_params :: proc(method, params: string) -> string {
	if method == "agent.chat.send" {
		to := strings.trim_space(bridge_local_extract_json_string(params, "to", ""))
		if to != "" && to != "user" {
			// inject to_instance = to (the hub's send-to-agent expects to_instance).
			body := strings.trim_space(params)
			if body == "" || body == "{}" {
				return strings.concatenate({"{\"to_instance\":\"", to, "\"}"})
			}
			// insert to_instance right after the opening brace.
			return strings.concatenate({"{\"to_instance\":\"", to, "\",", body[1:]})
		}
	}
	return params
}

// ---- local op handlers (bridge-served, no hub) --------------------------

// bridge_local_handle_agent_local_op fulfils .Local routes: bridge.list (merges
// Hub-registered bridges + this bridge's self row; direct bridge<->bridge peers
// were removed in favor of the star topology), search (hub relay + local
// decrypted task-chain hits), and the shell/vault/telemetry ops below.
bridge_local_handle_agent_local_op :: proc(request_id, op, params: string, rec: Bridge_Local_Agent_Token_Record) -> string {
	if op == "bridge.list" {
		scope := strings.trim_space(bridge_local_extract_json_string(params, "scope", "all"))
		if scope == "" do scope = "all"

		b := strings.builder_make()
		strings.write_string(&b, "{\"scope\":\"")
		bridge_local_write_json_string(&b, scope)
		strings.write_string(&b, "\",\"bridges\":[")
		first := true

		// Hub-registered bridges (scope hub|all): relay GET /api/v1/bridges and
		// splice each row through, tagged origin=hub.
		if (scope == "hub" || scope == "all") && strings.trim_space(rec.instance_token) != "" {
			relay := bridge_local_relay_raw("GET", "/api/v1/bridges", "", rec)
			if relay.ok && relay.status >= 200 && relay.status < 300 {
				for obj in bridge_agent_json_array_objects(bridge_agent_json_data_array(relay.body)) {
					if !first do strings.write_byte(&b, ',')
					first = false
					strings.write_string(&b, "{\"origin\":\"hub\",\"bridge\":")
					strings.write_string(&b, obj)
					strings.write_byte(&b, '}')
				}
			}
		}

		// Self (scope configured|all): served locally. Direct bridge<->bridge
		// peering was removed (star topology), so "configured" now returns just
		// this bridge's self row; hub-registered bridges come from the hub above.
		if scope == "configured" || scope == "all" {
			// self row
			if !first do strings.write_byte(&b, ',')
			first = false
			strings.write_string(&b, "{\"origin\":\"self\",\"daemon_id\":\"")
			bridge_local_write_json_string(&b, string(bridge_config.daemon_id))
			strings.write_string(&b, "\",\"local_endpoint_port\":")
			bridge_agent_write_int(&b, int(bridge_config.local_endpoint_port))
			strings.write_string(&b, "}")
		}

		strings.write_string(&b, "]}")
		return bridge_local_response_data(request_id, strings.to_string(b))
	}
	if op == "shell.wait" do return bridge_shell_wait_rpc(request_id, params, rec)
	if op == "search" do return bridge_agent_search_rpc(request_id, params, rec)
	// Task System v2 lease verbs: enrich with git state, then relay to the hub
	// path the route table names (agent_taskv2_vcs.odin).
	if op == "lease.next" do return bridge_agent_lease_local_rpc(request_id, "agent.lease.next", "/api/v1/agent-actions/lease/next", params, rec)
	if op == "lease.submit" do return bridge_agent_lease_local_rpc(request_id, "agent.lease.submit", "/api/v1/agent-actions/lease/submit", params, rec)
	if op == "lease.handoff" do return bridge_agent_lease_local_rpc(request_id, "agent.lease.handoff", "/api/v1/agent-actions/lease/handoff", params, rec)
	if op == "lease.switch" do return bridge_agent_lease_local_rpc(request_id, "agent.lease.switch", "/api/v1/agent-actions/lease/switch", params, rec)
	if op == "vault.status" {
		status := bridge_vault_status()
		status_str := bridge_vault_status_string(status)
		configured, permissions_valid, key_length := bridge_vault_key_status()
		b := strings.builder_make()
		strings.write_string(&b, "{\"status\":\"")
		strings.write_string(&b, status_str)
		strings.write_string(&b, "\",\"vault_status\":\"")
		strings.write_string(&b, status_str)
		strings.write_string(&b, "\",\"configured\":")
		strings.write_string(&b, "true" if status != .Disabled else "false")
		strings.write_string(&b, ",\"permissions_valid\":")
		strings.write_string(&b, "true" if permissions_valid else "false")
		strings.write_string(&b, ",\"key_length\":")
		bridge_agent_write_int(&b, key_length)
		strings.write_byte(&b, '}')
		return bridge_local_response_data(request_id, strings.to_string(b))
	}
	if op == "vault.lock" {
		bridge_vault_lock()
		return bridge_local_response_data(request_id, "{\"ok\":true,\"status\":\"locked\"}")
	}
	if op == "vault.reset" do return bridge_vault_reset_response(request_id)
	if op == "vault.get" {
		key, ok := bridge_read_vault_key()
		if !ok {
			return bridge_local_response_error(request_id, "not_found", "vault key not configured or permissions invalid")
		}
		defer delete(key)
		b := strings.builder_make()
		strings.write_string(&b, "{\"key\":\"")
		bridge_local_write_json_string(&b, key)
		strings.write_string(&b, "\",\"key_length\":")
		bridge_agent_write_int(&b, len(key))
		strings.write_byte(&b, '}')
		return bridge_local_response_data(request_id, strings.to_string(b))
	}
	if op == "telemetry.agents_count" {
		json := bridge_telemetry_agents_count_json()
		defer delete(json)
		return bridge_local_response_data(request_id, json)
	}
	return bridge_local_response_error(request_id, "bad_request", strings.concatenate({"unknown local op: ", op}))
}

// bridge_agent_write_int formats n straight into the builder. Allocates nothing:
// the digits land in a stack buffer that dies with the call, so there is no
// ownership question for a caller to get wrong. This is the right helper for the
// overwhelmingly common case of splicing an int into JSON being built.
//
// It replaces the old bridge_agent_itoa, whose ownership depended on its VALUE
// (the literal "0" for n == 0, a strings.clone otherwise), which made every
// possible caller wrong: dropping the result leaked for n != 0, and deleting it
// was a bad free for n == 0 -- and n == 0 is the most common exit code there is.
bridge_agent_write_int :: proc(b: ^strings.Builder, n: int) {
	buf: [24]byte
	strings.write_string(b, strconv.write_int(buf[:], i64(n), 10))
}

// bridge_agent_itoa_buf formats n into the CALLER-SUPPLIED buffer and returns a
// slice of it. The result is never owned by the callee and must never be freed by
// the caller; it stays valid exactly as long as buf does. Use this when the digits
// are needed as a string rather than written to a builder. buf should be >= 24
// bytes to hold any i64 with sign.
bridge_agent_itoa_buf :: proc(buf: []byte, n: int) -> string {
	return strconv.write_int(buf, i64(n), 10)
}

// bridge_agent_json_data_array returns the raw text of the top-level "data"
// array from a hub list response ({"data":[...],...}); "" if absent.
bridge_agent_json_data_array :: proc(body: string) -> string {
	key := "\"data\""
	idx := strings.index(body, key)
	if idx < 0 do return ""
	rest := body[idx + len(key):]
	lb := strings.index_byte(rest, '[')
	if lb < 0 do return ""
	depth := 0
	in_str := false
	esc := false
	for i := lb; i < len(rest); i += 1 {
		ch := rest[i]
		if in_str {
			if esc { esc = false; continue }
			if ch == '\\' { esc = true; continue }
			if ch == '"' do in_str = false
			continue
		}
		if ch == '"' { in_str = true; continue }
		if ch == '[' do depth += 1
		if ch == ']' { depth -= 1; if depth == 0 do return rest[lb:i + 1] }
	}
	return ""
}

// bridge_agent_json_array_objects splits a JSON array's top-level object elements
// into a slice of their raw {..} texts.
bridge_agent_json_array_objects :: proc(array: string) -> []string {
	out := make([dynamic]string)
	depth := 0
	in_str := false
	esc := false
	start := -1
	for i := 0; i < len(array); i += 1 {
		ch := array[i]
		if in_str {
			if esc { esc = false; continue }
			if ch == '\\' { esc = true; continue }
			if ch == '"' do in_str = false
			continue
		}
		if ch == '"' { in_str = true; continue }
		if ch == '{' { if depth == 0 do start = i; depth += 1; continue }
		if ch == '}' { depth -= 1; if depth == 0 && start >= 0 { append(&out, array[start:i + 1]); start = -1 } }
	}
	return out[:]
}

// bridge_vault_reset_response serves the bridge-local vault.reset op (REQ-T3-2):
// the one way to make an encrypted bridge report "disabled" again. Unlike
// vault.lock it also removes the vault_configured marker. The hub learns the new
// state from the next heartbeat; it has no command that reaches this path.
bridge_vault_reset_response :: proc(request_id: string) -> string {
	if !bridge_vault_reset() {
		return bridge_local_response_error(request_id, "internal", "vault key purged, but this bridge's vault_configured marker (~/.config/heimdall/bridges/<bridge_id>/vault_configured) could not be removed; the bridge still reports locked")
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "{\"ok\":true,\"status\":\"")
	strings.write_string(&b, bridge_vault_status_string())
	strings.write_string(&b, "\",\"marker_removed\":true,\"note\":\"vault.reset purged the vault key and removed this bridge's ~/.config/heimdall/bridges/<bridge_id>/vault_configured marker: it reports the vault as disabled (no encryption) until it is unsealed again. HEIMDALL_VAULT_CONFIGURED still takes precedence. To only drop the key and keep reporting locked, use vault.lock.\"}")
	return bridge_local_response_data(request_id, strings.to_string(b))
}
