package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core:thread"
import "core:strconv"
import "base:runtime"

model_test_destroy :: proc(models: ^[dynamic]Bridge_Discovered_Model) {
	for model in models { delete(model.model_id); delete(model.label); delete(model.resolved_model) }
	delete(models^)
}

@(test)
test_model_discovery_claude_correlation_and_aliases :: proc(t: ^testing.T) {
	models := make([dynamic]Bridge_Discovered_Model); defer model_test_destroy(&models)
	unrelated, _, _, _ := bridge_models_parse_reply("claude", `{"type":"control_response","response":{"request_id":"other","subtype":"success","response":{"models":[]}}}`, 2, &models)
	testing.expect(t, !unrelated, "an unrelated control response cannot complete discovery")
	matched, valid, cursor, _ := bridge_models_parse_reply("claude", `{"type":"control_response","response":{"request_id":"models","subtype":"success","response":{"models":[{"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus"},{"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default"}]}}}`, 2, &models)
	defer delete(cursor)
	testing.expect(t, matched && valid)
	if testing.expect_value(t, len(models), 2) {
		testing.expect_value(t, models[0].model_id, "opus")
		testing.expect_value(t, models[0].resolved_model, "claude-opus-5-5")
		testing.expect_value(t, models[1].model_id, "default")
	}
}

@(test)
test_model_discovery_codex_pages_and_invalid_entries :: proc(t: ^testing.T) {
	models := make([dynamic]Bridge_Discovered_Model); defer model_test_destroy(&models)
	matched, valid, cursor, _ := bridge_models_parse_reply("codex", `{"id":2,"error":null,"result":{"data":[{"model":"new-model","displayName":"New"},{"model":"hidden","hidden":true}],"nextCursor":"next"}}`, 2, &models)
	defer delete(cursor)
	testing.expect(t, matched && valid)
	testing.expect_value(t, cursor, "next")
	testing.expect_value(t, len(models), 1)
	_, valid, _, _ = bridge_models_parse_reply("codex", `{"id":3,"result":{"data":[{"model":"new-model"},{"model":"bad id"}],"nextCursor":null}}`, 3, &models)
	testing.expect(t, !valid, "invalid IDs invalidate a whole result, not silently disappear")
	matched, _, _, _ = bridge_models_parse_reply("codex", `{"id":2.5,"result":{"data":[]}}`, 2, &models)
	testing.expect(t, !matched, "fractional IDs cannot alias a pending request")
	_, valid, _, _ = bridge_models_parse_reply("codex", `{"id":3,"result":{"data":[],"nextCursor":123}}`, 3, &models)
	testing.expect(t, !valid, "malformed pagination must not produce a partial successful catalog")
}

@(test)
test_model_discovery_pi_qualification_and_empty_success :: proc(t: ^testing.T) {
	models := make([dynamic]Bridge_Discovered_Model); defer model_test_destroy(&models)
	_, valid, cursor, _ := bridge_models_parse_reply("pi", `{"id":"models","command":"get_available_models","success":true,"data":{"models":[{"provider":"anthropic","id":"same-id","name":"A"},{"provider":"openai-codex","id":"same-id","name":"B"}]}}`, 2, &models)
	defer delete(cursor)
	testing.expect(t, valid)
	if testing.expect_value(t, len(models), 2) {
		testing.expect_value(t, models[0].model_id, "anthropic/same-id")
		testing.expect_value(t, models[1].model_id, "openai-codex/same-id")
	}
	_, valid, _, _ = bridge_models_parse_reply("pi", `{"id":"models","command":"get_available_models","success":true,"data":{"models":[{"provider":"anthropic","id":""}]}}`, 2, &models)
	testing.expect(t, !valid)
	_, valid, _, _ = bridge_models_parse_reply("pi", `{"id":"models","command":"get_available_models","success":true,"data":{"models":[]}}`, 2, &models)
	testing.expect(t, valid, "an explicit empty configured list is a successful observation")
}

@(test)
test_model_discovery_copilot_policy_and_auth :: proc(t: ^testing.T) {
	models := make([dynamic]Bridge_Discovered_Model); defer model_test_destroy(&models)
	matched, valid, _, auth := bridge_models_parse_reply("copilot", `{"jsonrpc":"2.0","id":2,"error":{"message":"Not authenticated. Secret provider diagnostics must not be returned."}}`, 2, &models)
	testing.expect(t, matched && !valid && auth)
	_, policy_valid, cursor, _ := bridge_models_parse_reply("copilot", `{"id":2,"result":{"models":[{"id":"allowed","policy":{"state":"enabled"}},{"id":"blocked","policy":{"state":"disabled"}}]}}`, 2, &models)
	defer delete(cursor)
	testing.expect(t, policy_valid)
	if testing.expect_value(t, len(models), 1) do testing.expect_value(t, models[0].model_id, "allowed")
}

@(test)
test_model_discovery_agy_ids_and_output_limits :: proc(t: ^testing.T) {
	models := make([dynamic]Bridge_Discovered_Model); defer model_test_destroy(&models)
	testing.expect(t, bridge_models_parse_agy("gemini-new-high\tGemini New (High)\r\nclaude-new-medium  Claude New (Medium)\n", &models))
	if testing.expect_value(t, len(models), 2) {
		testing.expect_value(t, models[0].model_id, "gemini-new-high")
		testing.expect_value(t, models[1].label, "Claude New (Medium)")
	}
	testing.expect(t, !bridge_models_parse_agy("Please log in\n", &models), "diagnostic text is not a model list")
	for i in len(models)..<BRIDGE_MODEL_LIMIT do testing.expect(t, bridge_models_append(&models, fmt.tprintf("m-%d", i), "", ""))
	testing.expect(t, !bridge_models_append(&models, "one-too-many", "", ""))
}

@(test)
test_model_discovery_failure_retains_snapshot_and_empty_replaces :: proc(t: ^testing.T) {
	old := Bridge_Provider_Models{provider = "pi", has_snapshot = true, models = []Bridge_Discovered_Model{{"upstream/old", "Old", ""}}, models_source = "pi_rpc", models_checked_at = "old", binary_path = "old-path"}
	value := bridge_models_clone(old); defer bridge_models_destroy(&value)
	partial := []Bridge_Discovered_Model{{"partial/new", "New", ""}}
	bridge_models_apply_probe(&value, partial, "timeout", "new-path", "new-version", "attempt")
	testing.expect_value(t, value.models[0].model_id, "upstream/old")
	testing.expect_value(t, value.models_checked_at, "old")
	testing.expect_value(t, value.binary_path, "old-path")
	testing.expect_value(t, value.models_attempted_at, "attempt")
	bridge_models_apply_probe(&value, nil, "success", "new-path", "new-version", "new")
	testing.expect(t, value.has_snapshot && len(value.models) == 0, "empty success replaces prior snapshot")
	testing.expect_value(t, value.models_checked_at, "new")
	bytes, err := json.marshal(value, allocator = context.temp_allocator)
	testing.expect(t, err == nil && strings.contains(string(bytes), `"has_snapshot":true`))
}

model_test_fixture :: proc(t: ^testing.T, body: string) -> (string, string) {
	dir := fmt.aprintf("%s/.cache/heimdall-tests/model-probe-%d", os.get_env("HOME", context.temp_allocator), time.to_unix_nanoseconds(time.now()))
	if !testing.expect(t, bridge_make_directory_all(dir) == nil) { delete(dir); return "", "" }
	path := strings.concatenate({dir, "/fixture.sh"})
	if !testing.expect(t, os.write_entire_file(path, strings.concatenate({"#!/bin/sh\n", body}, context.temp_allocator)) == nil) { delete(path); delete(dir); return "", "" }
	if !testing.expect(t, os.chmod(path, {.Read_User, .Write_User, .Execute_User}) == nil) { delete(path); delete(dir); return "", "" }
	return path, dir
}

@(test)
test_model_discovery_process_pagination_and_cleanup :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows do return
	path, dir := model_test_fixture(t, `IFS= read -r init
printf '%s' "$$" > probe.pid
printf '%s\n' '{"id":1,"result":{}}'
IFS= read -r initialized
IFS= read -r first
printf '%s\n' '{"method":"notification","params":{}}' '{"id":2,"result":{"data":[{"model":"first","displayName":"First"}],"nextCursor":"next"}}'
IFS= read -r second
case "$second" in *'"cursor":"next"'*) ;; *) exit 1;; esac
printf '%s\n' '{"id":3,"result":{"data":[{"model":"second","displayName":"Second"}],"nextCursor":null}}'
while :; do :; done
`)
	if path == "" do return
	defer { os.remove(fmt.tprintf("%s/probe.pid", dir)); os.remove(path); os.remove(dir); delete(path); delete(dir) }
	models, state := bridge_models_probe("codex", path, 2*time.Second, dir)
	defer model_test_destroy(&models)
	testing.expect_value(t, state, "success")
	testing.expect_value(t, len(models), 2)
	pid_text, err := os.read_entire_file(fmt.tprintf("%s/probe.pid", dir), context.temp_allocator)
	testing.expect(t, err == nil)
	pid, valid := strconv.parse_int(string(pid_text))
	testing.expect(t, valid && !bridge_os_pid_alive(pid), "the metadata child is killed and reaped after its final response")
}

@(test)
test_model_discovery_process_agy_exit_and_timeout :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows do return
	path, dir := model_test_fixture(t, "printf 'model-high\\tModel (High)\\n'\n")
	if path == "" do return
	defer { os.remove(path); os.remove(dir); delete(path); delete(dir) }
	models, state := bridge_models_probe("antigravity", path, 2*time.Second, dir)
	defer model_test_destroy(&models)
	testing.expect_value(t, state, "success")
	if testing.expect_value(t, len(models), 1) do testing.expect_value(t, models[0].model_id, "model-high")
	testing.expect(t, os.write_entire_file(path, "#!/bin/sh\nwhile :; do :; done\n") == nil)
	start := time.now()
	timed, timed_state := bridge_models_probe("claude", path, 30*time.Millisecond, dir)
	defer model_test_destroy(&timed)
	testing.expect_value(t, timed_state, "timeout")
	testing.expect(t, time.diff(start, time.now()) < 2*time.Second, "silent process must not outlive its deadline")
}

@(test)
test_model_discovery_explicit_command_and_empty_filter :: proc(t: ^testing.T) {
	stage1, ok := bridge_command_spec("provider_discover")
	stage2, ok2 := bridge_command_spec("provider_models_discover")
	testing.expect(t, ok && ok2 && stage1.timeout_ms == 10_000 && stage2.timeout_ms == 30_000)
	testing.expect(t, !stage2.retry_safe, "model commands cannot be automatically retried")
	results := bridge_models_refresh(nil)
	defer delete(results)
	testing.expect_value(t, len(results), 0)
}

@(test)
test_model_discovery_worker_snapshot_ownership :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows do return
	path, dir := model_test_fixture(t, "printf 'model-high\\tModel (High)\\n'\n")
	if path == "" do return
	defer { os.remove(path); os.remove(dir); delete(path); delete(dir) }
	job := Bridge_Model_Job{provider = "antigravity", path = path, version = "test", working_dir = dir,
		deadline_ns = time.to_unix_nanoseconds(time.now()) + i64(2*time.Second),
		previous = bridge_models_clone({provider = "antigravity"}, runtime.default_allocator())}
	worker := thread.create(bridge_models_refresh_worker)
	worker.data = rawptr(&job)
	thread.start(worker); thread.join(worker); thread.destroy(worker)
	defer bridge_models_destroy(&job.result, runtime.default_allocator())
	testing.expect_value(t, job.result.models_state, "success")
	testing.expect(t, job.result.has_snapshot && job.result.models_checked_at != "")
	if testing.expect_value(t, len(job.result.models), 1) do testing.expect_value(t, job.result.models[0].model_id, "model-high")
	clone := bridge_models_clone(job.result); defer bridge_models_destroy(&clone)
	testing.expect_value(t, clone.version_text, "test")
}

@(test)
test_model_discovery_process_framing_and_output_limit :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows do return
	path, dir := model_test_fixture(t, `body='{"id":99,"result":{"models":[]}}'
printf 'Content-Length: %d\r\n\r\n%s' "${#body}" "$body"
body='{"id":2,"result":{"models":[{"id":"new","name":"New model"}]}}'
printf 'Content-Length: %d\r\n\r\n%s' "${#body}" "$body"
while :; do :; done
`)
	if path == "" do return
	defer { os.remove(path); os.remove(dir); delete(path); delete(dir) }
	models, state := bridge_models_probe("copilot", path, 2*time.Second, dir)
	defer model_test_destroy(&models)
	testing.expect_value(t, state, "success")
	if testing.expect_value(t, len(models), 1) do testing.expect_value(t, models[0].model_id, "new")
	testing.expect(t, os.write_entire_file(path, "#!/bin/sh\nprintf '%01000000d' 0\nprintf '%01000000d' 0\nwhile :; do :; done\n") == nil)
	large, large_state := bridge_models_probe("claude", path, 2*time.Second, dir)
	defer model_test_destroy(&large)
	testing.expect_value(t, large_state, "output_limit")
}
