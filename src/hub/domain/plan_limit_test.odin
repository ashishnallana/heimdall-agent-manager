package domain

import "core:encoding/json"
import "core:strings"
import "core:testing"

@(test)
test_plan_limit_error_details_escape_user_visible_values :: proc(t: ^testing.T) {
	err := plan_limit_error("max_bridges", 1, 2, "Custom \"agreement\"\n")
	testing.expect_value(t, err.code, Error_Code.Plan_Limit_Reached)
	testing.expect(t, strings.contains(err.message, "Upgrade"))
	details: struct {limit: string, allowed: int, current: int, plan_label: string, upgrade_path: string}
	testing.expect(t, json.unmarshal_string(err.details_json, &details, .JSON, context.temp_allocator) == nil)
	testing.expect_value(t, details.limit, "max_bridges")
	testing.expect_value(t, details.allowed, 1)
	testing.expect_value(t, details.current, 2)
	testing.expect_value(t, details.plan_label, "Custom \"agreement\"\n")
	testing.expect_value(t, details.upgrade_path, "/settings/account")
}
