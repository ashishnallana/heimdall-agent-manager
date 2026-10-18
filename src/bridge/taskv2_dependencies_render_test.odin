package main

import "core:strings"
import "core:testing"

@(private = "file")
DEP_PACK :: `{"version":1,"lease_id":"lease_1","task_id":"task_b","attempt_no":1,"max_attempts":5,` +
	`"lease":{"lease_id":"lease_1","kind":"work"},` +
	`"task":{"task_id":"task_b","title":"Rotate refresh tokens"},` +
	`"brief":{"goal":"KEEP_THE_BRIEF_GOAL","acceptance":["rotation works"],"verify":"pytest -q"},` +
	`"chain":{"summary":""},"inputs":[],` +
	`"dependencies":[` +
	`{"task_id":"task_a","title":"Add refresh_tokens table","state":"done","attempt_no":2,"summary":"DEP_SUMMARY_TABLE_ADDED",` +
	`"decisions":["hash with sha256"],"dead_ends":["DEP_DEAD_END_BCRYPT"],"next_steps":["wire rotation"],` +
	`"output":{"blob":"DEP_OUTPUT_BODY_` + "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" + `"},` +
	`"head":"abc123","verify":{"cmd":"pytest -q","exit_code":0}},` +
	`{"task_id":"task_c","title":"Spike","state":"cancelled","summary":"","decisions":[],"dead_ends":[],"next_steps":[]}` +
	`],"where_you_are":null,"previous_attempt":null,"findings":[],"why":"first_grant","protocol":{"rules":[]}}`

@(test)
test_bridge_taskv2_render_task_md_dependencies :: proc(t: ^testing.T) {
	md := bridge_taskv2_render_task_md(DEP_PACK, 32_000)
	defer delete(md)
	testing.expect(t, strings.contains(md, "## From The Tasks This One Waits For"), "section present")
	testing.expect(t, strings.contains(md, "### task_a: Add refresh_tokens table (done)"), "dependency heading")
	testing.expect(t, strings.contains(md, "**Handoff Summary**: DEP_SUMMARY_TABLE_ADDED"), "summary")
	testing.expect(t, strings.contains(md, "  - DEP_DEAD_END_BCRYPT"), "dead ends")
	testing.expect(t, strings.contains(md, "**Last Commit**: `abc123` (see what it changed with `git show --stat abc123`)"), "last commit + how to see the change")
	testing.expect(t, strings.contains(md, "**Verify**: `pytest -q` exit_code=`0`"), "verify")
	testing.expect(t, strings.contains(md, "DEP_OUTPUT_BODY_"), "uncapped output inline")
	testing.expect(t, strings.contains(md, "### task_c: Spike (cancelled)") && strings.contains(md, "was **cancelled**"), "cancelled dependency flagged")
	// The section sits between the chain summary and the protocol rules.
	testing.expect(t, strings.index(md, "## Chain Summary") < strings.index(md, "## From The Tasks"), "after chain summary")

	// Under a tight budget the dependency output goes first; summary, dead ends
	// and the brief stay.
	capped := bridge_taskv2_render_task_md(DEP_PACK, len(md) - 10)
	defer delete(capped)
	testing.expect(t, !strings.contains(capped, "DEP_OUTPUT_BODY_"), "output dropped for size")
	testing.expect(t, strings.contains(capped, "ham-ctl task fetch task_b output:task_a"), "fetch pointer for the dropped output")
	testing.expect(t, strings.contains(capped, "DEP_SUMMARY_TABLE_ADDED") && strings.contains(capped, "DEP_DEAD_END_BCRYPT"), "summary + dead ends kept")
	testing.expect(t, strings.contains(capped, "KEEP_THE_BRIEF_GOAL"), "brief kept")

	// No dependencies: no section.
	plain := bridge_taskv2_render_task_md(`{"task_id":"t","task":{"title":"x"},"brief":{"goal":"g"},"dependencies":[]}`, 32_000)
	defer delete(plain)
	testing.expect(t, !strings.contains(plain, "From The Tasks This One Waits For"), "no section without dependencies")
}
