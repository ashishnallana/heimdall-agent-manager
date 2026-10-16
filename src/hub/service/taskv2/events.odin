package taskv2

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Event kinds. task_events is the single source of truth for a task's ticket
// state: `fold_task` (fold.odin) derives state, attempt number and badges from
// the ordered list below. Payloads are JSON objects stored verbatim.
//
// State-bearing kinds (the fold reacts to them):
EV_MIGRATED          :: "migrated"           // {from_status, state, published, attempt_no, blocked_on?}
EV_PUBLISHED         :: "published"          // {brief?}
EV_LEASE_GRANTED     :: "lease_granted"      // {lease_id, kind, instance_id, attempt_no, bridge_id, provider, model, delivery, review_role?}
EV_SUBMITTED         :: "submitted"          // {lease_id, attempt_no, auto?, gate?}
EV_BLOCKED           :: "blocked"            // {lease_id?, attempt_no, waiting_on:{kind, ref?, reason?}}
EV_HANDOFF           :: "handoff"            // {lease_id, attempt_no}
EV_LEASE_EXPIRED     :: "lease_expired"      // {lease_id, kind, attempt_no, reason}
EV_CHANGES_REQUESTED :: "changes_requested"  // {attempt_no, role, reviewer}
EV_APPROVED          :: "approved"           // {attempt_no}
EV_CANCELLED         :: "cancelled"          // {reason}
EV_REOPENED          :: "reopened"           // {}
EV_ANSWERED          :: "answered"           // {}
// Audit-only kinds (no fold effect):
EV_CREATED           :: "created"
EV_UPDATED           :: "updated"            // {fields:[…]}
EV_DEP_ADDED         :: "dep_added"          // {depends_on}
EV_DEP_REMOVED       :: "dep_removed"        // {depends_on}
EV_LEASE_CONFIRMED   :: "lease_confirmed"    // {lease_id}
EV_LEASE_RESENT      :: "lease_resent"       // {lease_id}
EV_ATTEMPT_STARTED   :: "attempt_started"    // {attempt_no, vcs_base}
EV_HEARTBEAT         :: "heartbeat"          // {lease_id, note}  (only when note is non-empty)
EV_REVIEW_POSTED     :: "review_posted"      // {attempt_no, role, verdict, reviewer}
EV_COMMENT           :: "comment"            // {comment_id}
EV_READY_UNCLAIMED   :: "ready_unclaimed"    // {since}  — alert
EV_BLOCKED_REALERT   :: "blocked_realert"    // {since}  — 24 h re-alert
EV_SUMMARY_OVERFLOW  :: "summary_overflow"
EV_STARTED_WORKFLOW  :: "started_workflow"   // {chain_id}

// Expiry reasons. `replaced`, `dep_added` and `reopen` are STRUCTURAL: the
// attempt they end does not count toward the budget (fold rule).
EXPIRE_TTL           :: "ttl"
EXPIRE_HARD_CAP      :: "hard_cap"
EXPIRE_IDLE          :: "idle"
EXPIRE_INSTANCE_LOST :: "instance_lost"
EXPIRE_UNCONFIRMED   :: "grant_unconfirmed"
EXPIRE_REPLACED      :: "replaced"
EXPIRE_DEP_ADDED     :: "dep_added"
EXPIRE_CHAIN_CLOSED  :: "chain_closed"
EXPIRE_CANCELLED     :: "cancelled"
EXPIRE_CHANGES_REQUESTED :: "changes_requested" // review leases dropped after a request_changes
EXPIRE_HUB_RESTART   :: "hub_restart_no_lease"  // boot: in_progress row without a lease row

ACTOR_HUB    :: "hub"
ACTOR_AGENT  :: "agent"
ACTOR_USER   :: "user"
ACTOR_BRIDGE :: "bridge"

// Actor identifies who caused an event. Hub timers use Actor{} (kind "hub").
Actor :: struct {
	kind: string,
	id:   string,
}

actor_from_auth :: proc(auth: contracts.Auth_Context) -> Actor {
	switch auth.kind {
	case .Instance_Token: return Actor{kind = ACTOR_AGENT, id = auth.agent_instance_id}
	case .User_Token, .Trusted_Proxy: return Actor{kind = ACTOR_USER, id = auth.user_id}
	case .Bridge_Token: return Actor{kind = ACTOR_BRIDGE, id = auth.bridge_id}
	case .Enrollment_Token, .None:
	}
	return Actor{kind = ACTOR_HUB}
}

hub_actor :: proc() -> Actor { return Actor{kind = ACTOR_HUB} }

// append_event writes one event for `task` (within the caller's unit of work)
// and returns it with its event_id. The payload must already be a JSON object
// (use the json_* helpers below); it is stored verbatim.
append_event :: proc(repo: ^iface.Taskchain_Repository, clock: ^platform.Clock, task: domain.Task, actor: Actor, kind: string, payload_json: string) -> (domain.Task_Event, bool, domain.Domain_Error) {
	ev := domain.Task_Event{
		task_id = task.task_id,
		chain_id = task.chain_id,
		owner_user_id = task.owner_user_id,
		ts_ms = now_ms(clock),
		actor_kind = actor.kind if actor.kind != "" else ACTOR_HUB,
		actor_id = actor.id,
		kind = kind,
		payload_json = payload_json if strings.trim_space(payload_json) != "" else "{}",
	}
	return iface.taskchain_append_event(repo, ev)
}

// now_ms reads the service clock (RFC3339, second precision) as unix ms so that
// tests driving a fake clock order events deterministically.
now_ms :: proc(clock: ^platform.Clock) -> i64 {
	if ms, ok := platform.rfc3339_to_unix_ms(platform.clock_now(clock)); ok do return ms
	return 0
}

// ---- tiny JSON object builder ------------------------------------------------
// Payloads are small and flat; a builder keeps the engine free of core:encoding/json
// (which re-marshals and drops unknown keys — the exact thing verbatim storage
// is meant to avoid elsewhere).

Json_Object :: struct {
	b:     strings.Builder,
	count: int,
}

json_begin :: proc(allocator := context.allocator) -> Json_Object {
	o := Json_Object{b = strings.builder_make(allocator)}
	strings.write_byte(&o.b, '{')
	return o
}

@(private = "file")
json_key :: proc(o: ^Json_Object, key: string) {
	if o.count > 0 do strings.write_byte(&o.b, ',')
	o.count += 1
	strings.write_byte(&o.b, '"')
	contracts.write_json_string(&o.b, key)
	strings.write_string(&o.b, "\":")
}

json_str :: proc(o: ^Json_Object, key, value: string) {
	json_key(o, key)
	strings.write_byte(&o.b, '"')
	contracts.write_json_string(&o.b, value)
	strings.write_byte(&o.b, '"')
}

json_int :: proc(o: ^Json_Object, key: string, value: i64) {
	json_key(o, key)
	buf: [24]byte
	strings.write_string(&o.b, i64_to_string(value, buf[:]))
}

json_bool :: proc(o: ^Json_Object, key: string, value: bool) {
	json_key(o, key)
	strings.write_string(&o.b, "true" if value else "false")
}

// json_raw splices an already-valid JSON value verbatim.
json_raw :: proc(o: ^Json_Object, key, raw: string) {
	json_key(o, key)
	strings.write_string(&o.b, raw if strings.trim_space(raw) != "" else "null")
}

json_end :: proc(o: ^Json_Object) -> string {
	strings.write_byte(&o.b, '}')
	return strings.to_string(o.b)
}

@(private = "file")
i64_to_string :: proc(v: i64, buf: []byte) -> string {
	n := v
	neg := n < 0
	if neg do n = -n
	i := len(buf)
	if n == 0 {
		i -= 1
		buf[i] = '0'
	}
	for n > 0 {
		i -= 1
		buf[i] = byte('0' + n % 10)
		n /= 10
	}
	if neg {
		i -= 1
		buf[i] = '-'
	}
	return string(buf[i:])
}

// raw_object_field returns the VERBATIM text of the top-level object value at
// `key` in a JSON object (no re-marshalling, so key order and spacing are kept
// exactly as written — which is what makes "cached projection == fold" a string
// equality). Payloads here are hub-written and well-formed; a malformed body
// returns ok=false.
raw_object_field :: proc(payload, key: string) -> (string, bool) {
	n := len(payload)
	i := 0
	depth := 0
	in_str := false
	esc := false
	// scan for `"key"` at depth 1 followed by ':' and '{'
	for i < n {
		c := payload[i]
		if in_str {
			if esc { esc = false } else if c == '\\' { esc = true } else if c == '"' { in_str = false }
			i += 1
			continue
		}
		switch c {
		case '"':
			if depth == 1 {
				// candidate key
				end := i + 1
				for end < n && payload[end] != '"' {
					if payload[end] == '\\' do end += 1
					end += 1
				}
				if end >= n do return "", false
				found := payload[i+1:end]
				j := end + 1
				for j < n && (payload[j] == ' ' || payload[j] == '\t' || payload[j] == '\n' || payload[j] == '\r') do j += 1
				if j < n && payload[j] == ':' && found == key {
					j += 1
					for j < n && (payload[j] == ' ' || payload[j] == '\t' || payload[j] == '\n' || payload[j] == '\r') do j += 1
					if j >= n || payload[j] != '{' do return "", false
					// balanced scan of the object
					k := j
					d := 0
					s := false
					e := false
					for k < n {
						ch := payload[k]
						if s {
							if e { e = false } else if ch == '\\' { e = true } else if ch == '"' { s = false }
						} else if ch == '"' {
							s = true
						} else if ch == '{' {
							d += 1
						} else if ch == '}' {
							d -= 1
							if d == 0 do return payload[j:k+1], true
						}
						k += 1
					}
					return "", false
				}
				// not our key: skip the string (and its value is scanned normally)
				i = end + 1
				continue
			}
			in_str = true
		case '{':
			depth += 1
		case '}':
			depth -= 1
		}
		i += 1
	}
	return "", false
}
