// UI-14/UI-15: shared cookie-authenticated JSON fetch helper. The browser holds
// only the Hub's OIDC session cookie (HttpOnly); the rewrite app uses the SAME cookie auth
// session as `/api/v1/me` (`credentials: 'include'`), NOT the legacy per-client
// token session (`withSessionQuery` + `session.clientToken`). Centralizing this
// stops each new cookie endpoint from reinventing its own apiUrl/fetch wrapper.

import { withApiBase } from './apiBase';
import type { WireErrorClass } from './wireError';
import { announcePlanLimit } from '../utils/planLimit';

/**
 * ApiError carries the hub's MACHINE-READABLE error code alongside the message.
 *
 * Every helper below used to throw `new Error(message)`, which discarded the code —
 * and the code is the only thing that tells some outcomes apart. REQ-SHELL-8 is the
 * case that forced this: `GET /shells/{id}/log` answers 409 `bridge_offline` when the
 * owning bridge is gone, 410 `gone` when the retention window reclaimed the output,
 * and 200-with-zero-lines when the command genuinely printed nothing
 * (shell_session_service.odin:1037-1046). With only the message in hand a caller has
 * to string-match a human sentence that is free to be reworded, so the three states
 * collapse back into "something went wrong".
 *
 * `code` is the hub's `error.code` (domain.error_code_string), `status` the HTTP
 * status. Both are optional: a network failure or an unparseable body yields neither,
 * and callers must handle that rather than assume a code is always present.
 *
 * This subclasses Error, so every existing `catch (e) { e.message }` and
 * `apiErrorText` path is unaffected — the code is additive.
 */
export class ApiError extends Error {
  readonly status?: number;
  readonly code?: string;
  // REQ-ERR-PROTO-A: the error's class (retriable / recoverable / fatal) and its
  // fine-grained cause, when the hub sent them.
  readonly errorClass?: WireErrorClass;
  readonly errorCause?: string;
  // Tickets (M2): the hub's structured `error.details` object when sent
  // (e.g. 422 publish → {code:'brief_incomplete', tasks:[{task_id, missing}]}).
  readonly details?: any;
  constructor(message: string, status?: number, code?: string, errorClass?: WireErrorClass, errorCause?: string, details?: any) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
    this.errorClass = errorClass;
    this.errorCause = errorCause;
    this.details = details;
  }
}

// Shared by all three helpers: turn a non-2xx Response into an ApiError, preferring
// the hub's own sentence and code over a synthesised one.
export async function errorFromResponse(res: Response): Promise<ApiError> {
  let msg = `Request failed (${res.status})`;
  let code: string | undefined;
  let errorClass: WireErrorClass | undefined;
  let cause: string | undefined;
  let details: any;
  try {
    const text = await res.text();
    const errBody = JSON.parse(text);
    if (errBody?.error?.message) msg = errBody.error.message;
    else if (errBody?.message) msg = errBody.message;
    if (typeof errBody?.error?.code === 'string') code = errBody.error.code;
    else if (typeof errBody?.code === 'string') code = errBody.code;
    if (errBody?.error?.class) errorClass = errBody.error.class;
    if (typeof errBody?.error?.cause === 'string') cause = errBody.error.cause;
    if (errBody?.error?.details && typeof errBody.error.details === 'object') details = errBody.error.details;
  } catch (e) { /* non-JSON or unreadable body — the status line is all we have */ }
  const error = new ApiError(msg, res.status, code, errorClass, cause, details);
  announcePlanLimit(error);
  return error;
}

// `withApiBase` is the identity in every normal build; it only does something in a
// preview build, where the app is served under a path prefix (see apiBase.ts).
export function apiUrl(path: string): string {
  return withApiBase(path.startsWith('/api/v1') ? path : `/api/v1${path.startsWith('/') ? path : `/${path}`}`);
}

// GET `/api/v1/...` with cookie auth. Returns the unwrapped `data` array if the
// response is a list, otherwise the parsed body. Throws on non-2xx so RTK Query
// queryFn maps it to an error state.
// `init` carries an optional AbortSignal so a caller can bound a request that stalls.
export async function cookieJsonFetch(path: string, init?: RequestInit): Promise<any> {
  const res = await fetch(apiUrl(path), { ...init, credentials: 'include' });
  if (!res.ok) throw await errorFromResponse(res);
  let rawText: string;
  try {
    rawText = await res.text();
  } catch (e) {
    throw new Error(`Failed to read response body for ${path}`);
  }
  try {
    const body = JSON.parse(rawText);
    return body?.data !== undefined ? body.data : body;
  } catch (e) {
    console.error('[cookieJsonFetch] JSON parse error for', path, '— raw body (first 500 chars):', rawText.slice(0, 500));
    throw new Error(`JSON parse failed for ${path}: ${(e as Error).message}`);
  }
}

// Like cookieJsonFetch but returns the FULL response envelope ({data, page, meta})
// instead of unwrapping `data`. Needed by paginated endpoints (e.g. search) whose
// cursor/has_more live in the `page` sibling of `data`, which unwrapping strips.
// `init` carries an AbortSignal (and nothing else callers need today): a keyset
// paged list supersedes its in-flight page whenever the filters change, and
// `useInfiniteList` hands each fetch a signal it expects to be honoured.
export async function cookieJsonFetchEnvelope(path: string, init?: RequestInit): Promise<any> {
  const res = await fetch(apiUrl(path), { ...init, credentials: 'include' });
  if (!res.ok) throw await errorFromResponse(res);
  return res.json();
}

export async function cookieMutation(path: string, method: string = 'POST', data?: any): Promise<any> {
  const res = await fetch(apiUrl(path), {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: data ? JSON.stringify(data) : undefined,
    credentials: 'include'
  });
  if (!res.ok) throw await errorFromResponse(res);
  const text = await res.text();
  if (!text) return {};
  try {
    const body = JSON.parse(text);
    return body?.data !== undefined ? body.data : body;
  } catch (e) {
    return text;
  }
}

/**
 * customQueryError builds the RTK `CUSTOM_ERROR` a `queryFn` returns, keeping the
 * hub's machine-readable `code` and HTTP status beside the message. T10: without
 * them a typed refusal (HTTP 423 `vault_locked`) collapses into free text and the UI
 * can no longer tell a locked bridge from any other failure.
 */
export function customQueryError(error: unknown): { status: 'CUSTOM_ERROR'; error: string; code?: string; originalStatus?: number; details?: any } {
  const e = error as any;
  const out: { status: 'CUSTOM_ERROR'; error: string; code?: string; originalStatus?: number; details?: any } = {
    status: 'CUSTOM_ERROR',
    error: String(e?.message || e),
  };
  if (typeof e?.code === 'string' && e.code) out.code = e.code;
  if (typeof e?.status === 'number') out.originalStatus = e.status;
  if (e?.details) out.details = e.details;
  return out;
}

/**
 * apiErrorText turns whatever a `queryFn`-based mutation's `.unwrap()` rejects with
 * into a human-readable string.
 *
 * These endpoints reject with an RTK `CUSTOM_ERROR` object
 * `{ status: "CUSTOM_ERROR", error: "<message>" }` — so the real message lives on
 * `err.error`, NOT `err.data` or `err.message`. A caller reading only
 * `err?.data?.error || err?.message` falls through to `String(err)` and renders the
 * useless "[object Object]". This also handles the `FetchBaseQueryError` shape
 * (`{ data: { error | message } }`), a plain `Error`, and a bare string.
 *
 * Lives here rather than beside one resource: every resource's endpoints module
 * needs the same unwrapping, and a second copy is a second thing to fix.
 */
export function apiErrorText(err: unknown, fallback = 'Something went wrong'): string {
  const nonBlank = (v: unknown): string | undefined =>
    typeof v === 'string' && v.trim() ? v : undefined;
  if (err == null) return fallback;
  if (typeof err === 'string') return nonBlank(err) ?? fallback;
  const e = err as any;
  const data = e.data;
  if (data) {
    if (typeof data === 'string') { const s = nonBlank(data); if (s) return s; }
    else {
      const s = nonBlank(data?.error?.message) ?? nonBlank(data?.error) ?? nonBlank(data?.message);
      if (s) return s;
    }
  }
  const fromError = nonBlank(e.error) ?? nonBlank(e.error?.message);
  if (fromError) return fromError;
  return nonBlank(e.message) ?? fallback;
}

/** HTTP status a query error carries (`customQueryError`'s originalStatus or a fetchBaseQuery status). */
export function queryErrorStatus(error: unknown): number | undefined {
  const e = error as any;
  if (typeof e?.originalStatus === 'number') return e.originalStatus;
  if (typeof e?.status === 'number') return e.status;
  return undefined;
}

/**
 * A query error that repeating the same request cannot fix: the resource is gone or
 * not ours (404/410/403), or the session is unauthenticated (401; the fetch observer
 * and the Electron device gate already route that to sign-in). Polls stop on these;
 * an explicit refetch or invalidation may still try again.
 */
export function isTerminalQueryError(error: unknown): boolean {
  const status = queryErrorStatus(error);
  return status === 401 || status === 403 || status === 404 || status === 410;
}
