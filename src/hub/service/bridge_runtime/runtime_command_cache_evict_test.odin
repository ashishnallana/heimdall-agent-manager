package bridge_runtime

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import project_service "odin_test:hub/service/project"

// Guards the ring-buffer eviction fix: the command-result cache must keep caching
// past its capacity. The old fixed array stopped storing after 256 entries, so
// send_runtime_command_wait never saw the reply and every bridge relay 409-timed
// out hub-wide until a restart.
@(test)
runtime_command_cache_evicts_and_keeps_caching :: proc(t: ^testing.T) {
	registry := new(project_service.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(registry); free(registry) }
	cap := RUNTIME_COMMAND_RESULTS_PER_BRIDGE
	total := cap + 44 // overflow this Bridge's quota so its oldest entries are evicted

	ids: [dynamic]string
	results: [dynamic]string
	defer { for s in ids do delete(s); for s in results do delete(s); delete(ids); delete(results) }
	for i in 0 ..< total {
		id := fmt.aprintf("cmd_%d", i)
		res := fmt.aprintf("{\"command_id\":\"cmd_%d\"}", i)
		append(&ids, id); append(&results, res)
		_, _ = runtime_command_result_idempotent(registry, "brg_x", 1, id, res)
	}

	// The cache never stops: count keeps advancing past the capacity.
	testing.expect_value(t, registry.command_count, total)

	// The most recent `cap` results are still retrievable (this is what a relay
	// waiting on a fresh command needs).
	newest, ok := runtime_command_cached(registry, "brg_x", 1, ids[total - 1])
	testing.expect(t, ok, "the newest command result must still be cached")
	testing.expect_value(t, newest, results[total - 1])
	mid, ok_mid := runtime_command_cached(registry, "brg_x", 1, ids[total - cap]) // oldest still-live
	testing.expect(t, ok_mid, "the oldest still-live result must be cached")
	_ = mid

	// The overflowed-out oldest entries are evicted (bounded memory), not corrupt.
	_, ok_evicted := runtime_command_cached(registry, "brg_x", 1, ids[0])
	testing.expect(t, !ok_evicted, "the oldest overflowed id must be evicted")

	// Idempotent: the first result for an id still wins over a later frame.
	first := "{\"first\":true}"
	second := "{\"second\":true}"
	got1, _ := runtime_command_result_idempotent(registry, "brg_x", 1, "dup_id", first)
	testing.expect_value(t, got1, first)
	got2, existed := runtime_command_result_idempotent(registry, "brg_x", 1, "dup_id", second)
	testing.expect(t, existed, "second frame for a cached id must report a hit")
	testing.expect_value(t, got2, first)
}

@(test)
runtime_command_cache_is_partitioned_by_bridge :: proc(t: ^testing.T) {
	registry := new(project_service.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(registry); free(registry) }
	quiet_result := strings.clone("{\"type\":\"provider_discovery_report\",\"command_id\":\"quiet\"}")
	defer delete(quiet_result)
	_, _ = runtime_command_result_idempotent(registry, "brg_quiet", 1, "quiet", quiet_result)
	for i in 0 ..< RUNTIME_COMMAND_RESULTS_PER_BRIDGE * 4 {
		id := fmt.aprintf("noisy_%d", i)
		result := fmt.aprintf("{\"type\":\"command_result\",\"command_id\":\"noisy_%d\",\"payload\":{\"status\":\"succeeded\"}}", i)
		_, _ = runtime_command_result_idempotent(registry, "brg_noisy", 1, id, result)
		delete(id)
		delete(result)
	}
	quiet, quiet_ok := runtime_command_cached(registry, "brg_quiet", 1, "quiet")
	testing.expect(t, quiet_ok, "a noisy Bridge must not evict another Bridge's pending result")
	testing.expect_value(t, quiet, quiet_result)
}

@(test)
runtime_writer_mutexes_are_isolated_by_bridge :: proc(t: ^testing.T) {
	registry := new(project_service.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(registry); free(registry) }
	_, _, _ = runtime_accept_hello(registry, "brg_a", PROTOCOL_VERSION, "")
	_, _, _ = runtime_accept_hello(registry, "brg_b", PROTOCOL_VERSION, "")
	a1 := project_service.bridge_runtime_connection_acquire(registry, "brg_a")
	defer project_service.bridge_runtime_connection_release(registry, a1)
	a2 := project_service.bridge_runtime_connection_acquire(registry, "brg_a")
	defer project_service.bridge_runtime_connection_release(registry, a2)
	b := project_service.bridge_runtime_connection_acquire(registry, "brg_b")
	defer project_service.bridge_runtime_connection_release(registry, b)
	testing.expect(t, a1 != nil && a1 == a2, "one live generation retains one writer object")
	testing.expect(t, b != nil && &a1.writer_mutex != &b.writer_mutex, "different connections never share a writer lock")
}

@(test)
runtime_stalled_bridge_writer_does_not_block_another_bridge_send :: proc(t: ^testing.T) {
	registry := new(project_service.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(registry); free(registry) }
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expect(t, listen_err == nil)
	bound, _ := net.bound_endpoint(listener)
	a_peer, _ := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	a_hub, _, _ := net.accept_tcp(listener)
	b_peer, _ := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = bound.port})
	b_hub, _, _ := net.accept_tcp(listener)
	defer { net.close(a_peer); net.close(a_hub); net.close(b_peer); net.close(b_hub); net.close(listener) }
	stalled_hello, _, _ := runtime_accept_hello(registry, "brg_stalled", PROTOCOL_VERSION, "")
	healthy_hello, _, _ := runtime_accept_hello(registry, "brg_healthy", PROTOCOL_VERSION, "")
	project_service.bridge_runtime_registry_set_command_socket(registry, "brg_stalled", a_hub, stalled_hello.generation)
	project_service.bridge_runtime_registry_set_command_socket(registry, "brg_healthy", b_hub, healthy_hello.generation)

	stalled := project_service.bridge_runtime_connection_acquire(registry, "brg_stalled", stalled_hello.generation)
	defer project_service.bridge_runtime_connection_release(registry, stalled)
	if !testing.expect(t, stalled != nil, "stalled Bridge connection lease is available") do return
	sync.lock(&stalled.writer_mutex)
	started := time.now()
	sent, err := send_runtime_command(rawptr(registry), project_service.Runtime_Command{
		bridge_id = "brg_healthy", command_id = "cmd_healthy", body_json = `{"type":"bridge_heartbeat_ack"}`,
	})
	elapsed := time.diff(started, time.now())
	sync.unlock(&stalled.writer_mutex)
	testing.expect(t, sent, err.message)
	testing.expect(t, elapsed < 100 * time.Millisecond, "a held writer for Bridge A must not delay Bridge B")
	buf: [256]byte
	n, recv_err := net.recv_tcp(b_peer, buf[:])
	testing.expect(t, recv_err == nil && n > 0, "the healthy Bridge receives its frame")
}

@(test)
runtime_command_cache_isolated_by_connection_generation :: proc(t: ^testing.T) {
	registry := new(project_service.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(registry); free(registry) }
	old_result := `{"type":"command_result","payload":{"status":"succeeded","result":"old"}}`
	new_result := `{"type":"command_result","payload":{"status":"succeeded","result":"new"}}`
	_, _ = runtime_command_result_idempotent(registry, "brg_a", 1, "cmd_same", old_result)
	_, _ = runtime_command_result_idempotent(registry, "brg_a", 2, "cmd_same", new_result)
	old_cached, old_ok := runtime_command_cached(registry, "brg_a", 1, "cmd_same")
	new_cached, new_ok := runtime_command_cached(registry, "brg_a", 2, "cmd_same")
	testing.expect(t, old_ok && new_ok, "both generations retain their own terminal observation")
	testing.expect_value(t, old_cached, old_result)
	testing.expect_value(t, new_cached, new_result)
}
