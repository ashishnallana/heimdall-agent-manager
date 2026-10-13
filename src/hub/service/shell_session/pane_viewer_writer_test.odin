package shell_session

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import ws "odin_test:lib/ws"

Pane_Test_Pair :: struct { hub, peer: net.TCP_Socket }
pane_test_pair :: proc(t: ^testing.T) -> Pane_Test_Pair {
	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expect(t, err == nil)
	defer net.close(listener)
	ep, _ := net.bound_endpoint(listener)
	peer, dial_err := net.dial_tcp(ep)
	testing.expect(t, dial_err == nil)
	hub, _, accept_err := net.accept_tcp(listener)
	testing.expect(t, accept_err == nil)
	_ = net.set_blocking(peer, false)
	_ = net.set_option(hub, .Send_Buffer_Size, 4096)
	_ = net.set_option(peer, .Receive_Buffer_Size, 4096)
	return {hub, peer}
}
pane_test_read :: proc(t: ^testing.T, reader: ^ws.Connection) -> string {
	start := time.tick_now()
	for time.tick_since(start) < 2 * time.Second {
		text, ok := ws.poll_text(reader)
		if ok do return text
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "viewer did not receive its frame")
	return ""
}

@(test)
test_pane_slow_viewer_does_not_block_healthy_viewer :: proc(t: ^testing.T) {
	slow := pane_test_pair(t)
	healthy := pane_test_pair(t)
	defer net.close(slow.hub)
	defer net.close(slow.peer)
	defer net.close(healthy.hub)
	reader := ws.Connection{socket = healthy.peer, connected = true}
	defer ws.close(&reader)
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	shell_session_attach(&svc, "pane", slow.hub, "bridge")
	data := strings.repeat("A", 16 * 1024)
	defer delete(data)
	for i in 0..<2048 {
		start := time.tick_now()
		shell_session_broadcast_output(&svc, "pane", data)
		testing.expect(t, time.tick_since(start) < 100 * time.Millisecond, "slow viewer blocked reader")
		sync.mutex_lock(&svc.mu)
		w := svc.viewer_writers[slow.hub]
		sync.mutex_lock(&w.mu)
		stopped := w.stopped
		sync.mutex_unlock(&w.mu)
		sync.mutex_unlock(&svc.mu)
		if stopped do break
	}
	shell_session_attach(&svc, "pane", healthy.hub, "bridge")
	for i in 0..<40 {
		start := time.tick_now()
		shell_session_broadcast_output(&svc, "pane", data)
		testing.expect(t, time.tick_since(start) < 100 * time.Millisecond, "reader blocked on fan-out")
		text := pane_test_read(t, &reader)
		testing.expect(t, strings.contains(text, data), "healthy viewer output changed")
		delete(text)
	}
	sync.mutex_lock(&svc.mu)
	w := svc.viewer_writers[slow.hub]
	sync.mutex_lock(&w.mu)
	testing.expect(t, w.stopped, "slow viewer was not disconnected at its byte budget")
	testing.expect(t, w.bytes <= PANE_VIEWER_QUEUE_BYTES)
	sync.mutex_unlock(&w.mu)
	sync.mutex_unlock(&svc.mu)
	testing.expect_value(t, shell_session_viewer_count(&svc, "pane"), 1)
}

@(test)
test_pane_snapshot_chunks_and_output_remain_ordered :: proc(t: ^testing.T) {
	pair := pane_test_pair(t)
	defer net.close(pair.hub)
	reader := ws.Connection{socket = pair.peer, connected = true}
	defer ws.close(&reader)
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	shell_session_attach(&svc, "pane", pair.hub, "bridge")
	mu := shell_session_viewer_write_lock(&svc, "pane")
	sync.mutex_lock(mu)
	for frame in ([]string{"{\"type\":\"screen\",\"screen_b64\":\"QQ==\"}", "{\"type\":\"screen\",\"screen_b64\":\"Qg==\"}"}) {
		testing.expect_value(t, shell_session_enqueue_viewer_frame(&svc, pair.hub, frame), ws.Text_Write_Result.Ok)
	}
	sync.mutex_unlock(mu)
	shell_session_viewer_write_release(&svc, "pane")
	shell_session_broadcast_output(&svc, "pane", "Qw==")
	for expected in ([]string{"QQ==", "Qg==", "Qw=="}) {
		text := pane_test_read(t, &reader)
		testing.expect(t, strings.contains(text, expected))
		delete(text)
	}
	shell_session_detach(&svc, "pane", pair.hub)
	testing.expect_value(t, len(svc.viewer_writers), 0)
	testing.expect_value(t, len(svc.viewer_write_mu), 0)
	testing.expect_value(t, len(svc.viewers), 0)
	testing.expect_value(t, len(svc.pane_bridge_bytes), 0)
}

@(test)
test_pane_writer_churn_reclaims_workers_and_keys :: proc(t: ^testing.T) {
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	for i in 0..<100 {
		pair := pane_test_pair(t)
		shell_session_attach(&svc, "pane", pair.hub, "bridge")
		shell_session_detach(&svc, "pane", pair.hub)
		net.close(pair.hub)
		net.close(pair.peer)
	}
	testing.expect_value(t, len(svc.viewer_writers), 0)
	testing.expect_value(t, len(svc.viewers), 0)
	testing.expect_value(t, len(svc.viewer_write_mu), 0)
}

pane_test_wait_writer :: proc(t: ^testing.T, svc: ^Shell_Session_Service, socket: net.TCP_Socket) {
	start := time.tick_now()
	for time.tick_since(start) < 2 * time.Second {
		sync.mutex_lock(&svc.mu)
		w := svc.viewer_writers[socket]
		sync.mutex_lock(&w.mu)
		done := w.bytes == 0 || w.stopped
		sync.mutex_unlock(&w.mu)
		sync.mutex_unlock(&svc.mu)
		if done do return
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "viewer writer did not finish")
}

@(test)
test_pane_multiple_bridges_sustain_output_without_queue_growth :: proc(t: ^testing.T) {
	pairs: [10]Pane_Test_Pair
	readers: [10]ws.Connection
	ids := []string{"pane0", "pane1", "pane2", "pane3", "pane4", "pane5", "pane6", "pane7", "pane8", "pane9"}
	bridges := []string{"bridge0", "bridge1", "bridge2", "bridge3", "bridge4", "bridge5", "bridge6", "bridge7", "bridge8", "bridge9"}
	defer for i in 0..<len(pairs) { ws.close(&readers[i]); net.close(pairs[i].hub) }
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	for i in 0..<len(pairs) {
		pairs[i] = pane_test_pair(t)
		readers[i] = ws.Connection{socket = pairs[i].peer, connected = true}
		shell_session_attach(&svc, ids[i], pairs[i].hub, bridges[i])
	}
	data := strings.repeat("A", 1024)
	defer delete(data)
	for round in 0..<500 {
		for i in 0..<len(pairs) do shell_session_broadcast_output(&svc, ids[i], data, false, false, bridges[i])
		for i in 0..<len(pairs) {
			text := pane_test_read(t, &readers[i])
			testing.expect(t, strings.contains(text, data))
			delete(text)
		}
	}
	for i in 0..<len(pairs) {
		pane_test_wait_writer(t, &svc, pairs[i].hub)
		sync.mutex_lock(&svc.mu)
		testing.expect_value(t, svc.pane_bridge_bytes[bridges[i]], 0)
		sync.mutex_unlock(&svc.mu)
	}
}

@(test)
test_pane_resync_is_scoped_to_its_bridge :: proc(t: ^testing.T) {
	pair := pane_test_pair(t)
	defer net.close(pair.hub)
	reader := ws.Connection{socket = pair.peer, connected = true}
	defer ws.close(&reader)
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	shell_session_attach(&svc, "pane", pair.hub, "bridgeA")
	shell_session_resync_viewers(&svc, "pane", "bridgeB")
	testing.expect_value(t, shell_session_viewer_count(&svc, "pane"), 1)
	shell_session_broadcast_output(&svc, "pane", "QQ==", false, false, "bridgeB")
	shell_session_broadcast_output(&svc, "pane", "Qg==", false, false, "bridgeA")
	text := pane_test_read(t, &reader)
	defer delete(text)
	testing.expect(t, strings.contains(text, "Qg=="))
	shell_session_resync_viewers(&svc, "pane", "bridgeA")
	testing.expect_value(t, shell_session_viewer_count(&svc, "pane"), 0)
}

@(test)
test_pane_pong_uses_the_registered_writer_and_preserves_payload :: proc(t: ^testing.T) {
	pair := pane_test_pair(t)
	defer net.close(pair.hub)
	defer net.close(pair.peer)
	svc := new_shell_session_service()
	defer shell_session_service_free(&svc)
	shell_session_attach(&svc, "pane", pair.hub, "bridge")
	testing.expect(t, shell_session_enqueue_viewer_control(&svc, pair.hub, 0xA, "alive"))
	received := make([dynamic]byte)
	defer delete(received)
	buf: [32]byte
	started := time.tick_now()
	for len(received) < 7 && time.tick_since(started) < time.Second {
		n, err := net.recv_tcp(pair.peer, buf[:])
		if err == nil && n > 0 do append(&received, ..buf[:n])
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, len(received), 7)
	if len(received) == 7 {
		testing.expect_value(t, received[0], byte(0x8A))
		testing.expect_value(t, string(received[2:]), "alive")
	}
}
