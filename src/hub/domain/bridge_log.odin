package domain

// Bridge_Log_Event is one validated bridge error event as stored in
// bridge_log_events (bridge_log relay, plan §4.3). `fields_json` is the
// hub-normalised `{"key":int|"sym",...}` object (allow-listed keys and symbols
// only); `message` is rendered server-side from code+fields and is never stored.
// There is deliberately NO owner column: ownership is a join on `bridges`.
Bridge_Log_Event :: struct {
	id:          i64,
	bridge_id:   string,
	ts_ms:       i64, // bridge clock, clamped on ingest
	received_at: i64, // hub unix ms
	level:       string, // "warn" | "error"
	code:        string, // enum name or "other"
	fields_json: string,
	count:       int,
}

bridge_log_event_destroy :: proc(e: ^Bridge_Log_Event) {
	if e == nil do return
	if len(e.bridge_id) > 0 do delete(e.bridge_id)
	if len(e.level) > 0 do delete(e.level)
	if len(e.code) > 0 do delete(e.code)
	if len(e.fields_json) > 0 do delete(e.fields_json)
	e^ = {}
}

bridge_log_events_destroy :: proc(events: []Bridge_Log_Event) {
	for &e in events do bridge_log_event_destroy(&e)
	delete(events)
}
