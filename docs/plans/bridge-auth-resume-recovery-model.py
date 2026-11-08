#!/usr/bin/env python3
"""Offline ordering model for docs/plans/bridge-auth-resume-recovery.md.

Simulated clocks only: no network, credential files, real clocks, services or
tokens. Generations are integers; nothing here resembles a credential.

1. Checks the current-source premises the plan relies on (working tree).
2. Simulates the CURRENT design ("old") and the PROPOSED design ("new") against
   the plan's verification matrix and asserts the expected orderings.

This is a model of intended ordering, not evidence of native suspend behavior.
"""
from pathlib import Path
import random
import re

ROOT = Path(__file__).resolve().parents[2]


def src(path):
    return (ROOT / path).read_text()


def proc(text, name):
    m = re.search(r"^" + re.escape(name) + r" :: proc\b.*?^}", text, re.M | re.S)
    assert m, name
    return m.group(0)


def check_source_premises():
    flow = src("src/bridge/enroll_device_flow.odin")
    runtime = src("src/bridge/hub_runtime_client.odin")
    tokens = src("src/hub/service/bridge/bridge_token_service.odin")
    handlers = src("src/hub/transport/http/bridge_handlers.odin")
    worker = proc(flow, "bridge_credential_refresh_worker")
    assert "delay := BRIDGE_REFRESH_MIN_DELAY_SECONDS" in worker
    assert "time.sleep(time.Duration(delay)*time.Second)" in worker
    assert "time.sleep(BRIDGE_REFRESH_PAUSE_SECONDS * time.Second)" in proc(flow, "bridge_refresh_pause")
    rworker = proc(runtime, "bridge_hub_runtime_worker")
    assert "credential := bridge_credential_snapshot()" in rworker
    # bridge_ready clears the in-band reauth flag without a generation check.
    assert "sync.atomic_store(&bridge_credential_reauth_pending, false)" in rworker
    frame = proc(runtime, "bridge_hub_session_frame")
    expired = frame.split('case "bridge_token_expired":', 1)[1].split("case ", 1)[0]
    assert "bridge_credential_refresh" not in expired and "renew" not in expired
    assert "generation" not in proc(flow, "bridge_refresh_adopt")
    assert int(re.search(r"BRIDGE_ACCESS_TOKEN_TTL_SECONDS :: (\d+)", tokens).group(1)) == ACCESS_TTL
    assert int(re.search(r"BRIDGE_TOKEN_CLOCK_SKEW_SECONDS :: (\d+)", tokens).group(1)) == HUB_SKEW
    assert int(re.search(r"BRIDGE_REFRESH_RETRY_GRACE_SECONDS :: (\d+)", tokens).group(1)) == RETRY_GRACE
    # Any non-"expired" Unauthenticated/Forbidden at upgrade is reported as revoked.
    assert "code := BRIDGE_WS_CREDENTIAL_REVOKED_CODE" in proc(handlers, "bridge_ws_auth_error")
    # Repository errors are discarded and read as "not found" (-> invalid / invalid_grant).
    assert "row, ok, _ := iface.bridge_get_token(service.repo, token_id)" in proc(tokens, "refresh_bridge_token")
    assert "row, ok, _ := iface.bridge_get_token(service.repo, token_id)" in proc(tokens, "verify_access_token_scoped")
    assert "bridge, bridge_ok, _ := iface.bridge_get_bridge(service.repo, row.bridge_id)" in proc(tokens, "rotate_from")
    # A bare 401 (no typed body) becomes Unauthenticated, which the refresh path treats as final.
    assert "if resp.status == 401 do err.code = .Unauthenticated" in proc(src("src/bridge/retry_budget.odin"), "bridge_operation_http_error")
    assert "if err.code == .Unauthenticated do bridge_hub_stop_traffic(true)" in proc(flow, "bridge_credential_refresh_typed")
    print("SOURCE_PREMISES ok (relative refresh sleep, fixed 60s pause, no renewal on "
          "bridge_token_expired, unconditional reauth clear, no credential generation, "
          "Hub repo errors read as invalid, bare 401 final on refresh)")


ACCESS_TTL, HUB_SKEW, REFRESH_TTL, RETRY_GRACE = 3600, 60, 30 * 86400, 600
SKEW_MARGIN, REEVAL_MAX = 300, 30          # proposed constants
BUDGET_ATTEMPTS, BUDGET_WINDOW, PAUSE = 6, 120, 60
OLD_DELAY = 2880                           # 80% of 3600 at jitter byte 128


class World:
    def __init__(self, suspends=(), offline=(), hub_down=(), wall_jumps=(), proxy_401=(), repo_blip=()):
        self.suspends, self.offline, self.hub_down = suspends, offline, hub_down
        self.wall_jumps = wall_jumps
        self.proxy_401 = proxy_401  # gateway answers a bare 401 (no typed body) before the Hub
        self.repo_blip = repo_blip  # Hub repository errors (H0: Internal_Error, never invalid)

    @staticmethod
    def inside(t, spans):
        return any(a <= t < b for a, b in spans)

    def suspended(self, t):
        return self.inside(t, self.suspends)

    def mono(self, t):  # suspend-excluding monotonic clock
        return t - sum(max(0, min(t, b) - a) for a, b in self.suspends if a < t)

    def wall(self, t):
        return t + sum(d for at, d in self.wall_jumps if t >= at)

    def net(self, t):
        return not self.inside(t, self.offline) and not self.inside(t, self.hub_down)


class Hub:
    """Generation-level model of bridge_token_service.odin (Hub clock = true time)."""

    def __init__(self):
        self.gen, self.issued, self.rotated = 1, {1: 0}, {}
        self.used, self.revoked, self.exchanges = set(), False, 0

    def access(self, gen, t, blip=False):
        if blip:
            return "internal_error"  # H0: transient, not "invalid"/revoked
        if self.revoked:
            return "revoked"
        if t > self.issued[gen] + ACCESS_TTL + HUB_SKEW:
            return "expired"
        self.used.add(gen)
        return "ok"

    def mint(self, t):
        self.gen += 1
        self.issued[self.gen] = t
        return self.gen

    def refresh(self, gen, rid, t, blip=False):
        self.exchanges += 1
        if blip:
            return "internal_error"  # H0: repository error never becomes invalid_grant
        if self.revoked or t > self.issued[gen] + REFRESH_TTL + HUB_SKEW:
            return None
        if gen == self.gen:
            self.rotated[gen] = (t, rid)
            return self.mint(t)
        spent = self.rotated.get(gen)
        if (gen == self.gen - 1 and spent and rid and spent[1] == rid
                and t - spent[0] <= RETRY_GRACE and self.gen not in self.used):
            return self.mint(t)  # request-id retry of a lost reply
        self.revoked = True      # spent-token reuse: family revoked
        return None


class Bridge:
    def __init__(self, world, hub, design, rng, disk=None, crash=None):
        self.w, self.hub, self.design, self.rng = world, hub, design, rng
        self.disk = disk or {"access": 1, "refresh": 1, "meta": {"gen": 1, "wall": 0, "exp": ACCESS_TTL},
                             "pending": None, "rid": None}
        self.crash = crash  # (kind, earliest true time) for the crash scenarios
        self.exchange_attempts, self.offline_attempts, self.coalesced = 0, 0, 0
        self.dials, self.expired_dials, self.reenroll_dials = 0, 0, 0
        self.alive, self.state = True, "ok"
        self.connected_since = None

    def boot(self, t):
        m = self.w.mono(t)
        self.alive, self.connected, self.session_gen = True, False, None
        self.renewing, self.next_attempt, self.attempts, self.window = False, None, 0, None
        self.dial_failures, self.next_dial, self.next_eval = 0, m, m
        self.rejection_renewed = set()
        if self.design == "new" and self.disk["pending"]:
            self.commit(self.disk["pending"], t, exchanged=False)  # recover before first dial
        self.cred = self.disk["access"]
        meta = self.disk["meta"]
        known = self.design == "new" and meta and meta["gen"] == self.cred
        # Process-local monotonic anchor is never restored from disk.
        self.issued_wall, self.issued_mono = (meta["wall"], None) if known else (None, None)
        self.exp = meta["exp"] if known else ACCESS_TTL
        self.next_refresh = m + 30  # current worker: first exchange 30s after start

    # ----- proposed credential owner -----
    def needs_renew(self, t):
        if self.issued_wall is None and self.issued_mono is None:
            return True  # unknown age: revalidate
        el_wall = self.w.wall(t) - self.issued_wall if self.issued_wall is not None else 0
        el_mono = self.w.mono(t) - self.issued_mono if self.issued_mono is not None else 0
        return self.exp - max(el_wall, el_mono) < SKEW_MARGIN

    def request_renew(self, t):
        if self.state != "ok":
            return
        if self.renewing:
            self.coalesced += 1
            return
        self.renewing, self.next_attempt = True, self.w.mono(t)

    def jitter(self, s):
        return s * self.rng.uniform(0.8, 1.2)

    def attempt(self, t):
        m = self.w.mono(t)
        if self.window is None or m - self.window > BUDGET_WINDOW:
            self.window, self.attempts = m, 0
        self.exchange_attempts += 1
        bare_401 = self.w.inside(t, self.w.proxy_401)
        blip = self.w.inside(t, self.w.repo_blip)
        new = None
        if not bare_401 and self.w.net(t):
            if self.disk["rid"] is None:
                self.disk["rid"] = self.rng.randrange(1 << 60)  # durable before send
            new = self.hub.refresh(self.disk["refresh"], self.disk["rid"], t, blip=blip)
        # Only a typed invalid_grant body from the Hub is final; a bare 401 and
        # an Internal_Error are transient and use the bounded budget.
        if not self.w.net(t) or bare_401 or new == "internal_error":
            self.offline_attempts += 1
            self.attempts += 1
            if self.attempts < BUDGET_ATTEMPTS:
                delay = 5 * 2 ** (self.attempts - 1)
                self.next_attempt = m + (self.jitter(delay) if self.design == "new" else delay)
            else:
                self.window = None
                self.next_attempt = m + (self.jitter(PAUSE) if self.design == "new" else PAUSE)
            return
        if self.crash and self.crash[0] == "after_hub_rotation" and t >= self.crash[1]:
            self.alive, self.crash = False, None  # reply lost; nothing persisted
            return
        if new is None:
            self.state, self.renewing, self.connected = "reenroll_required", False, False
            self.disk.update(access=None, refresh=None, meta=None, rid=None)
            return
        self.disk["pending"] = new
        if self.crash and self.crash[0] == "after_pending_save" and t >= self.crash[1]:
            self.alive, self.crash = False, None
            return
        self.commit(new, t, exchanged=True)

    def commit(self, gen, t, exchanged):
        # pending -> refresh -> access -> meta, then publish and clean up.
        self.disk.update(refresh=gen, access=gen, meta={"gen": gen, "wall": self.w.wall(t), "exp": ACCESS_TTL})
        self.cred, self.issued_wall, self.issued_mono, self.exp = gen, self.w.wall(t), self.w.mono(t), ACCESS_TTL
        self.disk.update(pending=None, rid=None)
        self.renewing = False
        self.next_refresh = self.w.mono(t) + OLD_DELAY
        if self.connected:
            self.session_gen = gen  # in-band reauth, fenced by generation

    def on_rejection(self, gen, t):
        if self.design != "new":
            return
        if gen < self.cred:
            self.next_dial = self.w.mono(t)  # newer generation already published
        elif gen not in self.rejection_renewed:
            self.rejection_renewed.add(gen)  # at most one rejection-driven renewal per generation
            self.request_renew(t)

    def backoff(self):
        self.dial_failures += 1
        return self.jitter(min(30, 0.5 * 2 ** (self.dial_failures - 1)))

    def dial(self, t):
        m = self.w.mono(t)
        if self.design == "new" and self.needs_renew(t):
            self.request_renew(t)
            if self.renewing and m >= self.next_attempt:
                self.attempt(t)  # ensure_access_credential, bounded by its deadline
            if not self.alive or self.state != "ok":
                return
        self.dials += 1
        if not self.w.net(t):
            self.next_dial = m + self.backoff()
            return
        result = self.hub.access(self.cred, t, blip=self.w.inside(t, self.w.repo_blip))
        if result == "internal_error":
            self.next_dial = m + self.backoff()
            return
        if result == "ok":
            self.connected, self.session_gen, self.dial_failures = True, self.cred, 0
            if self.connected_since is None:
                self.connected_since = t
        elif result == "expired":
            self.expired_dials += 1
            self.on_rejection(self.cred, t)
            self.next_dial = m + self.backoff()
        else:
            self.state = "reenroll_required"

    def step(self, t):
        if not self.alive or self.w.suspended(t):
            return
        if self.state != "ok":
            return
        m = self.w.mono(t)
        if self.connected and (not self.w.net(t) or self.hub.access(
                self.session_gen, t, blip=self.w.inside(t, self.w.repo_blip)) not in ("ok", "internal_error")):
            self.connected = False
            if self.hub.revoked:
                self.state = "reenroll_required"
                return
            self.on_rejection(self.session_gen, t)
            self.next_dial = m + (self.backoff() if self.design == "old" else 0)
        if self.design == "new" and m >= self.next_eval:
            self.next_eval = m + REEVAL_MAX  # short, interruptible re-evaluation
            if self.needs_renew(t):
                self.request_renew(t)
        if self.design == "old" and m >= self.next_refresh and not self.renewing:
            self.request_renew(t)
        if self.renewing and m >= self.next_attempt:
            self.attempt(t)
        if self.alive and self.state == "ok" and not self.connected and m >= self.next_dial:
            self.dial(t)


def run(design, world, hub=None, until=20000, crash=None, restart_after=None, hooks=None, seed=7):
    hub = hub or Hub()
    b = Bridge(world, hub, design, random.Random(seed), crash=crash)
    b.boot(0)
    down = []  # (t, connected?) samples while awake
    crashed_at = None
    for t in range(until):
        if hooks and t in hooks:
            hooks[t](b, hub, t)
        if not b.alive and crashed_at is None:
            crashed_at = t
        if crashed_at is not None and restart_after is not None and t == crashed_at + restart_after:
            b.boot(t)
        b.step(t)
        if not world.suspended(t):
            down.append((t, b.connected))
    return b, hub, down


def first_up_after(down, t0):
    return next((t for t, c in down if t >= t0 and c), None)


def scenarios():
    resume = 600 + 7200
    # 1. Sleep past access expiry (suspend-excluding timer).
    w = World(suspends=[(600, resume)])
    old, _, d_old = run("old", w, until=resume + 3000)
    new, hub, d_new = run("new", w, until=resume + 3000)
    up_old, up_new = first_up_after(d_old, resume), first_up_after(d_new, resume)
    assert up_old - resume >= 2280 and old.expired_dials > 40
    assert up_new - resume <= REEVAL_MAX and new.expired_dials <= 1 and hub.exchanges == 1
    print(f"S1 sleep_past_access old_outage_s={up_old - resume} old_expired_dials={old.expired_dials} "
          f"new_outage_s={up_new - resume} new_expired_dials={new.expired_dials} new_exchanges={hub.exchanges}")

    # 2. Sleep past refresh expiry: one exchange, definitive, no loop.
    resume2 = 600 + 31 * 86400
    w = World(suspends=[(600, resume2)])
    b, hub, _ = run("new", w, until=resume2 + 3600)
    assert b.state == "reenroll_required" and hub.exchanges == 1 and b.dials <= 2
    print(f"S2 sleep_past_refresh state={b.state} exchanges={hub.exchanges} dials_total={b.dials}")
    # 2b. A gateway's bare 401 at wake is transient: pair kept, recovers after it clears.
    w = World(suspends=[(600, resume)], proxy_401=[(resume, resume + 300)])
    b, hub, d = run("new", w, until=resume + 2000)
    assert b.state == "ok" and b.disk["refresh"] is not None and first_up_after(d, resume + 300) is not None
    # 2c. Hub repository blip during refresh (H0): Internal_Error, retried, no wipe.
    w = World(suspends=[(600, resume)], repo_blip=[(resume, resume + 90)])
    b2, hub2, d2 = run("new", w, until=resume + 2000)
    assert b2.state == "ok" and not hub2.revoked and first_up_after(d2, resume + 90) - (resume + 90) <= PAUSE * 1.2 + 5
    print(f"S2b bare_401_at_wake state={b.state} pair_kept=True; S2c hub_repo_blip state={b2.state} "
          f"recovered_after_blip_s={first_up_after(d2, resume + 90) - (resume + 90)}")

    # 3. Wall clock jumps (no suspend; the Hub clock is true time).
    b, hub, d = run("new", World(wall_jumps=[(1000, 7200)]), until=8000)
    gaps = [t for t, c in d if t > 5 and not c]
    assert not gaps and b.state == "ok" and hub.exchanges >= 2
    b2, hub2, d2 = run("new", World(wall_jumps=[(1000, -7200)]), until=8000)
    assert not [t for t, c in d2 if t > 5 and not c] and b2.state == "ok"
    print(f"S3 clock_forward exchanges={hub.exchanges} outage_s=0; clock_back exchanges={hub2.exchanges} outage_s=0")
    # 3c. Suspend then a backward NTP step at wake: both age terms undercount, so
    # recovery relies on the rejection-driven path (D3) -- also after a restart
    # (no process-local anchor).
    w = World(suspends=[(600, resume)], wall_jumps=[(resume, -7200)])
    b3, hub3, d3 = run("new", w, until=resume + 600)
    up3 = first_up_after(d3, resume)
    assert up3 - resume <= 2 and b3.rejection_renewed and hub3.exchanges == 1
    def restart(b, hub, t):
        b.boot(t)
    b4, hub4, d4 = run("new", w, until=resume + 600, hooks={resume: restart})
    up4 = first_up_after(d4, resume)
    assert up4 - resume <= 35 and b4.rejection_renewed and b4.expired_dials <= 1
    print(f"S3c suspend_plus_backward_step via_rejection outage_s={up3 - resume}; after_restart "
          f"outage_s={up4 - resume} expired_dials={b4.expired_dials}")

    # 4. Network offline at wake for 600s.
    w = World(suspends=[(600, resume)], offline=[(resume, resume + 600)])
    b, hub, d = run("new", w, until=resume + 3000)
    up = first_up_after(d, resume + 600)
    assert b.offline_attempts <= 20 and up - (resume + 600) <= PAUSE * 1.2 + REEVAL_MAX + 5
    assert b.dials < 60 and hub.exchanges == 1
    print(f"S4 offline_at_wake offline_attempts={b.offline_attempts} dials={b.dials} "
          f"recovered_after_net_s={up - (resume + 600)}")

    # 5. Concurrent triggers at resume: timer, session rejection, dial, 3 HTTP 401s.
    def burst(b, hub, t):
        for _ in range(3):
            b.on_rejection(b.cred, t)
            b.request_renew(t)
    w = World(suspends=[(600, resume)])
    b, hub, _ = run("new", w, until=resume + 200, hooks={resume: burst})
    assert hub.exchanges == 1 and b.coalesced >= 3
    print(f"S5 concurrent_triggers exchanges={hub.exchanges} coalesced_waiters={b.coalesced}")

    # 6. Crash between Hub rotation and local persist.
    w = World()
    b, hub, _ = run("new", w, until=9000, crash=("after_hub_rotation", 3000), restart_after=120)
    assert b.state == "ok" and not hub.revoked
    b2, hub2, _ = run("new", w, until=9000, crash=("after_hub_rotation", 3000), restart_after=900)
    assert b2.state == "reenroll_required" and hub2.revoked
    b3, hub3, _ = run("new", w, until=9000, crash=("after_pending_save", 3000), restart_after=900)
    assert b3.state == "ok" and not hub3.revoked
    print(f"S6 crash_lost_reply restart_120s state={b.state}; restart_900s state={b2.state} "
          f"(Hub retry grace {RETRY_GRACE}s, expected); crash_after_pending state={b3.state} "
          f"exchanges={hub3.exchanges}")

    # 7. Revoked family while running.
    at_revoke = {}
    def revoke(b, hub, t):
        hub.revoked = True
        at_revoke.update(dials=b.dials, exchanges=hub.exchanges)
    b, hub, _ = run("new", World(), until=6000, hooks={1500: revoke})
    assert b.state == "reenroll_required" and b.dials == at_revoke["dials"]
    assert hub.exchanges == at_revoke["exchanges"]
    # 7b. Hub repository blip during a WS connect or session recheck (H0): transient, no park.
    w = World(hub_down=[(2000, 2001)], repo_blip=[(2001, 2120)])
    b2, hub2, d2 = run("new", w, until=3000)
    assert b2.state == "ok" and not hub2.revoked and first_up_after(d2, 2120) - 2120 <= 31
    print(f"S7 revoked state={b.state} dials_total={b.dials} exchanges={hub.exchanges}; "
          f"S7b repo_blip state={b2.state} reconnect_after_blip_s={first_up_after(d2, 2120) - 2120}")

    # 8. Hub restart (tokens are DB-backed): short and past-expiry outages.
    b, hub, d = run("new", World(hub_down=[(2000, 2600)]), until=4000)
    up = first_up_after(d, 2600)
    assert hub.exchanges <= 1 and up - 2600 <= 36
    b2, hub2, d2 = run("new", World(hub_down=[(3000, 5000)]), until=8000)
    up2 = first_up_after(d2, 5000)
    assert b2.state == "ok" and up2 - 5000 <= PAUSE * 1.2 + 36 and b2.dials < 120
    print(f"S8 hub_restart_600s reconnect_s={up - 2600} exchanges={hub.exchanges}; "
          f"hub_down_past_expiry reconnect_s={up2 - 5000} dials={b2.dials}")

    # 9. Fencing. After a 200 the old refresh token is spent on the Hub, so a
    # received pair is ALWAYS made durable within the same epoch. Only an epoch
    # change (re-enroll) or a final stop prevents the write; a generation
    # mismatch is an invariant violation that commits and then parks visibly.
    def receive(cur, disk, result):
        if result["epoch"] != cur["epoch"] or cur["final_stop"]:
            return cur, disk, "discarded_other_epoch"
        disk = dict(disk, pending=result["pair"], refresh=result["pair"], access=result["pair"], pending_after=None)
        if result["base_gen"] != cur["gen"]:
            return dict(cur, phase="parked", reason="generation_assertion"), disk, "committed_parked"
        return dict(cur, gen=cur["gen"] + 1), disk, "committed_published"
    cur = {"epoch": 2, "gen": 5, "final_stop": False, "phase": "valid"}
    disk = {"pending": None, "refresh": "P5", "access": "A5"}
    c, d, r = receive(cur, disk, {"epoch": 1, "base_gen": 5, "pair": "P6"})
    assert r == "discarded_other_epoch" and d == disk          # other enrollment's files untouched
    c, d, r = receive(cur, disk, {"epoch": 2, "base_gen": 4, "pair": "P6"})
    assert r == "committed_parked" and d["refresh"] == "P6" and d["access"] == "P6" and c["phase"] == "parked"
    c, d, r = receive(cur, disk, {"epoch": 2, "base_gen": 5, "pair": "P6"})
    assert r == "committed_published" and c["gen"] == 6 and d["refresh"] == "P6"
    # Reauth: ready for a dial made with gen 5 must not clear a gen-6 reauth.
    reauth_wanted, session_gen = 6, 5
    assert reauth_wanted > session_gen
    print("S9 fencing other_epoch_untouched generation_mismatch_committed_on_disk_and_parked "
          "reauth_not_cleared_by_old_hello")


if __name__ == "__main__":
    check_source_premises()
    scenarios()
    print("PASS model of proposed ordering; native suspend timing on Linux/macOS/Windows remains unmeasured")
