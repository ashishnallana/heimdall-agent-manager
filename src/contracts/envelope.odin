package contracts

import "core:fmt"
import "core:strconv"
import "core:strings"

API_V1_BASE_PATH :: "/api/v1"
API_DEFAULT_PAGE_LIMIT :: 50
API_MAX_PAGE_LIMIT :: 200

API_Meta :: struct {
	request_id:  string,
	server_time: string,
}

API_Page :: struct {
	limit:       int,
	next_cursor: string,
	has_more:    bool,
}

API_Error :: struct {
	code:    string,
	message: string,
	details_json: string,
	class:   string, // Bridge_Error_Class name; omitted when ""
	cause:   string, // fine-grained reason; omitted when ""
}

API_Sort_Direction :: enum {
	Asc,
	Desc,
}

API_Sort_Field :: struct {
	field:     string,
	direction: API_Sort_Direction,
}

API_Query :: struct {
	limit:      int,
	cursor:     string,
	search:     string,
	filters:    []API_Filter,
	sort:       []API_Sort_Field,
	expand:     []string,
}

API_Filter :: struct {
	name:  string,
	value: string,
}

api_meta :: proc(request_id, server_time: string) -> API_Meta {
	return API_Meta{request_id = request_id, server_time = server_time}
}

api_page :: proc(limit: int, next_cursor: string, has_more: bool) -> API_Page {
	clamped := limit
	if clamped <= 0 do clamped = API_DEFAULT_PAGE_LIMIT
	if clamped > API_MAX_PAGE_LIMIT do clamped = API_MAX_PAGE_LIMIT
	return API_Page{limit = clamped, next_cursor = next_cursor, has_more = has_more}
}

api_success_json :: proc(data_json: string, meta: API_Meta) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"data\":")
	write_json_value_or_object(&builder, data_json)
	strings.write_string(&builder, ",\"meta\":")
	write_meta_json(&builder, meta, true)
	strings.write_string(&builder, "}")
	return strings.to_string(builder)
}

api_list_json :: proc(data_json: string, page: API_Page, meta: API_Meta) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"data\":")
	write_json_value_or_array(&builder, data_json)
	strings.write_string(&builder, ",\"page\":{\"limit\":")
	strings.write_string(&builder, fmt.tprintf("%d", page.limit))
	strings.write_string(&builder, ",\"next_cursor\":")
	if page.next_cursor == "" {
		strings.write_string(&builder, "null")
	} else {
		strings.write_string(&builder, "\"")
		write_json_string(&builder, page.next_cursor)
		strings.write_string(&builder, "\"")
	}
	strings.write_string(&builder, ",\"has_more\":")
	strings.write_string(&builder, "true" if page.has_more else "false")
	strings.write_string(&builder, "},\"meta\":")
	write_meta_json(&builder, meta, true)
	strings.write_string(&builder, "}")
	return strings.to_string(builder)
}

api_error_json :: proc(err: API_Error, meta: API_Meta) -> string {
	details := err.details_json
	if details == "" do details = "{}"
	builder := strings.builder_make()
	strings.write_string(&builder, "{\"error\":{\"code\":\"")
	write_json_string(&builder, err.code)
	strings.write_string(&builder, "\",\"message\":\"")
	write_json_string(&builder, err.message)
	strings.write_string(&builder, "\"")
	if err.class != "" {
		strings.write_string(&builder, ",\"class\":\"")
		write_json_string(&builder, err.class)
		strings.write_string(&builder, "\"")
	}
	if err.cause != "" {
		strings.write_string(&builder, ",\"cause\":\"")
		write_json_string(&builder, err.cause)
		strings.write_string(&builder, "\"")
	}
	strings.write_string(&builder, ",\"details\":")
	write_json_value_or_object(&builder, details)
	strings.write_string(&builder, "},\"meta\":")
	write_meta_json(&builder, meta, false)
	strings.write_string(&builder, "}")
	return strings.to_string(builder)
}

write_meta_json :: proc(builder: ^strings.Builder, meta: API_Meta, include_server_time: bool) {
	strings.write_string(builder, "{\"request_id\":\"")
	write_json_string(builder, meta.request_id)
	strings.write_string(builder, "\"")
	if include_server_time {
		strings.write_string(builder, ",\"server_time\":\"")
		write_json_string(builder, meta.server_time)
		strings.write_string(builder, "\"")
	}
	strings.write_string(builder, "}")
}

write_json_value_or_object :: proc(builder: ^strings.Builder, value: string) {
	trimmed := strings.trim_space(value)
	if trimmed == "" {
		strings.write_string(builder, "{}")
		return
	}
	strings.write_string(builder, trimmed)
}

write_json_value_or_array :: proc(builder: ^strings.Builder, value: string) {
	trimmed := strings.trim_space(value)
	if trimmed == "" {
		strings.write_string(builder, "[]")
		return
	}
	strings.write_string(builder, trimmed)
}

write_json_string :: proc(builder: ^strings.Builder, value: string) {
	for i in 0..<len(value) {
		ch := value[i]
		switch ch {
		case '"': strings.write_string(builder, "\\\"")
		case '\\': strings.write_string(builder, "\\\\")
		case '\n': strings.write_string(builder, "\\n")
		case '\r': strings.write_string(builder, "\\r")
		case '\t': strings.write_string(builder, "\\t")
		case:
			if ch < 0x20 {
				strings.write_string(builder, fmt.tprintf("\\u%04x", int(ch)))
			} else {
				strings.write_byte(builder, ch)
			}
		}
	}
}

parse_int_default :: proc(value: string, default_value: int) -> int {
	if value == "" do return default_value
	parsed, ok := strconv.parse_int(value)
	if !ok do return default_value
	return int(parsed)
}
