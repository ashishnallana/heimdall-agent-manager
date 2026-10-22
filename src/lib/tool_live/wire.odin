package tool_live

// Enforced BEFORE parsing/clone at each live-tool trust boundary. The tracker
// contains only bounded identity/name fields; arbitrary tool input/output is
// never stored. With 256 entries,32 calls,32 tombstones and <=2048-byte generated
// keys, owned strings + dynamic capacities have a conservative 48 MiB ceiling.
MAX_FRAME_BYTES :: 256 * 1024
MAX_DIRTY_BYTES :: 8 * 1024 * 1024
MAX_DEPTH :: 8
MAX_KEY_BYTES :: 2048
wire_shape_ok :: proc(raw: string) -> bool {
    if len(raw) > MAX_FRAME_BYTES do return false
    depth := 0
    quoted := false
    escaped := false
    tokens := 0
    for c in transmute([]u8)raw {
        if quoted {
            if escaped { escaped = false; continue }
            if c == 92 { escaped = true; continue }
            if c == 34 { quoted = false }
            continue
        }
        switch c {
        case 34: quoted = true; tokens += 1
        case 123, 91: depth += 1; tokens += 1
        case 125, 93: depth -= 1
        }
        if depth < 0 || depth > MAX_DEPTH || tokens > 4096 do return false
    }
    return !quoted && depth == 0
}
