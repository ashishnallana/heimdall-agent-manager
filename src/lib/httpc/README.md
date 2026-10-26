# src/lib/httpc — the outbound HTTP client

Every outbound HTTP(S) request in Heimdall (hub, bridge, ctl, manager, test agent)
goes through this package. It wraps libcurl. The old hand-written client
(`src/lib/http_client`) was removed and `scripts/check-http-boundary.sh` keeps it
from coming back.

## Rules

1. **Only this package touches libcurl.** No other package may `foreign import`
   curl, import `vendor:curl`, or speak HTTP over raw `core:net` sockets. Callers
   never see `CURL*`, curl options or curl codes.
2. **Callers never build URLs, query strings, header lines or bodies by string
   interpolation** (`fmt.tprintf`, `strings.concatenate`, builders). Describe the
   request; the wrapper encodes it.

## API

```odin
import httpc "odin_test:lib/httpc"

// main(), before any thread starts:
if ok, msg := httpc.init(); !ok { fmt.eprintln(msg); os.exit(1) }

base, err := httpc.parse_url(config.hub_url)            // validated once by libcurl
resp, err := httpc.send({
	method  = .POST,
	url     = base,
	path    = {"api", "v1", "chains", chain_id, "comments"}, // each segment percent-encoded
	query   = {{"limit", "20"}, {"cursor", cursor}},          // encoded by curl_url_set
	headers = {httpc.bearer(token), {"If-None-Match", etag}},  // validated
	body    = httpc.json_body(payload),                        // json.marshal
	timeout_ms = 10_000,
})
defer httpc.response_destroy(&resp)
if err != .None { /* typed error; resp.may_have_sent says whether the server may have seen it */ }
etag, found := httpc.header(resp, "etag")                      // case-insensitive
```

- `Request`: `method`, `url` (from `parse_url`), `path` segments, `query`
  params, `headers`, `body`, `timeout_ms` (total budget, default 20 s),
  `connect_timeout_ms`, `stall_timeout_ms` (abort after that long without a
  byte moving; 0 = off), `max_response_bytes` (default 256 MiB), `max_redirects`
  (default 0: a 3xx is returned), `cancel` (atomic flag → `.Aborted`).
- Bodies: `json_body(value)` (marshalled immediately with `core:encoding/json`),
  `form_body([]Form_Field)` (encoded with curl's escaping),
  `raw_body(content_type, bytes)`. No body → no `Content-Type`.
- Header helpers: `bearer(token)`, `accept_json()`, `accept(type)`,
  `user_agent(v)`, `oauth_client_basic(id, secret)`. `Host`, `Content-Length`,
  `Content-Type`, `Transfer-Encoding`, `Connection`, `Expect`, ... are reserved.
- `Response`: `status`, `headers` (collected with `CURLOPT_HEADERFUNCTION`: final response only, trailers ignored, 64 KiB cap), `body`,
  `may_have_sent`, `detail`; `text(resp)`, `header(resp, name)`,
  `response_destroy(&resp)`.
- `send_json(req, &out)` decodes a 2xx body into a struct (`json.unmarshal`) and
  returns `Response_Meta{status, may_have_sent}`.
- `download_to_file(req, path)` streams to `path.part`, renamed on a complete 200.
- `build_url` / `build_target` render a URL / origin-form target for places that
  hand it to someone else (a browser redirect, the agent relay protocol).
- Escape hatches for **forwarding** data received verbatim from a peer protocol,
  never for building: `Request.relay_target` (an origin-form `/path?query`,
  validated) and `relay_json_body(document)`. The boundary check allow-lists the
  files that may use them.

### Errors and `may_have_sent`

`Error` is one of `Dns`, `Connect`, `Tls`, `Certificate`, `Timeout`, `Too_Large`,
`Send`, `Recv`, `Protocol`, `Too_Many_Redirects`, `Aborted`, `Invalid_Url`,
`Invalid_Header`, `Invalid_Body`, `Io`, `Decode`, `Not_Initialized`, `Internal`.

`may_have_sent` is true once libcurl reached the point of sending (connection and
TLS handshake complete — `CURLOPT_PREREQFUNCTION` fired) or any response arrived.
DNS, connect and handshake failures, and requests rejected locally, leave it false:
the server cannot have seen them. The bridge credential refresh journal relies on
this to decide whether a failed `POST /api/v1/device/bridge-refresh` may already
have rotated the token. Requests never reuse a pooled connection, so libcurl never
silently re-sends a request on a stale connection.

## Behaviour

- Fresh connection per request (`FRESH_CONNECT` + `FORBID_REUSE`), HTTP/1.1,
  `Accept-Encoding` = whatever libcurl decodes (gzip/deflate), chunked handled by
  libcurl, `Expect: 100-continue` disabled.
- One cumulative deadline (`CURLOPT_TIMEOUT_MS`) over DNS, connect, TLS, send and
  every read; a negative budget fails immediately without I/O. Transfers of
  unbounded size (ham-ctl, the bridge's agent relays, manager downloads) use
  `LONG_TRANSFER_TIMEOUT_MS` plus `stall_timeout_ms` instead of a short total.
- TLS peer and hostname verification always on.
- Trust anchors (`ca.odin`): `HAM_TLS_CA_FILE` (that bundle only) >
  `SSL_CERT_FILE` / `SSL_CERT_DIR` > the system store:
  - Linux: a statically linked OpenSSL knows only its build prefix, so `init()`
    probes, once: the first existing, non-empty, readable file of
    `/etc/ssl/certs/ca-certificates.crt` (Debian, Ubuntu, Alpine, Arch),
    `/etc/pki/tls/certs/ca-bundle.crt`,
    `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem` (Fedora, RHEL),
    `/etc/ssl/ca-bundle.pem` (openSUSE), `/etc/ssl/cert.pem` -> `CURLOPT_CAINFO`;
    else `/etc/ssl/certs` if it holds OpenSSL hash links -> `CURLOPT_CAPATH`;
    else the Mozilla bundle embedded at build time (`-define:HAM_CA_BUNDLE=<pem>`,
    nixpkgs `cacert`; release builds) -> `CURLOPT_CAINFO_BLOB`. A build without
    the embedded bundle on a host without any CA store fails with `.Certificate`.
  - macOS: Apple SecTrust (system keychains and trust settings): the pinned
    libcurl is built `--with-apple-sectrust` and uses it whenever no CA
    file/path is set; OpenSSL does the TLS.
  - Windows: Schannel with the Windows certificate store, revocation checked
    best effort (`CURLSSLOPT_REVOKE_BEST_EFFORT`).

  `trust_summary()` names the anchors in use (`ham-bridge --probe-hub` prints
  it with `libcurl_tls_version()`).
- **Proxies: never.** `http_proxy`, `HTTPS_PROXY`, `ALL_PROXY` etc. are ignored
  (`CURLOPT_PROXY ""`), as with the previous client.
- Redirects only when `max_redirects > 0`; an https request never follows a
  redirect to http.
- `User-Agent: heimdall/<version>` unless the request sets one.
- `HAM_TLS_BACKEND` does not affect HTTP any more; it only selects the WebSocket
  (`src/lib/ws` → `src/lib/tls_stream`) relay.

## Linking

Every build links ONE libcurl, pinned in `nix/libcurl-pin.json` (curl 8.23.0
and zlib 1.3.2 source tarballs with SHA-256). Feature set everywhere: HTTP,
HTTPS, WS, WSS; zlib (gzip/deflate); threaded resolver; proxies compiled in but
disabled per request. Not built: other protocols, HTTP/2 (requests are
HTTP/1.1 on a fresh connection, so nghttp2 would never be used), HTTP/3,
brotli, zstd, libpsl, IDN, libssh2, GSS-API/NTLM, cookies, netrc, alt-svc,
HSTS, MIME, and any compiled-in CA bundle or path.

| Build | libcurl | TLS | How |
| --- | --- | --- | --- |
| Linux release (`release-*`) | static | OpenSSL 3, static | `nix/libcurl.nix` `linuxStatic` (pkgsStatic, musl); the binary is fully static (`-static -no-pie`, no NEEDED) |
| macOS release | static | OpenSSL 3 static + Apple SecTrust | `nix/libcurl.nix` `darwinStatic`; only system frameworks are dynamic |
| Windows | static, /MT | Schannel | `scripts/windows/build-libcurl.ps1`; `build.ps1 -CurlLibDir` |
| Nix-native (hub units, `nix run`, `nix develop`) | shared, from its store path | nixpkgs OpenSSL 3 | `nix/libcurl.nix` `native` |

`curl_bindings.odin` selects the link line: `-define:HAM_CURL_STATIC=true`
links `curl ssl crypto z` (plus the CoreFoundation, CoreServices, Security and
SystemConfiguration frameworks on macOS); without it, `system:curl` (the
shared library). Windows always links `libcurl.lib` + `zlib.lib`. Own minimal
bindings, because `vendor:curl`'s Linux link line names mbedTLS and cannot be
overridden; the Odin toolchain's bundled Windows `libcurl.lib` (an unpinned
8.17.0-DEV snapshot without zlib) is not used.

`init()` refuses libcurl older than `MIN_CURL_VERSION` (8.11.0, what the
`curl_ws_*` WebSocket migration needs; today's bindings need 7.80). Every
flake and Windows build also passes `-define:HAM_CURL_VERSION=<pin>`, and then
`init()` refuses any libcurl but exactly that version, or one without TLS, so
a build that picked up some other libcurl fails at startup (`--version` too).

### Bumping the pin

1. Edit `nix/libcurl-pin.json`: version, URLs, SHA-256 of the `.tar.gz`
   (verify the release's `.asc` signature first). Same for zlib.
2. `nix build .#release-ham-bridge .#release-ham-ctl .#release-heimdall` and
   `.#ham-hub`; run `odin test src/lib/httpc -collection:odin_test=src` in
   `nix develop` and `bash tests/hub_package_libcurl_test.sh`.
3. The Windows cache key includes the pin, so the next release run rebuilds
   `libcurl.lib`.
