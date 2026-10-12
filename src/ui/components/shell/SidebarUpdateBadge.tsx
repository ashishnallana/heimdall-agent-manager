import { useEffect, useState } from 'react';
import Icon from '../Icon';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { pendingBridgeUpdates, type PendingBridgeUpdate } from '../settings/bridgeUpdate';

/** How long the badge shows the version with a glowing border before settling to an icon. */
const INTRO_MS = 4000;

/**
 * Sidebar badge advertising a Bridge update. Checked ONCE on load: the first
 * bridges response is captured and later refreshes are ignored, so the badge
 * never pops in mid-session. Shows only when a connected, online Bridge can
 * install a newer release; on load it shows "Update vX" with a glowing pulse,
 * then collapses to just the update icon.
 */
export default function SidebarUpdateBadge({ onOpen }: { onOpen: (update: PendingBridgeUpdate) => void }) {
  const bridgesQuery = useListBridgesQuery(undefined);
  const [update, setUpdate] = useState<PendingBridgeUpdate | null | undefined>(undefined);
  const [intro, setIntro] = useState(true);

  useEffect(() => {
    if (update !== undefined || !bridgesQuery.isSuccess) return;
    setUpdate(pendingBridgeUpdates(bridgesQuery.data?.bridges)[0] ?? null);
  }, [bridgesQuery.isSuccess, bridgesQuery.data, update]);

  useEffect(() => {
    if (!update) return;
    const timer = window.setTimeout(() => setIntro(false), INTRO_MS);
    return () => window.clearTimeout(timer);
  }, [update]);

  if (!update) return null;
  const version = update.latestVersion ? `v${update.latestVersion}` : 'latest';
  const label = `Bridge update available: ${version} for ${update.label}`;
  // The label stays mounted and collapses (max-width + opacity) so the pill
  // shrinks smoothly into the icon instead of snapping; the glow fades out via
  // `update-badge-settle` rather than stopping abruptly.
  return (
    <button
      type="button"
      data-debug-id="shell-update-badge"
      data-intro={intro ? 'true' : 'false'}
      onClick={() => onOpen(update)}
      aria-label={label}
      title={label}
      className={`inline-flex h-7 shrink-0 items-center rounded-full border border-accent/60 px-[7px] text-accent transition-colors duration-200 hover:bg-accent/10 focus-visible:outline-none focus-visible:shadow-focus ${intro ? 'update-badge-glow' : 'update-badge-settle'}`}
    >
      <Icon name="download" size={12} />
      <span aria-hidden="true" className={`overflow-hidden whitespace-nowrap text-[10.5px] font-semibold transition-[max-width,opacity,margin] duration-500 ease-in-out ${intro ? 'ml-1 max-w-[7rem] opacity-100' : 'ml-0 max-w-0 opacity-0'}`}>Update {version}</span>
    </button>
  );
}
