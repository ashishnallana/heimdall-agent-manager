package main

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import vault "odin_test:lib/vault"

// BT-3: unit tests for the single-template substitution + role-conditional engine
// (bridge_bootstrap_eval_role_sections + bridge_bootstrap_substitute_scalars).

@(test)
bt3_scalar_substitution_basic :: proc(t: ^testing.T) {
	names := []string{"agent_name", "instance_id", "project_name"}
	values := []string{"Backend Agent", "inst_1", "Heimdall"}
	got := bridge_bootstrap_substitute_scalars("Agent: {agent_name}\nInstance: {instance_id}\n- Name: {project_name}", names, values)
	defer delete(got)
	testing.expect_value(t, got, "Agent: Backend Agent\nInstance: inst_1\n- Name: Heimdall")
}

@(test)
bt3_scalar_empty_value_leaves_heading :: proc(t: ^testing.T) {
	// Empty value substitutes to empty; the static "- Name: " prefix stays (BT-1 §3).
	names := []string{"project_name"}
	values := []string{""}
	got := bridge_bootstrap_substitute_scalars("- Name: {project_name}", names, values)
	defer delete(got)
	testing.expect_value(t, got, "- Name: ")
}

@(test)
bt3_scalar_unknown_placeholder_fails_soft :: proc(t: ^testing.T) {
	// Unknown placeholder-looking token -> empty; non-placeholder braces kept verbatim.
	got := bridge_bootstrap_substitute_scalars("a={unknown_var} b={not a key}", nil, nil)
	defer delete(got)
	testing.expect_value(t, got, "a= b={not a key}")
}

@(test)
bt3_scalar_keeps_code_braces :: proc(t: ^testing.T) {
	// JSON/code braces must survive (they are not simple placeholder tokens).
	got := bridge_bootstrap_substitute_scalars("json: {\"k\": 1}", nil, nil)
	defer delete(got)
	testing.expect_value(t, got, "json: {\"k\": 1}")
}

@(test)
bt3_role_coordinator_kept_others_dropped :: proc(t: ^testing.T) {
	tpl := "H\n{{#is_coordinator}}\nCOORD\n{{/is_coordinator}}{{#is_worker}}\nWORK\n{{/is_worker}}{{#is_reviewer}}\nREVIEW\n{{/is_reviewer}}T"
	got := bridge_bootstrap_eval_role_sections(tpl, true, false, false)
	defer delete(got)
	testing.expect_value(t, got, "H\nCOORD\nT")
}

@(test)
bt3_role_worker_kept :: proc(t: ^testing.T) {
	tpl := "H\n{{#is_coordinator}}\nCOORD\n{{/is_coordinator}}{{#is_worker}}\nWORK\n{{/is_worker}}{{#is_reviewer}}\nREVIEW\n{{/is_reviewer}}T"
	got := bridge_bootstrap_eval_role_sections(tpl, false, true, false)
	defer delete(got)
	testing.expect_value(t, got, "H\nWORK\nT")
}

@(test)
bt3_role_reviewer_kept :: proc(t: ^testing.T) {
	tpl := "H\n{{#is_coordinator}}\nCOORD\n{{/is_coordinator}}{{#is_worker}}\nWORK\n{{/is_worker}}{{#is_reviewer}}\nREVIEW\n{{/is_reviewer}}T"
	got := bridge_bootstrap_eval_role_sections(tpl, false, false, true)
	defer delete(got)
	testing.expect_value(t, got, "H\nREVIEW\nT")
}

@(test)
bt3_role_inline_coordinator_line :: proc(t: ^testing.T) {
	// The header uses inline (no-leading-newline) role blocks for the Coordinator line.
	tpl := "Instance: x\n{{#is_coordinator}}Coordinator: you (coordinator)\n{{/is_coordinator}}{{#is_worker}}Coordinator: {coordinator_id}\n{{/is_worker}}next"
	coord := bridge_bootstrap_eval_role_sections(tpl, true, false, false)
	defer delete(coord)
	testing.expect_value(t, coord, "Instance: x\nCoordinator: you (coordinator)\nnext")
	work := bridge_bootstrap_eval_role_sections(tpl, false, true, false)
	defer delete(work)
	testing.expect_value(t, work, "Instance: x\nCoordinator: {coordinator_id}\nnext")
}

@(test)
bt3_full_pipeline_worker :: proc(t: ^testing.T) {
	// Role eval THEN scalar substitution, matching bridge_bootstrap_render_template order.
	tpl := "Agent: {agent_name}\n{{#is_worker}}Coordinator: {coordinator_id}\n{{/is_worker}}{{#is_coordinator}}Coordinator: you (coordinator)\n{{/is_coordinator}}## {project_name}"
	after_roles := bridge_bootstrap_eval_role_sections(tpl, false, true, false)
	names := []string{"agent_name", "coordinator_id", "project_name"}
	values := []string{"A", "inst_coord", "Proj"}
	got := bridge_bootstrap_substitute_scalars(after_roles, names, values)
	delete(after_roles)
	defer delete(got)
	testing.expect_value(t, got, "Agent: A\nCoordinator: inst_coord\n## Proj")
}

@(test)
bt3_is_placeholder_key :: proc(t: ^testing.T) {
	testing.expect(t, bridge_bootstrap_is_placeholder_key("agent_name"))
	testing.expect(t, bridge_bootstrap_is_placeholder_key("project_name2"))
	testing.expect(t, !bridge_bootstrap_is_placeholder_key(""))
	testing.expect(t, !bridge_bootstrap_is_placeholder_key("has space"))
	testing.expect(t, !bridge_bootstrap_is_placeholder_key("\"k\": 1"))
}

@(test)
bt3_e2e_real_template_worker :: proc(t: ^testing.T) {
	tpl := string(#load("../prompts/bootstrap_agents.md", string))
	after := bridge_bootstrap_eval_role_sections(tpl, false, true, false)
	defer delete(after)
	names := []string{"coordinator_id","coordinator_line"}
	values := []string{"inst_coord","\nCoordinator: inst_coord"}
	got := bridge_bootstrap_substitute_scalars(after, names, values)
	defer delete(got)
	testing.expect(t, strings.contains(got, "## You are a WORKER"))
	testing.expect(t, !strings.contains(got, "## You are the COORDINATOR"))
	testing.expect(t, strings.contains(got, "Coordinator: inst_coord"))
}

@(test)
bt_memory_decouple_manifest_and_file_set :: proc(t: ^testing.T) {
	tpl_body := "Agent: {agent_name}\n"
	mem_body := "# Applicable Memories\n\n### Test Title\nType: Fact\n\nSome memory body\n"

	tpl_hash := test_bootstrap_sha256(tpl_body)
	defer delete(tpl_hash)
	mem_hash := test_bootstrap_sha256(mem_body)
	defer delete(mem_hash)

	manifest := strings.concatenate({
		`{"protocol":2,"version":"v1","agent_id":"agt_1","files":[{"kind":"AGENTS_MD","relative_path":"AGENTS.md","assembly":[]},{"kind":"MEMORY_MD","relative_path":"MEMORY.md","hash":"`,
		mem_hash,
		`"}],"template":{"kind":"AGENTS_TEMPLATE","hash":"`,
		tpl_hash,
		`"},"variables":[]}`,
	})
	defer delete(manifest)

	// 1. bridge_bootstrap_collect_manifest_hashes picks up MEMORY_MD direct hash
	hashes := bridge_bootstrap_collect_manifest_hashes(manifest)
	defer {
		for h in hashes do delete(h)
		delete(hashes)
	}
	found_mem_hash := false
	for h in hashes {
		if h == mem_hash do found_mem_hash = true
	}
	testing.expect(t, found_mem_hash, "manifest hashes must collect MEMORY_MD hash")

	// 2. bridge_bootstrap_build_file_set builds MEMORY.md into files
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	prev, had := os.lookup_env("HEIMDALL_HAM_CTL_BIN", context.allocator)
	defer {
		if had {
			_ = os.set_env("HEIMDALL_HAM_CTL_BIN", prev)
		} else {
			os.unset_env("HEIMDALL_HAM_CTL_BIN")
		}
		delete(prev)
	}
	_ = os.set_env("HEIMDALL_HAM_CTL_BIN", "/bin/sh")

	cache: Bootstrap_Cache
	tmp := fmt.tprintf("/tmp/ham-test-mem-decouple-%d", os.get_pid())
	_ = os.remove_all(tmp)
	defer _ = os.remove_all(tmp)
	bootstrap_cache_init(&cache, tmp, 1024 * 1024)
	bootstrap_cache_put(&cache, tpl_hash, tpl_body)
	bootstrap_cache_put(&cache, mem_hash, mem_body)

	d := Bridge_Bootstrap_Descriptor{
		instance_id = "inst_1",
		agent_name = "Agent 1",
		role = "worker",
	}

	files, res := bridge_bootstrap_build_file_set(manifest, d, "unix:/tmp/test.sock", "tok", "codex", &cache)
	defer bridge_bootstrap_free_file_set(files)

	testing.expect(t, res.ok, "build file set should succeed")
	found_memory_file := false
	for f in files {
		if f.kind == "MEMORY_MD" {
			found_memory_file = true
			testing.expect_value(t, f.relative_path, "MEMORY.md")
			testing.expect_value(t, f.mode, 0o644)
			testing.expect_value(t, f.content, mem_body)
		}
	}
	testing.expect(t, found_memory_file, "MEMORY.md file should be present in file set")
}

@(test)
bt_memory_decouple_materialize_run_dir :: proc(t: ^testing.T) {
	tpl_body := "Agent: {agent_name}\n"
	mem_body := "# Applicable Memories\n\n### Habit Memory\nType: Habit\n\nAlways write tests\n"

	tpl_hash := test_bootstrap_sha256(tpl_body)
	defer delete(tpl_hash)
	mem_hash := test_bootstrap_sha256(mem_body)
	defer delete(mem_hash)

	manifest := strings.concatenate({
		`{"protocol":2,"version":"v1","agent_id":"agt_1","files":[{"kind":"AGENTS_MD","relative_path":"AGENTS.md","assembly":[]},{"kind":"MEMORY_MD","relative_path":"MEMORY.md","hash":"`,
		mem_hash,
		`"}],"template":{"kind":"AGENTS_TEMPLATE","hash":"`,
		tpl_hash,
		`"},"variables":[]}`,
	})
	defer delete(manifest)

	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	prev, had := os.lookup_env("HEIMDALL_HAM_CTL_BIN", context.allocator)
	defer {
		if had {
			_ = os.set_env("HEIMDALL_HAM_CTL_BIN", prev)
		} else {
			os.unset_env("HEIMDALL_HAM_CTL_BIN")
		}
		delete(prev)
	}
	_ = os.set_env("HEIMDALL_HAM_CTL_BIN", "/bin/sh")

	cache: Bootstrap_Cache
	cache_dir := fmt.tprintf("/tmp/ham-test-mat-cache-%d", os.get_pid())
	run_dir := fmt.tprintf("/tmp/ham-test-mat-rundir-%d", os.get_pid())
	_ = os.remove_all(cache_dir)
	_ = os.remove_all(run_dir)
	defer {
		_ = os.remove_all(cache_dir)
		_ = os.remove_all(run_dir)
	}
	bootstrap_cache_init(&cache, cache_dir, 1024 * 1024)
	bootstrap_cache_put(&cache, tpl_hash, tpl_body)
	bootstrap_cache_put(&cache, mem_hash, mem_body)

	d := Bridge_Bootstrap_Descriptor{
		instance_id = "inst_test_launch",
		agent_name = "Launch Agent",
		role = "worker",
	}

	res := bridge_bootstrap_materialize_run_dir(manifest, d, run_dir, "unix:/tmp/test.sock", "tok", "codex", &cache)
	testing.expect(t, res.ok, "materialize_run_dir should succeed")

	// Verify both AGENTS.md and MEMORY.md exist on disk in run_dir
	agents_path := strings.concatenate({run_dir, "/AGENTS.md"})
	defer delete(agents_path)
	agents_bytes, a_err := os.read_entire_file(agents_path, context.allocator)
	testing.expect(t, a_err == nil, "AGENTS.md should exist")
	if a_err == nil {
		defer delete(agents_bytes)
		testing.expect(t, strings.contains(string(agents_bytes), "Agent: Launch Agent"), "AGENTS.md content check")
	}

	mem_path := strings.concatenate({run_dir, "/MEMORY.md"})
	defer delete(mem_path)
	mem_bytes, m_err := os.read_entire_file(mem_path, context.allocator)
	testing.expect(t, m_err == nil, "MEMORY.md should exist")
	if m_err == nil {
		defer delete(mem_bytes)
		testing.expect_value(t, string(mem_bytes), mem_body)
	}

	// Verify heimdall-bootstrap-manifest.json lists MEMORY.md
	man_path := strings.concatenate({run_dir, "/heimdall-bootstrap-manifest.json"})
	defer delete(man_path)
	man_bytes, man_err := os.read_entire_file(man_path, context.allocator)
	testing.expect(t, man_err == nil, "manifest json should exist")
	if man_err == nil {
		defer delete(man_bytes)
		testing.expect(t, strings.contains(string(man_bytes), `"relative_path":"MEMORY.md","kind":"MEMORY_MD"`), "manifest json tracks MEMORY.md")
	}
}

test_bootstrap_sha256 :: proc(body: string) -> string {
	buf: [32]byte
	hash.hash_string_to_buffer(.SHA256, body, buf[:])
	hex_str := hex.encode(buf[:])
	defer delete(hex_str)
	return strings.concatenate({"sha256:", string(hex_str)})
}

@(test)
bootstrap_run_dir_ctl_routes_to_each_bridge :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	previous, existed := os.lookup_env("HEIMDALL_HAM_CTL_BIN", context.allocator)
	defer {
		if existed {
			_ = os.set_env("HEIMDALL_HAM_CTL_BIN", previous)
		} else {
			os.unset_env("HEIMDALL_HAM_CTL_BIN")
		}
		delete(previous)
	}
	_ = os.set_env("HEIMDALL_HAM_CTL_BIN", "/bin/sh")
	endpoints := []string{"tcp:127.0.0.1:50324", "tcp:127.0.0.1:50326", "unix:/tmp/bridge-own/socket"}
	for endpoint in endpoints {
		shim, ok := bridge_bootstrap_render_ham_ctl_shim(endpoint, "agent-test-token", "instance-test")
		testing.expect(t, ok)
		if !ok do continue
		defer delete(shim)
		argv := []string{"/bin/sh", "-c", shim, "ham-ctl", "-c", `printf '%s' "$HEIMDALL_BRIDGE_ENDPOINT"`}
		state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = argv}, context.allocator)
		defer delete(stdout)
		defer delete(stderr)
		testing.expect(t, err == nil && state.success)
		testing.expect_value(t, string(stdout), endpoint)
	}
}

// The hub holds no vault key, so encrypted template variables, memories and skills
// reach the bridge as vault:v1 tokens. The bridge must decrypt them before any
// bootstrap file is written.
@(test)
bt_file_set_decrypts_vault_tokens :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	enc :: proc(s: string) -> string {
		a, _ := test_encrypt_hex(s, TEST_VAULT_KEY_HEX, context.temp_allocator)
		return a
	}
	tpl_body := "Project: {project_name}\n"
	mem_body := strings.concatenate({"# Applicable Memories\n\n### ", enc("Memory Title"), "\nType: fact\n\n", enc("Memory body"), "\n"}, context.temp_allocator)
	skill_body := strings.concatenate({"# ", enc("Skill body"), "\n"}, context.temp_allocator)

	tpl_hash := test_bootstrap_sha256(tpl_body)
	defer delete(tpl_hash)
	mem_hash := test_bootstrap_sha256(mem_body)
	defer delete(mem_hash)
	skill_hash := test_bootstrap_sha256(skill_body)
	defer delete(skill_hash)

	manifest := strings.concatenate({
		`{"protocol":2,"version":"v1","agent_id":"agt_1","files":[{"kind":"AGENTS_MD","relative_path":"AGENTS.md","assembly":[]},{"kind":"MEMORY_MD","relative_path":"MEMORY.md","hash":"`, mem_hash,
		`"}],"skills":[{"name":"`, enc("Secret Skill"), `","hash":"`, skill_hash,
		`"}],"template":{"kind":"AGENTS_TEMPLATE","hash":"`, tpl_hash,
		`"},"variables":[{"name":"project_name","value":"`, enc("My Project"), `"}]}`,
	})
	defer delete(manifest)

	prev, had := os.lookup_env("HEIMDALL_HAM_CTL_BIN", context.allocator)
	defer {
		if had {
			_ = os.set_env("HEIMDALL_HAM_CTL_BIN", prev)
		} else {
			os.unset_env("HEIMDALL_HAM_CTL_BIN")
		}
		delete(prev)
	}
	_ = os.set_env("HEIMDALL_HAM_CTL_BIN", "/bin/sh")
	os.set_env("HEIMDALL_VAULT_KEYRING", test_keyring_env_value(TEST_VAULT_KEY_HEX))
	defer os.unset_env("HEIMDALL_VAULT_KEYRING")

	cache: Bootstrap_Cache
	tmp := fmt.tprintf("/tmp/ham-test-bootstrap-decrypt-%d", os.get_pid())
	_ = os.remove_all(tmp)
	defer _ = os.remove_all(tmp)
	bootstrap_cache_init(&cache, tmp, 1024 * 1024)
	bootstrap_cache_put(&cache, tpl_hash, tpl_body)
	bootstrap_cache_put(&cache, mem_hash, mem_body)
	bootstrap_cache_put(&cache, skill_hash, skill_body)

	d := Bridge_Bootstrap_Descriptor{instance_id = "inst_1", agent_name = "Agent 1", role = "worker"}
	test_providers := []Bridge_Catalog_Provider{{
		provider  = "codex",
		state     = "active",
		skill_dir = ".agents/skills",
	}}
	test_snap := Bridge_Provider_Catalog_Snapshot{
		providers = test_providers,
	}
	sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
	prev_loaded := bridge_provider_catalog_loaded
	prev_snap := bridge_provider_catalog_snapshot
	bridge_provider_catalog_loaded = true
	bridge_provider_catalog_snapshot = &test_snap
	sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
	defer {
		sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
		bridge_provider_catalog_loaded = prev_loaded
		bridge_provider_catalog_snapshot = prev_snap
		sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
	}
	files, res := bridge_bootstrap_build_file_set(manifest, d, "unix:/tmp/test.sock", "tok", "codex", &cache)
	defer bridge_bootstrap_free_file_set(files)
	testing.expect(t, res.ok, "build file set should succeed")

	seen_agents, seen_mem, seen_skill := false, false, false
	for f in files {
		testing.expect(t, !strings.contains(f.content, vault.VAULT_V2_PREFIX), f.relative_path)
		switch f.kind {
		case "AGENTS_MD":
			seen_agents = true
			testing.expect(t, strings.contains(f.content, "Project: My Project"), "template variable must be decrypted")
		case "MEMORY_MD":
			seen_mem = true
			testing.expect(t, strings.contains(f.content, "### Memory Title\nType: fact\n\nMemory body"), "memory title/body must be decrypted")
		case "SKILL":
			seen_skill = true
			testing.expect(t, strings.contains(f.relative_path, "/Secret-Skill/SKILL.md"), f.relative_path)
			testing.expect_value(t, f.content, "# Skill body\n")
		}
	}
	testing.expect(t, seen_agents && seen_mem && seen_skill, "AGENTS_MD, MEMORY_MD and SKILL files must all be present")
}
