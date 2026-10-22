import { cookieJsonFetch } from './cookieFetch';
import {
  LIVE_MEMBER_CAP, parseLiveSnapshot, liveSnapshotStarted, liveSnapshotLoaded,
  liveSnapshotFailed, type LiveMember, type LiveScope,
} from '../store/toolActivitySlice';

export class RosterChangedError extends Error {}
type ReadJson = (path: string, init?: RequestInit) => Promise<any>;

// Event-triggered Bridge proxy reads only. No query cache or polling.
export async function readLiveScope(scope: Pick<LiveScope, 'instanceId' | 'chainId'>,
  read: ReadJson = cookieJsonFetch, signal?: AbortSignal): Promise<LiveMember[]> {
  const boundedRead = (path: string) => read(path, {
    cache: 'no-store',
    signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(6500)]) : AbortSignal.timeout(6500),
  });
  if (!scope.chainId) {
    const snapshot = parseLiveSnapshot(await boundedRead(
      '/agent-instances/' + encodeURIComponent(scope.instanceId) + '/tool-activity-live'));
    if (!snapshot || snapshot.instance_id !== scope.instanceId) throw new Error('Invalid live tool snapshot');
    return [{ instance_id: snapshot.instance_id, agent_id: snapshot.agent_id,
      display_name: snapshot.display_name, snapshot, availability: 'ready' }];
  }
  const members: LiveMember[] = [];
  const seen = new Set<string>();
  let cursor = '';
  let rosterToken: string | undefined;
  do {
    const page = await boundedRead('/task-chains/' + encodeURIComponent(scope.chainId) +
      '/tool-activity-live' + (cursor ? '?cursor=' + encodeURIComponent(cursor) : ''));
    if (page?.chain_id !== scope.chainId || !Array.isArray(page.members) ||
        page.members.length > 8 || typeof page.roster_token !== 'string' ||
        page.roster_token.length > 128 || !page.roster_token ||
        typeof page.next_cursor !== 'string' || page.next_cursor.length > 64) {
      throw new Error('Invalid live tool roster');
    }
    if (rosterToken !== undefined && rosterToken !== page.roster_token) throw new RosterChangedError('Agent membership changed');
    rosterToken = page.roster_token;
    for (const member of page.members) {
      const id = member?.instance_id;
      if (typeof id !== 'string' || !id || id.length > 64 || seen.has(id) ||
          (cursor && id <= cursor) || members.length >= LIVE_MEMBER_CAP ||
          typeof member.agent_id !== 'string' || member.agent_id.length > 64 ||
          typeof member.display_name !== 'string' || member.display_name.length > 256 ||
          !['ready', 'offline'].includes(member.availability)) throw new Error('Invalid live tool member');
      const snapshot = member.snapshot == null ? null : parseLiveSnapshot(member.snapshot);
      if ((member.snapshot != null && !snapshot) || (snapshot && snapshot.instance_id !== id) ||
          (member.availability === 'ready' && !snapshot)) throw new Error('Invalid member snapshot');
      seen.add(id);
      members.push({ instance_id: id, agent_id: member.agent_id, display_name: member.display_name,
        snapshot, availability: snapshot ? 'ready' : 'offline' });
    }
    const next = page.next_cursor;
    if (next && (!page.members.length || next !== page.members[page.members.length - 1].instance_id ||
        next <= cursor || members.length >= LIVE_MEMBER_CAP)) throw new Error('Invalid live tool cursor');
    cursor = next;
  } while (cursor);
  return members;
}
let requestSequence = 0;
// Deduplicate duplicate panes. Tokens fence old pages after disconnect, user
// switch, unmount or resync. Check before and after each bounded request.
export const fetchLiveScope = (key: string) => async (dispatch: any, getState: any) => {
  const current = (): LiveScope | undefined => getState()?.toolActivity?.scopes[key];
  const scope = current();
  if (!scope || !getState()?.toolActivity?.connected || scope.requestId) return;
  const requestId = String(++requestSequence);
  dispatch(liveSnapshotStarted({ key, requestId }));
  const stillCurrent = () => current()?.requestId === requestId && getState()?.toolActivity?.connected;
  const read: ReadJson = async (path, init) => {
    if (!stillCurrent()) throw new Error('Snapshot superseded');
    const data = await cookieJsonFetch(path, init);
    if (!stillCurrent()) throw new Error('Snapshot superseded');
    return data;
  };
  try {
    let members: LiveMember[];
    try {
      members = await readLiveScope(scope, read);
    } catch (error) {
      // Actual failed handshake: retry a changed roster ONCE, then manual retry.
      if (!(error instanceof RosterChangedError) || !stillCurrent()) throw error;
      members = await readLiveScope(scope, read);
    }
    dispatch(liveSnapshotLoaded({ key, requestId, members }));
  } catch (error) {
    dispatch(liveSnapshotFailed({ key, requestId,
      error: error instanceof Error ? error.message : 'Live tools unavailable' }));
  }
};
