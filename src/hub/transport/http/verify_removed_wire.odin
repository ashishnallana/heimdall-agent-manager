package http

import "core:strings"
import taskv2 "odin_test:hub/service/taskv2"
import jsonx "odin_test:lib/jsonx"

// Configured verification commands were removed (REQ-TV2-1, migration M2): for
// one release requests that still carry the old keys succeed, the keys are
// dropped by the service, and the response says so with
//   "warnings":[{"code":"verify_removed","fields":[…]}]

// with_verify_removed_warnings appends the warning to a JSON object response
// body; the body is returned unchanged when nothing was dropped.
with_verify_removed_warnings :: proc(data: string, fields: []string) -> string {
	warnings := taskv2.verify_removed_warnings_json(fields)
	if warnings == "" do return data
	return with_response_warnings(data, warnings[1:len(warnings) - 1])
}

// with_response_warnings appends `"warnings":[items…]` (each item raw JSON) to
// a JSON object response body. "" leaves the body unchanged.
with_response_warnings :: proc(data: string, items: ..string) -> string {
	body := strings.trim_space(data)
	if len(items) == 0 || len(body) < 2 || body[len(body) - 1] != '}' do return data
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, body[:len(body) - 1])
	if strings.trim_space(body[1:len(body) - 1]) != "" do strings.write_byte(&b, ',')
	strings.write_string(&b, `"warnings":[`)
	written := 0
	for it in items {
		if strings.trim_space(it) == "" do continue
		if written > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, it)
		written += 1
	}
	if written == 0 do return data
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// brief_verify_removed_fields: the removed keys a request's `brief` carries.
brief_verify_removed_fields :: proc(body: string) -> []string {
	brief, ok := jsonx.extract_raw_object(body, "brief", top_level_only = true, allocator = context.temp_allocator)
	if !ok do return nil
	_, removed := taskv2.strip_removed_verify_keys(brief)
	return removed
}

// submit_verify_removed_fields: the removed lease.submit params a request carries.
submit_verify_removed_fields :: proc(params: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for key in taskv2.REMOVED_VERIFY_SUBMIT_KEYS do if jsonx.has_key(params, key, top_level_only = true) do append(&out, key)
	return out[:]
}

// task_specs_verify_removed_fields: the removed keys a chain.propose `tasks`
// array carries (in a spec's brief or on the spec itself).
task_specs_verify_removed_fields :: proc(tasks_json: string) -> []string {
	if strings.trim_space(tasks_json) == "" do return nil
	_, removed := taskv2.strip_removed_verify_keys_in_task_specs(tasks_json)
	return removed
}

// workflow_spec_verify_removed_fields: the removed keys a workflow spec carries
// in its defaults or stage briefs.
workflow_spec_verify_removed_fields :: proc(spec_json: string) -> []string {
	if strings.trim_space(spec_json) == "" do return nil
	_, removed := taskv2.strip_removed_verify_keys_in_workflow_spec(spec_json)
	return removed
}
