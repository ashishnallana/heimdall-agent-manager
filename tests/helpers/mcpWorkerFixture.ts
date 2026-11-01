import { FakeHub, newBrowser } from './vaultDirectoryFixture.ts';
import { buildMcpConsent } from '../../src/ui/utils/mcpConsent.ts';
import { importKeyring } from '../../src/ui/utils/vaultKeyring.ts';
import { encryptVaultText } from '../../src/ui/utils/vaultContent.ts';
import { mcpJobDigest, signMcpWorkerReply, transformMcpWorkerJob, type McpWorkerJob } from '../../src/ui/utils/mcpWorker.ts';

export async function mcpWorkerFixture(now = Date.now(), scope = 'mcp:chains') {
  const owner = 'usr_mcp_worker_fixture';
  const resource = 'https://hub.example/api/v1/mcp';
  const hub = new FakeHub(owner);
  const identity = await newBrowser(owner);
  await hub.genesis(identity);
  const bridge = await hub.addBridge(identity, 'brg_mcp_fixture');
  const chain = await hub.chain();
  const request = { owner, client: 'client-worker-fixture', redirect: 'https://client.example/callback', resource, scope, grant: 'grant-worker-fixture', family: 'family-worker-fixture', revision: 1, expires_ms: now + 300000 };
  const consent = await buildMcpConsent('ticket-worker-fixture', request, 'device', identity, chain, async () => { throw new Error('Default mode never exports keyring'); }, now);
  const bytes = await hub.keyringBytes(identity);
  const keyringHex = Buffer.from(bytes).toString('hex'); // SYNTHETIC fixture only.
  const keyring = await importKeyring(bytes, owner);
  const title = await encryptVaultText('worker secret title', keyring);
  const description = `embedded ${await encryptVaultText('worker secret body', keyring)}`;
  const snapshot = hub.dir();
  const directory = { owner, root_device_id: snapshot.root_device_id, head_hash: chain.headHash, version: chain.version, current_epoch: chain.currentEpoch, log: snapshot.log.map(e => ({ seq: e.seq, statement: e.statement, signature: JSON.stringify(e.signature) })), devices: snapshot.devices.map(d => ({ id: d.device_id, kind: d.kind, sign_alg: d.sign_alg, wrap_alg: d.wrap_alg, sign_public_key: d.sign_public_key, ecdh_public_key: d.ecdh_public_key, approved: d.status === 'approved', pending: d.status === 'pending' })), pin_seq: chain.version, pin_hash: chain.headHash, vault_id: chain.vaultId };
  const job: McpWorkerJob = { request_id: 'req_worker_fixture', generation: 'gen_worker_fixture', owner, resource, grant: request.grant, head: chain.headHash, operation: 'read', payload: JSON.stringify({ chain: { owner_user_id: owner, chain_id: 'chain_fixture', title, description, defaults_json: 'private internal brief' }, tasks: [], comments: [] }), digest: '', revision: 1, deadline_ms: now + 4000, epoch: chain.currentEpoch, consent: consent.consent, signature: consent.signature, directory };
  job.digest = await mcpJobDigest(job);
  const result = await transformMcpWorkerJob(job, keyring);
  const reply = await signMcpWorkerReply(job, identity, result);
  const bridgeIdentity = { ...identity, deviceId: bridge.deviceId, signPrivateKey: bridge.identity.privateKey };
  const bridgeReply = await signMcpWorkerReply(job, bridgeIdentity, result);
  return { hub, identity, bridge, chain, keyring, request, consent, keyringHex, job, result, reply, bridgeReply, now };
}
