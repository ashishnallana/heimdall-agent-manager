// REQ-LSP-UI-1: browser -> Hub LSP transport and session lifecycle.
//
// Speaks the relay envelope defined by the Hub in
// src/hub/transport/http/lsp_session_handlers.odin, and JSON-RPC inside it.
//
// ENVELOPE (verified against that file, not assumed):
//   browser -> hub : {"type":"start","bridge_id","language","file_path"}
//                    {"type":"send","message":"<raw JSON-RPC text>"}
//                    {"type":"stop"} / {"type":"ping"}
//   hub -> browser : {"type":"ready"}                       (sent on upgrade)
//                    {"type":"lsp_started","ok":bool,"error"?:{code,class,cause,message}}
//                    {"type":"lsp_data","message":"<raw JSON-RPC text>"}
//                    {"type":"lsp_error","reason","exit_code"}
//                    {"type":"lsp_stopped"} / {"type":"pong"}
//
// THE BROWSER NEVER SENDS cmd OR args. The Hub resolves the command from the
// operator's stored config; a browser-supplied command would be arbitrary code
// execution on the bridge host. That is the security boundary of this feature —
// do not add a cmd field here, however convenient it looks.
//
// FRAMING IS NOT OURS. The LSP base protocol's "Content-Length: N\r\n\r\n"
// header is added and stripped by the BRIDGE (src/bridge/lsp_session.odin:706
// on the way in, lsp_try_parse_one on the way out). What crosses this socket is
// therefore a bare JSON-RPC object as text. Do not add headers here; the server
// would see them twice.

import { apiAbsoluteUrl } from '../api/apiBase';
import {
  isJsonRpcNotification,
  isJsonRpcResponse,
  isJsonRpcServerRequest,
  jsonRpcNotification,
  jsonRpcRequest,
  type JsonRpcIncoming,
  type LspSymbolInformation,
} from './lspProtocol';

// The Hub closes a silent socket after LSP_IDLE_TIMEOUT (15 minutes,
// lsp_session_handlers.odin:48). An editor legitimately sits idle for longer, so
// the client pings well inside that bound to hold the session open. 4 minutes
// gives three missed pings of slack before the Hub's timer could fire.
const PING_INTERVAL_MS = 4 * 60 * 1000;

// A request that never comes back must not leak its promise forever: a language
// server that wedges would otherwise pin every pending completion closure for
// the life of the tab. 20s is far past a healthy server's worst case.
const REQUEST_TIMEOUT_MS = 20000;

export type LspClientStatus = 'idle' | 'connecting' | 'starting' | 'ready' | 'error' | 'closed';

export type LspClientOptions = {
  bridgeId: string;
  /** LSP language id — what the Hub resolves the server config by. */
  language: string;
  /** Absolute path on the bridge host; picks the dir_prefix override. */
  filePath: string;
  /** Workspace root, absolute, for the initialize handshake. */
  rootPath: string;
  onStatus?: (status: LspClientStatus, detail?: string) => void;
  onNotification?: (method: string, params: unknown) => void;
};

// http(s) -> ws(s) swap that PRESERVES the path already present in the URL
// (overwriting the pathname would discard a preview prefix).
function httpUrlToWs(absoluteUrl: string): URL {
  const parsed = new URL(absoluteUrl);
  parsed.protocol = parsed.protocol === 'https:' ? 'wss:' : 'ws:';
  parsed.hash = '';
  return parsed;
}

// Ticket auth, following src/ui/components/shells/useShellStream.ts:38-55 rather
// than inventing a second shape: the long-lived bearer token must never appear
// in a WebSocket URL, so a short-lived single-use ticket is minted over
// authenticated fetch and spent on the upgrade.
async function lspStreamUrl(sessionId: string): Promise<string> {
  const path = `/api/v1/lsp/${encodeURIComponent(sessionId)}/stream`;
  // The URLs must be resolved against `document.baseURI`, not the bare origin: under the shell-session preview prefix
  // (`/api/v1/preview/<session>/`) an origin-rooted path drops the prefix and lands
  // on the Hub root instead of the previewed app. `apiAbsoluteUrl` is exactly the
  // helper apiBase.ts documents for this ("a WebSocket, an `<a href>`").
  const res = await fetch(apiAbsoluteUrl('/api/v1/me/ws-ticket'), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
  });
  const text = await res.text();
  let body: any = {};
  try {
    body = JSON.parse(text);
  } catch {
    body = {};
  }
  const data = body?.data !== undefined ? body.data : body;
  if (!res.ok) throw new Error(String(data?.error?.message || data?.message || `WS ticket failed (${res.status})`));
  const ticket = String(data?.ticket || '');
  if (!ticket) throw new Error('WS ticket missing ticket field');
  const url = httpUrlToWs(apiAbsoluteUrl(path));
  url.searchParams.set('ticket', ticket);
  return url.toString();
}

// The session id is browser-chosen and namespaced per user by the Hub, so it
// needs no unguessability — but it MUST be unique per socket. The registry
// answers a second socket on a live id with 409 Conflict and never a silent
// takeover (lsp_session_handlers.odin:621-625), so a fixed id would make a
// remount collide with its own not-yet-reaped predecessor.
function newSessionId(): string {
  const rand = Math.random().toString(36).slice(2, 10);
  return `lspui-${Date.now().toString(36)}-${rand}`;
}

type Pending = {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout>;
};

export class LspClient {
  private socket: WebSocket | null = null;
  private readonly opts: LspClientOptions;
  private readonly sessionId = newSessionId();
  private nextId = 1;
  private readonly pending = new Map<number, Pending>();
  private pingTimer: ReturnType<typeof setInterval> | undefined;
  private status: LspClientStatus = 'idle';
  // disposed is the authority on "this client is finished". Every async
  // continuation checks it, because a React StrictMode double-mount tears the
  // first client down while its ticket fetch is still in flight.
  private disposed = false;
  private initialised = false;
  private serverCapabilities: any = null;

  constructor(opts: LspClientOptions) {
    this.opts = opts;
  }

  getStatus(): LspClientStatus {
    return this.status;
  }

  getCapabilities(): any {
    return this.serverCapabilities;
  }

  private setStatus(status: LspClientStatus, detail?: string) {
    if (this.disposed && status !== 'closed') return;
    this.status = status;
    try {
      this.opts.onStatus?.(status, detail);
    } catch {
      /* a status observer must never break the transport */
    }
  }

  async connect(): Promise<void> {
    if (this.disposed || this.socket) return;
    this.setStatus('connecting');
    let url: string;
    try {
      url = await lspStreamUrl(this.sessionId);
    } catch (err) {
      this.setStatus('error', err instanceof Error ? err.message : String(err));
      return;
    }
    // The ticket fetch is awaited, so a teardown may have landed meanwhile.
    // Opening the socket now would leak it past dispose().
    if (this.disposed) return;

    const socket = new WebSocket(url);
    this.socket = socket;

    socket.onmessage = (event) => this.handleEnvelope(String(event.data ?? ''));
    socket.onerror = () => this.setStatus('error', 'lsp socket error');
    socket.onclose = () => {
      this.stopPing();
      this.rejectAllPending('lsp socket closed');
      this.socket = null;
      if (!this.disposed) this.setStatus('closed');
    };
    // No onopen work: the Hub sends {"type":"ready"} itself once the upgrade
    // completes, and "start" before that would race the handler's read loop.
  }

  private handleEnvelope(raw: string) {
    let frame: any;
    try {
      frame = JSON.parse(raw);
    } catch {
      return;
    }
    switch (String(frame?.type || '')) {
      case 'ready':
        this.sendEnvelope({
          type: 'start',
          bridge_id: this.opts.bridgeId,
          language: this.opts.language,
          file_path: this.opts.filePath,
          root_path: this.opts.rootPath,
        });
        this.setStatus('starting');
        this.startPing();
        break;
      case 'lsp_started':
        if (frame.ok) {
          void this.initialize();
        } else {
          this.setStatus('error', String(frame.error?.message || frame.error?.cause || 'language server failed to start'));
        }
        break;
      case 'lsp_data':
        this.handleRpc(String(frame.message ?? ''));
        break;
      case 'lsp_error':
        this.setStatus('error', String(frame.reason || 'language server error'));
        break;
      case 'lsp_stopped':
        this.setStatus('closed');
        break;
      default:
        // "pong" and anything a future Hub adds: ignored, not an error.
        break;
    }
  }

  private handleRpc(text: string) {
    if (!text) return;
    let msg: JsonRpcIncoming;
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }

    if (isJsonRpcResponse(msg)) {
      const id = Number(msg.id);
      const entry = this.pending.get(id);
      if (!entry) return;
      this.pending.delete(id);
      clearTimeout(entry.timer);
      if (msg.error) entry.reject(new Error(String(msg.error.message || 'lsp request failed')));
      else entry.resolve(msg.result);
      return;
    }

    if (isJsonRpcServerRequest(msg)) {
      // The server asked US something. We advertise no client capabilities that
      // require an answer, but the protocol still requires a reply — an
      // unanswered request makes a conforming server wait forever. MethodNotFound
      // (-32601) is the honest answer.
      this.sendRpc({
        jsonrpc: '2.0',
        id: msg.id,
        error: { code: -32601, message: `client does not implement ${msg.method}` },
      });
      return;
    }

    if (isJsonRpcNotification(msg)) {
      try {
        this.opts.onNotification?.(String(msg.method), msg.params);
      } catch {
        /* a notification handler must never break the transport */
      }
    }
  }

  private async initialize(): Promise<void> {
    if (this.disposed || this.initialised) return;
    try {
      const result: any = await this.request('initialize', {
        processId: null,
        clientInfo: { name: 'heimdall-monaco', version: '1' },
        rootUri: this.opts.rootPath ? `file://${encodeURI(this.opts.rootPath)}` : null,
        rootPath: this.opts.rootPath || null,
        workspaceFolders: this.opts.rootPath
          ? [{ uri: `file://${encodeURI(this.opts.rootPath)}`, name: 'workspace' }]
          : null,
        // Only what this adapter actually implements is advertised. Claiming a
        // capability we do not handle makes a server send traffic nobody reads
        // and, for request-shaped ones, wait on a reply that never comes.
        capabilities: {
          textDocument: {
            synchronization: { dynamicRegistration: false, didSave: false },
            completion: {
              dynamicRegistration: false,
              completionItem: { snippetSupport: false, documentationFormat: ['markdown', 'plaintext'] },
            },
            hover: { dynamicRegistration: false, contentFormat: ['markdown', 'plaintext'] },
            definition: { dynamicRegistration: false, linkSupport: true },
            references: { dynamicRegistration: false },
            implementation: { dynamicRegistration: false, linkSupport: true },
            documentSymbol: { dynamicRegistration: false, hierarchicalDocumentSymbolSupport: true },
            publishDiagnostics: { relatedInformation: false },
          },
          workspace: {
            workspaceFolders: Boolean(this.opts.rootPath),
            symbol: { dynamicRegistration: false },
          },
        },
      });
      if (this.disposed) return;
      this.serverCapabilities = result?.capabilities ?? null;
      this.notify('initialized', {});
      this.initialised = true;
      this.setStatus('ready');
    } catch (err) {
      if (this.disposed) return;
      this.setStatus('error', err instanceof Error ? err.message : String(err));
    }
  }

  private sendEnvelope(obj: unknown) {
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    try {
      socket.send(JSON.stringify(obj));
    } catch {
      /* a dying socket surfaces through onclose, not here */
    }
  }

  private sendRpc(rpc: unknown) {
    this.sendEnvelope({ type: 'send', message: JSON.stringify(rpc) });
  }

  /** Fire-and-forget JSON-RPC notification (didOpen, didChange, ...). */
  notify(method: string, params?: unknown) {
    this.sendRpc(jsonRpcNotification(method, params));
  }

  /** JSON-RPC request; resolves with `result`, rejects on error or timeout. */
  request(method: string, params?: unknown): Promise<unknown> {
    if (this.disposed) return Promise.reject(new Error('lsp client disposed'));
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error('lsp socket is not open'));
    }
    const id = this.nextId++;
    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`lsp request ${method} timed out`));
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(id, { resolve, reject, timer });
      this.sendRpc(jsonRpcRequest(id, method, params));
    });
  }

  /** True once initialize/initialized has completed and requests are meaningful. */
  isReady(): boolean {
    return !this.disposed && this.status === 'ready';
  }

  /** Query workspace symbols via workspace/symbol (REQ-LSP-SYMBOLS-1). */
  async queryWorkspaceSymbols(query: string): Promise<LspSymbolInformation[]> {
    if (!this.isReady()) return [];
    try {
      const raw = await this.request('workspace/symbol', { query });
      return (Array.isArray(raw) ? raw : []) as LspSymbolInformation[];
    } catch {
      return [];
    }
  }

  private startPing() {
    this.stopPing();
    this.pingTimer = setInterval(() => this.sendEnvelope({ type: 'ping' }), PING_INTERVAL_MS);
  }

  private stopPing() {
    if (this.pingTimer !== undefined) clearInterval(this.pingTimer);
    this.pingTimer = undefined;
  }

  private rejectAllPending(reason: string) {
    for (const [, entry] of this.pending) {
      clearTimeout(entry.timer);
      entry.reject(new Error(reason));
    }
    this.pending.clear();
  }

  // Orderly teardown: shutdown/exit is the protocol's way of letting the server
  // flush and die on its own; "stop" then tells the Hub to reap the process, and
  // closing the socket alone would too (the Hub's teardown defer sends a stop
  // when the socket dies). Both are sent because the polite path gives a server
  // the chance to exit cleanly, and the stop guarantees it is not left running
  // if it ignores the polite path.
  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    this.stopPing();
    const socket = this.socket;
    if (socket && socket.readyState === WebSocket.OPEN) {
      if (this.initialised) {
        // shutdown's reply will never be read — the socket closes first. That is
        // deliberate: waiting for it would hold the tab open on a wedged server.
        this.sendRpc(jsonRpcRequest(this.nextId++, 'shutdown', null));
        this.sendRpc(jsonRpcNotification('exit'));
      }
      this.sendEnvelope({ type: 'stop' });
    }
    this.rejectAllPending('lsp client disposed');
    try {
      socket?.close();
    } catch {
      /* already gone */
    }
    this.socket = null;
    this.initialised = false;
    this.setStatus('closed');
  }
}
