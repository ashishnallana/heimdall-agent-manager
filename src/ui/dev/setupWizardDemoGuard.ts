/**
 * Network guard for the setup-wizard fixture (setup-wizard-demo.html). Imported FIRST
 * by setupWizardDemo.tsx so it replaces window.fetch / WebSocket / EventSource before
 * any app module can reach the network.
 *
 * Every request is answered from the fixture router the demo installs; anything the
 * router does not know is REFUSED here (502, never forwarded), and WebSocket /
 * EventSource / sendBeacon are disabled outright. That is the whole safety argument
 * for this page: there is no code path from it to a real hub, so no enrollment,
 * revocation or project write can reach production — they land in the on-page log.
 */

export interface DemoRequest {
  method: string;
  /** Path after /api/v1, without query. */
  path: string;
  query: URLSearchParams;
  body: any;
}

export interface DemoCall extends DemoRequest {
  status: number;
  blocked: boolean;
  at: number;
}

export type DemoRouter = (req: DemoRequest) => Promise<{ status: number; body: unknown } | null> | { status: number; body: unknown } | null;

let router: DemoRouter = () => null;
const calls: DemoCall[] = [];
const listeners = new Set<() => void>();

export function setDemoRouter(next: DemoRouter) { router = next; }
export function demoCalls(): DemoCall[] { return calls; }
export function subscribeDemoCalls(listener: () => void): () => void {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}

function record(call: DemoCall) {
  calls.push(call);
  listeners.forEach((l) => l());
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

const API_MARKER = '/api/v1';

async function guardedFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const raw = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
  const method = String(init?.method || (input instanceof Request ? input.method : 'GET')).toUpperCase();
  let url: URL;
  try { url = new URL(raw, location.href); } catch { url = new URL('about:blank'); }
  const at = url.pathname.indexOf(API_MARKER);
  // Same-origin static assets (Vite modules, fonts CSS is a <link>) never go through
  // fetch here; anything that is not the hub API is refused too.
  if (at < 0) {
    record({ method, path: url.href, query: url.searchParams, body: null, status: 502, blocked: true, at: Date.now() });
    return json(502, { error: { code: 'fixture_blocked', message: `Fixture refused a non-API request: ${url.href}` } });
  }
  const path = url.pathname.slice(at + API_MARKER.length) || '/';
  let body: any = null;
  try { body = init?.body ? JSON.parse(String(init.body)) : null; } catch { body = String(init?.body); }
  const req: DemoRequest = { method, path, query: url.searchParams, body };
  // A tiny delay so spinners and progress states are visible.
  await new Promise((r) => setTimeout(r, 250));
  const answer = await router(req);
  if (!answer) {
    record({ ...req, status: 502, blocked: true, at: Date.now() });
    return json(502, { error: { code: 'fixture_blocked', message: `Not available in the fixture preview: ${method} ${path}` } });
  }
  record({ ...req, status: answer.status, blocked: false, at: Date.now() });
  return json(answer.status, answer.body);
}

class BlockedSocket {
  constructor(url: string) {
    record({ method: 'WS', path: String(url), query: new URLSearchParams(), body: null, status: 0, blocked: true, at: Date.now() });
    throw new Error('WebSockets are disabled in the fixture preview');
  }
}

(window as any).fetch = guardedFetch;
(globalThis as any).fetch = guardedFetch;
(window as any).WebSocket = BlockedSocket;
(window as any).EventSource = BlockedSocket;
try { (navigator as any).sendBeacon = () => false; } catch { /* read-only in some engines */ }
