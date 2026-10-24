import { useEffect, useRef, useState } from 'react';
import { Icon } from '@ui';
import NewConversationPage from '../chat/NewConversationPage';
import { HomeChainSearch } from './HomeChainSearch';
import { RecentIssuesTab } from './RecentIssuesTab';
import { ActionItemsTab } from './ActionItemsTab';
import { useListIssuesQuery } from '../../api/endpoints/issues';
import { useListCardsQuery } from '../../api/endpoints/cards';
import { getRoutePathname, getRouteSearch, buildRouteHash } from '../../utils/appLocation';
import type { LauncherIntent } from '../../store/workspaceLayoutSlice';

type HomeSection = 'issues' | 'actions';
function routeSelection(): HomeSection | null {
  const tab = new URLSearchParams(getRouteSearch()).get('tab');
  return tab === 'issues' || tab === 'actions' ? tab : null;
}
function scrollContainer(node: HTMLElement | null): HTMLElement | null {
  for (let parent = node?.parentElement; parent; parent = parent.parentElement) {
    if (/(auto|scroll)/.test(getComputedStyle(parent).overflowY) && parent.scrollHeight > parent.clientHeight + 1) return parent;
  }
  return document.scrollingElement as HTMLElement | null;
}

export interface HomePageProps {
  /**
   * Main new-chat pane mode (Jetski: the `_new` pane renders the new
   * conversation view). Launching a conversation or picking a task chain puts
   * that agent into THIS pane instead of navigating; global home sections
   * (issues, actions) are omitted.
   */
  pane?: {
    onOpenAgent: (agentInstanceId: string) => void;
    launchIntent?: LauncherIntent;
  };
}

export function HomePage({ pane }: HomePageProps = {}) {
  const [selected, setSelected] = useState<HomeSection | null>(routeSelection);
  // Keep the outgoing panel mounted during the return scroll. Removing it first
  // would clamp scrollTop and turn the requested smooth scroll into a jump.
  const [visible, setVisible] = useState<HomeSection | null>(selected);
  const rootRef = useRef<HTMLDivElement>(null);
  const buttonsRef = useRef<HTMLDivElement>(null);
  const firstRender = useRef(true);
  const issues = useListIssuesQuery({ limit: 100 }, { skip: Boolean(pane) });
  const actions = useListCardsQuery(undefined, { skip: Boolean(pane) });
  const sections = [
    { id: 'issues' as const, label: 'Recent issues', subtitle: 'Reported bugs and blockers', icon: 'alert' as const, count: issues.data?.items.length || 0, loading: issues.isLoading, error: issues.isError },
    { id: 'actions' as const, label: 'Pending actions', subtitle: 'Suggestions awaiting your decision', icon: 'spark' as const, count: (actions.data?.cards || []).filter(card => card.status === 'pending').length, loading: actions.isLoading, error: actions.isError },
  ];

  useEffect(() => {
    const syncLocation = () => { const next = routeSelection(); setSelected(next); if (next) setVisible(next); };
    window.addEventListener('hashchange', syncLocation);
    window.addEventListener('popstate', syncLocation);
    return () => { window.removeEventListener('hashchange', syncLocation); window.removeEventListener('popstate', syncLocation); };
  }, []);

  useEffect(() => {
    if (firstRender.current) { firstRender.current = false; if (!selected) return; }
    let frame = 0;
    let timeout = 0;
    let container: HTMLElement | null = null;
    const finish = () => { if (!selected) setVisible(null); };
    frame = requestAnimationFrame(() => {
      if (selected) {
        const buttons = buttonsRef.current;
        const target = scrollContainer(buttons);
        if (buttons && target) {
          const top = target.scrollTop + buttons.getBoundingClientRect().top - target.getBoundingClientRect().top - 16;
          target.scrollTo({ top: Math.max(0, top), behavior: 'smooth' });
        }
        return;
      }
      container = scrollContainer(rootRef.current);
      if (!container || container.scrollTop <= 1) { finish(); return; }
      container.addEventListener('scrollend', finish, { once: true });
      container.scrollTo({ top: 0, behavior: 'smooth' });
      timeout = window.setTimeout(finish, 1000);
    });
    return () => { cancelAnimationFrame(frame); window.clearTimeout(timeout); container?.removeEventListener('scrollend', finish); };
  }, [selected]);

  function toggle(section: HomeSection) {
    const next = selected === section ? null : section;
    setSelected(next);
    if (next) setVisible(next);
    const params = new URLSearchParams(getRouteSearch());
    if (next) params.set('tab', next); else params.delete('tab');
    window.history.replaceState(window.history.state, '', buildRouteHash(getRoutePathname(), params.toString()));
  }

  // Task chains: search plus pages of task chains across projects.
  const chainSearch = <HomeChainSearch onOpenAgent={pane?.onOpenAgent} />;

  if (pane) {
    return <div ref={rootRef} data-debug-id="home-page-pane" className="h-full w-full min-h-0 overflow-y-auto pb-8">
      <NewConversationPage embedded launchIntent={pane.launchIntent} onLaunched={pane.onOpenAgent} footer={<div className="w-full min-w-0">{chainSearch}</div>} />
    </div>;
  }

  return <div ref={rootRef} data-debug-id="home-page" className="w-full pb-8">
    <NewConversationPage embedded footer={<div className="relative w-full min-w-0 space-y-4">
      {chainSearch}
      <div ref={buttonsRef} data-debug-id="home-section-buttons" role="group" aria-label="Home activity" className="grid w-full scroll-mt-4 grid-cols-2 gap-2 sm:gap-3">
        {sections.map(section => <button key={section.id} type="button" data-debug-id={`home-tab-${section.id}`} aria-pressed={selected === section.id} aria-expanded={selected === section.id} aria-controls="home-activity-panel" onClick={() => toggle(section.id)} className={`relative flex min-h-28 min-w-0 flex-col items-start gap-2 rounded-2xl border px-3 py-4 text-left transition-colors sm:px-4 ${selected === section.id ? 'border-accent bg-accent/10' : 'border-subtle bg-surface hover:bg-neutral-soft'}`}>
          <div className="flex w-full items-center justify-between gap-2"><Icon name={section.icon} size={20} className={selected === section.id ? 'text-accent' : 'text-muted'} /><span data-debug-id={`home-count-${section.id}`} aria-label={section.loading ? 'Loading count' : section.error ? 'Count unavailable' : `${section.count} ${section.label.toLowerCase()}`} className={`inline-flex h-6 min-w-6 items-center justify-center rounded-full px-1.5 text-xs font-semibold ${selected === section.id ? 'bg-accent text-accent-fg' : 'bg-neutral-soft text-primary'}`}>{section.loading ? '…' : section.error ? '—' : section.count}</span></div>
          <span className="text-sm font-semibold text-primary sm:text-base">{section.label}</span>
          <span className="text-[11px] text-muted sm:text-xs">{section.subtitle}</span>
        </button>)}
      </div>
      {visible ? <section id="home-activity-panel" data-debug-id={`home-panel-${visible}`} aria-label={sections.find(section => section.id === visible)?.label} className="absolute top-full mt-5 h-[max(20rem,calc(var(--app-viewport-height)-6rem))] min-h-0 w-full overflow-hidden">
        {visible === 'issues' ? <RecentIssuesTab /> : <ActionItemsTab />}
      </section> : null}
    </div>} />
    {visible ? <div aria-hidden="true" className="h-[max(20rem,calc(var(--app-viewport-height)-6rem))]" /> : null}
  </div>;
}
export default HomePage;
