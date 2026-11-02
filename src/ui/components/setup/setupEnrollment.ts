import { cancelBridgeEnrollment } from '../../api/endpoints/bridges';
import { postApproveBridge } from '../../api/endpoints/vaultDevices';

/** Cancel the Hub attempt before stopping local setup, so a retry can reuse its ID. */
export async function cancelSetupEnrollment(args: {
  bridgeId: string;
  pairLookup?: string;
  wait: AbortController | null;
  cancelLocal: () => Promise<{ ok: boolean; error?: string }>;
}): Promise<boolean> {
  if (args.bridgeId) {
    const result = await cancelBridgeEnrollment(args.bridgeId);
    if (!result.rolledBack) return false; // commit won: keep the completed enrollment
    args.wait?.abort(new Error('Bridge enrollment cancelled.'));
  } else if (args.pairLookup) {
    // An expired code must not prevent stopping an unapproved local setup.
    await postApproveBridge({ pair_lookup: args.pairLookup, approve: false }).catch(() => {});
  }
  const result = await args.cancelLocal();
  if (!result.ok) throw new Error(result.error || 'Unable to stop local setup.');
  return true;
}
