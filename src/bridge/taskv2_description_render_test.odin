package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

@(private = "file")
desc_pack :: proc(description: string, goal := "KEEP_THE_BRIEF_GOAL", extra := "") -> string {
	return strings.concatenate({
		`{"task_id":"task_d","lease":{"lease_id":"lease_1","kind":"work"},`,
		`"task":{"task_id":"task_d","title":"Describe me","description":"`, description, `"},`,
		`"brief":{"goal":"`, goal, `","acceptance":["KEEP_ACCEPTANCE_ONE","KEEP_ACCEPTANCE_TWO"],"verify":"pytest -q"},`,
		`"chain":{"summary":"CHAIN_SUMMARY_TEXT"}`, extra, `}`,
	}, context.temp_allocator)
}

// REQ-TMD-1: the description gets its own section right after the brief.
@(test)
test_bridge_taskv2_render_task_md_description :: proc(t: ^testing.T) {
	md := bridge_taskv2_render_task_md(desc_pack(`DESCRIPTION_LINE_ONE\nDESCRIPTION_LINE_TWO`), 32_000)
	defer delete(md)
	testing.expect(t, strings.contains(md, "\n## Description\nDESCRIPTION_LINE_ONE\nDESCRIPTION_LINE_TWO\n"), md)
	brief := strings.index(md, "## Brief")
	section := strings.index(md, "## Description")
	verify := strings.index(md, "**Verify**: `pytest -q`")
	chain := strings.index(md, "## Chain Summary")
	testing.expect(t, brief >= 0 && brief < verify && verify < section && section < chain, "Description sits between the brief and the chain summary")
	testing.expect(t, !strings.contains(md, "description truncated"), "no trailer when it fits")
}

// REQ-TMD-1: a vault:v2 description is rendered as plaintext.
@(test)
test_bridge_taskv2_render_task_md_description_decrypted :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.allocator)
	defer {
		if had_key {
			_ = os.set_env("HEIMDALL_VAULT_KEYRING", prev_key)
		} else {
			os.unset_env("HEIMDALL_VAULT_KEYRING")
		}
		delete(prev_key)
	}
	key := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	_ = os.set_env("HEIMDALL_VAULT_KEYRING", test_keyring_env_value(key))

	token := test_vault_seal("SECRET_DESCRIPTION_PLAINTEXT", key, allocator = context.temp_allocator)
	md := bridge_taskv2_render_task_md(desc_pack(token), 32_000)
	defer delete(md)
	testing.expect(t, strings.contains(md, "\n## Description\nSECRET_DESCRIPTION_PLAINTEXT\n"), md)
	testing.expect(t, !strings.contains(md, "vault:v2"), "no ciphertext in TASK.md")
}

// REQ-TMD-2: no description, no heading; the rest of the document is unchanged.
@(test)
test_bridge_taskv2_render_task_md_description_empty :: proc(t: ^testing.T) {
	empty := bridge_taskv2_render_task_md(desc_pack(""), 32_000)
	defer delete(empty)
	testing.expect(t, !strings.contains(empty, "## Description"), "empty description: no heading")

	blank := bridge_taskv2_render_task_md(desc_pack("  "), 32_000)
	defer delete(blank)
	testing.expect(t, !strings.contains(blank, "## Description"), "blank description: no heading")

	missing := bridge_taskv2_render_task_md(`{"task_id":"task_d","task":{"task_id":"task_d","title":"Describe me"},"brief":{"goal":"g"}}`, 32_000)
	defer delete(missing)
	testing.expect(t, !strings.contains(missing, "## Description"), "missing description: no heading")

	// Without the section the output is byte-for-byte what it was with "".
	with := bridge_taskv2_render_task_md(desc_pack("SOME_DESCRIPTION"), 32_000)
	defer delete(with)
	section := "\n## Description\nSOME_DESCRIPTION\n"
	testing.expect(t, strings.contains(with, section), with)
	stripped, _ := strings.replace(with, section, "", 1, context.temp_allocator)
	testing.expect_value(t, stripped, empty)

	// No goal: the goal line falls back to the description, so it is not repeated.
	fallback := bridge_taskv2_render_task_md(desc_pack("ONLY_DESCRIPTION", goal = ""), 32_000)
	defer delete(fallback)
	testing.expect(t, strings.contains(fallback, "**Goal**: ONLY_DESCRIPTION"), fallback)
	testing.expect(t, !strings.contains(fallback, "## Description"), "no duplicate Description section")
}

// REQ-TMD-3: a large description is cut to fit, with a trailer; goal and
// acceptance stay, and inputs are dropped before the description is touched.
@(test)
test_bridge_taskv2_render_task_md_description_truncated :: proc(t: ^testing.T) {
	big := strings.repeat("D", 20_000, context.temp_allocator)
	description := strings.concatenate({"DESC_HEAD_", big, "_DESC_TAIL"}, context.temp_allocator)
	input_body := strings.repeat("I", 2_000, context.temp_allocator)
	extra := strings.concatenate({`,"inputs":[{"ref":"#7","resolved":true,"data":"INPUT_BODY_`, input_body, `"}]`}, context.temp_allocator)
	pack := desc_pack(description, extra = extra)

	full := bridge_taskv2_render_task_md(pack, 32_000)
	defer delete(full)
	testing.expect(t, strings.contains(full, "_DESC_TAIL") && strings.contains(full, "INPUT_BODY_"), "fits uncapped")

	// Over budget by less than the input: only the input goes.
	budget := len(full) - 100
	light := bridge_taskv2_render_task_md(pack, budget)
	defer delete(light)
	testing.expect(t, !strings.contains(light, "INPUT_BODY_"), "input dropped first")
	testing.expect(t, strings.contains(light, "_DESC_TAIL") && !strings.contains(light, "description truncated"), "description untouched")

	// Over budget by much more: the description is cut to fit.
	budget = 12_000
	capped := bridge_taskv2_render_task_md(pack, budget)
	defer delete(capped)
	testing.expectf(t, len(capped) <= budget, "fits the cap: %d > %d", len(capped), budget)
	testing.expect(t, strings.contains(capped, "\n## Description\nDESC_HEAD_"), "head kept")
	testing.expect(t, !strings.contains(capped, "_DESC_TAIL"), "tail cut")
	testing.expect(t, strings.contains(capped, "_(description truncated — run `ham-ctl task show task_d` for the full text)_\n"), capped[:min(len(capped), 400)])
	testing.expect(t, strings.contains(capped, "**Goal**: KEEP_THE_BRIEF_GOAL"), "goal kept")
	testing.expect(t, strings.contains(capped, "- KEEP_ACCEPTANCE_ONE\n- KEEP_ACCEPTANCE_TWO\n"), "acceptance kept")
	testing.expect(t, !strings.contains(capped, "INPUT_BODY_"), "input dropped too")

	// A budget below everything else still keeps a bounded head, never the brief's expense.
	tiny := bridge_taskv2_render_task_md(pack, 100)
	defer delete(tiny)
	testing.expect(t, strings.contains(tiny, "**Goal**: KEEP_THE_BRIEF_GOAL") && strings.contains(tiny, "KEEP_ACCEPTANCE_TWO"), "brief kept")
	testing.expect(t, strings.contains(tiny, "description truncated"), "trailer")
	testing.expect(t, strings.contains(tiny, "DESC_HEAD_"), "a head is kept")
}

@(test)
test_bridge_taskv2_utf8_head :: proc(t: ^testing.T) {
	s := "ab€cd" // € is 3 bytes at [2:5]
	testing.expect_value(t, bridge_taskv2_utf8_head(s, 3), "ab")
	testing.expect_value(t, bridge_taskv2_utf8_head(s, 4), "ab")
	testing.expect_value(t, bridge_taskv2_utf8_head(s, 5), "ab€")
	testing.expect_value(t, bridge_taskv2_utf8_head(s, 99), s)
	testing.expect_value(t, bridge_taskv2_utf8_head(s, 0), "")
}
