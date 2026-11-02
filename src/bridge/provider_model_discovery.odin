package main

// REQ-MODEL-4/9: only provider_models_discover runs model probes. Ordinary
// provider detection, launch path resolution and reconnect never call it.
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import ws "odin_test:lib/ws"

BRIDGE_MODEL_LIMIT :: 512
BRIDGE_MODEL_PROBE_TIMEOUT :: 18 * time.Second
BRIDGE_MODEL_OUTPUT_LIMIT :: 1024 * 1024
// Five supported providers fit in the dispatcher's 1 MiB response budget.
BRIDGE_MODEL_SNAPSHOT_LIMIT :: 128 * 1024

Bridge_Discovered_Model :: struct {
	model_id: string `json:"model_id"`,
	label: string `json:"label"`,
	resolved_model: string `json:"resolved_model"`,
}

Bridge_Provider_Models :: struct {
	observed_models_json: string `json:"observed_models_json"`,
	custom_models: []string `json:"custom_models"`,
	profile_id: string `json:"profile_id"`,
	provider: string `json:"provider"`,
	// Snapshot provenance belongs to the last successful result.
	binary_path: string `json:"binary_path"`,
	version_text: string `json:"version_text"`,
	models: []Bridge_Discovered_Model `json:"models"`,
	has_snapshot: bool `json:"has_snapshot"`,
	models_source: string `json:"models_source"`,
	models_checked_at: string `json:"models_checked_at"`,
	models_attempted_at: string `json:"models_attempted_at"`,
	models_state: string `json:"models_state"`,
}
Bridge_Provider_Models_Wire :: struct { providers: []Bridge_Provider_Models `json:"providers"` }

bridge_models_mu: sync.Mutex
bridge_models_loaded: bool
bridge_models_cache: [dynamic]Bridge_Provider_Models
bridge_models_refresh_mu: sync.Mutex
bridge_models_last_key: string
bridge_models_last_completed: i64

bridge_models_destroy :: proc(value: ^Bridge_Provider_Models, allocator := context.allocator) {
	for id in value.custom_models do delete(id,allocator)
	delete(value.custom_models,allocator)
	delete(value.observed_models_json,allocator)
	delete(value.profile_id,allocator)
	delete(value.provider, allocator); delete(value.binary_path, allocator); delete(value.version_text, allocator)
	delete(value.models_source, allocator); delete(value.models_checked_at, allocator)
	delete(value.models_attempted_at, allocator); delete(value.models_state, allocator)
	for model in value.models {
		delete(model.model_id, allocator); delete(model.label, allocator); delete(model.resolved_model, allocator)
	}
	delete(value.models, allocator)
	value^ = {}
}

bridge_models_clone :: proc(value: Bridge_Provider_Models, allocator := context.allocator) -> Bridge_Provider_Models {
	out := value
	out.observed_models_json=strings.clone(value.observed_models_json,allocator)
	out.custom_models=make([]string,len(value.custom_models),allocator)
	for id,i in value.custom_models do out.custom_models[i]=strings.clone(id,allocator)
	out.profile_id = strings.clone(profile_effective_id(value.provider,value.profile_id),allocator)
	out.provider = strings.clone(value.provider, allocator)
	out.binary_path = strings.clone(value.binary_path, allocator)
	out.version_text = strings.clone(value.version_text, allocator)
	out.models_source = strings.clone(value.models_source, allocator)
	out.models_checked_at = strings.clone(value.models_checked_at, allocator)
	out.models_attempted_at = strings.clone(value.models_attempted_at, allocator)
	out.models_state = strings.clone(value.models_state, allocator)
	out.models = make([]Bridge_Discovered_Model, len(value.models), allocator)
	for model, i in value.models do out.models[i] = {strings.clone(model.model_id, allocator), strings.clone(model.label, allocator), strings.clone(model.resolved_model, allocator)}
	return out
}

bridge_models_path :: proc() -> string {
	paths := bridge_provider_paths_path()
	defer delete(paths)
	return strings.concatenate({paths[:strings.last_index_byte(paths, '/')], "/provider_models.json"})
}

bridge_models_load_locked :: proc() {
	if bridge_models_loaded do return
	bridge_models_loaded = true
	alloc := runtime.default_allocator()
	bridge_models_cache = make([dynamic]Bridge_Provider_Models, alloc)
	path := bridge_models_path(); defer delete(path)
	bytes, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(bytes) > 4 * BRIDGE_MODEL_OUTPUT_LIMIT do return
	wire: Bridge_Provider_Models_Wire
	if json.unmarshal(bytes, &wire, allocator = context.temp_allocator) != nil do return
	for value in wire.providers {
		if bridge_models_source(value.provider) != "unsupported" && len(value.models) <= BRIDGE_MODEL_LIMIT {
			encoded, encode_err := json.marshal(value.models, allocator = context.temp_allocator)
			if encode_err != nil || len(encoded) > BRIDGE_MODEL_SNAPSHOT_LIMIT do continue
			append(&bridge_models_cache, bridge_models_clone(value, alloc))
		}
	}
}

bridge_models_get :: proc(provider: string, allocator := context.allocator, profile_id: string = "") -> Bridge_Provider_Models {
	sync.mutex_lock(&bridge_models_mu); defer sync.mutex_unlock(&bridge_models_mu)
	bridge_models_load_locked()
	for value in bridge_models_cache do if value.provider == provider && profile_effective_id(provider,value.profile_id) == profile_effective_id(provider,profile_id) do return bridge_models_clone(value, allocator)
	return Bridge_Provider_Models{provider = strings.clone(provider, allocator),profile_id = strings.clone(profile_effective_id(provider,profile_id),allocator)}
}

bridge_models_save :: proc(value: Bridge_Provider_Models) {
	sync.mutex_lock(&bridge_models_mu); defer sync.mutex_unlock(&bridge_models_mu)
	bridge_models_load_locked()
	alloc := runtime.default_allocator()
	found := false
	for &cached in bridge_models_cache {
		if cached.provider != value.provider || profile_effective_id(cached.provider,cached.profile_id) != profile_effective_id(value.provider,value.profile_id) do continue
		bridge_models_destroy(&cached, alloc)
		cached = bridge_models_clone(value, alloc)
		found = true; break
	}
	if !found do append(&bridge_models_cache, bridge_models_clone(value, alloc))
	path := bridge_models_path(); defer delete(path)
	if slash := strings.last_index_byte(path, '/'); slash > 0 do _ = bridge_make_directory_all(path[:slash])
	bytes, err := json.marshal(Bridge_Provider_Models_Wire{providers = bridge_models_cache[:]}, allocator = context.temp_allocator)
	if err != nil do return
	tmp := strings.concatenate({path, ".tmp"}); defer delete(tmp)
	if os.write_entire_file(tmp, bytes) == nil {
		if os.rename(tmp, path) != nil do _ = os.remove(tmp)
	}
}

bridge_model_string :: proc(obj: json.Object, key: string) -> string {
	if value, ok := obj[key].(json.String); ok do return string(value)
	return ""
}

bridge_model_id_valid :: proc(id: string) -> bool {
	if len(id) == 0 || len(id) > 256 || id[0] == '-' do return false
	for ch in id do if ch <= ' ' || ch == 127 do return false
	return true
}

// Allocates model strings using the caller's allocator, never borrowing JSON.
bridge_models_append :: proc(models: ^[dynamic]Bridge_Discovered_Model, id, label, resolved: string) -> bool {
	if !bridge_model_id_valid(id) || (resolved != "" && !bridge_model_id_valid(resolved)) do return false
	label := label
	if len(label) > 512 do label = id // preserve a valid model despite display metadata
	for model in models do if model.model_id == id do return true
	if len(models) >= BRIDGE_MODEL_LIMIT do return false
	append(models, Bridge_Discovered_Model{strings.clone(id), strings.clone(label if label != "" else id), strings.clone(resolved)})
	return true
}

// A malformed entry invalidates the entire page; callers discard partial results.
bridge_models_parse_array :: proc(provider: string, array: json.Array, models: ^[dynamic]Bridge_Discovered_Model) -> bool {
	for entry in array {
		obj, ok := entry.(json.Object)
		if !ok do return false
		id, label, resolved := "", "", ""
		switch provider {
		case "claude": id = bridge_model_string(obj, "value"); label = bridge_model_string(obj, "displayName"); resolved = bridge_model_string(obj, "resolvedModel")
		case "codex":
			if hidden, _ := obj["hidden"].(json.Boolean); bool(hidden) do continue
			id = bridge_model_string(obj, "model"); label = bridge_model_string(obj, "displayName")
		case "pi":
			upstream := bridge_model_string(obj, "provider")
			// Pi's user-defined provider names do not follow Heimdall's own
			// catalog slug grammar (they can contain capitals and underscores).
			if !bridge_model_id_valid(upstream) || strings.contains(upstream, "/") || !bridge_model_id_valid(bridge_model_string(obj, "id")) do return false
			id = fmt.tprintf("%s/%s", upstream, bridge_model_string(obj, "id")); label = bridge_model_string(obj, "name")
		case "copilot":
			if policy, policy_ok := obj["policy"].(json.Object); policy_ok {
				if state := bridge_model_string(policy, "state"); state != "" && state != "enabled" do continue
			}
			id = bridge_model_string(obj, "id"); label = bridge_model_string(obj, "name")
		case: return false
		}
		if !bridge_models_append(models, id, label, resolved) do return false
	}
	return true
}

bridge_models_parse_agy :: proc(text: string, models: ^[dynamic]Bridge_Discovered_Model) -> bool {
	for line in strings.split_lines(text, context.temp_allocator) {
		line := strings.trim_space(line)
		if line == "" do continue
		cut := strings.index_byte(line, '\t')
		if cut < 0 do cut = strings.index(line, "  ")
		if cut <= 0 do return false
		if !bridge_models_append(models, line[:cut], strings.trim_space(line[cut:]), "") do return false
	}
	// Empty output is not a documented successful agy model list.
	return len(models) > 0
}

// Returns matched/valid/cursor. Ignore unrelated protocol notifications.
bridge_models_parse_reply :: proc(provider, text: string, expected_id: int, models: ^[dynamic]Bridge_Discovered_Model) -> (matched, valid: bool, cursor: string, auth_error: bool) {
	value, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil do return false, false, "", false
	obj, ok := value.(json.Object)
	if !ok do return false, false, "", false
	root := obj
	if provider == "claude" {
		if bridge_model_string(obj, "type") != "control_response" do return false, false, "", false
		response, _ := obj["response"].(json.Object)
		if bridge_model_string(response, "request_id") != "models" do return false, false, "", false
		if bridge_model_string(response, "subtype") != "success" do return true, false, "", false
		root, _ = response["response"].(json.Object)
	} else if provider == "pi" {
		if bridge_model_string(obj, "id") != "models" || bridge_model_string(obj, "command") != "get_available_models" do return false, false, "", false
		if success, _ := obj["success"].(json.Boolean); !bool(success) do return true, false, "", false
		root, _ = obj["data"].(json.Object)
	} else {
		id, id_ok := obj["id"].(json.Float)
		if !id_ok || id != json.Float(expected_id) do return false, false, "", false
		if error_obj, has_error := obj["error"].(json.Object); has_error {
			message := strings.to_lower(bridge_model_string(error_obj, "message"), context.temp_allocator)
			return true, false, "", strings.contains(message, "auth") || strings.contains(message, "login")
		}
		root, _ = obj["result"].(json.Object)
	}
	key := "data" if provider == "codex" else "models"
	array, array_ok := root[key].(json.Array)
	if !array_ok do return true, false, "", false
	if !bridge_models_parse_array(provider, array, models) do return true, false, "", false
	if next, present := root["nextCursor"]; present {
		if _, is_null := next.(json.Null); !is_null {
			if _, is_string := next.(json.String); !is_string do return true, false, "", false
		}
	}
	return true, true, strings.clone(bridge_model_string(root, "nextCursor")), false
}

bridge_models_write_request :: proc(input: ^os.File, body: string, framed: bool) -> bool {
	text := fmt.tprintf("Content-Length: %d\r\n\r\n%s", len(body), body) if framed else fmt.tprintf("%s\n", body)
	n, err := os.write_string(input, text)
	return err == nil && n == len(text)
}

// No prompts, threads, or inference turns are submitted. The only writes are
// small metadata requests; stdout is drained while the child is alive.
bridge_models_probe :: proc(provider, binary: string, timeout := BRIDGE_MODEL_PROBE_TIMEOUT, working_dir: string = "", child_env: []string = nil, launch_args: []string = nil) -> (models: [dynamic]Bridge_Discovered_Model, state: string) {
	state = "error"
	models = make([dynamic]Bridge_Discovered_Model)
	if timeout <= 0 do return models, "timeout"
	args := make([dynamic]string, context.temp_allocator)
	append(&args, binary)
	request := ""
	switch provider {
	case "claude":
		append(&args, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--strict-mcp-config", "--mcp-config", `{"mcpServers":{}}`, "--tools", "", "--settings", `{"disableAllHooks":true}`)
		request = `{"type":"control_request","request_id":"models","request":{"subtype":"initialize"}}`
	case "codex": append(&args, "app-server")
	case "pi":
		append(&args, "--offline", "--no-session", "--no-extensions", "--no-mcp", "--no-skills", "--no-prompt-templates", "--mode", "rpc")
		request = `{"id":"models","type":"get_available_models"}`
	case "copilot":
		append(&args, "--server", "--stdio")
		request = `{"jsonrpc":"2.0","id":2,"method":"models.list","params":{}}`
	case "antigravity": append(&args, "models")
	case: return models, "unsupported"
	}
	append(&args, ..launch_args)
	if binary == "" do return models, "absent"
	if !bridge_process_slot_try_acquire() do return models, "busy"
	defer bridge_process_slot_release()
	in_r, in_w, in_err := os.pipe()
	if in_err != nil do return
	out_r, out_w, out_err := os.pipe()
	if out_err != nil { os.close(in_r); os.close(in_w); return }
	defer os.close(in_w)
	defer os.close(out_r)
	env := child_env
	if env == nil {
		env_err: os.Error
		env,env_err = os.environ(context.temp_allocator)
	if env_err != nil { os.close(in_r); os.close(out_w); return }
	}
	clean_env := make([dynamic]string, context.temp_allocator)
	for e in env {
		if strings.has_prefix(e, "CLAUDECODE=") || strings.has_prefix(e, "COPILOT_AUTO_UPDATE=") do continue
		append(&clean_env, e)
	}
	append(&clean_env, "COPILOT_AUTO_UPDATE=false")
	path := bridge_models_path(); defer delete(path)
	cwd := strings.clone(working_dir) if working_dir != "" else strings.concatenate({path, ".probe"}); defer delete(cwd)
	if err := bridge_make_directory_all(cwd); err != nil && !os.is_dir(cwd) { os.close(in_r); os.close(out_w); return }
	process, started := bridge_model_process_start({command = args[:], stdin = in_r, stdout = out_w, env = clean_env[:], working_dir = cwd})
	os.close(in_r); os.close(out_w)
	if !started do return
	// Always terminate the owned process tree before reaping. No wait/reap races
	// or reader threads can outlive this invocation.
	defer if process.pid > 0 { bridge_model_process_kill(process); _, _ = os.process_wait(process, 500 * time.Millisecond) }
	framed := provider == "copilot"
	if provider == "codex" {
		if !bridge_models_write_request(in_w, `{"id":1,"method":"initialize","params":{"clientInfo":{"name":"heimdall-model-discovery","version":"1"}}}`, false) do return
		if !bridge_models_write_request(in_w, `{"method":"initialized","params":{}}`, false) do return
		request = `{"id":2,"method":"model/list","params":{"limit":100,"includeHidden":false}}`
	}
	if request != "" && !bridge_models_write_request(in_w, request, framed) do return
	buffer := make([dynamic]byte); defer delete(buffer)
	total, expected_id := 0, 2
	deadline := time.time_add(time.now(), timeout)
	for time.diff(time.now(), deadline) > 0 {
		ready, err := os.pipe_has_data(out_r)
		if err != nil {
			if provider == "antigravity" && err == .Broken_Pipe && bridge_models_parse_agy(string(buffer[:]), &models) {
				bridge_model_process_kill(process)
				status, wait_err := os.process_wait(process, 500 * time.Millisecond)
				process = {}
				if wait_err == nil && status.exited && status.exit_code == 0 do return models, "success"
			}
			return
		}
		if !ready { time.sleep(5 * time.Millisecond); continue }
		chunk: [8192]byte
		n, read_err := os.read(out_r, chunk[:])
		if read_err != nil || n == 0 {
			if provider == "antigravity" && bridge_models_parse_agy(string(buffer[:]), &models) {
				status, wait_err := os.process_wait(process, 0)
				if wait_err == nil && status.exited && status.exit_code == 0 {
					// Already reaped: prevent cleanup from targeting a reused pid.
					process = {}; return models, "success"
				}
			}
			return
		}
		total += n
		if total > BRIDGE_MODEL_OUTPUT_LIMIT do return models, "output_limit"
		append(&buffer, ..chunk[:n])
		if provider == "antigravity" do continue
		for {
			message, consumed := "", 0
			if framed {
				if header_end := strings.index(string(buffer[:]), "\r\n\r\n"); header_end >= 0 {
					header := string(buffer[:header_end])
					if !strings.has_prefix(header, "Content-Length: ") do return
					length, valid := strconv.parse_int(header[len("Content-Length: "):])
					if !valid || length < 0 || length > BRIDGE_MODEL_OUTPUT_LIMIT do return
					if len(buffer) >= header_end+4+length { consumed = header_end+4+length; message = string(buffer[header_end+4:consumed]) }
				} else if len(buffer) > 4096 do return
			} else if newline := strings.index_byte(string(buffer[:]), '\n'); newline >= 0 { consumed = newline+1; message = string(buffer[:newline]) }
			if consumed == 0 do break
			matched, valid, cursor, auth := bridge_models_parse_reply(provider, message, expected_id, &models)
			if matched {
				defer delete(cursor)
				if !valid do return models, "authentication_required" if auth else "invalid_response"
				if cursor == "" do return models, "success"
				if provider != "codex" || expected_id >= 18 || len(cursor) > 256 do return models, "page_limit"
				expected_id += 1
				cursor_json, _ := json.marshal(cursor, allocator = context.temp_allocator)
				body := fmt.tprintf(`{"id":%d,"method":"model/list","params":{"limit":100,"includeHidden":false,"cursor":%s}}`, expected_id, string(cursor_json))
				if !bridge_models_write_request(in_w, body, false) do return
			}
			copy(buffer[:], buffer[consumed:]); resize(&buffer, len(buffer)-consumed)
		}
	}
	return models, "timeout"
}

bridge_models_source :: proc(provider: string) -> string {
	switch provider {
	case "claude": return "claude_control"
	case "codex": return "codex_app_server"
	case "pi": return "pi_rpc"
	case "antigravity": return "agy_models"
	case "copilot": return "copilot_rpc"
	}
	return "unsupported"
}

bridge_models_apply_probe :: proc(previous: ^Bridge_Provider_Models, models: []Bridge_Discovered_Model, state, path, version, checked: string) {
	state := state
	if state == "success" {
		encoded, err := json.marshal(models, allocator = context.temp_allocator)
		if err != nil || len(encoded) > BRIDGE_MODEL_SNAPSHOT_LIMIT do state = "output_limit"
	}
	delete(previous.models_attempted_at); previous.models_attempted_at = strings.clone(checked)
	delete(previous.models_state); previous.models_state = strings.clone(state)
	if state == "success" {
		for model in previous.models { delete(model.model_id); delete(model.label); delete(model.resolved_model) }
		delete(previous.models)
		previous.models = make([]Bridge_Discovered_Model, len(models))
		for model, i in models do previous.models[i] = {strings.clone(model.model_id), strings.clone(model.label), strings.clone(model.resolved_model)}
		previous.has_snapshot = true
		delete(previous.binary_path); previous.binary_path = strings.clone(path)
		delete(previous.models_checked_at); previous.models_checked_at = strings.clone(checked)
		delete(previous.models_source); previous.models_source = strings.clone(bridge_models_source(previous.provider))
		delete(previous.version_text); previous.version_text = strings.clone(version)
	}
}

Bridge_Model_Job :: struct {
	provider, path, version, working_dir: string,
	deadline_ns: i64,
	profile: Provider_Profile,
	previous, result: Bridge_Provider_Models,
}
bridge_models_refresh_worker :: proc(th: ^thread.Thread) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	job := (^Bridge_Model_Job)(th.data)
	previous := job.previous // consumes a heap-owned snapshot; returned in result
	job.previous = {}
	remaining := time.Duration(job.deadline_ns - time.to_unix_nanoseconds(time.now()))
	env, env_ok := profile_child_env(&job.profile)
	models := make([dynamic]Bridge_Discovered_Model)
	state := "error"
	if env_ok {
		delete(models)
		models,state = bridge_models_probe(job.provider, job.path if bridge_provider_path_executable(job.path) else "", min(remaining, BRIDGE_MODEL_PROBE_TIMEOUT), job.working_dir,env,profile_tokenize_args(job.profile.config.launch_args))
	}
	defer { for model in models { delete(model.model_id); delete(model.label); delete(model.resolved_model) }; delete(models) }
	checked := bridge_provider_probe_time(); defer delete(checked)
	bridge_models_apply_probe(&previous, models[:], state, job.path, job.version, checked)
	job.result = previous
}

bridge_models_refresh :: proc(providers: []string, deadline_ns: i64 = 0, requested_ns: i64 = 0, profile_id: string = "") -> [dynamic]Bridge_Provider_Models {
	started := requested_ns if requested_ns > 0 else time.to_unix_nanoseconds(time.now())
	out := make([dynamic]Bridge_Provider_Models)
	// An absent/empty stage-2 filter means no enabled providers, never all.
	if len(providers) == 0 || len(providers) > 16 do return bridge_models_profile_views(out,profile_id)
	deadline_ns := deadline_ns
	if deadline_ns == 0 do deadline_ns = started + i64(25*time.Second)
	for !sync.mutex_try_lock(&bridge_models_refresh_mu) {
		if time.to_unix_nanoseconds(time.now()) >= deadline_ns {
			for provider in providers {
				value := bridge_models_get(provider,profile_id = profile_id)
				delete(value.models_state); value.models_state = strings.clone("busy")
				delete(value.models_attempted_at); value.models_attempted_at = bridge_provider_probe_time()
				append(&out, value)
			}
			return bridge_models_profile_views(out,profile_id)
		}
		time.sleep(5*time.Millisecond)
	}
	defer sync.mutex_unlock(&bridge_models_refresh_mu)
	bridge_provider_paths_init()
	filter_key := bridge_provider_discovery_key(providers); defer delete(filter_key)
	key := strings.clone(filter_key) if profile_id == "" else strings.concatenate({profile_id,"|",filter_key}); defer delete(key)
	if key == bridge_models_last_key && bridge_models_last_completed > started {
		for provider in providers {
			value := bridge_models_get(provider,profile_id = profile_id)
			append(&out,value)
		}
		return bridge_models_profile_views(out,profile_id)
	}
	jobs := make([dynamic]Bridge_Model_Job)
	defer delete(jobs)
	for provider in providers {
		if !bridge_provider_catalog_name_supported(provider) do continue
		duplicate := false
		for job in jobs do if job.provider == provider do duplicate = true
		if duplicate do continue
		p, profile_error := profile_lookup(provider,profile_id)
		if profile_error != .None {
			value := bridge_models_get(provider,profile_id = profile_id)
			delete(value.models_state); value.models_state = strings.clone("disabled" if profile_error == .Disabled else "error")
			delete(value.models_attempted_at); value.models_attempted_at = bridge_provider_probe_time()
			append(&out,value)
			continue
		}
		// Stage 2 only reads Stage 1's detection snapshot. Path resolution here
		// must not fall back to automatic version/extension probes.
		path, version := "", ""
		sync.rw_mutex_shared_lock(&bridge_provider_paths_mutex)
		for entry in bridge_provider_paths do if entry.provider == provider && profile_effective_id(provider,entry.profile_id) == p.profile_id && entry.state == "present" {
			path = strings.clone(entry.resolved_path); version = strings.clone(entry.version_text); break
		}
		sync.rw_mutex_shared_unlock(&bridge_provider_paths_mutex)
		model_path := bridge_models_path()
		working_dir := strings.concatenate({model_path,".probe-",p.profile_id},context.temp_allocator)
		delete(model_path)
		append(&jobs, Bridge_Model_Job{provider = provider, path = path, version = version, deadline_ns = deadline_ns, previous = bridge_models_get(provider, runtime.default_allocator(),profile_id), profile = p, working_dir = working_dir})
	}
	workers := make([dynamic]^thread.Thread); defer delete(workers)
	for &job in jobs {
		worker := thread.create(bridge_models_refresh_worker)
		worker.data = rawptr(&job); thread.start(worker); append(&workers, worker)
	}
	for worker in workers { thread.join(worker); thread.destroy(worker) }
	for &job in jobs {
		bridge_models_save(job.result)
		append(&out, bridge_models_clone(job.result))
		bridge_models_destroy(&job.result, runtime.default_allocator())
		delete(job.path); delete(job.version)
	}
	delete(bridge_models_last_key, runtime.default_allocator())
	bridge_models_last_key = strings.clone(key, runtime.default_allocator())
	bridge_models_last_completed = time.to_unix_nanoseconds(time.now())
	return bridge_models_profile_views(out,profile_id)
}

bridge_provider_handle_models_frame :: proc(conn: ^ws.Connection, frame_type, text: string) -> bool {
	if frame_type != "provider_models_discover" do return false
	request_id := extract_json_string(text, "request_id", ""); defer delete(request_id)
	providers, _ := bridge_provider_json_extract_string_array(text, "providers")
	defer { for provider in providers do delete(provider); delete(providers) }
	profile_id := extract_json_string(text,"profile_id",""); defer delete(profile_id)
	results := bridge_models_refresh(providers, bridge_command_worker_deadline_ns(conn), bridge_command_worker_enqueued_ns(conn),profile_id)
	defer { for &result in results do bridge_models_destroy(&result); delete(results) }
	report := struct { type: string `json:"type"`, request_id: string `json:"request_id"`, command_id: string `json:"command_id"`, providers: []Bridge_Provider_Models `json:"providers"` }{"provider_model_discovery_report", request_id, request_id, results[:]}
	bytes, err := json.marshal(report)
	if err == nil { defer delete(bytes); _ = bridge_hub_send(conn, string(bytes)) }
	return true
}

// Merge owned outbound models without persisting custom settings into probe provenance.
bridge_models_with_custom :: proc(value: Bridge_Provider_Models, custom: []string) -> Bridge_Provider_Models {
	out := value
	delete(out.observed_models_json)
	observed,err:=json.marshal(value.models)
	out.observed_models_json=string(observed) if err==nil else ""
	for id in out.custom_models do delete(id)
	delete(out.custom_models)
	out.custom_models=make([]string,len(custom))
	for id,i in custom do out.custom_models[i]=strings.clone(id)
	models := make([dynamic]Bridge_Discovered_Model)
	append(&models,..out.models)
	delete(out.models)
	for id in custom do _ = bridge_models_append(&models,id,id,"")
	out.models = models[:]
	return out
}

bridge_models_profile_views :: proc(values: [dynamic]Bridge_Provider_Models, profile_id: string) -> [dynamic]Bridge_Provider_Models {
	for &value in values {
		p,e := profile_lookup(value.provider,profile_id)
		if e != .None {
			delete(value.models_state)
			value.models_state = strings.clone("disabled" if e == .Disabled else "error")
		} else {
			value = bridge_models_with_custom(value,p.config.custom_models)
		}
	}
	return values
}
