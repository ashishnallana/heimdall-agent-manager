package main

import "core:fmt"
import "core:os"
import "core:strings"

// Use the service's config and (hub, bridge) exclusion, without requiring a
// healthy credential or reading/repairing enrollment. Hold both until the journal
// write is durable. In particular, journal load may normalize crash reservations.
bridge_recovery_resume :: proc(cfg: Bridge_Config, config_path: string, refresh: bool) -> bool {
    config_lock, config_locked := bridge_config_lock(config_path)
    if !config_locked {
        fmt.eprintln("recovery resume refused: config is unavailable or a bridge/enrollment is running")
        return false
    }
    defer bridge_instance_unlock(config_lock)
    scope, scoped := keystore_scope_name_for_hub(cfg.daemon_url, strings.trim_space(cfg.daemon_id))
    if !scoped {
        fmt.eprintln("recovery resume refused: cannot establish the bridge scope")
        return false
    }
    scope_lock, scope_locked := bridge_scope_lock(scope)
    if !scope_locked {
        fmt.eprintln("recovery resume refused: bridge scope is unavailable or a bridge/enrollment is running")
        return false
    }
    defer bridge_instance_unlock(scope_lock)
    if refresh {
        // This is the exact resolved path used by the rotation worker, including
        // HAM_BRIDGE_TOKEN_FILE and default adoption. Never guess another path.
        path := strings.trim_space(cfg.credential_file)
        if path == "" {
            fmt.eprintln("credential recovery resume refused: no effective credential file")
            return false
        }
        pending := strings.concatenate({path, ".pending-rotation-v1"}, context.temp_allocator)
        // stat errors other than absence also fail closed (e.g. unreadable parent).
        _, err := os.stat(pending, context.temp_allocator)
        if err != .Not_Exist {
            fmt.eprintln("credential recovery resume refused: reconcile the pending rotated pair or inaccessible path first")
            return false
        }
    }
    key := fmt.aprintf("refresh:%s:%s", cfg.daemon_url, strings.trim_space(cfg.daemon_id)) if refresh else bridge_action_scheduler_sync_key()
    defer delete(key)
    if !bridge_retry_operator_resume_sync(key, refresh) {
        fmt.eprintln("recovery resume refused: journal unavailable or operation in flight")
        return false
    }
    return true
}
