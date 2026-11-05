import NewConversationPage from '../chat/NewConversationPage';
import type { LauncherIntent } from '../../store/workspaceLayoutSlice';

export interface HomePageProps {
  /**
   * Main new-chat pane mode (Jetski: the `_new` pane renders the new
   * conversation view). Launching a conversation puts
   * that agent into THIS pane instead of navigating.
   */
  pane?: {
    onOpenAgent: (agentInstanceId: string) => void;
    launchIntent?: LauncherIntent;
  };
}

/** Below md the page is a flex column filling the height, so the composer can dock near the bottom. */
const FILL_MOBILE = 'max-md:flex max-md:flex-col max-md:pb-0';

export function HomePage({ pane }: HomePageProps = {}) {
  if (pane) {
    return <div data-debug-id="home-page-pane" className={`h-full w-full min-h-0 overflow-y-auto pb-8 ${FILL_MOBILE}`}>
      <NewConversationPage embedded launchIntent={pane.launchIntent} onLaunched={pane.onOpenAgent} />
    </div>;
  }

  return <div data-debug-id="home-page" className={`w-full pb-8 max-md:flex-1 ${FILL_MOBILE}`}>
    <NewConversationPage embedded />
  </div>;
}
export default HomePage;
