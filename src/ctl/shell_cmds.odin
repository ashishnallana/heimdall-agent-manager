package main

import json "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import httpc "odin_test:lib/httpc"
import jsonx "odin_test:lib/jsonx"
import os_random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"

// ── shell verb group ─────────────────────────────────────────────────────────
// Subcommands managing the three session kinds on the Bridge host. All calls
// route through the local Bridge via agent.rest.request (same auth token as
// task/chat commands).
//
// REQ-SHELL-2 added the two verbs an AGENT reaches for, both over the SAME create
// endpoint every other kind uses — there is no second spawn path:
//
//   run    one-shot command, agent-only, FOREGROUND by default. Backgrounding is
//          explicit (--bg); there is no duration at which it happens by itself.
//   serve  long-running process with an OPTIONAL exposable port.
//
// `start` remains the general form for anyone who wants to name the kind
// themselves. run and serve exist because they are what the agent actually means,
// and they fill the scope columns from the agent's own context so nobody has to
// remember which kind is keyed by what.

ctl_agentmode_shell :: proc(endpoint, token: string, tokens, args: []string) {
	verb := pos(tokens, 0)
	switch verb {
	case "start":
		ctl_shell_start(endpoint, token, tokens, args)
	case "run":
		ctl_shell_run(endpoint, token, tokens, args)
	case "serve":
		ctl_shell_serve(endpoint, token, tokens, args)
	case "background":
		ctl_shell_background(endpoint, token, tokens, args)
	case "kill":
		ctl_shell_kill(endpoint, token, tokens, args)
	case "signal":
		ctl_shell_signal(endpoint, token, tokens, args)
	case "restart":
		ctl_shell_restart(endpoint, token, tokens, args)
	case "set-port":
		ctl_shell_set_port(endpoint, token, tokens, args)
	case "show":
		ctl_shell_show(endpoint, token, tokens, args)
	case "list":
		ctl_shell_list(endpoint, token, tokens, args)
	case "log":
		ctl_shell_log(endpoint, token, tokens, args)
	case "capture":
		ctl_shell_capture(endpoint, token, tokens, args)
	case "", "--help", "-h", "help":
		print_help_shell()
	case:
		print_help_shell()
	}
}

// ctl_shell_rest calls a REST endpoint via the Bridge agent.rest.request RPC.
ctl_shell_rest :: proc(endpoint, token: string, req: Ctl_Request) {
	ctl_agent_rest(endpoint, token, req)
}

ctl_shell_preview_url_from_response :: proc(response: string) -> string {
	parsed, err := json.parse(transmute([]byte)response)
	if err != nil do return ""
	defer json.destroy_value(parsed)
	node, ok := parsed.(json.Object)
	if !ok do return ""
	for _ in 0 ..< 4 {
		if session, got := node["session"].(json.Object); got {
			if value, present := session["preview_url"].(json.String); present do return strings.clone(string(value))
		}
		if value, present := node["preview_url"].(json.String); present do return strings.clone(string(value))
		inner, got := node["data"].(json.Object)
		if !got do break
		node = inner
	}
	return ""
}

ctl_shell_rest_with_preview :: proc(endpoint, token: string, req: Ctl_Request) {
	response, ok := ctl_agent_rest_local(endpoint, token, req)
	if !ok {
		fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`)
		return
	}
	fmt.println(response)
	preview_url := ctl_shell_preview_url_from_response(response)
	defer if preview_url != "" do delete(preview_url)
	if preview_url != "" do fmt.println("Preview:", preview_url)
}

// ctl_shell_bridge_boot_id returns the target bridge's current unseal boot id, read
// from the hub (GET /api/v1/bridges/<id>/public-key). An enc_spec is bound to it, so
// an unknown boot id aborts. Test builds take --bridge-boot-id instead of the network.
ctl_shell_bridge_boot_id :: proc(endpoint, token, bridge_id: string, args: []string) -> string {
	when ODIN_TEST {
		if has_flag(args, "--bridge-boot-id") do return option_value(args, "--bridge-boot-id", "")
	}
	response, ok := ctl_agent_rest_local(endpoint, token, {method = .GET, path = ctl_api("bridges", bridge_id, "public-key")})
	if !ok do return ""
	defer delete(response)
	// The local reply wraps the hub's answer: {"data":{"data":{...,"unseal_boot_id"}}}.
	// One or both envelope levels may be absent.
	Boot_Id :: struct {
		unseal_boot_id: string,
	}
	envelope: struct {
		unseal_boot_id: string,
		data:           struct {
			unseal_boot_id: string,
			data:           Boot_Id,
		},
	}
	if !vault.wire_decode(response, &envelope) do return ""
	boot := envelope.data.data.unseal_boot_id
	if boot == "" do boot = envelope.data.unseal_boot_id
	if boot == "" do boot = envelope.unseal_boot_id
	return strings.clone(boot, context.temp_allocator)
}

// Ctl_Shell_Enc_Spec is the sealed shell start spec (the bridge decodes it into
// Bridge_Shell_Enc_Spec_Wire): cmd/cwd bound to bridge, session, kind and boot id.
Ctl_Shell_Enc_Spec :: struct {
	cmd:        string,
	cwd:        string,
	timestamp:  i64,
	nonce:      string,
	bridge_id:  string,
	session_id: string,
	kind:       string,
	boot_id:    string,
}

ctl_shell_boot_id_valid :: proc(boot_id: string) -> bool {
	if boot_id == "" || len(boot_id) > 64 do return false
	for c in transmute([]u8)boot_id {
		switch c {
		case '0' ..= '9', 'a' ..= 'f':
		case:
			return false
		}
	}
	return true
}

// ctl_shell_attach_enc_spec appends a client-chosen session_id and the enc_spec that
// authorizes exactly that start: the sealed spec binds cmd/cwd to the bridge id, the
// session id, the kind and the bridge's current boot id (finding N1). There is no
// plaintext shell start: without a keyring, randomness or the boot id this exits.
ctl_shell_attach_enc_spec :: proc(endpoint, token, bridge_id, kind: string, args: []string, cmd_str, cwd_str: string, body: ^Ctl_Shell_Create_Body) {
	keyring := ctl_vault_keyring_for_write(args)
	boot_id := ctl_shell_bridge_boot_id(endpoint, token, bridge_id, args)
	if !ctl_shell_boot_id_valid(boot_id) {
		fmt.println(`{"ok":false,"message":"the bridge has not announced a boot id; refusing to build enc_spec"}`)
		os.exit(1)
	}
	random_bytes: [32]byte
	if !os_random.fill(random_bytes[:]) {
		fmt.println(`{"ok":false,"message":"system randomness unavailable; refusing to build enc_spec"}`)
		os.exit(1)
	}
	nonce_hex := vault.hex_encode_lower(random_bytes[:16], context.temp_allocator)
	session_id := strings.concatenate({"sh_", vault.hex_encode_lower(random_bytes[16:], context.temp_allocator)}, context.temp_allocator)
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000
	spec_json, spec_ok := vault.wire_encode(Ctl_Shell_Enc_Spec{
		cmd = cmd_str, cwd = cwd_str, timestamp = now_ms, nonce = nonce_hex,
		bridge_id = bridge_id, session_id = session_id, kind = kind, boot_id = boot_id,
	}, context.temp_allocator)
	if !spec_ok {
		fmt.println(`{"ok":false,"message":"could not encode enc_spec"}`)
		os.exit(1)
	}
	body.session_id = session_id
	// The bridge rejects enc_spec under any epoch but its current one (command
	// epoch floor); ctl_seal_or_exit always seals under the current epoch.
	body.enc_spec = ctl_seal_or_exit(spec_json, keyring)
}

// Ctl_Shell_Create_Body: POST /api/v1/bridges/<bridge>/shells for every kind.
// cmd and cwd never appear here: they travel only inside the sealed enc_spec.
Ctl_Shell_Create_Body :: struct {
	kind:              string     `json:"kind"`,
	label:             string     `json:"label,omitempty"`,
	server_port:       Maybe(u64) `json:"server_port,omitempty"`,
	project_id:        string     `json:"project_id,omitempty"`,
	chain_id:          string     `json:"chain_id,omitempty"`,
	agent_instance_id: string     `json:"agent_instance_id,omitempty"`,
	conversation_id:   string     `json:"conversation_id,omitempty"`,
	background:        Maybe(bool) `json:"background,omitempty"`,
	session_id:        string     `json:"session_id,omitempty"`,
	enc_spec:          string     `json:"enc_spec,omitempty"`,
}

// ctl_shell_port_value converts a ctl_shell_uint_flag result ("" = absent).
ctl_shell_port_value :: proc(digits: string) -> Maybe(u64) {
	if digits == "" do return nil
	v, ok := strconv.parse_u64(digits)
	if !ok do return nil
	return v
}

// start — POST /api/v1/bridges/{bridge_id}/shells
// Flags: --kind, --cmd, --cwd, --label, --port, --project, --chain, --agent
// Prints: {session_id, status, pid}
ctl_shell_start :: proc(endpoint, token: string, tokens, args: []string) {
	bridge_id := option_value(args, "--bridge", "")
	if bridge_id == "" {
		fmt.println(`{"ok":false,"message":"shell start requires --bridge <bridge_id>"}`)
		return
	}
	// Defaults to `shell`, the kind a person starting a session from the CLI means.
	// `run` is agent-scoped and needs an --agent, so it is never the default here.
	kind := option_value(args, "--kind", "shell")
	// cmd and cwd go only inside the sealed enc_spec (never in clear to the hub).
	cmd_val := option_value(args, "--cmd", "")
	cwd_val := option_value(args, "--cwd", "")
	body := Ctl_Shell_Create_Body{
		kind              = kind,
		label             = option_value(args, "--label", ""),
		server_port       = ctl_shell_port_value(ctl_shell_uint_flag(args, "--port", "")),
		project_id        = option_value(args, "--project", ""),
		chain_id          = option_value(args, "--chain", ""),
		agent_instance_id = option_value(args, "--agent", ""),
	}
	ctl_shell_attach_enc_spec(endpoint, token, bridge_id, kind, args, cmd_val, cwd_val, &body)
	ctl_shell_rest_with_preview(endpoint, token, {method = .POST, path = ctl_api("bridges", bridge_id, "shells"), body = httpc.json_body(body)})
}

// ---- agent context resolution ------------------------------------------------

// Ctl_Shell_Context is the identity `run` and `serve` need to fill a session's
// scope columns: which bridge to create on, which agent instance owns a run,
// which chain a server belongs to, and which conversation triggered either.
Ctl_Shell_Context :: struct {
	bridge_id:         string,
	agent_instance_id: string,
	chain_id:          string,
	conversation_id:   string,
	project_id:        string,
}

// ctl_shell_context fetches the calling agent's own context from the hub
// (agent.context.get), so `shell run` and `shell serve` are single-flag commands
// rather than asking the agent to restate identity it already has.
//
// This is ONE extra round trip, and it buys the property that matters most here:
// the scope columns cannot be got wrong. A run whose agent_instance_id is empty
// cannot be rendered against the conversation that asked for it, and a server
// with no chain_id is invisible to its own chain summary — both are silent
// failures at the far end of the system, days later, not errors at the call.
// Deriving them from the agent's identity makes both unrepresentable.
//
// Every field is still overridable by an explicit flag (see the callers); this is
// the default, not a lock.
ctl_shell_context :: proc(endpoint, token: string) -> (Ctl_Shell_Context, bool) {
	response, ok := ctl_agent_local_call(endpoint, token, "agent.context.get", "{}")
	if !ok do return {}, false

	parsed, jerr := json.parse(transmute([]byte)response)
	if jerr != nil do return {}, false
	defer json.destroy_value(parsed)

	// The local endpoint wraps every hub reply as {v,id,ok,data:{data:{...}}}; the
	// context object is at whichever depth carries agent_instance_id, so descend
	// through the envelope rather than hard-coding a path that a future envelope
	// change would silently break.
	obj, is_obj := parsed.(json.Object)
	if !is_obj do return {}, false
	node := obj
	for _ in 0 ..< 4 {
		if _, has := node["agent_instance_id"]; has do break
		inner, got := node["data"].(json.Object)
		if !got do break
		node = inner
	}

	read :: proc(o: json.Object, key: string) -> string {
		if v, ok := o[key].(json.String); ok do return string(v)
		return ""
	}
	ctx := Ctl_Shell_Context{
		bridge_id         = strings.clone(read(node, "bridge_id")),
		agent_instance_id = strings.clone(read(node, "agent_instance_id")),
		chain_id          = strings.clone(read(node, "chain_id")),
		conversation_id   = strings.clone(read(node, "conversation_id")),
		project_id        = strings.clone(read(node, "project_id")),
	}
	return ctx, ctx.agent_instance_id != ""
}

// ctl_shell_session_id_from_response digs the created session's id out of a
// create reply. Same envelope descent as above, for the same reason.
ctl_shell_session_id_from_response :: proc(response: string) -> string {
	parsed, jerr := json.parse(transmute([]byte)response)
	if jerr != nil do return ""
	defer json.destroy_value(parsed)
	obj, is_obj := parsed.(json.Object)
	if !is_obj do return ""

	node := obj
	for _ in 0 ..< 5 {
		if sess, has := node["session"].(json.Object); has {
			if v, ok := sess["session_id"].(json.String); ok do return strings.clone(string(v))
		}
		if v, ok := node["session_id"].(json.String); ok do return strings.clone(string(v))
		inner, got := node["data"].(json.Object)
		if !got do break
		node = inner
	}
	return ""
}

// run — POST /api/v1/bridges/{bridge_id}/shells with kind=run
// Flags: --cmd (required), --cwd, --label, --bg, --bridge
//
// FOREGROUND BY DEFAULT: the call blocks until the command finishes and prints
// its output inline, and NO notification is sent — you are holding the answer, so
// a message about it would be noise. There is no elapsed time at which this turns
// into something else; the 15s auto-background rule that used to do that is gone.
//
// --bg returns immediately with the session id and notifies on completion.
//
// The block is a LOCAL call to the bridge that owns the process (agent.shell.wait),
// not a long hub request: the hub transport times out at 20s and a run may take
// half an hour. The local endpoint has no receive timeout, so no shared client
// path is lengthened to make this work.
//
// Interrupting this command does NOT affect the run. The session is registered
// and persisted before the wait begins, so a Ctrl-C leaves a run that is still
// live, still tracked, still readable with `shell log` and still killable with
// `shell kill`.
ctl_shell_run :: proc(endpoint, token: string, tokens, args: []string) {
	cmd := option_value(args, "--cmd", "")
	if strings.trim_space(cmd) == "" {
		fmt.println(`{"ok":false,"message":"shell run requires --cmd '<command>'"}`)
		return
	}

	ctx, ctx_ok := ctl_shell_context(endpoint, token)
	bridge_id := option_value(args, "--bridge", ctx.bridge_id)
	if bridge_id == "" {
		fmt.println(`{"ok":false,"message":"shell run could not resolve your bridge; pass --bridge <bridge_id>"}`)
		return
	}
	if !ctx_ok && option_value(args, "--agent", "") == "" {
		fmt.println(`{"ok":false,"message":"shell run could not resolve your agent instance; a run is agent-scoped and cannot be created without it"}`)
		return
	}

	background := has_flag(args, "--bg")

	body := Ctl_Shell_Create_Body{kind = "run"}
	// cmd and cwd go only inside the sealed enc_spec (never in clear to the hub).
	// agent_instance_id is a run's SCOPE KEY. The hub also fills it from the
	// caller's token, so this is belt-and-braces rather than the only source —
	// which is why an explicit --agent cannot be used to attribute a run elsewhere.
	body.agent_instance_id = option_value(args, "--agent", ctx.agent_instance_id)
	// The TRIGGERING conversation. A run's completion notice and its one `shell_run`
	// marker go here and nowhere else — never to a chain-wide or user-wide feed.
	//
	// TAKEN FROM CONTEXT, with no flag to override it (REQ-SHELL-5 AC9). There used to
	// be a `--conversation` here whose default was already ctx.conversation_id, so the
	// flag could only ever replace the correct answer with a different one. The hub now
	// resolves a run's conversation from the caller's token regardless
	// (shell_session_create), so sending anything else was at best ignored and at worst
	// an attempt to write into somebody else's conversation.
	body.conversation_id = ctx.conversation_id
	// project_id is an annotation every kind may carry, not a scope column.
	body.project_id = option_value(args, "--project", ctx.project_id)
	// chain_id is deliberately NOT sent: a run is agent-scoped and the hub refuses
	// one that carries a chain rather than storing a column that describes nothing.
	cwd_val := option_value(args, "--cwd", "")
	body.label = option_value(args, "--label", "")
	if background do body.background = true
	ctl_shell_attach_enc_spec(endpoint, token, bridge_id, "run", args, cmd, cwd_val, &body)

	response, ok := ctl_agent_rest_local(endpoint, token, {method = .POST, path = ctl_api("bridges", bridge_id, "shells"), body = httpc.json_body(body)})
	if !ok {
		fmt.println(`{"ok":false,"message":"local Bridge endpoint is not reachable"}`)
		return
	}

	// --bg: the session id IS the answer. Print the create reply and stop.
	if background {
		fmt.println(response)
		return
	}

	session_id := ctl_shell_session_id_from_response(response)
	if session_id == "" {
		// The create failed, or returned a shape we do not recognise. Print it
		// verbatim rather than replacing a real error with a wait we cannot perform.
		fmt.println(response)
		return
	}
	defer delete(session_id)

	ctl_agent_call(endpoint, token, "agent.shell.wait", json_object(json_kv("session_id", session_id)))
}

// serve — POST /api/v1/bridges/{bridge_id}/shells with kind=server
// Flags: --cmd (required), --port, --cwd, --label, --bridge, --chain
//
// A server is long-running and is NOT subject to the 30-minute cap that bounds a
// run. It returns as soon as it has started; there is nothing to wait for.
//
// --port is OPTIONAL. A server with no port is perfectly valid and simply exposes
// nothing — the port is what makes it reachable through the existing
// preview/tunnel path, not what makes it a server.
//
// Agent OR user started, unlike run. A server is chain-scoped, so it is listed in
// its chain's summary whoever started it.
ctl_shell_serve :: proc(endpoint, token: string, tokens, args: []string) {
	cmd := option_value(args, "--cmd", "")
	if strings.trim_space(cmd) == "" {
		fmt.println(`{"ok":false,"message":"shell serve requires --cmd '<command>'"}`)
		return
	}

	ctx, _ := ctl_shell_context(endpoint, token)
	bridge_id := option_value(args, "--bridge", ctx.bridge_id)
	if bridge_id == "" {
		fmt.println(`{"ok":false,"message":"shell serve could not resolve your bridge; pass --bridge <bridge_id>"}`)
		return
	}
	chain_id := option_value(args, "--chain", ctx.chain_id)
	if chain_id == "" {
		fmt.println(`{"ok":false,"message":"shell serve requires a task chain; pass --chain <chain_id>"}`)
		return
	}

	// cmd and cwd go only inside the sealed enc_spec (never in clear to the hub).
	// chain_id + bridge_id are a server's SCOPE KEY: the chain summary lists every
	// server started for that chain, whoever started it.
	body := Ctl_Shell_Create_Body{kind = "server", chain_id = chain_id}
	// From context, no flag — same reasoning as `run` above (REQ-SHELL-5 AC9). A server
	// is chain-scoped, so this is an annotation recording who started it rather than a
	// scope column, and it is still the starting agent's own conversation.
	body.conversation_id = ctx.conversation_id
	body.project_id = option_value(args, "--project", ctx.project_id)
	// agent_instance_id is deliberately NOT sent: a server is chain-scoped, and the
	// hub refuses one that names an agent instance.
	cwd_val := option_value(args, "--cwd", "")
	body.label = option_value(args, "--label", "")
	body.server_port = ctl_shell_port_value(ctl_shell_uint_flag(args, "--port", ""))
	ctl_shell_attach_enc_spec(endpoint, token, bridge_id, "server", args, cmd, cwd_val, &body)

	ctl_shell_rest_with_preview(endpoint, token, {method = .POST, path = ctl_api("bridges", bridge_id, "shells"), body = httpc.json_body(body)})
}

// background — POST /api/v1/shells/{session_id}/background
// Converts a live FOREGROUND run to a background one. One-way: a run that is
// already background, or already finished, is refused rather than silently
// accepted.
ctl_shell_background :: proc(endpoint, token: string, tokens, args: []string) {
	sid := pos(tokens, 1)
	if sid == "" {
		fmt.println(`{"ok":false,"message":"shell background requires <session_id>"}`)
		return
	}
	ctl_shell_rest(endpoint, token, {method = .POST, path = ctl_api("shells", sid, "background"), body = ctl_empty_object_body()})
}

// kill — DELETE /api/v1/shells/{session_id}
// Prints: {ok, outcome, message} — outcome is "delivered" (the bridge has the kill)
// or "queued" (bridge offline; the intent is durable and applies on reconnect,
// answered as HTTP 202). Both are successes, and they are deliberately
// distinguishable: a queued kill that printed the same thing as a delivered one
// would tell you the shell is dead while it is still running (REQ-SHELL-3).
ctl_shell_kill :: proc(endpoint, token: string, tokens, args: []string) {
	sid := pos(tokens, 1)
	if sid == "" {
		fmt.println(`{"ok":false,"message":"shell kill requires <session_id>"}`)
		return
	}
	ctl_shell_rest(endpoint, token, {method = .DELETE, path = ctl_api("shells", sid)})
}

// signal — POST /api/v1/shells/{session_id}/signal
// Flags: --signal <int>
ctl_shell_signal :: proc(endpoint, token: string, tokens, args: []string) {
	sid := pos(tokens, 1)
	sig := ctl_shell_uint_flag(args, "--signal", "")
	if sid == "" || sig == "" {
		fmt.println(`{"ok":false,"message":"shell signal requires <session_id> --signal <int>"}`)
		return
	}
	Signal_Body :: struct {
		signal: u64 `json:"signal"`,
	}
	sig_value, _ := strconv.parse_u64(sig)
	ctl_shell_rest(endpoint, token, {method = .POST, path = ctl_api("shells", sid, "signal"), body = httpc.json_body(Signal_Body{signal = sig_value})})
}

// restart — POST /api/v1/shells/{session_id}/restart
// Prints: {session_id, pid, status}
ctl_shell_restart :: proc(endpoint, token: string, tokens, args: []string) {
	sid := pos(tokens, 1)
	if sid == "" {
		fmt.println(`{"ok":false,"message":"shell restart requires <session_id>"}`)
		return
	}
	ctl_shell_rest(endpoint, token, {method = .POST, path = ctl_api("shells", sid, "restart"), body = ctl_empty_object_body()})
}

// set-port — POST /api/v1/shells/{session_id}/port
// Flags: --port <n> | --clear
// Declares the port of a session that is ALREADY running, for the common case of
// opening a terminal and only then starting a server in it. Prints the updated
// session.
//
// --clear and --port 0 are the same request. 0 is the value the session record
// already uses for "no port", so it has to work; --clear is the spelling a
// reader finds without knowing that.
ctl_shell_set_port :: proc(endpoint, token: string, tokens, args: []string) {
	sid := pos(tokens, 1)
	if sid == "" {
		fmt.println(`{"ok":false,"message":"shell set-port requires <session_id> --port <n> (or --clear)"}`)
		return
	}

	// option_value rather than ctl_shell_uint_flag: that helper folds an invalid
	// value into its fallback, which would make a typo indistinguishable from an
	// omitted flag — and here the difference decides whether we clear the port.
	raw := strings.trim_space(option_value(args, "--port", ""))
	clearing := has_flag(args, "--clear")

	if clearing && raw != "" && raw != "0" {
		fmt.println(`{"ok":false,"message":"shell set-port: --clear and --port <n> conflict; pass one"}`)
		return
	}
	if !clearing && raw == "" {
		fmt.println(`{"ok":false,"message":"shell set-port requires --port <n> (1-65535) or --clear"}`)
		return
	}

	port := "0"
	if !clearing {
		for ch in raw {
			if ch < '0' || ch > '9' {
				fmt.println(`{"ok":false,"message":"shell set-port: --port must be a number between 1 and 65535, or use --clear"}`)
				return
			}
		}
		port = raw
	}

	Port_Body :: struct {
		server_port: u64 `json:"server_port"`,
	}
	port_value, _ := strconv.parse_u64(port)
	ctl_shell_rest_with_preview(endpoint, token, {method = .POST, path = ctl_api("shells", sid, "port"), body = httpc.json_body(Port_Body{server_port = port_value})})
}

// show — GET /api/v1/shells/{session_id}
ctl_shell_show :: proc(endpoint, token: string, tokens, args: []string) {
	sid := pos(tokens, 1)
	if sid == "" {
		fmt.println(`{"ok":false,"message":"shell show requires <session_id>"}`)
		return
	}
	ctl_shell_rest_with_preview(endpoint, token, {method = .GET, path = ctl_api("shells", sid)})
}

// list — GET /api/v1/shells with optional filters
// Flags: --bridge, --project, --chain, --status, --limit, --cursor
// With no flags: every shell the caller owns, across every bridge.
//
// All flags go to the one owner-wide route. Previously --bridge switched to
// /api/v1/bridges/{id}/shells, which reads only `status` — so
// `shell list --bridge X --project Y` silently ignored --project and listed the
// whole bridge. /api/v1/shells ANDs every filter, so each flag now narrows.
// The bridge-scoped route is untouched and keeps its other callers.
ctl_shell_list :: proc(endpoint, token: string, tokens, args: []string) {
	bridge_id := option_value(args, "--bridge", "")
	project_id := option_value(args, "--project", "")
	chain_id := option_value(args, "--chain", "")
	// A run is AGENT scoped, so it never appears in a bridge- or chain-narrowed
	// listing; this is the filter that names a run's own scope, and without it the
	// CLI could not list runs at all.
	agent_id := option_value(args, "--agent", "")
	status := option_value(args, "--status", "")

	query := ctl_query_make()
	ctl_query_add(&query, "bridge_id", bridge_id)
	ctl_query_add(&query, "project_id", project_id)
	ctl_query_add(&query, "chain_id", chain_id)
	ctl_query_add(&query, "agent_instance_id", agent_id)
	ctl_query_add(&query, "status", status)
	ctl_query_add(&query, "limit", ctl_shell_uint_flag(args, "--limit", ""))
	ctl_query_add(&query, "cursor", option_value(args, "--cursor", ""))
	ctl_shell_rest(endpoint, token, {method = .GET, path = ctl_api("shells"), query = query[:]})
}

// log — GET /api/v1/shells/{session_id}/log?offset=&limit=&grep=
// Flags: --offset, --limit, --grep
// Streams lines to stdout; response: {lines:[], truncated:bool, total_lines:int}
ctl_shell_log :: proc(endpoint, token: string, tokens, args: []string) {
	sid := pos(tokens, 1)
	if sid == "" {
		fmt.println(`{"ok":false,"message":"shell log requires <session_id>"}`)
		return
	}
	query := ctl_query_make()
	ctl_query_add(&query, "offset", ctl_shell_uint_flag(args, "--offset", ""))
	ctl_query_add(&query, "limit", ctl_shell_uint_flag(args, "--limit", ""))
	ctl_query_add(&query, "grep", option_value(args, "--grep", ""))
	ctl_shell_rest(endpoint, token, {method = .GET, path = ctl_api("shells", sid, "log"), query = query[:]})
}

// capture — GET /api/v1/shells/{session_id}/capture
// Prints current screen/terminal content snapshot.
ctl_shell_capture :: proc(endpoint, token: string, tokens, args: []string) {
	sid := pos(tokens, 1)
	if sid == "" {
		fmt.println(`{"ok":false,"message":"shell capture requires <session_id>"}`)
		return
	}
	// The bridge seals the screen (a v2 content envelope); decrypt it locally.
	params := ctl_agent_rest_params_or_exit({method = .GET, path = ctl_api("shells", sid, "capture")})
	ctl_agent_call_and_decrypt(endpoint, token, "agent.rest.request", params, args)
}

print_help_shell :: proc() {
	fmt.println("ham-ctl shell — manage PTY/shell sessions on the Bridge host")
	fmt.println("")
	fmt.println("THE THREE KINDS")
	fmt.println("  run     a one-shot command with captured output. AGENT ONLY.")
	fmt.println("          FOREGROUND by default; backgrounding is explicit (--bg).")
	fmt.println("  shell   an interactive terminal. USER ONLY. No output capture.")
	fmt.println("  server  a long-running process with output and an OPTIONAL port.")
	fmt.println("          Started by an agent or a user.")
	fmt.println("")
	fmt.println("VERBS")
	fmt.println("  run   --cmd '<command>' [--cwd <dir>] [--label <lbl>] [--bg]")
	fmt.println("        Run a command and WAIT for it, printing its output inline.")
	fmt.println("        No notification is sent — you are holding the result already.")
	fmt.println("        It does not matter how long it takes: a run is never moved to")
	fmt.println("        the background on its own.")
	fmt.println("        --bg returns immediately with a session id instead, and you are")
	fmt.println("        notified when it finishes.")
	fmt.println("        Ctrl-C does not stop the run. It keeps going, and you can still")
	fmt.println("        reach it with `shell log <id>` and `shell kill <id>`.")
	fmt.println("        Bridge, agent, conversation and project are taken from your own")
	fmt.println("        context. Bridge, agent and project can be overridden with a flag;")
	fmt.println("        the conversation cannot — a run belongs to the one that started it.")
	fmt.println("  serve --cmd '<command>' [--port <n>] [--cwd <dir>] [--label <lbl>]")
	fmt.println("        Start a long-running process. Returns as soon as it is up.")
	fmt.println("        NOT subject to the 30-minute cap that bounds a run.")
	fmt.println("        --port is OPTIONAL: with one, the server is reachable through the")
	fmt.println("        preview/tunnel path below; without one it simply exposes nothing.")
	fmt.println("        Two live sessions cannot hold the same port on one bridge — the")
	fmt.println("        second is refused, naming the session that holds it.")
	fmt.println("  background <session_id>              Move a running FOREGROUND run to the")
	fmt.println("        background. Releases whoever is waiting on it with the session id,")
	fmt.println("        and notifies on completion from then on. One-way.")
	fmt.println("  start --bridge <id> [--kind shell|server|run]   Launch a new session.")
	fmt.println("        Scope is per kind and enforced by the hub: server needs --chain,")
	fmt.println("        run needs --agent, shell needs neither.")
	fmt.println("        [--cmd <cmd>] [--cwd <dir>] [--label <lbl>]")
	fmt.println("        [--port <n>] [--project <id>] [--chain <id>]")
	fmt.println("        --port declares the port the process binds; it is what makes the")
	fmt.println("        session reachable over HTTP, whatever its kind (see REACHING A")
	fmt.println("        SERVER below). It can also be declared later with set-port.")
	fmt.println("        Prints: {session_id, status, pid}")
	fmt.println("  kill    <session_id>                 Terminate a session (DELETE).")
	fmt.println("        Reliable while the bridge is DISCONNECTED: the request is recorded")
	fmt.println("        durably and applied when the bridge next connects, if the process is")
	fmt.println("        still running. The reply says which happened, so success is never")
	fmt.println("        ambiguous:")
	fmt.println("          outcome=delivered  the bridge has it; the process is being killed now.")
	fmt.println("          outcome=queued     bridge offline; queued, applied on reconnect (HTTP 202).")
	fmt.println("        `message` is the same fact as a sentence. Refused on a session that")
	fmt.println("        has already terminated.")
	fmt.println("  signal  <session_id> --signal <int>  Send a POSIX signal to the session process.")
	fmt.println("        BEST-EFFORT, unlike kill: a signal is an interactive act aimed at the")
	fmt.println("        process as it is NOW, so it is never queued for later — if the bridge")
	fmt.println("        is offline this fails and you decide whether to ask again.")
	fmt.println("  restart <session_id>                 Stop then restart a session.")
	fmt.println("        Prints: {session_id, pid, status}")
	fmt.println("  set-port <session_id> --port <n> | --clear")
	fmt.println("        Declare (or clear) the port of a session that is ALREADY running —")
	fmt.println("        for when you open a terminal and only then start a server in it.")
	fmt.println("        Takes effect immediately, on both access paths, with no restart.")
	fmt.println("        --port 0 and --clear are the same request. Refused on a session")
	fmt.println("        that has exited, and on a session you do not own.")
	fmt.println("        Prints the updated session.")
	fmt.println("  show    <session_id>                 Show one session and its Preview URL.")
	fmt.println("  list  [--bridge <id>] [--project <id>] [--chain <id>] [--agent <id>] [--status <s>]")
	fmt.println("        [--limit N] [--cursor <c>]")
	fmt.println("        With NO flags: every shell you own, across every bridge, paginated.")
	fmt.println("        Filters are AND-ed, so --bridge X --status running means both.")
	fmt.println("        --agent <agent_instance_id> is how you list RUNS. A run is agent")
	fmt.println("        scoped, so it is deliberately absent from bridge- and chain-narrowed")
	fmt.println("        listings; --agent is the filter that names its scope.")
	fmt.println("        --status accepts a concrete status or the groups live | finished.")
	fmt.println("        Prints sessions including preview_url when a port is declared.")
	fmt.println("  log     <session_id> [--offset N] [--limit N] [--grep <pattern>]")
	fmt.println("        Stream log lines; response: {lines, truncated, total_lines}")
	fmt.println("  capture <session_id>                 Snapshot current terminal screen content.")
	fmt.println("")
	fmt.println("AUTH")
	fmt.println("  ham-ctl shell authenticates with your AGENT token: HEIMDALL_AGENT_TOKEN,")
	fmt.println("  or --agent-token if you pass it explicitly. That is the only credential")
	fmt.println("  involved — no user token and no browser session. The call goes to the local")
	fmt.println("  Bridge endpoint, which relays it to the Hub on your behalf.")
	fmt.println("")
	fmt.println("REACHING A SERVER SESSION OVER HTTP")
	fmt.println("  When the Hub has a preview origin configured, serve/start/show print its")
	fmt.println("  canonical Preview URL. Use that URL exactly; do not construct a preview path.")
	fmt.println("")
	fmt.println("  A session started with --kind server --port N is reachable from this host")
	fmt.println("  through the Bridge's local endpoint. No inbound port is opened on either")
	fmt.println("  machine and no user token or browser session is involved:")
	fmt.println("")
	fmt.println("      http://127.0.0.1:<local_endpoint_port>/proxy/<session_id>/<path>")
	fmt.println("")
	fmt.println("  The Bridge relays over the WebSocket it already holds to the Hub, the Hub")
	fmt.println("  splices it to the Bridge owning <session_id>, and that Bridge dials")
	fmt.println("  127.0.0.1:<declared port>. Method, path, query and body are forwarded.")
	fmt.println("")
	fmt.println("  The local endpoint is the same one ham-ctl itself uses — a unix socket in")
	fmt.println("  HEIMDALL_BRIDGE_ENDPOINT, with a TCP fallback (default port 49324). Find it:")
	fmt.println("      ham-ctl bridge list --scope configured    -> {local_endpoint_port: 49324}")
	fmt.println("")
	fmt.println("  The target session must be status=running with a declared port, and be")
	fmt.println("  owned by you; cross-owner targets are refused. Its kind does not matter —")
	fmt.println("  a `shell` you started a server inside is reachable too, and")
	fmt.println("  set-port is how you declare that port after the fact.")
	fmt.println("")
	fmt.println("  EXAMPLE (both transports; each line below has been run end to end)")
	fmt.println("      ham-ctl shell start --bridge brg_abc --kind server --chain chain_abc --port 8000 \\")
	fmt.println("        --cwd /srv/site --cmd 'python3 -m http.server 8000 --bind 127.0.0.1'")
	fmt.println("      # -> {session_id: sh_123, status: running, pid: ...}")
	fmt.println("      curl http://127.0.0.1:49324/proxy/sh_123/index.html")
	fmt.println("      curl --unix-socket \"${HEIMDALL_BRIDGE_ENDPOINT#unix:}\" \\")
	fmt.println("        http://localhost/proxy/sh_123/index.html")
	fmt.println("")
	fmt.println("  REFUSALS (JSON body, {error: <reason>})")
	fmt.println("      404 session_not_found     no such session, or not yours")
	fmt.println("      409 session_not_running   session exited")
	fmt.println("      409 no_server_port        no port declared (see set-port)")
	fmt.println("      403 cross_owner           target belongs to another user")
	fmt.println("      503 unavailable           bridge cannot reach the hub right now")
	fmt.println("")
	fmt.println("  Any process on this host that can reach the local endpoint can use this and")
	fmt.println("  acts with the Bridge owner's authority. Disable with --no-local-proxy or")
	fmt.println("  [bridge] local_proxy_enabled=false.")
	fmt.println("")
	fmt.println("EXAMPLES")
	fmt.println("  ham-ctl shell run --cmd 'go test ./...'          # waits, prints output")
	fmt.println("  ham-ctl shell run --cmd 'make release' --bg      # returns a session id")
	fmt.println("  ham-ctl shell serve --cmd 'npm run dev' --port 5173")
	fmt.println("  ham-ctl shell background sh_123")
	fmt.println("  ham-ctl shell start --bridge brg_abc --kind shell --cmd bash --label 'my shell'")
	fmt.println("  ham-ctl shell list")
	fmt.println("  ham-ctl shell list --bridge brg_abc --status running")
	fmt.println("  ham-ctl shell log  sess_123 --limit 50 --grep error")
	fmt.println("  ham-ctl shell capture sess_123")
	fmt.println("  ham-ctl shell signal sess_123 --signal 2")
	fmt.println("  ham-ctl shell restart sess_123")
	fmt.println("  ham-ctl shell set-port sess_123 --port 3000")
	fmt.println("  ham-ctl shell set-port sess_123 --clear")
	fmt.println("  ham-ctl shell kill sess_123")
}
