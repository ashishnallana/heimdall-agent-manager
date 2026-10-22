package agent

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// ham.ext.v1 ingest: identity comes only from the instance token, invalid events
// are counted (not fatal), and hello/session update provider_session_id.

@(private = "file")
Ext_Store :: struct {
	inst:     domain.Agent_Instance,
	events:   [dynamic]domain.Agent_Extension_Event,
	inserted_for: string,
	updates:  [dynamic]domain.Agent_Extension_Instance_Update,
}

@(private = "file")
ext_get_instance :: proc(ctx: rawptr, instance_id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	s := (^Ext_Store)(ctx)
	if instance_id != s.inst.agent_instance_id do return {}, false, domain.domain_error(.Not_Found, "agent instance not found")
	return s.inst, true, {}
}

@(private = "file")
ext_insert :: proc(ctx: rawptr, instance_id: string, events: []domain.Agent_Extension_Event, keep: int) -> ([]domain.Agent_Extension_Event, domain.Domain_Error) {
	s := (^Ext_Store)(ctx)
	s.inserted_for = instance_id
	out := make([]domain.Agent_Extension_Event, len(events))
	for ev, i in events {
		e := ev
		e.instance_id = instance_id
		e.seq = len(s.events) + 1
		append(&s.events, e)
		out[i] = e
	}
	return out, {}
}

@(private = "file")
ext_update :: proc(ctx: rawptr, instance_id: string, upd: domain.Agent_Extension_Instance_Update) -> (bool, domain.Domain_Error) {
	s := (^Ext_Store)(ctx)
	append(&s.updates, upd)
	if upd.provider_session_id != "" do s.inst.provider_session_id = upd.provider_session_id
	if upd.extension_capabilities != "" do s.inst.extension_capabilities = upd.extension_capabilities
	return true, {}
}

@(private = "file")
ext_service :: proc(store: ^Ext_Store, repo: ^iface.Agent_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Agent_Service {
	store.inst = domain.Agent_Instance{agent_instance_id = "inst_me", owner_user_id = "owner", provider_session_id = "sess_old"}
	repo^ = iface.Agent_Repository{ctx = store, get_instance = ext_get_instance, ext_insert_events = ext_insert, ext_update_instance = ext_update}
	clock^ = platform.real_clock()
	ids^ = platform.real_id_generator()
	return new_agent_service(repo, nil, clock, ids)
}

@(private = "file")
ME :: contracts.Auth_Context{kind = .Instance_Token, user_id = "owner", agent_instance_id = "inst_me"}

@(test)
test_extension_ingest_batch_stamps_identity_and_session :: proc(t: ^testing.T) {
	store: Ext_Store
	repo: iface.Agent_Repository
	clock: platform.Clock
	ids: platform.ID_Generator
	service := ext_service(&store, &repo, &clock, &ids)
	defer delete(store.events)
	defer delete(store.updates)

	// The payload claims another instance; the hub must ignore that entirely.
	params := `{"agent_instance_id":"inst_other","events":[
		{"schema":"ham.ext.v1","provider":"claude","ext_version":"0.1.0","event":"hello","ts":"t1","session_id":"sess_new","transcript_path":"/t.jsonl","agent":{},"payload":{"capabilities":["activity","subagents"]}},
		{"schema":"ham.ext.v1","provider":"claude","event":"file.edit","session_id":"sess_new","agent":{"id":"sub_1","type":"Explore"},"tool":{"name":"Edit","use_id":"tu_1","input":{"file_path":"/w/a.odin"}},"payload":{}},
		{"schema":"wrong","provider":"claude","event":"activity","payload":{}},
		{"schema":"ham.ext.v1","provider":"claude","event":"not.an.event","payload":{}},
		"not an object"
	]}`
	result, ok, err := ingest_extension_events(&service, ME, params)
	testing.expect(t, ok, err.message)
	testing.expect_value(t, len(result.stored), 2)
	testing.expect_value(t, result.rejected, 3)
	testing.expect_value(t, store.inserted_for, "inst_me")
	testing.expect_value(t, result.session_changed, true)
	testing.expect_value(t, result.instance.provider_session_id, "sess_new")
	if len(result.stored) == 2 {
		fe := result.stored[1]
		testing.expect_value(t, fe.event, "file.edit")
		testing.expect_value(t, fe.agent_id, "sub_1")
		testing.expect_value(t, fe.agent_type, "Explore")
		testing.expect_value(t, fe.tool_name, "Edit")
		testing.expect_value(t, fe.tool_use_id, "tu_1")
		testing.expect_value(t, fe.file_path, "/w/a.odin")
	}
	if len(store.updates) == 1 {
		u := store.updates[0]
		testing.expect_value(t, u.extension_provider, "claude")
		testing.expect_value(t, u.extension_version, "0.1.0")
		testing.expect_value(t, u.provider_transcript_path, "/t.jsonl")
		testing.expect_value(t, u.extension_capabilities, `["activity","subagents"]`)
	} else {
		testing.expect_value(t, len(store.updates), 1)
	}
}

@(test)
test_extension_ingest_single_event_and_same_session :: proc(t: ^testing.T) {
	store: Ext_Store
	repo: iface.Agent_Repository
	clock: platform.Clock
	ids: platform.ID_Generator
	service := ext_service(&store, &repo, &clock, &ids)
	defer delete(store.events)
	defer delete(store.updates)

	// A bare event (no {"events":[...]}) is accepted; a session event with an
	// unchanged id is not reported as a change.
	result, ok, _ := ingest_extension_events(&service, ME, `{"schema":"ham.ext.v1","provider":"claude","event":"session","session_id":"sess_old","payload":{}}`)
	testing.expect(t, ok, "single event ingested")
	testing.expect_value(t, len(result.stored), 1)
	testing.expect_value(t, result.session_changed, false)

	// Activity events never touch the session id.
	result2, _, _ := ingest_extension_events(&service, ME, `{"events":[{"schema":"ham.ext.v1","provider":"claude","event":"activity","session_id":"sess_x","payload":{"state":"idle"}}]}`)
	testing.expect_value(t, len(result2.stored), 1)
	testing.expect_value(t, result2.session_changed, false)
	testing.expect_value(t, store.inst.provider_session_id, "sess_old")
}

@(test)
test_extension_ingest_requires_instance_token :: proc(t: ^testing.T) {
	store: Ext_Store
	repo: iface.Agent_Repository
	clock: platform.Clock
	ids: platform.ID_Generator
	service := ext_service(&store, &repo, &clock, &ids)
	defer delete(store.events)
	defer delete(store.updates)

	_, ok, err := ingest_extension_events(&service, contracts.Auth_Context{kind = .User_Token, user_id = "owner"}, `{"events":[]}`)
	testing.expect(t, !ok, "user token rejected")
	testing.expect_value(t, err.code, domain.Error_Code.Forbidden)

	// Another owner's token for the same instance id is not found.
	_, ok2, err2 := ingest_extension_events(&service, contracts.Auth_Context{kind = .Instance_Token, user_id = "intruder", agent_instance_id = "inst_me"}, `{"events":[]}`)
	testing.expect(t, !ok2, "foreign owner rejected")
	testing.expect_value(t, err2.code, domain.Error_Code.Not_Found)

	_, ok3, err3 := ingest_extension_events(&service, ME, `[1,2]`)
	testing.expect(t, !ok3, "non-object params rejected")
	testing.expect_value(t, err3.code, domain.Error_Code.Validation_Failed)
	testing.expect_value(t, len(store.events), 0)
}
