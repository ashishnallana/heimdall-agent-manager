package taskv2

// flush_wakes sends one wake_agent command per bridge for the runs/stops a
// committed UoW decided on. M1.
flush_wakes :: proc(svc: ^Service, e: ^Effects) {
	_ = svc; _ = e
}
