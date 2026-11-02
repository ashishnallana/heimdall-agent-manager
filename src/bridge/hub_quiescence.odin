package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:encoding/json"
import cfg_lib "odin_test:lib/config"

// Once set, only a fresh process explicitly activated by the operator can send.
// Connection writers consult this flag under their own send mutex as well.
bridge_hub_traffic_stopped: bool
bridge_hub_traffic_mu: sync.Mutex
bridge_hub_traffic_config_path: string
bridge_hub_traffic_final: bool

Bridge_Hub_Pause :: struct {
    hub, bridge_id: string,
    final: bool,
}

bridge_hub_pause_path :: proc(config_path: string) -> string {
    if config_path == "" do return ""
    context.allocator = context.temp_allocator
    expanded := cfg_lib.expand_home(config_path)
    canonical, ok := bridge_canonical_file_path(expanded)
    path := canonical if ok else expanded // preserve inaccessible-path fail-closed checks
    return strings.concatenate({path, ".hub-paused-v1"}, context.temp_allocator)
}

// Called only after a successful enrollment, while its config lock is held.
bridge_hub_pause_clear_enrolled :: proc(config_path: string) -> bool {
    path := bridge_hub_pause_path(config_path)
    if path == "" do return true
    _, err := os.stat(path, context.temp_allocator)
    return err == .Not_Exist || os.remove(path) == nil
}

bridge_hub_pause_read :: proc(config_path: string) -> (pause: Bridge_Hub_Pause, exists, valid: bool) {
    path := bridge_hub_pause_path(config_path)
    if path == "" do return {}, false, false
    _, stat_err := os.stat(path, context.temp_allocator)
    if stat_err == .Not_Exist do return {}, false, false
    // Unreadable or corrupt state fails closed, including inaccessible parents.
    bytes, err := os.read_entire_file(path, context.temp_allocator)
    valid = err == nil && json.unmarshal(bytes, &pause, allocator = context.temp_allocator) == nil && pause.hub != "" && pause.bridge_id != ""
    return pause, true, valid
}

bridge_hub_stop_traffic :: proc(final: bool) {
    sync.mutex_lock(&bridge_hub_traffic_mu)
    defer sync.mutex_unlock(&bridge_hub_traffic_mu)
    was_stopped := sync.atomic_exchange(&bridge_hub_traffic_stopped, true)
    sync.atomic_store(&bridge_hub_runtime_up, false)
    if was_stopped && (!final || bridge_hub_traffic_final) do return
    bridge_hub_traffic_final = bridge_hub_traffic_final || final
    if bridge_hub_traffic_config_path == "" do return // non-runtime callers / tests
    if bridge_hub_traffic_final {
        bridge_reenroll_mark(bridge_hub_traffic_config_path, bridge_config.daemon_url, bridge_config.daemon_id, .Revoked)
    }
    pause := Bridge_Hub_Pause{hub = bridge_config.daemon_url, bridge_id = bridge_config.daemon_id, final = bridge_hub_traffic_final}
    bytes, err := json.marshal(pause, allocator = context.temp_allocator)
    if err != nil || !bridge_retry_atomic_write(bridge_hub_pause_path(bridge_hub_traffic_config_path), bytes) {
        fmt.eprintln("bridge: could not persist Hub traffic pause; keep this process parked until local state is repaired")
    }
}

// No Hub I/O. Caller must stop the service first; config and scope locks exclude
// runtime, enrollment and concurrent activation. Final/corrupt markers never resume.
bridge_hub_resume_sunset :: proc(cfg: Bridge_Config, config_path: string) -> bool {
    lock, locked := bridge_config_lock(config_path)
    if !locked do return false
    defer bridge_instance_unlock(lock)
    scope, scoped := keystore_scope_name_for_hub(cfg.daemon_url, strings.trim_space(cfg.daemon_id))
    if !scoped do return false
    scope_lock, scope_locked := bridge_scope_lock(scope)
    if !scope_locked do return false
    defer bridge_instance_unlock(scope_lock)
    pause, exists, valid := bridge_hub_pause_read(config_path)
    if !exists || !valid || pause.final || pause.hub != cfg.daemon_url || pause.bridge_id != cfg.daemon_id do return false
    return os.remove(bridge_hub_pause_path(config_path)) == nil
}
