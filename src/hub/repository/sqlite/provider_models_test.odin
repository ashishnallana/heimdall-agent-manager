#+private file
package sqlite

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import provider "odin_test:hub/service/provider"

@(test)
test_bridge_models_persistence_effective_launch_and_isolation :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	testing.expect(t,exec(&conn,"INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES ('models-a','alice','',''),('models-b','bob','','');"))
	impl: Provider_Repo_SQLite
	repo := new_provider_repository(&impl,&conn)
	svc := provider.new_provider_service(&repo)
	defer delete(svc.test_runs)
	for bid in ([]string{"models-a","models-b"}) {
		_,err := iface.bridge_provider_status_upsert(&repo,{bridge_id=bid,provider="codex",binary_path="/bin/codex",state="present"})
		testing.expect_value(t,err.code,domain.Error_Code.None)
		_,err = iface.bridge_provider_setting_upsert(&repo,{bridge_id=bid,provider="codex",enabled=true})
		testing.expect_value(t,err.code,domain.Error_Code.None)
	}
	allowed := []string{"codex"}
	first := provider.Model_Discovery_Item{
		provider="codex",binary_path="/bin/codex",version_text="v1",has_snapshot=true,
		models=[]provider.Discovered_Model{{model_id="new-seed-absent-id",label="New",resolved_model="resolved-id"}},
		models_source="codex_app_server",models_checked_at="2026-10-01T00:00:00Z",models_attempted_at="2026-10-01T00:00:00Z",models_state="success",
	}
	testing.expect_value(t,provider.apply_model_discovery_report(&svc,"models-a",allowed,[]provider.Model_Discovery_Item{first}).code,domain.Error_Code.None)
	testing.expect_value(t,provider.validate_launchable(&svc,"models-a","codex","new-seed-absent-id").code,domain.Error_Code.None)
	testing.expect(t,provider.validate_launchable(&svc,"models-b","codex","new-seed-absent-id").code!=.None,"another bridge/account keeps its fallback list")
	catalog,_,_ := iface.provider_catalog_get(&repo,"codex")
	for m in catalog.models do testing.expect(t,m.model_id!="new-seed-absent-id","global catalog remains unchanged")
	domain.provider_catalog_entry_destroy(catalog)

	// Both ordinary and extension detection ingestion use this path. Neither
	// can erase an independent model snapshot.
	testing.expect_value(t,provider.apply_discovery_report(&svc,"models-a",[]domain.Bridge_Provider_Status{{bridge_id="models-a",provider="codex",state="present",extension_state="error"}}).code,domain.Error_Code.None)
	failed := provider.Model_Discovery_Item{provider="codex",models_state="authentication_required",models_attempted_at="2026-10-02T00:00:00Z"}
	testing.expect_value(t,provider.apply_model_discovery_report(&svc,"models-a",allowed,[]provider.Model_Discovery_Item{failed}).code,domain.Error_Code.None)
	views,view_err := provider.list_bridge_providers(&svc,"models-a")
	testing.expect_value(t,view_err.code,domain.Error_Code.None)
	for v in views do if v.catalog.provider=="codex" {
		testing.expect(t,v.models_has_snapshot)
		testing.expect_value(t,v.models_state,"authentication_required")
		testing.expect_value(t,v.models_checked_at,first.models_checked_at)
		testing.expect_value(t,v.models_source,"codex_app_server")
		testing.expect_value(t,len(v.catalog.models),1)
		if len(v.catalog.models)==1 {
			testing.expect_value(t,v.catalog.models[0].model_id,"new-seed-absent-id")
			testing.expect_value(t,v.catalog.models[0].resolved_model,"resolved-id")
		}
	}
	provider.bridge_provider_views_destroy(views)
	testing.expect_value(t,provider.validate_launchable(&svc,"models-a","codex","new-seed-absent-id").code,domain.Error_Code.None)
	// Identical completed success advances checked time, with no TTL semantics.
	first.models_checked_at="2026-10-03T00:00:00Z"; first.models_attempted_at=first.models_checked_at
	testing.expect_value(t,provider.apply_model_discovery_report(&svc,"models-a",allowed,[]provider.Model_Discovery_Item{first}).code,domain.Error_Code.None)
	saved,_ := iface.bridge_provider_models_list(&repo,"models-a")
	testing.expect_value(t,saved[0].models_checked_at,first.models_checked_at)
	domain.bridge_provider_models_list_destroy(saved)
	// Empty success is authoritative and must never resurrect static models.
	first.models=nil; first.models_checked_at="2026-10-04T00:00:00Z"; first.models_attempted_at=first.models_checked_at
	testing.expect_value(t,provider.apply_model_discovery_report(&svc,"models-a",allowed,[]provider.Model_Discovery_Item{first}).code,domain.Error_Code.None)
	testing.expect(t,provider.validate_launchable(&svc,"models-a","codex","new-seed-absent-id").code!=.None)
	entry,_,_ := iface.provider_catalog_get(&repo,"codex")
	testing.expect_value(t,provider.apply_effective_models(&repo,"models-a",&entry).code,domain.Error_Code.None)
	testing.expect_value(t,len(entry.models),0)
	domain.provider_catalog_entry_destroy(entry)
	// A failed first attempt leaves a labelled static fallback.
	testing.expect_value(t,provider.apply_model_discovery_report(&svc,"models-b",allowed,[]provider.Model_Discovery_Item{failed}).code,domain.Error_Code.None)
	views,_ = provider.list_bridge_providers(&svc,"models-b")
	for v in views do if v.catalog.provider=="codex" {
		testing.expect(t,!v.models_has_snapshot && len(v.catalog.models)>0)
		testing.expect_value(t,v.models_source,"static_fallback")
	}
	provider.bridge_provider_views_destroy(views)
	// An explicit failed refresh can recover a Bridge's persisted last-good
	// snapshot when the Hub has never received it. Keep its failure state.
	recovered:=provider.Model_Discovery_Item{provider="codex",has_snapshot=true,models=[]provider.Discovered_Model{{model_id="bridge-last-good",label="Recovered"}},models_source="codex_app_server",models_checked_at="2026-10-01T00:00:00Z",models_attempted_at="2026-10-05T00:00:00Z",models_state="timeout"}
	testing.expect_value(t,provider.apply_model_discovery_report(&svc,"models-b",allowed,[]provider.Model_Discovery_Item{recovered}).code,domain.Error_Code.None)
	testing.expect_value(t,provider.validate_launchable(&svc,"models-b","codex","bridge-last-good").code,domain.Error_Code.None)

}

@(test)
test_bridge_models_report_rejects_unsolicited_or_malformed_data :: proc(t: ^testing.T) {
	svc := provider.new_provider_service(nil)
	defer delete(svc.test_runs)
	item := provider.Model_Discovery_Item{provider="codex",models_state="success",has_snapshot=true,models_source="codex_app_server",models_checked_at="now",models_attempted_at="now"}
	testing.expect_value(t,provider.apply_model_discovery_report(&svc,"a",[]string{},[]provider.Model_Discovery_Item{item}).code,domain.Error_Code.Validation_Failed)
	testing.expect_value(t,provider.apply_model_discovery_report(&svc,"a",[]string{"claude"},[]provider.Model_Discovery_Item{item}).code,domain.Error_Code.Forbidden)
	item.models=[]provider.Discovered_Model{{model_id="--bad",label="bad"}}
	testing.expect_value(t,provider.apply_model_discovery_report(&svc,"a",[]string{"codex"},[]provider.Model_Discovery_Item{item}).code,domain.Error_Code.Validation_Failed)
	item.models=[]provider.Discovered_Model{{model_id="same"},{model_id="same"}}
	testing.expect_value(t,provider.apply_model_discovery_report(&svc,"a",[]string{"codex"},[]provider.Model_Discovery_Item{item}).code,domain.Error_Code.Validation_Failed)
	testing.expect(t,!provider.model_id_valid(strings.repeat("x",257,context.temp_allocator)))
}
