import { useEffect, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { Icon } from '@ui';
import type { AttentionTaskItem } from '../../api/endpoints/attention';
import { useFetchTaskFacetQuery } from '../../api/endpoints/tasks';
import { useArtifactPreview } from '../ArtifactAttachmentPreview';
import { taskChangedFiles } from '../tasks/taskV2Types';
import { DecryptedMarkdown, VaultText } from '../vault';
import { formatAge } from './attentionModel';
import { artifactIdsFrom, artifactLinksFrom, handoffDecisions, isBlockedItem, needLabel } from './actionTrayModel';

/** Same-origin cookie auth, like the chat pane's attachments (the store's legacy session is not the v1 hub). */
const ARTIFACT_SESSION = { daemonUrl: '', clientToken: '' };

/** Files listed on a review card before "+N more". */
const MAX_FILES = 6;

/**
 * One task waiting on the user in the chat pane's action tray (REQ-AT-2/4).
 * Top to bottom: title; agent · age; what is needed; the ask (dominant, scrolls
 * inside the card); then `footer` (the action row or an inline picker).
 *
 * A blocked card's ask is the agent's question (the card excerpt). A review
 * card shows the worker's result, fetched lazily once `active` (the page is
 * showing): handoff summary + decisions, commit/files, artifact
 * thumbnails (tap for full size). Until it loads, or when the attempt recorded
 * none of it, the excerpt stands in.
 */
export function ActionTaskCard({ item, mobile, active, now, footer }: { item: AttentionTaskItem; mobile: boolean; active: boolean; now: number; footer: ReactNode }) {
  const blocked = isBlockedItem(item);
  const agent = item.details.assignee_name || item.context.agent_name || 'Agent';
  const age = formatAge(item.attention_since, now);
  return (
    <article
      data-debug-id={`action-tray-card-${blocked ? 'blocked' : 'review'}`}
      aria-label={blocked ? 'Task blocked on you' : 'Task waiting on your review'}
      className="flex h-full min-h-0 min-w-0 flex-col gap-3"
    >
      <header className="min-w-0 space-y-1">
        <h3 data-debug-id="action-tray-card-title" className={`font-semibold leading-snug text-primary ${mobile ? 'text-[16px]' : 'text-[17px]'}`}>
          <VaultText value={item.title} fallback="Untitled task" />
        </h3>
        <div className="flex min-w-0 items-center gap-2 text-[13px] text-muted">
          <span aria-hidden="true" className="grid h-5 w-5 shrink-0 place-items-center rounded-full bg-neutral-soft text-muted">
            <Icon name="bot" size={12} />
          </span>
          <span data-debug-id="action-tray-card-agent" className="min-w-0 truncate">
            <span className="font-medium text-primary">{agent}</span>
            {age ? ` · ${age === 'just now' ? age : `${age} ago`}` : ''}
          </span>
        </div>
        <p data-debug-id="action-tray-card-need" className={`pt-1 text-[12px] font-semibold uppercase tracking-wide ${blocked ? 'text-warning' : 'text-info'}`}>
          {needLabel(item)}
        </p>
      </header>
      {/* touch-pan-y: its own vertical scroller; horizontal gestures page the tray. */}
      <div data-debug-id="action-tray-card-ask" className="min-h-0 flex-1 touch-pan-y overflow-y-auto overscroll-contain pr-1">
        {blocked ? <BlockedAsk item={item} mobile={mobile} /> : <ReviewResult item={item} mobile={mobile} active={active} />}
      </div>
      <div className="shrink-0">{footer}</div>
    </article>
  );
}

function askClass(mobile: boolean): string {
  return `text-primary ${mobile ? 'text-[18px] leading-[1.45]' : 'text-[19px] leading-[1.5]'}`;
}

function BlockedAsk({ item, mobile }: { item: AttentionTaskItem; mobile: boolean }) {
  const excerpt = item.details.excerpt;
  if (item.details.badge === 'agent_not_running') return <p role="alert" className="text-[15px] text-danger">{item.rationale}</p>;
  if (!excerpt?.body) {
    return (
      <p data-debug-id="action-tray-card-no-ask" className="text-[15px] text-muted">
        The agent is waiting on you but did not say what it needs. Open the task to see its latest comments.
      </p>
    );
  }
  return <DecryptedMarkdown source={excerpt.body} compact copyAll={false} className={askClass(mobile)} data-debug-id="action-tray-card-question" />;
}

/** A facet body, or null while loading / when the attempt has none (the hub answers 404). */
function useFacet(item: AttentionTaskItem, kind: string, active: boolean): { facet: any; loading: boolean } {
  const { chain_id: chainId, task_id: taskId } = item.action_refs;
  const attemptNo = item.details.attempt_no || 1;
  const q = useFetchTaskFacetQuery({ chainId, taskId, attemptNo, kind }, { skip: !active || !chainId || !taskId });
  return { facet: q.isError ? null : q.data?.facet ?? null, loading: q.isLoading || (q.isUninitialized && active) };
}

function ReviewResult({ item, mobile, active }: { item: AttentionTaskItem; mobile: boolean; active: boolean }) {
  // Lazy: nothing is fetched until the card is the page being shown; once
  // fetched, RTK Query keeps it while the user pages back and forth.
  const [seen, setSeen] = useState(active);
  useEffect(() => { if (active) setSeen(true); }, [active]);
  const handoff = useFacet(item, 'handoff', seen);
  const vcs = useFacet(item, 'vcs', seen);
  const artifacts = useFacet(item, 'artifacts', seen);
  const [shot, setShot] = useState<string | null>(null);

  const summary = typeof handoff.facet?.summary === 'string' ? handoff.facet.summary : '';
  const decisions = handoffDecisions(handoff.facet);
  const files = taskChangedFiles(vcs.facet);
  const head = String(vcs.facet?.head || '').slice(0, 8);
  const branch = String(vcs.facet?.branch || '');
  const shots = artifactIdsFrom(artifacts.facet, summary);
  const links = artifactLinksFrom(artifacts.facet);
  const textSize = mobile ? 'text-[16px] leading-[1.5]' : 'text-[17px] leading-[1.55]';
  const excerpt = item.details.excerpt;
  const nothing = !summary && !decisions.length && !files.length && !head && !shots.length && !links.length;
  const loading = handoff.loading || vcs.loading || artifacts.loading;

  if (nothing) {
    if (excerpt?.body) return <DecryptedMarkdown source={excerpt.body} compact copyAll={false} className={textSize} data-debug-id="action-tray-review-excerpt" />;
    return <p data-debug-id="action-tray-review-empty" className="text-[15px] text-muted">{loading ? 'Loading the result…' : 'The worker left no summary. Open the task to review it.'}</p>;
  }

  return (
    <div data-debug-id="action-tray-review-result" className="space-y-4">
      {summary ? <DecryptedMarkdown source={summary} compact copyAll={false} className={`${textSize} text-primary`} data-debug-id="action-tray-review-summary" /> : null}
      {decisions.length ? (
        <section aria-label="Decisions" data-debug-id="action-tray-review-decisions">
          <h4 className="mb-1.5 text-[13px] font-semibold text-muted">Decisions</h4>
          <ul className="list-disc space-y-1 pl-5 text-[14px] text-primary">
            {decisions.map((d, i) => <li key={i}><VaultText value={d} /></li>)}
          </ul>
        </section>
      ) : null}
      {shots.length ? (
        <section aria-label="Screenshots" data-debug-id="action-tray-review-shots">
          <h4 className="mb-1.5 text-[13px] font-semibold text-muted">Screenshots</h4>
          <div className="flex gap-2 overflow-x-auto overscroll-x-contain pb-1">
            {shots.map((id, i) => <ShotThumb key={id} artifactId={id} index={i} onOpen={() => setShot(id)} />)}
          </div>
        </section>
      ) : null}
      {links.length ? (
        <ul data-debug-id="action-tray-review-links" className="space-y-1 text-[13px]">
          {links.map((l) => (
            <li key={l.href} className="min-w-0 truncate">
              <a href={l.href} target="_blank" rel="noreferrer" className="text-accent hover:underline">{l.label}</a>
            </li>
          ))}
        </ul>
      ) : null}
      {head || files.length ? (
        <section aria-label="Changes" data-debug-id="action-tray-review-changes">
          <h4 className="mb-1.5 text-[13px] font-semibold text-muted">Changes</h4>
          {head ? (
            <p className="mb-1.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-[13px] text-muted">
              <Icon name="git-branch" size={13} className="shrink-0" />
              <code className="font-mono text-primary">{head}</code>
              {branch ? (<><span>on</span><code className="min-w-0 break-all font-mono">{branch}</code></>) : null}
            </p>
          ) : null}
          {files.length ? (
            <ul className="space-y-1">
              {files.slice(0, MAX_FILES).map((f) => (
                <li key={f.path} className="text-[13px]">
                  <code className="break-all font-mono text-primary">{f.path}</code>
                  {f.add !== undefined || f.del !== undefined ? <span className="text-muted"> · +{f.add ?? 0} −{f.del ?? 0}</span> : null}
                </li>
              ))}
              {files.length > MAX_FILES ? <li className="text-[13px] text-muted">+{files.length - MAX_FILES} more</li> : null}
            </ul>
          ) : null}
        </section>
      ) : null}
      {shot ? <ShotLightbox artifactId={shot} onClose={() => setShot(null)} /> : null}
    </div>
  );
}

function ShotThumb({ artifactId, index, onOpen }: { artifactId: string; index: number; onOpen: () => void }) {
  const preview = useArtifactPreview({ artifactId, session: ARTIFACT_SESSION });
  const name = String(preview.meta?.name || artifactId);
  // Not an image (a log, a JSON file): no thumbnail, the task page lists it.
  if (preview.meta && !preview.isImage) return null;
  return (
    <button
      type="button"
      data-debug-id={`action-tray-shot-${index}`}
      aria-label={`Enlarge screenshot ${index + 1}`}
      onClick={onOpen}
      disabled={!preview.contentUrl}
      className="group shrink-0 overflow-hidden rounded-[var(--radius-md)] border border-subtle bg-canvas text-left"
    >
      {preview.contentUrl ? (
        <img src={preview.contentUrl} alt={name} className="h-32 w-auto max-w-[260px] object-cover object-top group-hover:opacity-90 sm:h-40" />
      ) : (
        <span className="grid h-32 w-40 place-items-center text-[12px] text-faint sm:h-40">{preview.error ? 'Unavailable' : 'Loading…'}</span>
      )}
      <span className="block max-w-[220px] truncate px-2 py-1 text-[12px] text-muted"><VaultText value={name} fallback={artifactId} /></span>
    </button>
  );
}

/** Full-size screenshot over everything; the backdrop, the close button or Esc dismiss it. */
function ShotLightbox({ artifactId, onClose }: { artifactId: string; onClose: () => void }) {
  const preview = useArtifactPreview({ artifactId, session: ARTIFACT_SESSION });
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  }, [onClose]);
  const name = String(preview.meta?.name || artifactId);
  // Portaled: the tray's frost card (backdrop-filter) would otherwise be the
  // containing block of this fixed overlay.
  return createPortal(
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Screenshot"
      data-debug-id="action-tray-lightbox"
      onClick={onClose}
      className="fixed inset-0 z-modal flex flex-col items-center justify-center gap-2 bg-black/85 p-4"
    >
      <button
        type="button"
        aria-label="Close"
        data-debug-id="action-tray-lightbox-close"
        onClick={onClose}
        className="absolute right-3 top-[max(env(safe-area-inset-top),0.75rem)] grid h-11 w-11 place-items-center rounded-full bg-white/10 text-white"
      >
        <Icon name="close" size={20} />
      </button>
      {preview.contentUrl ? (
        <img src={preview.contentUrl} alt={name} onClick={(e) => e.stopPropagation()} className="max-h-[85svh] max-w-full rounded-[var(--radius-md)] object-contain" />
      ) : (
        <p className="text-[13px] text-white/80">Loading…</p>
      )}
      <p className="max-w-full truncate text-[13px] text-white/80"><VaultText value={name} fallback={artifactId} /></p>
    </div>,
    document.body,
  );
}
