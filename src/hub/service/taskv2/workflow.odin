package taskv2

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import jsonx "odin_test:lib/jsonx"

// ---- Built-in Workflow Templates (#load) --------------------------------------------

BUILTIN_WORKFLOW_EXPLORE_PLAN_BUILD :: string(#load("../../../prompts/workflows/explore_plan_build.json"))
BUILTIN_WORKFLOW_FIX_FLAKY_TESTS    :: string(#load("../../../prompts/workflows/fix_flaky_tests.json"))
BUILTIN_WORKFLOW_SECURITY_AUDIT     :: string(#load("../../../prompts/workflows/security_audit.json"))

Workflow_Template :: struct {
	id:          string,
	name:        string,
	title:       string,
	description: string,
	source:      string,
	spec_json:   string,
}

workflow_builtin_templates :: proc(allocator := context.temp_allocator) -> []Workflow_Template {
	out := make([dynamic]Workflow_Template, 0, 3, allocator)
	append(&out, Workflow_Template{
		id          = "tpl_explore_plan_build",
		name        = "explore_plan_build",
		title       = "Explore -> Plan -> Approve -> Build -> Integrate",
		description = "Explore the codebase, produce a structured task_list.v1 plan, pause at a human/coordinator gate, then fan out across planned items and finish with an integration review of the combined result.",
		source      = "builtin",
		spec_json   = BUILTIN_WORKFLOW_EXPLORE_PLAN_BUILD,
	})
	append(&out, Workflow_Template{
		id          = "tpl_fix_flaky_tests",
		name        = "fix_flaky_tests",
		title       = "Reproduce -> Diagnose -> Fix Flaky Tests",
		description = "Scan a test suite for flaky tests, produce a task_list.v1 of reproducers/fixes, and fix each flaky test in parallel, reporting the checks that show it is stable.",
		source      = "builtin",
		spec_json   = BUILTIN_WORKFLOW_FIX_FLAKY_TESTS,
	})
	append(&out, Workflow_Template{
		id          = "tpl_security_audit",
		name        = "security_audit",
		title       = "Security Audit -> Triage Gate -> Remediate",
		description = "Scan target scope for security vulnerabilities (findings.v1), triage at a gate, and remediate findings.",
		source      = "builtin",
		spec_json   = BUILTIN_WORKFLOW_SECURITY_AUDIT,
	})
	return out[:]
}

// ---- Workflow Spec Types & Parser ---------------------------------------------------

Workflow_Input_Spec :: struct {
	name:        string,
	type_name:   string,
	required:    bool,
	default_val: string,
	has_default: bool,
	// default_raw is the declared default as raw JSON (any type), so array
	// defaults can feed `for_each: "inputs.<name>"`. type_declared records
	// whether the spec stated a type (the parser otherwise assumes "string").
	default_raw:   string,
	type_declared: bool,
	description: string,
}

Workflow_Stage_Spec :: struct {
	key:                    string,
	kind:                   domain.Task_Kind,
	title:                  string,
	description:            string,
	depends_on:             []string,
	for_each:               string,
	parallel:               int,
	max_parallel:           int,
	priority:               string,
	brief_raw:              string,
	gate_raw:               string,
	approver:               string,
	prompt:                 string,
	requires_user_approval: bool,
	// the spec SAID requires_user_approval (true or false); absent → the solo default.
	has_requires_user_approval: bool,
	raw_json:               string,
}

Workflow_Parsed_Spec :: struct {
	name:            string,
	title:           string,
	description:     string,
	version:         int,
	inputs:          []Workflow_Input_Spec,
	defaults_raw:    string,
	stages:          []Workflow_Stage_Spec,
	normalized_json: string,
}

Workflow_Run_Snapshot :: struct {
	spec:        Workflow_Parsed_Spec,
	inputs_json: string,
	// inputs_members: key → raw value text of inputs_json, scanned once when
	// the snapshot is built. Every {{inputs.*}} placeholder and input fan-out
	// reads it; re-extracting each key from the JSON text cost a full parse of
	// the whole input snapshot per lookup (multi-second for MB-sized inputs,
	// inside the UoW).
	inputs_members: map[string]string,
	def_id:      string,
}

// parse_and_validate_workflow_spec parses and validates both dialects of workflow.v1:
//   Dialect A: {"kind":"workflow", "v":1, "name":..., "stages":[...]}
//   Dialect B: {"schema":"workflow.v1", "version":1, "name":..., "stages":[...]}
parse_and_validate_workflow_spec :: proc(raw_spec: string, name_override := "", version_override := 0, allocator := context.temp_allocator) -> (Workflow_Parsed_Spec, bool, domain.Domain_Error) {
	trimmed := strings.trim_space(raw_spec)
	if !strings.has_prefix(trimmed, "{") || !strings.has_suffix(trimmed, "}") {
		return {}, false, domain.domain_error(.Validation_Failed, "workflow spec must be a JSON object", `{"code":"workflow_invalid"}`)
	}
	// M2: legacy verify keys in defaults / stage briefs are dropped, so neither
	// stored definitions, run snapshots nor materialised briefs carry them.
	trimmed, _ = strip_removed_verify_keys_in_workflow_spec(trimmed, allocator)
	schema_str := strings.trim_space(jsonx.extract_string(trimmed, "schema", "", true, allocator))
	kind_str := strings.trim_space(jsonx.extract_string(trimmed, "kind", "", true, allocator))
	if schema_str != "" && schema_str != "workflow.v1" && schema_str != "workflow" {
		return {}, false, domain.domain_error(.Validation_Failed, "workflow schema must be workflow.v1", `{"code":"workflow_invalid"}`)
	}
	if kind_str != "" && kind_str != "workflow" && kind_str != "workflow.v1" {
		return {}, false, domain.domain_error(.Validation_Failed, "workflow kind must be workflow", `{"code":"workflow_invalid"}`)
	}
	ver := jsonx.extract_int(trimmed, "version", 0, true)
	if ver <= 0 do ver = jsonx.extract_int(trimmed, "v", 1, true)
	if version_override > 0 do ver = version_override
	if ver <= 0 do ver = 1

	name := strings.trim_space(name_override)
	if name == "" do name = strings.trim_space(jsonx.extract_string(trimmed, "name", "", true, allocator))
	if name == "" do name = strings.trim_space(jsonx.extract_string(trimmed, "id", "", true, allocator))
	title := strings.trim_space(jsonx.extract_string(trimmed, "title", name, true, allocator))
	if title == "" do title = name
	desc := strings.trim_space(jsonx.extract_string(trimmed, "description", "", true, allocator))

	defaults_raw, has_def := jsonx.extract_raw_object(trimmed, "defaults", true, allocator)
	if !has_def || strings.trim_space(defaults_raw) == "" do defaults_raw = "{}"

	inputs_specs := parse_workflow_inputs_spec(trimmed, allocator)

	stages_arr, has_stages := jsonx.extract_raw_array(trimmed, "stages", true, allocator)
	if !has_stages || strings.trim_space(stages_arr) == "" {
		return {}, false, domain.domain_error(.Validation_Failed, "workflow stages array is required", `{"code":"workflow_invalid"}`)
	}
	stage_objs, ok_arr := split_json_array_objects(stages_arr, allocator)
	if !ok_arr || len(stage_objs) == 0 {
		return {}, false, domain.domain_error(.Validation_Failed, "workflow must declare at least one stage", `{"code":"workflow_invalid"}`)
	}

	stages := make([dynamic]Workflow_Stage_Spec, 0, len(stage_objs), allocator)
	stage_by_key := make(map[string]Workflow_Stage_Spec, len(stage_objs), allocator)

	for sobj in stage_objs {
		skey := strings.trim_space(jsonx.extract_string(sobj, "key", "", true, allocator))
		if skey == "" do skey = strings.trim_space(jsonx.extract_string(sobj, "id", "", true, allocator))
		if !is_valid_stage_key(skey) {
			return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("invalid or empty stage key: %s", skey), `{"code":"workflow_invalid"}`)
		}
		if _, dup := stage_by_key[skey]; dup {
			return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("duplicate stage key: %s", skey), `{"code":"workflow_invalid"}`)
		}
		skind_str := strings.trim_space(jsonx.extract_string(sobj, "kind", "task", true, allocator))
		if skind_str == "" do skind_str = "task"
		if skind_str != "task" && skind_str != "gate" {
			return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s kind must be task or gate", skey), `{"code":"workflow_invalid"}`)
		}
		skind := domain.task_kind_from_string(skind_str)
		stitle := strings.trim_space(jsonx.extract_string(sobj, "title", skey, true, allocator))
		if stitle == "" do stitle = skey
		sdesc := strings.trim_space(jsonx.extract_string(sobj, "description", "", true, allocator))
		deps := jsonx.extract_string_array(sobj, "depends_on", true, allocator)
		if len(deps) == 0 do deps = jsonx.extract_string_array(sobj, "needs", true, allocator)
		for_each := strings.trim_space(jsonx.extract_string(sobj, "for_each", "", true, allocator))
		max_p := jsonx.extract_int(sobj, "max_parallel", 0, true)
		parallel_n, has_parallel := jsonx.extract_int_found(sobj, "parallel", true)
		if has_parallel && (parallel_n < 1 || parallel_n > 50) {
			return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s parallel must be between 1 and 50", skey), `{"code":"workflow_invalid"}`)
		}
		prio := strings.trim_space(jsonx.extract_string(sobj, "priority", "", true, allocator))
		brief_raw, has_brief := jsonx.extract_raw_object(sobj, "brief", true, allocator)
		if !has_brief do brief_raw = "{}"
		// If stage-level `output` is declared and `brief` has no `output`, merge it into `brief_raw`
		if !brief_has_output_contract(brief_raw) {
			if stage_out_obj, has_so := jsonx.extract_raw_object(sobj, "output", true, allocator); has_so && strings.trim_space(stage_out_obj) != "" {
				bb := json_begin(allocator)
				for k, v in jsonx_top_level_members(brief_raw) do json_raw(&bb, k, v)
				json_raw(&bb, "output", stage_out_obj)
				brief_raw = json_end(&bb)
			} else if stage_out_str := strings.trim_space(jsonx.extract_string(sobj, "output", "", true, allocator)); stage_out_str != "" && stage_out_str != "none" {
				bb := json_begin(allocator)
				for k, v in jsonx_top_level_members(brief_raw) do json_raw(&bb, k, v)
				json_str(&bb, "output", stage_out_str)
				brief_raw = json_end(&bb)
			}
		}
		gate_raw, has_gate := jsonx.extract_raw_object(sobj, "gate", true, allocator)
		if !has_gate do gate_raw = "{}"
		approver := strings.trim_space(jsonx.extract_string(sobj, "approver", "", true, allocator))
		if approver == "" && has_gate do approver = strings.trim_space(jsonx.extract_string(gate_raw, "approver", "", true, allocator))
		if approver == "" && has_brief do approver = strings.trim_space(jsonx.extract_string(brief_raw, "approver", "", true, allocator))
		if approver == "" do approver = "user_or_coordinator"
		prompt := strings.trim_space(jsonx.extract_string(sobj, "prompt", "", true, allocator))
		if prompt == "" && has_gate do prompt = strings.trim_space(jsonx.extract_string(gate_raw, "prompt", "", true, allocator))
		if prompt == "" && has_brief do prompt = strings.trim_space(jsonx.extract_string(brief_raw, "goal", "", true, allocator))
		req_user, has_req_user := jsonx.extract_bool_literal(sobj, "requires_user_approval", true)
		if !has_req_user && has_brief do req_user, has_req_user = jsonx.extract_bool_literal(brief_raw, "requires_user_approval", true)

		if skind == .Gate && (for_each != "" || parallel_n > 1) {
			return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("gate stage %s cannot use for_each or parallel > 1", skey), `{"code":"workflow_invalid"}`)
		}
		if skind == .Gate && approver != "user" && approver != "user_or_coordinator" {
			return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("gate stage %s approver must be user or user_or_coordinator", skey), `{"code":"workflow_invalid"}`)
		}
		if skind == .Task {
			bgoal := strings.trim_space(jsonx.extract_string(brief_raw, "goal", "", true, allocator))
			// A stage needs a goal and something checkable: acceptance items or a
			// structured output contract. No command is ever required.
			bacc := jsonx.extract_string_array(brief_raw, "acceptance", true, allocator)
			if bgoal == "" || (len(bacc) == 0 && !brief_has_output_contract(brief_raw)) {
				return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s brief requires a non-empty goal and acceptance items or an output contract", skey), `{"code":"workflow_invalid"}`)
			}
		}

		st := Workflow_Stage_Spec{
			key                    = skey,
			kind                   = skind,
			title                  = stitle,
			description            = sdesc,
			depends_on             = deps[:],
			for_each               = for_each,
			parallel               = parallel_n if parallel_n > 0 else 1,
			max_parallel           = max_p,
			priority               = prio,
			brief_raw              = brief_raw,
			gate_raw               = gate_raw,
			approver               = approver,
			prompt                 = prompt,
			requires_user_approval = req_user,
			has_requires_user_approval = has_req_user,
			raw_json               = sobj,
		}
		append(&stages, st)
		stage_by_key[skey] = st
	}

	// Validate depends_on references exist and no self-dependency
	for st in stages {
		for dep in st.depends_on {
			d := strings.trim_space(dep)
			if d == st.key {
				return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s cannot depend on itself", st.key), `{"code":"workflow_cycle"}`)
			}
			if _, ok := stage_by_key[d]; !ok {
				return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s depends_on unknown stage %s", st.key, d), `{"code":"workflow_invalid"}`)
			}
		}
	}

	// Cycle detection (DFS 3-color: 0=unvisited, 1=visiting, 2=visited)
	color := make(map[string]int, len(stages), allocator)
	for st in stages {
		if color[st.key] == 0 {
			if workflow_has_cycle_dfs(st.key, stage_by_key, &color) {
				return {}, false, domain.domain_error(.Validation_Failed, "workflow stage dependency graph contains a cycle", `{"code":"workflow_cycle"}`)
			}
		}
	}

	// Validate for_each paths and reachability in depends_on transitive closure, plus placeholder references
	for st in stages {
		ancestors := make(map[string]bool, len(stages), allocator)
		collect_stage_ancestors(st.key, stage_by_key, &ancestors)
		if input_field, is_input := parse_for_each_input_expr(st.for_each); is_input {
			if input_field == "" {
				return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s has invalid for_each expression: %s (use inputs.<array-input-name>)", st.key, st.for_each), `{"code":"workflow_invalid"}`)
			}
			if verr := validate_for_each_input_declaration(st.key, input_field, inputs_specs); verr.code != .None {
				return {}, false, verr
			}
		} else if st.for_each != "" {
			up_stage, up_field, ok_fe := parse_for_each_expr(st.for_each)
			if !ok_fe || up_stage == "" || up_field == "" {
				return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s has invalid for_each expression: %s", st.key, st.for_each), `{"code":"workflow_invalid"}`)
			}
			if !ancestors[up_stage] {
				return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s for_each references stage %s which is not in its depends_on closure", st.key, up_stage), `{"code":"workflow_invalid"}`)
			}
			up_spec := stage_by_key[up_stage]
			if !brief_has_output_contract(up_spec.brief_raw) {
				return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s for_each references stage %s which has no output contract", st.key, up_stage), `{"code":"workflow_invalid"}`)
			}
		}
		if perr := validate_stage_placeholders(st, ancestors, stage_by_key); perr.code != .None {
			return {}, false, perr
		}
	}

	parsed := Workflow_Parsed_Spec{
		name            = name,
		title           = title,
		description     = desc,
		version         = ver,
		inputs          = inputs_specs,
		defaults_raw    = defaults_raw,
		stages          = stages[:],
		normalized_json = trimmed,
	}
	return parsed, true, domain.Domain_Error{}
}

@(private = "file")
is_valid_stage_key :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 64 do return false
	for i in 0..<len(s) {
		ch := s[i]
		is_lower := ch >= 'a' && ch <= 'z'
		is_upper := ch >= 'A' && ch <= 'Z'
		is_digit := ch >= '0' && ch <= '9'
		if i == 0 && !is_lower && !is_upper do return false
		if !is_lower && !is_upper && !is_digit && ch != '_' && ch != '-' do return false
	}
	return true
}

@(private = "file")
workflow_has_cycle_dfs :: proc(key: string, stage_by_key: map[string]Workflow_Stage_Spec, color: ^map[string]int) -> bool {
	color[key] = 1
	st, ok := stage_by_key[key]
	if ok {
		for dep in st.depends_on {
			d := strings.trim_space(dep)
			c := color[d]
			if c == 1 do return true
			if c == 0 && workflow_has_cycle_dfs(d, stage_by_key, color) do return true
		}
	}
	color[key] = 2
	return false
}

@(private = "file")
collect_stage_ancestors :: proc(key: string, stage_by_key: map[string]Workflow_Stage_Spec, out: ^map[string]bool) {
	st, ok := stage_by_key[key]
	if !ok do return
	for dep in st.depends_on {
		d := strings.trim_space(dep)
		if !out[d] {
			out[d] = true
			collect_stage_ancestors(d, stage_by_key, out)
		}
	}
}

// WORKFLOW_FAN_OUT_MAX_ITEMS bounds one for_each stage (input or stage-output
// source). Expansion creates every item's task in a single transaction, so an
// unbounded array would be an unbounded write. Input fan-out over the cap is
// rejected before the run is created; stage-output fan-out over the cap fails
// the run at expansion (nothing from that stage is created).
WORKFLOW_FAN_OUT_MAX_ITEMS :: 256

// parse_for_each_input_expr recognises workflow-input fan-out:
//   "inputs.<name>" (canonical) or "workflow.input.<name>" (placeholder alias).
// is_input is true whenever the expression uses an input prefix; field is ""
// when the remainder is not a single top-level input name (nested paths are
// not supported), which callers report as an invalid expression.
parse_for_each_input_expr :: proc(expr: string) -> (field: string, is_input: bool) {
	s := strings.trim_space(expr)
	rest := ""
	if strings.has_prefix(s, "inputs.") {
		rest = s[len("inputs."):]
	} else if strings.has_prefix(s, "workflow.input.") {
		rest = s[len("workflow.input."):]
	} else {
		return "", false
	}
	// A stage that happens to be keyed "inputs" keeps its stage-output form.
	if strings.has_prefix(rest, "output.") || strings.has_prefix(rest, "outputs[") do return "", false
	if len(rest) == 0 || len(rest) > 128 do return "", true
	for i in 0..<len(rest) {
		ch := rest[i]
		if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-') do return "", true
	}
	return rest, true
}

// workflow_input_type_is_array reports whether a declared input type names a
// JSON array ("array", "list", "array<object>", "string[]", ...).
@(private = "file")
workflow_input_type_is_array :: proc(type_name: string) -> bool {
	t := strings.to_lower(strings.trim_space(type_name), context.temp_allocator)
	return t == "array" || t == "list" || strings.has_prefix(t, "array<") || strings.has_prefix(t, "list<") || strings.has_suffix(t, "[]")
}

// validate_for_each_input_declaration checks an input fan-out against the
// definition's declared inputs. Undeclared inputs are allowed only when the
// definition declares no inputs at all (the run then validates the value).
@(private = "file")
validate_for_each_input_declaration :: proc(stage_key, field: string, inputs: []Workflow_Input_Spec) -> domain.Domain_Error {
	if len(inputs) == 0 do return domain.Domain_Error{}
	for inp in inputs {
		if inp.name != field do continue
		if inp.type_declared && !workflow_input_type_is_array(inp.type_name) {
			return domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s for_each input %s is declared as type %s; declare it as \"type\": \"array\"", stage_key, field, inp.type_name), `{"code":"workflow_invalid"}`)
		}
		if raw := strings.trim_space(inp.default_raw); raw != "" && raw != "null" && !strings.has_prefix(raw, "[") {
			return domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s for_each input %s has a non-array default", stage_key, field), `{"code":"workflow_invalid"}`)
		}
		return domain.Domain_Error{}
	}
	return domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s for_each references undeclared input %s", stage_key, field), `{"code":"workflow_invalid"}`)
}

// workflow_input_raw_member returns the raw JSON text of a top-level member.
@(private = "file")
workflow_input_raw_member :: proc(members: map[string]string, key: string) -> (string, bool) {
	raw, ok := members[key]
	if !ok do return "", false
	return strings.trim_space(raw), true
}

// resolve_for_each_input_items resolves `for_each: "inputs.<field>"` from the
// execution's immutable input snapshot (falling back to the declared default).
// Items keep array order, so stage indexes are deterministic across
// reconciliation passes and retries. An empty array is valid (zero items).
resolve_for_each_input_items :: proc(stage_key, field: string, inputs_members: map[string]string, inputs: []Workflow_Input_Spec, allocator := context.temp_allocator) -> ([]string, domain.Domain_Error) {
	raw, supplied := workflow_input_raw_member(inputs_members, field)
	if !supplied || raw == "null" {
		raw, supplied = "", false
		for inp in inputs {
			if inp.name == field && strings.trim_space(inp.default_raw) != "" && strings.trim_space(inp.default_raw) != "null" {
				raw, supplied = strings.trim_space(inp.default_raw), true
			}
		}
	}
	if !supplied {
		return nil, domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s for_each needs input %s: supply it as a JSON array (for example --inputs-file with {\"%s\": [...]})", stage_key, field, field), `{"code":"workflow_input_invalid"}`)
	}
	if len(raw) < 2 || raw[0] != '[' || raw[len(raw) - 1] != ']' {
		return nil, domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s for_each input %s must be a JSON array", stage_key, field), `{"code":"workflow_input_invalid"}`)
	}
	items: []string
	if objs, ok := split_json_array_objects(raw, allocator); ok {
		items = objs
	} else {
		items = jsonx_top_level_array_items(raw)
	}
	if err := workflow_check_fan_out_size(stage_key, fmt.tprintf("inputs.%s", field), len(items), true); err.code != .None do return nil, err
	return items, domain.Domain_Error{}
}

// workflow_check_fan_out_size enforces WORKFLOW_FAN_OUT_MAX_ITEMS for both
// fan-out sources. Input arrays report workflow_input_invalid (the caller fixes
// the run inputs); stage outputs report workflow_fan_out_too_large, which fails
// the run at expansion before any of that stage's tasks are created.
workflow_check_fan_out_size :: proc(stage_key, source: string, count: int, from_inputs: bool) -> domain.Domain_Error {
	if count <= WORKFLOW_FAN_OUT_MAX_ITEMS do return domain.Domain_Error{}
	if from_inputs {
		return domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s for_each %s has %d items; at most %d are allowed per fan-out stage (split the list across runs)", stage_key, source, count, WORKFLOW_FAN_OUT_MAX_ITEMS), `{"code":"workflow_input_invalid"}`)
	}
	return domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s for_each %s produced %d items; at most %d are allowed per fan-out stage", stage_key, source, count, WORKFLOW_FAN_OUT_MAX_ITEMS), `{"code":"workflow_fan_out_too_large"}`)
}

// validate_workflow_run_inputs checks every input fan-out before a run is
// created, so a missing or non-array input never dispatches part of a run.
validate_workflow_run_inputs :: proc(parsed: Workflow_Parsed_Spec, inputs_json: string) -> domain.Domain_Error {
	members := jsonx_top_level_members(inputs_json)
	for st in parsed.stages {
		field, is_input := parse_for_each_input_expr(st.for_each)
		if !is_input do continue
		if _, err := resolve_for_each_input_items(st.key, field, members, parsed.inputs); err.code != .None do return err
	}
	return domain.Domain_Error{}
}

// parse_for_each_expr accepts all four path forms:
// 1. "<stage>.outputs[0].<field>"
// 2. "<stage>.outputs[].<field>"
// 3. "stage.<stage>.output.<field>"
// 4. "<stage>.output.<field>"
parse_for_each_expr :: proc(expr: string) -> (stage_key: string, field_path: string, ok: bool) {
	s := strings.trim_space(expr)
	if s == "" do return "", "", false
	if strings.has_prefix(s, "stage.") {
		rest := s[len("stage."):]
		dot := strings.index_byte(rest, '.')
		if dot <= 0 do return "", "", false
		stage_key = rest[:dot]
		after := rest[dot + 1:]
		if strings.has_prefix(after, "output.") {
			return stage_key, after[len("output."):], true
		}
		if strings.has_prefix(after, "outputs[0].") {
			return stage_key, after[len("outputs[0]."):], true
		}
		if strings.has_prefix(after, "outputs[].") {
			return stage_key, after[len("outputs[]."):], true
		}
		return "", "", false
	}
	dot := strings.index_byte(s, '.')
	if dot <= 0 do return "", "", false
	stage_key = s[:dot]
	after := s[dot + 1:]
	if strings.has_prefix(after, "outputs[0].") {
		return stage_key, after[len("outputs[0]."):], true
	}
	if strings.has_prefix(after, "outputs[].") {
		return stage_key, after[len("outputs[]."):], true
	}
	if strings.has_prefix(after, "output.") {
		return stage_key, after[len("output."):], true
	}
	return "", "", false
}

@(private = "file")
validate_stage_placeholders :: proc(st: Workflow_Stage_Spec, ancestors: map[string]bool, stage_by_key: map[string]Workflow_Stage_Spec) -> domain.Domain_Error {
	// Scan raw_json for {{...}} placeholders
	s := st.raw_json
	pos := 0
	for pos < len(s) {
		open_idx := strings.index(s[pos:], "{{")
		if open_idx < 0 do break
		start := pos + open_idx + 2
		close_idx := strings.index(s[start:], "}}")
		if close_idx < 0 do break
		token := strings.trim_space(s[start : start + close_idx])
		pos = start + close_idx + 2

		if token == "item" || strings.has_prefix(token, "item.") {
			if st.for_each == "" {
				return domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s uses {{%s}} without for_each", st.key, token), `{"code":"workflow_invalid"}`)
			}
		} else if strings.has_prefix(token, "stage.") && token != "stage.key" && token != "stage.index" && token != "stage.count" {
			rest := token[len("stage."):]
			dot := strings.index_byte(rest, '.')
			if dot > 0 {
				ref_stage := rest[:dot]
				if _, exists := stage_by_key[ref_stage]; !exists {
					return domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s references unknown stage %s in {{%s}}", st.key, ref_stage, token), `{"code":"workflow_invalid"}`)
				}
				if !ancestors[ref_stage] {
					return domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s references non-ancestor stage %s in {{%s}}", st.key, ref_stage, token), `{"code":"workflow_invalid"}`)
				}
			}
		}
	}
	return domain.Domain_Error{}
}

@(private = "file")
parse_workflow_inputs_spec :: proc(raw_spec: string, allocator := context.temp_allocator) -> []Workflow_Input_Spec {
	out := make([dynamic]Workflow_Input_Spec, allocator)
	if arr, has_arr := jsonx.extract_raw_array(raw_spec, "inputs", true, allocator); has_arr {
		if objs, ok := split_json_array_objects(arr, allocator); ok {
			for obj in objs {
				iname := strings.trim_space(jsonx.extract_string(obj, "name", "", true, allocator))
				if iname == "" do iname = strings.trim_space(jsonx.extract_string(obj, "key", "", true, allocator))
				if iname == "" do continue
				itype := strings.trim_space(jsonx.extract_string(obj, "type", "string", true, allocator))
				req := jsonx.extract_bool(obj, "required", true, true)
				def_val, has_def := jsonx.extract_string_found(obj, "default", true, allocator)
				def_raw, has_def_raw := workflow_input_raw_member(jsonx_top_level_members(obj), "default")
				_, type_declared := jsonx_top_level_members(obj)["type"]
				desc := strings.trim_space(jsonx.extract_string(obj, "description", "", true, allocator))
				append(&out, Workflow_Input_Spec{
					name          = iname,
					type_name     = itype,
					required      = req,
					default_val   = def_val,
					has_default   = has_def || has_def_raw,
					default_raw   = def_raw,
					type_declared = type_declared,
					description   = desc,
				})
			}
		}
		return out[:]
	}
	if obj, has_obj := jsonx.extract_raw_object(raw_spec, "inputs", true, allocator); has_obj {
		for k, v in jsonx_top_level_members(obj) {
			trimmed_v := strings.trim_space(v)
			if strings.has_prefix(trimmed_v, "{") {
				itype := strings.trim_space(jsonx.extract_string(trimmed_v, "type", "string", true, allocator))
				req := jsonx.extract_bool(trimmed_v, "required", true, true)
				def_val, has_def := jsonx.extract_string_found(trimmed_v, "default", true, allocator)
				def_raw, has_def_raw := workflow_input_raw_member(jsonx_top_level_members(trimmed_v), "default")
				_, type_declared := jsonx_top_level_members(trimmed_v)["type"]
				desc := strings.trim_space(jsonx.extract_string(trimmed_v, "description", "", true, allocator))
				append(&out, Workflow_Input_Spec{
					name          = k,
					type_name     = itype,
					required      = req,
					default_val   = def_val,
					has_default   = has_def || has_def_raw,
					default_raw   = def_raw,
					type_declared = type_declared,
					description   = desc,
				})
			} else {
				// Shorthand: {"goal": "string"}
				tstr := strings.trim(trimmed_v, "\"")
				req := !strings.has_suffix(tstr, "?")
				append(&out, Workflow_Input_Spec{
					name          = k,
					type_name     = strings.trim_suffix(tstr, "?"),
					required      = req,
					type_declared = true,
				})
			}
		}
	}
	return out[:]
}

// ---- Output Contracts (`task_list.v1`, `findings.v1`, `inline`) ----------------------

brief_output_schema :: proc(brief_json: string, allocator := context.temp_allocator) -> (schema: string, required_fields: []string, has_output: bool) {
	if obj, ok := jsonx.extract_raw_object(brief_json, "output", true, allocator); ok && strings.trim_space(obj) != "" {
		s := strings.trim_space(jsonx.extract_string(obj, "schema", "", true, allocator))
		if s == "" do s = strings.trim_space(jsonx.extract_string(obj, "kind", "inline", true, allocator))
		req := jsonx.extract_string_array(obj, "required_fields", true, allocator)
		if len(req) == 0 do req = jsonx.extract_string_array(obj, "required", true, allocator)
		return s, req[:], true
	}
	if str := strings.trim_space(jsonx.extract_string(brief_json, "output", "", true, allocator)); str != "" {
		return str, nil, true
	}
	return "", nil, false
}

brief_has_output_contract :: proc(brief_json: string) -> bool {
	_, _, has := brief_output_schema(brief_json)
	return has
}

validate_task_output_contract :: proc(task: domain.Task, output_json: string) -> domain.Domain_Error {
	schema, req_fields, has_output := brief_output_schema(task.brief_json)
	if !has_output do return domain.Domain_Error{}
	trimmed := strings.trim_space(output_json)
	if !strings.has_prefix(trimmed, "{") || !strings.has_suffix(trimmed, "}") {
		return domain.domain_error(.Validation_Failed, "this brief declares an output contract; submit must carry `output`", `{"code":"output_contract_invalid"}`)
	}
	switch schema {
	case "task_list.v1":
		return validate_task_list_v1_json(trimmed)
	case "findings.v1":
		return validate_findings_v1_json(trimmed)
	case:
		for rf in req_fields {
			members := jsonx_top_level_members(trimmed)
			val, exists := members[rf]
			if !exists || strings.trim_space(val) == "" || strings.trim_space(val) == "null" || strings.trim_space(val) == `""` {
				return domain.domain_error(.Validation_Failed, fmt.tprintf("output is missing required field: %s", rf), `{"code":"output_contract_invalid"}`)
			}
		}
	}
	return domain.Domain_Error{}
}

validate_task_list_v1_json :: proc(output_json: string) -> domain.Domain_Error {
	arr_raw, has_tasks := jsonx.extract_raw_array(output_json, "tasks", true, context.temp_allocator)
	if !has_tasks {
		arr_raw, has_tasks = jsonx.extract_raw_array(output_json, "items", true, context.temp_allocator)
	}
	if !has_tasks {
		return domain.domain_error(.Validation_Failed, "task_list.v1 output requires a `tasks` or `items` array", `{"code":"output_contract_invalid"}`)
	}
	objs, ok := split_json_array_objects(arr_raw, context.temp_allocator)
	if !ok {
		return domain.domain_error(.Validation_Failed, "task_list.v1 `tasks` must be a JSON array of objects", `{"code":"output_contract_invalid"}`)
	}
	seen_keys := make(map[string]bool, len(objs), context.temp_allocator)
	for obj, idx in objs {
		key := strings.trim_space(jsonx.extract_string(obj, "key", "", true, context.temp_allocator))
		if key == "" do key = strings.trim_space(jsonx.extract_string(obj, "id", "", true, context.temp_allocator))
		if key != "" {
			if seen_keys[key] {
				return domain.domain_error(.Validation_Failed, fmt.tprintf("task_list.v1 has duplicate item key: %s", key), `{"code":"output_contract_invalid"}`)
			}
			seen_keys[key] = true
		}
		goal := strings.trim_space(jsonx.extract_string(obj, "goal", "", true, context.temp_allocator))
		if goal == "" {
			if bobj, bok := jsonx.extract_raw_object(obj, "brief", true, context.temp_allocator); bok {
				goal = strings.trim_space(jsonx.extract_string(bobj, "goal", "", true, context.temp_allocator))
			}
		}
		if goal == "" {
			return domain.domain_error(.Validation_Failed, fmt.tprintf("task_list.v1 item[%d] is missing non-empty `goal`", idx), `{"code":"output_contract_invalid"}`)
		}

	}
	return domain.Domain_Error{}
}

validate_findings_v1_json :: proc(output_json: string) -> domain.Domain_Error {
	arr_raw, has_arr := jsonx.extract_raw_array(output_json, "findings", true, context.temp_allocator)
	if !has_arr {
		arr_raw, has_arr = jsonx.extract_raw_array(output_json, "items", true, context.temp_allocator)
	}
	if !has_arr {
		return domain.domain_error(.Validation_Failed, "findings.v1 output requires a `findings` or `items` array", `{"code":"output_contract_invalid"}`)
	}
	objs, ok := split_json_array_objects(arr_raw, context.temp_allocator)
	if !ok {
		return domain.domain_error(.Validation_Failed, "findings.v1 `findings` must be a JSON array of objects", `{"code":"output_contract_invalid"}`)
	}
	for obj, idx in objs {
		sev := strings.trim_space(jsonx.extract_string(obj, "severity", "", true, context.temp_allocator))
		valid_sev := false
		switch sev {
		case "critical", "high", "medium", "low", "info", "blocker", "major", "minor", "warn", "nit":
			valid_sev = true
		}
		if !valid_sev {
			return domain.domain_error(.Validation_Failed, fmt.tprintf("findings.v1 item[%d] has invalid severity: %s", idx, sev), `{"code":"output_contract_invalid"}`)
		}
		summary := strings.trim_space(jsonx.extract_string(obj, "summary", "", true, context.temp_allocator))
		if summary == "" do summary = strings.trim_space(jsonx.extract_string(obj, "text", "", true, context.temp_allocator))
		if summary == "" do summary = strings.trim_space(jsonx.extract_string(obj, "message", "", true, context.temp_allocator))
		if summary == "" {
			return domain.domain_error(.Validation_Failed, fmt.tprintf("findings.v1 item[%d] requires non-empty summary", idx), `{"code":"output_contract_invalid"}`)
		}
	}
	return domain.Domain_Error{}
}

// ---- Workflow Snapshot Extraction ---------------------------------------------------

Workflow_Context :: struct {
	using chain: domain.Task_Chain,
	run: domain.Workflow_Run,
	execution: domain.Workflow_Run_Execution,
}

extract_workflow_snapshot :: proc(chain: Workflow_Context, allocator := context.temp_allocator) -> (Workflow_Run_Snapshot, bool) {
	parsed, ok, _ := parse_and_validate_workflow_spec(chain.run.spec_json, "", 0, allocator)
	if !ok do return {}, false
	inputs := chain.execution.resolved_inputs_json
	return Workflow_Run_Snapshot{spec = parsed, inputs_json = inputs, inputs_members = jsonx_top_level_members(inputs), def_id = chain.run.definition_ref}, true
}

workflow_stage_max_parallel :: proc(chain: Workflow_Context, stage_key: string) -> int {
	if chain.run.run_id == "" do return 0
	snap, ok := extract_workflow_snapshot(chain, context.temp_allocator)
	if !ok do return 0
	for st in snap.spec.stages {
		if st.key == stage_key do return st.max_parallel
	}
	return 0
}

workflow_stage_pack_json :: proc(svc: ^Service, chain: domain.Task_Chain, task: domain.Task) -> string {
	o := json_begin()
	json_str(&o, "stage_key", task.stage_key)
	json_int(&o, "stage_index", i64(task.stage_index))
	total := 1
	if tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id); terr.code == .None {
		count := 0
		for t in tasks do if t.workflow_run_id == task.workflow_run_id && t.workflow_execution_no == task.workflow_execution_no && t.stage_key == task.stage_key do count += 1
		if count > 0 do total = count
	}
	json_int(&o, "stage_count", i64(total))
	json_str(&o, "run_id", string(task.workflow_run_id))
	json_int(&o, "execution_no", i64(task.workflow_execution_no))
	if strings.has_prefix(strings.trim_space(task.generated_by_json), "{") && strings.trim_space(task.generated_by_json) != "{}" {
		json_raw(&o, "generated_by", task.generated_by_json)
	}
	return json_end(&o)
}

// ---- Stage Fold (`fold_stage`) & Completeness ---------------------------------------

fold_stage :: proc(svc: ^Service, chain: Workflow_Context, stage_key: string, tasks: []domain.Task, stage_materialised: bool, allocator := context.temp_allocator) -> Stage_View {
	instances := make([dynamic]domain.Task, 0, len(tasks), allocator)
	for t in tasks {
		if t.stage_key == stage_key do append(&instances, t)
	}
	slice.sort_by(instances[:], proc(a, b: domain.Task) -> bool {
		if a.stage_index != b.stage_index do return a.stage_index < b.stage_index
		return a.task_id < b.task_id
	})
	if len(instances) == 0 {
		// Empty fan-out stage is complete ONLY if the materializer explicitly marked it materialised with 0 items
		if stage_materialised {
			return Stage_View{stage_key = stage_key, complete = true, failed = false, outputs = nil}
		}
		return Stage_View{stage_key = stage_key, complete = false, failed = false, outputs = nil}
	}
	all_done := true
	any_failed := false
	for inst in instances {
		if inst.state != .Done {
			all_done = false
		} else {
			merge := task_merge_status(svc, inst)
			if merge.state != "none" && merge.state != "merged" do all_done = false
		}
		if inst.state == .Cancelled {
			any_failed = true
		} else if inst.state == .Backlog && strings.trim_space(inst.blocked_on_json) != "" {
			if strings.contains(inst.blocked_on_json, `"budget_exhausted"`) || strings.contains(inst.blocked_on_json, `"oscillation"`) {
				any_failed = true
			}
		}
	}
	outputs := make([dynamic]string, 0, len(instances), allocator)
	if all_done && svc != nil && svc.repo != nil {
		for inst in instances {
			out_body := "{}"
			if facets, ferr := iface.taskchain_list_facets_by_task(svc.repo, inst.task_id, inst.owner_user_id); ferr.code == .None {
				best_att := -1
				for f in facets {
					if f.kind == FACET_OUTPUT && f.attempt_no >= best_att {
						best_att = f.attempt_no
						out_body = f.body_json
					}
				}
			}
			append(&outputs, out_body)
		}
	}
	return Stage_View{
		stage_key = stage_key,
		complete  = all_done,
		failed    = any_failed,
		outputs   = outputs[:],
	}
}

is_stage_marked_empty_done :: proc(svc: ^Service, chain: Workflow_Context, stage_key: string) -> bool {
	stages, err := iface.taskchain_list_workflow_stage_executions(svc.repo, chain.run.run_id, chain.execution.execution_no, chain.owner_user_id)
	if err.code != .None do return false
	for stage in stages do if stage.stage_key == stage_key do return stage.item_count == 0
	return false
}

workflow_all_stages_complete :: proc(svc: ^Service, chain: Workflow_Context, tasks: []domain.Task) -> bool {
	snap, ok := extract_workflow_snapshot(chain, context.temp_allocator)
	if !ok do return true
	for st in snap.spec.stages {
		sv := fold_stage(svc, chain, st.key, tasks, is_stage_marked_empty_done(svc, chain, st.key), context.temp_allocator)
		if !sv.complete do return false
	}
	return true
}

// ---- Workflow Materializer (`materialize_ready_stages_in_uow`) ----------------------

materialize_ready_stages_in_uow :: proc(svc: ^Service, u: ^Uow, chain_in: Workflow_Context) -> (changed_any: bool, ok: bool, err: domain.Domain_Error) {
	chain := chain_in
	if chain.execution.state != domain.WORKFLOW_EXECUTION_RUNNING || chain.publish_state != .Published || chain.status != .Active {
		return false, true, domain.Domain_Error{}
	}
	snap, sok := extract_workflow_snapshot(chain, context.temp_allocator)
	if !sok do return false, true, domain.Domain_Error{}

	// Loop so 0-item fan-out stages can immediately unblock their downstream stages in the same UoW
	for pass := 0; pass < len(snap.spec.stages) + 1; pass += 1 {
		pass_changed := false
		tasks, terr := workflow_execution_tasks(svc, chain)
		if terr.code != .None do return changed_any, false, terr

		stage_views := make(map[string]Stage_View, len(snap.spec.stages), context.temp_allocator)
		for st in snap.spec.stages {
			stage_views[st.key] = fold_stage(svc, chain, st.key, tasks, is_stage_marked_empty_done(svc, chain, st.key), context.temp_allocator)
		}

		for st in snap.spec.stages {
			// Check if all depends_on stages are COMPLETE
			deps_complete := true
			for dep_key in st.depends_on {
				dv, exists := stage_views[strings.trim_space(dep_key)]
				if !exists || !dv.complete {
					deps_complete = false
					break
				}
			}
			if !deps_complete do continue

			// Check if this stage already has materialised rows or is marked empty_done
			has_rows := false
			for t in tasks {
				if t.stage_key == st.key {
					has_rows = true
					break
				}
			}
			if has_rows || is_stage_marked_empty_done(svc, chain, st.key) do continue

			// Ready to materialise stage `st`!
			mat_ok, mat_err := materialize_single_stage_in_uow(svc, u, &chain, snap, st, tasks, stage_views)
			if !mat_ok do return changed_any, false, mat_err
			changed_any = true
			pass_changed = true
		}
		if !pass_changed do break
	}
	return changed_any, true, domain.Domain_Error{}
}

@(private = "file")
materialize_single_stage_in_uow :: proc(
	svc: ^Service,
	u: ^Uow,
	chain: ^Workflow_Context,
	snap: Workflow_Run_Snapshot,
	st: Workflow_Stage_Spec,
	existing_tasks: []domain.Task,
	stage_views: map[string]Stage_View,
) -> (bool, domain.Domain_Error) {
	items_raw := make([dynamic]string, context.temp_allocator)
	source_task_id := ""
	input_field, input_fan_out := parse_for_each_input_expr(st.for_each)
	if input_fan_out {
		items, ierr := resolve_for_each_input_items(st.key, input_field, snap.inputs_members, snap.spec.inputs)
		if ierr.code != .None do return false, ierr
		for it in items do append(&items_raw, it)
		if len(items_raw) == 0 {
			_, ok, err := iface.taskchain_insert_workflow_stage_execution(svc.repo, domain.Workflow_Stage_Execution{
				run_id = chain.run.run_id, execution_no = chain.execution.execution_no, stage_key = st.key,
				chain_id = chain.chain_id, owner_user_id = chain.owner_user_id, item_count = 0, expanded_at = platform.clock_now(svc.clock),
			})
			if ok do effect_publish_workflow_stage(u, chain.chain_id, chain.owner_user_id, chain.run.run_id, st.key)
			return ok, err
		}
	} else if st.for_each != "" {
		up_stage, up_field, ok_fe := parse_for_each_expr(st.for_each)
		if !ok_fe do return false, domain.domain_error(.Validation_Failed, "invalid for_each expression")
		up_view := stage_views[up_stage]
		for t in existing_tasks {
			if t.stage_key == up_stage && t.stage_index == 0 {
				source_task_id = string(t.task_id)
				break
			}
		}
		if strings.contains(st.for_each, "outputs[]") {
			for out_json in up_view.outputs {
				arr := extract_for_each_array_items(out_json, up_field, context.temp_allocator)
				for it in arr do append(&items_raw, it)
			}
		} else if len(up_view.outputs) > 0 {
			arr := extract_for_each_array_items(up_view.outputs[0], up_field, context.temp_allocator)
			for it in arr do append(&items_raw, it)
		}
		if len(items_raw) == 0 {
			_, ok, err := iface.taskchain_insert_workflow_stage_execution(svc.repo, domain.Workflow_Stage_Execution{
				run_id = chain.run.run_id, execution_no = chain.execution.execution_no, stage_key = st.key,
				chain_id = chain.chain_id, owner_user_id = chain.owner_user_id, item_count = 0, expanded_at = platform.clock_now(svc.clock),
			})
			if ok do effect_publish_workflow_stage(u, chain.chain_id, chain.owner_user_id, chain.run.run_id, st.key)
			return ok, err
		}
		if err := workflow_check_fan_out_size(st.key, st.for_each, len(items_raw), false); err.code != .None do return false, err
	} else {
		count_n := st.parallel if st.parallel > 1 else 1
		for _ in 0..<count_n do append(&items_raw, "{}")
	}

	total_count := len(items_raw)
	now := platform.clock_now(svc.clock)

	// Collect all upstream tasks from depends_on stages (and transitively if a depends_on stage was empty)
	upstream_task_ids := collect_upstream_stage_task_ids(st.depends_on, existing_tasks, snap.spec.stages, context.temp_allocator)

	// Idempotency: (chain_id, stage_key, stage_index) is created at most once.
	existing_indexes := make(map[int]bool, 8, context.temp_allocator)
	for t in existing_tasks do if t.stage_key == st.key do existing_indexes[t.stage_index] = true

	for item_json, idx in items_raw {
		if existing_indexes[idx] do continue
		// Field lookups (priority, key/id) apply to object items only.
		item_is_object := strings.has_prefix(strings.trim_space(item_json), "{")

		title_sub := substitute_workflow_placeholders(st.title, snap, st.key, idx, total_count, item_json, stage_views, false, context.temp_allocator)
		desc_sub := substitute_workflow_placeholders(st.description, snap, st.key, idx, total_count, item_json, stage_views, false, context.temp_allocator)

		brief_json := "{}"
		if st.kind == .Gate {
			gb := json_begin()
			prompt_sub := substitute_workflow_placeholders(st.prompt if st.prompt != "" else st.title, snap, st.key, idx, total_count, item_json, stage_views, false, context.temp_allocator)
			json_str(&gb, "goal", prompt_sub)
			json_str(&gb, "approver", st.approver if st.approver != "" else "user_or_coordinator")
			json_str(&gb, "prompt", prompt_sub)
			gate_inner := json_begin()
			json_str(&gate_inner, "approver", st.approver if st.approver != "" else "user_or_coordinator")
			json_str(&gate_inner, "prompt", prompt_sub)
			json_raw(&gb, "gate", json_end(&gate_inner))
			brief_json = json_end(&gb)
		} else {
			brief_json = substitute_workflow_placeholders(st.brief_raw, snap, st.key, idx, total_count, item_json, stage_views, true, context.temp_allocator)
		}

        if st.kind != .Gate {
            if err := workflow_validate_fleet(svc, chain.chain, brief_json); err.code != .None do return false, err
        }

		prio_str := st.priority
		if prio_str == "" do prio_str = jsonx.extract_string(snap.spec.defaults_raw, "priority", "p2", true, context.temp_allocator)
		if st.for_each != "" && item_is_object {
			if item_prio := jsonx.extract_string(item_json, "priority", "", true, context.temp_allocator); item_prio != "" {
				prio_str = item_prio
			}
		}

		gen_by := "{}"
		if st.for_each != "" {
			g := json_begin()
			if input_fan_out {
				json_str(&g, "input", input_field)
			} else {
				up_stage, _, _ := parse_for_each_expr(st.for_each)
				json_str(&g, "stage", up_stage)
			}
			if source_task_id != "" do json_str(&g, "source_task_id", source_task_id)
			item_key := ""
			if item_is_object {
				item_key = jsonx.extract_string(item_json, "key", "", true, context.temp_allocator)
				if item_key == "" do item_key = jsonx.extract_string(item_json, "id", "", true, context.temp_allocator)
			}
			if item_key == "" do item_key = fmt.tprintf("item_%d", idx)
			json_str(&g, "item_key", item_key)
			json_int(&g, "item_index", i64(idx))
			// Object and scalar items are both kept verbatim (raw JSON).
			json_raw(&g, "item", item_json if strings.trim_space(item_json) != "" else "{}")
			gen_by = json_end(&g)
		} else {
			g := json_begin()
			json_str(&g, "stage", st.key)
			gen_by = json_end(&g)
		}

		req_user := solo_default_user_approval(svc, chain.chain, st.has_requires_user_approval, st.requires_user_approval)
		if st.kind == .Gate && st.approver == "user" do req_user = true

		tid := domain.Task_ID(platform.generate_id(svc.ids, "task_"))
		task := domain.Task{
			task_id                = tid,
			chain_id               = chain.chain_id,
			owner_user_id          = chain.owner_user_id,
			title                  = title_sub,
			description            = desc_sub,
			publish_state          = .Published,
			state                  = .In_Review if st.kind == .Gate else .Backlog,
			kind                   = st.kind,
			priority               = domain.task_priority_from_string(prio_str),
			attempt_no             = 0,
			brief_json             = brief_json,
			blocked_on_json        = "",
			requires_user_approval = req_user,
			ready_since            = "",
			workflow_run_id        = chain.run.run_id,
			workflow_execution_no  = chain.execution.execution_no,
			stage_key              = st.key,
			stage_index            = idx,
			generated_by_json      = gen_by,
			created_at             = now,
			updated_at             = now,
			published_at           = now,
		}
		saved_t, tok, terr := iface.taskchain_save_task(svc.repo, task)
		if !tok do return false, terr

		for up_tid in upstream_task_ids {
			if _, saved, err := iface.taskchain_save_dependency(svc.repo, domain.Task_Dependency{
				task_id            = saved_t.task_id,
				depends_on_task_id = up_tid,
				chain_id           = chain.chain_id,
				owner_user_id      = chain.owner_user_id,
				created_at         = now,
			}); !saved do return false, err
		}

		cp := json_begin()
		json_raw(&cp, "brief", saved_t.brief_json)
		json_str(&cp, "stage_key", st.key)
		json_int(&cp, "stage_index", i64(idx))
		if _, saved, err := append_event(svc.repo, svc.clock, saved_t, hub_actor(), EV_CREATED, json_end(&cp)); !saved do return false, err
		if _, saved, err := append_event(svc.repo, svc.clock, saved_t, hub_actor(), EV_PUBLISHED, "{}"); !saved do return false, err
		if st.kind == .Gate {
			sp := json_begin()
			json_bool(&sp, "gate", true)
			if _, saved, err := append_event(svc.repo, svc.clock, saved_t, hub_actor(), EV_SUBMITTED, json_end(&sp)); !saved do return false, err
			effect_notify_coordinator(svc, u, chain.chain_id, chain.owner_user_id, "review_requested_from_user", fmt.tprintf("[taskv2] gate %s (%s) is awaiting approval in workflow run %s", saved_t.task_id, saved_t.title, chain.run.run_id))
		}
		if u != nil do effect_publish_task(u, saved_t, "created")
	}
	_, expanded, expansion_err := iface.taskchain_insert_workflow_stage_execution(svc.repo, domain.Workflow_Stage_Execution{
		run_id = chain.run.run_id, execution_no = chain.execution.execution_no, stage_key = st.key,
		chain_id = chain.chain_id, owner_user_id = chain.owner_user_id, item_count = total_count, expanded_at = now,
	})
	if expanded do effect_publish_workflow_stage(u, chain.chain_id, chain.owner_user_id, chain.run.run_id, st.key)
	return expanded, expansion_err
}

json_values_equal :: proc(v1, v2: json.Value) -> bool {
	#partial switch a in v1 {
	case json.Null:
		_, is_null := v2.(json.Null)
		return is_null
	case json.Boolean:
		b, is_b := v2.(json.Boolean)
		return is_b && bool(a) == bool(b)
	case json.Integer:
		b, is_b := v2.(json.Integer)
		if is_b do return i64(a) == i64(b)
		f, is_f := v2.(json.Float)
		return is_f && f64(a) == f64(f)
	case json.Float:
		b, is_b := v2.(json.Float)
		if is_b do return f64(a) == f64(b)
		i, is_i := v2.(json.Integer)
		return is_i && f64(a) == f64(i)
	case json.String:
		b, is_b := v2.(json.String)
		return is_b && string(a) == string(b)
	case json.Array:
		b, is_b := v2.(json.Array)
		if !is_b || len(a) != len(b) do return false
		for it, idx in a {
			if !json_values_equal(it, b[idx]) do return false
		}
		return true
	case json.Object:
		b, is_b := v2.(json.Object)
		if !is_b || len(a) != len(b) do return false
		for k, v in a {
			b_val, has_k := b[k]
			if !has_k || !json_values_equal(v, b_val) do return false
		}
		return true
	}
	return false
}

@(private = "file")
json_strings_equal :: proc(s1, s2: string, allocator := context.temp_allocator) -> bool {
	t1 := strings.trim_space(s1)
	t2 := strings.trim_space(s2)
	if t1 == t2 do return true
	v1, err1 := json.parse(transmute([]u8)t1, allocator = allocator)
	if err1 != .None do return false
	v2, err2 := json.parse(transmute([]u8)t2, allocator = allocator)
	if err2 != .None do return false
	return json_values_equal(v1, v2)
}

@(private = "file")
collect_upstream_stage_task_ids :: proc(
	dep_stage_keys: []string,
	existing_tasks: []domain.Task,
	all_stages: []Workflow_Stage_Spec,
	allocator := context.temp_allocator,
) -> []domain.Task_ID {
	out := make([dynamic]domain.Task_ID, allocator)
	seen := make(map[domain.Task_ID]bool, allocator)
	visited_stages := make(map[string]bool, allocator)
	queue := make([dynamic]string, allocator)
	for k in dep_stage_keys do append(&queue, strings.trim_space(k))

	for len(queue) > 0 {
		sk := queue[0]
		ordered_remove(&queue, 0)
		if visited_stages[sk] do continue
		visited_stages[sk] = true
		found_in_stage := false
		for t in existing_tasks {
			if t.stage_key == sk {
				found_in_stage = true
				if !seen[t.task_id] {
					seen[t.task_id] = true
					append(&out, t.task_id)
				}
			}
		}
		// If the stage was a 0-item fan-out stage, wire dependencies to its upstream stages
		if !found_in_stage {
			for st in all_stages {
				if st.key == sk {
					for dk in st.depends_on do append(&queue, strings.trim_space(dk))
				}
			}
		}
	}
	return out[:]
}

// A workflow shares the chain fleet. It must never create or widen fleet rows.
workflow_validate_fleet :: proc(svc: ^Service, chain: domain.Task_Chain, brief: string) -> domain.Domain_Error {
 fleets, err := iface.taskchain_list_fleets_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
 if err.code != .None do return err
 if solo, implicit := implicit_solo_worker(svc, chain, fleets); implicit {
  copy := make([dynamic]domain.Task_Chain_Fleet, context.temp_allocator)
  append(&copy, ..fleets); append(&copy, solo); fleets = copy[:]
 }
 assignee := brief_assignee(brief)
 worker := false
 coordinator := chain_coordinator_agent_id(svc, chain)
 for fleet in fleets {
  if fleet.capacity <= 0 || !fleet_row_has_role(fleet, domain.FLEET_ROLE_WORKER) do continue
  if fleet.agent_id == coordinator && !chain_is_solo(svc, chain) do continue
  if assignee == "" || strings.contains(assignee, "{{") || fleet.agent_id == assignee do worker = true
 }
 if !worker do return domain.domain_error(.Validation_Failed, "configure an eligible worker fleet row with positive capacity before starting the run")
 for reviewer in brief_named_reviewers(brief, context.temp_allocator) {
  if strings.contains(reviewer, "{{") do continue
  covered := false
  for fleet in fleets do if fleet.agent_id == reviewer && fleet.agent_id != coordinator && fleet.capacity > 0 do covered = true
  if !covered do return domain.domain_error(.Validation_Failed, fmt.tprintf("configure eligible fleet row for named workflow reviewer %s before starting the run", reviewer))
 }
 if assignee != "" && !strings.contains(assignee, "{{") {
  covered := false
  for fleet in fleets do if fleet.agent_id == assignee && fleet_row_has_role(fleet, domain.FLEET_ROLE_WORKER) do covered = true
  if !covered do return domain.domain_error(.Validation_Failed, fmt.tprintf("configure worker fleet row for workflow assignee %s before starting the run", assignee))
 }
 for role in brief_review_roles(brief, context.temp_allocator) {
  if strings.contains(role, "{{") do continue
  covered := false
  for fleet in fleets do if fleet.agent_id != coordinator && fleet.capacity > 0 && fleet_row_has_role(fleet, role) do covered = true
  if !covered do return domain.domain_error(.Validation_Failed, fmt.tprintf("configure fleet review role %s before starting the run", role))
 }
 return domain.Domain_Error{}
}

@(private = "file")
extract_for_each_array_items :: proc(output_json: string, field_path: string, allocator := context.temp_allocator) -> []string {
	arr_raw, ok := jsonx.extract_raw_array(output_json, field_path, true, allocator)
	if !ok {
		if field_path == "tasks" {
			arr_raw, ok = jsonx.extract_raw_array(output_json, "items", true, allocator)
		} else if field_path == "items" {
			arr_raw, ok = jsonx.extract_raw_array(output_json, "tasks", true, allocator)
			if !ok {
				arr_raw, ok = jsonx.extract_raw_array(output_json, "findings", true, allocator)
			}
		} else if field_path == "findings" {
			arr_raw, ok = jsonx.extract_raw_array(output_json, "items", true, allocator)
		}
	}
	if !ok || strings.trim_space(arr_raw) == "" do return nil
	if objs, ok_objs := split_json_array_objects(arr_raw, allocator); ok_objs {
		return objs
	}
	return jsonx_top_level_array_items(arr_raw)
}

// substitute_workflow_placeholders replaces:
// - {{inputs.<k>}} and {{workflow.input.<k>}}
// - {{stage.key}}, {{stage.index}}, {{stage.count}}
// - {{stage.<k>.output.<field>}} and {{stage.<k>.output.items.length}}
// - {{item.<field>}} and {{item}}
substitute_workflow_placeholders :: proc(
	template: string,
	snap: Workflow_Run_Snapshot,
	stage_key: string,
	stage_index: int,
	stage_count: int,
	item_json: string,
	stage_views: map[string]Stage_View,
	escape_for_json: bool,
	allocator := context.temp_allocator,
) -> string {
	if !strings.contains(template, "{{") do return template
	b := strings.builder_make(allocator)
	s := template
	pos := 0
	for pos < len(s) {
		open_idx := strings.index(s[pos:], "{{")
		if open_idx < 0 {
			strings.write_string(&b, s[pos:])
			break
		}
		strings.write_string(&b, s[pos : pos + open_idx])
		start := pos + open_idx + 2
		close_idx := strings.index(s[start:], "}}")
		if close_idx < 0 {
			strings.write_string(&b, s[pos + open_idx:])
			break
		}
		token := strings.trim_space(s[start : start + close_idx])
		pos = start + close_idx + 2

		val := resolve_placeholder_token(token, snap, stage_key, stage_index, stage_count, item_json, stage_views, allocator)
		if escape_for_json {
			contracts.write_json_string(&b, val)
		} else {
			strings.write_string(&b, val)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
resolve_placeholder_token :: proc(
	token: string,
	snap: Workflow_Run_Snapshot,
	stage_key: string,
	stage_index: int,
	stage_count: int,
	item_json: string,
	stage_views: map[string]Stage_View,
	allocator := context.temp_allocator,
) -> string {
	if token == "stage.key" do return stage_key
	if token == "stage.index" do return fmt.tprintf("%d", stage_index)
	if token == "stage.count" do return fmt.tprintf("%d", stage_count)
	if token == "item" {
		t := strings.trim_space(item_json)
		if strings.has_prefix(t, `"`) {
			// A string item renders as its decoded text, not escaped JSON.
			if value, perr := json.parse(transmute([]u8)t, parse_integers = true, allocator = allocator); perr == nil {
				if s, is_str := value.(json.String); is_str do return string(s)
			}
		}
		return t
	}
	if strings.has_prefix(token, "item.") {
		field := token[len("item."):]
		// Scalar items have no fields; only {{item.key}} keeps its index fallback.
		if !strings.has_prefix(strings.trim_space(item_json), "{") {
			return fmt.tprintf("item_%d", stage_index) if field == "key" else ""
		}
		if v, ok := extract_scalar_or_raw_string(item_json, field, allocator); ok && v != "" do return v
		// Fallbacks between title/goal/summary/key
		if field == "title" {
			if v, ok := extract_scalar_or_raw_string(item_json, "goal", allocator); ok && v != "" do return v
			if v, ok := extract_scalar_or_raw_string(item_json, "summary", allocator); ok && v != "" do return v
			if v, ok := extract_scalar_or_raw_string(item_json, "key", allocator); ok && v != "" do return v
		} else if field == "key" {
			if v, ok := extract_scalar_or_raw_string(item_json, "id", allocator); ok && v != "" do return v
			return fmt.tprintf("item_%d", stage_index)
		}
		return ""
	}
	if strings.has_prefix(token, "inputs.") {
		k := token[len("inputs."):]
		return resolve_workflow_input_value(snap, k, allocator)
	}
	if strings.has_prefix(token, "workflow.input.") {
		k := token[len("workflow.input."):]
		return resolve_workflow_input_value(snap, k, allocator)
	}
	if strings.has_prefix(token, "stage.") {
		rest := token[len("stage."):]
		dot := strings.index_byte(rest, '.')
		if dot > 0 {
			up_key := rest[:dot]
			after := rest[dot + 1:]
			sv, exists := stage_views[up_key]
			if !exists || len(sv.outputs) == 0 do return ""
			out0 := sv.outputs[0]
			field := ""
			if strings.has_prefix(after, "output.") {
				field = after[len("output."):]
			} else if strings.has_prefix(after, "outputs[0].") {
				field = after[len("outputs[0]."):]
			}
			if field == "items.length" || field == "tasks.length" || field == "findings.length" {
				arr := extract_for_each_array_items(out0, strings.split(field, ".", allocator)[0], allocator)
				return fmt.tprintf("%d", len(arr))
			}
			if field != "" {
				if v, ok := extract_scalar_or_raw_string(out0, field, allocator); ok do return v
			}
		}
	}
	return ""
}

@(private = "file")
resolve_workflow_input_value :: proc(snap: Workflow_Run_Snapshot, key: string, allocator := context.temp_allocator) -> string {
	// A supplied null falls back to the declared default, as fan-out does.
	supplied, found := scalar_or_raw_member(snap.inputs_members, key, allocator)
	if found && supplied != "null" do return supplied
	for inp in snap.spec.inputs {
		if inp.name != key || !inp.has_default do continue
		// Non-string defaults (arrays, objects, numbers) render as raw JSON.
		raw := strings.trim_space(inp.default_raw)
		if raw != "" && raw != "null" && !strings.has_prefix(raw, `"`) do return raw
		return inp.default_val
	}
	return supplied
}

@(private = "package")
extract_scalar_or_raw_string :: proc(obj_json: string, key: string, allocator := context.temp_allocator) -> (string, bool) {
	return scalar_or_raw_member(jsonx_top_level_members(obj_json), key, allocator)
}

// scalar_or_raw_member renders one top-level member the way placeholders want
// it: strings decoded, numbers and booleans as their text, objects/arrays (and
// null) as raw trimmed JSON. Only the member's own text is parsed, never the
// whole object, so a lookup costs O(member) instead of O(object).
@(private = "package")
scalar_or_raw_member :: proc(members: map[string]string, key: string, allocator := context.temp_allocator) -> (string, bool) {
	raw, ok := members[key]
	if !ok do return "", false
	raw = strings.trim_space(raw)
	if raw == "" || raw[0] == '{' || raw[0] == '[' do return raw, true
	// Scalars are small: parse just this value with the same decoder the
	// whole-object path used, so formatting (e.g. floats as %f) is unchanged.
	value, err := json.parse(transmute([]u8)raw, parse_integers = true, allocator = allocator)
	if err != nil do return raw, true
	#partial switch v in value {
	case json.String:  return string(v), true
	case json.Integer: return fmt.tprintf("%d", v), true
	case json.Float:   return fmt.tprintf("%f", v), true
	case json.Boolean: return "true" if v else "false", true
	}
	return raw, true
}

// ---- Workflow Service Entry Points (Templates, Define, List, Run, Status, Output, Retry, Cancel) ----

workflow_list_definitions :: proc(svc: ^Service, owner_user_id: domain.User_ID) -> ([]domain.Workflow_Definition, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return nil, domain.domain_error(.Internal_Error, "service not configured")
	return iface.taskchain_list_workflow_definitions_by_owner(svc.repo, owner_user_id)
}

workflow_define :: proc(
	svc: ^Service,
	owner_user_id: domain.User_ID,
	spec_json: string,
	name_override := "",
	version_override := 0,
) -> (domain.Workflow_Definition, bool, domain.Domain_Error) {
	if svc == nil || svc.repo == nil do return {}, false, domain.domain_error(.Internal_Error, "service not configured")
	parsed, ok, verr := parse_and_validate_workflow_spec(spec_json, name_override, version_override, context.temp_allocator)
	if !ok do return {}, false, verr
	if parsed.name == "" {
		return {}, false, domain.domain_error(.Validation_Failed, "workflow name is required", `{"code":"workflow_invalid"}`)
	}
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr

	existing, _ := iface.taskchain_list_workflow_definitions_by_owner(svc.repo, owner_user_id)
	ver := parsed.version
	if version_override <= 0 {
		max_v := 0
		for d in existing {
			if d.name == parsed.name && d.version > max_v do max_v = d.version
		}
		if max_v > 0 && ver <= max_v do ver = max_v + 1
	}
	now := platform.clock_now(svc.clock)
	def := domain.Workflow_Definition{
		def_id        = platform.generate_id(svc.ids, "wfd_"),
		owner_user_id = owner_user_id,
		name          = parsed.name,
		version       = ver,
		body_json     = parsed.normalized_json,
		created_at    = now,
	}
	saved, sok, serr := iface.taskchain_save_workflow_definition(svc.repo, def)
	_, cerr := end_uow(svc, &u, sok)
	if !sok do return {}, false, serr
	if cerr.code != .None do return {}, false, cerr
	return saved, true, domain.Domain_Error{}
}

resolve_workflow_ref :: proc(svc: ^Service, owner_user_id: domain.User_ID, ref: string, allocator := context.temp_allocator) -> (def_ref: string, spec_json: string, ok: bool) {
	// 1. Check user definitions by def_id or name (latest version wins)
	if defs, derr := iface.taskchain_list_workflow_definitions_by_owner(svc.repo, owner_user_id); derr.code == .None {
		best := domain.Workflow_Definition{}
		found_name := false
		for d in defs {
			if d.def_id == ref do return d.def_id, d.body_json, true
			if d.name == ref {
				if !found_name || d.version > best.version {
					best = d
					found_name = true
				}
			}
		}
		if found_name do return best.def_id, best.body_json, true
	}
	// 2. Check built-in templates by id or name
	for tpl in workflow_builtin_templates(allocator) {
		if tpl.id == ref || tpl.name == ref || fmt.tprintf("builtin:%s", tpl.name) == ref {
			return tpl.name, tpl.spec_json, true
		}
	}
	return "", "", false
}

@(private = "file")
chain_status_str :: proc(st: domain.Task_Chain_Status) -> string {
	switch st {
	case .Active:    return "active"
	case .Completed: return "completed"
	case .Cancelled: return "cancelled"
	case .Archived:  return "archived"
	}
	return "active"
}

// ---- Workflow Status & Output -------------------------------------------------------

workflow_status_json_for_chain :: proc(svc: ^Service, chain: Workflow_Context, allocator := context.temp_allocator) -> (string, bool, domain.Domain_Error) {
	if chain.run.run_id == "" {
		return "", false, domain.domain_error(.Validation_Failed, "workflow run is required")
	}
	snap, sok := extract_workflow_snapshot(chain, allocator)
	if !sok {
		return "", false, domain.domain_error(.Validation_Failed, "workflow run has no valid snapshot")
	}
	tasks, terr := workflow_execution_tasks(svc, chain)
	if terr.code != .None do return "", false, terr

	o := json_begin(allocator)
	json_str(&o, "chain_id", string(chain.chain_id))
	json_str(&o, "title", chain.run.title)
	json_str(&o, "run_id", string(chain.run.run_id))
	json_int(&o, "execution_no", i64(chain.execution.execution_no))
	json_int(&o, "revision", chain.run.revision)
	json_str(&o, "status", chain.execution.state)
	json_str(&o, "definition_ref", chain.run.definition_ref)
	json_int(&o, "current_execution_no", i64(chain.run.current_execution_no))
	json_int(&o, "execution_revision", chain.execution.revision)
	json_str(&o, "failure_code", chain.execution.failure_code)
	json_str(&o, "failure_detail", chain.execution.failure_detail)
	json_str(&o, "started_at", chain.execution.started_at)
	json_str(&o, "ended_at", chain.execution.ended_at)
	json_raw(&o, "output_manifest", chain.execution.output_manifest_json)
	json_str(&o, "workflow_name", snap.spec.name)
	json_raw(&o, "inputs", snap.inputs_json)

	sb := strings.builder_make(allocator)
	strings.write_byte(&sb, '[')
	for st, sidx in snap.spec.stages {
		if sidx > 0 do strings.write_byte(&sb, ',')
		sv := fold_stage(svc, chain, st.key, tasks, is_stage_marked_empty_done(svc, chain, st.key), allocator)
		so := json_begin(allocator)
		json_str(&so, "key", st.key)
		json_str(&so, "kind", domain.task_kind_string(st.kind))
		json_str(&so, "title", st.title)
		json_bool(&so, "complete", sv.complete)
		json_bool(&so, "failed", sv.failed)

		stage_tasks := make([dynamic]domain.Task, 0, len(tasks), allocator)
		for t in tasks do if t.stage_key == st.key do append(&stage_tasks, t)
		slice.sort_by(stage_tasks[:], proc(a, b: domain.Task) -> bool {
			return a.stage_index < b.stage_index
		})
		state_label := "pending"
		if sv.complete {
			state_label = "done"
		} else if sv.failed {
			state_label = "failed"
		} else if len(stage_tasks) > 0 {
			any_in_prog := false
			any_in_rev := false
			for t in stage_tasks {
				if t.state == .In_Progress do any_in_prog = true
				if t.state == .In_Review do any_in_rev = true
			}
			if st.kind == .Gate && any_in_rev {
				state_label = "waiting_approval"
			} else if any_in_prog {
				state_label = "in_progress"
			} else if any_in_rev {
				state_label = "in_review"
			} else {
				state_label = "ready"
			}
		}
		json_str(&so, "state", state_label)
		json_int(&so, "instance_count", i64(len(stage_tasks)))

		tb := strings.builder_make(allocator)
		strings.write_byte(&tb, '[')
		for t, tidx in stage_tasks {
			if tidx > 0 do strings.write_byte(&tb, ',')
			to := json_begin(allocator)
			json_str(&to, "task_id", string(t.task_id))
			json_str(&to, "title", t.title)
			json_str(&to, "state", domain.task_state_string(t.state))
			json_int(&to, "stage_index", i64(t.stage_index))
			json_int(&to, "attempt_no", i64(t.attempt_no))
			strings.write_string(&tb, json_end(&to))
		}
		strings.write_byte(&tb, ']')
		json_raw(&so, "tasks", strings.to_string(tb))

		ob := strings.builder_make(allocator)
		strings.write_byte(&ob, '[')
		for out_item, oidx in sv.outputs {
			if oidx > 0 do strings.write_byte(&ob, ',')
			strings.write_string(&ob, out_item if strings.trim_space(out_item) != "" else "{}")
		}
		strings.write_byte(&ob, ']')
		json_raw(&so, "outputs", strings.to_string(ob))
		strings.write_string(&sb, json_end(&so))
	}
	strings.write_byte(&sb, ']')
	json_raw(&o, "stages", strings.to_string(sb))
	return json_end(&o), true, domain.Domain_Error{}
}

workflow_stage_output_json_for_chain :: proc(svc: ^Service, chain: Workflow_Context, stage_key: string, allocator := context.temp_allocator) -> (string, bool, domain.Domain_Error) {
	if chain.run.run_id == "" {
		return "", false, domain.domain_error(.Validation_Failed, "workflow run is required")
	}
	snap, sok := extract_workflow_snapshot(chain, allocator)
	if !sok do return "", false, domain.domain_error(.Validation_Failed, "workflow run has no valid snapshot")
	found_stage := false
	for st in snap.spec.stages do if st.key == stage_key { found_stage = true; break }
	if !found_stage {
		return "", false, domain.domain_error(.Not_Found, fmt.tprintf("stage not found in workflow: %s", stage_key))
	}
	tasks, terr := workflow_execution_tasks(svc, chain)
	if terr.code != .None do return "", false, terr
	sv := fold_stage(svc, chain, stage_key, tasks, is_stage_marked_empty_done(svc, chain, stage_key), allocator)

	o := json_begin(allocator)
	json_str(&o, "chain_id", string(chain.chain_id))
	json_str(&o, "run_id", string(chain.run.run_id))
	json_int(&o, "execution_no", i64(chain.execution.execution_no))
	json_str(&o, "stage_key", stage_key)
	json_bool(&o, "complete", sv.complete)
	json_bool(&o, "failed", sv.failed)
	ob := strings.builder_make(allocator)
	strings.write_byte(&ob, '[')
	for out_item, oidx in sv.outputs {
		if oidx > 0 do strings.write_byte(&ob, ',')
		strings.write_string(&ob, out_item if strings.trim_space(out_item) != "" else "{}")
	}
	strings.write_byte(&ob, ']')
	json_raw(&o, "outputs", strings.to_string(ob))
	if len(sv.outputs) > 0 {
		json_raw(&o, "output", sv.outputs[0])
	} else {
		json_raw(&o, "output", "null")
	}
	return json_end(&o), true, domain.Domain_Error{}
}

substitute_on_output_placeholders :: proc(template: string, output_json: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(template, "{{") do return template
	b := strings.builder_make(allocator)
	s := template
	pos := 0
	for pos < len(s) {
		open_idx := strings.index(s[pos:], "{{")
		if open_idx < 0 {
			strings.write_string(&b, s[pos:])
			break
		}
		strings.write_string(&b, s[pos : pos + open_idx])
		start := pos + open_idx + 2
		close_idx := strings.index(s[start:], "}}")
		if close_idx < 0 {
			strings.write_string(&b, s[pos + open_idx:])
			break
		}
		token := strings.trim_space(s[start : start + close_idx])
		pos = start + close_idx + 2
		val := ""
		if token == "output" {
			val = output_json
		} else if strings.has_prefix(token, "output.") {
			field := token[len("output."):]
			if v, ok := extract_scalar_or_raw_string(output_json, field, allocator); ok do val = v
		}
		strings.write_string(&b, val)
	}
	return strings.to_string(b)
}


// ---- F1: a rejected gate re-plans -------------------------------------------------------

GATE_MAX_REPLANS_DEFAULT :: 3
