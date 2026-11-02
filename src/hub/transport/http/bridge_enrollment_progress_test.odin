package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

// REQ-ENROLL-PENDING: pending replacement is independent of runtime status and
// enrollment_state. An existing online bridge remains an enrolled target.
@(test)
test_bridge_json_marks_replacement_without_hiding_enrolled_bridge :: proc(t: ^testing.T) {
	row := domain.Bridge{bridge_id = "brg_existing", status = .Online, capabilities_json = "{}"}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_bridge_json(&b, row, nil, nil, true)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, `"enrollment_in_progress":true`))
	testing.expect(t, strings.contains(out, `"enrollment_state":"enrolled"`))
	testing.expect(t, strings.contains(out, `"status":"online"`))
}
