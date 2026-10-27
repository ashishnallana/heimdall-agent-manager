package main

import "core:sync"
import "core:testing"
import agent_runtime "odin_test:lib/agent_runtime"

@(test)
test_bridge_effective_models_and_launch_argv :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	snap:=Bridge_Provider_Catalog_Snapshot{providers=[]Bridge_Catalog_Provider{{provider="codex",state="active",model_flag="-m",models=[]Bridge_Catalog_Model{{model_id="seed",state="active"}}}}}
	sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
	old_snap,old_loaded:=bridge_provider_catalog_snapshot,bridge_provider_catalog_loaded
	bridge_provider_catalog_snapshot=&snap;bridge_provider_catalog_loaded=true
	sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
	defer {
		sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
		bridge_provider_catalog_snapshot=old_snap;bridge_provider_catalog_loaded=old_loaded
		sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
	}
	sync.mutex_lock(&bridge_models_mu)
	old_cache,old_models_loaded:=bridge_models_cache,bridge_models_loaded
	bridge_models_cache=make([dynamic]Bridge_Provider_Models)
	bridge_models_loaded=true
	sync.mutex_unlock(&bridge_models_mu)
	defer {
		sync.mutex_lock(&bridge_models_mu)
		for &v in bridge_models_cache do bridge_models_destroy(&v)
		delete(bridge_models_cache)
		bridge_models_cache=old_cache;bridge_models_loaded=old_models_loaded
		sync.mutex_unlock(&bridge_models_mu)
	}
	testing.expect(t,bridge_provider_catalog_has_model("codex","seed"),"missing snapshot preserves old-Hub fallback")
	sync.mutex_lock(&bridge_models_mu)
	append(&bridge_models_cache,bridge_models_clone({provider="codex",has_snapshot=true,models=[]Bridge_Discovered_Model{{model_id="new-launch-id",label="New"}},models_state="authentication_required"}))
	sync.mutex_unlock(&bridge_models_mu)
	testing.expect(t,bridge_provider_catalog_has_model("codex","new-launch-id"),"last-good models survive failed attempts")
	testing.expect(t,!bridge_provider_catalog_has_model("codex","seed"),"snapshot replaces seed membership")
	profile:=bridge_agent_runtime_profile(bridge_provider_profile_from_catalog(snap.providers[0]))
	argv:=agent_runtime.build_agent_command(profile,"new-launch-id","","tok","inst",agent_runtime.PERMISSION_MODE_ASK)
	defer delete(argv)
	testing.expect_value(t,len(argv),2)
	if len(argv)==2 do testing.expect_value(t,argv[1],"new-launch-id")
	sync.mutex_lock(&bridge_models_mu)
	for m in bridge_models_cache[0].models {delete(m.model_id);delete(m.label);delete(m.resolved_model)}
	delete(bridge_models_cache[0].models);bridge_models_cache[0].models=nil
	sync.mutex_unlock(&bridge_models_mu)
	testing.expect(t,!bridge_provider_catalog_has_model("codex","seed"),"successful empty list does not fall back")
}
