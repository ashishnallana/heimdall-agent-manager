package http

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import platform "odin_test:hub/platform"

Experiment_Rest_Handlers :: struct {
	auth:  ^auth_service.Auth_Service,
	repo:  ^iface.Experiment_Repository,
	clock: ^platform.Clock,
}

write_experiment_json :: proc(b: ^strings.Builder, exp: domain.Experiment) {
	strings.write_string(b, "{\"key\":\"")
	write_handler_json_string(b, exp.key)
	strings.write_string(b, "\",\"enabled\":")
	strings.write_string(b, "true" if exp.enabled else "false")
	strings.write_string(b, ",\"updated_at\":\"")
	write_handler_json_string(b, exp.updated_at)
	strings.write_string(b, "\"}")
}

// GET /api/v1/me/experiments
// Lists all experiment flags for the authenticated user.
// A key the user never set is listed with its default when it is default-on
// (domain.EXPERIMENTS_DEFAULT_ON); any other unset key is absent, and callers treat
// missing keys as disabled.
experiment_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Experiment_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	exps, err := iface.experiment_list_by_owner(h.repo, auth_ctx.user_id)
	if err.code != .None do return respond_error(err, req.request_id)
	defer {
		for exp in exps {
			delete(exp.owner_user_id)
			delete(exp.key)
			delete(exp.updated_at)
		}
		delete(exps)
	}

	body := experiment_list_json(exps[:])
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// PUT /api/v1/me/experiments/{key}
// Sets (creates or updates) a single experiment flag for the authenticated user.
// Body: {"enabled": true|false}
experiment_set_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Experiment_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	key := path_part(req.path, 5)
	if key == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "experiment key is required"), req.request_id)
	}

	// Require "enabled" to be a JSON boolean literal (true or false).
	// json_bool silently returns false for absent or non-boolean values, which
	// would treat a missing field or a mis-typed value as "disable" with no error.
	enabled, enabled_ok := json_bool_literal(req.body, "enabled")
	if !enabled_ok {
		return respond_error(domain.domain_error(.Validation_Failed, "enabled must be a JSON boolean (true or false)"), req.request_id)
	}
	now := platform.clock_now(h.clock)

	exp := domain.Experiment{
		owner_user_id = auth_ctx.user_id,
		key           = key,
		enabled       = enabled,
		updated_at    = now,
	}

	_, set_err := iface.experiment_set(h.repo, exp)
	if set_err.code != .None do return respond_error(set_err, req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"experiment\":")
	write_experiment_json(&b, exp)
	strings.write_string(&b, "}")
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// experiment_list_json renders the user's stored flags plus every default-on flag they
// never set (REQ: streaming terminal panes on by default).
experiment_list_json :: proc(exps: []domain.Experiment) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"experiments\":[")
	for exp, i in exps {
		if i > 0 do strings.write_string(&b, ",")
		write_experiment_json(&b, exp)
	}
	n := len(exps)
	defaults := domain.EXPERIMENTS_DEFAULT_ON
	for key in defaults {
		stored := false
		for exp in exps do if exp.key == key { stored = true; break }
		if stored do continue
		if n > 0 do strings.write_string(&b, ",")
		write_experiment_json(&b, domain.Experiment{key = key, enabled = true})
		n += 1
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// experiment_gate_error is the shared owner-scoped server guard for experimental
// features (REQ-EXP-GATE-3). It returns an error with code .None when `key` is enabled
// for `owner_user_id` (the authenticated user, or the owner of an authenticated
// bridge), otherwise the error to answer with:
//   - flag off or never set (and not default-on): domain.experimental_feature_disabled_error
//     (forbidden / 403, details {code:"experimental_feature_disabled", feature:key});
//   - empty owner: the same refusal (no owner, no opt-in);
//   - repository missing or failing: .Internal_Error, never success (fail closed).
// Only that owner's rows are consulted, so one user's opt-in never enables another's.
// Use it where no HTTP Response is built (bridge frames, schedulers); use
// require_experiment_enabled in request handlers.
experiment_gate_error :: proc(repo: ^iface.Experiment_Repository, owner_user_id: string, key: string) -> domain.Domain_Error {
	if owner_user_id == "" do return domain.experimental_feature_disabled_error(key)
	exps, err := iface.experiment_list_by_owner(repo, owner_user_id)
	defer {
		for exp in exps {
			delete(exp.owner_user_id)
			delete(exp.key)
			delete(exp.updated_at)
		}
		delete(exps)
	}
	if err.code != .None do return domain.domain_error(.Internal_Error, "could not read experiment settings")
	if domain.experiment_enabled_in(exps[:], key) do return domain.Domain_Error{}
	return domain.experimental_feature_disabled_error(key)
}

// require_experiment_enabled is experiment_gate_error for request handlers: ok=true
// to continue, otherwise the error Response (existing envelope via respond_error).
// Call it after authentication/ownership checks and before any read, write, relay,
// dispatch or launch the feature performs:
//   auth_ctx, ok, auth_resp := require_auth(h.auth, req)
//   if !ok do return auth_resp
//   if gated, resp := require_experiment_enabled(h.experiments, auth_ctx.user_id, domain.ACTIONS_EXPERIMENT_KEY, req.request_id); !gated do return resp
require_experiment_enabled :: proc(repo: ^iface.Experiment_Repository, owner_user_id: string, key: string, request_id: string) -> (ok: bool, resp: Response) {
	err := experiment_gate_error(repo, owner_user_id, key)
	if err.code == .None do return true, Response{}
	return false, respond_error(err, request_id)
}
