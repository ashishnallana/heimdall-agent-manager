import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { check, eventually } from './nativeMcpAcceptance.ts';

export async function remoteMcpBridge(h: any) {
  const executable = process.env.HEIMDALL_E2E_OPERATOR_CTL_BIN;
  const bridge = process.env.HEIMDALL_E2E_REMOTE_BRIDGE;
  h.operatorEnv.HEIMDALL_AGENT_INSTANCE_ID ||= process.env.HEIMDALL_E2E_OPERATOR_INSTANCE_ID;
  check(executable && bridge && h.operatorEnv.HEIMDALL_AGENT_INSTANCE_ID, 'explicit remote operator context supplied');
  const call = (args: string[]) => new Promise<any>((resolve, reject) => {
    execFile(executable, args, { env: h.operatorEnv, maxBuffer: 1024 * 1024 }, (error, stdout) => {
      if (error) { reject(new Error('Remote operator CLI failed')); return; }
      let result: any; try { result = JSON.parse(stdout); } catch { reject(new Error('Non-JSON remote operator reply')); return; }
      if (!result.ok) { reject(new Error('Remote operator ' + args.slice(0,2).join(' ') + ': ' + (result.error?.code || 'refused'))); return; }
      resolve(result.data?.data ?? result.data);
    });
  });
  const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";
  const code = fs.readFileSync(new URL('./remoteMcpBridge.py', import.meta.url), 'utf8');
  const hash = createHash('sha256').update(fs.readFileSync(h.certFile)).digest('hex');
  const binaryHash = process.env.HEIMDALL_E2E_REMOTE_TEST_BINARY === '1' ? createHash('sha256').update(fs.readFileSync(process.env.HEIMDALL_E2E_BRIDGE_BIN!)).digest('hex') : '';
  const started = await call(['shell','start','--bridge',bridge,'--agent',h.operatorEnv.HEIMDALL_AGENT_INSTANCE_ID,'--kind','run','--label','isolated-mcp-dawnstar-acceptance','--cmd',`python3 -u -c ${quote(code)} ${quote(h.base)} ${quote(hash)} ${quote(binaryHash)}`]);
  const session = started.session.session_id;
  console.log('REMOTE_SESSION ' + session);
  const logs = async () => (await call(['shell','log',session,'--limit','100'])).lines.join('\n');
  const close = async () => { await call(['shell','kill',session]).catch(() => {}); };
  try {
    const pairing = await eventually(async () => /PAIR_CODE ([A-Z2-7-]+)/.exec(await logs())?.[1], 'remote Bridge pairing', 45000);
    const bridgeId = await h.approveBridge(pairing);
    await eventually(async () => (await logs()).includes('REMOTE_ENROLLED') ? true : undefined, 'remote enrollment exit');
    const meta = JSON.parse(/REMOTE_META (.+)/.exec(await logs())![1]);
    await eventually(async () => { const response = await h.request('GET','/api/v1/bridges'); return (response.data.bridges ?? response.data).find((row: any) => row.bridge_id === bridgeId && row.status === 'online'); }, 'remote Bridge online');
    check(meta.hostname === 'dawnstar', 'second Bridge runs on physical Dawnstar');
    return { bridgeId, projectDir: meta.project, physicalHostname: meta.hostname, close,
      async releaseBarrier() { await call(['shell','start','--bridge',bridge,'--agent',h.operatorEnv.HEIMDALL_AGENT_INSTANCE_ID,'--kind','run','--cmd',`python3 -c ${quote(`from pathlib import Path; Path(${JSON.stringify(meta.project + '/.controller-ready')}).write_text('ready')`)}`]); },
    };
  } catch (error) { await close(); throw error; }
}
