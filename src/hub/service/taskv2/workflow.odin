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
		title       = "Explore -> Plan -> Approve -> Build -> Verify",
		description = "Explore the codebase, produce a structured task_list.v1 plan, pause at a human/coordinator gate, then fan out across planned items and run a final integration verification.",
		source      = "builtin",
		spec_json   = BUILTIN_WORKFLOW_EXPLORE_PLAN_BUILD,
	})
	append(&out, Workflow_Template{
		id          = "tpl_fix_flaky_tests",
		name        = "fix_flaky_tests",
		title       = "Reproduce -> Diagnose -> Fix Flaky Tests",
		description = "Scan a test suite for flaky tests, produce a task_list.v1 of reproducers/fixes, and fix each flaky test in parallel with verification.",
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
		req_user := jsonx.extract_bool(sobj, "requires_user_approval", false, true)
		if !req_user && has_brief do req_user = jsonx.extract_bool(brief_raw, "requires_user_approval", false, true)

		if skind == .Gate && (for_each != "" || parallel_n > 1) {
			return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("gate stage %s cannot use for_each or parallel > 1", skey), `{"code":"workflow_invalid"}`)
		}
		if skind == .Gate && approver != "user" && approver != "user_or_coordinator" {
			return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("gate stage %s approver must be user or user_or_coordinator", skey), `{"code":"workflow_invalid"}`)
		}
		if skind == .Task {
			bgoal := strings.trim_space(jsonx.extract_string(brief_raw, "goal", "", true, allocator))
			bacc := jsonx.extract_string_array(brief_raw, "acceptance", true, allocator)
			bver := strings.trim_space(jsonx.extract_string(brief_raw, "verify", "", true, allocator))
			has_out := brief_has_output_contract(brief_raw)
			if bgoal == "" || (len(bacc) == 0 && bver == "") {
				return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s brief requires non-empty goal, acceptance, and verify", skey), `{"code":"workflow_invalid"}`)
			}
			if bver == "" do bver = "none"
			if bver == "none" && !has_out && len(bacc) == 0 {
				return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("stage %s brief requires non-empty acceptance or verify", skey), `{"code":"workflow_invalid"}`)
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
		if st.for_each != "" {
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
				desc := strings.trim_space(jsonx.extract_string(obj, "description", "", true, allocator))
				append(&out, Workflow_Input_Spec{
					name        = iname,
					type_name   = itype,
					required    = req,
					default_val = def_val,
					has_default = has_def,
					description = desc,
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
				desc := strings.trim_space(jsonx.extract_string(trimmed_v, "description", "", true, allocator))
				append(&out, Workflow_Input_Spec{
					name        = k,
					type_name   = itype,
					required    = req,
					default_val = def_val,
					has_default = has_def,
					description = desc,
				})
			} else {
				// Shorthand: {"goal": "string"}
				tstr := strings.trim(trimmed_v, "\"")
				req := !strings.has_suffix(tstr, "?")
				append(&out, Workflow_Input_Spec{
					name      = k,
					type_name = strings.trim_suffix(tstr, "?"),
					required  = req,
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
		verify, has_v := jsonx.extract_string_found(obj, "verify", true, context.temp_allocator)
		if has_v && (strings.trim_space(verify) == "" || strings.trim_space(verify) == "none") {
			return domain.domain_error(.Validation_Failed, fmt.tprintf("task_list.v1 item[%d] has invalid verify command", idx), `{"code":"output_contract_invalid"}`)
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

extract_workflow_snapshot :: proc(chain: domain.Task_Chain, allocator := context.temp_allocator) -> (Workflow_Run_Snapshot, bool) {
	snap_raw := strings.trim_space(chain.workflow_snapshot_json)
	if snap_raw == "" || !strings.has_prefix(snap_raw, "{") do return {}, false
	inputs_raw := "{}"
	if in_obj, has_in := jsonx.extract_raw_object(snap_raw, "run_inputs", true, allocator); has_in {
		inputs_raw = in_obj
	} else if in_obj2, has_in2 := jsonx.extract_raw_object(chain.defaults_json, "workflow_inputs", true, allocator); has_in2 {
		inputs_raw = in_obj2
	}
	spec_source := snap_raw
	if nested_spec, has_nested := jsonx.extract_raw_object(snap_raw, "spec", true, allocator); has_nested {
		if _, has_st := jsonx.extract_raw_array(nested_spec, "stages", true, allocator); has_st {
			spec_source = nested_spec
		}
	}
	parsed, ok, _ := parse_and_validate_workflow_spec(spec_source, "", 0, allocator)
	if !ok do return {}, false
	def_id := strings.trim_space(jsonx.extract_string(snap_raw, "def_id", chain.workflow_def_ref, true, allocator))
	return Workflow_Run_Snapshot{
		spec        = parsed,
		inputs_json = inputs_raw,
		def_id      = def_id,
	}, true
}

workflow_stage_max_parallel :: proc(chain: domain.Task_Chain, stage_key: string) -> int {
	if chain.kind != domain.CHAIN_KIND_WORKFLOW || chain.workflow_snapshot_json == "" do return 0
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
		for t in tasks do if t.stage_key == task.stage_key do count += 1
		if count > 0 do total = count
	}
	json_int(&o, "stage_count", i64(total))
	if chain.workflow_def_ref != "" do json_str(&o, "workflow_def_ref", chain.workflow_def_ref)
	if strings.has_prefix(strings.trim_space(task.generated_by_json), "{") && strings.trim_space(task.generated_by_json) != "{}" {
		json_raw(&o, "generated_by", task.generated_by_json)
	}
	return json_end(&o)
}

// ---- Stage Fold (`fold_stage`) & Completeness ---------------------------------------

fold_stage :: proc(svc: ^Service, chain: domain.Task_Chain, stage_key: string, tasks: []domain.Task, stage_materialised: bool, allocator := context.temp_allocator) -> Stage_View {
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
		}
		if inst.state == .Cancelled {
			any_failed = true
		} else if inst.state == .Backlog && strings.trim_space(inst.blocked_on_json) != "" {
			if strings.contains(inst.blocked_on_json, `"human"`) || strings.contains(inst.blocked_on_json, `"budget_exhausted"`) || strings.contains(inst.blocked_on_json, `"oscillation"`) {
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

is_stage_marked_empty_done :: proc(chain: domain.Task_Chain, stage_key: string) -> bool {
	if strings.trim_space(chain.defaults_json) == "" do return false
	arr := jsonx.extract_string_array(chain.defaults_json, "empty_stages", true, context.temp_allocator)
	for s in arr do if s == stage_key do return true
	return false
}

mark_stage_empty_done :: proc(chain: ^domain.Task_Chain, stage_key: string) {
	if is_stage_marked_empty_done(chain^, stage_key) do return
	existing := jsonx.extract_string_array(chain.defaults_json, "empty_stages", true, context.temp_allocator)
	append(&existing, stage_key)
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for s, idx in existing {
		if idx > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"')
		contracts.write_json_string(&b, s)
		strings.write_byte(&b, '"')
	}
	strings.write_byte(&b, ']')
	o := json_begin()
	if strings.has_prefix(strings.trim_space(chain.defaults_json), "{") {
		for k, v in jsonx_top_level_members(chain.defaults_json) {
			if k == "empty_stages" do continue
			json_raw(&o, k, v)
		}
	}
	json_raw(&o, "empty_stages", strings.to_string(b))
	chain.defaults_json = json_end(&o)
}

workflow_all_stages_complete :: proc(svc: ^Service, chain: domain.Task_Chain, tasks: []domain.Task) -> bool {
	snap, ok := extract_workflow_snapshot(chain, context.temp_allocator)
	if !ok do return true
	for st in snap.spec.stages {
		sv := fold_stage(svc, chain, st.key, tasks, is_stage_marked_empty_done(chain, st.key), context.temp_allocator)
		if !sv.complete do return false
	}
	return true
}

// ---- Workflow Materializer (`materialize_ready_stages_in_uow`) ----------------------

materialize_ready_stages_in_uow :: proc(svc: ^Service, u: ^Uow, chain_in: domain.Task_Chain) -> (changed_any: bool, ok: bool, err: domain.Domain_Error) {
	chain := chain_in
	if chain.kind != domain.CHAIN_KIND_WORKFLOW || chain.publish_state != .Published || chain.status != .Active {
		return false, true, domain.Domain_Error{}
	}
	snap, sok := extract_workflow_snapshot(chain, context.temp_allocator)
	if !sok do return false, true, domain.Domain_Error{}

	// Loop so 0-item fan-out stages can immediately unblock their downstream stages in the same UoW
	for pass := 0; pass < len(snap.spec.stages) + 1; pass += 1 {
		pass_changed := false
		tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
		if terr.code != .None do return changed_any, false, terr

		stage_views := make(map[string]Stage_View, len(snap.spec.stages), context.temp_allocator)
		for st in snap.spec.stages {
			stage_views[st.key] = fold_stage(svc, chain, st.key, tasks, is_stage_marked_empty_done(chain, st.key), context.temp_allocator)
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
			if has_rows || is_stage_marked_empty_done(chain, st.key) do continue

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
	chain: ^domain.Task_Chain,
	snap: Workflow_Run_Snapshot,
	st: Workflow_Stage_Spec,
	existing_tasks: []domain.Task,
	stage_views: map[string]Stage_View,
) -> (bool, domain.Domain_Error) {
	items_raw := make([dynamic]string, context.temp_allocator)
	source_task_id := ""
	if st.for_each != "" {
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
			mark_stage_empty_done(chain, st.key)
			chain.updated_at = platform.clock_now(svc.clock)
			if saved_c, cok, cerr := iface.taskchain_save_chain(svc.repo, chain^); cok {
				chain^ = saved_c
			} else {
				return false, cerr
			}
			return true, domain.Domain_Error{}
		}
	} else {
		count_n := st.parallel if st.parallel > 1 else 1
		for _ in 0..<count_n do append(&items_raw, "{}")
	}

	total_count := len(items_raw)
	now := platform.clock_now(svc.clock)

	// Collect all upstream tasks from depends_on stages (and transitively if a depends_on stage was empty)
	upstream_task_ids := collect_upstream_stage_task_ids(st.depends_on, existing_tasks, snap.spec.stages, context.temp_allocator)

	for item_json, idx in items_raw {
		// Check idempotency: does (chain_id, stage_key, stage_index) already exist?
		already_exists := false
		for t in existing_tasks {
			if t.stage_key == st.key && t.stage_index == idx {
				already_exists = true
				break
			}
		}
		if already_exists do continue

		// Carry-forward check (after a `--cascade` retry): if an archived Done task for
		// this stage has identical generated_by item JSON, restore it to active (st.key, idx)
		// and wire any newly-materialised upstream dependencies without re-running it!
		if st.for_each != "" {
			if carried, cok := try_carry_forward_stage_item(svc, u, chain^, st.key, idx, item_json, existing_tasks, upstream_task_ids, now); cok {
				_ = carried
				continue
			}
		}

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

		// Ensure fleet roles for assignee and review_roles in brief_json
		if assignee := brief_assignee(brief_json); assignee != "" {
			ensure_workflow_fleet_role(svc, chain^, assignee, domain.FLEET_ROLE_WORKER)
		}
		for r in brief_review_roles(brief_json, context.temp_allocator) {
			if r == domain.FLEET_ROLE_REVIEWER {
				ensure_workflow_fleet_role(svc, chain^, "reviewer", domain.FLEET_ROLE_REVIEWER)
			}
		}

		prio_str := st.priority
		if prio_str == "" do prio_str = jsonx.extract_string(snap.spec.defaults_raw, "priority", "p2", true, context.temp_allocator)
		if st.for_each != "" {
			if item_prio := jsonx.extract_string(item_json, "priority", "", true, context.temp_allocator); item_prio != "" {
				prio_str = item_prio
			}
		}

		gen_by := "{}"
		if st.for_each != "" {
			g := json_begin()
			up_stage, _, _ := parse_for_each_expr(st.for_each)
			json_str(&g, "stage", up_stage)
			if source_task_id != "" do json_str(&g, "source_task_id", source_task_id)
			item_key := jsonx.extract_string(item_json, "key", "", true, context.temp_allocator)
			if item_key == "" do item_key = jsonx.extract_string(item_json, "id", fmt.tprintf("item_%d", idx), true, context.temp_allocator)
			json_str(&g, "item_key", item_key)
			json_int(&g, "item_index", i64(idx))
			json_raw(&g, "item", item_json if strings.has_prefix(strings.trim_space(item_json), "{") else "{}")
			gen_by = json_end(&g)
		} else {
			g := json_begin()
			json_str(&g, "stage", st.key)
			gen_by = json_end(&g)
		}

		req_user := st.requires_user_approval
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
			_, _, _ = iface.taskchain_save_dependency(svc.repo, domain.Task_Dependency{
				task_id            = saved_t.task_id,
				depends_on_task_id = up_tid,
				chain_id           = chain.chain_id,
				owner_user_id      = chain.owner_user_id,
				created_at         = now,
			})
		}

		cp := json_begin()
		json_raw(&cp, "brief", saved_t.brief_json)
		json_str(&cp, "stage_key", st.key)
		json_int(&cp, "stage_index", i64(idx))
		_, _, _ = append_event(svc.repo, svc.clock, saved_t, hub_actor(), EV_CREATED, json_end(&cp))
		_, _, _ = append_event(svc.repo, svc.clock, saved_t, hub_actor(), EV_PUBLISHED, "{}")
		if st.kind == .Gate {
			sp := json_begin()
			json_bool(&sp, "gate", true)
			_, _, _ = append_event(svc.repo, svc.clock, saved_t, hub_actor(), EV_SUBMITTED, json_end(&sp))
			effect_notify_coordinator(svc, u, chain.chain_id, chain.owner_user_id, "review_requested_from_user", fmt.tprintf("[taskv2] gate %s (%s) is awaiting approval on workflow chain %s", saved_t.task_id, saved_t.title, chain.chain_id))
		}
		if u != nil do effect_publish_task(u, saved_t, "created")
	}
	return true, domain.Domain_Error{}
}

@(private = "file")
try_carry_forward_stage_item :: proc(
	svc: ^Service,
	u: ^Uow,
	chain: domain.Task_Chain,
	stage_key: string,
	stage_index: int,
	item_json: string,
	existing_tasks: []domain.Task,
	upstream_task_ids: []domain.Task_ID,
	now: string,
) -> (domain.Task, bool) {
	prefix := fmt.tprintf("~carry~%s~", stage_key)
	new_key := strings.trim_space(jsonx.extract_string(item_json, "key", "", true, context.temp_allocator))
	if new_key == "" do new_key = strings.trim_space(jsonx.extract_string(item_json, "id", "", true, context.temp_allocator))

	for t in existing_tasks {
		if t.state != .Done || !strings.has_prefix(t.stage_key, prefix) do continue
		old_item, has_old := jsonx.extract_raw_object(t.generated_by_json, "item", true, context.temp_allocator)
		if !has_old do continue
		old_key := strings.trim_space(jsonx.extract_string(t.generated_by_json, "item_key", "", true, context.temp_allocator))
		if new_key != "" && old_key != "" && new_key != old_key do continue
		if !json_strings_equal(old_item, item_json, context.temp_allocator) do continue

		// Identical item found! Restore it to active stage_key and stage_index
		restored := t
		restored.stage_key = stage_key
		restored.stage_index = stage_index
		restored.updated_at = now
		saved, sok, _ := iface.taskchain_save_task(svc.repo, restored)
		if !sok do return {}, false
		cfp := json_begin()
		json_str(&cfp, "from_task_id", string(t.task_id))
		json_int(&cfp, "from_attempt_no", i64(t.attempt_no))
		_, _, _ = append_event(svc.repo, svc.clock, saved, hub_actor(), EV_CARRIED_FORWARD, json_end(&cfp))
		for up_tid in upstream_task_ids {
			_, _, _ = iface.taskchain_save_dependency(svc.repo, domain.Task_Dependency{
				task_id            = saved.task_id,
				depends_on_task_id = up_tid,
				chain_id           = chain.chain_id,
				owner_user_id      = chain.owner_user_id,
				created_at         = now,
			})
		}
		if u != nil do effect_publish_task(u, saved, "updated")
		return saved, true
	}
	return {}, false
}

@(private = "file")
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

@(private = "file")
ensure_workflow_fleet_role :: proc(svc: ^Service, chain: domain.Task_Chain, agent_id, role: string, bridge_id := "") {
	if svc == nil || svc.repo == nil || strings.trim_space(agent_id) == "" do return
	fleets, ferr := iface.taskchain_list_fleets_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if ferr.code != .None do return
	for f in fleets {
		if f.agent_id == agent_id && fleet_row_has_role(f, role) do return
	}
	now := platform.clock_now(svc.clock)
	roles_json := fmt.tprintf(`["%s"]`, role) if domain.fleet_role_name_valid(role) else `["worker"]`
	_ = iface.taskchain_ensure_fleet(svc.repo, domain.Task_Chain_Fleet{
		task_chain_id    = chain.chain_id,
		agent_id         = agent_id,
		capacity         = 4,
		min_warm         = 0,
		idle_ttl_seconds = 600,
		roles_json       = roles_json,
		bridge_id        = bridge_id,
		created_at       = now,
		updated_at       = now,
	})
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
		if strings.has_prefix(t, `"`) && strings.has_suffix(t, `"`) && len(t) >= 2 {
			return t[1 : len(t) - 1]
		}
		return t
	}
	if strings.has_prefix(token, "item.") {
		field := token[len("item."):]
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
	if v, ok := extract_scalar_or_raw_string(snap.inputs_json, key, allocator); ok do return v
	for inp in snap.spec.inputs {
		if inp.name == key && inp.has_default do return inp.default_val
	}
	return ""
}

@(private = "file")
extract_scalar_or_raw_string :: proc(obj_json: string, key: string, allocator := context.temp_allocator) -> (string, bool) {
	if s, ok := jsonx.extract_string_found(obj_json, key, true, allocator); ok do return s, true
	if n, ok := jsonx.extract_int_found(obj_json, key, true); ok do return fmt.tprintf("%d", n), true
	if b, ok := jsonx.extract_bool_literal(obj_json, key, true); ok do return "true" if b else "false", true
	members := jsonx_top_level_members(obj_json)
	if raw, ok := members[key]; ok {
		return strings.trim_space(raw), true
	}
	return "", false
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
		body_json     = spec_json,
		created_at    = now,
	}
	saved, sok, serr := iface.taskchain_save_workflow_definition(svc.repo, def)
	_, cerr := end_uow(svc, &u, sok)
	if !sok do return {}, false, serr
	if cerr.code != .None do return {}, false, cerr
	return saved, true, domain.Domain_Error{}
}

Workflow_Run_Input :: struct {
	chain_id:                      string, // optional existing unpublished chain to activate as a workflow
	ref:                           string, // template name, def_id, or user workflow name
	title:                         string,
	description:                   string,
	inputs_json:                   string,
	coordinator_agent_instance_id: string,
	bridge_id:                     string,
	directory_path:                string,
}

activate_workflow_on_existing_chain_in_uow :: proc(
	svc: ^Service,
	u: ^Uow,
	existing_chain: domain.Task_Chain,
	actor: Actor,
	ref: string,
	inputs_json: string,
) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	return workflow_run_in_uow(svc, u, existing_chain.owner_user_id, actor, Workflow_Run_Input{
		chain_id                      = string(existing_chain.chain_id),
		ref                           = ref,
		title                         = existing_chain.title,
		description                   = existing_chain.description,
		inputs_json                   = inputs_json,
		coordinator_agent_instance_id = existing_chain.coordinator_agent_instance_id,
	})
}

workflow_run :: proc(
	svc: ^Service,
	owner_user_id: domain.User_ID,
	actor: Actor,
	input: Workflow_Run_Input,
) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	chain, ok, err := workflow_run_in_uow(svc, &u, owner_user_id, actor, input)
	_, cerr := end_uow(svc, &u, ok)
	if !ok do return {}, false, err
	if cerr.code != .None do return {}, false, cerr
	fresh, fok, _ := iface.taskchain_get_chain(svc.repo, chain.chain_id)
	if fok do return fresh, true, domain.Domain_Error{}
	return chain, true, domain.Domain_Error{}
}

workflow_run_in_uow :: proc(
	svc: ^Service,
	u: ^Uow,
	owner_user_id: domain.User_ID,
	actor: Actor,
	input: Workflow_Run_Input,
) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	ref := strings.trim_space(input.ref)
	if ref == "" {
		return {}, false, domain.domain_error(.Validation_Failed, "workflow template or definition ref is required", `{"code":"workflow_invalid"}`)
	}
	def_ref, spec_json, found := resolve_workflow_ref(svc, owner_user_id, ref, context.temp_allocator)
	if !found {
		return {}, false, domain.domain_error(.Not_Found, fmt.tprintf("workflow definition or template not found: %s", ref))
	}
	parsed, pok, perr := parse_and_validate_workflow_spec(spec_json, "", 0, context.temp_allocator)
	if !pok do return {}, false, perr

	inputs_obj := strings.trim_space(input.inputs_json)
	if inputs_obj == "" do inputs_obj = "{}"
	if !strings.has_prefix(inputs_obj, "{") || !strings.has_suffix(inputs_obj, "}") {
		return {}, false, domain.domain_error(.Validation_Failed, "workflow inputs must be a JSON object", `{"code":"workflow_invalid"}`)
	}
	// Validate required workflow inputs
	for inp in parsed.inputs {
		if !inp.required do continue
		val, ok_v := extract_scalar_or_raw_string(inputs_obj, inp.name, context.temp_allocator)
		if (!ok_v || strings.trim_space(val) == "") && !inp.has_default {
			return {}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("missing required workflow input: %s", inp.name), `{"code":"workflow_input_missing"}`)
		}
	}

	// Build immutable snapshot JSON embedding spec + run_inputs
	snap_builder := json_begin()
	for k, v in jsonx_top_level_members(spec_json) {
		if k == "run_inputs" || k == "def_id" do continue
		json_raw(&snap_builder, k, v)
	}
	json_str(&snap_builder, "def_id", def_ref)
	json_raw(&snap_builder, "run_inputs", inputs_obj)
	snapshot_json := json_end(&snap_builder)

	defaults_builder := json_begin()
	for k, v in jsonx_top_level_members(parsed.defaults_raw) {
		json_raw(&defaults_builder, k, v)
	}
	json_raw(&defaults_builder, "workflow_inputs", inputs_obj)
	defaults_json := json_end(&defaults_builder)

	now := platform.clock_now(svc.clock)
	coord_id := strings.trim_space(input.coordinator_agent_instance_id)
	if coord_id == "" && (actor.kind == ACTOR_AGENT || actor.kind == ACTOR_COORDINATOR) {
		coord_id = actor.id
	}

	chain_title := strings.trim_space(input.title)
	if chain_title == "" {
		chain_title = substitute_workflow_placeholders(
			parsed.title if parsed.title != "" else parsed.name,
			Workflow_Run_Snapshot{spec = parsed, inputs_json = inputs_obj, def_id = def_ref},
			"", 0, 1, "{}", nil, false, context.temp_allocator,
		)
	}
	chain_desc := strings.trim_space(input.description)
	if chain_desc == "" do chain_desc = parsed.description

	target_cid := domain.Task_Chain_ID(strings.trim_space(input.chain_id))
	created_at := now
	if target_cid != "" {
		ex_c, ex_ok, _ := iface.taskchain_get_chain(svc.repo, target_cid)
		if !ex_ok || ex_c.owner_user_id != owner_user_id {
			return {}, false, domain.domain_error(.Not_Found, "chain not found")
		}
		if ex_c.publish_state == .Published || strings.trim_space(ex_c.workflow_snapshot_json) != "" {
			return {}, false, domain.domain_error(.Conflict, "chain is already published", `{"code":"already_published"}`)
		}
		created_at = ex_c.created_at
		if coord_id == "" do coord_id = ex_c.coordinator_agent_instance_id
		if strings.trim_space(input.title) == "" && ex_c.title != "" do chain_title = ex_c.title
		if strings.trim_space(input.description) == "" && ex_c.description != "" do chain_desc = ex_c.description
	} else {
		target_cid = domain.Task_Chain_ID(platform.generate_id(svc.ids, "chain_"))
	}

	chain := domain.Task_Chain{
		chain_id                      = target_cid,
		owner_user_id                 = owner_user_id,
		title                         = chain_title,
		description                   = chain_desc,
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = domain.CHAIN_KIND_WORKFLOW,
		coordinator_agent_instance_id = coord_id,
		workflow_def_ref              = def_ref,
		workflow_snapshot_json        = snapshot_json,
		defaults_json                 = defaults_json,
		created_at                    = created_at,
		updated_at                    = now,
		published_at                  = now,
	}
	saved_chain, sok, serr := iface.taskchain_save_chain(svc.repo, chain)
	if !sok do return {}, false, serr

	if coord_id != "" && !strings.has_prefix(coord_id, "agt_") {
		_, _, _ = iface.taskchain_save_member(svc.repo, domain.Task_Chain_Member{
			chain_id          = saved_chain.chain_id,
			agent_instance_id = coord_id,
			owner_user_id     = owner_user_id,
			role              = "coordinator",
			created_at        = now,
		})
	}
	if strings.trim_space(input.directory_path) != "" {
		_, _, _ = iface.taskchain_save_directory(svc.repo, domain.Task_Chain_Directory{
			directory_id  = platform.generate_id(svc.ids, "dir_"),
			chain_id      = saved_chain.chain_id,
			owner_user_id = owner_user_id,
			path          = strings.trim_space(input.directory_path),
			bridge_id     = strings.trim_space(input.bridge_id),
			vcs_kind      = "git",
			vcs_info_json = "{}",
			created_at    = now,
			updated_at    = now,
		})
	}
	// Ensure default worker fleet row so stages without explicit assignee can be matched
	ensure_workflow_fleet_role(svc, saved_chain, "coder", domain.FLEET_ROLE_WORKER, strings.trim_space(input.bridge_id))
	if svc.agents != nil {
		if insts, ierr := iface.agent_list_instances_by_owner(svc.agents, owner_user_id, 1000, ""); ierr.code == .None {
			for inst in insts {
				if inst.agent_instance_id == coord_id || strings.trim_space(inst.chain_id) != "" do continue
				bound := inst
				bound.chain_id = string(saved_chain.chain_id)
				_, _, _ = iface.agent_save_instance(svc.agents, bound)
				_, _, _ = iface.taskchain_save_member(svc.repo, domain.Task_Chain_Member{
					chain_id          = saved_chain.chain_id,
					agent_instance_id = inst.agent_instance_id,
					agent_id          = inst.agent_id,
					owner_user_id     = owner_user_id,
					role              = "worker",
					created_at        = now,
				})
				if inst.agent_id != "" {
					ensure_workflow_fleet_role(svc, saved_chain, inst.agent_id, domain.FLEET_ROLE_WORKER, inst.bridge_id)
				}
			}
		}
	}

	if _, mok, merr := materialize_ready_stages_in_uow(svc, u, saved_chain); !mok {
		return {}, false, merr
	}
	if aok, aerr := after_chain_change(svc, u, saved_chain.chain_id, owner_user_id, .Chain_Published); !aok {
		return {}, false, aerr
	}
	if u != nil do effect_publish_chain(u, saved_chain.chain_id, owner_user_id, "created")
	return saved_chain, true, domain.Domain_Error{}
}

@(private = "file")
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

workflow_status_json_for_chain :: proc(svc: ^Service, chain: domain.Task_Chain, allocator := context.temp_allocator) -> (string, bool, domain.Domain_Error) {
	if chain.kind != domain.CHAIN_KIND_WORKFLOW {
		return "", false, domain.domain_error(.Validation_Failed, "chain is not a workflow chain")
	}
	snap, sok := extract_workflow_snapshot(chain, allocator)
	if !sok {
		return "", false, domain.domain_error(.Validation_Failed, "workflow chain has no valid snapshot")
	}
	tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if terr.code != .None do return "", false, terr

	o := json_begin(allocator)
	json_str(&o, "chain_id", string(chain.chain_id))
	json_str(&o, "title", chain.title)
	json_str(&o, "kind", chain.kind)
	json_str(&o, "status", chain_status_str(chain.status))
	json_str(&o, "workflow_def_ref", chain.workflow_def_ref)
	json_str(&o, "workflow_name", snap.spec.name)
	json_raw(&o, "inputs", snap.inputs_json)

	sb := strings.builder_make(allocator)
	strings.write_byte(&sb, '[')
	for st, sidx in snap.spec.stages {
		if sidx > 0 do strings.write_byte(&sb, ',')
		sv := fold_stage(svc, chain, st.key, tasks, is_stage_marked_empty_done(chain, st.key), allocator)
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

workflow_status_json_by_id :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, allocator := context.temp_allocator) -> (string, bool, domain.Domain_Error) {
	chain, ok, err := iface.taskchain_get_chain(svc.repo, chain_id)
	if !ok do return "", false, err
	if chain.owner_user_id != owner_user_id do return "", false, domain.domain_error(.Forbidden, "forbidden")
	return workflow_status_json_for_chain(svc, chain, allocator)
}

workflow_status_json :: proc{workflow_status_json_for_chain, workflow_status_json_by_id}

workflow_stage_output_json_for_chain :: proc(svc: ^Service, chain: domain.Task_Chain, stage_key: string, allocator := context.temp_allocator) -> (string, bool, domain.Domain_Error) {
	if chain.kind != domain.CHAIN_KIND_WORKFLOW {
		return "", false, domain.domain_error(.Validation_Failed, "chain is not a workflow chain")
	}
	snap, sok := extract_workflow_snapshot(chain, allocator)
	if !sok do return "", false, domain.domain_error(.Validation_Failed, "workflow chain has no valid snapshot")
	found_stage := false
	for st in snap.spec.stages do if st.key == stage_key { found_stage = true; break }
	if !found_stage {
		return "", false, domain.domain_error(.Not_Found, fmt.tprintf("stage not found in workflow: %s", stage_key))
	}
	tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, chain.owner_user_id)
	if terr.code != .None do return "", false, terr
	sv := fold_stage(svc, chain, stage_key, tasks, is_stage_marked_empty_done(chain, stage_key), allocator)

	o := json_begin(allocator)
	json_str(&o, "chain_id", string(chain.chain_id))
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

workflow_stage_output_json_by_id :: proc(svc: ^Service, chain_id: domain.Task_Chain_ID, owner_user_id: domain.User_ID, stage_key: string, allocator := context.temp_allocator) -> (string, bool, domain.Domain_Error) {
	chain, ok, err := iface.taskchain_get_chain(svc.repo, chain_id)
	if !ok do return "", false, err
	if chain.owner_user_id != owner_user_id do return "", false, domain.domain_error(.Forbidden, "forbidden")
	return workflow_stage_output_json_for_chain(svc, chain, stage_key, allocator)
}

workflow_stage_output_json :: proc{workflow_stage_output_json_for_chain, workflow_stage_output_json_by_id}

// ---- Workflow Retry (`--stage`, `--item`, `--cascade`) & Cancel ---------------------

Workflow_Retry_Input :: struct {
	stage_key:   string,
	item_index:  int,
	has_item:    bool,
	task_id:     string,
	cascade:     bool,
	reason:      string,
}

Workflow_Retry_Result :: struct {
	reopened_task_ids:    []domain.Task_ID,
	cancelled_task_ids:   []domain.Task_ID,
	carried_forward_keys: []string,
	orphaned_task_ids:    []domain.Task_ID,
}

workflow_retry :: proc(
	svc: ^Service,
	chain_id: domain.Task_Chain_ID,
	owner_user_id: domain.User_ID,
	actor: Actor,
	input: Workflow_Retry_Input,
) -> (Workflow_Retry_Result, bool, domain.Domain_Error) {
	in_mut := input
	if in_mut.task_id != "" && in_mut.stage_key == "" {
		if t, tok, _ := iface.taskchain_get_task(svc.repo, domain.Task_ID(in_mut.task_id)); tok {
			in_mut.stage_key = t.stage_key
			in_mut.item_index = t.stage_index
			in_mut.has_item = true
		}
	}
	skey := strings.trim_space(in_mut.stage_key)
	if skey == "" {
		return {}, false, domain.domain_error(.Validation_Failed, "stage is required for workflow retry")
	}
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	res, ok, err := workflow_retry_in_uow(svc, &u, chain_id, owner_user_id, actor, in_mut)
	_, cerr := end_uow(svc, &u, ok)
	if !ok do return {}, false, err
	if cerr.code != .None do return {}, false, cerr
	return res, true, domain.Domain_Error{}
}

workflow_retry_in_uow :: proc(
	svc: ^Service,
	u: ^Uow,
	chain_id: domain.Task_Chain_ID,
	owner_user_id: domain.User_ID,
	actor: Actor,
	input: Workflow_Retry_Input,
) -> (Workflow_Retry_Result, bool, domain.Domain_Error) {
	chain, cok, _ := iface.taskchain_get_chain(svc.repo, chain_id)
	if !cok || chain.owner_user_id != owner_user_id {
		return {}, false, domain.domain_error(.Not_Found, "workflow chain not found")
	}
	if chain.kind != domain.CHAIN_KIND_WORKFLOW {
		return {}, false, domain.domain_error(.Validation_Failed, "chain is not a workflow chain")
	}
	snap, sok := extract_workflow_snapshot(chain, context.temp_allocator)
	if !sok do return {}, false, domain.domain_error(.Validation_Failed, "workflow chain has no valid snapshot")

	found_stage := false
	for st in snap.spec.stages {
		if st.key == input.stage_key {
			found_stage = true
			break
		}
	}
	if !found_stage {
		return {}, false, domain.domain_error(.Not_Found, fmt.tprintf("stage not found: %s", input.stage_key))
	}

	tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, owner_user_id)
	if terr.code != .None do return {}, false, terr

	// Compute transitive downstream stage keys of `input.stage_key`
	downstream_stages := make(map[string]bool, len(snap.spec.stages), context.temp_allocator)
	for pass := 0; pass < len(snap.spec.stages); pass += 1 {
		for st in snap.spec.stages {
			if downstream_stages[st.key] do continue
			for dep in st.depends_on {
				d := strings.trim_space(dep)
				if d == input.stage_key || downstream_stages[d] {
					downstream_stages[st.key] = true
					break
				}
			}
		}
	}

	// Collect materialised downstream tasks
	downstream_tasks := make([dynamic]domain.Task, 0, len(tasks), context.temp_allocator)
	for t in tasks {
		if downstream_stages[t.stage_key] {
			append(&downstream_tasks, t)
		}
	}

	// Rule: if any downstream stage has materialised tasks and !cascade -> 409 downstream_materialised
	if len(downstream_tasks) > 0 && !input.cascade {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"code":"downstream_materialised","downstream_tasks":[`)
		for dt, idx in downstream_tasks {
			if idx > 0 do strings.write_byte(&b, ',')
			strings.write_byte(&b, '"')
			contracts.write_json_string(&b, string(dt.task_id))
			strings.write_byte(&b, '"')
		}
		strings.write_string(&b, "]}")
		return {}, false, domain.domain_error(.Conflict, "downstream stages have already been materialised; pass --cascade to cancel and re-evaluate downstream work", strings.to_string(b))
	}

	reopened_ids := make([dynamic]domain.Task_ID, context.temp_allocator)
	cancelled_ids := make([dynamic]domain.Task_ID, context.temp_allocator)
	carried_keys := make([dynamic]string, context.temp_allocator)
	orphaned_ids := make([dynamic]domain.Task_ID, context.temp_allocator)

	// Target tasks in `input.stage_key`
	target_tasks := make([dynamic]domain.Task, context.temp_allocator)
	for t in tasks {
		if t.stage_key != input.stage_key do continue
		if input.has_item && t.stage_index != input.item_index do continue
		append(&target_tasks, t)
	}
	if len(target_tasks) == 0 {
		return {}, false, domain.domain_error(.Not_Found, "no matching materialised task for stage/item")
	}

	// Handle downstream tasks under --cascade
	now := platform.clock_now(svc.clock)
	existing_deps, _ := iface.taskchain_list_dependencies_by_chain(svc.repo, chain.chain_id, owner_user_id)

	for dt in downstream_tasks {
		orig_stage := dt.stage_key
		orig_idx := dt.stage_index
		item_key := jsonx.extract_string(dt.generated_by_json, "item_key", "", true, context.temp_allocator)
		_, has_gen_item := jsonx.extract_raw_object(dt.generated_by_json, "item", true, context.temp_allocator)

		// Remove dependency edges into/from `dt` so it doesn't block or get blocked while parked/cancelled
		for ed in existing_deps {
			if ed.task_id == dt.task_id || ed.depends_on_task_id == dt.task_id {
				_, _ = iface.taskchain_remove_dependency(svc.repo, ed.task_id, ed.depends_on_task_id, owner_user_id)
			}
		}

		// If `dt` is a Done fan-out item, park it as a carry-forward candidate!
		// When the upstream stage finishes its retry, `try_carry_forward_stage_item` will restore it if its item JSON is unchanged.
		if dt.state == .Done && has_gen_item {
			parked := dt
			parked.stage_key = fmt.tprintf("~carry~%s~%s", orig_stage, dt.task_id)
			parked.updated_at = now
			_, _, _ = iface.taskchain_save_task(svc.repo, parked)
			if item_key != "" do append(&carried_keys, item_key)
			continue
		}

		// Otherwise cancel `dt`, reclaim its leases, emit `orphaned_work` if it had VCS commits, and archive its stage_key
		if leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, dt.task_id); lerr.code == .None {
			for l in leases {
				_ = expire_lease_in_uow(svc, u, l, EXPIRE_CANCELLED, actor)
			}
		}
		if vcs_head := latest_vcs_head_for_task(svc, dt); vcs_head != "" {
			op := json_begin()
			json_str(&op, "task_id", string(dt.task_id))
			json_str(&op, "stage_key", orig_stage)
			json_int(&op, "stage_index", i64(orig_idx))
			json_str(&op, "head", vcs_head)
			if item_key != "" do json_str(&op, "item_key", item_key)
			_, _, _ = append_event(svc.repo, svc.clock, dt, actor, EV_ORPHANED_WORK, json_end(&op))
			append(&orphaned_ids, dt.task_id)
		}
		dt_cur := dt
		if dt_cur.state != .Cancelled {
			cp := json_begin()
			json_str(&cp, "reason", "cascade_retry")
			json_str(&cp, "upstream_stage", input.stage_key)
			refolded, _, rok, rerr := record_event(svc, u, dt_cur, actor, EV_CANCELLED, json_end(&cp))
			if !rok do return {}, false, rerr
			dt_cur = refolded
			append(&cancelled_ids, dt_cur.task_id)
		}
		dt_cur.stage_key = fmt.tprintf("~cancelled~%s~%s", orig_stage, dt_cur.task_id)
		dt_cur.updated_at = now
		_, _, _ = iface.taskchain_save_task(svc.repo, dt_cur)
	}

	// Reopen target task(s)
	for tt in target_tasks {
		if leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, tt.task_id); lerr.code == .None {
			for l in leases {
				_ = expire_lease_in_uow(svc, u, l, EXPIRE_REPLACED, actor)
			}
		}
		rp := json_begin()
		json_str(&rp, "stage_key", tt.stage_key)
		json_int(&rp, "stage_index", i64(tt.stage_index))
		if input.cascade do json_bool(&rp, "cascade", true)
		refolded, _, rok, rerr := record_event(svc, u, tt, actor, EV_REOPENED, json_end(&rp))
		if !rok do return {}, false, rerr
		if refolded.kind == .Gate {
			sp := json_begin()
			json_bool(&sp, "gate", true)
			_, _, _, _ = record_event(svc, u, refolded, actor, EV_SUBMITTED, json_end(&sp))
		}
		append(&reopened_ids, tt.task_id)
	}

	// If chain was Completed, reopen chain status to Active
	if chain.status == .Completed {
		chain.status = .Active
		chain.completed_at = ""
		chain.updated_at = now
		_, _, _ = iface.taskchain_save_chain(svc.repo, chain)
	}

	if aok, aerr := after_chain_change(svc, u, chain.chain_id, owner_user_id, .Task_Reopened); !aok {
		return {}, false, aerr
	}
	return Workflow_Retry_Result{
		reopened_task_ids    = reopened_ids[:],
		cancelled_task_ids   = cancelled_ids[:],
		carried_forward_keys = carried_keys[:],
		orphaned_task_ids    = orphaned_ids[:],
	}, true, domain.Domain_Error{}
}

@(private = "file")
latest_vcs_head_for_task :: proc(svc: ^Service, task: domain.Task) -> string {
	facets, ferr := iface.taskchain_list_facets_by_task(svc.repo, task.task_id, task.owner_user_id)
	if ferr.code != .None do return ""
	best_att := -1
	head := ""
	for f in facets {
		if f.kind == FACET_VCS && f.attempt_no >= best_att {
			if h := strings.trim_space(jsonx.extract_string(f.body_json, "head", "", true, context.temp_allocator)); h != "" {
				best_att = f.attempt_no
				head = h
			}
		}
	}
	return head
}

workflow_cancel :: proc(
	svc: ^Service,
	chain_id: domain.Task_Chain_ID,
	owner_user_id: domain.User_ID,
	actor: Actor,
	reason := "workflow_cancelled",
) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	chain, cok, _ := iface.taskchain_get_chain(svc.repo, chain_id)
	if !cok || chain.owner_user_id != owner_user_id {
		_, _ = end_uow(svc, &u, false)
		return {}, false, domain.domain_error(.Not_Found, "workflow chain not found")
	}
	if chain.kind != domain.CHAIN_KIND_WORKFLOW {
		_, _ = end_uow(svc, &u, false)
		return {}, false, domain.domain_error(.Validation_Failed, "chain is not a workflow chain")
	}
	tasks, terr := iface.taskchain_list_tasks_by_chain(svc.repo, chain.chain_id, owner_user_id)
	if terr.code != .None {
		_, _ = end_uow(svc, &u, false)
		return {}, false, terr
	}
	for t in tasks {
		if domain.task_state_is_terminal(t.state) do continue
		if leases, lerr := iface.taskchain_list_leases_by_task(svc.repo, t.task_id); lerr.code == .None {
			for l in leases {
				_ = expire_lease_in_uow(svc, &u, l, EXPIRE_CHAIN_CLOSED, actor)
			}
		}
		cp := json_begin()
		json_str(&cp, "reason", reason if strings.trim_space(reason) != "" else "workflow_cancelled")
		_, _, _, _ = record_event(svc, &u, t, actor, EV_CANCELLED, json_end(&cp))
	}
	now := platform.clock_now(svc.clock)
	chain.status = .Cancelled
	chain.completed_at = now
	chain.updated_at = now
	saved, sok, serr := iface.taskchain_save_chain(svc.repo, chain)
	if sok do effect_publish_chain(&u, saved.chain_id, owner_user_id, "cancelled")
	_, cerr := end_uow(svc, &u, sok)
	if !sok do return {}, false, serr
	if cerr.code != .None do return {}, false, cerr
	return saved, true, domain.Domain_Error{}
}

// ---- Ticket -> Workflow Trigger (`brief.on_output` = `start_workflow`) ---------------

// trigger_on_output_workflows_in_uow inspects every Done task in `tasks` that
// declares `brief.on_output` (`{"kind":"start_workflow", ...}` or `{"workflow":...}`).
// If the task does not yet have an `EV_STARTED_WORKFLOW` event, it starts the
// child workflow chain in the SAME UoW and records `EV_STARTED_WORKFLOW {chain_id}`.
trigger_on_output_workflows_in_uow :: proc(
	svc: ^Service,
	u: ^Uow,
	parent_chain: domain.Task_Chain,
	tasks: []domain.Task,
) -> (bool, domain.Domain_Error) {
	for t in tasks {
		if t.state != .Done do continue
		on_out, has_on_out := jsonx.extract_raw_object(t.brief_json, "on_output", true, context.temp_allocator)
		if !has_on_out || strings.trim_space(on_out) == "" do continue

		kind_str := strings.trim_space(jsonx.extract_string(on_out, "kind", "start_workflow", true, context.temp_allocator))
		if kind_str != "" && kind_str != "start_workflow" do continue

		// Idempotency: check if EV_STARTED_WORKFLOW already exists on `t`
		if event_exists(svc, t, EV_STARTED_WORKFLOW) do continue

		wf_ref := strings.trim_space(jsonx.extract_string(on_out, "workflow", "", true, context.temp_allocator))
		if wf_ref == "" do wf_ref = strings.trim_space(jsonx.extract_string(on_out, "start_workflow", "", true, context.temp_allocator))
		if wf_ref == "" do wf_ref = strings.trim_space(jsonx.extract_string(on_out, "template", "", true, context.temp_allocator))
		if wf_ref == "" do wf_ref = strings.trim_space(jsonx.extract_string(on_out, "def_id", "", true, context.temp_allocator))
		if wf_ref == "" do continue

		// Extract task's latest output facet
		out_body := "{}"
		if facets, ferr := iface.taskchain_list_facets_by_task(svc.repo, t.task_id, t.owner_user_id); ferr.code == .None {
			best_att := -1
			for f in facets {
				if f.kind == FACET_OUTPUT && f.attempt_no >= best_att {
					best_att = f.attempt_no
					out_body = f.body_json
				}
			}
		}

		// Resolve inputs for the spawned workflow:
		// If `on_output.inputs` is provided, substitute `{{output.<field>}}` or `{{output}}` in its values;
		// otherwise pass `out_body` (or merge `on_output.inputs` with `out_body`).
		wf_inputs_json := out_body
		if raw_in, has_in := jsonx.extract_raw_object(on_out, "inputs", true, context.temp_allocator); has_in && strings.has_prefix(strings.trim_space(raw_in), "{") {
			ib := json_begin()
			raw_in_members := jsonx_top_level_members(raw_in)
			// Also include top-level fields from out_body if not overridden by raw_in
			for k, v in jsonx_top_level_members(out_body) {
				if _, overridden := raw_in_members[k]; overridden do continue
				json_raw(&ib, k, v)
			}
			for k, v in raw_in_members {
				trimmed_v := strings.trim_space(v)
				if strings.has_prefix(trimmed_v, `"`) && strings.has_suffix(trimmed_v, `"`) && strings.contains(trimmed_v, "{{") {
					unquoted := trimmed_v[1 : len(trimmed_v) - 1]
					resolved := substitute_on_output_placeholders(unquoted, out_body, context.temp_allocator)
					json_str(&ib, k, resolved)
				} else {
					json_raw(&ib, k, trimmed_v)
				}
			}
			wf_inputs_json = json_end(&ib)
		}

		wf_title := strings.trim_space(jsonx.extract_string(on_out, "title", "", true, context.temp_allocator))
		if wf_title != "" {
			wf_title = substitute_on_output_placeholders(wf_title, out_body, context.temp_allocator)
		}

		child_chain, cok, cerr := workflow_run_in_uow(svc, u, parent_chain.owner_user_id, hub_actor(), Workflow_Run_Input{
			ref                           = wf_ref,
			title                         = wf_title,
			inputs_json                   = wf_inputs_json,
			coordinator_agent_instance_id = parent_chain.coordinator_agent_instance_id,
		})
		if !cok do return false, cerr

		// Copy fleet rows from parent chain to child workflow chain so reviewers/workers match seamlessly
		if parent_fleets, pferr := iface.taskchain_list_fleets_by_chain(svc.repo, parent_chain.chain_id, parent_chain.owner_user_id); pferr.code == .None {
			for pf in parent_fleets {
				cf := pf
				cf.task_chain_id = child_chain.chain_id
				_, _ = iface.taskchain_upsert_fleet(svc.repo, cf)
			}
		}
		// Copy directories from parent chain to child workflow chain
		if parent_dirs, pderr := iface.taskchain_list_directories_by_chain(svc.repo, parent_chain.chain_id, parent_chain.owner_user_id); pderr.code == .None {
			for pd in parent_dirs {
				cd := pd
				cd.directory_id = platform.generate_id(svc.ids, "dir_")
				cd.chain_id = child_chain.chain_id
				_, _, _ = iface.taskchain_save_directory(svc.repo, cd)
			}
		}

		ep := json_begin()
		json_str(&ep, "chain_id", string(child_chain.chain_id))
		json_str(&ep, "workflow", wf_ref)
		if _, aok, aerr := append_event(svc.repo, svc.clock, t, hub_actor(), EV_STARTED_WORKFLOW, json_end(&ep)); !aok {
			return false, aerr
		}
		// Re-run matcher on child_chain now that fleets/directories are copied
		_, _ = match_chain_in_uow(svc, u, child_chain, .Chain_Published)
	}
	return true, domain.Domain_Error{}
}

@(private = "file")
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

