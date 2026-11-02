#!/usr/bin/env node
// Run from a development checkout after npm ci, as with the existing WS smoke
// clients. Node >=24 provides native TypeScript stripping for shared UI crypto.
import WebSocket from 'ws';
import { McpProtocol } from './mcp/protocol.mjs';
import { HeimdallControlClient } from './mcp/heimdall-client.mjs';

let protocol;
try {
  const client = new HeimdallControlClient({
    hubUrl: process.env.HEIMDALL_MCP_HUB_URL,
    token: process.env.HEIMDALL_MCP_OIDC_TOKEN,
    openSocket: (url, headers) => new WebSocket(url, { headers, perMessageDeflate: false, maxPayload: 1024 * 1024, handshakeTimeout: 10_000 }),
    onPairing: ({ code, fingerprint }) => process.stderr.write(`Approve Ninjy MCP POC using code ${code} (fingerprint ${fingerprint}).\n`),
  });
  // Keep no second copy in the process environment inherited by future children.
  delete process.env.HEIMDALL_MCP_OIDC_TOKEN;
  protocol = new McpProtocol(client);
} catch {
  process.stderr.write('MCP configuration failed. Set HEIMDALL_MCP_HUB_URL and HEIMDALL_MCP_OIDC_TOKEN to an OIDC user access token.\n');
  process.exitCode = 1;
}

if (protocol) {
  let buffer = '';
  const output = response => { if (response) process.stdout.write(JSON.stringify(response) + '\n'); };
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => {
    buffer += chunk;
    if (Buffer.byteLength(buffer) > 1024 * 1024) { process.stderr.write('MCP input limit exceeded.\n'); protocol.close(); process.exit(1); }
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
      if (!line.trim()) continue;
      let request;
      try { request = JSON.parse(line); }
      catch { output({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }); continue; }
      void protocol.handle(request).then(output).catch(() => output({ jsonrpc: '2.0', id: request?.id ?? null, error: { code: -32603, message: 'Internal error' } }));
    }
  });
  const close = () => { protocol.close(); process.stdin.destroy(); };
  process.stdin.on('end', close);
  process.on('SIGTERM', close);
  process.on('SIGINT', close);
}
