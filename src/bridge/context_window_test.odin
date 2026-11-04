package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// Context-window resolution (context_window.odin): shipped config parsing and
// regex order, alias via resolved_model, override precedence + persistence,
// minimum validation, the default, the context_window_op frame and the
// accumulator snapshot fields.

// ctxwin_scratch isolates the override file in a per-process scratch data dir
// and returns a restore proc. Callers hold bridge_test_config_mutex.
@(private = "file")
ctxwin_scratch_begin :: proc(tag: string) -> (saved, scratch: string) {
	saved = bridge_config.data_dir
	scratch = fmt.aprintf("%s/.cache/heimdall-tests/ctxwin-%s-%d", os.get_env("HOME", context.temp_allocator), tag, os.get_pid())
	_ = os.remove_all(scratch)
	bridge_config.data_dir = scratch
	bridge_context_window_reload_for_test()
	return
}

@(private = "file")
ctxwin_scratch_end :: proc(saved, scratch: string) {
	_ = os.remove_all(scratch)
	bridge_config.data_dir = saved
	bridge_context_window_reload_for_test()
	delete(scratch)
}

// ctxwin_forget_launch hides a test instance from bridge_ext_context_window_instances
// so its reported window cannot leak into other tests' settings lists.
ctxwin_forget_launch :: proc(instance_id: string) {
	sync.mutex_lock(&bridge_ext_mutex); defer sync.mutex_unlock(&bridge_ext_mutex)
	for &s in bridge_ext_states {
		if s.agent_instance_id != instance_id do continue
		delete(s.launch_provider, runtime.heap_allocator())
		s.launch_provider = ""
	}
}

@(test)
test_ctxwin_shipped_config_parses_every_entry :: proc(t: ^testing.T) {
	c: Bridge_Context_Window_Config
	testing.expect(t, bridge_context_window_parse_config(BRIDGE_CONTEXT_WINDOWS_EMBEDDED, &c))
	defer bridge_context_window_config_destroy(&c)
	testing.expect_value(t, len(c.entries), 17) // no shipped regex may fail to compile
	testing.expect_value(t, c.default_window, i64(200_000))
	testing.expect_value(t, c.default_window, i64(BRIDGE_EXT_TOKEN_DEFAULT_WINDOW))
	testing.expect_value(t, c.warn_pct, 40)
	testing.expect_value(t, c.rollover_pct, 70)
}

@(test)
test_ctxwin_regex_match_order_and_default :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved, scratch := ctxwin_scratch_begin("order")
	defer ctxwin_scratch_end(saved, scratch)

	r := bridge_context_window_resolve("claude", "claude-opus-4-6")
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{200_000, .Config})
	// The [1m] entry is listed first, so it wins over the 4-6 entry.
	r = bridge_context_window_resolve("claude", "claude-opus-4-6[1m]")
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{1_000_000, .Config})
	r = bridge_context_window_resolve("claude", "sonnet[1m]")
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{1_000_000, .Config})
	// Aliases are anchored too: a suffix or prefix is not the alias.
	r = bridge_context_window_resolve("claude", "opus-ish")
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{200_000, .Default})
	r = bridge_context_window_resolve("codex", "gpt-5.5-codex")
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{258_400, .Config})
	// Anchored: gpt-.* must match the whole id, and entries are per provider.
	r = bridge_context_window_resolve("codex", "my-gpt-5")
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{200_000, .Default})
	r = bridge_context_window_resolve("claude", "gpt-5")
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{200_000, .Default})
	r = bridge_context_window_resolve("copilot", "anthropic/claude-opus") // provider with no entries
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{200_000, .Default})
	r = bridge_context_window_resolve("", "")
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{200_000, .Default})
}

@(test)
test_ctxwin_custom_config_first_match_wins_and_bad_regex_skipped :: proc(t: ^testing.T) {
	c: Bridge_Context_Window_Config
	doc := `{"default_window":300000,"warn_pct":0,"rollover_pct":101,"entries":[
		{"provider":"x","model_regex":"(unclosed","context_window":1},
		{"provider":"x","model_regex":"m-.*","context_window":111111},
		{"provider":"x","model_regex":"m-1","context_window":222222},
		{"provider":"","model_regex":".*","context_window":5}]}`
	testing.expect(t, bridge_context_window_parse_config(doc, &c))
	defer bridge_context_window_config_destroy(&c)
	testing.expect_value(t, len(c.entries), 2)
	testing.expect_value(t, c.entries[0].context_window, i64(111111))
	testing.expect_value(t, c.default_window, i64(300000))
	testing.expect_value(t, c.warn_pct, 40) // out-of-range thresholds fall back
	testing.expect_value(t, c.rollover_pct, 70)
	bad: Bridge_Context_Window_Config
	testing.expect(t, !bridge_context_window_parse_config("not json", &bad))
}

@(test)
test_ctxwin_alias_via_resolved_model :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved, scratch := ctxwin_scratch_begin("alias")
	defer ctxwin_scratch_end(saved, scratch)

	// Discovery maps aliases to resolved_model (same reply shape as discovery tests).
	models := make([dynamic]Bridge_Discovered_Model)
	defer { for m in models { delete(m.model_id); delete(m.label); delete(m.resolved_model) }; delete(models) }
	_, valid, cursor, _ := bridge_models_parse_reply("claude", `{"type":"control_response","response":{"request_id":"models","subtype":"success","response":{"models":[{"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default"},{"value":"big","resolvedModel":"claude-sonnet-5-5[1m]","displayName":"Big"},{"value":"plain","displayName":"Plain"}]}}}`, 2, &models)
	defer delete(cursor)
	testing.expect(t, valid)
	testing.expect_value(t, bridge_context_window_resolved_in(models[:], "default"), "claude-opus-5-5")
	testing.expect_value(t, bridge_context_window_resolved_in(models[:], "plain"), "")
	testing.expect_value(t, bridge_context_window_resolved_in(models[:], "unknown"), "")

	// `plain` matches no entry and has no resolved_model; `default` is a
	// shipped alias entry itself and its resolved_model agrees.
	r := bridge_context_window_resolve("claude", "plain", bridge_context_window_resolved_in(models[:], "plain"))
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{200_000, .Default})
	r = bridge_context_window_resolve("claude", "default", bridge_context_window_resolved_in(models[:], "default"))
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{1_000_000, .Config})
	// Conservative map: an alias with no resolved model is small, with a
	// verified 1M resolved id it is large; unknown pi anthropic ids are small.
	r = bridge_context_window_resolve("claude", "opus")
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{200_000, .Config})
	r = bridge_context_window_resolve("claude", "opus", "claude-opus-5-5")
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{1_000_000, .Config})
	r = bridge_context_window_resolve("pi", "anthropic/claude-sonnet-6")
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{200_000, .Config})
	// An unknown alias falls through to its resolved_model.
	r = bridge_context_window_resolve("claude", "my-alias", "claude-sonnet-4-6")
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{200_000, .Config})
	r = bridge_context_window_resolve("claude", "big", bridge_context_window_resolved_in(models[:], "big"))
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{1_000_000, .Config})
	// The resolved model is tried first: the concrete id beats the alias entry.
	r = bridge_context_window_resolve("claude", "opus[1m]", "claude-opus-4-6")
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{200_000, .Config})
	r = bridge_context_window_resolve("claude", "sonnet", "claude-sonnet-4-6")
	testing.expect_value(t, r, Bridge_Context_Window_Resolution{200_000, .Config})
}

@(test)
test_ctxwin_override_precedence_persistence_and_clear :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved, scratch := ctxwin_scratch_begin("override")
	defer ctxwin_scratch_end(saved, scratch)

	testing.expect_value(t, bridge_context_window_set("claude", "claude-opus-5-5", 500_000), Bridge_Context_Window_Error.None)
	testing.expect_value(t, bridge_context_window_set("codex", "brand-new-model", 1_000_000), Bridge_Context_Window_Error.None)
	// Override beats the shipped entry, by model or by resolved_model.
	testing.expect_value(t, bridge_context_window_resolve("claude", "claude-opus-5-5"), Bridge_Context_Window_Resolution{500_000, .Override})
	testing.expect_value(t, bridge_context_window_resolve("claude", "default", "claude-opus-5-5"), Bridge_Context_Window_Resolution{500_000, .Override})
	testing.expect_value(t, bridge_context_window_resolve("codex", "brand-new-model"), Bridge_Context_Window_Resolution{1_000_000, .Override})
	// Keyed by provider: the same model id under another provider is untouched.
	testing.expect_value(t, bridge_context_window_resolve("pi", "claude-opus-5-5").source, Bridge_Context_Window_Source.Default)
	// Updating an existing key replaces its value.
	testing.expect_value(t, bridge_context_window_set("claude", "claude-opus-5-5", 200_000), Bridge_Context_Window_Error.None)
	testing.expect_value(t, bridge_context_window_resolve("claude", "claude-opus-5-5"), Bridge_Context_Window_Resolution{200_000, .Override})

	// Survives a restart: drop the cache and re-read the file.
	path := bridge_context_window_overrides_path(context.temp_allocator)
	testing.expect(t, strings.has_prefix(path, scratch))
	testing.expect(t, os.exists(path))
	bridge_context_window_reload_for_test()
	testing.expect_value(t, bridge_context_window_resolve("claude", "claude-opus-5-5"), Bridge_Context_Window_Resolution{200_000, .Override})
	testing.expect_value(t, bridge_context_window_resolve("codex", "brand-new-model"), Bridge_Context_Window_Resolution{1_000_000, .Override})

	// Clear falls back to the shipped config, persistently; clearing again is fine.
	testing.expect_value(t, bridge_context_window_clear("claude", "claude-opus-5-5"), Bridge_Context_Window_Error.None)
	testing.expect_value(t, bridge_context_window_clear("claude", "claude-opus-5-5"), Bridge_Context_Window_Error.None)
	bridge_context_window_reload_for_test()
	testing.expect_value(t, bridge_context_window_resolve("claude", "claude-opus-5-5"), Bridge_Context_Window_Resolution{1_000_000, .Config})
	testing.expect_value(t, bridge_context_window_resolve("codex", "brand-new-model").source, Bridge_Context_Window_Source.Override)

	// A hand-edited file is validated on load like the RPC.
	_ = os.write_entire_file(path, transmute([]byte)string(`{"overrides":[{"provider":"codex","model":"tiny","context_window":5000},{"provider":"codex","model":"ok","context_window":300000}]}`))
	bridge_context_window_reload_for_test()
	testing.expect_value(t, bridge_context_window_resolve("codex", "tiny").source, Bridge_Context_Window_Source.Default)
	testing.expect_value(t, bridge_context_window_resolve("codex", "ok"), Bridge_Context_Window_Resolution{300_000, .Override})
}

@(test)
test_ctxwin_min_value_and_key_validation :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved, scratch := ctxwin_scratch_begin("validate")
	defer ctxwin_scratch_end(saved, scratch)

	testing.expect_value(t, bridge_context_window_set("claude", "m", 99_999), Bridge_Context_Window_Error.Below_Minimum)
	testing.expect_value(t, bridge_context_window_set("claude", "m", 0), Bridge_Context_Window_Error.Below_Minimum)
	testing.expect_value(t, bridge_context_window_set("claude", "m", -1), Bridge_Context_Window_Error.Below_Minimum)
	testing.expect_value(t, bridge_context_window_set("claude", "m", BRIDGE_CONTEXT_WINDOW_MAX + 1), Bridge_Context_Window_Error.Above_Maximum)
	testing.expect_value(t, bridge_context_window_set("", "m", 200_000), Bridge_Context_Window_Error.Invalid_Provider)
	testing.expect_value(t, bridge_context_window_set("a/b", "m", 200_000), Bridge_Context_Window_Error.Invalid_Provider)
	testing.expect_value(t, bridge_context_window_set("claude", "", 200_000), Bridge_Context_Window_Error.Invalid_Model)
	testing.expect_value(t, bridge_context_window_set("claude", "bad id", 200_000), Bridge_Context_Window_Error.Invalid_Model)
	testing.expect(t, !os.exists(bridge_context_window_overrides_path(context.temp_allocator)), "rejected values are never persisted")
	// Exactly the minimum is accepted.
	testing.expect_value(t, bridge_context_window_set("claude", "m", 100_000), Bridge_Context_Window_Error.None)
	testing.expect_value(t, bridge_context_window_resolve("claude", "m"), Bridge_Context_Window_Resolution{100_000, .Override})
}

@(test)
test_ctxwin_op_frame_list_set_clear :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved, scratch := ctxwin_scratch_begin("op")
	defer ctxwin_scratch_end(saved, scratch)

	set_reply := bridge_context_window_op_json(`{"type":"context_window_op","command_id":"cmd_1","op":"set","provider":"codex","model":"gpt-x-test","context_window":1000000}`)
	defer delete(set_reply)
	v, err := json.parse_string(set_reply, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	root := v.(json.Object)
	testing.expect_value(t, root["type"].(json.String), "context_window_op_result")
	testing.expect_value(t, root["command_id"].(json.String), "cmd_1")
	testing.expect_value(t, root["ok"].(json.Boolean), true)
	testing.expect_value(t, root["warn_pct"].(json.Integer), 40)
	testing.expect_value(t, root["rollover_pct"].(json.Integer), 70)
	testing.expect_value(t, root["default_window"].(json.Integer), 200000)
	testing.expect_value(t, root["min_window"].(json.Integer), 100000)
	testing.expect_value(t, len(root["entries"].(json.Array)), 17)
	overrides := root["overrides"].(json.Array)
	testing.expect_value(t, len(overrides), 1)
	found := false
	for w in root["windows"].(json.Array) {
		o := w.(json.Object)
		if o["provider"].(json.String) != "codex" || o["model"].(json.String) != "gpt-x-test" do continue
		found = true
		testing.expect_value(t, o["context_window"].(json.Integer), 1000000)
		testing.expect_value(t, o["source"].(json.String), "override")
	}
	testing.expect(t, found, "the overridden pair is listed with source=override")

	bad := bridge_context_window_op_json(`{"command_id":"cmd_2","op":"set","provider":"codex","model":"gpt-x-test","context_window":50000}`)
	defer delete(bad)
	testing.expect(t, strings.contains(bad, `"ok":false`))
	testing.expect(t, strings.contains(bad, `"error":"below_minimum"`))
	testing.expect_value(t, bridge_context_window_resolve("codex", "gpt-x-test").context_window, i64(1000000))

	// A list for a pair with no override reports where its value comes from.
	list := bridge_context_window_op_json(`{"command_id":"cmd_3","op":"list","provider":"codex","model":"gpt-6.1-sol"}`)
	defer delete(list)
	testing.expect(t, strings.contains(list, `{"provider":"codex","model":"gpt-6.1-sol","context_window":475000,"source":"config"}`))

	clr := bridge_context_window_op_json(`{"command_id":"cmd_4","op":"clear","provider":"codex","model":"gpt-x-test"}`)
	defer delete(clr)
	testing.expect(t, strings.contains(clr, `"ok":true`))
	testing.expect(t, strings.contains(clr, `"overrides":[]`))
	testing.expect(t, strings.contains(clr, `{"provider":"codex","model":"gpt-x-test","context_window":258400,"source":"config"}`))

	unknown := bridge_context_window_op_json(`{"command_id":"cmd_5","op":"nuke"}`)
	defer delete(unknown)
	testing.expect(t, strings.contains(unknown, `"error":"bad_op"`))
}

@(test)
test_ctxwin_instance_snapshot_carries_window_and_pct :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved, scratch := ctxwin_scratch_begin("inst")
	defer ctxwin_scratch_end(saved, scratch)

	id := "inst_test_ctxwin_snapshot"
	defer ctxwin_forget_launch(id)
	bridge_runtime_mark_start_success(id)
	bridge_ext_note_launch(id, "codex", "gpt-6.1-sol", "")
	window, source, pct := bridge_ext_context_window_for(id)
	testing.expect_value(t, window, i64(475_000))
	testing.expect_value(t, source, Bridge_Context_Window_Source.Config)
	testing.expect_value(t, pct, i64(-1))

	now := bridge_runtime_now_ms()
	raw := `{"schema":"ham.ext.v1","provider":"codex","ext_version":"0.1.0","event":"tool.end","ts":"2026-11-02T06:00:00Z","session_id":"s-ctxwin","tool":{"name":"Read","use_id":"tu_9"},"usage":{"context_tokens":285000,"context_window":999999,"source":"codex_transcript"}}`
	res := bridge_ext_ingest(Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "tok_test", role = .Agent}, raw, now)
	bridge_ext_ingest_result_destroy(&res)
	_, _, pct = bridge_ext_context_window_for(id)
	testing.expect_value(t, pct, i64(28)) // 285000 / 999999: the provider-reported window beats config (T5)

	frame := bridge_instance_status_json(id)
	defer delete(frame)
	testing.expect(t, strings.contains(frame, `"context_window":999999,"window_source":"reported","warn_pct":40,"rollover_pct":70,"reported_window":999999,"window_mismatch":true,"context_pct":28`))

	// An override re-resolves the live instance; a session reset keeps the window.
	testing.expect_value(t, bridge_context_window_set("codex", "gpt-6.1-sol", 1_000_000), Bridge_Context_Window_Error.None)
	window, source, pct = bridge_ext_context_window_for(id)
	testing.expect_value(t, window, i64(1_000_000))
	testing.expect_value(t, source, Bridge_Context_Window_Source.Override)
	testing.expect_value(t, pct, i64(28))
	res = bridge_ext_ingest(Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "tok_test", role = .Agent}, `{"schema":"ham.ext.v1","provider":"codex","ext_version":"0.1.0","event":"tool.end","ts":"2026-11-02T06:00:01Z","session_id":"s-ctxwin-2","tool":{"name":"Read"}}`, now + 1)
	bridge_ext_ingest_result_destroy(&res)
	window, source, _ = bridge_ext_context_window_for(id)
	testing.expect_value(t, window, i64(1_000_000))
	testing.expect_value(t, source, Bridge_Context_Window_Source.Override)
	testing.expect_value(t, bridge_context_window_clear("codex", "gpt-6.1-sol"), Bridge_Context_Window_Error.None)
	window, source, _ = bridge_ext_context_window_for(id)
	testing.expect_value(t, window, i64(999_999)) // no override again: the reported window applies
	testing.expect_value(t, source, Bridge_Context_Window_Source.Reported)
}

// The settings list reflects a running instance's provider-reported window
// (source "reported", reported_window, window_mismatch) unless an override wins.
@(test)
test_ctxwin_state_json_carries_reported_window_and_mismatch :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved, scratch := ctxwin_scratch_begin("listreported")
	defer ctxwin_scratch_end(saved, scratch)

	id := "inst_test_ctxwin_listreported"
	defer ctxwin_forget_launch(id)
	bridge_runtime_mark_start_success(id)
	bridge_ext_note_launch(id, "codex", "gpt-6.1-sol", "") // config: 475000
	now := bridge_runtime_now_ms()
	ingest :: proc(id: string, window: int, now: i64) {
		raw := fmt.tprintf(`{{"schema":"ham.ext.v1","provider":"codex","ext_version":"0.1.0","event":"tool.end","ts":"2026-11-02T06:00:%02dZ","session_id":"s-lr","tool":{{"name":"Read","use_id":"tu_%d"}},"usage":{{"context_tokens":1000,"context_window":%d,"source":"codex_transcript"}}}}`, int(now % 50), int(now), window)
		res := bridge_ext_ingest(Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "tok_test", role = .Agent}, raw, now)
		bridge_ext_ingest_result_destroy(&res)
	}
	window_row :: proc() -> string {
		b := strings.builder_make(context.temp_allocator)
		bridge_context_window_state_json(&b)
		s := strings.to_string(b)
		w := strings.index(s, `"windows":[`)
		if w < 0 do return ""
		i := strings.index(s[w:], `{"provider":"codex","model":"gpt-6.1-sol"`)
		if i < 0 do return ""
		i += w
		j := strings.index_byte(s[i:], '}')
		return s[i:i + j + 1]
	}

	ingest(id, 999_999, now)
	row := window_row()
	testing.expect(t, strings.contains(row, `"context_window":999999,"source":"reported","reported_window":999999,"window_mismatch":true`), row)

	ingest(id, 490_000, now + 1) // within 10% of 475000: reported, no mismatch
	row = window_row()
	testing.expect(t, strings.contains(row, `"source":"reported","reported_window":490000`), row)
	testing.expect(t, !strings.contains(row, "window_mismatch"), row)

	testing.expect_value(t, bridge_context_window_set("codex", "gpt-6.1-sol", 1_000_000), Bridge_Context_Window_Error.None)
	row = window_row()
	testing.expect(t, strings.contains(row, `"context_window":1000000,"source":"override"`), row)
	testing.expect(t, !strings.contains(row, "reported_window"), row)
}

// A stopped instance keeps its final usage but must not drive the settings
// overlay: stopped-only shows no reported fields; a stopped mismatching
// instance never beats a live matching one.
@(test)
test_ctxwin_state_json_ignores_stopped_instances :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved, scratch := ctxwin_scratch_begin("liststopped")
	defer ctxwin_scratch_end(saved, scratch)

	old_id, live_id := "inst_test_ctxwin_stopped_old", "inst_test_ctxwin_stopped_live"
	defer ctxwin_forget_launch(old_id)
	defer ctxwin_forget_launch(live_id)
	bridge_runtime_mark_start_success(old_id)
	bridge_ext_note_launch(old_id, "codex", "gpt-6.1-sol", "")
	ingest :: proc(id: string, window: int, now: i64) {
		raw := fmt.tprintf(`{{"schema":"ham.ext.v1","provider":"codex","ext_version":"0.1.0","event":"tool.end","ts":"2026-11-02T06:00:%02dZ","session_id":"s-st","tool":{{"name":"Read","use_id":"tu_%d"}},"usage":{{"context_tokens":1000,"context_window":%d,"source":"codex_transcript"}}}}`, int(now % 50), int(now), window)
		res := bridge_ext_ingest(Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "tok_test", role = .Agent}, raw, now)
		bridge_ext_ingest_result_destroy(&res)
	}
	window_row :: proc() -> string {
		b := strings.builder_make(context.temp_allocator)
		bridge_context_window_state_json(&b)
		s := strings.to_string(b)
		w := strings.index(s, `"windows":[`)
		if w < 0 do return ""
		i := strings.index(s[w:], `{"provider":"codex","model":"gpt-6.1-sol"`)
		if i < 0 do return ""
		i += w
		j := strings.index_byte(s[i:], '}')
		return s[i:i + j + 1]
	}
	now := bridge_runtime_now_ms()
	ingest(old_id, 999_999, now)
	row := window_row()
	testing.expect(t, strings.contains(row, `"source":"reported","reported_window":999999`), row) // running: overlay applies

	bridge_runtime_set_status(old_id, "stopped", "idle")
	row = window_row()
	testing.expect(t, strings.contains(row, `"source":"config"`) || !strings.contains(row, "reported"), row)
	testing.expect(t, !strings.contains(row, "reported_window"), row)
	testing.expect(t, !strings.contains(row, "window_mismatch"), row)

	bridge_runtime_mark_start_success(live_id)
	bridge_ext_note_launch(live_id, "codex", "gpt-6.1-sol", "")
	ingest(live_id, 490_000, now + 1) // within 10% of 475000
	row = window_row()
	testing.expect(t, strings.contains(row, `"source":"reported","reported_window":490000`), row)
	testing.expect(t, !strings.contains(row, "window_mismatch"), row)
	testing.expect(t, !strings.contains(row, "999999"), row)
}

// The shipped map (R1 research, docs/transient-extension-signals.md): every
// model id seen on our bridges resolves to its documented window. Claude 5.x
// and Opus 4.7+ run at a native 1M in Claude Code; opus/sonnet-4-6 and
// haiku-4-5 are 200K unless the id carries [1m]; Codex windows are the
// effective (95%) values Codex reports.
@(test)
test_ctxwin_shipped_map_known_model_ids :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved, scratch := ctxwin_scratch_begin("shipped")
	defer ctxwin_scratch_end(saved, scratch)

	Case :: struct {
		provider, model: string,
		want:            Bridge_Context_Window_Resolution,
	}
	cases := [?]Case {
		// Claude Code aliases with no resolved model: conservative 200K.
		{"claude", "default", {200_000, .Config}},
		{"claude", "opus", {200_000, .Config}},
		{"claude", "sonnet", {200_000, .Config}},
		{"claude", "haiku", {200_000, .Config}},
		{"claude", "fable", {200_000, .Config}},
		// Claude 5.x and Opus 4.7 / 4.8: native 1M.
		{"claude", "claude-opus-5-5", {1_000_000, .Config}},
		{"claude", "claude-sonnet-5-5", {1_000_000, .Config}},
		{"claude", "claude-haiku-5-5", {1_000_000, .Config}},
		{"claude", "claude-fable-5-1", {1_000_000, .Config}},
		{"claude", "claude-opus-4-8", {1_000_000, .Config}},
		{"claude", "claude-opus-4-7", {1_000_000, .Config}},
		// Older models: 200K unless the [1m] variant is selected.
		{"claude", "claude-opus-4-6", {200_000, .Config}},
		{"claude", "claude-sonnet-4-6", {200_000, .Config}},
		{"claude", "claude-haiku-4-5-20251001", {200_000, .Config}},
		{"claude", "claude-opus-4-6[1m]", {1_000_000, .Config}},
		// Codex effective windows.
		{"codex", "gpt-6.1-sol", {475_000, .Config}},
		{"codex", "gpt-6.1-terra", {475_000, .Config}},
		{"codex", "gpt-6-luna", {258_400, .Config}},
		{"codex", "gpt-5.6-sol", {258_400, .Config}},
		// Unknown Claude ids get the default, as Claude Code assumes.
		{"claude", "claude-mystery-9", {200_000, .Default}},
		{"claude", "claude-opus-4-5", {200_000, .Default}},
		// Pi: ids are <provider>/<model>; windows from `pi --list-models`.
		{"pi", "anthropic/claude-opus-4-5", {200_000, .Config}},
		{"pi", "anthropic/claude-sonnet-4-6", {200_000, .Config}},
		{"pi", "openai-codex/gpt-5.3-codex-spark", {128_000, .Config}},
		{"pi", "openai-codex/gpt-6.1-sol", {272_000, .Config}},
		{"pi", "zai/glm-4.7", {204_800, .Config}},
		{"pi", "zai/glm-5-turbo", {200_000, .Config}},
		{"pi", "zai/glm-5.3-flash", {1_000_000, .Config}},
		// Antigravity: conservative (in-app limit undocumented).
		{"antigravity", "gemini-4-argon-high", {256_000, .Config}},
		{"antigravity", "claude-opus-5-5-medium", {200_000, .Config}},
		{"antigravity", "gpt-oss-120b-medium", {131_072, .Config}},
		// Escaped dots stay literal; unknown pi providers get the default.
		{"pi", "zai/glm-4x7", {200_000, .Default}},
		{"pi", "zai/glm-5x2", {200_000, .Default}},
		{"pi", "google/gemini-4-argon", {200_000, .Default}},
		// Pi/Antigravity regexes never leak into claude/codex (and vice versa).
		{"claude", "anthropic/claude-opus-5-5", {200_000, .Default}},
		{"codex", "openai-codex/gpt-6.1-sol", {200_000, .Default}},
		{"codex", "gpt-oss-120b-medium", {258_400, .Config}},
		{"claude", "claude-opus-5-5-medium", {1_000_000, .Config}},
		{"antigravity", "gpt-6.1-sol", {200_000, .Default}},
	}
	for c in cases {
		got := bridge_context_window_resolve(c.provider, c.model)
		testing.expectf(t, got == c.want, "%s/%s: got %v, want %v", c.provider, c.model, got, c.want)
	}
}

// The snapshot sent to the hub carries the shipped config's thresholds (single
// source of truth), not copies of the literals.
@(test)
test_ctxwin_snapshot_thresholds_match_shipped_config :: proc(t: ^testing.T) {
	c: Bridge_Context_Window_Config
	testing.expect(t, bridge_context_window_parse_config(BRIDGE_CONTEXT_WINDOWS_EMBEDDED, &c))
	defer bridge_context_window_config_destroy(&c)
	b := strings.builder_make(context.temp_allocator)
	bridge_ext_token_usage_write_json(&b, Bridge_Ext_Token_Usage{updated_at_ms = 1})
	value, err := json.parse_string(strings.to_string(b), json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	root, is_obj := value.(json.Object)
	testing.expect(t, is_obj)
	testing.expect_value(t, root["warn_pct"].(json.Integer), json.Integer(c.warn_pct))
	testing.expect_value(t, root["rollover_pct"].(json.Integer), json.Integer(c.rollover_pct))
}

@(test)
test_ctxwin_usage_dark_log_state_survives_relaunch :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved, scratch := ctxwin_scratch_begin("inst")
	defer ctxwin_scratch_end(saved, scratch)

	id := "inst_test_usage_dark_relaunch"
	bridge_runtime_mark_start_success(id)
	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "tok_test", role = .Agent}
	hello := `{"schema":"ham.ext.v1","provider":"claude","ext_version":"0.1.0","event":"hello","ts":"2026-11-02T05:59:00Z","payload":{"capabilities":["usage"]}}`
	raw := `{"schema":"ham.ext.v1","provider":"claude","ext_version":"0.1.0","event":"tool.end","ts":"2026-11-02T06:00:00Z","session_id":"s-dark","tool":{"name":"Read"},"usage_unavailable":true}`
	logged :: proc(id: string) -> string {
		sync.mutex_lock(&bridge_ext_mutex); defer sync.mutex_unlock(&bridge_ext_mutex)
		for s in bridge_ext_states do if s.agent_instance_id == id do return strings.clone(s.usage_dark_logged_session, context.temp_allocator)
		return "?"
	}
	now := bridge_runtime_now_ms()
	bridge_ext_note_launch(id, "claude", "sonnet", "")
	res := bridge_ext_ingest(rec, hello, now)
	bridge_ext_ingest_result_destroy(&res)
	res = bridge_ext_ingest(rec, raw, now)
	bridge_ext_ingest_result_destroy(&res)
	testing.expect_value(t, logged(id), "s-dark")
	// Relaunch clears the marker (no dangling string), repeated launch is safe.
	bridge_ext_note_launch(id, "claude", "sonnet", "")
	testing.expect_value(t, logged(id), "")
	bridge_ext_note_launch(id, "claude", "sonnet", "")
	res = bridge_ext_ingest(rec, hello, now + 1)
	bridge_ext_ingest_result_destroy(&res)
	res = bridge_ext_ingest(rec, raw, now + 1)
	bridge_ext_ingest_result_destroy(&res)
	testing.expect_value(t, logged(id), "s-dark")
}

// usage_unavailable is logged only when the hello advertised `usage`, once per
// session_id (the marker field records the last logged session).
@(test)
test_ctxwin_usage_dark_log_gated_on_usage_supported :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved, scratch := ctxwin_scratch_begin("inst")
	defer ctxwin_scratch_end(saved, scratch)

	ev :: proc(sid: string) -> string {
		return fmt.tprintf(`{{"schema":"ham.ext.v1","provider":"claude","ext_version":"0.1.0","event":"tool.end","ts":"2026-11-02T06:00:00Z","session_id":"%s","tool":{{"name":"Read"}},"usage_unavailable":true}}`, sid)
	}
	logged :: proc(id: string) -> string {
		sync.mutex_lock(&bridge_ext_mutex); defer sync.mutex_unlock(&bridge_ext_mutex)
		for s in bridge_ext_states do if s.agent_instance_id == id do return strings.clone(s.usage_dark_logged_session, context.temp_allocator)
		return "?"
	}
	feed :: proc(rec: Bridge_Local_Agent_Token_Record, raw: string, now: i64) {
		res := bridge_ext_ingest(rec, raw, now)
		bridge_ext_ingest_result_destroy(&res)
	}
	now := bridge_runtime_now_ms()

	// No hello (usage_supported absent): no log.
	id_a := "inst_test_usage_dark_nohello"
	bridge_runtime_mark_start_success(id_a)
	rec_a := Bridge_Local_Agent_Token_Record{agent_instance_id = id_a, instance_token = "tok_test", role = .Agent}
	bridge_ext_note_launch(id_a, "claude", "sonnet", "")
	feed(rec_a, ev("s1"), now)
	testing.expect_value(t, logged(id_a), "")

	// Hello without the usage capability (usage_supported=false): no log.
	id_b := "inst_test_usage_dark_unsupported"
	bridge_runtime_mark_start_success(id_b)
	rec_b := Bridge_Local_Agent_Token_Record{agent_instance_id = id_b, instance_token = "tok_test", role = .Agent}
	bridge_ext_note_launch(id_b, "claude", "sonnet", "")
	feed(rec_b, `{"schema":"ham.ext.v1","provider":"claude","ext_version":"0.1.0","event":"hello","ts":"2026-11-02T05:59:00Z","payload":{"capabilities":[]}}`, now)
	feed(rec_b, ev("s1"), now)
	testing.expect_value(t, logged(id_b), "")

	// Supported: logs once per session_id, again for a new session_id.
	id_c := "inst_test_usage_dark_supported"
	bridge_runtime_mark_start_success(id_c)
	rec_c := Bridge_Local_Agent_Token_Record{agent_instance_id = id_c, instance_token = "tok_test", role = .Agent}
	bridge_ext_note_launch(id_c, "claude", "sonnet", "")
	feed(rec_c, `{"schema":"ham.ext.v1","provider":"claude","ext_version":"0.1.0","event":"hello","ts":"2026-11-02T05:59:00Z","payload":{"capabilities":["usage"]}}`, now)
	feed(rec_c, ev("s1"), now)
	testing.expect_value(t, logged(id_c), "s1")
	feed(rec_c, ev("s1"), now + 1) // same session: marker unchanged, no second log
	testing.expect_value(t, logged(id_c), "s1")
	feed(rec_c, ev("s2"), now + 2) // new session: logs again
	testing.expect_value(t, logged(id_c), "s2")
}
