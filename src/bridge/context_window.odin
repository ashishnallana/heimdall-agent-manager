package main

// Context window per agent instance (chain "Estimate agent tokens via
// extensions", T2b). bridge_context_window_resolve never probes a provider; it
// resolves, in order:
//   1. a user override persisted on this bridge, keyed by provider + model;
//   2. the read-only config shipped inside the bridge binary
//      (context_windows.json: ordered {provider, model_regex, context_window},
//      first match wins, regex anchored to the whole model id);
//      the entries and their sources (and the CLAUDE_CODE_DISABLE_1M_CONTEXT
//      caveat) are listed in docs/transient-extension-signals.md;
//   3. the default (200 000).
// The model id tried is the resolved_model when discovery knows it, then the
// configured model (which may be an alias such as `default` or `opus`); an alias
// with no known resolved id resolves small (200K), never large.
// A window the provider itself reports (Codex model_context_window) is layered on
// top in extension_token_usage.odin: it replaces the config/default result
// (source "reported") but never a user override, and a >10% disagreement with
// the config/default result raises window_mismatch.
// The hub reaches this through the `context_window_op` frame (list/set/clear).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:text/regex"
import ws "odin_test:lib/ws"

BRIDGE_CONTEXT_WINDOWS_EMBEDDED :: #load("context_windows.json", string)
// User values below this are rejected (the UI offers 200K/500K/1M or custom >= 100K).
BRIDGE_CONTEXT_WINDOW_MIN :: 100_000
// Sanity cap so a typo cannot make every percentage read 0.
BRIDGE_CONTEXT_WINDOW_MAX :: 100_000_000
// Used only when the shipped config itself is unreadable.
BRIDGE_CONTEXT_WINDOW_FALLBACK :: 200_000
BRIDGE_CONTEXT_OVERRIDES_LIMIT :: 256

Bridge_Context_Window_Source :: enum u8 {
	Default,
	Config,
	Override,
	// Provider-reported window (Codex model_context_window); applies only when
	// no override exists. Never produced by bridge_context_window_resolve.
	Reported,
}

bridge_context_window_source_name :: proc(source: Bridge_Context_Window_Source) -> string {
	switch source {
	case .Override: return "override"
	case .Reported: return "reported"
	case .Config:   return "config"
	case .Default:  return "default"
	}
	return "default"
}

Bridge_Context_Window_Entry_Wire :: struct {
	provider:       string `json:"provider"`,
	model_regex:    string `json:"model_regex"`,
	context_window: i64 `json:"context_window"`,
}

Bridge_Context_Window_Config_Wire :: struct {
	default_window: i64 `json:"default_window"`,
	warn_pct:       int `json:"warn_pct"`,
	rollover_pct:   int `json:"rollover_pct"`,
	entries:        []Bridge_Context_Window_Entry_Wire `json:"entries"`,
}

Bridge_Context_Window_Entry :: struct {
	provider:       string,
	model_regex:    string,
	context_window: i64,
	re:             regex.Regular_Expression,
}

Bridge_Context_Window_Config :: struct {
	default_window: i64,
	warn_pct:       int,
	rollover_pct:   int,
	entries:        [dynamic]Bridge_Context_Window_Entry,
}

Bridge_Context_Window_Override :: struct {
	provider:       string `json:"provider"`,
	model:          string `json:"model"`,
	context_window: i64 `json:"context_window"`,
}

Bridge_Context_Window_Overrides_Wire :: struct {
	overrides: []Bridge_Context_Window_Override `json:"overrides"`,
}

Bridge_Context_Window_Resolution :: struct {
	context_window: i64,
	source:         Bridge_Context_Window_Source,
}

Bridge_Context_Window_Error :: enum u8 {
	None,
	Invalid_Provider,
	Invalid_Model,
	Below_Minimum,
	Above_Maximum,
	Too_Many,
	Persist_Failed,
	Bad_Op,
}

bridge_context_window_error_code :: proc(err: Bridge_Context_Window_Error) -> string {
	switch err {
	case .None:             return ""
	case .Invalid_Provider: return "invalid_provider"
	case .Invalid_Model:    return "invalid_model"
	case .Below_Minimum:    return "below_minimum"
	case .Above_Maximum:    return "above_maximum"
	case .Too_Many:         return "too_many_overrides"
	case .Persist_Failed:   return "persist_failed"
	case .Bad_Op:           return "bad_op"
	}
	return "bad_op"
}

// One mutex guards the parsed config (regex VMs are run under it too) and the
// override cache. It never nests with bridge_ext_mutex or bridge_models_mu.
bridge_ctxwin_mu: sync.Mutex
bridge_ctxwin_config: Bridge_Context_Window_Config
bridge_ctxwin_config_loaded: bool
bridge_ctxwin_overrides: [dynamic]Bridge_Context_Window_Override
bridge_ctxwin_overrides_loaded: bool

@(private = "file")
ctxwin_allocator :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

// bridge_context_window_parse_config parses a config document into out
// (allocator: out's owner). Entries with an empty provider, an invalid window
// or a regex that does not compile are skipped, so one bad line cannot hide the
// rest. Returns false only when the document itself is unusable.
bridge_context_window_parse_config :: proc(text: string, out: ^Bridge_Context_Window_Config, allocator := context.allocator) -> bool {
	wire: Bridge_Context_Window_Config_Wire
	if json.unmarshal_string(text, &wire, allocator = context.temp_allocator) != nil do return false
	out.default_window = wire.default_window if wire.default_window >= BRIDGE_CONTEXT_WINDOW_MIN else BRIDGE_CONTEXT_WINDOW_FALLBACK
	out.warn_pct = wire.warn_pct if wire.warn_pct > 0 && wire.warn_pct <= 100 else 40
	out.rollover_pct = wire.rollover_pct if wire.rollover_pct > 0 && wire.rollover_pct <= 100 else 70
	out.entries = make([dynamic]Bridge_Context_Window_Entry, allocator)
	for e in wire.entries {
		provider := strings.trim_space(e.provider)
		if provider == "" || e.model_regex == "" || e.context_window <= 0 {
			fmt.eprintln("bridge context windows: skipping invalid entry", e.provider, e.model_regex)
			continue
		}
		// Anchor so `gpt-.*` does not match `my-gpt-x`: the regex is the whole id.
		anchored := strings.concatenate({"^(", e.model_regex, ")$"}, context.temp_allocator)
		re, err := regex.create(anchored, {.No_Capture}, allocator)
		if err != nil {
			fmt.eprintln("bridge context windows: skipping entry with bad regex", e.model_regex, err)
			continue
		}
		append(&out.entries, Bridge_Context_Window_Entry{
			provider = strings.clone(provider, allocator),
			model_regex = strings.clone(e.model_regex, allocator),
			context_window = e.context_window,
			re = re,
		})
	}
	return true
}

bridge_context_window_config_destroy :: proc(c: ^Bridge_Context_Window_Config, allocator := context.allocator) {
	for e in c.entries {
		delete(e.provider, allocator); delete(e.model_regex, allocator)
		regex.destroy_regex(e.re, allocator)
	}
	delete(c.entries)
	c^ = {}
}

@(private = "file")
ctxwin_config_load_locked :: proc() {
	if bridge_ctxwin_config_loaded do return
	bridge_ctxwin_config_loaded = true
	if !bridge_context_window_parse_config(BRIDGE_CONTEXT_WINDOWS_EMBEDDED, &bridge_ctxwin_config, ctxwin_allocator()) {
		fmt.eprintln("bridge context windows: shipped config unreadable; using the 200000 default")
		bridge_ctxwin_config = {default_window = BRIDGE_CONTEXT_WINDOW_FALLBACK, warn_pct = 40, rollover_pct = 70}
	}
}

bridge_context_window_overrides_path :: proc(allocator := context.allocator) -> string {
	paths := bridge_provider_paths_path()
	defer delete(paths)
	return strings.concatenate({paths[:strings.last_index_byte(paths, '/')], "/context_window_overrides.json"}, allocator)
}

@(private = "file")
ctxwin_overrides_clear_locked :: proc() {
	alloc := ctxwin_allocator()
	for o in bridge_ctxwin_overrides { delete(o.provider, alloc); delete(o.model, alloc) }
	clear(&bridge_ctxwin_overrides)
}

@(private = "file")
ctxwin_overrides_load_locked :: proc() {
	if bridge_ctxwin_overrides_loaded do return
	bridge_ctxwin_overrides_loaded = true
	alloc := ctxwin_allocator()
	if bridge_ctxwin_overrides == nil do bridge_ctxwin_overrides = make([dynamic]Bridge_Context_Window_Override, alloc)
	path := bridge_context_window_overrides_path(context.temp_allocator)
	bytes, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(bytes) > 1024 * 1024 do return
	wire: Bridge_Context_Window_Overrides_Wire
	if json.unmarshal(bytes, &wire, allocator = context.temp_allocator) != nil {
		fmt.eprintln("bridge context windows: ignoring unreadable", path)
		return
	}
	for o in wire.overrides {
		// A hand-edited file is held to the same rules as the RPC.
		if bridge_context_window_validate(o.provider, o.model, o.context_window) != .None do continue
		if len(bridge_ctxwin_overrides) >= BRIDGE_CONTEXT_OVERRIDES_LIMIT do break
		append(&bridge_ctxwin_overrides, Bridge_Context_Window_Override{strings.clone(o.provider, alloc), strings.clone(o.model, alloc), o.context_window})
	}
}

@(private = "file")
ctxwin_overrides_save_locked :: proc() -> bool {
	bytes, err := json.marshal(Bridge_Context_Window_Overrides_Wire{overrides = bridge_ctxwin_overrides[:]}, {pretty = true}, context.temp_allocator)
	if err != nil do return false
	path := bridge_context_window_overrides_path(context.temp_allocator)
	return bridge_retry_atomic_write(path, bytes)
}

// bridge_context_window_reload_for_test drops the cached overrides so the next
// call re-reads them from disk (simulates a bridge restart).
bridge_context_window_reload_for_test :: proc() {
	sync.mutex_lock(&bridge_ctxwin_mu); defer sync.mutex_unlock(&bridge_ctxwin_mu)
	ctxwin_overrides_clear_locked()
	bridge_ctxwin_overrides_loaded = false
}

bridge_context_window_validate :: proc(provider, model: string, window: i64) -> Bridge_Context_Window_Error {
	if !bridge_model_id_valid(provider) || strings.contains(provider, "/") do return .Invalid_Provider
	if !bridge_model_id_valid(model) do return .Invalid_Model
	if window < BRIDGE_CONTEXT_WINDOW_MIN do return .Below_Minimum
	if window > BRIDGE_CONTEXT_WINDOW_MAX do return .Above_Maximum
	return .None
}

// bridge_context_window_set persists an override for provider + model.
bridge_context_window_set :: proc(provider, model: string, window: i64) -> Bridge_Context_Window_Error {
	provider, model := strings.trim_space(provider), strings.trim_space(model)
	if err := bridge_context_window_validate(provider, model, window); err != .None do return err
	{
		sync.mutex_lock(&bridge_ctxwin_mu); defer sync.mutex_unlock(&bridge_ctxwin_mu)
		ctxwin_overrides_load_locked()
		found := -1
		for o, i in bridge_ctxwin_overrides do if o.provider == provider && o.model == model { found = i; break }
		previous: i64
		if found >= 0 {
			previous = bridge_ctxwin_overrides[found].context_window
			bridge_ctxwin_overrides[found].context_window = window
		} else {
			if len(bridge_ctxwin_overrides) >= BRIDGE_CONTEXT_OVERRIDES_LIMIT do return .Too_Many
			alloc := ctxwin_allocator()
			append(&bridge_ctxwin_overrides, Bridge_Context_Window_Override{strings.clone(provider, alloc), strings.clone(model, alloc), window})
		}
		if !ctxwin_overrides_save_locked() {
			// Keep memory and disk in agreement: a value that did not persist is not applied.
			if found >= 0 {
				bridge_ctxwin_overrides[found].context_window = previous
			} else {
				last := pop(&bridge_ctxwin_overrides)
				delete(last.provider, ctxwin_allocator()); delete(last.model, ctxwin_allocator())
			}
			return .Persist_Failed
		}
	}
	bridge_ext_context_windows_refresh()
	return .None
}

// bridge_context_window_clear removes an override; clearing a missing one is a no-op success.
bridge_context_window_clear :: proc(provider, model: string) -> Bridge_Context_Window_Error {
	provider, model := strings.trim_space(provider), strings.trim_space(model)
	if !bridge_model_id_valid(provider) || strings.contains(provider, "/") do return .Invalid_Provider
	if !bridge_model_id_valid(model) do return .Invalid_Model
	{
		sync.mutex_lock(&bridge_ctxwin_mu); defer sync.mutex_unlock(&bridge_ctxwin_mu)
		ctxwin_overrides_load_locked()
		found := -1
		for o, i in bridge_ctxwin_overrides do if o.provider == provider && o.model == model { found = i; break }
		if found < 0 do return .None
		removed := bridge_ctxwin_overrides[found]
		ordered_remove(&bridge_ctxwin_overrides, found)
		if !ctxwin_overrides_save_locked() {
			inject_at(&bridge_ctxwin_overrides, found, removed)
			return .Persist_Failed
		}
		delete(removed.provider, ctxwin_allocator()); delete(removed.model, ctxwin_allocator())
	}
	bridge_ext_context_windows_refresh()
	return .None
}

// bridge_context_window_resolve: override (exact provider + resolved_model or
// model) > first matching shipped entry (resolved_model, then model) > default.
// resolved_model is tried first: it is the concrete id, so an alias such as
// `opus` gets the window of the model it resolves to, and only an alias with no
// known resolved id falls back to its (conservative, 200K) alias entry.
// Pure lookup; never probes a provider.
bridge_context_window_resolve :: proc(provider, model: string, resolved_model: string = "") -> Bridge_Context_Window_Resolution {
	provider := strings.trim_space(provider)
	candidates: [2]string = {strings.trim_space(resolved_model), strings.trim_space(model)}
	sync.mutex_lock(&bridge_ctxwin_mu); defer sync.mutex_unlock(&bridge_ctxwin_mu)
	ctxwin_config_load_locked()
	ctxwin_overrides_load_locked()
	if provider != "" {
		for candidate in candidates {
			if candidate == "" do continue
			for o in bridge_ctxwin_overrides do if o.provider == provider && o.model == candidate do return {o.context_window, .Override}
		}
		for candidate in candidates {
			if candidate == "" do continue
			for e in bridge_ctxwin_config.entries {
				if e.provider != provider do continue
				if _, ok := regex.match_and_allocate_capture(e.re, candidate, context.temp_allocator); ok do return {e.context_window, .Config}
			}
		}
	}
	return {bridge_ctxwin_config.default_window, .Default}
}

bridge_context_window_thresholds :: proc() -> (warn_pct, rollover_pct: int, default_window: i64) {
	sync.mutex_lock(&bridge_ctxwin_mu); defer sync.mutex_unlock(&bridge_ctxwin_mu)
	ctxwin_config_load_locked()
	return bridge_ctxwin_config.warn_pct, bridge_ctxwin_config.rollover_pct, bridge_ctxwin_config.default_window
}

// bridge_context_window_resolved_model looks the configured model (an id or an
// alias) up in the persisted discovery snapshot. "" when unknown. temp allocator.
bridge_context_window_resolved_model :: proc(provider, model, profile_id: string) -> string {
	if strings.trim_space(provider) == "" || strings.trim_space(model) == "" do return ""
	snapshot := bridge_models_get(provider, context.temp_allocator, profile_id)
	return bridge_context_window_resolved_in(snapshot.models, model)
}

// bridge_context_window_resolved_in returns model's resolved_model in a
// discovered model list ("" when absent or the same id).
bridge_context_window_resolved_in :: proc(models: []Bridge_Discovered_Model, model: string) -> string {
	for m in models do if m.model_id == model && m.resolved_model != model do return m.resolved_model
	return ""
}

// --- context_window_op frame ------------------------------------------------

Bridge_Context_Window_Pair :: struct {
	provider, model, resolved_model: string,
}

@(private = "file")
ctxwin_pair_add :: proc(pairs: ^[dynamic]Bridge_Context_Window_Pair, provider, model, resolved: string) {
	if provider == "" || model == "" do return
	for &p in pairs {
		if p.provider == provider && p.model == model {
			if p.resolved_model == "" do p.resolved_model = resolved
			return
		}
	}
	append(pairs, Bridge_Context_Window_Pair{provider, model, resolved})
}

// bridge_context_window_list_pairs gathers every provider/model the bridge knows
// of: discovered models (with their resolved_model), live instances and the
// overrides themselves (so a value set for a model not yet seen still shows).
// Strings live in the temp allocator.
bridge_context_window_list_pairs :: proc() -> [dynamic]Bridge_Context_Window_Pair {
	pairs := make([dynamic]Bridge_Context_Window_Pair, context.temp_allocator)
	{
		sync.mutex_lock(&bridge_models_mu)
		bridge_models_load_locked()
		for value in bridge_models_cache {
			for m in value.models do ctxwin_pair_add(&pairs, strings.clone(value.provider, context.temp_allocator), strings.clone(m.model_id, context.temp_allocator), strings.clone(m.resolved_model, context.temp_allocator))
		}
		sync.mutex_unlock(&bridge_models_mu)
	}
	for inst in bridge_ext_context_window_instances() do ctxwin_pair_add(&pairs, inst.provider, inst.model, inst.resolved_model)
	{
		sync.mutex_lock(&bridge_ctxwin_mu)
		ctxwin_overrides_load_locked()
		for o in bridge_ctxwin_overrides do ctxwin_pair_add(&pairs, strings.clone(o.provider, context.temp_allocator), strings.clone(o.model, context.temp_allocator), "")
		sync.mutex_unlock(&bridge_ctxwin_mu)
	}
	return pairs
}

@(private = "file")
ctxwin_write_str :: proc(b: ^strings.Builder, key, value: string) {
	strings.write_string(b, `"`); strings.write_string(b, key); strings.write_string(b, `":"`)
	bridge_local_write_json_string(b, value)
	strings.write_string(b, `"`)
}

// ctxwin_instance_live reports whether an instance is still running. Stopped,
// failed or unreachable instances keep their extension state (final usage
// snapshots) but must not drive the settings' reported-window overlay.
@(private = "file")
ctxwin_instance_live :: proc(instance_id: string) -> bool {
	inst, ok := bridge_runtime_instance_snapshot(instance_id)
	if !ok do return false
	switch inst.runtime_status {
	case "stopped", "stopping", "failed", "unreachable": return false
	}
	return true
}

// bridge_context_window_state_json renders the list payload members (no braces):
// thresholds, the shipped entries, the overrides and the resolved windows.
bridge_context_window_state_json :: proc(b: ^strings.Builder, extra_provider: string = "", extra_model: string = "") {
	pairs := bridge_context_window_list_pairs()
	if bridge_model_id_valid(extra_provider) && bridge_model_id_valid(extra_model) do ctxwin_pair_add(&pairs, extra_provider, extra_model, "")
	for &p in pairs {
		if p.resolved_model == "" do p.resolved_model = bridge_context_window_resolved_model(p.provider, p.model, "")
	}
	warn, rollover, default_window := bridge_context_window_thresholds()
	strings.write_string(b, fmt.tprintf(`"default_window":%d,"min_window":%d,"max_window":%d,"warn_pct":%d,"rollover_pct":%d,"entries":[`, default_window, BRIDGE_CONTEXT_WINDOW_MIN, BRIDGE_CONTEXT_WINDOW_MAX, warn, rollover))
	{
		sync.mutex_lock(&bridge_ctxwin_mu)
		for e, i in bridge_ctxwin_config.entries {
			if i > 0 do strings.write_byte(b, ',')
			strings.write_byte(b, '{'); ctxwin_write_str(b, "provider", e.provider)
			strings.write_byte(b, ','); ctxwin_write_str(b, "model_regex", e.model_regex)
			strings.write_string(b, fmt.tprintf(`,"context_window":%d}}`, e.context_window))
		}
		strings.write_string(b, `],"overrides":[`)
		ctxwin_overrides_load_locked()
		for o, i in bridge_ctxwin_overrides {
			if i > 0 do strings.write_byte(b, ',')
			strings.write_byte(b, '{'); ctxwin_write_str(b, "provider", o.provider)
			strings.write_byte(b, ','); ctxwin_write_str(b, "model", o.model)
			strings.write_string(b, fmt.tprintf(`,"context_window":%d}}`, o.context_window))
		}
		sync.mutex_unlock(&bridge_ctxwin_mu)
	}
	strings.write_string(b, `],"windows":[`)
	insts := bridge_ext_context_window_instances()
	for p, i in pairs {
		r := bridge_context_window_resolve(p.provider, p.model, p.resolved_model)
		// A running instance's provider-reported window replaces a config/default
		// result (never an override); the first mismatching instance wins.
		reported, mismatch := i64(0), false
		if r.source != .Override {
			for inst in insts {
				if inst.provider != p.provider || inst.model != p.model || inst.reported_window <= 0 do continue
				if !ctxwin_instance_live(inst.agent_instance_id) do continue
				if reported == 0 || (inst.window_mismatch && !mismatch) {
					reported, mismatch = inst.reported_window, inst.window_mismatch
				}
			}
			if reported > 0 do r = {context_window = reported, source = .Reported}
		}
		if i > 0 do strings.write_byte(b, ',')
		strings.write_byte(b, '{'); ctxwin_write_str(b, "provider", p.provider)
		strings.write_byte(b, ','); ctxwin_write_str(b, "model", p.model)
		if p.resolved_model != "" { strings.write_byte(b, ','); ctxwin_write_str(b, "resolved_model", p.resolved_model) }
		strings.write_string(b, fmt.tprintf(`,"context_window":%d,`, r.context_window))
		ctxwin_write_str(b, "source", bridge_context_window_source_name(r.source))
		if reported > 0 {
			strings.write_string(b, fmt.tprintf(`,"reported_window":%d`, reported))
			if mismatch do strings.write_string(b, `,"window_mismatch":true`)
		}
		strings.write_byte(b, '}')
	}
	strings.write_byte(b, ']')
}

// bridge_context_window_op_json executes one context_window_op frame and
// returns its context_window_op_result reply (context.allocator).
//   {type:"context_window_op", command_id, op:"list"|"set"|"clear", provider?, model?, context_window?}
// Every reply carries the full list state, so the UI re-renders from it.
bridge_context_window_op_json :: proc(text: string) -> string {
	command_id := extract_json_string(text, "command_id", "", context.temp_allocator)
	op := extract_json_string(text, "op", "list", context.temp_allocator)
	provider := strings.trim_space(extract_json_string(text, "provider", "", context.temp_allocator))
	model := strings.trim_space(extract_json_string(text, "model", "", context.temp_allocator))
	err: Bridge_Context_Window_Error
	switch op {
	case "list":
	case "set":   err = bridge_context_window_set(provider, model, i64(extract_json_int(text, "context_window", 0)))
	case "clear": err = bridge_context_window_clear(provider, model)
	case:         err = .Bad_Op
	}
	b := strings.builder_make()
	strings.write_byte(&b, '{'); ctxwin_write_str(&b, "type", "context_window_op_result")
	strings.write_byte(&b, ','); ctxwin_write_str(&b, "command_id", command_id)
	strings.write_byte(&b, ','); ctxwin_write_str(&b, "op", op)
	strings.write_string(&b, `,"ok":`); strings.write_string(&b, "true" if err == .None else "false")
	if err != .None { strings.write_byte(&b, ','); ctxwin_write_str(&b, "error", bridge_context_window_error_code(err)) }
	strings.write_byte(&b, ',')
	bridge_context_window_state_json(&b, provider, model)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

bridge_hub_handle_context_window_op :: proc(conn: ^ws.Connection, text: string) {
	reply := bridge_context_window_op_json(text)
	defer delete(reply)
	if conn != nil do _ = bridge_hub_send(conn, reply)
}
