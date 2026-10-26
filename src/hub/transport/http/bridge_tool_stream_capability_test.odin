// Tool-stream support through the bridge capability record: hello -> repeated
// heartbeats -> GET /api/v1/bridges/{id} -> live tool subscription admission, and a
// heartbeat that withdraws the feature fails closed.
package http

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import agent_service "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import bridge_service "odin_test:hub/service/bridge"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import user_service "odin_test:hub/service/user"

@(private = "file")
TOOL_STREAM_CAPABILITY_FEATURES :: `["capture_agent_pane","get_agent_pane","instance_reconfiguration_v1","tool_stream_demand_v2"]`
// The list a pre-fix bridge's heartbeat carried: everything but tool_stream_demand_v2.
@(private = "file")
TOOL_STREAM_CAPABILITY_STALE_FEATURES :: `["capture_agent_pane","get_agent_pane","instance_reconfiguration_v1"]`

@(private = "file")
Tool_Stream_Capability_Fixture :: struct {
	conn: sqlite.Conn,
	br_repo_sqlite: sqlite.Bridge_Repo_SQLite,
	us_repo_sqlite: sqlite.User_Repo_SQLite,
	ag_repo_sqlite: sqlite.Agent_Repo_SQLite,
	br_repo: iface.Bridge_Repository,
	us_repo: iface.User_Repository,
	ag_repo: iface.Agent_Repository,
	tool_repo: iface.Agent_Repository,
	clock: platform.Clock,
	ids: platform.ID_Generator,
	br_svc: bridge_service.Bridge_Service,
	us_svc: user_service.User_Service,
	ag_svc: agent_service.Agent_Service,
	auth_svc: auth_service.Auth_Service,
	bh: Bridge_Handlers,
	user_headers: []contracts.HTTP_Header,
	owner_user_id: string,
	bridge_id: string,
	bridge_token: string,
	viewer: agent_service.Tool_Stream_Viewer,
}

@(private = "file")
tool_stream_capability_setup :: proc(t: ^testing.T, f: ^Tool_Stream_Capability_Fixture) -> bool {
	conn, open_ok, _ := sqlite.open(":memory:")
	if !testing.expect(t, open_ok, "sqlite open ok") do return false
	f.conn = conn
	mig_ok, _ := sqlite.run_migrations(&f.conn)
	if !testing.expect(t, mig_ok, "migrations ok") do return false
	f.br_repo = sqlite.new_bridge_repository(&f.br_repo_sqlite, &f.conn)
	f.us_repo = sqlite.new_user_repository(&f.us_repo_sqlite, &f.conn)
	f.ag_repo = sqlite.new_agent_repository(&f.ag_repo_sqlite, &f.conn)
	f.clock = platform.real_clock()
	f.ids = http_test_id_generator()
	f.br_svc = bridge_service.new_bridge_service(&f.br_repo, &f.clock, &f.ids)
	f.us_svc = user_service.new_user_service_basic(&f.us_repo, &f.clock, &f.ids)
	f.ag_svc = agent_service.new_agent_service(&f.ag_repo, &f.br_repo, &f.clock, &f.ids)
	f.auth_svc = auth_service.new_auth_service(auth_service.Auth_Config{auto_provision_users = true}, &f.us_svc)
	f.auth_svc.clock = &f.clock
	f.auth_svc.ids = &f.ids
	f.auth_svc.bridges = &f.br_svc
	f.auth_svc.agents = &f.ag_svc
	f.bh = Bridge_Handlers{auth = &f.auth_svc, bridges = &f.br_svc, agents = &f.ag_svc}

	owned := context.allocator
	{
		// Session login and enrollment results are request-scoped in production.
		context.allocator = context.temp_allocator
		f.user_headers = http_test_login(t, &f.auth_svc, "tanmay")
		owner_ctx, owner_ok, _ := auth_service.resolve_auth_any(&f.auth_svc, auth_service.Auth_Request{remote_addr = "127.0.0.1:4444", headers = f.user_headers})
		if !testing.expect(t, owner_ok, "session owner resolved") do return false
		f.owner_user_id = strings.clone(owner_ctx.user_id, owned)
		enrolled, e_ok, _ := bridge_service.enroll_bridge_from_device_grant(&f.br_svc, bridge_service.Device_Enroll_Input{
			owner_user_id = f.owner_user_id,
			bridge_public_key = "04aabb",
			bridge_key_fingerprint = "aaaa bbbb cccc dddd",
			machine_hostname = "test-box",
		})
		if !testing.expect(t, e_ok, "bridge enrolled") do return false
		f.bridge_id = strings.clone(enrolled.bridge.bridge_id, owned)
		f.bridge_token = strings.clone(enrolled.bridge_token, owned)
	}

	// The live instance runs on the enrolled bridge; admission reads the bridge row.
	f.tool_repo = iface.Agent_Repository{ctx = f, get_tool_instance = proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
		f := (^Tool_Stream_Capability_Fixture)(ctx)
		return domain.Agent_Instance{agent_instance_id = id, bridge_id = f.bridge_id, owner_user_id = domain.User_ID(f.owner_user_id), run_count = 1, runtime_status = "running"}, true, {}
	}}
	f.ag_svc.agents = &f.tool_repo
	heap := runtime.heap_allocator()
	s := &f.ag_svc.tool_live
	s.routes = make(map[string]^agent_service.Tool_Stream_Route, heap)
	s.viewers = make(map[net.TCP_Socket]^agent_service.Tool_Stream_Viewer, heap)
	s.controls = make([dynamic]agent_service.Tool_Stream_Control, heap)
	f.viewer = {owner = f.owner_user_id, socket = net.TCP_Socket(-1), external = true, ids = make(map[string]bool, heap), queue = make([dynamic]agent_service.Tool_Stream_Frame, heap)}
	s.viewers[f.viewer.socket] = &f.viewer
	return true
}

@(private = "file")
tool_stream_capability_teardown :: proc(f: ^Tool_Stream_Capability_Fixture) {
	heap := runtime.heap_allocator()
	_ = agent_service.tool_stream_subscribe(&f.ag_svc, &f.viewer, nil) // releases routes and scopes
	for frame in f.viewer.queue { delete(frame.text, heap); delete(frame.instance_id, heap) }
	for key in f.viewer.ids do delete(key, heap)
	delete(f.viewer.ids); delete(f.viewer.queue)
	agent_service.tool_live_destroy(&f.ag_svc.tool_live)
	sqlite.close(&f.conn)
	delete(f.owner_user_id); delete(f.bridge_id); delete(f.bridge_token)
}

@(private = "file")
tool_stream_capability_frame :: proc(type, features: string) -> string {
	return fmt.tprintf(`{{"type":"%s","protocol_version":1,"capabilities":[],"features":%s,"active_instance_ids":[]}}`, type, features)
}

@(private = "file")
tool_stream_capability_heartbeat :: proc(t: ^testing.T, f: ^Tool_Stream_Capability_Fixture, features: string) {
	saved, ok, err := bridge_service.update_runtime_capabilities(&f.br_svc, f.bridge_id, tool_stream_capability_frame("bridge_heartbeat", features))
	testing.expect(t, ok, "heartbeat stored")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	domain.bridge_destroy(&saved)
}

// GET /api/v1/bridges/{id}: the existing capability response, decoded strictly.
@(private = "file")
tool_stream_capability_detail :: proc(t: ^testing.T, f: ^Tool_Stream_Capability_Fixture) -> (tool_stream, reconfiguration: bool) {
	context.allocator = context.temp_allocator // a request arena in production
	resp := bridge_detail_handler(rawptr(&f.bh), Request{method = "GET", path = fmt.tprintf("/api/v1/bridges/%s", f.bridge_id), request_id = "req_tool_stream_caps", remote_addr = "127.0.0.1:4444", headers = f.user_headers})
	testing.expect_value(t, resp.status, 200)
	value, err := json.parse_string(resp.body, .JSON, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	root, _ := value.(json.Object)
	bridge := root
	if data, nested := root["data"].(json.Object); nested do bridge = data
	id, _ := bridge["bridge_id"].(json.String)
	testing.expect_value(t, string(id), f.bridge_id)
	ts, ts_ok := bridge["tool_stream_supported"].(json.Boolean)
	rc, rc_ok := bridge["reconfiguration_supported"].(json.Boolean)
	testing.expect(t, ts_ok, "tool_stream_supported is a JSON boolean")
	testing.expect(t, rc_ok, "reconfiguration_supported is a JSON boolean")
	return bool(ts), bool(rc)
}

@(private = "file")
tool_stream_capability_subscribe :: proc(f: ^Tool_Stream_Capability_Fixture) -> string {
	heap := runtime.heap_allocator()
	scopes := make(map[string]string, heap)
	scopes[strings.clone("inst_live", heap)] = strings.clone("chat_live", heap)
	ids := [1]string{"inst_live"}
	result := agent_service.tool_stream_subscribe(&f.ag_svc, &f.viewer, ids[:], scopes)
	if result != "" do agent_service.tool_stream_scopes_free(scopes) // ownership moves only on success
	return result
}

@(test)
test_tool_stream_support_survives_heartbeats_into_capability_response_and_admission :: proc(t: ^testing.T) {
	f: Tool_Stream_Capability_Fixture
	defer tool_stream_capability_teardown(&f)
	if !tool_stream_capability_setup(t, &f) do return

	// Before any runtime frame the bridge advertises nothing: fail closed.
	ts, rc := tool_stream_capability_detail(t, &f)
	testing.expect(t, !ts, "no runtime frame yet: tool stream unsupported")
	testing.expect_value(t, tool_stream_capability_subscribe(&f), "upgrade_required")

	{
		context.allocator = context.temp_allocator // the hello handler's request scope
		_, connect_ok, connect_err := bridge_service.bridge_runtime_connect(&f.br_svc, f.bridge_token, "test-box", "linux", "amd64", tool_stream_capability_frame("bridge_hello", TOOL_STREAM_CAPABILITY_FEATURES))
		testing.expect(t, connect_ok, "hello accepted")
		testing.expect_value(t, connect_err.code, domain.Error_Code.None)
	}

	// Several heartbeats carrying the same complete list never erase the feature.
	for _ in 0 ..< 3 do tool_stream_capability_heartbeat(t, &f, TOOL_STREAM_CAPABILITY_FEATURES)
	ts, rc = tool_stream_capability_detail(t, &f)
	testing.expect(t, ts, "tool_stream_supported after hello and repeated heartbeats")
	testing.expect(t, rc, "reconfiguration_supported read from the same feature record")
	testing.expect_value(t, tool_stream_capability_subscribe(&f), "")
	testing.expect_value(t, len(f.ag_svc.tool_live.routes), 1)
	testing.expect(t, f.viewer.ids["inst_live"], "viewer holds the live subscription")

	// A heartbeat that withdraws the feature (the pre-fix stale list) fails closed:
	// the API reports it unsupported and renewed admission is refused, while the
	// other features in the same record stay supported.
	tool_stream_capability_heartbeat(t, &f, TOOL_STREAM_CAPABILITY_STALE_FEATURES)
	ts, rc = tool_stream_capability_detail(t, &f)
	testing.expect(t, !ts, "withdrawn feature reported unsupported")
	testing.expect(t, rc, "withdrawal is per feature")
	testing.expect_value(t, tool_stream_capability_subscribe(&f), "upgrade_required")
	testing.expect(t, f.viewer.ids["inst_live"], "rejected renewal leaves the previous set intact (atomic validation)")
}
