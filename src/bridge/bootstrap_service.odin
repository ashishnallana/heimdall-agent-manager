package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import httpc "odin_test:lib/httpc"
import agent_runtime "odin_test:lib/agent_runtime"

// Bridge_Bootstrap_Result carries the staged outcome of a conditional bootstrap
// fetch so callers (and logs) can distinguish WHERE a launch failed instead of
// collapsing every cause to one opaque message (BRG-4).
Bridge_Bootstrap_Result :: struct {
	ok:          bool,
	stage:       string, // e.g. "manifest_get", "blob_fetch", "assemble", "write_run_dir"
	http_status: int,    // last HTTP status seen at the failing stage (0 if N/A)
	detail:      string,
}

// bridge_bootstrap_result_error classifies a failed bootstrap: hub fetches carry
// their HTTP status (0 = transport, retriable), a rejected descriptor is fatal,
// and a local assemble/write failure is recoverable (it needs a fixed manifest
// or disk, not another identical attempt).
bridge_bootstrap_result_error :: proc(r: Bridge_Bootstrap_Result) -> Bridge_Error {
	switch r.stage {
	case "validate":
		return bridge_error(.agent_bootstrap_invalid, .unsupported)
	case "manifest_get", "blob_fetch":
		if r.http_status == 0 do return bridge_error(.agent_bootstrap_invalid, .transport)
		return bridge_error(.agent_bootstrap_invalid, .other, r.http_status)
	}
	return bridge_error(.agent_bootstrap_invalid)
}

// Retry/backoff for the individually-retriable hub calls (BRG-4/RETRY-1): the
// conditional manifest GET and each per-hash blob GET retry alone with a short
// exponential backoff so a transient failure of one small request never fails the
// whole launch.
BRIDGE_BOOTSTRAP_MAX_ATTEMPTS :: BRIDGE_RETRY_MAX_ATTEMPTS
BRIDGE_BOOTSTRAP_BASE_BACKOFF_MS :: BRIDGE_RETRY_BASE_BACKOFF_MS

bridge_bootstrap_backoff_sleep :: proc(attempt: int) {
	bridge_http_backoff_sleep(attempt, BRIDGE_BOOTSTRAP_BASE_BACKOFF_MS)
}

// bridge_bootstrap_http_get_retry issues a GET with retry/backoff. It treats a
// transport failure OR a 5xx/429 as retriable; any other status is returned to
// the caller to interpret (200/304/404/...). The final response+ok are returned.
bridge_bootstrap_http_get_retry :: proc(req: httpc.Request, deadline_ns: i64 = 0) -> (httpc.Response, httpc.Error) {
	get := req
	get.method = .GET
	return bridge_http_request_retry(get, deadline_ns = deadline_ns)
}

bridge_bootstrap_fetch_and_materialize :: proc(hub_url, bridge_token, instance_id, run_dir, bridge_endpoint, agent_token, provider: string) -> bool {
	if strings.trim_space(hub_url) == "" || strings.trim_space(bridge_token) == "" || strings.trim_space(instance_id) == "" || strings.trim_space(run_dir) == "" do return false
	headers := [?]httpc.Header{httpc.bearer(bridge_token)}
	resp, http_err := bridge_http_request_retry({method = .GET, url = bridge_hub_url(hub_url), path = {"api", "v1", "bridge", "agent-instances", instance_id, "bootstrap"}, headers = headers[:]})
	defer httpc.response_destroy(&resp)
	if http_err != .None || resp.status != 200 do return false
	resp_body := httpc.text(resp)
	_ = bridge_make_directory_all(run_dir)
	content := bridge_bootstrap_decrypt_owned(extract_json_string(resp_body, "content", strings.concatenate({"# Agent bootstrap\n\nInstance: ", instance_id, "\n"})))
	agents_md_name := bridge_bootstrap_agents_md_name(provider)
	bridge_bootstrap_cleanup_stale_agents_md(run_dir, agents_md_name)
	if os.write_entire_file(strings.concatenate({strings.trim_right(run_dir, "/"), "/", agents_md_name}), content) != nil do return false
	mem_content := extract_json_string(resp_body, "memory_md", "")
	if mem_content == "" {
		delete(mem_content)
		mem_content = extract_json_string(resp_body, "MEMORY.md", "")
	}
	mem_content = bridge_bootstrap_decrypt_owned(mem_content)
	has_mem := mem_content != ""
	if has_mem {
		mem_path := strings.concatenate({strings.trim_right(run_dir, "/"), "/MEMORY.md"})
		defer delete(mem_path)
		_ = os.write_entire_file(mem_path, transmute([]u8)mem_content)
	}
	delete(mem_content)
	skill_paths := bridge_bootstrap_write_skills(run_dir, provider, resp_body)
	if !bridge_bootstrap_write_ham_ctl_wrapper(run_dir, bridge_endpoint, agent_token, instance_id) do return false
	manifest := strings.builder_make()
	strings.write_string(&manifest, "{\"agent_instance_id\":\""); strings.write_string(&manifest, instance_id)
	strings.write_string(&manifest, "\",\"managed_files\":[{\"relative_path\":\""); bridge_bootstrap_json_string(&manifest, agents_md_name); strings.write_string(&manifest, "\",\"kind\":\"AGENTS_MD\"},{\"relative_path\":\"" + agent_runtime.CTL_SHIM_PATH + "\",\"kind\":\"CTL_WRAPPER\"}")
	if has_mem {
		strings.write_string(&manifest, ",{\"relative_path\":\"MEMORY.md\",\"kind\":\"MEMORY_MD\"}")
	}
	for skill_path in skill_paths {
		strings.write_string(&manifest, ",{\"relative_path\":\""); bridge_bootstrap_json_string(&manifest, skill_path); strings.write_string(&manifest, "\",\"kind\":\"SKILL\"}")
	}
	strings.write_string(&manifest, "]}")
	if os.write_entire_file(strings.concatenate({run_dir, "/heimdall-bootstrap-manifest.json"}), strings.to_string(manifest)) != nil do return false
	return true
}

bridge_bootstrap_write_skills :: proc(run_dir, provider, body: string) -> []string {
	written := make([dynamic]string)
	if skills_array, ok := bridge_provider_json_extract_array(body, "skills"); ok {
		for obj in bridge_provider_json_top_level_objects(skills_array) {
			name := bridge_provider_json_extract_string(obj, "name", "")
			content := bridge_bootstrap_decrypt_owned(bridge_provider_json_extract_string(obj, "content", ""))
			plain_name := bridge_decrypt_embedded_vault_tokens(name)
			path := bridge_bootstrap_skill_relative_path(provider, plain_name)
			if bridge_bootstrap_write_skill_file(run_dir, path, content) do append(&written, path)
		}
	}
	if len(written) == 0 {
		skill_name := extract_json_string(body, "default_skill_name", "heimdall-ctl-communication")
		skill_content := extract_json_string(body, "default_skill_content", "")
		skill_path := bridge_bootstrap_skill_relative_path(provider, skill_name)
		if bridge_bootstrap_write_skill_file(run_dir, skill_path, skill_content) do append(&written, skill_path)
	}
	return written[:]
}

bridge_bootstrap_materialize_local_provider_test :: proc(run_dir, bridge_endpoint, agent_token, instance_id, provider: string) -> bool {
	if strings.trim_space(run_dir) == "" || strings.trim_space(bridge_endpoint) == "" || strings.trim_space(agent_token) == "" || strings.trim_space(instance_id) == "" do return false
	_ = bridge_make_directory_all(run_dir)
	content := strings.concatenate({"# Provider test bootstrap\n\nInstance: ", instance_id, "\nProvider: ", provider, "\n\nThis is a temporary Ninjy provider smoke-test run. Report readiness with `" + agent_runtime.CTL_SHIM_INVOCATION + " agent start-success` after the provider is usable.\n"})
	agents_md_name := bridge_bootstrap_agents_md_name(provider)
	bridge_bootstrap_cleanup_stale_agents_md(run_dir, agents_md_name)
	if os.write_entire_file(strings.concatenate({strings.trim_right(run_dir, "/"), "/", agents_md_name}), content) != nil do return false
	if !bridge_bootstrap_write_ham_ctl_wrapper(run_dir, bridge_endpoint, agent_token, instance_id) do return false
	manifest := strings.builder_make()
	strings.write_string(&manifest, "{\"agent_instance_id\":\""); strings.write_string(&manifest, instance_id)
	strings.write_string(&manifest, "\",\"provider_test\":true,\"managed_files\":[{\"relative_path\":\""); bridge_bootstrap_json_string(&manifest, agents_md_name); strings.write_string(&manifest, "\",\"kind\":\"AGENTS_MD\"},{\"relative_path\":\"" + agent_runtime.CTL_SHIM_PATH + "\",\"kind\":\"CTL_WRAPPER\"}]}")
	if os.write_entire_file(strings.concatenate({strings.trim_right(run_dir, "/"), "/heimdall-bootstrap-manifest.json"}), strings.to_string(manifest)) != nil do return false
	return true
}

// bridge_bootstrap_free_object_slice frees a []string of cloned JSON objects
// (as returned by bridge_provider_json_top_level_objects): both each element and
// the backing slice.
bridge_bootstrap_free_object_slice :: proc(objs: []string) {
	for o in objs do delete(o)
	delete(objs)
}

// bridge_bootstrap_agents_md_name resolves the bootstrap filename the agent
// reads on startup. It honors the provider profile's configurable
// bootstrap_file_name (surfaced from bootstrap.features['AGENTS_MD'].name); a
// blank value falls back to the profile default (CLAUDE.md for the claude
// profile, AGENTS.md otherwise). The name is validated to a bare, safe filename
// so a store override can never escape the run dir.
bridge_bootstrap_agents_md_name :: proc(provider: string) -> string {
	if profile, ok := bridge_provider_by_name_or_default(provider); ok {
		name := strings.trim_space(profile.bootstrap_file_name)
		if name != "" && bridge_bootstrap_is_safe_bootstrap_name(name) do return name
	}
	if strings.to_lower(strings.trim_space(provider)) == "claude" do return "CLAUDE.md"
	return "AGENTS.md"
}

// bridge_bootstrap_is_safe_bootstrap_name rejects anything that is not a plain
// filename (no path separators, no traversal, no leading dot-slash) so the
// bootstrap file always lands directly in the run dir.
bridge_bootstrap_is_safe_bootstrap_name :: proc(name: string) -> bool {
	if strings.contains(name, "/") || strings.contains(name, "\\") do return false
	if strings.contains(name, "..") do return false
	if name == "." do return false
	return true
}

// bridge_bootstrap_cleanup_stale_agents_md removes a previously-generated
// bootstrap file when the operator renames it (e.g. AGENTS.md -> CLAUDE.md) so
// the run dir never carries two competing bootstrap docs. Only the well-known
// default names are eligible for removal, and only when they differ from the
// active name, so user-authored files are never touched.
bridge_bootstrap_cleanup_stale_agents_md :: proc(run_dir, active_name: string) {
	candidates := [?]string{"AGENTS.md", "CLAUDE.md"}
	for candidate in candidates {
		if candidate == active_name do continue
		path := strings.concatenate({strings.trim_right(run_dir, "/"), "/", candidate})
		if _, err := os.stat(path, context.allocator); err == nil {
			bridge_os_remove_file(path)
		}
	}
}

bridge_bootstrap_skill_relative_path :: proc(provider, skill_name: string) -> string {
	profile, ok := bridge_provider_by_name_or_default(provider)
	skill_dir := ""
	if ok do skill_dir = strings.trim_space(profile.skill_dir)
	if skill_dir == "" do skill_dir = bridge_provider_default_skill_dir(provider)
	if skill_dir == "" do return ""
	name := bridge_bootstrap_safe_path_part(skill_name)
	if name == "" do name = "heimdall-ctl-communication"
	return strings.concatenate({strings.trim_right(skill_dir, "/"), "/", name, "/SKILL.md"})
}

bridge_bootstrap_safe_path_part :: proc(value: string) -> string {
	b := strings.builder_make()
	for ch in strings.trim_space(value) {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '-': strings.write_rune(&b, ch)
		case '_', ' ', '.': strings.write_byte(&b, '-')
		case:
		}
	}
	return strings.to_string(b)
}

bridge_bootstrap_write_skill_file :: proc(run_dir, relative_path, content: string) -> bool {
	if strings.trim_space(relative_path) == "" || strings.trim_space(content) == "" do return false
	if strings.has_prefix(relative_path, "/") || strings.contains(relative_path, "..") do return false
	full_path := strings.concatenate({strings.trim_right(run_dir, "/"), "/", relative_path})
	if slash := strings.last_index_byte(full_path, '/'); slash > 0 {
		_ = bridge_make_directory_all(full_path[:slash])
	}
	return os.write_entire_file(full_path, content) == nil
}

bridge_bootstrap_json_string :: proc(b: ^strings.Builder, value: string) {
	for ch in value {
		switch ch {
		case '\\': strings.write_string(b, "\\\\")
		case '"': strings.write_string(b, "\\\"")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case: strings.write_rune(b, ch)
		}
	}
}

// bridge_bootstrap_render_ham_ctl_shim renders the ham-ctl shim script content in
// memory (BRG-3): the bridge holds the tokens/endpoint + resolved ctl-binary path,
// so it renders the shim and the wrapper merely places it (chmod +x). Returns
// ("", false) when ham-ctl cannot be resolved.
bridge_bootstrap_render_ham_ctl_shim :: proc(bridge_endpoint, agent_token, instance_id: string) -> (string, bool) {
	ctl := bridge_bootstrap_sh_path(bridge_bootstrap_ham_ctl_path())
	if strings.trim_space(ctl) == "" do return "", false
	b := strings.builder_make()
	strings.write_string(&b, "#!/bin/sh\n")
	strings.write_string(&b, "export HEIMDALL_BRIDGE_ENDPOINT="); bridge_bootstrap_shell_quote(&b, bridge_endpoint); strings.write_byte(&b, '\n')
	strings.write_string(&b, "export HEIMDALL_AGENT_TOKEN="); bridge_bootstrap_shell_quote(&b, agent_token); strings.write_byte(&b, '\n')
	strings.write_string(&b, "export HEIMDALL_AGENT_INSTANCE_ID="); bridge_bootstrap_shell_quote(&b, instance_id); strings.write_byte(&b, '\n')
	strings.write_string(&b, "exec "); bridge_bootstrap_shell_quote(&b, ctl); strings.write_string(&b, " \"$@\"\n")
	return strings.to_string(b), true
}

bridge_bootstrap_write_ham_ctl_wrapper :: proc(run_dir, bridge_endpoint, agent_token, instance_id: string) -> bool {
	ctl := bridge_bootstrap_sh_path(bridge_bootstrap_ham_ctl_path())
	if strings.trim_space(ctl) == "" {
		fmt.eprintln("bridge bootstrap failed: ham-ctl not found; set HEIMDALL_HAM_CTL_BIN or put ham-ctl on PATH (the flake `bridge` app sets this automatically)")
		return false
	}
	bin_dir := strings.concatenate({strings.trim_right(run_dir, "/"), "/", agent_runtime.CTL_SHIM_DIR})
	_ = bridge_make_directory_all(bin_dir)
	wrapper_path := bridge_prespawn_ctl_bin_path(run_dir)
	bridge_os_remove_file(wrapper_path)
	b := strings.builder_make()
	strings.write_string(&b, "#!/bin/sh\n")
	strings.write_string(&b, "export HEIMDALL_BRIDGE_ENDPOINT="); bridge_bootstrap_shell_quote(&b, bridge_endpoint); strings.write_byte(&b, '\n')
	strings.write_string(&b, "export HEIMDALL_AGENT_TOKEN="); bridge_bootstrap_shell_quote(&b, agent_token); strings.write_byte(&b, '\n')
	strings.write_string(&b, "export HEIMDALL_AGENT_INSTANCE_ID="); bridge_bootstrap_shell_quote(&b, instance_id); strings.write_byte(&b, '\n')
	strings.write_string(&b, "exec "); bridge_bootstrap_shell_quote(&b, ctl); strings.write_string(&b, " \"$@\"\n")
	if os.write_entire_file(wrapper_path, strings.to_string(b)) != nil do return false
	bridge_os_make_owner_executable(wrapper_path)
	when ODIN_OS == .Windows {
		cmd_shim, cmd_ok := bridge_bootstrap_render_ham_ctl_cmd_shim(bridge_endpoint, agent_token, instance_id)
		if !cmd_ok do return false
		defer delete(cmd_shim)
		cmd_path := strings.concatenate({wrapper_path, ".cmd"}, context.temp_allocator)
		if os.write_entire_file(cmd_path, cmd_shim) != nil do return false
	}
	return true
}

// bridge_bootstrap_sh_path writes a Windows path with forward slashes, which both
// Git Bash (the shell agent CLIs use on Windows) and Win32 accept, and which needs
// no escaping inside the sh shim. Unix paths are returned unchanged.
bridge_bootstrap_sh_path :: proc(path: string) -> string {
	when ODIN_OS == .Windows {
		out, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
		return out
	} else {
		return path
	}
}

// bridge_bootstrap_render_ham_ctl_cmd_shim renders the cmd.exe twin of the sh shim
// (agent_runtime.CTL_SHIM_CMD_PATH) so the shim also works from
// PowerShell and cmd on Windows (both resolve it through PATHEXT). `%` is doubled;
// a value cmd cannot hold inside set "..." (a quote or a line break) is refused
// rather than written wrongly. Caller owns the result.
bridge_bootstrap_render_ham_ctl_cmd_shim :: proc(bridge_endpoint, agent_token, instance_id: string) -> (string, bool) {
	ctl := bridge_bootstrap_ham_ctl_path()
	if strings.trim_space(ctl) == "" do return "", false
	for v in ([?]string{bridge_endpoint, agent_token, instance_id, ctl}) {
		if strings.contains_any(v, "\"\r\n") do return "", false
	}
	esc :: proc(v: string) -> string {
		out, _ := strings.replace_all(v, "%", "%%", context.temp_allocator)
		return out
	}
	b := strings.builder_make()
	strings.write_string(&b, "@echo off\r\n")
	strings.write_string(&b, "set \"HEIMDALL_BRIDGE_ENDPOINT="); strings.write_string(&b, esc(bridge_endpoint)); strings.write_string(&b, "\"\r\n")
	strings.write_string(&b, "set \"HEIMDALL_AGENT_TOKEN="); strings.write_string(&b, esc(agent_token)); strings.write_string(&b, "\"\r\n")
	strings.write_string(&b, "set \"HEIMDALL_AGENT_INSTANCE_ID="); strings.write_string(&b, esc(instance_id)); strings.write_string(&b, "\"\r\n")
	strings.write_string(&b, "\""); strings.write_string(&b, esc(ctl)); strings.write_string(&b, "\" %*\r\n")
	return strings.to_string(b), true
}

bridge_bootstrap_shell_quote :: proc(b: ^strings.Builder, value: string) {
	strings.write_byte(b, '\'')
	for ch in value {
		if ch == '\'' {
			strings.write_string(b, "'\\''")
		} else {
			strings.write_rune(b, ch)
		}
	}
	strings.write_byte(b, '\'')
}

bridge_bootstrap_ham_ctl_path :: proc() -> string {
	// ham-ctl is resolved from the HEIMDALL_HAM_CTL_BIN env var (set by the service
	// file and the flake `bridge` app to the matching build), then the ham-ctl
	// installed next to this ham-bridge, then `ham-ctl` on PATH. There is
	// intentionally no config-file entry — the env var keeps the ctl bound to the
	// same build as the bridge without a stale hardcoded path in config.toml.
	env := os.get_env_alloc("HEIMDALL_HAM_CTL_BIN", context.allocator)
	exe, _ := os.get_executable_path(context.temp_allocator)
	return bridge_bootstrap_resolve_ham_ctl(env, exe)
}

// bridge_bootstrap_resolve_ham_ctl picks the ham-ctl the agent shims exec. An env
// value naming a missing or non-executable file is skipped rather than trusted:
// a service file rendered by an older setup pointed at bin/ham-ctl-<service>,
// which setup never installed, so every agent shim exec'd nothing. setup always
// installs ham-ctl beside ham-bridge in bin/, so the sibling is the fallback.
// Like bridge_bootstrap_normalize_executable_path and find_on_path, the result is
// allocated on context.allocator and owned by the caller ("" is not allocated).
bridge_bootstrap_resolve_ham_ctl :: proc(env_value, self_exe: string) -> string {
	if strings.trim_space(env_value) != "" {
		normalized := bridge_bootstrap_normalize_executable_path(env_value)
		if normalized != "" && bridge_os_is_executable(normalized) do return normalized
		if normalized != "" do fmt.eprintfln("bridge: HEIMDALL_HAM_CTL_BIN=%s is not an executable; falling back", env_value)
	}
	if self_exe != "" {
		dir := strings.trim_right(self_exe[:strings.last_index_any(self_exe, "/\\") + 1], "/\\")
		if dir != "" do for name in bridge_os_executable_names("ham-ctl") {
			candidate := strings.concatenate({dir, "/", name})
			if bridge_os_is_executable(candidate) do return candidate
			delete(candidate)
		}
	}
	if found := bridge_bootstrap_find_on_path("ham-ctl"); found != "" do return found
	return ""
}

bridge_bootstrap_normalize_executable_path :: proc(value: string) -> string {
	trimmed := strings.trim_space(value)
	if trimmed == "" do return ""
	if bridge_os_path_is_explicit(trimmed) {
		expanded := bridge_expand_home(trimmed)
		if absolute, err := os.get_absolute_path(expanded, context.allocator); err == nil && strings.trim_space(absolute) != "" do return absolute
		return expanded
	}
	return bridge_bootstrap_find_on_path(trimmed)
}

bridge_bootstrap_find_on_path :: proc(name: string) -> string {
	return bridge_runtime_find_on_path(name)
}

bootstrap_global_cache: Bootstrap_Cache

// Bridge_Bootstrap_Descriptor is the per-instance data the bridge receives inside
// the enriched launch_agent WS payload. It supplies (a) the (agent_id, role,
// provider, project) key for the conditional manifest GET and (b) the values the
// bridge injects locally into the AGENTS.md header + ctl shim, so the bridge never
// queries hub chains/agents tables for this.
Bridge_Bootstrap_Descriptor :: struct {
	instance_id:              string,
	agent_id:                 string,
	agent_name:               string,
	display_name:             string,
	role:                     string, // "coordinator" | "worker"
	coordinator_id:           string,
	coordinator_display_name: string,
	chain_id:                 string,
	chain_title:              string,
	project_id:               string,
	project_path:             string,
	conversation_id:          string,
	provider:                 string,
	pack_json:                string,
}

// bridge_bootstrap_descriptor_from_launch parses the enriched launch_agent
// payload into a descriptor. Missing fields degrade to empty; role defaults to
// "worker".
bridge_bootstrap_descriptor_from_launch :: proc(command_json: string) -> Bridge_Bootstrap_Descriptor {
	payload := bridge_provider_payload_object(command_json)
	pack_obj, _ := bridge_provider_json_extract_object(payload, "pack")
	d := Bridge_Bootstrap_Descriptor{
		instance_id              = bridge_provider_json_extract_string(payload, "agent_instance_id", ""),
		agent_id                 = bridge_provider_json_extract_string(payload, "agent_id", ""),
		agent_name               = bridge_provider_json_extract_string(payload, "agent_name", ""),
		display_name             = bridge_provider_json_extract_string(payload, "display_name", ""),
		role                     = bridge_provider_json_extract_string(payload, "role", ""),
		coordinator_id           = bridge_provider_json_extract_string(payload, "coordinator_agent_instance_id", ""),
		coordinator_display_name = bridge_provider_json_extract_string(payload, "coordinator_display_name", ""),
		chain_id                 = bridge_provider_json_extract_string(payload, "chain_id", ""),
		chain_title              = bridge_provider_json_extract_string(payload, "chain_title", ""),
		project_id               = bridge_provider_json_extract_string(payload, "project_id", ""),
		project_path             = bridge_provider_json_extract_string(payload, "project_path", ""),
		conversation_id          = bridge_provider_json_extract_string(payload, "conversation_id", ""),
		provider                 = bridge_provider_json_extract_string(payload, "name", ""),
		pack_json                = pack_obj,
	}
	if strings.trim_space(d.role) == "" do d.role = "worker"
	return d
}

// bridge_bootstrap_conditional_manifest performs the HUB-FACING half (BRG-1/BRG-2/
// BRG-4 + LOG-1): a single conditional GET to the agent-keyed bootstrap-manifest
// endpoint with If-None-Match from the persisted per-key ETag, then per-hash blob
// GETs for only the hashes missing from disk. Returns the resolved manifest JSON.
//
//   - 304 => HIT: reuse the cached manifest, fetch zero blobs.
//   - 200 => MISS: persist the new manifest+ETag, fetch only missing hashes.
//
// All hub calls retry individually with backoff; failures surface the stage +
// HTTP status via Bridge_Bootstrap_Result.
bridge_bootstrap_conditional_manifest :: proc(hub_url, bridge_token, provider: string, d: Bridge_Bootstrap_Descriptor, cache: ^Bootstrap_Cache, deadline_ns: i64 = 0) -> (string, Bridge_Bootstrap_Result) {
	auth := httpc.bearer(bridge_token)

	// Load any persisted ETag/manifest for this key to drive If-None-Match.
	prev_etag, prev_manifest, have_prev := bootstrap_manifest_store_load(cache, d.agent_id, d.role, provider, d.project_id)
	defer if have_prev { delete(prev_etag); delete(prev_manifest) }

	manifest_json := ""
	{
		headers_dyn := make([dynamic]httpc.Header, context.temp_allocator)
		append(&headers_dyn, auth)
		if have_prev do append(&headers_dyn, httpc.if_none_match(prev_etag))

		if bridge_command_deadline_expired(deadline_ns) {
			return "", Bridge_Bootstrap_Result{ok = false, stage = "manifest_get", detail = "bootstrap command deadline exceeded"}
		}
		resp, http_err := bridge_bootstrap_http_get_retry({
			url = bridge_hub_url(hub_url), path = {"api", "v1", "bridge", "agents", d.agent_id, "bootstrap-manifest"},
			query = {{"role", d.role}, {"provider", provider}, {"project", d.project_id}}, headers = headers_dyn[:],
		}, deadline_ns)
		defer httpc.response_destroy(&resp)
		if http_err != .None {
			return "", Bridge_Bootstrap_Result{ok = false, stage = "manifest_get", http_status = resp.status, detail = "conditional manifest GET failed after retries"}
		}
		resp_body := httpc.text(resp)
		if resp.status == 304 {
			if !have_prev {
				return "", Bridge_Bootstrap_Result{ok = false, stage = "manifest_get", http_status = 304, detail = "hub returned 304 but bridge has no cached manifest"}
			}
			fmt.println("bridge bootstrap manifest HIT (304)", "agent=", d.agent_id, "role=", d.role, "provider=", provider, "project=", d.project_id)
			manifest_json = strings.clone(prev_manifest)
		} else if resp.status == 200 {
			// The manifest body is wrapped in the hub API envelope {"data": ...}.
			data_obj, data_ok := bridge_provider_json_extract_object(resp_body, "data")
			if !data_ok {
				return "", Bridge_Bootstrap_Result{ok = false, stage = "manifest_get", http_status = 200, detail = "manifest 200 missing data object"}
			}
			// NOTE: data_obj is an ALIAS into resp.body (not an owned clone), so it
			// must NOT be freed here — the response is destroyed by the defer above.
			// version is json_unescape'd (owned) so it IS freed.
			version := bridge_provider_json_extract_string(data_obj, "version", "")
			defer delete(version)
			// Reconstruct the ETag from the manifest body, the same derivation the hub
			// uses for its ETag: {agent}:{role}:{provider}:{project}:{version}.
			etag := strings.concatenate({d.agent_id, ":", d.role, ":", provider, ":", d.project_id, ":", version})
			defer delete(etag)
			fmt.println("bridge bootstrap manifest MISS (200)", "agent=", d.agent_id, "role=", d.role, "provider=", provider, "project=", d.project_id, "version=", version)
			_ = bootstrap_manifest_store_save(cache, d.agent_id, d.role, provider, d.project_id, etag, data_obj)
			manifest_json = strings.clone(data_obj)
		} else {
			return "", Bridge_Bootstrap_Result{ok = false, stage = "manifest_get", http_status = resp.status, detail = "unexpected manifest status"}
		}
	}

	// Resolve every fragment/skill hash: served from disk (HIT) or fetched per-hash
	// from the hub (FETCH). Each fetch is individually retriable.
	if res := bridge_bootstrap_fetch_missing_blobs(hub_url, auth, manifest_json, cache, deadline_ns); !res.ok {
		delete(manifest_json)
		return "", res
	}
	return manifest_json, Bridge_Bootstrap_Result{ok = true, stage = "done"}
}

// bridge_bootstrap_fetch_missing_blobs walks the manifest's assembly + skill
// hashes and ensures each is present in the disk cache, fetching only the missing
// ones via GET /api/v1/bridge/blobs/{hash} (BRG-2). Logs HIT(disk) vs FETCH(hub)
// per hash (LOG-1).
bridge_bootstrap_fetch_missing_blobs :: proc(hub_url: string, auth: httpc.Header, manifest_json: string, cache: ^Bootstrap_Cache, deadline_ns: i64 = 0) -> Bridge_Bootstrap_Result {
	hashes := bridge_bootstrap_collect_manifest_hashes(manifest_json)
	defer { for h in hashes do delete(h); delete(hashes) }
	headers := [?]httpc.Header{auth}
	for h in hashes {
		if bridge_command_deadline_expired(deadline_ns) {
			return Bridge_Bootstrap_Result{ok = false, stage = "blob_fetch", detail = "bootstrap command deadline exceeded"}
		}
		if cache != nil && bootstrap_cache_has(cache, h) {
			fmt.println("bridge bootstrap blob HIT (disk)", "hash=", h)
			continue
		}
		// The hash ("sha256:<hex>") is one path segment; httpc encodes its ':'.
		resp, http_err := bridge_bootstrap_http_get_retry({url = bridge_hub_url(hub_url), path = {"api", "v1", "bridge", "blobs", h}, headers = headers[:]}, deadline_ns)
		if http_err != .None || resp.status != 200 {
			status := resp.status
			httpc.response_destroy(&resp)
			return Bridge_Bootstrap_Result{ok = false, stage = "blob_fetch", http_status = status, detail = strings.concatenate({"blob fetch failed for ", h})}
		}
		body := bridge_provider_json_extract_string(httpc.text(resp), "body", "")
		httpc.response_destroy(&resp)
		if cache != nil {
			if !bootstrap_cache_put(cache, h, body) {
				delete(body)
				return Bridge_Bootstrap_Result{ok = false, stage = "blob_fetch", http_status = 200, detail = strings.concatenate({"blob hash verify/cache failed for ", h})}
			}
		}
		delete(body)
		fmt.println("bridge bootstrap blob FETCH (hub)", "hash=", h)
	}
	return Bridge_Bootstrap_Result{ok = true, stage = "blobs_done"}
}

// bridge_bootstrap_collect_manifest_hashes returns every fragment (files[].
// assembly[].hash) and skill (skills[].hash) hash referenced by the manifest, in
// document order. Caller owns the returned strings.
bridge_bootstrap_collect_manifest_hashes :: proc(manifest_json: string) -> [dynamic]string {
	out := make([dynamic]string)
	if files_array, files_ok := bridge_provider_json_extract_array(manifest_json, "files"); files_ok {
		file_objs := bridge_provider_json_top_level_objects(files_array)
		defer bridge_bootstrap_free_object_slice(file_objs)
		for f_obj in file_objs {
			h_direct := bridge_provider_json_extract_string(f_obj, "hash", "")
			if h_direct != "" { append(&out, h_direct) } else { delete(h_direct) }
			if ass_arr, got := bridge_provider_json_extract_array(f_obj, "assembly"); got {
				ass_objs := bridge_provider_json_top_level_objects(ass_arr)
				defer bridge_bootstrap_free_object_slice(ass_objs)
				for a_obj in ass_objs {
					h := bridge_provider_json_extract_string(a_obj, "hash", "")
					if h != "" { append(&out, h) } else { delete(h) }
				}
			}
		}
	}
	if skills_array, skills_ok := bridge_provider_json_extract_array(manifest_json, "skills"); skills_ok {
		skill_objs := bridge_provider_json_top_level_objects(skills_array)
		defer bridge_bootstrap_free_object_slice(skill_objs)
		for s_obj in skill_objs {
			h := bridge_provider_json_extract_string(s_obj, "hash", "")
			if h != "" { append(&out, h) } else { delete(h) }
		}
	}
	// BT-3: the single-template blob hash (must be cached to render).
	if tpl_obj, ok := bridge_provider_json_extract_object(manifest_json, "template"); ok {
		h := bridge_provider_json_extract_string(tpl_obj, "hash", "")
		if h != "" { append(&out, h) } else { delete(h) }
	}
	// BT-3: variable value blobs — only fetch those WITHOUT an inline value (the hub
	// inlines tiny values, so these are usually skipped; a hash-only variable is
	// fetched as a blob).
	if vars_arr, ok := bridge_provider_json_extract_array(manifest_json, "variables"); ok {
		var_objs := bridge_provider_json_top_level_objects(vars_arr)
		defer bridge_bootstrap_free_object_slice(var_objs)
		for v_obj in var_objs {
			if _, has_val := bridge_provider_json_extract_string_set(v_obj, "value"); has_val do continue
			h := bridge_provider_json_extract_string(v_obj, "hash", "")
			if h != "" { append(&out, h) } else { delete(h) }
		}
	}
	return out
}


// bridge_bootstrap_render_header renders the AGENTS.md header LOCALLY from the
// per-instance descriptor (comment 3 / DM): the hub's agent-keyed manifest carries
// NO per-instance data, so the bridge injects the instance/chain/coordinator
// header itself. Mirrors the hub's former render_header_inline format so the
// assembled doc is byte-identical to the legacy bundle header.
bridge_bootstrap_render_header :: proc(d: Bridge_Bootstrap_Descriptor) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "# Agent bootstrap\n\nAgent: ")
	strings.write_string(&b, d.agent_name)
	strings.write_string(&b, "\nInstance: ")
	strings.write_string(&b, d.instance_id)
	is_coordinator := d.role == "coordinator"
	if d.chain_title != "" || d.chain_id != "" {
		strings.write_string(&b, "\nTask chain: ")
		chain_title := bridge_decrypt_embedded_vault_tokens(d.chain_title)
		defer delete(chain_title)
		strings.write_string(&b, chain_title)
		strings.write_string(&b, " (")
		strings.write_string(&b, d.chain_id)
		strings.write_string(&b, ")")
		if is_coordinator {
			strings.write_string(&b, "\nCoordinator: you (coordinator)")
		} else if d.coordinator_id != "" {
			strings.write_string(&b, "\nCoordinator: ")
			if strings.trim_space(d.coordinator_display_name) != "" && strings.trim_space(d.coordinator_display_name) != d.coordinator_id {
				strings.write_string(&b, d.coordinator_display_name)
				strings.write_string(&b, " (")
				strings.write_string(&b, d.coordinator_id)
				strings.write_string(&b, ")")
			} else {
				strings.write_string(&b, d.coordinator_id)
			}
		}
	}
	return strings.to_string(b)
}

// bridge_bootstrap_assemble_agents_md produces the full AGENTS.md body. BT-3: when
// the manifest carries a single-template blob ("template":{...}) it renders via the
// substitution + role-conditional engine (bridge_bootstrap_render_template);
// otherwise it falls back to the legacy concat-by-assembly path so older manifests
// still work. In both cases the ctl guidance appendix is appended.
bridge_bootstrap_assemble_agents_md :: proc(manifest_json: string, d: Bridge_Bootstrap_Descriptor, cache: ^Bootstrap_Cache) -> (string, bool) {
	// Prefer the single-template path when the hub advertised a template blob.
	if tpl_obj, ok := bridge_provider_json_extract_object(manifest_json, "template"); ok {
		if rendered, r_ok := bridge_bootstrap_render_template(tpl_obj, manifest_json, d, cache); r_ok {
			return rendered, true
		}
		return "", false
	}
	return bridge_bootstrap_assemble_agents_md_legacy(manifest_json, d, cache)
}

// bridge_bootstrap_assemble_agents_md_legacy is the pre-BT-3 assembler: the
// locally-rendered header + each cached fragment (in manifest assembly order) +
// the ctl guidance appendix. Kept as a fallback for manifests without a template.
bridge_bootstrap_assemble_agents_md_legacy :: proc(manifest_json: string, d: Bridge_Bootstrap_Descriptor, cache: ^Bootstrap_Cache) -> (string, bool) {
	b := strings.builder_make()
	header := bridge_bootstrap_render_header(d)
	strings.write_string(&b, header)
	delete(header)

	files_array, files_ok := bridge_provider_json_extract_array(manifest_json, "files")
	if !files_ok { strings.builder_destroy(&b); return "", false }
	file_objs := bridge_provider_json_top_level_objects(files_array)
	defer bridge_bootstrap_free_object_slice(file_objs)
	for f_obj in file_objs {
		kind := bridge_provider_json_extract_string(f_obj, "kind", "")
		is_agents := kind == "AGENTS_MD"
		delete(kind)
		if !is_agents do continue
		ass_arr, got := bridge_provider_json_extract_array(f_obj, "assembly")
		if !got do continue
		ass_objs := bridge_provider_json_top_level_objects(ass_arr)
		defer bridge_bootstrap_free_object_slice(ass_objs)
		for a_obj in ass_objs {
			// A section is either an inline literal or a content-addressed hash.
			inline_str := bridge_provider_json_extract_string(a_obj, "inline", "")
			if inline_str != "" {
				strings.write_string(&b, inline_str)
				delete(inline_str)
				continue
			}
			delete(inline_str)
			h := bridge_provider_json_extract_string(a_obj, "hash", "")
			if h == "" { delete(h); continue }
			body, found := bootstrap_cache_get(cache, h)
			delete(h)
			if !found { strings.builder_destroy(&b); return "", false }
			strings.write_string(&b, body)
			delete(body)
		}
	}
	return strings.to_string(b), true
}

// -----------------------------------------------------------------------------
// BT-3: single-template substitution + role-conditional engine.
//
// The bridge renders AGENTS.md by taking the hub-served static template and
// (a) substituting {scalar} placeholders with variable values and (b) evaluating
// the three role blocks {{#is_coordinator}}/{{#is_worker}}/{{#is_reviewer}}.
// Syntax (BT-1 §3): single-brace {name} scalars; double-brace {{#flag}}..{{/flag}}
// role sections for exactly is_coordinator|is_worker|is_reviewer. No expressions,
// no nesting, no inverted sections. Unknown {name} -> empty. Empty value -> empty
// substitution (its static heading may remain; no hiding).
// -----------------------------------------------------------------------------

// bridge_bootstrap_render_template loads the template blob referenced by tpl_obj,
// builds the variable set (hub DB variables + bridge-local header values + role
// flags from the descriptor), substitutes/evaluates, and appends the ctl guidance.
// Returns ("", false) if the template blob is missing from the cache.
bridge_bootstrap_render_template :: proc(tpl_obj, manifest_json: string, d: Bridge_Bootstrap_Descriptor, cache: ^Bootstrap_Cache) -> (string, bool) {
	tpl_hash := bridge_provider_json_extract_string(tpl_obj, "hash", "")
	defer delete(tpl_hash)
	if tpl_hash == "" do return "", false
	template_body, found := bootstrap_cache_get(cache, tpl_hash)
	if !found do return "", false
	defer delete(template_body)

	// Scalar variable set: names -> values. Hub DB variables first.
	names := make([dynamic]string)
	values := make([dynamic]string)
	defer { for n in names do delete(n); delete(names) }
	defer { for v in values do delete(v); delete(values) }
	add_var :: proc(names, values: ^[dynamic]string, name, value: string) {
		append(names, strings.clone(name)); append(values, strings.clone(value))
	}
	if vars_arr, ok := bridge_provider_json_extract_array(manifest_json, "variables"); ok {
		var_objs := bridge_provider_json_top_level_objects(vars_arr)
		defer bridge_bootstrap_free_object_slice(var_objs)
		for v_obj in var_objs {
			n := bridge_provider_json_extract_string(v_obj, "name", "")
			if n == "" { delete(n); continue }
			// Prefer the inline value; fall back to the cached blob by hash.
			val, has_val := bridge_provider_json_extract_string_set(v_obj, "value")
			if !has_val {
				h := bridge_provider_json_extract_string(v_obj, "hash", "")
				if h != "" { if body, ok2 := bootstrap_cache_get(cache, h); ok2 { val = body; has_val = true } }
				delete(h)
			}
			add_var(&names, &values, n, val if has_val else "")
			delete(n); if has_val do delete(val)
		}
	}
	decrypted_chain_title := bridge_decrypt_embedded_vault_tokens(d.chain_title)
	defer delete(decrypted_chain_title)
	// Bridge-local header values (the agent-keyed manifest is instance-free, so the
	// hub does not carry these; BT-1 §2/§5).
	add_var(&names, &values, "agent_name", d.agent_name)
	add_var(&names, &values, "instance_id", d.instance_id)
	add_var(&names, &values, "chain_title", decrypted_chain_title)
	add_var(&names, &values, "chain_id", d.chain_id)
	add_var(&names, &values, "coordinator_id", d.coordinator_id)
	coord_dn := d.coordinator_display_name if strings.trim_space(d.coordinator_display_name) != "" else d.coordinator_id
	add_var(&names, &values, "coordinator_display_name", coord_dn)

	// Role flags from the descriptor role. Exactly one is true for a chain member;
	// all false leaves every role block dropped.
	is_coordinator := d.role == "coordinator"
	is_reviewer := d.role == "reviewer"
	is_worker := !is_coordinator && !is_reviewer

	// {coordinator_line} is the header's "Coordinator:" line, computed here (the
	// engine has no emptiness conditional). It carries its OWN leading newline so an
	// empty value drops the whole line rather than leaving a bare "Coordinator: "
	// with a trailing space — matching the legacy render_header behavior for a
	// worker/reviewer whose coordinator_id is unset.
	coordinator_line := ""
	coord_line_owned := false
	if is_coordinator {
		coordinator_line = "\nCoordinator: you (coordinator)"
	} else if d.coordinator_id != "" {
		if strings.trim_space(d.coordinator_display_name) != "" && strings.trim_space(d.coordinator_display_name) != d.coordinator_id {
			coordinator_line = strings.concatenate({"\nCoordinator: ", d.coordinator_display_name, " (", d.coordinator_id, ")"})
		} else {
			coordinator_line = strings.concatenate({"\nCoordinator: ", d.coordinator_id})
		}
		coord_line_owned = true
	}
	add_var(&names, &values, "coordinator_line", coordinator_line)
	if coord_line_owned do delete(coordinator_line)

	body := bridge_bootstrap_eval_role_sections(template_body, is_coordinator, is_worker, is_reviewer)
	defer delete(body)
	substituted := bridge_bootstrap_substitute_scalars(body, names[:], values[:])

	b := strings.builder_make()
	strings.write_string(&b, substituted)
	delete(substituted)
	return strings.to_string(b), true
}

// bridge_bootstrap_eval_role_sections drops or keeps each {{#flag}}..{{/flag}}
// block for flag in {is_coordinator,is_worker,is_reviewer} based on the booleans.
// A block's opening/closing tag each consume the single newline immediately after
// the tag (when present) so a dropped block leaves no blank line and a kept block
// starts cleanly (BT-1 §3 whitespace rule). Non-role {{...}} are left untouched.
bridge_bootstrap_eval_role_sections :: proc(template: string, is_coordinator, is_worker, is_reviewer: bool) -> string {
	flags := [3]string{"is_coordinator", "is_worker", "is_reviewer"}
	vals := [3]bool{is_coordinator, is_worker, is_reviewer}
	result := strings.clone(template)
	for fi in 0..<3 {
		open := strings.concatenate({"{{#", flags[fi], "}}"})
		close := strings.concatenate({"{{/", flags[fi], "}}"})
		defer { delete(open); delete(close) }
		for {
			os := strings.index(result, open)
			if os < 0 do break
			inner_start := os + len(open)
			ce := strings.index(result[inner_start:], close)
			if ce < 0 do break // malformed: leave as-is to avoid corrupting output
			inner_end := inner_start + ce
			after_close := inner_end + len(close)
			// consume one newline right after the opening tag and after the closing tag.
			content_start := inner_start
			if content_start < len(result) && result[content_start] == '\n' do content_start += 1
			content_end := inner_end
			tail_start := after_close
			if tail_start < len(result) && result[tail_start] == '\n' do tail_start += 1
			new_result: string
			if vals[fi] {
				new_result = strings.concatenate({result[:os], result[content_start:content_end], result[tail_start:]})
			} else {
				new_result = strings.concatenate({result[:os], result[tail_start:]})
			}
			delete(result)
			result = new_result
		}
	}
	return result
}

// bridge_bootstrap_substitute_scalars replaces each {name} occurrence with its
// value. Longer names are matched first is unnecessary because names are matched
// exactly against the braces content; unknown {name} tokens are replaced with "".
// Only tokens whose inner text is a known variable name are substituted; any other
// {..} (e.g. code braces) is left verbatim.
bridge_bootstrap_substitute_scalars :: proc(body: string, names, values: []string) -> string {
	b := strings.builder_make()
	i := 0
	for i < len(body) {
		if body[i] == '{' && (i+1 >= len(body) || body[i+1] != '{') {
			// find closing brace on the same token (no nested braces)
			j := i + 1
			for j < len(body) && body[j] != '}' && body[j] != '{' && body[j] != '\n' do j += 1
			if j < len(body) && body[j] == '}' {
				key := body[i+1:j]
				matched := false
				for n, ni in names {
					if n == key { strings.write_string(&b, values[ni]); matched = true; break }
				}
				if matched { i = j + 1; continue }
				// Unknown single-brace token: emit empty (BT-1 §3 fail-soft) ONLY if it
				// looks like a placeholder (letters/underscore); otherwise keep verbatim.
				if bridge_bootstrap_is_placeholder_key(key) { i = j + 1; continue }
			}
		}
		strings.write_byte(&b, body[i])
		i += 1
	}
	return strings.to_string(b)
}

bridge_bootstrap_is_placeholder_key :: proc(key: string) -> bool {
	if len(key) == 0 do return false
	for i in 0..<len(key) {
		ch := key[i]
		if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_' || (ch >= '0' && ch <= '9')) do return false
	}
	return true
}

// Bridge_Bootstrap_File is one FINISHED file the wrapper places into the run_dir
// (BRG-3): relative_path is resolved by the bridge (provider layout), content is
// the fully-assembled body, mode is the octal file mode (0644 default, 0755 for
// the ctl shim). kind lets the wrapper reason about the file if needed.
Bridge_Bootstrap_File :: struct {
	file_id:       string, // stable id = relative_path
	relative_path: string,
	kind:          string, // AGENTS_MD | SKILL | CTL_WRAPPER | MANIFEST
	content:       string,
	mode:          int,
}

// bridge_bootstrap_build_file_set assembles the complete FINISHED file set in
// memory (AGENTS.md, skills, ctl shim, bootstrap manifest json) from the resolved
// manifest + descriptor. This is the single source of truth used both to write
// the run_dir (current launch path) and to serve the wrapper bootstrap RPCs
// (BRG-3). Caller owns the returned files (free via bridge_bootstrap_free_file_set).
bridge_bootstrap_build_file_set :: proc(manifest_json: string, d: Bridge_Bootstrap_Descriptor, bridge_endpoint, agent_token, provider: string, cache: ^Bootstrap_Cache) -> ([dynamic]Bridge_Bootstrap_File, Bridge_Bootstrap_Result) {
	files := make([dynamic]Bridge_Bootstrap_File)

	agents_md, asm_ok := bridge_bootstrap_assemble_agents_md(manifest_json, d, cache)
	if !asm_ok {
		bridge_bootstrap_free_file_set(files)
		return nil, Bridge_Bootstrap_Result{ok = false, stage = "assemble", detail = "failed to assemble AGENTS.md from cached fragments"}
	}
	// The hub holds no vault key, so encrypted template variables (project name,
	// description, ...), memories and skills reach the bridge as vault:v2 tokens.
	// Decrypt each file's content here, the one point every bootstrap file passes
	// through, so the agent never reads raw ciphertext.
	agents_md = bridge_bootstrap_decrypt_owned(agents_md)
	agents_md_name := bridge_bootstrap_agents_md_name(provider)
	append(&files, Bridge_Bootstrap_File{file_id = strings.clone(agents_md_name), relative_path = strings.clone(agents_md_name), kind = "AGENTS_MD", content = agents_md, mode = 0o644})

	if files_array, files_ok := bridge_provider_json_extract_array(manifest_json, "files"); files_ok {
		file_objs := bridge_provider_json_top_level_objects(files_array)
		defer bridge_bootstrap_free_object_slice(file_objs)
		for f_obj in file_objs {
			kind := bridge_provider_json_extract_string(f_obj, "kind", "")
			if kind == "MEMORY_MD" {
				rel_path := bridge_provider_json_extract_string(f_obj, "relative_path", "MEMORY.md")
				if strings.trim_space(rel_path) == "" {
					delete(rel_path)
					rel_path = strings.clone("MEMORY.md")
				}
				h := bridge_provider_json_extract_string(f_obj, "hash", "")
				content, found := bootstrap_cache_get(cache, h)
				delete(h)
				if !found {
					delete(kind)
					delete(rel_path)
					bridge_bootstrap_free_file_set(files)
					return nil, Bridge_Bootstrap_Result{ok = false, stage = "assemble", detail = "memory blob missing from cache"}
				}
				content = bridge_bootstrap_decrypt_owned(content)
				append(&files, Bridge_Bootstrap_File{file_id = strings.clone(rel_path), relative_path = rel_path, kind = "MEMORY_MD", content = content, mode = 0o644})
			}
			delete(kind)
		}
	}

	if skills_array, skills_ok := bridge_provider_json_extract_array(manifest_json, "skills"); skills_ok {
		skill_objs := bridge_provider_json_top_level_objects(skills_array)
		defer bridge_bootstrap_free_object_slice(skill_objs)
		for s_obj in skill_objs {
			name := bridge_provider_json_extract_string(s_obj, "name", "")
			h := bridge_provider_json_extract_string(s_obj, "hash", "")
			content, found := bootstrap_cache_get(cache, h)
			if !found {
				delete(name); delete(h)
				bridge_bootstrap_free_file_set(files)
				return nil, Bridge_Bootstrap_Result{ok = false, stage = "assemble", detail = "skill blob missing from cache"}
			}
			content = bridge_bootstrap_decrypt_owned(content)
			// No locked marker for the name: it becomes a directory, and distinct
			// ciphertext keeps distinct skills from colliding on one path.
			plain_name := bridge_decrypt_embedded_vault_tokens(name)
			path := bridge_bootstrap_skill_relative_path(provider, plain_name)
			delete(plain_name); delete(name); delete(h)
			if strings.trim_space(path) == "" { delete(path); delete(content); continue }
			append(&files, Bridge_Bootstrap_File{file_id = strings.clone(path), relative_path = path, kind = "SKILL", content = content, mode = 0o644})
		}
	}

	ctl_shim, shim_ok := bridge_bootstrap_render_ham_ctl_shim(bridge_endpoint, agent_token, d.instance_id)
	if !shim_ok {
		bridge_bootstrap_free_file_set(files)
		return nil, Bridge_Bootstrap_Result{ok = false, stage = "assemble", detail = "ham-ctl not found; set HEIMDALL_HAM_CTL_BIN or put ham-ctl on PATH"}
	}
	append(&files, Bridge_Bootstrap_File{file_id = strings.clone(agent_runtime.CTL_SHIM_PATH), relative_path = strings.clone(agent_runtime.CTL_SHIM_PATH), kind = "CTL_WRAPPER", content = ctl_shim, mode = 0o755})
	when ODIN_OS == .Windows {
		cmd_shim, cmd_ok := bridge_bootstrap_render_ham_ctl_cmd_shim(bridge_endpoint, agent_token, d.instance_id)
		if !cmd_ok {
			bridge_bootstrap_free_file_set(files)
			return nil, Bridge_Bootstrap_Result{ok = false, stage = "assemble", detail = "ham-ctl.cmd shim could not be rendered"}
		}
		append(&files, Bridge_Bootstrap_File{file_id = strings.clone(agent_runtime.CTL_SHIM_CMD_PATH), relative_path = strings.clone(agent_runtime.CTL_SHIM_CMD_PATH), kind = "CTL_WRAPPER", content = cmd_shim, mode = 0o644})
	}

	if strings.has_prefix(strings.trim_space(d.pack_json), "{") {
		bridge_taskv2_ensure_pack_worktree(d.pack_json)
		task_md := bridge_taskv2_render_task_md(d.pack_json)
		if strings.trim_space(task_md) != "" {
			append(&files, Bridge_Bootstrap_File{file_id = strings.clone("TASK.md"), relative_path = strings.clone("TASK.md"), kind = "TASK_MD", content = task_md, mode = 0o644})
		} else {
			delete(task_md)
		}
	}

	// heimdall-bootstrap-manifest.json listing the managed files.
	mb := strings.builder_make()
	strings.write_string(&mb, "{\"agent_instance_id\":\""); strings.write_string(&mb, d.instance_id)
	strings.write_string(&mb, "\",\"managed_files\":[")
	for f, i in files {
		if i > 0 do strings.write_byte(&mb, ',')
		strings.write_string(&mb, "{\"relative_path\":\""); bridge_bootstrap_json_string(&mb, f.relative_path)
		strings.write_string(&mb, "\",\"kind\":\""); bridge_bootstrap_json_string(&mb, f.kind); strings.write_string(&mb, "\"}")
	}
	strings.write_string(&mb, "]}")
	append(&files, Bridge_Bootstrap_File{file_id = strings.clone("heimdall-bootstrap-manifest.json"), relative_path = strings.clone("heimdall-bootstrap-manifest.json"), kind = "MANIFEST", content = strings.to_string(mb), mode = 0o644})

	return files, Bridge_Bootstrap_Result{ok = true, stage = "done"}
}

// bridge_bootstrap_decrypt_owned decrypts embedded vault tokens in an owned
// string, frees the original and returns the result. Tokens left undecryptable
// because the vault is locked become VAULT_LOCKED_MARKER.
bridge_bootstrap_decrypt_owned :: proc(text: string) -> string {
	if !bridge_has_vault_token(text) do return text
	out := bridge_decrypt_embedded_vault_tokens(text, locked_marker = VAULT_LOCKED_MARKER)
	delete(text)
	return out
}

bridge_bootstrap_free_file_set :: proc(files: [dynamic]Bridge_Bootstrap_File) {
	for f in files {
		delete(f.file_id)
		delete(f.relative_path)
		delete(f.content)
	}
	delete(files)
}

// bridge_bootstrap_publish_file_set builds the finished file set and PUBLISHES it
// for the wrapper bootstrap RPCs (BRG-3). The bridge intentionally does NOT write
// the run_dir — the WRAPPER is the sole writer (WRP-1). This keeps the e2e test
// honest: if the wrapper's fetch-and-place path is broken, no run_dir appears.
bridge_bootstrap_publish_file_set :: proc(manifest_json: string, d: Bridge_Bootstrap_Descriptor, bridge_endpoint, agent_token, provider: string, cache: ^Bootstrap_Cache) -> Bridge_Bootstrap_Result {
	files, build_res := bridge_bootstrap_build_file_set(manifest_json, d, bridge_endpoint, agent_token, provider, cache)
	if !build_res.ok do return build_res
	// Publish for the wrapper RPCs BEFORE freeing; the store clones what it keeps.
	bridge_bootstrap_fileset_store_put(d.instance_id, provider, files[:])
	bridge_bootstrap_free_file_set(files)
	return Bridge_Bootstrap_Result{ok = true, stage = "published"}
}

// bridge_bootstrap_materialize_run_dir is the wrapper-free (pty-host) writer: it
// CLEAN-SLATES run_dir (deletes the whole tree, recreates empty) then WRITES the
// fully-assembled file set (AGENTS.md/CLAUDE.md, skills, ham-ctl shim,
// heimdall-bootstrap-manifest.json) directly to disk. The bridge is the sole
// materializer here — no ham-wrapper, no bootstrap.list/.file RPC. Returns a
// staged result so the caller can report WHERE it failed.
bridge_bootstrap_materialize_run_dir :: proc(manifest_json: string, d: Bridge_Bootstrap_Descriptor, run_dir, bridge_endpoint, agent_token, provider: string, cache: ^Bootstrap_Cache) -> Bridge_Bootstrap_Result {
	clean := strings.trim_right(run_dir, "/")
	if strings.trim_space(clean) == "" do return Bridge_Bootstrap_Result{ok = false, stage = "write_run_dir", detail = "empty run_dir"}

	files, build_res := bridge_bootstrap_build_file_set(manifest_json, d, bridge_endpoint, agent_token, provider, cache)
	if !build_res.ok do return build_res
	defer bridge_bootstrap_free_file_set(files)

	// Clean slate on every (re)launch: delete the entire run_dir tree then recreate.
	bridge_prespawn_clean_slate(clean)

	for f in files {
		rel := strings.trim_left(f.relative_path, "/")
		if strings.trim_space(rel) == "" do continue
		full := strings.concatenate({clean, "/", rel})
		defer delete(full)
		// Ensure parent dirs (skills live under nested dirs; ctl shim under agent_runtime.CTL_SHIM_DIR).
		if slash := strings.last_index_byte(full, '/'); slash > 0 {
			parent := full[:slash]
			_ = bridge_make_directory_all(parent)
		}
		if os.write_entire_file(full, transmute([]byte)f.content) != nil {
			return Bridge_Bootstrap_Result{ok = false, stage = "write_run_dir", detail = strings.concatenate({"failed to write ", rel})}
		}
		// Executable bit for the ham-ctl shim (mode 0755): owner rwx.
		if f.mode == 0o755 {
			bridge_os_make_owner_executable(full)
		}
	}
	return Bridge_Bootstrap_Result{ok = true, stage = "materialized"}
}

bridge_bootstrap_dir_exists :: proc(path: string) -> bool {
	return os.is_dir(path)
}

// bridge_bootstrap_launch_materialize is the top-level bootstrap entry for
// launch_agent: parse the descriptor, run the conditional manifest + per-hash blob
// fetch, then ASSEMBLE + PUBLISH the finished file set for the wrapper RPCs. It
// does NOT write the run_dir (the wrapper does that via bootstrap.list/.file).
// Returns a staged result so callers can log/report WHERE it failed (BRG-4).
bridge_bootstrap_launch_materialize :: proc(hub_url, bridge_token, run_dir, bridge_endpoint, agent_token: string, d: Bridge_Bootstrap_Descriptor, cache: ^Bootstrap_Cache, deadline_ns: i64 = 0) -> Bridge_Bootstrap_Result {
	_ = run_dir // run_dir is materialized by the wrapper, not the bridge (WRP-1).
	if strings.trim_space(hub_url) == "" || strings.trim_space(bridge_token) == "" || strings.trim_space(d.instance_id) == "" {
		return Bridge_Bootstrap_Result{ok = false, stage = "validate", detail = "missing hub_url/bridge_token/instance_id"}
	}
	if strings.trim_space(d.agent_id) == "" {
		// REQ-37: refuse to launch on an incomplete descriptor rather than fall back to
		// the header-only instance-endpoint bootstrap (see the matching guard in
		// bridge_bootstrap_launch_materialize_run_dir). Every launch path supplies
		// agent_id, so an empty agent_id is a caller bug — fail loudly.
		fmt.eprintln("bridge bootstrap: refusing launch with empty agent_id (would degrade to header-only bootstrap)", "instance=", d.instance_id)
		return Bridge_Bootstrap_Result{ok = false, stage = "validate", detail = "launch descriptor missing agent_id -- refusing degraded header-only bootstrap (REQ-37)"}
	}
	provider := d.provider
	manifest_json, res := bridge_bootstrap_conditional_manifest(hub_url, bridge_token, provider, d, cache, deadline_ns)
	if !res.ok do return res
	defer delete(manifest_json)
	return bridge_bootstrap_publish_file_set(manifest_json, d, bridge_endpoint, agent_token, provider, cache)
}

// bridge_bootstrap_launch_materialize_run_dir is the wrapper-free (pty-host)
// top-level bootstrap entry: same conditional manifest + per-hash blob fetch as
// launch_materialize, but the bridge itself CLEAN-SLATES run_dir and WRITES the
// assembled file set to disk (no wrapper, no bootstrap.list/.file RPC). Falls back
// to the legacy manifest/content materializers for a minimal descriptor.
bridge_bootstrap_launch_materialize_run_dir :: proc(hub_url, bridge_token, run_dir, bridge_endpoint, agent_token: string, d: Bridge_Bootstrap_Descriptor, cache: ^Bootstrap_Cache, deadline_ns: i64 = 0) -> Bridge_Bootstrap_Result {
	if strings.trim_space(hub_url) == "" || strings.trim_space(bridge_token) == "" || strings.trim_space(d.instance_id) == "" {
		return Bridge_Bootstrap_Result{ok = false, stage = "validate", detail = "missing hub_url/bridge_token/instance_id"}
	}
	if strings.trim_space(d.agent_id) == "" {
		// REQ-37: refuse to launch on an incomplete descriptor. This branch used to
		// fall back to the instance-endpoint header-only bootstrap, silently
		// materializing a 6-line CLAUDE.md/AGENTS.md (all static skills, persona, and
		// instructions missing) because that endpoint's AGENTS_MD assembly now carries
		// only the header — the static prose lives in the template blob that the
		// fallback ignored. Every launch path now supplies agent_id (the hub's
		// launch_command_json_full, the wake_agent handler's enriched payload, and the
		// scheduler's bridge_scheduler_fetch_enriched_launch_json), so an empty agent_id
		// here means the caller is broken. Fail loudly and visibly rather than start an
		// agent with a degraded bootstrap.
		fmt.eprintln("bridge bootstrap: refusing launch with empty agent_id (would degrade to header-only bootstrap)", "instance=", d.instance_id)
		return Bridge_Bootstrap_Result{ok = false, stage = "validate", detail = "launch descriptor missing agent_id -- refusing degraded header-only bootstrap (REQ-37)"}
	}
	provider := d.provider
	manifest_json, res := bridge_bootstrap_conditional_manifest(hub_url, bridge_token, provider, d, cache, deadline_ns)
	if !res.ok do return res
	defer delete(manifest_json)
	// Also publish for any bootstrap.list/.file readers (harmless under pty-host),
	// then write the run_dir directly.
	return bridge_bootstrap_materialize_run_dir(manifest_json, d, run_dir, bridge_endpoint, agent_token, provider, cache)
}

bridge_bootstrap_fetch_manifest_and_materialize :: proc(hub_url, bridge_token, instance_id, run_dir, bridge_endpoint, agent_token, provider: string, cache: ^Bootstrap_Cache) -> bool {
	if strings.trim_space(hub_url) == "" || strings.trim_space(bridge_token) == "" || strings.trim_space(instance_id) == "" || strings.trim_space(run_dir) == "" do return false
	headers := [?]httpc.Header{httpc.bearer(bridge_token)}
	hub := bridge_hub_url(hub_url)
	resp, http_err := bridge_http_request_retry({
		method = .GET, url = hub, path = {"api", "v1", "bridge", "agent-instances", instance_id, "bootstrap"},
		query = {{"format", "manifest"}}, headers = headers[:],
	})
	defer httpc.response_destroy(&resp)
	if http_err != .None || resp.status != 200 do return false

	data_obj, data_ok := bridge_provider_json_extract_object(httpc.text(resp), "data")
	if !data_ok do return false
	protocol, _ := bridge_provider_json_extract_int(data_obj, "protocol")
	if protocol != 2 do return false

	files_array, files_ok := bridge_provider_json_extract_array(data_obj, "files")
	if !files_ok do return false

	skills_array, _ := bridge_provider_json_extract_array(data_obj, "skills")

	// top_level_objects returns freshly-cloned object substrings; free each slice
	// (and its elements) at function end. Scalars extracted below (hashes, names)
	// are freed where they are transient; hashes retained in needed_hashes are
	// freed via that array's element cleanup.
	file_objs := bridge_provider_json_top_level_objects(files_array)
	defer bridge_bootstrap_free_object_slice(file_objs)
	agents_md_assembly := ""
	for f_obj in file_objs {
		kind := bridge_provider_json_extract_string(f_obj, "kind", "")
		if kind == "AGENTS_MD" {
			if ass_arr, got_ass := bridge_provider_json_extract_array(f_obj, "assembly"); got_ass {
				agents_md_assembly = ass_arr
			}
		}
		delete(kind)
	}
	if agents_md_assembly == "" do return false

	// needed_hashes owns its hash strings (delete(dynamic) frees only the backing
	// array). missing_hashes holds ALIASES of needed_hashes entries, so we free
	// only its array, never its elements, to avoid a double free.
	needed_hashes := make([dynamic]string)
	defer { for h in needed_hashes do delete(h); delete(needed_hashes) }
	missing_hashes := make([dynamic]string)
	defer delete(missing_hashes)

	assembly_objs := bridge_provider_json_top_level_objects(agents_md_assembly)
	defer bridge_bootstrap_free_object_slice(assembly_objs)
	for item_obj in assembly_objs {
		h := bridge_provider_json_extract_string(item_obj, "hash", "")
		if h != "" {
			append(&needed_hashes, h)
			if cache != nil && !bootstrap_cache_has(cache, h) {
				append(&missing_hashes, h)
			}
		} else {
			delete(h)
		}
	}

	for f_obj in file_objs {
		kind := bridge_provider_json_extract_string(f_obj, "kind", "")
		if kind == "MEMORY_MD" {
			h := bridge_provider_json_extract_string(f_obj, "hash", "")
			if h != "" {
				append(&needed_hashes, h)
				if cache != nil && !bootstrap_cache_has(cache, h) {
					append(&missing_hashes, h)
				}
			} else {
				delete(h)
			}
		}
		delete(kind)
	}

	skill_objs := bridge_provider_json_top_level_objects(skills_array)
	defer bridge_bootstrap_free_object_slice(skill_objs)
	for s_obj in skill_objs {
		h := bridge_provider_json_extract_string(s_obj, "hash", "")
		if h != "" {
			append(&needed_hashes, h)
			if cache != nil && !bootstrap_cache_has(cache, h) {
				append(&missing_hashes, h)
			}
		} else {
			delete(h)
		}
	}

	if len(missing_hashes) > 0 {
		Blob_Request :: struct {
			hashes: []string `json:"hashes"`,
		}
		post_resp, post_err := bridge_hub_http_send_alloc({
			method = .POST, url = hub, path = {"api", "v1", "bridge", "blobs"}, headers = headers[:],
			body = httpc.json_body(Blob_Request{hashes = missing_hashes[:]}),
		})
		defer httpc.response_destroy(&post_resp)
		if post_err != .None || post_resp.status != 200 do return false
		post_body := httpc.text(post_resp)

		post_data_obj, post_data_ok := bridge_provider_json_extract_object(post_body, "data")
		if !post_data_ok {
			post_data_obj, post_data_ok = bridge_provider_json_extract_object(post_body, "")
			if !post_data_ok do return false
		}

		blobs_array, blobs_ok := bridge_provider_json_extract_array(post_data_obj, "blobs")
		if !blobs_ok do return false

		missing_resp_array, _ := bridge_provider_json_extract_array(post_data_obj, "missing")
		if missing_resp_array != "" {
			missing_parsed := bridge_provider_json_parse_string_array(missing_resp_array)
			defer {
				for item in missing_parsed do delete(item)
				delete(missing_parsed)
			}
			if len(missing_parsed) > 0 do return false
		}

		blob_objs := bridge_provider_json_top_level_objects(blobs_array)
		defer bridge_bootstrap_free_object_slice(blob_objs)
		for b_obj in blob_objs {
			b_hash := bridge_provider_json_extract_string(b_obj, "hash", "")
			b_content := bridge_provider_json_extract_string(b_obj, "body", "")
			if cache != nil {
				if !bootstrap_cache_put(cache, b_hash, b_content) { delete(b_hash); delete(b_content); return false }
			}
			delete(b_hash); delete(b_content)
		}
	}

	agents_md_b := strings.builder_make()
	defer strings.builder_destroy(&agents_md_b)
	for item_obj in assembly_objs {
		inline_str := bridge_provider_json_extract_string(item_obj, "inline", "")
		if inline_str != "" {
			strings.write_string(&agents_md_b, inline_str)
			delete(inline_str)
		} else {
			delete(inline_str)
			h := bridge_provider_json_extract_string(item_obj, "hash", "")
			if h != "" {
				if cache != nil {
					body, found := bootstrap_cache_get(cache, h)
					if !found { delete(h); return false }
					strings.write_string(&agents_md_b, body)
					delete(body)
				}
			}
			delete(h)
		}
	}

	// WRP-1: PUBLISH a bootstrap file set for the wrapper's bootstrap.list/.file
	// RPCs rather than writing run_dir here. The wrapper is the sole run_dir writer;
	// a bridge-side disk write left bootstrap.list with nothing to serve, so a woken
	// agent failed with "bootstrap.list failed after retries". We assemble the same
	// file set the primary agent-keyed path produces (AGENTS.md + skills + ham-ctl
	// shim + a managed-files manifest) and hand it to the fileset store, which clones
	// what it keeps (so we free our locals below).
	_ = run_dir
	agents_md_name := bridge_bootstrap_agents_md_name(provider)
	files := make([dynamic]Bridge_Bootstrap_File)
	defer bridge_bootstrap_free_file_set(files)

	append(&files, Bridge_Bootstrap_File{
		file_id = strings.clone(agents_md_name), relative_path = strings.clone(agents_md_name),
		kind = "AGENTS_MD", content = bridge_bootstrap_decrypt_owned(strings.clone(strings.to_string(agents_md_b))), mode = 0o644,
	})

	for s_obj in skill_objs {
		name := bridge_provider_json_extract_string(s_obj, "name", "")
		h := bridge_provider_json_extract_string(s_obj, "hash", "")
		content := ""
		if cache != nil {
			got, found := bootstrap_cache_get(cache, h)
			if !found { delete(name); delete(h); return false }
			content = bridge_bootstrap_decrypt_owned(got)
		}
		plain_name := bridge_decrypt_embedded_vault_tokens(name)
		path := bridge_bootstrap_skill_relative_path(provider, plain_name)
		delete(plain_name); delete(name); delete(h)
		if strings.trim_space(path) == "" { delete(path); if content != "" do delete(content); continue }
		// content is an owned clone from the cache; hand ownership to the file entry.
		append(&files, Bridge_Bootstrap_File{file_id = strings.clone(path), relative_path = path, kind = "SKILL", content = content, mode = 0o644})
	}

	for f_obj in file_objs {
		kind := bridge_provider_json_extract_string(f_obj, "kind", "")
		if kind == "MEMORY_MD" {
			rel_path := bridge_provider_json_extract_string(f_obj, "relative_path", "MEMORY.md")
			if strings.trim_space(rel_path) == "" {
				delete(rel_path)
				rel_path = strings.clone("MEMORY.md")
			}
			h := bridge_provider_json_extract_string(f_obj, "hash", "")
			content := ""
			if cache != nil {
				got, found := bootstrap_cache_get(cache, h)
				if !found {
					delete(kind)
					delete(rel_path)
					delete(h)
					return false
				}
				content = bridge_bootstrap_decrypt_owned(got)
			}
			delete(h)
			append(&files, Bridge_Bootstrap_File{file_id = strings.clone(rel_path), relative_path = rel_path, kind = "MEMORY_MD", content = content, mode = 0o644})
		}
		delete(kind)
	}

	ctl_shim, shim_ok := bridge_bootstrap_render_ham_ctl_shim(bridge_endpoint, agent_token, instance_id)
	if !shim_ok do return false
	append(&files, Bridge_Bootstrap_File{
		file_id = strings.clone(agent_runtime.CTL_SHIM_PATH), relative_path = strings.clone(agent_runtime.CTL_SHIM_PATH),
		kind = "CTL_WRAPPER", content = ctl_shim, mode = 0o755,
	})
	when ODIN_OS == .Windows {
		cmd_shim, cmd_ok := bridge_bootstrap_render_ham_ctl_cmd_shim(bridge_endpoint, agent_token, instance_id)
		if !cmd_ok do return false
		append(&files, Bridge_Bootstrap_File{
			file_id = strings.clone(agent_runtime.CTL_SHIM_CMD_PATH), relative_path = strings.clone(agent_runtime.CTL_SHIM_CMD_PATH),
			kind = "CTL_WRAPPER", content = cmd_shim, mode = 0o644,
		})
	}

	mb := strings.builder_make()
	strings.write_string(&mb, "{\"agent_instance_id\":\""); strings.write_string(&mb, instance_id)
	strings.write_string(&mb, "\",\"managed_files\":[")
	for f, i in files {
		if i > 0 do strings.write_byte(&mb, ',')
		strings.write_string(&mb, "{\"relative_path\":\""); bridge_bootstrap_json_string(&mb, f.relative_path)
		strings.write_string(&mb, "\",\"kind\":\""); bridge_bootstrap_json_string(&mb, f.kind); strings.write_string(&mb, "\"}")
	}
	strings.write_string(&mb, "]}")
	append(&files, Bridge_Bootstrap_File{
		file_id = strings.clone("heimdall-bootstrap-manifest.json"), relative_path = strings.clone("heimdall-bootstrap-manifest.json"),
		kind = "MANIFEST", content = strings.to_string(mb), mode = 0o644,
	})

	bridge_bootstrap_fileset_store_put(instance_id, provider, files[:])
	return true
}
