// Unit coverage for the bridge-side conditional bootstrap helpers (BRG-1/BRG-2):
//   - manifest+ETag store round-trip per (agent,role,provider,project)
//   - descriptor parsing from the enriched launch_agent payload
//   - local AGENTS.md header rendering from the descriptor
//   - manifest hash collection (assembly + skills, in order)
//   - hash url-encoding for the per-hash blob GET path segment
package bridge_bootstrap_conditional_test

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import httpc "odin_test:lib/httpc"
import bridge "odin_test:bridge"

@(test)
test_bridge_bootstrap_conditional :: proc(t: ^testing.T) {
	_ = t
	main()
}

bridge_sha256 :: proc(body: string) -> string {
	buf: [32]byte
	hash.hash_string_to_buffer(.SHA256, body, buf[:])
	hex_str := hex.encode(buf[:])
	defer delete(hex_str)
	return strings.concatenate({"sha256:", string(hex_str)})
}

main :: proc() {
	tmp := "/tmp/heimdall-bridge-bootstrap-conditional-test"
	_ = os.remove_all(tmp)
	defer _ = os.remove_all(tmp)

	cache: bridge.Bootstrap_Cache
	bridge.bootstrap_cache_init(&cache, tmp, 8 * 1024 * 1024)

	// (1) manifest+ETag store round-trip.
	etag := "agt_x:worker:claude:proj_1:sha256:deadbeef"
	manifest := "{\"protocol\":2,\"version\":\"sha256:deadbeef\"}"
	check(bridge.bootstrap_manifest_store_save(&cache, "agt_x", "worker", "claude", "proj_1", etag, manifest), "manifest store save must succeed")
	got_etag, got_manifest, ok := bridge.bootstrap_manifest_store_load(&cache, "agt_x", "worker", "claude", "proj_1")
	check(ok, "manifest store load must find the saved key")
	check(got_etag == etag, "loaded ETag must match saved ETag")
	check(got_manifest == manifest, "loaded manifest must match saved manifest")
	// A different key must miss.
	_, _, miss := bridge.bootstrap_manifest_store_load(&cache, "agt_x", "coordinator", "claude", "proj_1")
	check(!miss, "different (role) key must not collide")

	// (2) descriptor parse from an enriched launch payload.
	launch := "{\"type\":\"launch_agent\",\"payload\":{\"agent_instance_id\":\"inst_1\",\"agent_id\":\"agt_x\",\"agent_name\":\"Backend\",\"role\":\"coordinator\",\"coordinator_agent_instance_id\":\"inst_1\",\"chain_id\":\"chain_9\",\"chain_title\":\"Cache work\",\"project_id\":\"proj_1\",\"project_path\":\"/repo\",\"conversation_id\":\"chat_1\",\"name\":\"claude\"}}"
	d := bridge.bridge_bootstrap_descriptor_from_launch(launch)
	check(d.instance_id == "inst_1", "descriptor instance_id")
	check(d.agent_id == "agt_x", "descriptor agent_id")
	check(d.agent_name == "Backend", "descriptor agent_name")
	check(d.role == "coordinator", "descriptor role")
	check(d.coordinator_id == "inst_1", "descriptor coordinator id")
	check(d.chain_title == "Cache work", "descriptor chain_title")
	check(d.project_id == "proj_1", "descriptor project_id")
	check(d.provider == "claude", "descriptor provider from name")

	// role defaults to worker when absent.
	d2 := bridge.bridge_bootstrap_descriptor_from_launch("{\"payload\":{\"agent_id\":\"agt_y\"}}")
	check(d2.role == "worker", "absent role defaults to worker")

	// (3) header render from descriptor (coordinator path).
	header := bridge.bridge_bootstrap_render_header(d)
	check(strings.contains(header, "# Agent bootstrap"), "header must have title")
	check(strings.contains(header, "Agent: Backend"), "header must name the agent")
	check(strings.contains(header, "Instance: inst_1"), "header must carry instance id")
	check(strings.contains(header, "Task chain: Cache work (chain_9)"), "header must carry chain title+id")
	check(strings.contains(header, "Coordinator: you (coordinator)"), "coordinator header must say you (coordinator)")
	// worker path shows the coordinator id.
	dw := d
	dw.role = "worker"
	dw.coordinator_id = "inst_boss"
	hw := bridge.bridge_bootstrap_render_header(dw)
	check(strings.contains(hw, "Coordinator: inst_boss"), "worker header must reference coordinator id")

	// (4) manifest hash collection (assembly + skills, in order).
	mj := "{\"files\":[{\"kind\":\"AGENTS_MD\",\"assembly\":[{\"section\":\"agent_identity\",\"hash\":\"sha256:aaa\"},{\"section\":\"memories\",\"hash\":\"sha256:bbb\"}]}],\"skills\":[{\"kind\":\"SKILL\",\"name\":\"s1\",\"hash\":\"sha256:ccc\"}]}"
	hashes := bridge.bridge_bootstrap_collect_manifest_hashes(mj)
	defer { for h in hashes do delete(h); delete(hashes) }
	check(len(hashes) == 3, "must collect all three hashes")
	check(hashes[0] == "sha256:aaa" && hashes[1] == "sha256:bbb" && hashes[2] == "sha256:ccc", "hashes must be in document order")

	// (5) a blob hash is ONE path segment: httpc percent-encodes its ':'.
	enc, enc_err := httpc.build_target({"api", "v1", "bridge", "blobs", "sha256:abc-123"}, allocator = context.temp_allocator)
	check(enc_err == .None && enc == "/api/v1/bridge/blobs/sha256%3Aabc-123", "a blob hash must be a single encoded segment")

	// (6) BRG-3 wrapper file-set store + list/file RPC JSON. Seed the disk cache
	// with the fragment/skill bodies the manifest references, then build the set.
	prev_ctl, had_ctl := os.lookup_env("HEIMDALL_HAM_CTL_BIN", context.allocator)
	defer {
		if had_ctl {
			_ = os.set_env("HEIMDALL_HAM_CTL_BIN", prev_ctl)
		} else {
			os.unset_env("HEIMDALL_HAM_CTL_BIN")
		}
		delete(prev_ctl)
	}
	_ = os.set_env("HEIMDALL_HAM_CTL_BIN", "/bin/sh")
	catalog_providers := [?]bridge.Bridge_Catalog_Provider{{
		provider = "claude",
		state = "active",
		skill_dir = ".claude/skills",
		bootstrap_file = "CLAUDE.md",
	}}
	catalog_snap := bridge.Bridge_Provider_Catalog_Snapshot{
		providers = catalog_providers[:],
	}
	bridge.bridge_provider_catalog_publish(&catalog_snap)
	id_body := "\n\n## Agent Identity & Instructions\nBe excellent."
	sk_body := "# skill one\nbody"
	id_hash := bridge_sha256(id_body)
	sk_hash := bridge_sha256(sk_body)
	check(bridge.bootstrap_cache_put(&cache, id_hash, id_body), "seed identity blob")
	check(bridge.bootstrap_cache_put(&cache, sk_hash, sk_body), "seed skill blob")
	mj2 := strings.concatenate({
		"{\"files\":[{\"kind\":\"AGENTS_MD\",\"assembly\":[{\"section\":\"agent_identity\",\"hash\":\"", id_hash, "\"}]}],",
		"\"skills\":[{\"kind\":\"SKILL\",\"name\":\"s1\",\"hash\":\"", sk_hash, "\"}]}",
	})
	files, res := bridge.bridge_bootstrap_build_file_set(mj2, dw, "unix:/tmp/x.sock", "hlat_test", "claude", &cache)
	check(res.ok, "file set build must succeed")
	// Expect AGENTS.md, one SKILL, CTL_WRAPPER, MANIFEST.
	kinds := map[string]bool{}
	for f in files { kinds[f.kind] = true }
	check(kinds["AGENTS_MD"] && kinds["SKILL"] && kinds["CTL_WRAPPER"] && kinds["MANIFEST"], "file set must contain all four kinds")
	delete(kinds)
	bridge.bridge_bootstrap_fileset_store_put(dw.instance_id, "claude", files[:])
	bridge.bridge_bootstrap_free_file_set(files)

	list_json, list_ok := bridge.bridge_bootstrap_fileset_list_json(dw.instance_id)
	check(list_ok, "list RPC must find the published set")
	check(strings.contains(list_json, "\"kind\":\"AGENTS_MD\"") && strings.contains(list_json, "\"relative_path\""), "list must expose kind + relative_path")
	check(!strings.contains(list_json, "\"content\""), "list must NOT include content")
	// ctl shim file_id is bin/ham-ctl with mode 0755 (493 decimal).
	check(strings.contains(list_json, "\"mode\":493"), "ctl shim must be mode 0755")
	// PROV-1: list must surface provider layout override values for the wrapper.
	check(strings.contains(list_json, "\"layout\"") && strings.contains(list_json, "\"skill_dir\"") && strings.contains(list_json, "\"bootstrap_file_name\""), "list must expose provider layout override values")

	file_json, file_ok := bridge.bridge_bootstrap_fileset_file_json(dw.instance_id, "CLAUDE.md")
	check(file_ok, "file RPC must return the AGENTS_MD file (CLAUDE.md for claude)")
	check(strings.contains(file_json, "Be excellent."), "file content must include the identity fragment body")
	check(strings.contains(file_json, "# Agent bootstrap"), "AGENTS.md must include the locally-rendered header")
	_, miss_ok := bridge.bridge_bootstrap_fileset_file_json(dw.instance_id, "nope")
	check(!miss_ok, "unknown file_id must miss")
	_, unknown_inst := bridge.bridge_bootstrap_fileset_list_json("inst_unknown")
	check(!unknown_inst, "unknown instance must miss")

	fmt.println("PASS: bridge bootstrap conditional")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
