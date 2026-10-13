// Golden-output (no-drift) guard for the bootstrap AGENTS.md.
//
// Two complementary layers:
//   1. This file pins the surviving per-renderer output: the AGENTS.md header
//      (render_header_inline — the bridge injects it locally) plus the BT-2/BT-2a
//      hub manifest producers (template blob hash, project + identity variables,
//      the shared template+variables JSON writer).
//   2. bt5_render_golden.odin pins the FULLY-ASSEMBLED AGENTS.md rendered through
//      the real hub->bridge single-template engine (see bt5_render_goldens_checks).
//
// BT-6 removed the old per-fragment renderers (render_agent_identity/project/
// tasks_guidance/role_guidance) and their goldens: the single template now owns
// that prose, so the assembled-document goldens (layer 2) are the source of truth
// for it and per-fragment goldens would be redundant/misleading.
//
// Regenerate goldens intentionally with:  HEIMDALL_GOLDEN_UPDATE=1 <run test>
// (only when the change to the rendered output is deliberate).
//
// Case coverage:
//   - header_coordinator / header_worker / header_no_chain (render_header_inline)
//   - BT-2 template blob + project variables (bt2_template_and_variables_checks)
//   - BT-2a identity variables (bt2a_identity_variables_checks)
//   - BT-5 assembled AGENTS.md, all role/identity cases (bt5_render_goldens_checks)
package hub_bootstrap_golden_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import agent_service "odin_test:hub/service/agent"

GOLDEN_DIR :: "tests/hub_bootstrap_golden_test/golden"

failures := 0

@(test)
test_hub_bootstrap_golden :: proc(t: ^testing.T) {
	main()
	testing.expect_value(t, failures, 0)
}

main :: proc() {
	failures = 0
	// --- Header goldens -----------------------------------------------------
	// render_header_inline is the ONLY surviving per-fragment renderer (the bridge
	// injects the AGENTS.md header locally from the instance manifest). The
	// BT-6 fragment cutover removed render_agent_identity/project/tasks_guidance/
	// role_guidance and their goldens; the fully-assembled document is now pinned
	// by the BT-5 goldens (bt5_render_goldens_checks) instead.
	// render_header_inline(agent_name, instance_id, chain_title, chain_id, coordinator_id, is_coordinator)
	check_golden("header_coordinator", agent_service.render_header_inline(
		"Backend Agent", "inst_1", "Prompts audit", "chain_1", "inst_1", true))
	check_golden("header_worker", agent_service.render_header_inline(
		"Backend Agent", "inst_2", "Prompts audit", "chain_1", "inst_coord", false))
	check_golden("header_no_chain", agent_service.render_header_inline(
		"Backend Agent", "inst_3", "", "", "", false))

	// --- BT-2: single-template blob + variables manifest emission -----------
	bt2_template_and_variables_checks()

	// --- BT-2a: identity variables (template_persona/instructions/agent_instructions)
	bt2a_identity_variables_checks()

	// --- BT-5: fully-assembled single-template AGENTS.md goldens (real render path)
	bt5_render_goldens_checks()

	if failures > 0 {
		fmt.eprintfln("bootstrap golden test: %d case(s) FAILED", failures)
		os.exit(1)
	}
	fmt.println("bootstrap golden test: all cases OK")
}

// bt2_template_and_variables_checks exercises the BT-2 hub producers directly
// (no DB): the template blob hash, the fixed-order project variable set, and the
// shared template+variables JSON writer. Asserts structure/order/hash-stability
// so BT-3 (bridge) can build to a pinned contract.
bt2_template_and_variables_checks :: proc() {
	// Template blob: hashed + cached, hash is deterministic sha256 of the body.
	h1 := agent_service.bootstrap_template_hash()
	h2 := agent_service.bootstrap_fragment_hash(agent_service.BOOTSTRAP_AGENTS_TEMPLATE)
	assert_true("bt2_template_hash_stable", h1 == h2 && strings.has_prefix(h1, "sha256:"))
	assert_true("bt2_template_nonempty", len(agent_service.BOOTSTRAP_AGENTS_TEMPLATE) > 0)
	// Template must carry the placeholders + role blocks the bridge substitutes.
	tpl := agent_service.BOOTSTRAP_AGENTS_TEMPLATE
	assert_true("bt2_template_has_scalars",
		strings.contains(tpl, "{agent_name}") && strings.contains(tpl, "{project_name}") &&
		strings.contains(tpl, "{template_persona}") && strings.contains(tpl, "{agent_instructions}"))
	assert_true("bt2_template_has_role_blocks",
		strings.contains(tpl, "{{#is_coordinator}}") && strings.contains(tpl, "{{#is_worker}}") &&
		strings.contains(tpl, "{{#is_reviewer}}"))

	// Project variables: exactly 5, fixed order, each hashed.
	vars := agent_service.bootstrap_build_project_variables("Heimdall", "~/h", "git@x:h.git", "git", "desc")
	defer delete(vars)
	expect_names := []string{"project_name", "project_path", "project_repo", "project_vcs", "project_description"}
	ordered := len(vars) == 5
	if ordered do for v, i in vars { if v.name != expect_names[i] { ordered = false; break } }
	assert_true("bt2_project_vars_order", ordered)
	assert_true("bt2_project_var_value", len(vars) == 5 && vars[0].value == "Heimdall")
	assert_true("bt2_project_var_hashed", len(vars) == 5 && vars[0].hash == agent_service.bootstrap_fragment_hash("Heimdall"))

	// Empty values still emitted (deterministic version / explicit empty substitution).
	empty_vars := agent_service.bootstrap_build_project_variables("", "", "", "", "")
	defer delete(empty_vars)
	assert_true("bt2_empty_vars_present", len(empty_vars) == 5 && empty_vars[0].value == "")

	// JSON writer: shape = ,"template":{...},"variables":[...] with name/hash/value.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	agent_service.bootstrap_write_template_and_variables_json(&b, h1, vars[:])
	json := strings.to_string(b)
	assert_true("bt2_json_template_obj", strings.contains(json, "\"template\":{\"kind\":\"AGENTS_TEMPLATE\",\"hash\":\""))
	assert_true("bt2_json_variables_arr", strings.contains(json, "\"variables\":["))
	assert_true("bt2_json_var_fields", strings.contains(json, "\"name\":\"project_name\"") &&
		strings.contains(json, "\"value\":\"Heimdall\""))
}

// bt2a_identity_variables_checks exercises the BT-2a identity variable producers:
// bootstrap_append_identity_variables adds template_persona/template_instructions/
// agent_instructions onto the project vars in the correct fixed order.
bt2a_identity_variables_checks :: proc() {
	vars := agent_service.bootstrap_build_project_variables("P", "/p", "", "", "")
	defer delete(vars)
	agent_service.bootstrap_append_identity_variables(
		&vars, "You are Odin.", "Base rules.", "Agent rules.")

	// 5 project + 3 identity = 8 total in fixed order.
	assert_true("bt2a_var_count", len(vars) == 8)
	assert_true("bt2a_order_template_persona",
		len(vars) >= 6 && vars[5].name == "template_persona")
	assert_true("bt2a_order_template_instructions",
		len(vars) >= 7 && vars[6].name == "template_instructions")
	assert_true("bt2a_order_agent_instructions",
		len(vars) >= 8 && vars[7].name == "agent_instructions")
	// Values correct.
	assert_true("bt2a_persona_value",  len(vars) >= 6 && vars[5].value == "You are Odin.")
	assert_true("bt2a_tinstr_value",   len(vars) >= 7 && vars[6].value == "Base rules.")
	assert_true("bt2a_ainstr_value",   len(vars) >= 8 && vars[7].value == "Agent rules.")
	// Each is independently hashed.
	assert_true("bt2a_persona_hashed",
		len(vars) >= 6 && vars[5].hash == agent_service.bootstrap_fragment_hash("You are Odin."))
	// Empty persona still emitted (deterministic version + explicit empty substitution).
	vars2 := agent_service.bootstrap_build_project_variables("", "", "", "", "")
	defer delete(vars2)
	agent_service.bootstrap_append_identity_variables(&vars2, "", "", "")
	assert_true("bt2a_empty_identity_present", len(vars2) == 8 && vars2[5].value == "")
	// JSON writer includes identity vars.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	h := agent_service.bootstrap_template_hash()
	agent_service.bootstrap_write_template_and_variables_json(&b, h, vars[:])
	json := strings.to_string(b)
	assert_true("bt2a_json_has_persona",
		strings.contains(json, "\"name\":\"template_persona\"") &&
		strings.contains(json, "\"value\":\"You are Odin.\""))
	assert_true("bt2a_json_has_agent_instr",
		strings.contains(json, "\"name\":\"agent_instructions\""))
}

assert_true :: proc(name: string, ok: bool) {
	if ok {
		fmt.printfln("ok %s", name)
	} else {
		failures += 1
		fmt.eprintfln("ASSERT FAILED %s", name)
	}
}

// check_golden compares `got` against golden/<name>.txt. With HEIMDALL_GOLDEN_UPDATE=1
// it (re)writes the golden instead of asserting — use only for deliberate output
// changes.
check_golden :: proc(name, got: string) {
	path := strings.concatenate({GOLDEN_DIR, "/", name, ".txt"})
	defer delete(path)

	if os.get_env("HEIMDALL_GOLDEN_UPDATE", context.allocator) == "1" {
		if os.write_entire_file(path, transmute([]byte)got) == nil {
			fmt.printfln("updated golden %s (%d bytes)", name, len(got))
		} else {
			fmt.eprintfln("FAILED to write golden %s", name)
			failures += 1
		}
		return
	}

	want_bytes, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("MISSING golden %s (run with HEIMDALL_GOLDEN_UPDATE=1 to create)", name)
		failures += 1
		return
	}
	defer delete(want_bytes)
	want := string(want_bytes)
	if got != want {
		failures += 1
		fmt.eprintfln("GOLDEN MISMATCH %s", name)
		fmt.eprintfln("  got  (%d bytes): %q", len(got), got)
		fmt.eprintfln("  want (%d bytes): %q", len(want), want)
	} else {
		fmt.printfln("ok %s (%d bytes)", name, len(got))
	}
}
