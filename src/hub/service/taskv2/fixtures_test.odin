package taskv2

import "core:encoding/json"
import "core:strings"
import "core:testing"
import jsonx "odin_test:lib/jsonx"

// Facet fixtures (plan §4b): the same JSON files are decoded by Odin (#load,
// here) and by node (tests/facets_fixtures_conformance.test.mjs); unknown
// fields must survive the hub verbatim.
FIXTURE_HANDOFF   :: #load("../../../../tests/fixtures/facets/handoff.json", string)
FIXTURE_VCS       :: #load("../../../../tests/fixtures/facets/vcs.json", string)
FIXTURE_VERIFY    :: #load("../../../../tests/fixtures/facets/verify.json", string)
FIXTURE_OUTPUT    :: #load("../../../../tests/fixtures/facets/output.json", string)
FIXTURE_RUNTIME   :: #load("../../../../tests/fixtures/facets/runtime.json", string)
FIXTURE_ARTIFACTS :: #load("../../../../tests/fixtures/facets/artifacts.json", string)
FIXTURE_UNKNOWN   :: #load("../../../../tests/fixtures/facets/unknown_fields.json", string)

@(test)
test_facet_fixtures_decode :: proc(t: ^testing.T) {
	// handoff
	testing.expect(t, jsonx.extract_string(FIXTURE_HANDOFF, "summary", "", true, context.temp_allocator) != "", "handoff.summary")
	// vcs
	testing.expect(t, jsonx.extract_string(FIXTURE_VCS, "head", "", true, context.temp_allocator) != "", "vcs.head")
	_, dirty_ok := jsonx.extract_bool_literal(FIXTURE_VCS, "dirty", true)
	testing.expect(t, dirty_ok, "vcs.dirty is a boolean")
	files, files_ok := jsonx.extract_raw_array(FIXTURE_VCS, "files", true, context.temp_allocator)
	testing.expect(t, files_ok && strings.has_prefix(files, "["), "vcs.files is an array")
	// verify
	_, ec_ok := jsonx.extract_int_found(FIXTURE_VERIFY, "exit_code", true)
	_, dur_ok := jsonx.extract_int_found(FIXTURE_VERIFY, "duration_ms", true)
	testing.expect(t, ec_ok && dur_ok, "verify.exit_code / duration_ms are integers")
	testing.expect(t, jsonx.extract_string(FIXTURE_VERIFY, "log_ref", "", true, context.temp_allocator) != "", "verify.log_ref")
	testing.expect(t, jsonx.extract_string(FIXTURE_VERIFY, "head_at_start", "", true, context.temp_allocator) != "" && jsonx.extract_string(FIXTURE_VERIFY, "head_at_end", "", true, context.temp_allocator) != "", "verify heads")
	_, vdirty_ok := jsonx.extract_bool_literal(FIXTURE_VERIFY, "dirty", true)
	testing.expect(t, vdirty_ok || strings.contains(FIXTURE_VERIFY, `"dirty": null`) || strings.contains(FIXTURE_VERIFY, `"dirty":null`), "verify.dirty is bool|null")
	// output
	testing.expect(t, strings.has_prefix(strings.trim_space(FIXTURE_OUTPUT), "{"), "output is an object")
	// runtime
	testing.expect(t, jsonx.extract_string(FIXTURE_RUNTIME, "bridge_id", "", true, context.temp_allocator) != "", "runtime.bridge_id")
	testing.expect(t, jsonx.extract_string(FIXTURE_RUNTIME, "started_at", "", true, context.temp_allocator) != "", "runtime.started_at")
	// artifacts
	_, aok, _ := validate_artifacts_facet_json(FIXTURE_ARTIFACTS)
	testing.expect(t, aok, "artifacts fixture validates")
	// all parse as JSON
	for fx in ([]string{FIXTURE_HANDOFF, FIXTURE_VCS, FIXTURE_VERIFY, FIXTURE_OUTPUT, FIXTURE_RUNTIME, FIXTURE_ARTIFACTS, FIXTURE_UNKNOWN}) {
		v, err := json.parse_string(fx, allocator = context.temp_allocator)
		testing.expect(t, err == nil, "fixture parses")
		_, is_obj := v.(json.Object)
		testing.expect(t, is_obj, "fixture is an object")
	}
}

// The verbatim walker the hub uses to merge handoff members keeps every
// unknown (nested) member byte-for-byte, and the facet save path stores the
// whole body unchanged.
@(test)
test_facet_unknown_fields_round_trip_verbatim :: proc(t: ^testing.T) {
	members := jsonx_top_level_members(FIXTURE_UNKNOWN)
	raw_vendor, has := members["x_vendor"]
	testing.expect(t, has, "unknown member found by the walker")
	// re-extract through the library and compare structurally with the walker's slice
	lib_vendor, lib_ok := raw_object_field(FIXTURE_UNKNOWN, "x_vendor")
	testing.expect(t, lib_ok && strings.trim_space(lib_vendor) == strings.trim_space(raw_vendor), "walker slice == verbatim extractor slice")
	testing.expect(t, strings.contains(raw_vendor, `"ratio": 0.25`) && strings.contains(FIXTURE_UNKNOWN, `"x_big": 9007199254740991`), "spacing and big ints untouched (no re-marshal)")
	// handoff_body_json keeps the unknown member verbatim (modulo top-level ordering)
	summary := jsonx.extract_string(FIXTURE_UNKNOWN, "summary", "", true, context.temp_allocator)
	body := handoff_body_json(summary, FIXTURE_UNKNOWN)
	testing.expect(t, strings.contains(body, strings.trim_space(raw_vendor)), "unknown nested member spliced verbatim into the stored handoff")
	testing.expect(t, !strings.contains(body, `"truncated"`), "fixture is under the caps")
	// and the stored body parses back to the same values
	a, aerr := json.parse_string(FIXTURE_UNKNOWN, allocator = context.temp_allocator)
	b, berr := json.parse_string(body, allocator = context.temp_allocator)
	testing.expect(t, aerr == nil && berr == nil, "both parse")
	ao, _ := a.(json.Object)
	bo, _ := b.(json.Object)
	testing.expect_value(t, len(bo), len(ao))
	for k in ao do testing.expect(t, k in bo, k)
}
