package domain

import "core:encoding/json"
import "core:fmt"

STREAMING_TERMINAL_PANE_EXPERIMENT_KEY :: "streaming_terminal_pane"
// PROJECT_VCS_EXPERIMENT_KEY gates the Project Explorer (project/directory file and
// VCS views). Projects management itself is not experimental.
PROJECT_VCS_EXPERIMENT_KEY :: "project_vcs"
// ACTIONS_EXPERIMENT_KEY gates scheduled and on-demand Actions (REQ-EXP-GATE-1).
// Off until the user enables it; existing users are never auto-enabled.
ACTIONS_EXPERIMENT_KEY :: "actions"

// EXPERIMENTAL_FEATURE_DISABLED_CODE is error.details.code on the 403 a gated route
// answers while the owner's flag is off (REQ-EXP-GATE-3). error.code stays "forbidden".
EXPERIMENTAL_FEATURE_DISABLED_CODE :: "experimental_feature_disabled"

// EXPERIMENTS_DEFAULT_ON are experiments a user gets when they have never set them.
// Every other key is off until enabled. A stored row always wins, so turning one of
// these off in Settings -> Experimental is respected.
EXPERIMENTS_DEFAULT_ON :: [?]string{STREAMING_TERMINAL_PANE_EXPERIMENT_KEY}

// experiment_default_enabled is the value of `key` for a user with no stored row.
experiment_default_enabled :: proc(key: string) -> bool {
	for k in EXPERIMENTS_DEFAULT_ON do if k == key do return true
	return false
}

Experiment :: struct {
	owner_user_id: string,
	key:           string,
	enabled:       bool,
	updated_at:    string,
}

// experiment_enabled_in resolves `key` from one owner's stored rows: the stored row
// wins, otherwise the key's default. Callers pass only that owner's rows.
experiment_enabled_in :: proc(exps: []Experiment, key: string) -> bool {
	for exp in exps do if exp.key == key do return exp.enabled
	return experiment_default_enabled(key)
}

// experiment_feature_label is the user-facing name of a gated feature.
experiment_feature_label :: proc(key: string) -> string {
	switch key {
	case PROJECT_VCS_EXPERIMENT_KEY: return "Project Explorer"
	case ACTIONS_EXPERIMENT_KEY:     return "Actions"
	case STREAMING_TERMINAL_PANE_EXPERIMENT_KEY: return "Streaming Terminal Pane"
	}
	return key
}

// experimental_feature_disabled_error is the refusal for a gated feature whose flag is
// off or absent: code forbidden (HTTP 403), details {code, feature}. Message and
// details use the request temp arena, like other domain errors.
experimental_feature_disabled_error :: proc(key: string) -> Domain_Error {
	details := struct {code: string, feature: string}{EXPERIMENTAL_FEATURE_DISABLED_CODE, key}
	encoded, _ := json.marshal(details, allocator = context.temp_allocator)
	return domain_error(.Forbidden,
		fmt.tprintf("%s is experimental. Enable it in Settings > Experimental to use it.", experiment_feature_label(key)),
		string(encoded))
}
