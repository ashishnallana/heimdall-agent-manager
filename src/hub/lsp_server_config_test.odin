package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import api_http "odin_test:hub/transport/http"

// make_cfg is a test helper that builds a minimal Lsp_Server_Config.
// It does NOT allocate heap strings — the literals live in the test binary's
// read-only segment, so the tracking allocator never sees them.  Do not call
// lsp_server_config_destroy on values produced here.
@(private)
make_cfg :: proc(language, dir_prefix: string, dir_pattern: string = "", file_extensions: string = "") -> domain.Lsp_Server_Config {
	return domain.Lsp_Server_Config{
		config_id       = "id",
		language        = language,
		dir_prefix      = dir_prefix,
		dir_pattern     = dir_pattern,
		file_extensions = file_extensions,
		cmd             = "lsp",
	}
}

// --- resolution tests ---

// No configs at all — must return false.
@(test)
test_lsp_resolve_no_configs :: proc(t: ^testing.T) {
	_, found := domain.lsp_server_config_resolve(nil, "/work/main.go")
	testing.expect(t, !found, "expected no match with empty config slice")
}

// Only a language default (dir_prefix="") — must match any path.
@(test)
test_lsp_resolve_default_only :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{make_cfg("go", "")}
	got, found := domain.lsp_server_config_resolve(configs, "/work/main.go")
	testing.expect(t, found, "expected default to match")
	testing.expect(t, got.dir_prefix == "", "expected the default row")
}

// One specific override — it must win over the default.
@(test)
test_lsp_resolve_one_override :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", ""),
		make_cfg("go", "/work/project"),
	}
	got, found := domain.lsp_server_config_resolve(configs, "/work/project/main.go")
	testing.expect(t, found, "expected a match")
	testing.expect(t, got.dir_prefix == "/work/project", "override must beat default")
}

// File outside the override directory — must fall back to default.
@(test)
test_lsp_resolve_fallback_to_default :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", ""),
		make_cfg("go", "/work/project"),
	}
	got, found := domain.lsp_server_config_resolve(configs, "/home/user/other.go")
	testing.expect(t, found, "expected default match for path outside override")
	testing.expect(t, got.dir_prefix == "", "expected default row for unrelated path")
}

// Nested overrides — the LONGER prefix must win.
@(test)
test_lsp_resolve_nested_overrides :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", ""),
		make_cfg("go", "/work"),
		make_cfg("go", "/work/project"),
		make_cfg("go", "/work/project/pkg"),
	}
	got, found := domain.lsp_server_config_resolve(configs, "/work/project/pkg/types.go")
	testing.expect(t, found, "expected match for nested overrides")
	testing.expect(t, got.dir_prefix == "/work/project/pkg", "longest prefix must win")
}

// Sibling directory boundary — /work/exp must NOT match /work/experiment/main.go.
@(test)
test_lsp_resolve_sibling_dir_no_match :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", "/work/exp"),
	}
	_, found := domain.lsp_server_config_resolve(configs, "/work/experiment/main.go")
	testing.expect(t, !found, "/work/exp must not match /work/experiment/main.go (path boundary)")
}

// Sibling directory — /work/exp MUST match /work/exp/main.go.
@(test)
test_lsp_resolve_exact_prefix_matches :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", "/work/exp"),
	}
	got, found := domain.lsp_server_config_resolve(configs, "/work/exp/main.go")
	testing.expect(t, found, "/work/exp must match /work/exp/main.go")
	testing.expect(t, got.dir_prefix == "/work/exp", "expected the /work/exp row")
}

// Exact match (file_path == dir_prefix with no trailing slash) must still match.
@(test)
test_lsp_resolve_exact_path_match :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", "/work/project"),
	}
	got, found := domain.lsp_server_config_resolve(configs, "/work/project")
	testing.expect(t, found, "exact path match (no trailing slash) must work")
	testing.expect(t, got.dir_prefix == "/work/project", "expected the row")
}

// Boundary rejection with fallback: /work/exp must NOT match /work/experiment/main.go
// but the language default must still be returned (not "no match").
@(test)
test_lsp_resolve_boundary_fallback_to_default :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", ""),
		make_cfg("go", "/work/exp"),
	}
	got, found := domain.lsp_server_config_resolve(configs, "/work/experiment/main.go")
	testing.expect(t, found, "default must match when override is rejected by path boundary")
	testing.expect(t, got.dir_prefix == "", "expected default row (not the /work/exp override)")
}

// A dir_prefix with a trailing slash (what old/buggy code stores) can NEVER resolve,
// because the path-boundary check reads file_path[len(prefix)] which is already past
// the '/' separator. The create handler must normalize by stripping trailing slashes.
// This test documents that invariant and acts as a regression guard.
@(test)
test_lsp_resolve_trailing_slash_prefix_never_matches :: proc(t: ^testing.T) {
	// Simulate what the old code (without normalization) would store.
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", ""),
		make_cfg("go", "/work/project/"), // single trailing slash — invalid stored value
	}
	got, found := domain.lsp_server_config_resolve(configs, "/work/project/main.go")
	testing.expect(t, found, "default must still match when override has trailing slash")
	testing.expect(t, got.dir_prefix == "", "trailing-slash override must not win (boundary check fails)")
}

// A dir_prefix with MULTIPLE trailing slashes also silently misses — documents that
// the handler must strip ALL trailing slashes (strings.trim_right, not a single chop).
@(test)
test_lsp_resolve_double_trailing_slash_prefix_never_matches :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", ""),
		make_cfg("go", "/work/project//"), // double trailing slash — still invalid
	}
	got, found := domain.lsp_server_config_resolve(configs, "/work/project/main.go")
	testing.expect(t, found, "default must still match when override has double trailing slash")
	testing.expect(t, got.dir_prefix == "", "double-trailing-slash override must not win")
}

// --- glob pattern matching tests ---

@(test)
test_lsp_glob_match_single_and_recursive :: proc(t: ^testing.T) {
	// Single '*' matches within path segment, does not cross '/'
	testing.expect(t, domain.lsp_path_glob_match("/work/*/main.go", "/work/foo/main.go"), "* matches segment")
	testing.expect(t, !domain.lsp_path_glob_match("/work/*/main.go", "/work/foo/bar/main.go"), "* must not cross slash")
	testing.expect(t, !domain.lsp_path_glob_match("/work/*/main.go", "/work/main.go"), "* requires segment")

	// '**' matches across slashes
	testing.expect(t, domain.lsp_path_glob_match("/work/**", "/work/foo/bar/main.go"), "** matches deep path")
	testing.expect(t, domain.lsp_path_glob_match("/work/**", "/work/main.go"), "** matches shallow path")
	testing.expect(t, domain.lsp_path_glob_match("/work/**", "/work"), "** matches directory root")
	testing.expect(t, domain.lsp_path_glob_match("**/main.go", "/work/foo/main.go"), "leading ** matches path")
	testing.expect(t, domain.lsp_path_glob_match("**/main.go", "main.go"), "leading ** matches root file")

	// Sample Fig pattern
	fig_pat := "/google/src/cloud/*/*/google3/**"
	testing.expect(t, domain.lsp_path_glob_match(fig_pat, "/google/src/cloud/tanmayvijay/heimdall/google3/experimental/main.go"), "fig pattern matches deep file")
	testing.expect(t, domain.lsp_path_glob_match(fig_pat, "/google/src/cloud/user/ws/google3/BUILD"), "fig pattern matches BUILD in google3")
	testing.expect(t, domain.lsp_path_glob_match(fig_pat, "/google/src/cloud/user/ws/google3"), "fig pattern matches google3 dir")
	testing.expect(t, !domain.lsp_path_glob_match(fig_pat, "/google/src/cloud/user/google3/main.go"), "fig pattern requires 2 wildcard segments")
	testing.expect(t, !domain.lsp_path_glob_match(fig_pat, "/google/src/head/tanmayvijay/heimdall/google3/main.go"), "fig pattern rejects non-cloud")
}

// --- multi-language and file extension matching tests ---

@(test)
test_lsp_matches_multi_language_and_wildcard :: proc(t: ^testing.T) {
	// Wildcard "*" language
	wild_cfg := make_cfg("*", "")
	testing.expect(t, domain.lsp_server_config_matches_language_or_ext(wild_cfg, "go", "/work/main.go"), "* matches go")
	testing.expect(t, domain.lsp_server_config_matches_language_or_ext(wild_cfg, "rust", "/work/lib.rs"), "* matches rust")
	testing.expect(t, domain.lsp_server_config_matches_language_or_ext(wild_cfg, "", "/work/unknown"), "* matches empty language")

	// Comma-separated list with whitespace
	multi_cfg := make_cfg("go, cpp, java, python, proto, typescript", "")
	testing.expect(t, domain.lsp_server_config_matches_language_or_ext(multi_cfg, "go", "/work/f"), "matches go")
	testing.expect(t, domain.lsp_server_config_matches_language_or_ext(multi_cfg, "cpp", "/work/f"), "matches cpp")
	testing.expect(t, domain.lsp_server_config_matches_language_or_ext(multi_cfg, "CPP", "/work/f"), "case insensitive matches CPP")
	testing.expect(t, domain.lsp_server_config_matches_language_or_ext(multi_cfg, "Java", "/work/f"), "case insensitive matches Java")
	testing.expect(t, domain.lsp_server_config_matches_language_or_ext(multi_cfg, "proto", "/work/f"), "matches proto")
	testing.expect(t, domain.lsp_server_config_matches_language_or_ext(multi_cfg, "typescript", "/work/f"), "matches typescript")
	testing.expect(t, !domain.lsp_server_config_matches_language_or_ext(multi_cfg, "rust", "/work/f"), "does not match rust")
	testing.expect(t, !domain.lsp_server_config_matches_language_or_ext(multi_cfg, "py", "/work/f"), "does not partial-match py for python")
}

@(test)
test_lsp_matches_file_extensions :: proc(t: ^testing.T) {
	ext_cfg := make_cfg("ciderlsp", "", "", ".go, .cc, .cpp, .java, .py, .proto, .textpb")

	// Language differs / unknown, but extension matches
	testing.expect(t, domain.lsp_server_config_matches_language_or_ext(ext_cfg, "unknown", "/work/service.proto"), "matches .proto extension")
	testing.expect(t, domain.lsp_server_config_matches_language_or_ext(ext_cfg, "other", "/work/BUILD.textpb"), "matches .textpb extension")
	testing.expect(t, domain.lsp_server_config_matches_language_or_ext(ext_cfg, "c++", "/work/main.cc"), "matches .cc extension")
	testing.expect(t, domain.lsp_server_config_matches_language_or_ext(ext_cfg, "", "/work/main.CPP"), "case-insensitive extension match")
	testing.expect(t, !domain.lsp_server_config_matches_language_or_ext(ext_cfg, "other", "/work/main.rs"), "rejects unmatched extension")
	testing.expect(t, !domain.lsp_server_config_matches_language_or_ext(ext_cfg, "other", "/work/noext"), "rejects file without extension")

	// Extension configured without leading dots
	nodot_cfg := make_cfg("ciderlsp", "", "", "go, cc, cpp")
	testing.expect(t, domain.lsp_server_config_matches_language_or_ext(nodot_cfg, "other", "/work/main.go"), "matches extension configured without leading dot")
}

// --- pattern resolution and precedence tests ---

@(test)
test_lsp_resolve_dir_pattern_matches :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", "", "/google/src/cloud/*/*/google3/**"),
	}
	got, found := domain.lsp_server_config_resolve(configs, "/google/src/cloud/tanmay/ws/google3/foo.go")
	testing.expect(t, found, "dir_pattern should match")
	testing.expect_value(t, got.dir_pattern, "/google/src/cloud/*/*/google3/**")

	_, not_found := domain.lsp_server_config_resolve(configs, "/other/work/main.go")
	testing.expect(t, !not_found, "dir_pattern should not match unrelated path")
}

@(test)
test_lsp_resolve_dir_pattern_beats_default :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", "", "", ""),                                 // global default
		make_cfg("go", "", "/google/src/cloud/*/*/google3/**", ""), // pattern match
	}
	// Matching pattern path
	got1, found1 := domain.lsp_server_config_resolve(configs, "/google/src/cloud/tanmay/ws/google3/foo.go")
	testing.expect(t, found1, "match found")
	testing.expect_value(t, got1.dir_pattern, "/google/src/cloud/*/*/google3/**")

	// Path outside pattern falls back to default
	got2, found2 := domain.lsp_server_config_resolve(configs, "/home/user/code/main.go")
	testing.expect(t, found2, "default match found")
	testing.expect_value(t, got2.dir_pattern, "")
	testing.expect_value(t, got2.dir_prefix, "")
}

@(test)
test_lsp_resolve_literal_prefix_beats_dir_pattern :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", "", "", ""),                                            // default
		make_cfg("go", "", "/google/src/cloud/*/*/google3/**", ""),            // pattern
		make_cfg("go", "/google/src/cloud/tanmay/ws/google3/special", "", ""), // literal dir_prefix
	}

	// Inside literal dir_prefix: literal wins over pattern
	got1, found1 := domain.lsp_server_config_resolve(configs, "/google/src/cloud/tanmay/ws/google3/special/main.go")
	testing.expect(t, found1, "match found")
	testing.expect_value(t, got1.dir_prefix, "/google/src/cloud/tanmay/ws/google3/special")

	// Inside pattern but outside literal prefix: pattern wins over default
	got2, found2 := domain.lsp_server_config_resolve(configs, "/google/src/cloud/tanmay/ws/google3/other/main.go")
	testing.expect(t, found2, "match found")
	testing.expect_value(t, got2.dir_pattern, "/google/src/cloud/*/*/google3/**")
	testing.expect_value(t, got2.dir_prefix, "")

	// Outside both: default wins
	got3, found3 := domain.lsp_server_config_resolve(configs, "/home/tanmay/other.go")
	testing.expect(t, found3, "default match found")
	testing.expect_value(t, got3.dir_prefix, "")
	testing.expect_value(t, got3.dir_pattern, "")
}

@(test)
test_lsp_resolve_full_precedence_chain :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", "", "", ""),                // default (Model 1)
		make_cfg("go", "", "/work/**", ""),        // pattern (Model 2)
		make_cfg("go", "/work/proj", "", ""),      // shorter prefix (Model 3)
		make_cfg("go", "/work/proj/deep", "", ""), // longest prefix (Model 3 winner)
	}

	// Longest prefix wins
	got1, f1 := domain.lsp_server_config_resolve(configs, "/work/proj/deep/file.go")
	testing.expect(t, f1, "found")
	testing.expect_value(t, got1.dir_prefix, "/work/proj/deep")

	// Shorter prefix wins when deep doesn't match
	got2, f2 := domain.lsp_server_config_resolve(configs, "/work/proj/file.go")
	testing.expect(t, f2, "found")
	testing.expect_value(t, got2.dir_prefix, "/work/proj")

	// Pattern wins when prefix doesn't match
	got3, f3 := domain.lsp_server_config_resolve(configs, "/work/other/file.go")
	testing.expect(t, f3, "found")
	testing.expect_value(t, got3.dir_pattern, "/work/**")
	testing.expect_value(t, got3.dir_prefix, "")

	// Default wins when outside pattern
	got4, f4 := domain.lsp_server_config_resolve(configs, "/opt/file.go")
	testing.expect(t, f4, "found")
	testing.expect_value(t, got4.dir_prefix, "")
	testing.expect_value(t, got4.dir_pattern, "")
}

// --- HTTP handler roundtrip and dir_prefix "/" rejection tests ---

@(test)
test_lsp_server_config_slash_dir_prefix_rejected :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-lsp-handler-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{
		database_path        = db_path,
		migrations_dir       = "src/hub/repository/sqlite/migrations",
		auto_provision_users = true,
		paddle_environment   = "sandbox",
	})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)

	alice := hub_test_user_headers(&graph, "alice")

	bridge_id, _, enroll_ok := device_enroll_test_bridge(&graph, alice[:], "Alice Bridge")
	testing.expect(t, enroll_ok, "device-flow bridge provisioning failed")
	testing.expect(t, bridge_id != "", "bridge_id must be non-empty after enrollment")

	lsp_path := fmt.tprintf("/api/v1/bridges/%s/lsp-servers", bridge_id)

	// Step 1: Create a language default (dir_prefix="")
	default_created := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "POST",
		path        = lsp_path,
		body        = `{"language":"go","cmd":"gopls","dir_prefix":""}`,
		request_id  = "req_lsph_3",
		remote_addr = "127.0.0.1",
		headers     = alice[:],
	})
	testing.expect(t, default_created.status == 200, "creating language default must succeed")

	default_config_id := ""
	if idx := strings.index(default_created.body, "\"config_id\":\""); idx >= 0 {
		rest := default_created.body[idx + len("\"config_id\":\""):]
		if end := strings.index_byte(rest, '"'); end >= 0 do default_config_id = rest[:end]
	}
	testing.expect(t, default_config_id != "", "default config_id must be non-empty")

	// Step 2: POST dir_prefix="/" must be rejected with 400
	slash_rejected := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "POST",
		path        = lsp_path,
		body        = `{"language":"go","cmd":"gopls-root","dir_prefix":"/"}`,
		request_id  = "req_lsph_4",
		remote_addr = "127.0.0.1",
		headers     = alice[:],
	})
	testing.expect(t, slash_rejected.status == 400, `POST dir_prefix="/" must return 400`)

	// Step 3: POST dir_prefix="///" must also be rejected with 400
	multi_slash_rejected := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "POST",
		path        = lsp_path,
		body        = `{"language":"go","cmd":"gopls-root","dir_prefix":"///"}`,
		request_id  = "req_lsph_5",
		remote_addr = "127.0.0.1",
		headers     = alice[:],
	})
	testing.expect(t, multi_slash_rejected.status == 400, `POST dir_prefix="///" must return 400`)

	// Step 4: The default row must survive both rejections unchanged
	list_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "GET",
		path        = lsp_path,
		request_id  = "req_lsph_6",
		remote_addr = "127.0.0.1",
		headers     = alice[:],
	})
	testing.expect(t, list_resp.status == 200, "list must succeed")
	testing.expect(t, strings.contains(list_resp.body, default_config_id), "default config_id must be unchanged after rejected POSTs")
	testing.expect(t, strings.contains(list_resp.body, "\"cmd\":\"gopls\""), "default row cmd must be unchanged")
	testing.expect(t, strings.count(list_resp.body, "\"config_id\"") == 1, "exactly one config must exist after rejections")
}

@(test)
test_lsp_server_config_dir_pattern_and_multilang_rest_roundtrip :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-lsp-pattern-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{
		database_path        = db_path,
		migrations_dir       = "src/hub/repository/sqlite/migrations",
		auto_provision_users = true,
		paddle_environment   = "sandbox",
	})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)

	alice := hub_test_user_headers(&graph, "alice")

	bridge_id, _, enroll_ok := device_enroll_test_bridge(&graph, alice[:], "Alice Bridge")
	testing.expect(t, enroll_ok, "device-flow bridge provisioning failed")
	testing.expect(t, bridge_id != "", "bridge_id must be non-empty")

	lsp_path := fmt.tprintf("/api/v1/bridges/%s/lsp-servers", bridge_id)

	create_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "POST",
		path        = lsp_path,
		body        = `{"language":"go, cpp, proto","cmd":"ciderlsp","file_extensions":".go, .cc, .proto","dir_pattern":"/google/src/cloud/*/*/google3/**"}`,
		request_id  = "req_lspp_3",
		remote_addr = "127.0.0.1",
		headers     = alice[:],
	})
	testing.expect(t, create_resp.status == 200, "create config with pattern must succeed")
	testing.expect(t, strings.contains(create_resp.body, `"dir_pattern":"/google/src/cloud/*/*/google3/**"`), "response must contain dir_pattern")

	resolve_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "GET",
		path        = fmt.tprintf("/api/v1/bridges/%s/lsp-servers/resolve", bridge_id),
		query       = "language=proto&path=/google/src/cloud/tanmay/ws/google3/service.proto",
		request_id  = "req_lspp_4",
		remote_addr = "127.0.0.1",
		headers     = alice[:],
	})
	testing.expect(t, resolve_resp.status == 200, "resolve must succeed for matching proto and pattern")
	testing.expect(t, strings.contains(resolve_resp.body, `"cmd":"ciderlsp"`), "resolved server cmd matches")

	resolve_ext_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "GET",
		path        = fmt.tprintf("/api/v1/bridges/%s/lsp-servers/resolve", bridge_id),
		query       = "language=unknown&path=/google/src/cloud/tanmay/ws/google3/main.cc",
		request_id  = "req_lspp_5",
		remote_addr = "127.0.0.1",
		headers     = alice[:],
	})
	testing.expect(t, resolve_ext_resp.status == 200, "resolve must succeed via file extension .cc")

	resolve_outside_resp := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "GET",
		path        = fmt.tprintf("/api/v1/bridges/%s/lsp-servers/resolve", bridge_id),
		query       = "language=proto&path=/other/path/service.proto",
		request_id  = "req_lspp_6",
		remote_addr = "127.0.0.1",
		headers     = alice[:],
	})
	testing.expect(t, resolve_outside_resp.status == 404, "resolve outside pattern without default must return 404")
}
