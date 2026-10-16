package domain

STREAMING_TERMINAL_PANE_EXPERIMENT_KEY :: "streaming_terminal_pane"
PROJECT_VCS_EXPERIMENT_KEY :: "project_vcs"

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
