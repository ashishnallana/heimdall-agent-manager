package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import api_http "odin_test:hub/transport/http"
import user_vault_service "odin_test:hub/service/user_vault"

@(test)
test_user_vault_http_handlers_lifecycle :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-user-vault-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{
		database_path        = db_path,
		migrations_dir       = "src/hub/repository/sqlite/migrations",
		username_header      = "X-authentik-username",
		display_name_header  = "X-authentik-name",
		email_header         = "X-authentik-email",
		trusted_proxy_cidrs  = cidrs[:],
		auto_provision_users = true,
		logout_url           = "/_dev/logout",
		paddle_environment   = "sandbox",
	})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)

	user_headers := [?]contracts.HTTP_Header{{name = "X-authentik-username", value = "alice"}}

	// 1. Unauthenticated GET /api/v1/user/vault -> 401
	unauth_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "GET",
		path        = "/api/v1/user/vault",
		request_id  = "req_v_unauth",
		remote_addr = "127.0.0.1",
	})
	testing.expect_value(t, unauth_res.status, 401)

	// 2. Authenticated GET /api/v1/user/vault before setup -> 404
	not_found_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "GET",
		path        = "/api/v1/user/vault",
		request_id  = "req_v_404",
		remote_addr = "127.0.0.1",
		headers     = user_headers[:],
	})
	testing.expect_value(t, not_found_res.status, 404)
	testing.expect(t, strings.contains(not_found_res.body, "configured\":false") || strings.contains(not_found_res.body, "not_configured"), "404 response contains not_configured or configured:false")

	// 3. Authenticated POST /api/v1/user/vault with invalid payload (missing fields) -> 400
	bad_post := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "POST",
		path        = "/api/v1/user/vault",
		body        = `{"encrypted_vault_key":""}`,
		request_id  = "req_v_bad",
		remote_addr = "127.0.0.1",
		headers     = user_headers[:],
	})
	testing.expect_value(t, bad_post.status, 400)

	// 4. Authenticated POST /api/v1/user/vault with valid payload -> 200
	valid_body := `{"encrypted_vault_key":"abc123enc","vault_key_nonce":"nonce456","vault_key_tag":"tag789","kdf_algorithm":"PBKDF2-SHA256","kdf_salt":"salt321","kdf_iterations":100000,"recovery_encrypted_vault_key":"recabc123","recovery_nonce":"recnonce456","recovery_tag":"rectag789","recovery_salt":"recsalt321"}`
	good_post := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "POST",
		path        = "/api/v1/user/vault",
		body        = valid_body,
		request_id  = "req_v_good",
		remote_addr = "127.0.0.1",
		headers     = user_headers[:],
	})
	testing.expect_value(t, good_post.status, 200)
	testing.expect(t, strings.contains(good_post.body, "\"configured\":true"), "POST response contains configured:true")
	testing.expect(t, strings.contains(good_post.body, "\"encrypted_vault_key\":\"abc123enc\""), "POST response contains encrypted_vault_key")

	// 5. Authenticated GET /api/v1/user/vault after setup -> 200 with stored envelopes
	get_ok_res := api_http.router_dispatch(&graph.router, api_http.Request{
		method      = "GET",
		path        = "/api/v1/user/vault",
		request_id  = "req_v_ok",
		remote_addr = "127.0.0.1",
		headers     = user_headers[:],
	})
	testing.expect_value(t, get_ok_res.status, 200)
	testing.expect(t, strings.contains(get_ok_res.body, "\"configured\":true"), "GET response contains configured:true")
	testing.expect(t, strings.contains(get_ok_res.body, "\"encrypted_vault_key\":\"abc123enc\""), "GET response contains encrypted_vault_key")
	testing.expect(t, strings.contains(get_ok_res.body, "\"kdf_iterations\":100000"), "GET response contains kdf_iterations")
	testing.expect(t, strings.contains(get_ok_res.body, "\"recovery_encrypted_vault_key\":\"recabc123\""), "GET response contains recovery envelope")
}

@(test)
test_user_vault_service_direct :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-uv-service-%d.db", os.get_pid())
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	cidrs := [?]string{"127.0.0.1/32"}
	graph: app.App_Graph
	ok, msg := app.build_graph(&graph, app.Hub_Config{
		database_path        = db_path,
		migrations_dir       = "src/hub/repository/sqlite/migrations",
		trusted_proxy_cidrs  = cidrs[:],
		auto_provision_users = true,
		paddle_environment   = "sandbox",
	})
	testing.expect(t, ok, msg)
	defer app.shutdown_graph(&graph)

	// 1. Unauthenticated / empty user
	_, _, empty_err := user_vault_service.get_vault(&graph.user_vaults, "")
	testing.expect_value(t, empty_err.code, domain.Error_Code.Unauthenticated)

	// 2. Direct service get when unconfigured -> Not_Found
	_, found0, err0 := user_vault_service.get_vault(&graph.user_vaults, "bob")
	testing.expect(t, !found0, "unconfigured returns not found")
	testing.expect_value(t, err0.code, domain.Error_Code.Not_Found)

	// 3. Direct service set with validation error
	_, set_bad, val_err := user_vault_service.set_vault(&graph.user_vaults, domain.Set_User_Vault_Input{
		user_id = "bob",
		encrypted_vault_key = "",
	})
	testing.expect(t, !set_bad, "empty key rejected")
	testing.expect_value(t, val_err.code, domain.Error_Code.Validation_Failed)

	// 4. Direct service set with valid input
	saved, set_ok, set_err := user_vault_service.set_vault(&graph.user_vaults, domain.Set_User_Vault_Input{
		user_id                      = "bob",
		encrypted_vault_key          = "bob_vault_key",
		vault_key_nonce              = "bob_nonce",
		vault_key_tag                = "bob_tag",
		kdf_algorithm                = "PBKDF2-SHA256",
		kdf_salt                     = "bob_salt",
		kdf_iterations               = 100000,
		recovery_encrypted_vault_key = "bob_rec_key",
		recovery_nonce               = "bob_rec_nonce",
		recovery_tag                 = "bob_rec_tag",
		recovery_salt                = "bob_rec_salt",
	})
	testing.expect(t, set_ok, "valid set succeeds")
	testing.expect_value(t, set_err.code, domain.Error_Code.None)
	testing.expect_value(t, string(saved.user_id), "bob")

	// 5. Direct service get after set -> found
	retrieved, found1, get_err := user_vault_service.get_vault(&graph.user_vaults, "bob")
	testing.expect(t, found1, "retrieved vault found")
	testing.expect_value(t, get_err.code, domain.Error_Code.None)
	testing.expect_value(t, retrieved.encrypted_vault_key, "bob_vault_key")
	testing.expect_value(t, retrieved.kdf_iterations, 100000)
}

