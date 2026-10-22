package main

import "core:testing"
import contracts "odin_test:contracts"

@(test)
test_default_roster_has_free_default_and_paid_user :: proc(t: ^testing.T) {
	config := default_dev_proxy_config()
	defer delete(config.users)
	testing.expect_value(t, config.default_user, "tanmay")

	found_paid := false
	for user in config.users {
		if user.username == "paid" {
			found_paid = true
			testing.expect_value(t, user.display_name, "Paid User")
			testing.expect_value(t, user.email, "paid@example.com")
		}
	}
	testing.expect(t, found_paid, "default roster must include the paid seed user")

	headers := []contracts.HTTP_Header{{name = "X-Dev-User", value = "paid"}}
	selected, ok := select_dev_user(&config, headers, "")
	testing.expect(t, ok)
	testing.expect_value(t, selected.username, "paid")

	fallback, fallback_ok := select_dev_user(&config, nil, "")
	testing.expect(t, fallback_ok)
	testing.expect_value(t, fallback.username, "tanmay")
}
