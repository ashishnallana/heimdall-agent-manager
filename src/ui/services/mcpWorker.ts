import { currentDeviceIdentity, verifiedChainForApproval } from './deviceVault';
import { getKeyringSession, subscribeKeyringSession } from '../utils/vaultKeyringSession';
import { verifyMcpWorkerJob, transformMcpWorkerJob, signMcpWorkerReply } from '../utils/mcpWorker';
import { fetchMcpWorkerJob, deliverMcpWorkerReply, registerMcpWorker } from '../api/endpoints/mcp';
import { apiUrl } from '../api/cookieFetch';

let busy = false;
let again = false;
let enabled = false;
let generation = '';
let generationUser = '';
let registeredAt = 0;
let observing = false;
const listeners = new Set<() => void>();
export const isMcpWorkerEnabled = () => enabled;
export const subscribeMcpWorker = (fn: () => void) => { listeners.add(fn); return () => { listeners.delete(fn); }; };
export async function setMcpWorkerEnabled(value: boolean): Promise<void> {
  if (!value) {
    enabled = false;
    for (const fn of listeners) fn();
    const old = generation;
    if (old) { try { await registerMcpWorker(old, false); } finally { if (generation === old) { generation = ''; registeredAt = 0; } } }
    return;
  }
  const identity = currentDeviceIdentity();
  if (!identity || !getKeyringSession()) throw new Error('Unlock this approved device first');
  if (!observing) { observing = true; subscribeKeyringSession(() => { void refreshMcpWorkerRegistration(); }); }
  const candidate = crypto.randomUUID();
  generation = candidate; generationUser = identity.userId;
  const response = await registerMcpWorker(candidate, true);
  if (generation !== candidate || !response.registered || currentDeviceIdentity() !== identity || !getKeyringSession()) {
    await registerMcpWorker(candidate, false).catch(() => {});
    throw new Error('Worker registration unavailable');
  }
  enabled = true; registeredAt = Date.now();
  for (const fn of listeners) fn();
  void runMcpWorker();
}
/** Called by the existing user-socket heartbeat. No independent polling loop. */
export async function refreshMcpWorkerRegistration(): Promise<void> {
  if (!enabled) return;
  const identity = currentDeviceIdentity();
  if (!identity || identity.userId !== generationUser || !getKeyringSession()) {
    await setMcpWorkerEnabled(false).catch(() => {}); return;
  }
  if (Date.now() - registeredAt < 20000) return;
  try { await registerMcpWorker(generation, true); registeredAt = Date.now(); }
  catch { /* A missed renewal expires on the Hub; it never grants offline authority. */ }
}
/** A bounded hint handler, not a background provider-wake or polling loop.
 * The existing vault boot/unlock is the only way this worker obtains keys. */
export async function runMcpWorker(): Promise<void> {
  if (busy) { again = true; return; }
  if (!enabled || !generation || currentDeviceIdentity()?.userId !== generationUser || !getKeyringSession()) return;
  const workerGeneration = generation;
  busy = true;
  try {
    for (let n = 0; n < 4; n += 1) {
      again = false;
      if (!enabled || generation !== workerGeneration) return;
      const job = await fetchMcpWorkerJob(workerGeneration);
      if (!job) break;
      const chain = await verifiedChainForApproval();
      const session = getKeyringSession();
      const identity = currentDeviceIdentity();
      if (!session || !identity || session.identity !== identity) return;
      const resource = new URL(apiUrl('/api/v1/mcp'), window.location.href).href;
      await verifyMcpWorkerJob(job, identity, chain, resource);
      const result = await transformMcpWorkerJob(job, session.keyring);
      if (!enabled || generation !== workerGeneration || getKeyringSession() !== session || currentDeviceIdentity() !== identity || Date.now() >= job.deadline_ms) return;
      const reply = await signMcpWorkerReply(job, identity, result);
      if (!enabled || generation !== workerGeneration || getKeyringSession() !== session || Date.now() >= job.deadline_ms) return;
      await deliverMcpWorkerReply(reply, workerGeneration);
    }
  } catch {
    // The tool returns a generic unavailable error. Never log job/plaintext or
    // treat worker failure as a reason to launch pairing/recovery automatically.
  } finally {
    busy = false;
    if (again) { again = false; void runMcpWorker(); }
  }
}
