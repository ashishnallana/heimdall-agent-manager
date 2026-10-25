package main

// REQ-BE-2/3: device enrollment onto an EXISTING bridge ("reuse identity") through
// the production endpoints and the real device_bridge_minter (app/wiring.odin):
//
//   - approve with target_bridge_id reuses that bridge_id; the swap happens on commit,
//     and only then is the bridge's previous vault identity retired;
//   - a target the approver does not own, or that is revoked, is refused (404, the
//     same anti-enumeration shape as a missing bridge);
//   - /device/verify serves previous_bridge_id only when it names one of the
//     approver's live bridges, plus the approver's reusable_bridges;
//   - rolling back a pending attach leaves the old bridge, its credential and its
//     vault identity exactly as they were.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import api_http "odin_test:hub/transport/http"
import bridge_service "odin_test:hub/service/bridge"


attach_test_graph :: proc(t: ^testing.T, graph: ^app.App_Graph, name: string) -> (db_path: string, ok: bool) {
	db_path = fmt.tprintf("%s/heimdall-hub-test-attach-%s-%d.db", os.get_env("TEMP", context.temp_allocator) if ODIN_OS == .Windows else "/tmp", name, os.get_pid())
	_ = os.remove(db_path)
	built, msg := app.build_graph(graph, app.Hub_Config{
		database_path        = db_path,
		migrations_dir       = "src/hub/repository/sqlite/migrations",
		auto_provision_users = true,
		paddle_environment   = "sandbox",
	})
	testing.expect(t, built, msg)
	return db_path, built
}

// The attach_* helpers below are shared with device_enroll_reuse_integration_test.odin.

// Attach_Enrollment is one device-flow enrollment driven up to the token poll.
Attach_Enrollment :: struct {
	verify_status:  int,
	verify_body:    string,
	approve_status: int,
	approve_body:   string,
	bridge_id:      string, // from the poll; "" when approval was refused
	access_token:   string,
	refresh_token:  string,
	identity_id:    string, // the vault device id of the new bridge identity
}

// attach_enroll authorizes a bridge grant (optionally carrying a previous_bridge_id
// hint), resolves it on /device/verify as the approver, approves it (optionally onto
// target_bridge_id) and, if approved, polls its credential. Nothing is committed.
attach_enroll :: proc(graph: ^app.App_Graph, headers: []contracts.HTTP_Header, label: string, target_bridge_id := "", previous_bridge_id := "", root_seed: u16 = VT_ROOT_SEED) -> (out: Attach_Enrollment, ok: bool) {
	user_id, version, vault_ok := vt_ensure_vault(graph, headers, root_seed)
	if !vault_ok do return out, false
	br, approval := vt_bridge_approval(graph, user_id, version, root_seed)
	out.identity_id = br.id
	pair_lookup := vt_lookup(br.sign_pub)
	hint := ""
	if previous_bridge_id != "" do hint = strings.concatenate({`,"previous_bridge_id":"`, previous_bridge_id, `"`}, context.temp_allocator)
	authorize_body := strings.concatenate({
		`{"client":"ham-bridge","device_label":"`, label,
		`","os":"linux","os_user":"tester","bridge_public_key":"`, DEVICE_TEST_PUBLIC_KEY,
		`","bridge_identity_public_key":"`, br.sign_pub,
		`","bridge_identity_proof":`, vt_enroll_proof(&br, DEVICE_TEST_PUBLIC_KEY, DEVICE_TEST_CODE_CHALLENGE),
		`,"code_challenge":"`, DEVICE_TEST_CODE_CHALLENGE, `","code_challenge_method":"S256","pair_salt":"0123456789abcdef0123456789abcdef","pair_hub_origin":"https://hub.example.test:443","pair_lookup":"`, pair_lookup, `","pair_key_mac":"`, vt_lookup(strings.concatenate({"mac|", br.sign_pub}, context.temp_allocator)), `"`, hint, `}`,
	}, context.temp_allocator)
	authorized := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/device/authorize", body = authorize_body,
		request_id = "req_attach_authorize", remote_addr = "127.0.0.1",
	})
	if authorized.status != 200 do return out, false
	device_code := device_test_json_string(authorized.body, "device_code")

	verified := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/device/verify", body = strings.concatenate({`{"pair_lookup":"`, pair_lookup, `"}`}, context.temp_allocator),
		request_id = "req_attach_verify", remote_addr = "127.0.0.1", headers = headers,
	})
	out.verify_status, out.verify_body = verified.status, verified.body

	target := ""
	if target_bridge_id != "" do target = strings.concatenate({`,"target_bridge_id":"`, target_bridge_id, `"`}, context.temp_allocator)
	approved := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/device/approve",
		body = strings.concatenate({`{"pair_lookup":"`, pair_lookup, `","approve":true`, target, `,"vault_approval":`, approval, `}`}, context.temp_allocator),
		request_id = "req_attach_approve", remote_addr = "127.0.0.1", headers = headers,
	})
	out.approve_status, out.approve_body = approved.status, approved.body
	if approved.status != 200 do return out, true

	issued := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = "/api/v1/device/token",
		body = strings.concatenate({`{"device_code":"`, device_code, `","code_verifier":"`, DEVICE_TEST_CODE_VERIFIER, `"}`}, context.temp_allocator),
		request_id = "req_attach_token", remote_addr = "127.0.0.1",
	})
	if issued.status != 200 do return out, false
	out.bridge_id = device_test_json_string(issued.body, "bridge_id")
	out.access_token = device_test_json_string(issued.body, "access_token")
	out.refresh_token = device_test_json_string(issued.body, "refresh_token")
	return out, out.bridge_id != "" && out.access_token != ""
}

// attach_commit commits the bridge's pending enrollment through the PRODUCTION commit
// (api_http.bridge_enroll_commit, what the unseal relay calls on ok:true), with the
// enroll-only socket's hello recorded as a connecting bridge would.
attach_commit :: proc(graph: ^app.App_Graph, bridge_id: string) -> bool {
	family_id := ""
	pending, err := iface.bridge_list_live_tokens_by_scope(graph.bridges.repo, bridge_service.BRIDGE_ENROLL_TOKEN_SCOPE)
	if err.code != .None do return false
	for tok in pending do if tok.bridge_id == bridge_id do family_id = strings.clone(tok.family_id, context.temp_allocator)
	for &tok in pending do domain.bridge_token_destroy(&tok)
	delete(pending)
	if family_id == "" do return false
	api_http.bridge_enroll_hello_store(bridge_id, api_http.Bridge_Enroll_Hello{generation = 1, family_id = family_id, hostname = "attached-host", os = "linux", version = "9.9.9", public_key = DEVICE_TEST_PUBLIC_KEY})
	bridge, ok, _ := iface.bridge_get_bridge(graph.bridges.repo, bridge_id)
	if !ok do return false
	defer domain.bridge_destroy(&bridge)
	commit_err, committed := api_http.bridge_enroll_commit(&graph.bridge_handlers, bridge)
	return committed && commit_err.code == .None
}

attach_vault_row :: proc(graph: ^app.App_Graph, user_id, device_id: string) -> (domain.Vault_Device, bool) {
	devices, err := iface.vault_list_devices(graph.vault_directory.repo, user_id)
	if err.code != .None do return {}, false
	for d in devices do if d.device_id == device_id do return d, true
	return {}, false
}

attach_token_works :: proc(graph: ^app.App_Graph, token: string) -> bool {
	_, ok, _ := bridge_service.verify_bridge_token(&graph.bridges, token)
	return ok
}

@(test)
test_device_attach_reuses_bridge_id_and_retires_old_identity_on_commit :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path, built := attach_test_graph(t, &graph, "commit")
	defer _ = os.remove(db_path)
	if !built do return
	defer app.shutdown_graph(&graph)
	alice := hub_test_user_headers(&graph, "alice")
	user_id := vt_user_id(&graph, alice[:])

	first, first_ok := attach_enroll(&graph, alice[:], "alice-box")
	testing.expect(t, first_ok && first.approve_status == 200, first.approve_body)
	if !first_ok do return
	testing.expect(t, attach_commit(&graph, first.bridge_id), "first enrollment commits")
	testing.expect(t, attach_token_works(&graph, first.access_token), "the first device's credential works")

	// The re-enrolling machine hints its previous id; the approver reuses it.
	second, second_ok := attach_enroll(&graph, alice[:], "alice-box", target_bridge_id = first.bridge_id, previous_bridge_id = first.bridge_id)
	testing.expect(t, second_ok, second.approve_body)
	if !second_ok do return
	testing.expect_value(t, second.verify_status, 200)
	testing.expect(t, strings.contains(second.verify_body, fmt.tprintf(`"previous_bridge_id":"%s"`, first.bridge_id)), second.verify_body)
	testing.expect(t, strings.contains(second.verify_body, strings.concatenate({`"reusable_bridges":[{"bridge_id":"`, first.bridge_id, `","label":"alice-box","machine_hostname":"alice-box","status":"offline","last_seen":"`}, context.temp_allocator)), second.verify_body)
	testing.expect_value(t, second.bridge_id, first.bridge_id)

	// Still pending: nothing about the old device has changed yet.
	testing.expect(t, attach_token_works(&graph, first.access_token), "the old credential works until the attach commits")
	old_row, _ := attach_vault_row(&graph, user_id, first.identity_id)
	testing.expect_value(t, old_row.retired_at, "")

	testing.expect(t, attach_commit(&graph, second.bridge_id), "the attach commits")
	testing.expect(t, !attach_token_works(&graph, first.access_token), "the old credential is revoked by the commit")
	testing.expect(t, attach_token_works(&graph, second.access_token), "the new device's credential is live")
	old_row, _ = attach_vault_row(&graph, user_id, first.identity_id)
	testing.expect(t, old_row.retired_at != "", "the superseded vault identity is hinted retired on commit")
	testing.expect_value(t, old_row.status, domain.Vault_Device_Status.Approved)
	new_row, _ := attach_vault_row(&graph, user_id, second.identity_id)
	testing.expect_value(t, new_row.retired_at, "")
	testing.expect_value(t, new_row.bridge_id, first.bridge_id)

	bridges, _ := bridge_service.list_bridges(&graph.bridges, contracts.Auth_Context{user_id = user_id})
	testing.expect_value(t, len(bridges), 1)
}

@(test)
test_device_attach_rollback_leaves_old_bridge_intact :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path, built := attach_test_graph(t, &graph, "rollback")
	defer _ = os.remove(db_path)
	if !built do return
	defer app.shutdown_graph(&graph)
	alice := hub_test_user_headers(&graph, "alice")
	user_id := vt_user_id(&graph, alice[:])

	first, first_ok := attach_enroll(&graph, alice[:], "alice-box")
	if !first_ok || !attach_commit(&graph, first.bridge_id) {
		testing.fail_now(t, "first enrollment failed")
	}
	pending, pending_ok := attach_enroll(&graph, alice[:], "alice-box", target_bridge_id = first.bridge_id)
	testing.expect(t, pending_ok && pending.bridge_id == first.bridge_id, pending.approve_body)

	// A second attach onto the same bridge while one is pending is refused, and the
	// refusal rolls back only its own family: the first pending attach survives.
	clash, _ := attach_enroll(&graph, alice[:], "alice-box", target_bridge_id = first.bridge_id)
	testing.expect_value(t, clash.approve_status, 409)
	family, has_family, _ := bridge_service.pending_enrollment_family(&graph.bridges, first.bridge_id)
	testing.expect(t, has_family && family != "", "the first pending attach is still pending")

	cancelled := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = fmt.tprintf("/api/v1/bridges/%s/enrollment/cancel", first.bridge_id),
		request_id = "req_attach_cancel", remote_addr = "127.0.0.1", headers = alice[:],
	})
	testing.expect_value(t, cancelled.status, 200)
	testing.expect(t, strings.contains(cancelled.body, `"rolled_back":true`), cancelled.body)
	testing.expect(t, strings.contains(cancelled.body, `"row_deleted":false`), cancelled.body)

	testing.expect(t, attach_token_works(&graph, first.access_token), "the old credential survives the rollback")
	testing.expect(t, !attach_token_works(&graph, pending.access_token), "the attach's credential is dead")
	bridge, found, _ := iface.bridge_get_bridge(graph.bridges.repo, first.bridge_id)
	testing.expect(t, found && bridge.status != .Revoked, "the old bridge row survives")
	old_row, _ := attach_vault_row(&graph, user_id, first.identity_id)
	testing.expect_value(t, old_row.retired_at, "")
	testing.expect_value(t, old_row.status, domain.Vault_Device_Status.Approved)
	new_row, _ := attach_vault_row(&graph, user_id, pending.identity_id)
	testing.expect(t, new_row.retired_at != "", "the rolled-back identity is retired")
}

@(test)
test_device_attach_refuses_foreign_revoked_and_hides_unusable_hints :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path, built := attach_test_graph(t, &graph, "refuse")
	defer _ = os.remove(db_path)
	if !built do return
	defer app.shutdown_graph(&graph)
	alice := hub_test_user_headers(&graph, "alice")
	bob := hub_test_user_headers(&graph, "bob")

	alice_box, a_ok := attach_enroll(&graph, alice[:], "alice-box")
	if !a_ok || !attach_commit(&graph, alice_box.bridge_id) do testing.fail_now(t, "alice enrollment failed")

	// Bob hints and targets Alice's bridge: hint hidden, nothing reusable, refused.
	// Bob's own vault root: device ids are unique across accounts.
	stranger, _ := attach_enroll(&graph, bob[:], "bob-box", target_bridge_id = alice_box.bridge_id, previous_bridge_id = alice_box.bridge_id, root_seed = 2)
	testing.expect_value(t, stranger.verify_status, 200)
	testing.expect(t, strings.contains(stranger.verify_body, `"previous_bridge_id":""`), stranger.verify_body)
	testing.expect(t, strings.contains(stranger.verify_body, `"reusable_bridges":[]`), stranger.verify_body)
	testing.expect(t, !strings.contains(stranger.verify_body, alice_box.bridge_id), "nothing about the foreign bridge leaks")
	testing.expect_value(t, stranger.approve_status, 404)
	testing.expect(t, attach_token_works(&graph, alice_box.access_token), "alice's bridge is untouched")

	// A revoked bridge of Alice's own: hidden and refused.
	retired_box, r_ok := attach_enroll(&graph, alice[:], "old-box")
	if !r_ok || !attach_commit(&graph, retired_box.bridge_id) do testing.fail_now(t, "second enrollment failed")
	revoked := api_http.router_dispatch(&graph.router, api_http.Request{
		method = "POST", path = fmt.tprintf("/api/v1/bridges/%s/revoke", retired_box.bridge_id), request_id = "req_attach_revoke", remote_addr = "127.0.0.1", headers = alice[:],
	})
	testing.expect_value(t, revoked.status, 200)
	onto_revoked, _ := attach_enroll(&graph, alice[:], "old-box", target_bridge_id = retired_box.bridge_id, previous_bridge_id = retired_box.bridge_id)
	testing.expect(t, strings.contains(onto_revoked.verify_body, `"previous_bridge_id":""`), onto_revoked.verify_body)
	testing.expect(t, !strings.contains(onto_revoked.verify_body, fmt.tprintf(`"bridge_id":"%s"`, retired_box.bridge_id)), onto_revoked.verify_body)
	testing.expect(t, strings.contains(onto_revoked.verify_body, fmt.tprintf(`"bridge_id":"%s"`, alice_box.bridge_id)), "alice's live bridge is offered")
	testing.expect_value(t, onto_revoked.approve_status, 404)

	// A still-pending enrollment is neither offered nor shown as the hint.
	pending_box, p_ok := attach_enroll(&graph, alice[:], "pending-box")
	testing.expect(t, p_ok, pending_box.approve_body)
	hinted_pending, _ := attach_enroll(&graph, alice[:], "pending-box", previous_bridge_id = pending_box.bridge_id)
	testing.expect(t, strings.contains(hinted_pending.verify_body, `"previous_bridge_id":""`), hinted_pending.verify_body)
	testing.expect(t, !strings.contains(hinted_pending.verify_body, fmt.tprintf(`"bridge_id":"%s"`, pending_box.bridge_id)), hinted_pending.verify_body)
}
