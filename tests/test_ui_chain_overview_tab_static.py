#!/usr/bin/env python3
"""Static validation and regression tests for Chain Overview Tab in Right Sidebar.

Requirements covered:
- REQ-UI-CHAIN-OVERVIEW-TAB:
  * ChainOverviewPanel.tsx exports, sub-components, and imports.
  * RightSidebarTab union and persistence logic in src/ui/utils/clientPersistence.ts.
  * ConversationThreadPage.tsx tab toggle, 'layers' icon, bidirectional ?panel=chain URL synchronization,
    and lazy panel mounting.
  * Fleet Terminals strictly lazy mounting logic (terminals mount only when expanded, unmount when collapsed).
  * 6 core sections: Chain Agents, Chain Artifacts, VCS Changes, Ongoing Tasks, Attention Needed, Fleet Terminals.
  * Interactive review gate with checklist, vote comment textarea, and LGTM/NGTM voting.
  * Attachment metadata propagation (REQ-UI-COMPOSER-ATTACHMENT-METADATA).
- REQ-CITC-DEPLOY-VERIFY:
  * Validates code contracts ahead of de-Nixified bundle packaging and CitC depot deployment.
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PANEL_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ChainOverviewPanel.tsx"
CONVERSATION_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"
PERSISTENCE_FILE = ROOT / "src" / "ui" / "utils" / "clientPersistence.ts"
ICON_FILE = ROOT / "src" / "ui" / "components" / "ui" / "primitives" / "Icon.tsx"
DAEMON_API_FILE = ROOT / "src" / "ui" / "api" / "daemonApi.ts"
ARTIFACTS_API_FILE = ROOT / "src" / "ui" / "api" / "endpoints" / "artifacts.ts"
APP_SHELL_FILE = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def test_client_persistence() -> None:
    print("[*] Testing RightSidebarTab persistence in src/ui/utils/clientPersistence.ts...")
    require(PERSISTENCE_FILE.exists(), "clientPersistence.ts must exist")
    src = PERSISTENCE_FILE.read_text(encoding="utf-8")

    # RightSidebarTab union type must include 'chain'
    require(
        "'chain'" in src and "RIGHT_SIDEBAR_TABS" in src and "export type RightSidebarTab" in src,
        "RightSidebarTab union type must include 'chain'",
    )

    # readRightSidebarTab handles 'chain'
    require(
        "isRightSidebarTab" in src and "readRightSidebarTab" in src,
        "readRightSidebarTab must support 'chain' tab",
    )

    # writeRightSidebarTab handles 'chain'
    require(
        "writeRightSidebarTab" in src,
        "writeRightSidebarTab must persist 'chain' tab",
    )

    # Collapsed state persistence functions and key
    require(
        "export function readChainOverviewCollapsedState" in src,
        "clientPersistence.ts must export readChainOverviewCollapsedState",
    )
    require(
        "export function writeChainOverviewCollapsedState" in src,
        "clientPersistence.ts must export writeChainOverviewCollapsedState",
    )
    require(
        "'heimdall:chainOverview:collapsed:'" in src,
        "clientPersistence.ts must use 'heimdall:chainOverview:collapsed:' key prefix",
    )
    print("  [+] RightSidebarTab and ChainOverview collapsed persistence verified.")


def test_chain_overview_panel_exports_and_imports() -> None:
    print("[*] Testing ChainOverviewPanel.tsx exports, props, and imports...")
    require(PANEL_FILE.exists(), "ChainOverviewPanel.tsx must exist")
    src = PANEL_FILE.read_text(encoding="utf-8")

    # Component export
    require(
        "export default function ChainOverviewPanel" in src,
        "ChainOverviewPanel must default export the functional component",
    )

    # Props interface
    require(
        "export interface ChainOverviewPanelProps" in src,
        "ChainOverviewPanelProps interface must be exported",
    )
    for prop in [
        "chainId: string;",
        "projectId: string;",
        "bridgeId?: string;",
        "agentInstanceId?: string;",
        "onClose?: () => void;",
        "onSelectTask?: (taskId: string) => void;",
        "onOpenFileDiff?: (filePath: string) => void;",
        "onOpenVcsFiles?: () => void;",
        "isMobile?: boolean;",
    ]:
        require(prop in src, f"ChainOverviewPanelProps must include '{prop}'")

    # API Hooks and Component Imports
    require("useFetchChainTaskDetailQuery" in src, "Must import useFetchChainTaskDetailQuery")
    require("useFetchTaskChainDetailQuery" in src, "Must import useFetchTaskChainDetailQuery")
    require("useVoteTaskMutation" in src, "Must import useVoteTaskMutation")
    require("useGetProjectVcsStatusQuery" in src, "Must import useGetProjectVcsStatusQuery")
    require("useListVcsFilesQuery" in src, "Must import useListVcsFilesQuery")
    require("useListArtifactsQuery" in src, "Must import useListArtifactsQuery")
    require("useStartInstanceMutation" in src, "Must import useStartInstanceMutation")
    require("ArtifactViewer" in src, "Must import ArtifactViewer")
    require("AgentPaneComposerPanel" in src, "Must import AgentPaneComposerPanel")
    require("MonacoDiffViewer" not in src, "Must not import MonacoDiffViewer")
    require("buildRouteHash" in src, "Must import buildRouteHash")
    require("writeRightSidebarOpen" in src, "Must import writeRightSidebarOpen")
    require("writeRightSidebarTab" in src, "Must import writeRightSidebarTab")
    require("readChainOverviewCollapsedState" in src, "Must import readChainOverviewCollapsedState")
    require("writeChainOverviewCollapsedState" in src, "Must import writeChainOverviewCollapsedState")

    # Redundant inner header removed
    require('data-debug-id="chain-overview-close-btn"' not in src, "Redundant inner header close button must be removed")

    print("  [+] ChainOverviewPanel exports, props, and imports verified.")


def test_chain_overview_panel_sections() -> None:
    print("[*] Testing ChainOverviewPanel.tsx 6 core sections...")
    src = PANEL_FILE.read_text(encoding="utf-8")

    # Section 1: Chain Agents Roster
    require("Chain Agents" in src, "Must include Chain Agents section header")
    require('data-debug-id="chain-overview-section-agents"' in src, "Must have data-debug-id for agents section")
    require("data-debug-id={`chain-overview-agent-row-${instId}`}" in src, "Agent rows must have data-debug-id")
    require("handleStartAgent" in src, "Must have start agent handler")
    require("data-debug-id={`chain-overview-start-agent-${instId}`}" in src, "Start agent button must have data-debug-id")
    require("handleNavigateToAgent" in src, "Must have agent navigation handler")
    require("writeRightSidebarOpen(true, agentInstanceId)" in src, "handleNavigateToAgent must persist sidebar open on desktop")
    require("writeRightSidebarTab('chain', agentInstanceId)" in src, "handleNavigateToAgent must persist 'chain' tab on desktop")
    require("buildRouteHash(`/conversations/${encodeURIComponent(agentInstanceId)}`, '?panel=chain')" in src,
            "handleNavigateToAgent must preserve '?panel=chain' on desktop")

    # Section 2: Chain Artifacts
    require("Chain Artifacts" in src, "Must include Chain Artifacts section header")
    require('data-debug-id="chain-overview-section-artifacts"' in src, "Must have data-debug-id for artifacts section")
    require("data-debug-id={`chain-overview-artifact-${artId}`}" in src, "Artifact rows must have data-debug-id")
    require("useListArtifactsQuery" in src, "Must use useListArtifactsQuery")
    require("<ArtifactViewer" in src, "Must render ArtifactViewer modal on artifact selection")

    # Section 3: VCS Changes
    require("VCS Changes" in src, "Must include VCS Changes section header")
    require('data-debug-id="chain-overview-section-vcs"' in src, "Must have data-debug-id for VCS section")
    require("projectVcsEnabled ? (" in src, "VCS section must render only when the Project/VCS experiment is enabled")
    require("skip: !projectVcsEnabled || !projectId" in src,
            "Both VCS polling queries must skip when the Project/VCS experiment is disabled")
    require("vcsModifiedCount" in src, "Must calculate vcsModifiedCount")
    require("vcsStagedCount" in src, "Must calculate vcsStagedCount")
    require("vcsUntrackedCount" in src, "Must calculate vcsUntrackedCount")
    require("onOpenVcsFiles" in src, "Must support jumping to project files tab")
    require("onOpenFileDiff(file.path)" in src, "Must route clicked file directly via onOpenFileDiff(file.path)")
    require("diffModalFile" not in src, "Must remove diffModalFile state")
    require("<MonacoDiffViewer" not in src, "Must not render MonacoDiffViewer modal for file diffs")
    require('data-debug-id="chain-overview-diff-modal"' not in src, "Must remove inline diff modal")
    require("Quick preview diff" not in src, "Must remove quick preview diff button")

    # Section 4: Ongoing Tasks
    require("Ongoing Tasks" in src, "Must include Ongoing Tasks section header")
    require('data-debug-id="chain-overview-section-ongoing-tasks"' in src, "Must have data-debug-id for ongoing tasks")
    require("data-debug-id={`chain-overview-ongoing-task-${taskId}`}" in src, "Task rows must have data-debug-id")
    require("priorityTone" in src, "Must format priority chip tones")
    require("onSelectTask" in src, "Must support focusing task in Tasks tab")

    # Section 5: Attention Needed
    require("Attention Needed" in src, "Must include Attention Needed section header")
    require('data-debug-id="chain-overview-section-attention"' in src, "Must have data-debug-id for attention section")
    require("data-debug-id={`chain-overview-attention-task-${taskId}`}" in src, "Attention task row must have data-debug-id")
    require("isAttentionNeeded" in src, "Must define isAttentionNeeded helper")
    require("attentionReason" in src, "Must define attentionReason helper")
    require("AttentionTaskReviewCard" in src, "Must define AttentionTaskReviewCard component")
    require("data-debug-id={`chain-overview-attention-review-${taskId}`}" in src, "Review card must have data-debug-id")
    require("data-debug-id={`chain-overview-vote-lgtm-${taskId}`}" in src, "LGTM vote button must have data-debug-id")
    require("data-debug-id={`chain-overview-vote-ngtm-${taskId}`}" in src, "NGTM vote button must have data-debug-id")
    require("checklistItems" in src, "Must parse acceptance criteria checklist from task description")

    # Section 6: Fleet Terminals
    require("Fleet Terminals" in src, "Must include Fleet Terminals section header")
    require('data-debug-id="chain-overview-section-fleet-terminals"' in src, "Must have data-debug-id for fleet terminals")
    require("data-debug-id={`chain-overview-terminal-accordion-${instId}`}" in src, "Terminal accordion must have data-debug-id")
    require("openTerminalIds" in src, "Must track open terminals state")
    require("toggleTerminal" in src, "Must provide toggleTerminal callback")
    require("grid grid-cols-1 sm:grid-cols-2 gap-3 items-start" in src, "Fleet Terminals container must use 2-column grid layout with items-start")

    # 2x2 Grid and Coordinator Styling in Section 1
    require("grid grid-cols-1 sm:grid-cols-2 gap-2.5" in src, "Chain Agents container must use 2x2 responsive grid")
    require(
        "border-accent/50 bg-gradient-to-br from-accent/10 to-accent/5 ring-1 ring-accent/20" in src,
        "Chain Agents must apply special coordinator styling",
    )

    # Collapsible interactive subheadings for all 6 sections
    for sec_key in ['agents', 'attention', 'ongoingTasks', 'artifacts', 'vcs', 'terminals']:
        require(f"toggleSection('{sec_key}')" in src, f"Section '{sec_key}' must be collapsible")
        require(f'data-debug-id="chain-overview-section-toggle-{sec_key}"' in src, f"Toggle button for '{sec_key}' must exist")

    print("  [+] ChainOverviewPanel 6 core sections and collapsible subheadings verified.")


def test_fleet_terminals_lazy_mounting() -> None:
    print("[*] Testing Fleet Terminals strict lazy mounting and 2-column grid...")
    src = PANEL_FILE.read_text(encoding="utf-8")

    # 2-column responsive grid layout
    require(
        "grid grid-cols-1 sm:grid-cols-2 gap-3" in src or "grid-cols-1 sm:grid-cols-2" in src,
        "Fleet Terminals container must use responsive 2-column grid",
    )

    # Check lazy mounting condition in accordion
    require("{isOpen && (" in src, "Accordion terminal content must be conditionally mounted with {isOpen && (")
    require(
        "data-debug-id={`chain-overview-stopped-terminal-${instId}`}" in src,
        "Stopped terminal must mount with data-debug-id",
    )
    require(
        "<AgentPaneComposerPanel" in src,
        "Active terminal must mount AgentPaneComposerPanel component",
    )

    # Check modal maximize rendering
    require("maximizedTerminalInstanceId" in src, "Must track maximized terminal instance id")
    require("{maximizedTerminalInstanceId ? (" in src or "{maximizedTerminalInstanceId && (" in src,
            "Maximized terminal modal must be conditionally rendered")

    print("  [+] Fleet Terminals lazy mounting and 2-column grid verified.")


def test_conversation_thread_page_tab_integration() -> None:
    print("[*] Testing ConversationThreadPage.tsx Chain tab and URL synchronization...")
    require(CONVERSATION_FILE.exists(), "ConversationThreadPage.tsx must exist")
    src = CONVERSATION_FILE.read_text(encoding="utf-8")

    # Import of ChainOverviewPanel
    require(
        "import ChainOverviewPanel from './ChainOverviewPanel';" in src,
        "ConversationThreadPage must import ChainOverviewPanel",
    )

    # Tab toggle button
    require(
        'data-debug-id="conversation-right-panel-tab-chain"' in src,
        "Right sidebar tabs must include chain tab with data-debug-id='conversation-right-panel-tab-chain'",
    )
    require(
        'aria-label="Chain Overview"' in src,
        "Chain tab button must have aria-label='Chain Overview'",
    )
    require(
        '<Icon name="layers" size={16} />' in src or '<Icon name="layers" size={18} />' in src or '<Icon name="layers" size={20} />' in src,
        "Chain tab button must render 'layers' icon of size 16, 18, or 20",
    )
    require(
        "selectRightPanelTab('chain')" in src,
        "Chain tab button must call selectRightPanelTab('chain')",
    )
    require(
        "hasChain" in src,
        "Chain tab button must be conditionally rendered when hasChain is true",
    )

    # URL query parameter ?panel=chain initialization & sync
    require("isRightSidebarTab(norm)" in src or "if (norm === 'chain') return 'chain';" in src, "Initial state parser must recognize ?panel=chain")
    require("syncUrlPanel" in src, "ConversationThreadPage must have syncUrlPanel function")
    require("params.set('panel', tab);" in src, "syncUrlPanel must set ?panel=<tab>")
    require("params.delete('panel');" in src, "syncUrlPanel must clean up ?panel parameter on close")

    # Lazy mounting of ChainOverviewPanel
    require(
        "active === 'chain' && hasChain ? (" in src,
        "ChainOverviewPanel must be conditionally mounted only when active === 'chain' && hasChain",
    )
    require(
        "<ChainOverviewPanel" in src,
        "ConversationThreadPage must render <ChainOverviewPanel",
    )
    require(
        "agentInstanceId={agentInstanceId}" in src,
        "ConversationThreadPage must pass agentInstanceId to ChainOverviewPanel",
    )

    # Overflow bounds to prevent void scroll
    require(
        'max-w-full overflow-hidden bg-canvas' in src,
        "ConversationThreadPage root container must use overflow-hidden to prevent void scroll",
    )

    # Small-width composer toolbar responsiveness
    require(
        "flex flex-wrap items-center gap-1.5 min-w-0" in src,
        "Composer bottom toolbar must use flex-wrap with min-w-0",
    )
    require(
        "max-w-[120px] truncate font-medium" in src,
        "AgentPickerTrigger must truncate at max-w-[120px]",
    )
    require(
        'data-debug-id="conversation-composer-send-btn"' in src and "shrink-0" in src,
        "Composer send button must retain shrink-0",
    )

    print("  [+] ConversationThreadPage tab integration and composer responsiveness verified.")


def test_app_shell_container() -> None:
    print("[*] Testing AppShell.tsx container layout bounds...")
    require(APP_SHELL_FILE.exists(), "AppShell.tsx must exist")
    src = APP_SHELL_FILE.read_text(encoding="utf-8")
    require(
        'className="flex min-w-0 flex-1 flex-col h-full min-h-0 overflow-hidden"' in src,
        "AppShell main container must include h-full min-h-0 overflow-hidden",
    )
    print("  [+] AppShell container layout bounds verified.")


def test_icon_definitions() -> None:
    print("[*] Testing Icon.tsx 'layers' icon definition...")
    require(ICON_FILE.exists(), "Icon.tsx must exist")
    src = ICON_FILE.read_text(encoding="utf-8")

    require("layers:" in src, "Icon.tsx must define 'layers' icon svg path")
    require("polygon points=" in src, "Layers icon must contain polygon svg elements")
    print("  [+] Icon.tsx 'layers' icon definition verified.")


def test_attachment_metadata_contract() -> None:
    print("[*] Testing Attachment Metadata contract (REQ-UI-COMPOSER-ATTACHMENT-METADATA)...")
    require(DAEMON_API_FILE.exists(), "daemonApi.ts must exist")
    daemon_src = DAEMON_API_FILE.read_text(encoding="utf-8")
    require("agent_id: params.agentId" in daemon_src or "agent_id:" in daemon_src,
            "daemonApi.ts createArtifact must support agent_id")
    require("agent_instance_id: params.agentInstanceId" in daemon_src or "agent_instance_id:" in daemon_src,
            "daemonApi.ts createArtifact must support agent_instance_id")
    require("chain_id: params.chainId" in daemon_src or "chain_id:" in daemon_src,
            "daemonApi.ts createArtifact must support chain_id")
    require("project_id: params.projectId" in daemon_src or "project_id:" in daemon_src,
            "daemonApi.ts createArtifact must support project_id")

    require(ARTIFACTS_API_FILE.exists(), "artifacts.ts must exist")
    artifacts_src = ARTIFACTS_API_FILE.read_text(encoding="utf-8")
    require("agent_id?:" in artifacts_src or "agentId?:" in artifacts_src,
            "artifacts.ts CreateArtifactRequest must declare agent_id")
    require("agent_instance_id?:" in artifacts_src or "agentInstanceId?:" in artifacts_src,
            "artifacts.ts CreateArtifactRequest must declare agent_instance_id")
    require("chain_id?:" in artifacts_src or "chainId?:" in artifacts_src,
            "artifacts.ts CreateArtifactRequest must declare chain_id")
    require("project_id?:" in artifacts_src or "projectId?:" in artifacts_src,
            "artifacts.ts CreateArtifactRequest must declare project_id")

    conv_src = CONVERSATION_FILE.read_text(encoding="utf-8")
    require("uploadAttachment" in conv_src, "ConversationThreadPage must implement uploadAttachment")
    require("chainId" in conv_src and "agentInstanceId" in conv_src,
            "ConversationThreadPage uploadAttachment must forward context metadata")

    print("  [+] Attachment metadata contract verified.")


def main() -> None:
    print("=== Running Static Tests for Chain Overview Tab ===")
    test_client_persistence()
    test_chain_overview_panel_exports_and_imports()
    test_chain_overview_panel_sections()
    test_fleet_terminals_lazy_mounting()
    test_conversation_thread_page_tab_integration()
    test_app_shell_container()
    test_icon_definitions()
    test_attachment_metadata_contract()
    print("ALL TESTS PASSED: test_ui_chain_overview_tab_static.py (REQ-UI-CHAIN-OVERVIEW-TAB, REQ-CITC-DEPLOY-VERIFY)")


if __name__ == "__main__":
    main()
