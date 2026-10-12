package main

import "core:testing"

@(test)
bridge_provider_catalog_name_supported_accepts_slugs_only :: proc(t: ^testing.T) {
	for name in ([]string{"claude", "codex", "copilot", "antigravity", "pi", "open-code", "gpt5"}) {
		testing.expectf(t, bridge_provider_catalog_name_supported(name), "%q should be a supported provider slug", name)
	}
	for name in ([]string{"", "Claude", "pi agent", "-pi", "pi-", "pi/x", "a-very-long-provider-name-over-32b"}) {
		testing.expectf(t, !bridge_provider_catalog_name_supported(name), "%q should be rejected", name)
	}
}

@(test)
bridge_provider_catalog_valid_accepts_any_provider_count :: proc(t: ^testing.T) {
	models := []Bridge_Catalog_Model{{model_id = "m1", label = "M1", state = "active"}}
	providers := []Bridge_Catalog_Provider{
		{provider = "claude", display_name = "Claude Code", binary = "claude", state = "active", models = models},
		{provider = "codex", display_name = "Codex", binary = "codex", state = "active", models = models},
		{provider = "copilot", display_name = "GitHub Copilot", binary = "copilot", state = "active", models = models},
		{provider = "antigravity", display_name = "Antigravity", binary = "agy", state = "active", models = models},
		{provider = "pi", display_name = "Pi", binary = "pi", state = "active", models = models},
	}
	testing.expect(t, bridge_provider_catalog_valid({providers = providers}), "five-provider catalog (with pi) is valid")
	testing.expect(t, bridge_provider_catalog_valid({providers = providers[:1]}), "single-provider catalog is valid")
	testing.expect(t, !bridge_provider_catalog_valid({}), "empty catalog is rejected")

	duplicate := []Bridge_Catalog_Provider{providers[0], providers[0]}
	testing.expect(t, !bridge_provider_catalog_valid({providers = duplicate}), "duplicate provider is rejected")

	bad_name := []Bridge_Catalog_Provider{{provider = "Pi Agent", display_name = "Pi", binary = "pi", state = "active", models = models}}
	testing.expect(t, !bridge_provider_catalog_valid({providers = bad_name}), "malformed provider name is rejected")

	no_models := []Bridge_Catalog_Provider{{provider = "pi", display_name = "Pi", binary = "pi", state = "active"}}
	testing.expect(t, !bridge_provider_catalog_valid({providers = no_models}), "provider without models is rejected")
}
