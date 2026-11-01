package main

import "core:strings"
import "core:testing"

@(test)
test_bridge_taskv2_requirements_context_and_review_checkpoint :: proc(t: ^testing.T) {
	md := bridge_taskv2_render_task_md(`{
		"task_id":"task_req",
		"lease":{"lease_id":"lease_req","kind":"review"},
		"task":{"title":"Requirement context"},
		"brief":{"goal":"New objective","acceptance":["Google sign-in"]},
		"requirements":{
			"revision":3,"acknowledged_revision":2,"acknowledgement_required":true,
			"submitted_revision":2,"submitted_attempt_no":4,"submitted_head":"review-head",
			"review_checkpoint_required":true,
			"latest_change":{"reason":"Added provider","before":{"goal":"Old objective"},"after":{"goal":"New objective"}},
			"change_fetch":"ham-ctl task fetch task_req '#123'",
			"submitted_fetch":"ham-ctl task fetch task_req '#122'"
		}
	}`)
	defer delete(md)
	for expected in ([]string{
		"Current revision: **3**", "acknowledged revision: **2**",
		"--lease lease_req --acknowledge-requirements-revision 3",
		"Submitted revision: **2**, attempt: **4**, head: `review-head`",
		"Do not post a verdict", "lease handoff", "Added provider",
		"Old objective", "New objective", "'#123'", "'#122'",
	}) {
		testing.expectf(t, strings.contains(md, expected), "missing %s", expected)
	}
}
