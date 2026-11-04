import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { useListBridgesQuery } from '../api/endpoints/bridgeSupport';
import { accountBridgeProfile, installedHubProfiles, otherAccountProfiles,
  type DesktopBridgeConfig, type DesktopBridgeManagerApi, type DesktopBridgeStatus } from './desktopBridge';
import { attachDesktopBridgeSession, desktopBridgeSession, subscribeDesktopBridgeSession } from './desktopBridgeSession';

export type MachineDetectionPhase = 'loading' | 'present' | 'absent' | 'error' | 'unsupported';

/** Status is identity evidence only when it confirms the exact discovered slot. */
export function verifiedMachineStatus(own: DesktopBridgeStatus, status: DesktopBridgeStatus, hub: string): boolean {
  try {
    return Boolean(status.supported && status.installed && !status.error && ['connected', 'disconnected', 'stopped', 'needs_reenrollment'].includes(status.state) && status.bridge_id === own.bridge_id
      && (status.profile || '') === (own.profile || '')
      && new URL(status.hub || '').origin === new URL(hub).origin);
  } catch { return false; }
}

/** Shared read-only detector. The operation itself remains owned by desktopBridgeSession. */
export function useThisMachineBridge(manager: DesktopBridgeManagerApi) {
  const query = useListBridgesQuery();
  const bridges = useMemo(() => query.data?.bridges || [], [query.data]);
  const accountBridgeIds = useMemo(() => query.data && !query.isError && !query.isFetching
    ? bridges.map((b: any) => String(b.bridge_id || b.bridgeId || b.id || '')).filter(Boolean) : null, [bridges, query.data, query.isError, query.isFetching]);
  const session = useSyncExternalStore(subscribeDesktopBridgeSession, desktopBridgeSession);
  const [config, setConfig] = useState<DesktopBridgeConfig | null>(null);
  const [status, setStatus] = useState<DesktopBridgeStatus | null>(null);
  const [profiles, setProfiles] = useState<DesktopBridgeStatus[]>([]);
  const [otherAccounts, setOtherAccounts] = useState(0);
  const [phase, setPhase] = useState<MachineDetectionPhase>('loading');
  const [error, setError] = useState('');
  const generation = useRef(0);
  const refresh = useCallback(async () => {
    const run = ++generation.current;
    setPhase('loading');
    setStatus(null);
    setError('');
    if (!accountBridgeIds) {
      if (query.isError) { setPhase('error'); setError('Unable to verify your bridges with the Hub.'); }
      return;
    }
    try {
      const nextConfig = await manager.getConfig();
      if (run !== generation.current) return;
      if (!nextConfig.ok || nextConfig.error) throw new Error(nextConfig.error || 'Unable to read bridge configuration.');
      setConfig(nextConfig);
      if (!nextConfig.supported) { setPhase('unsupported'); setError('This platform cannot run a Ninjy bridge.'); return; }
      // Reject an invalid Hub before even an empty local inventory can mean absence.
      const hubUrl = new URL(nextConfig.hubUrl);
      if (!['http:', 'https:'].includes(hubUrl.protocol)) throw new Error('The Hub URL must use HTTP or HTTPS.');
      const listed = await manager.list();
      if (run !== generation.current) return;
      if (!listed.ok || !Array.isArray(listed.profiles)) throw new Error(listed.error || 'Unable to list bridges on this machine.');
      const own = accountBridgeProfile(listed.profiles, nextConfig.hubUrl, accountBridgeIds);
      setProfiles(installedHubProfiles(listed.profiles, nextConfig.hubUrl));
      setOtherAccounts(otherAccountProfiles(listed.profiles, nextConfig.hubUrl, accountBridgeIds).length);
      if (!own) {
        if (listed.profiles.some((p) => p.error || p.state === 'unknown')) throw new Error('Local bridge status is unknown. Check again before installing.');
        setPhase('absent');
        return;
      }
      const nextStatus = await manager.getStatus({ hub: nextConfig.hubUrl, profile: String(own.profile || '') });
      if (run !== generation.current) return;
      if (!verifiedMachineStatus(own, nextStatus, nextConfig.hubUrl)) throw new Error(nextStatus.error || 'Unable to verify the installed bridge identity and status.');
      setStatus(nextStatus);
      setPhase('present');
    } catch (err: any) {
      if (run === generation.current) { setStatus(null); setPhase('error'); setError(String(err?.message || err)); }
    }
  }, [manager, accountBridgeIds, query.isError]);
  useEffect(() => { attachDesktopBridgeSession(manager); }, [manager]);
  useEffect(() => {
    void refresh();
    return () => { ++generation.current; };
  }, [refresh]);
  const finishedSeen = useRef(session.finished);
  useEffect(() => {
    if (session.finished === finishedSeen.current) return;
    finishedSeen.current = session.finished;
    // Never adopt an unverified completion as account ownership. The Hub list
    // and the manager must agree before a badge or lifecycle target is exposed.
    void query.refetch();
    void refresh();
  }, [session.finished, query.refetch, refresh]);
  const owned = phase === 'present' && Boolean(status?.bridge_id && accountBridgeIds?.includes(status.bridge_id));
  const verifiedPhase = query.isError ? 'error' : query.isLoading || query.isFetching || !accountBridgeIds ? 'loading'
    : phase === 'present' && !owned ? 'loading' : phase;
  return { config, status, profiles, otherAccounts, phase: verifiedPhase, error, setError, refresh,
    accountBridgeIds, bridges, session, bridgeId: owned ? String(status?.bridge_id || '') : '' };
}
