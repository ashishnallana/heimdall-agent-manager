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
  `connect_timeout_ms`, `max_response_bytes` (default 32 MiB), `max_redirects`
  (default 0: a 3xx is returned), `cancel` (atomic flag → `.Aborted`).
- Bodies: `json_body(value)` (marshalled immediately with `core:encoding/json`),
  `form_body([]Form_Field)` (encoded with curl's escaping),
  `raw_body(content_type, bytes)`. No body → no `Content-Type`.
- Header helpers: `bearer(token)`, `accept_json()`, `accept(type)`,
  `user_agent(v)`, `oauth_client_basic(id, secret)`. `Host`, `Content-Length`,
  `Content-Type`, `Transfer-Encoding`, `Connection`, `Expect`, ... are reserved.
- `Response`: `status`, `headers` (copied from `curl_easy_nextheader`), `body`,
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
  every read; a negative budget fails immediately without I/O.
- TLS peer and hostname verification always on.
- Trust anchors: `HAM_TLS_CA_FILE` (that bundle only) > `SSL_CERT_FILE` /
  `SSL_CERT_DIR` > libcurl's default (system store; Schannel: Windows store).
- **Proxies: never.** `http_proxy`, `HTTPS_PROXY`, `ALL_PROXY` etc. are ignored
  (`CURLOPT_PROXY ""`), as with the previous client.
- Redirects only when `max_redirects > 0`; an https request never follows a
  redirect to http.
- `User-Agent: heimdall/<version>` unless the request sets one.
- `HAM_TLS_BACKEND` does not affect HTTP any more; it only selects the WebSocket
  (`src/lib/ws` → `src/lib/tls_stream`) relay.

## Linking

One setup per OS, in `curl_bindings.odin` (own minimal bindings; `vendor:curl`'s
Linux link line names mbedTLS and cannot be overridden):

| OS | libcurl |
| --- | --- |
| Linux | `system:curl` — nixpkgs `curl` in the flake's buildInputs; release binaries need the host's `libcurl.so.4` |
| macOS | `system:curl` — the OS's `/usr/lib/libcurl.4.dylib` |
| Windows | static `libcurl.lib` (Schannel) shipped with the Odin toolchain in `vendor/curl/lib`; build with `-extra-linker-flags:/LIBPATH:<odin root>/vendor/curl/lib` |

`init()` refuses libcurl older than `MIN_CURL_VERSION` (7.84.0). The planned
WebSocket migration to `curl_ws_*` will need 8.11.0.
