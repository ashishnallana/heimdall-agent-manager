package app

import "core:strings"
import "core:testing"

@(private = "file")
oidc_test_hub_config :: proc() -> Hub_Config {
	config := default_config()
	config.oidc_issuer = "https://auth.example.test/application/o/heimdall-native/"
	config.oidc_jwks_url = "https://auth.example.test/application/o/heimdall-native/jwks/"
	config.oidc_userinfo_url = "https://auth.example.test/application/o/userinfo/"
	config.oidc_api_audience = "heimdall-api"
	config.oidc_api_scope = "heimdall.api"
	return config
}

@(test)
test_oidc_config_validation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	off := default_config()
	ok, msg := validate_oidc_config(off)
	testing.expect(t, ok && !oidc_configured(off), "no OIDC settings: OIDC disabled, valid")

	full := oidc_test_hub_config()
	ok, msg = validate_oidc_config(full)
	testing.expect(t, ok && oidc_configured(full), msg)

	orphan := default_config()
	orphan.oidc_jwks_url = full.oidc_jwks_url
	ok, msg = validate_oidc_config(orphan)
	testing.expect(t, !ok && strings.contains(msg, "oidc_issuer"), "settings without an issuer fail closed")

	missing := [?]string{"jwks", "userinfo", "audience", "scope"}
	for name in missing {
		c := full
		switch name {
		case "jwks": c.oidc_jwks_url = ""
		case "userinfo": c.oidc_userinfo_url = ""
		case "audience": c.oidc_api_audience = ""
		case "scope": c.oidc_api_scope = ""
		}
		ok, msg = validate_oidc_config(c)
		testing.expect(t, !ok && strings.contains(msg, "is required"), name)
	}

	plain := full
	plain.oidc_jwks_url = "http://auth.example.test/jwks/"
	ok, msg = validate_oidc_config(plain)
	testing.expect(t, !ok && strings.contains(msg, "https://"), "provider endpoints must be https")

	web := full
	web.oidc_token_url = "http://auth.example.test/token/"
	ok, msg = validate_oidc_config(web)
	testing.expect(t, !ok && strings.contains(msg, "oidc_token_url"), "optional web endpoints must be https when set")

	spaced := full
	spaced.oidc_api_scope = "heimdall.api other"
	ok, msg = validate_oidc_config(spaced)
	testing.expect(t, !ok && strings.contains(msg, "whitespace"), "a single scope value is required")
}

@(test)
test_web_login_config_validation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	full := oidc_test_hub_config()
	full.ui_origin = "https://hub.example.test"
	full.oidc_authorize_url = "https://auth.example.test/application/o/authorize/"
	full.oidc_token_url = "https://auth.example.test/application/o/token/"
	full.oidc_web_client_id = "heimdall-web"
	ok, msg := validate_oidc_config(full)
	testing.expect(t, ok && web_login_configured(full), msg)
	testing.expect_value(t, web_redirect_uri(full), "https://hub.example.test/api/v1/auth/callback")

	bearer_only := oidc_test_hub_config()
	ok, msg = validate_oidc_config(bearer_only)
	testing.expect(t, ok && !web_login_configured(bearer_only), "bearer-only OIDC stays valid without browser login")

	partial := full
	partial.oidc_web_client_id = ""
	ok, msg = validate_oidc_config(partial)
	testing.expect(t, !ok && strings.contains(msg, "browser login needs"), "partial web client config fails closed")

	no_ui := full
	no_ui.ui_origin = ""
	ok, msg = validate_oidc_config(no_ui)
	testing.expect(t, !ok && strings.contains(msg, "ui_origin"), "browser login requires ui_origin (CSRF origin)")

	bad_redirect := full
	bad_redirect.oidc_redirect_uri = "http://hub.example.test/api/v1/auth/callback"
	ok, msg = validate_oidc_config(bad_redirect)
	testing.expect(t, !ok && strings.contains(msg, "oidc_redirect_uri"), "redirect must be https")
}

@(test)
test_loopback_http_url_is_exact :: proc(t: ^testing.T) {
	for url in ([]string{"http://localhost", "http://localhost:5173/api/v1/auth/callback", "http://127.0.0.1:8081", "http://[::1]:9000/x"}) {
		testing.expect(t, loopback_http_url(url), url)
	}
	for url in ([]string{"http://localhost.evil.example", "http://127.0.0.1.nip.io/cb", "http://localhost@evil.example/", "https://localhost", "http://[::1]evil", "http://localhost:80a", "http://evil.example/localhost"}) {
		testing.expect(t, !loopback_http_url(url), url)
	}
	config := oidc_test_hub_config()
	config.oidc_authorize_url = "https://auth.example.test/application/o/authorize/"
	config.oidc_token_url = "https://auth.example.test/application/o/token/"
	config.oidc_web_client_id = "heimdall-web"
	config.ui_origin = "http://hub.example.test"
	ok, msg := validate_oidc_config(config)
	testing.expect(t, !ok && strings.contains(msg, "ui_origin must be an https"), msg)
	// Loopback http is accepted only in the explicit dev mode.
	config.ui_origin = "http://localhost:8081"
	ok, msg = validate_oidc_config(config)
	testing.expect(t, !ok && strings.contains(msg, "HAM_OIDC_ALLOW_INSECURE_LOCALHOST"), msg)
	config.oidc_allow_insecure_localhost = true
	ok, msg = validate_oidc_config(config)
	testing.expect(t, ok, msg)
	config.ui_origin = "https://hub.example.test"
	config.oidc_redirect_uri = "http://localhost.evil.example/api/v1/auth/callback"
	ok, msg = validate_oidc_config(config)
	testing.expect(t, !ok, "prefix-matching localhost host is refused even in dev mode")
}

// Dev mode: http OIDC endpoints on an exact loopback host; never another host.
@(test)
test_insecure_localhost_mode_is_scoped :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	config := default_config()
	config.ui_origin = "http://127.0.0.1:8081"
	config.oidc_issuer = "http://127.0.0.1:9400/application/o/heimdall-native/"
	config.oidc_jwks_url = "http://127.0.0.1:9400/application/o/heimdall-native/jwks/"
	config.oidc_userinfo_url = "http://127.0.0.1:9400/application/o/userinfo/"
	config.oidc_api_audience = "heimdall-api"
	config.oidc_api_scope = "heimdall.api"
	config.oidc_authorize_url = "http://127.0.0.1:9400/application/o/authorize/"
	config.oidc_token_url = "http://127.0.0.1:9400/application/o/token/"
	config.oidc_web_client_id = "heimdall-native"
	ok, msg := require_oidc_config(config)
	testing.expect(t, !ok && strings.contains(msg, "https"), "http endpoints refused without the dev flag")
	config.oidc_allow_insecure_localhost = true
	ok, msg = require_oidc_config(config)
	testing.expect(t, ok, msg)
	config.oidc_jwks_url = "http://auth.example.test/jwks/"
	ok, msg = require_oidc_config(config)
	testing.expect(t, !ok, "dev mode never allows a non-loopback http endpoint")
}

// The server cannot start without OIDC bearer AND browser-login configuration.
@(test)
test_require_oidc_config :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	ok, msg := require_oidc_config(default_config())
	testing.expect(t, !ok && strings.contains(msg, "OIDC is required"), msg)
	bearer_only := oidc_test_hub_config()
	ok, msg = require_oidc_config(bearer_only)
	testing.expect(t, !ok && strings.contains(msg, "browser login is required"), msg)
	full := bearer_only
	full.ui_origin = "https://hub.example.test"
	full.oidc_authorize_url = "https://auth.example.test/application/o/authorize/"
	full.oidc_token_url = "https://auth.example.test/application/o/token/"
	full.oidc_web_client_id = "heimdall-native"
	ok, msg = require_oidc_config(full)
	testing.expect(t, ok, msg)
}
