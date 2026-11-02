# Remote MCP OAuth interoperability spike

This opt-in Hub transport tests URL-only sign-in with an actual remote MCP
client. It returns synthetic data only. It has no chain/content/vault service
references and cannot decrypt or modify user data. It is U0 of the approved
remote MCP plan, not the hosted-decryption implementation.

## Run in staging

For the authorized Dawnstar canary at `heimdall.mundus.in`, the preferred option
is the separate `ham-mcp-probe` package. It binds only loopback port 8120 and
checks the named Ninjy session cookie through the existing Hub's loopback
`/api/v1/me` on port 8113. It forwards no caller bearer or identity headers,
follows no redirects, and never opens the Hub database. The existing Hub OIDC
login and callback routes remain on the existing Hub; a short resume ticket
brings the browser back to the probe. This avoids replacing/restarting that Hub.

```bash
ham-mcp-probe --origin https://heimdall.mundus.in --port 8120
```

Proxy only the exact discovery and MCP paths below to this sidecar, with query
logging disabled and ingress request/body/rate limits. Keep `/api/v1/auth/*` on
the existing Hub. Run the sidecar as its own unprivileged user with no state
directory or secret files; losing its in-memory registrations on restart is an
explicit U0 limit. This cookie-checking adapter is for the synthetic probe only;
U1's hosted grant/capability handling remains the reviewed Odin Hub design.

The integrated flag below is an alternative for a dedicated staging Hub.

Build the Hub normally with the project's supported compiler. Start a dedicated
staging instance using its existing real OIDC browser-login configuration and
an HTTPS UI origin, adding:

```bash
ham-hub --mcp-oauth-spike --ui-origin https://YOUR-STAGING-HOST
```

Retain the normal database, OIDC and listening flags for that staging instance.
The flag defaults off. A non-HTTPS UI origin is refused. Do not change the running
production Hub simply to try the probe. No OIDC client secrets belong in chat,
source control or process arguments; use the existing secret-file option.

Forward these paths unchanged from the public HTTPS ingress to the staging Hub:

| Path | Purpose |
| --- | --- |
| `/.well-known/oauth-protected-resource/api/v1/mcp-spike` | Protected-resource discovery |
| `/.well-known/oauth-protected-resource` | Discovery fallback |
| `/.well-known/oauth-authorization-server` | Authorization-server discovery |
| `/api/v1/mcp-spike` | Authenticated Streamable HTTP probe |
| `/api/v1/mcp-spike/oauth/register` | Public-client registration |
| `/api/v1/mcp-spike/oauth/authorize` | Existing provider sign-in and probe authorization |
| `/api/v1/mcp-spike/oauth/token` | Code/PKCE exchange and refresh |
| `/api/v1/auth/login`, `/api/v1/auth/callback` | Existing Ninjy browser login |

The Hub router admits only those three exact GET metadata paths outside
`/api/v1`; handlers are registered only when the flag is enabled. No wildcard
well-known route or generic anonymous API exception is added. The ingress may
need an explicit well-known location: some deployments forward only `/api/v1`.

Heimdall shell previews are unsuitable for this remote-client test: they require
a separate Hub/preview cookie before reaching the application. A cloud MCP
client cannot use the user's browser preview cookie. Likewise the local mock
OIDC provider must remain loopback-only, per `tools/mock-oidc/README.md`.

## Real client acceptance

Add `https://YOUR-STAGING-HOST/api/v1/mcp-spike` in Claude browser's remote
connector UI, with no manually entered headers, client secret or token.

1. Confirm discovery and automatic public-client registration complete.
2. Follow Ninjy's existing provider sign-in. The probe grants only `mcp:probe`;
   it does not enroll a device or approve hosted vault access.
3. Confirm initialization and `tools/list` expose only `probe`; calling it
   returns a fixed synthetic connectivity message.
4. Start another conversation and confirm it reuses the connection.
5. After the ten-minute access-token expiry, confirm the provider refreshes
   automatically and the probe still works. Record whether refresh happens
   proactively or after a 401; do not infer it from a successful initial call.
6. Record the actual client callback URI, requested MCP version, registration
   method, code/token length acceptance and refresh behavior. Never record raw
   codes, tokens, session cookies or user secrets.

The service journal emits only fixed success markers (`mcp_probe token_issued
authorization_code`, `mcp_probe token_issued refresh_token`, `mcp_probe tool_called
probe`). These establish that refresh and tool invocation actually reached the
service. The synthetic tool response includes server time to distinguish calls.
Markers contain no user identities, credentials, bindings or request contents.

No real Claude acceptance result has been recorded yet. Fixture tests do not
prove actual provider interoperability. Repeat against each additional provider
before claiming it is supported.

## Deliberate U0 limits

- Credentials and codes are 1,024-character opaque random strings. This exercises
  representative callback/header/token sizes without creating a private vault
  capability. These are not sealed capability envelopes. U1 must repeat size
  acceptance with the actual reviewed envelope format.
- Codes expire after two minutes and are single-use, with exact client/redirect
  binding and required S256 PKCE. OAuth resource binding is required at authorize
  and token exchange. Only public clients (`none`) and one HTTPS redirect URI
  per registration are supported; no client-metadata fetches or SSRF surface.
- Access expires after ten minutes. U0 refresh credentials expire after one hour
  and rotate once without lost-response grace. This limited synthetic probe is
  not the U1 persistent delegation/retry protocol; do not reuse this store for U1.
- All registrations and hash-only credential records live in process RAM. A
  restart invalidates them. Stores are bounded at 256 entries per kind; expired
  credentials/pending logins are swept, and a full store rejects new issuance.
  Registrations last until restart; this is a small staging probe, not a public
  production registration service. Keep staging ingress rate limits enabled.
- A five-minute, one-use resume ticket carries the OAuth request through the
  existing browser-login return-path validator. The validator itself is unchanged.
- No hosted-decryption consent screen or persistent grants are implemented here.
  U1 owns that UI and must use `DESIGN.md`, `docs/design-system/README.md`, shared
  components and `src/ui/tokens.css`. U0 adds no UI components.
- The probe supports MCP versions `2025-03-26`, `2025-06-18` and `2025-11-25` with
  JSON POST responses; GET returns 405. No SSE stream or unsolicited model wake.
- Normal native bearer/device-proof gates are unchanged; probe credentials are
  accepted only by this synthetic endpoint, never by existing Hub APIs.

Ingress must redact OAuth query codes, Authorization and token response bodies.
Disable request/response body capture for the probe, including proxy/APM error
dumps. Even though U0 contains no real vault key, its credential flow should be
tested under the non-persistence controls required by U1.

## Protocol references

- [MCP authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
- [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)

## Local checks

```bash
odin test src/hub/service/mcp -collection:odin_test=src \
  -out:$HOME/.cache/heimdall-tests/mcp-spike-$$
odin test src/hub/transport/http -collection:odin_test=src \
  -out:$HOME/.cache/heimdall-tests/mcp-http-$$ \
  -define:ODIN_TEST_NAMES=test_mcp_probe_metadata_routes_are_exact,test_mcp_probe_login_resume_and_oauth_exchange,test_mcp_probe_unauthenticated_and_parameter_errors
```

Use the host's usual linker flags if needed. This development host's Odin version
also rejects four inherited `json.parse(string)` sites outside this change.
Validation can temporarily substitute `json.parse_string` at those sites, then
restore the original files byte-for-byte; those substitutions are not part of
the deliverable. Report that limitation alongside results.
