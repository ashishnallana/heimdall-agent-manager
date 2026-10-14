package push

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import metrics "odin_test:lib/metrics"

// heimdall_push_sent_total{result}: skipped when push is disabled or the
// subscription list fails; one `failed` per subscription when the batch cannot
// even be signed; class -> result mapping is the fixed enum.

@(private = "file")
Fake_List_Repo :: struct {
	subs: []domain.Push_Subscription,
	fail: bool,
}

@(private = "file")
fake_list_by_owner :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Push_Subscription, domain.Domain_Error) {
	r := (^Fake_List_Repo)(ctx)
	if r.fail do return nil, domain.domain_error(.Internal_Error, "boom")
	out := make([]domain.Push_Subscription, len(r.subs))
	copy(out, r.subs)
	return out, domain.Domain_Error{}
}

@(private = "file")
push_count :: proc(result: string) -> u64 {
	return metrics.counter_value(metrics.with(push_metrics.sent_total, result))
}

@(test)
test_push_metrics_result_enum :: proc(t: ^testing.T) {
	testing.expect_value(t, push_metrics_result(.Success), "sent")
	testing.expect_value(t, push_metrics_result(.Gone), "gone")
	testing.expect_value(t, push_metrics_result(.Auth_Failed), "failed")
	testing.expect_value(t, push_metrics_result(.Transient), "failed")
}

@(test)
test_push_metrics_skipped_and_failed_paths :: proc(t: ^testing.T) {
	push_metrics_init(metrics.init_global())

	// Disabled (no VAPID keypair) -> one `skipped`.
	repo: iface.Push_Repository
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	disabled := new_push_service(&repo, &clock, &ids)
	skipped_before := push_count("skipped")
	_ = send_to_user(&disabled, domain.User_ID("usr_1"), "{}")
	testing.expect_value(t, push_count("skipped") - skipped_before, u64(1))

	// Subscription list failure -> one `skipped`.
	failing := Fake_List_Repo{fail = true}
	failing_repo := iface.Push_Repository{ctx = rawptr(&failing), list_by_owner = fake_list_by_owner}
	svc := Push_Service{subscriptions = &failing_repo, vapid = Vapid_Config{public_key = "pk", private_key = "not-a-key"}}
	skipped_before = push_count("skipped")
	_ = send_to_user(&svc, domain.User_ID("usr_1"), "{}")
	testing.expect_value(t, push_count("skipped") - skipped_before, u64(1))

	// Two subscriptions but an unusable VAPID key -> two `failed`, nothing sent.
	fake := Fake_List_Repo{subs = []domain.Push_Subscription{
		{id = "psub_1", endpoint = "https://push.example/a"},
		{id = "psub_2", endpoint = "https://push.example/b"},
	}}
	fake_repo := iface.Push_Repository{ctx = rawptr(&fake), list_by_owner = fake_list_by_owner}
	svc2 := Push_Service{subscriptions = &fake_repo, vapid = Vapid_Config{public_key = "pk", private_key = "!!!not-base64url!!!"}}
	failed_before := push_count("failed")
	sent_before := push_count("sent")
	testing.expect_value(t, send_to_user(&svc2, domain.User_ID("usr_1"), "{}"), 0)
	testing.expect_value(t, push_count("failed") - failed_before, u64(2))
	testing.expect_value(t, push_count("sent") - sent_before, u64(0))
}
