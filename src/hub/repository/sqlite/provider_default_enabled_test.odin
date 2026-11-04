#+private file
package sqlite

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import provider "odin_test:hub/service/provider"

// One source of truth for "enabled": with no explicit per-bridge setting, a PRESENT provider whose
// profile is enabled is runtime-enabled (list, profile and launch agree). An explicit setting wins.
@(test)
test_provider_default_enabled_when_present_and_explicit_setting_overrides :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	testing.expect(t,exec(&conn,"INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES ('def-a','alice','','');"))
	impl: Provider_Repo_SQLite
	repo := new_provider_repository(&impl,&conn)
	svc := provider.new_provider_service(&repo)
	defer delete(svc.test_runs)
	// Fresh bridge: codex present, claude absent, no settings rows at all.
	_,err := iface.bridge_provider_status_upsert(&repo,{bridge_id="def-a",provider="codex",binary_path="/bin/codex",state="present"})
	testing.expect_value(t,err.code,domain.Error_Code.None)
	_,err = iface.bridge_provider_status_upsert(&repo,{bridge_id="def-a",provider="claude",state="absent"})
	testing.expect_value(t,err.code,domain.Error_Code.None)

	enabled_of :: proc(t: ^testing.T, svc: ^provider.Provider_Service, name: string) -> bool {
		views,verr := provider.list_bridge_providers(svc,"def-a")
		testing.expect_value(t,verr.code,domain.Error_Code.None)
		defer provider.bridge_provider_views_destroy(views)
		for v in views do if v.catalog.provider==name && v.profile_id==name do return v.enabled
		return false
	}
	testing.expect(t,enabled_of(t,&svc,"codex"),"present provider is enabled by default")
	testing.expect(t,!enabled_of(t,&svc,"claude"),"absent provider is not enabled")

	// Explicit runtime disable is an override and sticks.
	_,_,serr := provider.set_bridge_provider_enabled(&svc,"def-a","codex","2026-11-04T00:00:00Z",false)
	testing.expect_value(t,serr.code,domain.Error_Code.None)
	testing.expect(t,!enabled_of(t,&svc,"codex"),"explicit disable overrides the default")
	_,_,serr = provider.set_bridge_provider_enabled(&svc,"def-a","codex","2026-11-04T00:00:01Z",true)
	testing.expect_value(t,serr.code,domain.Error_Code.None)
	testing.expect(t,enabled_of(t,&svc,"codex"),"explicit enable restores it")
}
