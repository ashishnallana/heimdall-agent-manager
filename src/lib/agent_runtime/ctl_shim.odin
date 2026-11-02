package agent_runtime

// The per-agent ham-ctl shim the bridge materializes into every agent run dir.
// These are the single source of truth for its location: the bridge writes the
// shim (and the HEIMDALL_CTL_BIN env, the managed-files manifest) from them, and
// every agent-facing string (starter prompt, PTY notifications) tells the agent to
// run CTL_SHIM_INVOCATION, so the documented path can never drift from the file.
CTL_SHIM_DIR        :: "bin"
CTL_SHIM_PATH       :: CTL_SHIM_DIR + "/ham-ctl"
CTL_SHIM_CMD_PATH   :: CTL_SHIM_PATH + ".cmd" // Windows cmd.exe twin
CTL_SHIM_INVOCATION :: "./" + CTL_SHIM_PATH
