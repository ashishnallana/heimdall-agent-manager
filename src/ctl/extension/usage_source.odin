package extension

// Per-provider usage sources. A provider that can report context usage has ONE
// entry in USAGE_READERS and one parser file; adapters never name a parser.
// Providers without an entry (antigravity) simply report no usage.

import json "core:encoding/json"
import "core:strings"

// Usage_Reader extracts the provider's context usage for one hook payload. It
// finds the transcript (transcript_path) itself and returns ok=false when no
// usable record exists. Readers never write to stdout or stderr.
Usage_Reader :: proc(root: json.Object) -> (Transcript_Usage, bool)

@(private = "file")
Usage_Source_Entry :: struct {
	provider: string,
	reader:   Usage_Reader,
}

@(private = "file")
USAGE_READERS := [?]Usage_Source_Entry{
	{CLAUDE_PROVIDER, claude_usage_reader},
	{CODEX_PROVIDER, codex_usage_reader},
}

usage_reader_for :: proc(provider: string) -> (Usage_Reader, bool) {
	for e in USAGE_READERS {
		if e.provider == provider do return e.reader, true
	}
	return nil, false
}

// ext_event_finish_usage appends the usage block for provider when want_usage.
// If the provider has a reader but it found nothing, it appends
// ,"usage_unavailable":true instead so the bridge can note (once per session)
// that the transcript parser went dark. Providers without a reader add nothing.
// Call where ext_event_usage was called: after tool/metrics, before ext_event_end.
ext_event_finish_usage :: proc(eb: ^Ext_Event_Builder, provider: string, root: json.Object, want_usage: bool) {
	if !want_usage do return
	reader, has_reader := usage_reader_for(provider)
	if !has_reader do return
	u, ok := reader(root)
	if ok {
		ext_event_usage(eb, u, true)
		return
	}
	strings.write_string(&eb.b, `,"usage_unavailable":true`)
}
