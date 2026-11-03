package main

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
	testing.expect_value(t, pct, i64(60)) // 285000 / 475000, the reported 999999 ignored

	frame := bridge_instance_status_json(id)
	defer delete(frame)
	testing.expect(t, strings.contains(frame, `"context_window":475000,"window_source":"config","context_pct":60`))

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
	testing.expect_value(t, window, i64(475_000))
	testing.expect_value(t, source, Bridge_Context_Window_Source.Config)
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

@(test)
test_ctxwin_usage_dark_log_state_survives_relaunch :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	saved, scratch := ctxwin_scratch_begin("inst")
	defer ctxwin_scratch_end(saved, scratch)

	id := "inst_test_usage_dark_relaunch"
	bridge_runtime_mark_start_success(id)
	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = id, instance_token = "tok_test", role = .Agent}
	raw := `{"schema":"ham.ext.v1","provider":"claude","ext_version":"0.1.0","event":"tool.end","ts":"2026-11-02T06:00:00Z","session_id":"s-dark","tool":{"name":"Read"},"usage_unavailable":true}`
	logged :: proc(id: string) -> string {
		sync.mutex_lock(&bridge_ext_mutex); defer sync.mutex_unlock(&bridge_ext_mutex)
		for s in bridge_ext_states do if s.agent_instance_id == id do return strings.clone(s.usage_dark_logged_session, context.temp_allocator)
		return "?"
	}
	now := bridge_runtime_now_ms()
	bridge_ext_note_launch(id, "claude", "sonnet", "")
	res := bridge_ext_ingest(rec, raw, now)
	bridge_ext_ingest_result_destroy(&res)
	testing.expect_value(t, logged(id), "s-dark")
	// Relaunch clears the marker (no dangling string), repeated launch is safe.
	bridge_ext_note_launch(id, "claude", "sonnet", "")
	testing.expect_value(t, logged(id), "")
	bridge_ext_note_launch(id, "claude", "sonnet", "")
	res = bridge_ext_ingest(rec, raw, now + 1)
	bridge_ext_ingest_result_destroy(&res)
	testing.expect_value(t, logged(id), "s-dark")
}
