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
