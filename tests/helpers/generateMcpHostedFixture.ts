// Synthetic cross-runtime vectors only; no live account or key material.
import { writeFileSync } from 'node:fs';
import { FakeHub, newBrowser } from './vaultDirectoryFixture.ts';
import { buildMcpConsent } from '../../src/ui/utils/mcpConsent.ts';
import { buildRotation } from '../../src/ui/utils/vaultDeviceFlows.ts';
import { sealKeyringWrap } from '../../src/ui/utils/vaultKeyringWrap.ts';
import { importKeyring } from '../../src/ui/utils/vaultKeyring.ts';
import { genesisKeyringBytes, nextEpochKeyringBytes } from '../../src/ui/utils/vaultKeyringSession.ts';
import { encryptVaultText } from '../../src/ui/utils/vaultContent.ts';

const now = Date.parse('2026-10-31T07:00:00Z');
async function fixture(owner: string) {
  const hub = new FakeHub(owner);
  const identity = await newBrowser(owner);
  await hub.genesis(identity);
  const chain = await hub.chain();
  const request = { owner, client: 'client-fixture', redirect: 'https://client.example/callback', resource: 'https://hub.example/api/v1/mcp', scope: 'mcp:chains', grant: `grant-${owner}`, family: `family-${owner}`, revision: 1, expires_ms: now + 300000 };
  const withBytes = async <T>(run: (bytes: Uint8Array) => Promise<T>) => { const bytes = await hub.keyringBytes(identity); try { return await run(bytes); } finally { bytes.fill(0); } };
  const hosted = await buildMcpConsent(`ticket-${owner}`, request, 'hosted', identity, chain, withBytes, now);
  const initial = { now_ms: now, request, directory: hub.dir(), hosted };
  const initialKey = await importKeyring(await hub.keyringBytes(identity), owner);
  const title = await encryptVaultText(`${owner} secret`, initialKey);
  const content = { title, description: `note ${await encryptVaultText('embedded secret', initialKey)}`, comment_summary: { last_comment_preview: `comment ${title}` } };
  const bytes = await hub.keyringBytes(identity);
  const rotated = await buildRotation(identity, chain, bytes, now + 1000);
  bytes.fill(0);
  await hub.append(rotated.body.statement, rotated.body.signature);
  for (const wrap of rotated.body.wraps) hub.wraps.set(wrap.recipient_device_id, wrap);
  const next = await hub.chain();
  const consent = JSON.parse(hosted.consent);
  const wrap = await sealKeyringWrap(identity, owner, { device_id: consent.recipient, ecdh_public_key: consent.recipient_public_key }, next.version, rotated.nextKeyring);
  const key2 = await importKeyring(Uint8Array.from(rotated.nextKeyring), owner);
  const falseEpoch1 = genesisKeyringBytes(owner, chain.vaultId);
  const falseEpoch2 = nextEpochKeyringBytes(falseEpoch1, owner);
  falseEpoch1.fill(0);
  const wrong = await sealKeyringWrap(identity, owner, { device_id: consent.recipient, ecdh_public_key: consent.recipient_public_key }, next.version, falseEpoch2);
  falseEpoch2.fill(0);
  rotated.nextKeyring.fill(0);
  const rotated_directory = hub.dir();
  const a = await newBrowser(owner);
  const b = await newBrowser(owner);
  await hub.addBrowser(identity, a, 'Second browser');
  await hub.addBrowser(identity, b, 'Third browser');
  await hub.revoke(identity, a.deviceId);
  return { initial, content, rotated_directory, complex_directory: hub.dir(), rotated_wrap: { grant: request.grant, revision: 1, directory_version: next.version, directory_head: next.headHash, wrap_json: JSON.stringify(wrap.json) }, wrong_key_wrap: { grant: request.grant, revision: 1, directory_version: next.version, directory_head: next.headHash, wrap_json: JSON.stringify(wrong.json) }, rotated_content: { title: await encryptVaultText(`${owner} epoch two`, key2), description: title } };
}
writeFileSync(new URL('../fixtures/mcp_hosted_v1.json', import.meta.url), JSON.stringify({ synthetic_fixture: true, alice: await fixture('usr_alice_fixture'), bob: await fixture('usr_bob_fixture') }, null, 2) + '\n');
