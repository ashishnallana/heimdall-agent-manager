package hub_bridge_offline_mark_test

// Unit test for bridge_service.mark_bridge_offline (task_18d12a41150e0ec4).
//
// On a bridge WS disconnect the hub must flip the durable bridge record to
// .Offline (bridge_runtime_connect sets .Online but nothing marked it back down,
// so bridges showed 'online' forever after a crash/quit). The mark must be:
//   - a real transition Online -> Offline (changed=true), publishing an event,
//   - idempotent: re-marking an already-.Offline bridge is changed=false (no
//     spurious event),
//   - non-destructive to a terminal .Revoked bridge (left untouched).
// Uses a tiny in-memory Bridge_Repository + a fixed clock.

import "core:fmt"
import "core:testing"
import "core:os"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import bridge_service "odin_test:hub/service/bridge"
import platform "odin_test:hub/platform"

Fake_Bridge_Repo :: struct {
	bridges: [16]domain.Bridge,
	count:   int,
}

fb_save :: proc(ctx: rawptr, bridge: domain.Bridge) -> (domain.Bridge, bool, domain.Domain_Error) {
	repo := (^Fake_Bridge_Repo)(ctx)
	for i in 0..<repo.count {
		if repo.bridges[i].bridge_id == bridge.bridge_id {
			repo.bridges[i] = bridge
			return bridge, true, domain.Domain_Error{}
		}
	}
	repo.bridges[repo.count] = bridge
	repo.count += 1
	return bridge, true, domain.Domain_Error{}
}

fb_get :: proc(ctx: rawptr, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	repo := (^Fake_Bridge_Repo)(ctx)
	for i in 0..<repo.count {
		if repo.bridges[i].bridge_id == bridge_id do return repo.bridges[i], true, domain.Domain_Error{}
	}
	return domain.Bridge{}, false, domain.domain_error(.Not_Found, "nf")
}

fb_status :: proc(repo: ^Fake_Bridge_Repo, bridge_id: string) -> domain.Bridge_Status {
	for i in 0..<repo.count { if repo.bridges[i].bridge_id == bridge_id do return repo.bridges[i].status }
	return .Offline
}

fb_now: string = "2026-09-01T10:00:00Z"
fb_clock_now :: proc(ctx: rawptr) -> string { _ = ctx; return fb_now }

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln("FAIL:", message); os.exit(1) }

@(test)
test_hub_bridge_offline_mark_test :: proc(t: ^testing.T) {
	_ = t
	main()
}

main :: proc() {
	repo := new(Fake_Bridge_Repo)
	bridges := iface.Bridge_Repository{ ctx = rawptr(repo), save_bridge = fb_save, get_bridge = fb_get }
	clock := platform.Clock{ now = fb_clock_now }
	ids := platform.real_id_generator()
	svc := bridge_service.new_bridge_service(&bridges, &clock, &ids)

	_, _, _ = fb_save(rawptr(repo), domain.Bridge{bridge_id = "brg_online", owner_user_id = "usr_1", status = .Online})
	_, _, _ = fb_save(rawptr(repo), domain.Bridge{bridge_id = "brg_revoked", owner_user_id = "usr_1", status = .Revoked})

	// Online -> Offline is a real transition (changed=true) and persists.
	b1, changed1, err1 := bridge_service.mark_bridge_offline(&svc, "brg_online")
	check(err1.code == .None, "mark_bridge_offline must not error on a known online bridge")
	check(changed1, "online -> offline must report changed=true")
	check(b1.status == .Offline, "returned bridge must be .Offline")
	check(fb_status(repo, "brg_online") == .Offline, "durable status must persist as .Offline")

	// Idempotent: re-marking an already-offline bridge is a no-op (changed=false).
	_, changed2, err2 := bridge_service.mark_bridge_offline(&svc, "brg_online")
	check(err2.code == .None, "second mark must not error")
	check(!changed2, "already-offline bridge must report changed=false (no spurious event)")
	check(fb_status(repo, "brg_online") == .Offline, "status stays .Offline")

	// Revoked is terminal: never overridden to offline.
	_, changed3, _ := bridge_service.mark_bridge_offline(&svc, "brg_revoked")
	check(!changed3, "revoked bridge must not be changed by mark_bridge_offline")
	check(fb_status(repo, "brg_revoked") == .Revoked, "revoked bridge stays .Revoked")

	fmt.println("PASS: hub bridge offline mark (online->offline, idempotent, revoked-safe)")
}
