package http_client
import "core:testing"
import "core:net"
import "core:fmt"
import "core:thread"
import "core:time"

Deadline_Trickle :: struct { listener: net.TCP_Socket, closed: bool }
deadline_trickle_thread :: proc(data: rawptr) {
    f := (^Deadline_Trickle)(data)
    client, _, err := net.accept_tcp(f.listener)
    if err != nil do return
    defer net.close(client)
    buf: [4096]byte
    _ = net.set_option(client, .Receive_Timeout, time.Second)
    _, _ = net.recv_tcp(client, buf[:])
    header := "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n"
    _, _ = net.send_tcp(client, transmute([]byte)header)
    for _ in 0..<12 {
        time.sleep(20*time.Millisecond)
        if _, err := net.send_tcp(client, []byte{'x'}); err != nil do break
    }
    f.closed = true
}
@(test)
deadline_bounds_slow_trickle_across_all_reads :: proc(t: ^testing.T) {
    listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
    if !testing.expect(t, err == nil) do return
    defer net.close(listener)
    bound, _ := net.bound_endpoint(listener)
    f := Deadline_Trickle{listener = listener}
    worker := thread.create_and_start_with_data(&f, deadline_trickle_thread)
    defer { thread.join(worker); thread.destroy(worker) }
    started := time.tick_now()
    resp, ok := request_with_headers_deadline("GET", fmt.tprintf("http://127.0.0.1:%d", bound.port), "/", "", nil, 80)
    defer delete(resp.body)
    elapsed := time.tick_since(started)
    testing.expect(t, !ok)
    testing.expect(t, resp.may_have_sent, "a lost/truncated response fences unsafe POST replay")
    testing.expect(t, elapsed >= 50*time.Millisecond && elapsed < 300*time.Millisecond)
}
@(test)
deadline_positive_complete_response_and_zero_budget :: proc(t: ^testing.T) {
    response := http_test_response(200, "OK", "", "complete")
    mock, port, worker := http_test_start_mock(t, []string{response})
    if worker == nil do return
    defer http_test_mock_join(mock, worker)
    resp, ok := request_with_headers_deadline("GET", fmt.tprintf("http://127.0.0.1:%d", port), "/", "", nil, 1000)
    defer delete(resp.body)
    testing.expect(t, ok && resp.status == 200 && resp.body == "complete")
    _, granted := request_with_headers_deadline("GET", "http://localhost", "/", "", nil, 0)
    testing.expect(t, !granted)
}
