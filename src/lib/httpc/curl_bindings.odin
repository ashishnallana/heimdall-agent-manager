package httpc

// Minimal private libcurl bindings: only what this package calls. Nothing here is
// exported for other packages, and scripts/check-http-boundary.sh fails the build
// if any package other than src/lib/httpc declares or imports libcurl.
//
// Why not `vendor:curl`: its Linux foreign import hard-codes
// `system:curl system:mbedtls system:mbedx509 system:mbedcrypto system:z`, which
// does not link against nixpkgs (OpenSSL) curl, and a foreign import cannot be
// overridden from outside the package. Its curl_url_get binding also has the
// wrong return type. Owning ~25 declarations is cheaper than working around it.
//
// Linking, one setup per OS:
//   - Linux / BSD: `system:curl` (the nixpkgs curl in buildInputs, or the host's
//     libcurl.so.4 for release binaries).
//   - macOS: `system:curl` (/usr/lib/libcurl.4.dylib, part of the OS).
//   - Windows: the static `libcurl.lib` (Schannel) that ships with the Odin
//     toolchain under vendor/curl/lib. A foreign import path is relative to this
//     source file, so the library is named `system:libcurl.lib` here and the
//     build passes `/LIBPATH:<odin root>/vendor/curl/lib` (scripts/windows/build.ps1).
//
// MIN_CURL_VERSION (httpc.odin) is checked at startup by `init`.

import "core:c"

when ODIN_OS == .Windows {
	@(extra_linker_flags = "/NODEFAULTLIB:msvcrt")
	foreign import libcurl {
		"system:libcurl.lib",
		"system:Advapi32.lib",
		"system:Crypt32.lib",
		"system:Normaliz.lib",
		"system:Secur32.lib",
		"system:Wldap32.lib",
		"system:Ws2_32.lib",
		"system:iphlpapi.lib",
	}
} else {
	foreign import libcurl "system:curl"
}

@(private) CURL :: struct {}
@(private) CURLU :: struct {}
@(private) curl_slist :: struct {
	data: cstring,
	next: ^curl_slist,
}

@(private) curl_header :: struct {
	name:   cstring,
	value:  cstring,
	amount: c.size_t,
	index:  c.size_t,
	origin: c.uint,
	anchor: rawptr,
}

@(private) curl_version_info_data :: struct {
	age:         c.int,
	version:     cstring,
	version_num: c.uint,
	host:        cstring,
	features:    c.int,
	ssl_version: cstring,
}

@(private) CURLcode :: distinct c.int
@(private) CURLUcode :: distinct c.int
@(private) CURLoption :: distinct c.int
@(private) CURLINFO :: distinct c.int

// CURLcode values this package distinguishes (curl.h; stable since their introduction).
@(private) CURLE_OK :: CURLcode(0)
@(private) CURLE_UNSUPPORTED_PROTOCOL :: CURLcode(1)
@(private) CURLE_FAILED_INIT :: CURLcode(2)
@(private) CURLE_URL_MALFORMAT :: CURLcode(3)
@(private) CURLE_COULDNT_RESOLVE_PROXY :: CURLcode(5)
@(private) CURLE_COULDNT_RESOLVE_HOST :: CURLcode(6)
@(private) CURLE_COULDNT_CONNECT :: CURLcode(7)
@(private) CURLE_WEIRD_SERVER_REPLY :: CURLcode(8)
@(private) CURLE_HTTP2 :: CURLcode(16)
@(private) CURLE_PARTIAL_FILE :: CURLcode(18)
@(private) CURLE_WRITE_ERROR :: CURLcode(23)
@(private) CURLE_READ_ERROR :: CURLcode(26)
@(private) CURLE_OUT_OF_MEMORY :: CURLcode(27)
@(private) CURLE_OPERATION_TIMEDOUT :: CURLcode(28)
@(private) CURLE_SSL_CONNECT_ERROR :: CURLcode(35)
@(private) CURLE_ABORTED_BY_CALLBACK :: CURLcode(42)
@(private) CURLE_TOO_MANY_REDIRECTS :: CURLcode(47)
@(private) CURLE_GOT_NOTHING :: CURLcode(52)
@(private) CURLE_SEND_ERROR :: CURLcode(55)
@(private) CURLE_RECV_ERROR :: CURLcode(56)
@(private) CURLE_SSL_CERTPROBLEM :: CURLcode(58)
@(private) CURLE_SSL_CIPHER :: CURLcode(59)
@(private) CURLE_PEER_FAILED_VERIFICATION :: CURLcode(60)
@(private) CURLE_BAD_CONTENT_ENCODING :: CURLcode(61)
@(private) CURLE_FILESIZE_EXCEEDED :: CURLcode(63)
@(private) CURLE_SSL_CACERT_BADFILE :: CURLcode(77)
@(private) CURLE_SSL_SHUTDOWN_FAILED :: CURLcode(80)
@(private) CURLE_SSL_CRL_BADFILE :: CURLcode(82)
@(private) CURLE_SSL_ISSUER_ERROR :: CURLcode(83)
@(private) CURLE_SSL_PINNEDPUBKEYNOTMATCH :: CURLcode(90)
@(private) CURLE_SSL_INVALIDCERTSTATUS :: CURLcode(91)
@(private) CURLE_HTTP2_STREAM :: CURLcode(92)
@(private) CURLE_UNRECOVERABLE_POLL :: CURLcode(99)
@(private) CURLE_TOO_LARGE :: CURLcode(100)

@(private) CURLOPTTYPE_LONG :: 0
@(private) CURLOPTTYPE_OBJECTPOINT :: 10000
@(private) CURLOPTTYPE_FUNCTIONPOINT :: 20000
@(private) CURLOPTTYPE_OFF_T :: 30000

@(private) CURLOPT_WRITEDATA :: CURLoption(CURLOPTTYPE_OBJECTPOINT + 1)
@(private) CURLOPT_PROXY :: CURLoption(CURLOPTTYPE_OBJECTPOINT + 4)
@(private) CURLOPT_ERRORBUFFER :: CURLoption(CURLOPTTYPE_OBJECTPOINT + 10)
@(private) CURLOPT_WRITEFUNCTION :: CURLoption(CURLOPTTYPE_FUNCTIONPOINT + 11)
@(private) CURLOPT_POSTFIELDS :: CURLoption(CURLOPTTYPE_OBJECTPOINT + 15)
@(private) CURLOPT_USERAGENT :: CURLoption(CURLOPTTYPE_OBJECTPOINT + 18)
@(private) CURLOPT_HTTPHEADER :: CURLoption(CURLOPTTYPE_OBJECTPOINT + 23)
@(private) CURLOPT_CUSTOMREQUEST :: CURLoption(CURLOPTTYPE_OBJECTPOINT + 36)
@(private) CURLOPT_NOPROGRESS :: CURLoption(CURLOPTTYPE_LONG + 43)
@(private) CURLOPT_NOBODY :: CURLoption(CURLOPTTYPE_LONG + 44)
@(private) CURLOPT_POST :: CURLoption(CURLOPTTYPE_LONG + 47)
@(private) CURLOPT_FOLLOWLOCATION :: CURLoption(CURLOPTTYPE_LONG + 52)
@(private) CURLOPT_XFERINFODATA :: CURLoption(CURLOPTTYPE_OBJECTPOINT + 57)
@(private) CURLOPT_SSL_VERIFYPEER :: CURLoption(CURLOPTTYPE_LONG + 64)
@(private) CURLOPT_CAINFO :: CURLoption(CURLOPTTYPE_OBJECTPOINT + 65)
@(private) CURLOPT_MAXREDIRS :: CURLoption(CURLOPTTYPE_LONG + 68)
@(private) CURLOPT_FRESH_CONNECT :: CURLoption(CURLOPTTYPE_LONG + 74)
@(private) CURLOPT_FORBID_REUSE :: CURLoption(CURLOPTTYPE_LONG + 75)
@(private) CURLOPT_HTTPGET :: CURLoption(CURLOPTTYPE_LONG + 80)
@(private) CURLOPT_SSL_VERIFYHOST :: CURLoption(CURLOPTTYPE_LONG + 81)
@(private) CURLOPT_HTTP_VERSION :: CURLoption(CURLOPTTYPE_LONG + 84)
@(private) CURLOPT_CAPATH :: CURLoption(CURLOPTTYPE_OBJECTPOINT + 97)
@(private) CURLOPT_NOSIGNAL :: CURLoption(CURLOPTTYPE_LONG + 99)
@(private) CURLOPT_ACCEPT_ENCODING :: CURLoption(CURLOPTTYPE_OBJECTPOINT + 102)
@(private) CURLOPT_MAXFILESIZE_LARGE :: CURLoption(CURLOPTTYPE_OFF_T + 117)
@(private) CURLOPT_POSTFIELDSIZE_LARGE :: CURLoption(CURLOPTTYPE_OFF_T + 120)
@(private) CURLOPT_TIMEOUT_MS :: CURLoption(CURLOPTTYPE_LONG + 155)
@(private) CURLOPT_CONNECTTIMEOUT_MS :: CURLoption(CURLOPTTYPE_LONG + 156)
@(private) CURLOPT_PROTOCOLS :: CURLoption(CURLOPTTYPE_LONG + 181)
@(private) CURLOPT_REDIR_PROTOCOLS :: CURLoption(CURLOPTTYPE_LONG + 182)
@(private) CURLOPT_XFERINFOFUNCTION :: CURLoption(CURLOPTTYPE_FUNCTIONPOINT + 219)
@(private) CURLOPT_CURLU :: CURLoption(CURLOPTTYPE_OBJECTPOINT + 282)
@(private) CURLOPT_PREREQFUNCTION :: CURLoption(CURLOPTTYPE_FUNCTIONPOINT + 312)
@(private) CURLOPT_PREREQDATA :: CURLoption(CURLOPTTYPE_OBJECTPOINT + 313)

@(private) CURLINFO_LONG :: 0x200000
@(private) CURLINFO_RESPONSE_CODE :: CURLINFO(CURLINFO_LONG + 2)

@(private) CURLPROTO_HTTP :: c.long(1 << 0)
@(private) CURLPROTO_HTTPS :: c.long(1 << 1)
@(private) CURL_HTTP_VERSION_1_1 :: c.long(2)
@(private) CURL_GLOBAL_ALL :: c.long(3) // CURL_GLOBAL_SSL | CURL_GLOBAL_WIN32
@(private) CURL_ERROR_SIZE :: 256
@(private) CURLH_HEADER :: c.uint(1 << 0)
@(private) CURL_PREREQFUNC_OK :: c.int(0)
@(private) CURLVERSION_FIRST :: c.int(0)

// CURLUPart
@(private) CURLUPART_URL :: c.int(0)
@(private) CURLUPART_SCHEME :: c.int(1)
@(private) CURLUPART_USER :: c.int(2)
@(private) CURLUPART_PASSWORD :: c.int(3)
@(private) CURLUPART_OPTIONS :: c.int(4)
@(private) CURLUPART_HOST :: c.int(5)
@(private) CURLUPART_PORT :: c.int(6)
@(private) CURLUPART_PATH :: c.int(7)
@(private) CURLUPART_QUERY :: c.int(8)
@(private) CURLUPART_FRAGMENT :: c.int(9)

// curl_url_set / curl_url_get flags
@(private) CURLU_NO_DEFAULT_PORT :: c.uint(1 << 1)
@(private) CURLU_DISALLOW_USER :: c.uint(1 << 5)
@(private) CURLU_URLENCODE :: c.uint(1 << 7)
@(private) CURLU_APPENDQUERY :: c.uint(1 << 8)

@(private) CURLUE_OK :: CURLUcode(0)

@(private) Curl_Write_Callback :: #type proc "c" (ptr: [^]byte, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t
@(private) Curl_Xferinfo_Callback :: #type proc "c" (clientp: rawptr, dltotal, dlnow, ultotal, ulnow: i64) -> c.int
@(private) Curl_Prereq_Callback :: #type proc "c" (clientp: rawptr, conn_primary_ip, conn_local_ip: cstring, conn_primary_port, conn_local_port: c.int) -> c.int

@(private, default_calling_convention = "c")
foreign libcurl {
	curl_global_init :: proc(flags: c.long) -> CURLcode ---
	curl_version_info :: proc(age: c.int) -> ^curl_version_info_data ---
	curl_easy_init :: proc() -> ^CURL ---
	curl_easy_cleanup :: proc(handle: ^CURL) ---
	curl_easy_setopt :: proc(handle: ^CURL, option: CURLoption, #c_vararg args: ..any) -> CURLcode ---
	curl_easy_getinfo :: proc(handle: ^CURL, info: CURLINFO, #c_vararg args: ..any) -> CURLcode ---
	curl_easy_perform :: proc(handle: ^CURL) -> CURLcode ---
	curl_easy_strerror :: proc(code: CURLcode) -> cstring ---
	curl_easy_escape :: proc(handle: ^CURL, str: [^]byte, length: c.int) -> cstring ---
	curl_easy_nextheader :: proc(handle: ^CURL, origin: c.uint, request: c.int, prev: ^curl_header) -> ^curl_header ---
	curl_free :: proc(ptr: rawptr) ---
	curl_slist_append :: proc(list: ^curl_slist, data: cstring) -> ^curl_slist ---
	curl_slist_free_all :: proc(list: ^curl_slist) ---
	curl_url :: proc() -> ^CURLU ---
	curl_url_cleanup :: proc(handle: ^CURLU) ---
	curl_url_set :: proc(handle: ^CURLU, what: c.int, part: cstring, flags: c.uint) -> CURLUcode ---
	curl_url_get :: proc(handle: ^CURLU, what: c.int, part: ^cstring, flags: c.uint) -> CURLUcode ---
}
