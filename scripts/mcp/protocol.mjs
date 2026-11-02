import { ControlError } from './heimdall-client.mjs';

const objectSchema = (properties, required = []) => ({ type: 'object', properties, required, additionalProperties: false });
const chain = { type: 'string', description: 'Owned task chain identifier.' };
export const tools = [
  { name: 'chains.list', description: 'List your Heimdall task chains. Pair this MCP device if prompted.', inputSchema: objectSchema({ limit: { type: 'integer', minimum: 1, maximum: 100 }, cursor: { type: 'string' } }), annotations: { readOnlyHint: true } },
  { name: 'chains.get', description: 'Read a chain and its task/review status in readable form.', inputSchema: objectSchema({ chain_id: chain }, ['chain_id']), annotations: { readOnlyHint: true } },
  { name: 'chains.create', description: 'Create a task chain as the signed-in user. Does not launch or assign an agent.', inputSchema: objectSchema({ title: { type: 'string', minLength: 1, maxLength: 500 }, description: { type: 'string', maxLength: 20000 } }, ['title']), annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false } },
  { name: 'events.wait', description: 'Wait up to 30 seconds for a change on one owned chain, then return fresh state. Live hints only; no replay. Keep calling to continue waiting.', inputSchema: objectSchema({ chain_id: chain, timeout_ms: { type: 'integer', minimum: 1, maximum: 30000 } }, ['chain_id']), annotations: { readOnlyHint: true } },
];
const error = (id, code, message) => ({ jsonrpc: '2.0', id, error: { code, message } });
const success = (id, result) => ({ jsonrpc: '2.0', id, result });

export class McpProtocol {
  constructor(client) { this.client = client; this.initialized = false; this.pending = new Map(); this.busy = false; }
  async handle(request) {
    if (!request || Array.isArray(request) || request.jsonrpc !== '2.0' || typeof request.method !== 'string') return error(request?.id ?? null, -32600, 'Invalid Request');
    const hasId = Object.hasOwn(request, 'id');
    if (hasId && typeof request.id !== 'string' && !(typeof request.id === 'number' && Number.isSafeInteger(request.id))) return error(null, -32600, 'Invalid request id');
    if (request.method === 'notifications/cancelled') { this.pending.get(request.params?.requestId)?.abort(); return null; }
    if (!hasId) return null;
    if (this.pending.has(request.id)) return error(request.id, -32600, 'Request id is already active');
    if (request.method === 'initialize') {
      if (!request.params || typeof request.params.protocolVersion !== 'string' || this.initialized) return error(request.id, -32602, 'Invalid initialization');
      this.initialized = true;
      const supported = ['2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25'];
      return success(request.id, { protocolVersion: supported.includes(request.params.protocolVersion) ? request.params.protocolVersion : '2025-11-25', capabilities: { tools: {} }, serverInfo: { name: 'heimdall-control-poc', version: '0.1.0' }, instructions: 'Act under the authenticated Heimdall user. If pairing_pending is returned, ask the user to approve the displayed code in Ninjy, then retry. Use events.wait cooperatively and refetch after reconnect; this server has no task claim/review tools.' });
    }
    if (!this.initialized) return error(request.id, -32002, 'Initialize first');
    if (request.method === 'ping') return success(request.id, {});
    if (request.method === 'tools/list') return success(request.id, { tools });
    if (request.method !== 'tools/call') return error(request.id, -32601, 'Method not found');
    const tool = tools.find(item => item.name === request.params?.name);
    const args = request.params?.arguments ?? {};
    if (!tool || !args || typeof args !== 'object' || Array.isArray(args) || Object.keys(args).some(k => !Object.hasOwn(tool.inputSchema.properties, k)) || tool.inputSchema.required.some(k => !Object.hasOwn(args, k))) return error(request.id, -32602, 'Unknown tool or invalid arguments');
    // One in-memory vault identity per MCP process. Serialize tool calls to avoid
    // racing pairing/global keyring state; protocol cancellation still runs.
    if (this.busy) return success(request.id, { isError: true, content: [{ type: 'text', text: 'busy: another tool call is active; retry after it completes.' }] });
    const controller = new AbortController();
    this.pending.set(request.id, controller);
    this.busy = true;
    try {
      const result = await this.client[{ 'chains.list': 'list', 'chains.get': 'get', 'chains.create': 'create', 'events.wait': 'wait' }[tool.name]](args, controller.signal);
      return success(request.id, { content: [{ type: 'text', text: JSON.stringify(result) }] });
    } catch (cause) {
      return success(request.id, { isError: true, content: [{ type: 'text', text: cause instanceof ControlError ? `${cause.code}: ${cause.message}` : 'request_failed: request failed; check authentication, connectivity and vault approval.' }] });
    } finally { this.pending.delete(request.id); this.busy = false; }
  }
  close() { for (const controller of this.pending.values()) controller.abort(); this.client.close(); }
}
