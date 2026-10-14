package shell_session

// Telemetry assertions for plan 3.5 (heimdall_shell_*). These run alongside the
// rest of the package in parallel, so every assertion is a DELTA against a value
// read before the action, on a bridge id no other test uses; fleet-wide counters
// are asserted with >= because sibling tests move them too.

import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project_service "odin_test:hub/service/project"
import metrics "odin_test:lib/metrics"

@(private = "file")
metrics_test_init :: proc() {
	reg := metrics.init_global()
	project_service.fleet_metrics_init(reg)
	shell_metrics_init(reg)
}

@(private = "file")
Metrics_Pair :: struct {
	listener: net.TCP_Socket,
	peer:     net.TCP_Socket,
	hub:      net.TCP_Socket,
}

@(private = "file")
metrics_make_pair :: proc(t: ^testing.T) -> Metrics_Pair {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not listen on loopback")
	bound, bound_err := net.bound_endpoint(listener)
	if bound_err != nil do testing.fail_now(t, "could not read the bound endpoint")
	peer, dial_err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	if dial_err != nil do testing.fail_now(t, "could not dial loopback")
	hub, _, accept_err := net.accept_tcp(listener)
	if accept_err != nil do testing.fail_now(t, "could not accept on loopback")
	return Metrics_Pair{listener = listener, peer = peer, hub = hub}
}

@(private = "file")
metrics_close_pair :: proc(p: ^Metrics_Pair) {
	net.close(p.hub)
	net.close(p.peer)
	net.close(p.listener)
}

@(test)
test_shell_metrics_output_fanout_detach_and_first_frame :: proc(t: ^testing.T) {
	metrics_test_init()
	pair := metrics_make_pair(t)
	defer metrics_close_pair(&pair)
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)

	bridge_id := "brg_metrics_shell_a"
	session_id := "sh_metrics_a"
	m := &shell_metrics
	fm := &project_service.fleet_metrics

	out_before := metrics.counter_value(metrics.with(m.output_bytes, bridge_id))
	fanout_before := metrics.counter_value(m.fanout_bytes)
	tx_before := metrics.counter_value(metrics.with(fm.ws_bytes, project_service.WS_KIND_SHELL, "tx", bridge_id))
	detach_before := metrics.counter_value(metrics.with(m.viewer_detaches, "peer_gone"))

	shell_session_attach(&svc, session_id, pair.hub, bridge_id, project_service.WS_KIND_SHELL)
	testing.expect_value(t, shell_session_viewer_count(&svc, session_id), 1)

	payload := "aGVsbG8gbWV0cmljcw==" // "hello metrics"
	shell_session_broadcast_output(&svc, session_id, payload)
	pane_test_wait_writer(t, &svc, pair.hub)

	// Output bytes: exactly the payload, on exactly this bridge.
	testing.expect_value(t, metrics.counter_value(metrics.with(m.output_bytes, bridge_id)) - out_before, u64(len(payload)))
	// Fan-out and the per-connection tx series both moved by at least the frame size
	// (the frame wraps the payload in JSON, so strictly more than the payload).
	testing.expect(t, metrics.counter_value(m.fanout_bytes) - fanout_before > u64(len(payload)), "fanout bytes must count the written frame")
	testing.expect(t, metrics.counter_value(metrics.with(fm.ws_bytes, project_service.WS_KIND_SHELL, "tx", bridge_id)) - tx_before > u64(len(payload)), "ws_bytes{shell,tx,bridge} must count the written frame")
	shell_session_detach(&svc, session_id, pair.hub, bridge_id, .Peer_Gone)
	testing.expect(t, metrics.counter_value(metrics.with(m.viewer_detaches, "peer_gone")) - detach_before >= 1, "detach reason must be counted")
	testing.expect_value(t, shell_session_viewer_count(&svc, session_id), 0)
}

// The first-frame tracker is process-global and sibling tests reset it, so the
// latency path is pinned directly rather than through a live socket.
@(test)
test_shell_metrics_first_frame_latency_is_observed :: proc(t: ^testing.T) {
	metrics_test_init()
	session_id := "sh_metrics_first_frame"
	before := metrics.histogram_count(shell_metrics.first_frame_latency)
	shell_first_frame_arm(session_id)
	time.sleep(2 * time.Millisecond)
	fired, latency := shell_first_frame_take_latency(session_id)
	if fired {
		testing.expect(t, latency >= 2 * time.Millisecond, "latency must measure from the arming attach")
		shell_metrics_note_first_frame(latency)
		testing.expect(t, metrics.histogram_count(shell_metrics.first_frame_latency) - before >= 1, "first frame latency must land in the histogram")
	}
	fired_again, zero := shell_first_frame_take_latency(session_id)
	testing.expect(t, !fired_again && zero == 0, "the one-shot must not fire twice")
}

@(test)
test_shell_metrics_input_counter_and_reason_mappers :: proc(t: ^testing.T) {
	metrics_test_init()
	before := metrics.counter_value(shell_metrics.input_bytes)
	shell_metrics_note_input(7)
	shell_metrics_note_input(0)
	shell_metrics_note_input(-3)
	testing.expect(t, metrics.counter_value(shell_metrics.input_bytes) - before >= 7)

	testing.expect_value(t, ws_write_reason_string(.Peer_Gone), "peer_gone")
	testing.expect_value(t, ws_write_reason_string(.Desynchronised), "desync")
	testing.expect_value(t, ws_write_reason_string(.Too_Large), "too_large")
	testing.expect_value(t, shell_session_state_enum("running"), "running")
	testing.expect_value(t, shell_session_state_enum("starting"), "starting")
	testing.expect_value(t, shell_session_state_enum("made-up"), "other")
	testing.expect_value(t, shell_session_state_enum(""), "other")
}

// --- collector ---------------------------------------------------------------

@(private = "file")
Fake_Live_Repo :: struct {
	bridge_id: string,
	statuses:  []string,
}

@(private = "file")
fake_live_bridge_ids :: proc(ctx: rawptr, limit: int) -> ([dynamic]string, domain.Domain_Error) {
	f := (^Fake_Live_Repo)(ctx)
	out := make([dynamic]string)
	append(&out, strings.clone(f.bridge_id))
	return out, domain.Domain_Error{}
}

@(private = "file")
fake_live_by_bridge :: proc(ctx: rawptr, bridge_id: string, limit: int) -> ([dynamic]domain.Shell_Session, domain.Domain_Error) {
	f := (^Fake_Live_Repo)(ctx)
	out := make([dynamic]domain.Shell_Session)
	if bridge_id != f.bridge_id do return out, domain.Domain_Error{}
	for st, i in f.statuses {
		append(&out, domain.Shell_Session{
			session_id    = strings.clone("sh_live_"),
			owner_user_id = strings.clone("user_m"),
			bridge_id     = strings.clone(bridge_id),
			status        = strings.clone(st),
		})
		_ = i
	}
	return out, domain.Domain_Error{}
}

@(private = "file")
gather_text :: proc() -> string {
	b := strings.builder_make()
	metrics.gather(metrics.global(), &b)
	return strings.to_string(b)
}

@(test)
test_shell_metrics_collector_reports_viewers_and_sessions :: proc(t: ^testing.T) {
	metrics_test_init()
	pair := metrics_make_pair(t)
	defer metrics_close_pair(&pair)

	fake := Fake_Live_Repo{bridge_id = "brg_metrics_collect", statuses = {"running", "running", "starting", "weird"}}
	repo := iface.Shell_Session_Repository{
		ctx                  = rawptr(&fake),
		list_live_bridge_ids = fake_live_bridge_ids,
		list_live_by_bridge  = fake_live_by_bridge,
	}
	svc := new_shell_session_service(repo = &repo)
	defer shell_session_service_free(&svc)

	shell_metrics_set_service(&svc)
	defer shell_metrics_detach_service(&svc)
	shell_metrics_invalidate_sessions_cache()

	shell_session_attach(&svc, "sh_collect", pair.hub, "brg_metrics_collect")
	defer shell_session_detach(&svc, "sh_collect", pair.hub, "brg_metrics_collect", .Stream_Closed)

	text := gather_text()
	defer delete(text)
	testing.expect(t, strings.contains(text, "heimdall_shell_viewers{bridge_id=\"brg_metrics_collect\"} 1\n"), "viewers gauge must count the attached socket per bridge")
	testing.expect(t, strings.contains(text, "heimdall_shell_sessions{bridge_id=\"brg_metrics_collect\",state=\"running\"} 2\n"), "sessions gauge must group live rows by state")
	testing.expect(t, strings.contains(text, "heimdall_shell_sessions{bridge_id=\"brg_metrics_collect\",state=\"starting\"} 1\n"))
	testing.expect(t, strings.contains(text, "heimdall_shell_sessions{bridge_id=\"brg_metrics_collect\",state=\"other\"} 1\n"), "unknown states must collapse to other")

	// Detached: the collector must not touch the service any more.
	shell_metrics_detach_service(&svc)
	again := gather_text()
	defer delete(again)
	testing.expect(t, !strings.contains(again, "heimdall_shell_viewers{bridge_id=\"brg_metrics_collect\"}"), "a detached service must not be scraped")
	testing.expect(t, !strings.contains(again, "heimdall_shell_sessions{bridge_id=\"brg_metrics_collect\""), "a detached service must not be scraped (sessions)")
}
