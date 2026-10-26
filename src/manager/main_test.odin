// Tests for the heimdall CLI core helpers (src/manager/main.odin), plus the
// shared test infrastructure (temp dirs, in-test HTTP mock hub over real TCP).
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

manager_test_env_mutex: sync.Mutex

@(test)
test_manager_option_helpers :: proc(t: ^testing.T) {
	// MANAGER_ENROLL_VALUE_FLAGS went with the deleted enroll command, so this uses
	// a local flag list. The helper under test is general-purpose (`update` and
	// `logs` both pass their own lists), so the coverage is unchanged — only the
	// constant it used to borrow is gone.
	value_flags := []string{"--hub", "--config", "--token-file"}
	args := []string{"heimdall", "update", "v1.2.3", "--hub", "http://127.0.0.1:9"}
	testing.expect(t, manager_has_flag(args, "update"), "has_flag finds a bare subcommand token")
	testing.expect(t, manager_has_flag(args, "--hub"), "has_flag finds a flag")
	testing.expect(t, !manager_has_flag(args, "--follow"), "has_flag does not invent flags")
	testing.expect(t, manager_option_value(args, "--hub", "") == "http://127.0.0.1:9", "option_value returns the next token")
	testing.expect(t, manager_option_value(args, "--config", "/fallback") == "/fallback", "option_value falls back when absent")
	testing.expect(t, manager_first_positional(args, value_flags) == "v1.2.3", "positional token after subcommand")

	// A flag's VALUE must never be mistaken for the positional argument.
	flag_value_form := []string{"heimdall", "update", "--hub", "http://127.0.0.1:9", "--config", "/tmp/c.toml"}
	testing.expect(t, manager_first_positional(flag_value_form, value_flags) == "", "flag value must not be taken as positional")
}

@(test)
test_manager_json_helpers :: proc(t: ^testing.T) {
	b := strings.builder_make()
	manager_json_write_string(&b, "a\"b\\c\nd\te\x01")
	escaped := strings.to_string(b)
	testing.expect(t, escaped == "a\\\"b\\\\c\\nd\\te\\u0001", fmt.tprintf("json escape matches hub escaping: %s", escaped))

	body := `{"bridge_id":"brg_1","note":"say \"hi\"","empty":""}`
	testing.expect(t, manager_extract_json_string(body, "bridge_id", "x") == "brg_1", "plain value extract")
	testing.expect(t, manager_extract_json_string(body, "note", "x") == `say "hi"`, "escaped value is unescaped")
	testing.expect(t, manager_extract_json_string(body, "empty", "fallback") == "", "empty value extracts as empty string")
	testing.expect(t, manager_extract_json_string(body, "missing", "fallback") == "fallback", "missing key falls back")
	testing.expect(t, manager_json_unescape("a\\nb") == "a\nb", "unescape newline")
}

@(test)
test_manager_permissions_mode :: proc(t: ^testing.T) {
	testing.expect(t, manager_mode_string(manager_permissions_mode(os.Permissions{.Read_User, .Write_User})) == "0600", "0600 render")
	testing.expect(t, manager_mode_string(manager_permissions_mode(os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other})) == "0644", "0644 render")
	testing.expect(t, manager_mode_string(manager_permissions_mode(os.Permissions{.Read_User, .Write_User, .Execute_User})) == "0700", "0700 render")
}

@(test)
test_manager_path_helpers :: proc(t: ^testing.T) {
	testing.expect(t, manager_dir_of("/a/b/c") == "/a/b", "dir_of nested")
	testing.expect(t, manager_dir_of("/a") == "/", "dir_of top level")
	testing.expect(t, manager_dir_of("relative.toml") == ".", "dir_of bare name")
	testing.expect(t, manager_dir_of("/config.toml") == "/", "dir_of rooted file")

	testing.expect(t, manager_nearest_existing_dir("/nonexistent-heimdall-xyz/a/b") == "/", "nearest existing dir walks to /")

	tmp := manager_test_tmp_dir("paths")
	defer manager_test_cleanup(tmp)
	testing.expect(t, manager_write_probe(tmp), "write probe succeeds in a writable dir")
	testing.expect(t, !manager_write_probe(fmt.tprintf("%s/missing", tmp)), "write probe fails for missing dir")
}

@(test)
test_manager_hub_url_validation :: proc(t: ^testing.T) {
	testing.expect(t, manager_hub_url_supported("http://127.0.0.1:49322"), "http base ok")
	testing.expect(t, manager_hub_url_supported("https://hub.example.com"), "https base ok")
	testing.expect(t, manager_hub_url_supported("https://hub.example.com/"), "trailing slash tolerated")
	testing.expect(t, !manager_hub_url_supported("ftp://hub.example.com"), "non-http scheme rejected")
	testing.expect(t, !manager_hub_url_supported("http://"), "empty authority rejected")
	testing.expect(t, !manager_hub_url_supported("http://hub.example.com/path"), "path in base url rejected")
	testing.expect(t, !manager_hub_url_supported(""), "empty rejected")
}

@(test)
test_manager_line_number_parse :: proc(t: ^testing.T) {
	testing.expect(t, manager_parse_line_number("", 200) == 200, "empty -> fallback")
	testing.expect(t, manager_parse_line_number("50", 200) == 50, "number parsed")
	testing.expect(t, manager_parse_line_number("abc", 200) == 200, "garbage -> fallback")
	testing.expect(t, manager_parse_line_number("0", 200) == 200, "zero -> fallback")
	testing.expect(t, manager_parse_line_number("-3", 200) == 200, "negative -> fallback")
}

@(test)
test_manager_config_and_token_paths :: proc(t: ^testing.T) {
	sync.mutex_lock(&manager_test_env_mutex)
	defer sync.mutex_unlock(&manager_test_env_mutex)
	tmp := manager_test_tmp_dir("paths-home")
	defer manager_test_cleanup(tmp)
	previous := os.get_env("HEIMDALL_HOME", context.allocator)
	defer {
		if previous != "" do os.set_env("HEIMDALL_HOME", previous)
		else do os.unset_env("HEIMDALL_HOME")
	}
	os.set_env("HEIMDALL_HOME", tmp)

	config_path := manager_config_path([]string{"heimdall", "status"})
	testing.expect(t, config_path == fmt.tprintf("%s/config.toml", tmp), fmt.tprintf("default config path honors HEIMDALL_HOME: %s", config_path))
	token_path := manager_token_path([]string{"heimdall", "status"}, config_path)
	testing.expect(t, token_path == fmt.tprintf("%s/bridge-token", tmp), fmt.tprintf("default token path is sibling of config: %s", token_path))

	custom_token := fmt.tprintf("%s/custom-token", tmp)
	override := manager_token_path([]string{"heimdall", "enroll", "--token-file", custom_token}, config_path)
	testing.expect(t, override == custom_token, "--token-file override wins")

	other_config := fmt.tprintf("%s/other.toml", tmp)
	explicit_config := manager_config_path([]string{"heimdall", "enroll", "--config", other_config})
	testing.expect(t, explicit_config == other_config, "--config override wins")
}

@(test)
test_manager_bin_on_path :: proc(t: ^testing.T) {
	sync.mutex_lock(&manager_test_env_mutex)
	defer sync.mutex_unlock(&manager_test_env_mutex)
	tmp := manager_test_tmp_dir("path-bin")
	defer manager_test_cleanup(tmp)
	fake := fmt.tprintf("%s/fake-heimdall-bin", tmp)
	testing.expect(t, os.write_entire_file(fake, "#!/bin/sh\n") == nil, "write fake bin")

	previous := os.get_env("PATH", context.allocator)
	defer {
		if previous != "" do os.set_env("PATH", previous)
	}
	os.set_env("PATH", fmt.tprintf("%s:%s", tmp, previous))
	path, found := manager_bin_on_path("fake-heimdall-bin")
	testing.expect(t, found, "fake bin is found on the overridden PATH")
	testing.expect(t, path == fake, fmt.tprintf("resolved path is the fake bin: %s", path))
	_, missing_found := manager_bin_on_path("definitely-not-a-real-bin")
	testing.expect(t, !missing_found, "missing bin is not found")
	_, empty_found := manager_bin_on_path("")
	testing.expect(t, !empty_found, "empty bin name is rejected")
}

// ---- shared test helpers ----

manager_test_unique_counter: int

manager_test_unique :: proc() -> int {
	val := sync.atomic_add(&manager_test_unique_counter, 1) + 1
	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		return int(posix.getpid()) * 1000 + val
	}
	return val
}

manager_test_tmp_dir :: proc(suffix: string) -> string {
	dir := fmt.tprintf("/tmp/heimdall-manager-test-%s-%d", suffix, manager_test_unique())
	_ = os.make_directory_all(dir)
	return dir
}

manager_test_cleanup :: proc(dir: string) {
	_ = os.remove_all(dir)
}

manager_test_file_mode :: proc(path: string) -> int {
	fi, err := os.stat(path, context.allocator)
	if err != nil do return -1
	defer os.file_info_delete(fi, context.allocator)
	return manager_permissions_mode(fi.mode)
}

manager_test_argv_eq :: proc(argv, expected: []string) -> bool {
	if len(argv) != len(expected) do return false
	for i in 0 ..< len(argv) {
		if argv[i] != expected[i] do return false
	}
	return true
}

manager_test_argv_string :: proc(argv: []string) -> string {
	return strings.join(argv, " ")
}

// ---- in-test HTTP mock hub (real TCP; used by enroll/doctor tests) ----
//
// The mock thread does NO heap allocation: the response is prebuilt by the
// test thread in manager_test_mock_hub_start and requests are captured into
// fixed struct storage. Allocating inside the thread and freeing in the test
// thread would be flagged as a "bad free" by the test runner's tracker.

MANAGER_TEST_MOCK_MAX_REQUESTS :: 4
MANAGER_TEST_MOCK_REQUEST_CAPACITY :: 8192

Manager_Test_Mock_Hub :: struct {
	listener:       net.TCP_Socket,
	response:       string, // prebuilt in the test thread (temp memory)
	max_requests:   int,
	served:         int,
	request_data:   [MANAGER_TEST_MOCK_MAX_REQUESTS][MANAGER_TEST_MOCK_REQUEST_CAPACITY]byte,
	request_length: [MANAGER_TEST_MOCK_MAX_REQUESTS]int,
}

manager_test_loopback_listener :: proc() -> (net.TCP_Socket, int, bool) {
	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if err != nil do return 0, 0, false
	bound, berr := net.bound_endpoint(listener)
	if berr != nil {
		net.close(listener)
		return 0, 0, false
	}
	return listener, int(bound.port), true
}

// manager_test_mock_hub_start spawns a thread that serves up to `max_requests`
// HTTP requests on `listener`, answering each with `status`/`body`. Bare TCP
// connections (port probes) are accepted and dropped without a response so a
// probe does not consume a request slot. The caller must join the returned
// thread with manager_test_mock_hub_join and then free the mock.
manager_test_mock_hub_start :: proc(mock: ^Manager_Test_Mock_Hub, listener: net.TCP_Socket, status: int, body: string, max_requests := 1) -> ^thread.Thread {
	mock.listener = listener
	mock.max_requests = max_requests
	mock.response = fmt.tprintf(
		"HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		status,
		manager_test_mock_reason(status),
		len(body),
		body,
	)
	return thread.create_and_start_with_data(mock, manager_test_mock_hub_thread)
}

manager_test_mock_hub_join :: proc(mock: ^Manager_Test_Mock_Hub, handle: ^thread.Thread) {
	if handle != nil {
		thread.join(handle)
		thread.destroy(handle)
	}
	net.close(mock.listener)
}

manager_test_mock_hub_free :: proc(mock: ^Manager_Test_Mock_Hub) {
	free(mock)
}

// manager_test_mock_request returns the raw request served at `index` ("" when
// the mock served fewer requests).
manager_test_mock_request :: proc(mock: ^Manager_Test_Mock_Hub, index: int) -> string {
	if index < 0 || index >= mock.served do return ""
	return string(mock.request_data[index][:mock.request_length[index]])
}

manager_test_mock_hub_thread :: proc(data: rawptr) {
	mock := cast(^Manager_Test_Mock_Hub)data
	for mock.served < mock.max_requests {
		client, _, aerr := net.accept_tcp(mock.listener)
		if aerr != nil do return
		_ = net.set_option(client, .Receive_Timeout, 3 * time.Second)
		length := manager_test_mock_read_request(client, mock.request_data[mock.served][:])
		if length <= 0 {
			net.close(client)
			continue
		}
		mock.request_length[mock.served] = length
		mock.served += 1
		_, _ = net.send_tcp(client, transmute([]byte)mock.response)
		net.close(client)
	}
}

// manager_test_mock_read_request reads one HTTP request (headers plus
// Content-Length body) into `buffer` and returns its length, or 0 when the
// connection closed without sending a request.
manager_test_mock_read_request :: proc(client: net.TCP_Socket, buffer: []byte) -> int {
	total := 0
	header_end := -1
	for total < len(buffer) {
		n, err := net.recv_tcp(client, buffer[total:])
		if err != nil || n <= 0 do break
		total += n
		text := string(buffer[:total])
		if header_end < 0 {
			if idx := strings.index(text, "\r\n\r\n"); idx >= 0 do header_end = idx
		}
		if header_end >= 0 {
			// No Content-Length means no body (a GET), as the hub and bridge servers read it.
			content_length := max(manager_test_mock_content_length(text[:header_end]), 0)
			if total >= header_end + 4 + content_length do break
		}
	}
	if header_end < 0 do return 0
	return total
}

manager_test_mock_content_length :: proc(headers: string) -> int {
	text := headers
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "Content-Length:") || strings.has_prefix(line, "content-length:") {
			value := strings.trim_space(line[len("Content-Length:"):])
			if parsed, ok := strconv.parse_int(value); ok do return int(parsed)
		}
	}
	return -1
}

manager_test_mock_reason :: proc(status: int) -> string {
	switch status {
	case 200: return "OK"
	case 201: return "Created"
	case 401: return "Unauthorized"
	case 403: return "Forbidden"
	case 404: return "Not Found"
	}
	return "Status"
}
