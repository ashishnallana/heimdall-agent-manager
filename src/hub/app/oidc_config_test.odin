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
