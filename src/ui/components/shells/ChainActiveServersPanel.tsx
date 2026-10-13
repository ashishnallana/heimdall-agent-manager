import React from 'react';
import { useDispatch } from 'react-redux';
import { useListShellsQuery } from '../../api/endpoints/shells';
import type { ShellSession } from '../../api/endpoints/shells';
import { openPreviewInWorkbench } from '../../store/workbenchSlice';
import { activeServersOf, statusPresentation, supportsLivePreview } from './shellModel';
import { ShellLogViewer } from './ShellLogViewer';

/**
 * REQ-SHELL-6 §4 — the chain summary's ACTIVE SERVERS panel.
 *
 * Lists every ACTIVE server running for one task chain, whoever started it (agent or
 * user). Each row can stream its stdout on demand, and can open a live preview when it
 * declares a port.
 *
 * WHY THIS IS A SCOPED QUERY AND NOT A CLIENT-SIDE FILTER — which is what AC2b's
 * negatives actually test. `server` is CHAIN + BRIDGE scoped, and the scope table is
 * enforced in the repository, not here (src/hub/domain/shell_session.odin:87-91):
 *
 *     .Run    = {key = {.Agent_Instance}, forbidden = {.Chain}}
 *     .Server = {key = {.Chain, .Bridge}, forbidden = {.Agent_Instance}}
 *     .Shell  = {key = {.Bridge},         forbidden = {.Chain, .Agent_Instance}}
 *
 * `Chain` appears in the scope key of SERVER ALONE, so a list narrowed by chain_id can
 * only ever come back with servers — a run or a shell leaking in is impossible one layer
 * below this component rather than merely filtered out inside it. Adding `status=live`
 * narrows to the non-terminal ones, which is the whole of §4's set in ONE request.
 *
 * WHY THE CHAIN SUMMARY IS THE RIGHT HOME. It is not one option among several: chain is
 * in no other kind's scope key, so the chain summary is the only mounted surface whose
 * scope matches what this panel displays. Note this deliberately REVISITS
 * REQ-UI-REMOVE-SHELLS-FROM-CHAIN-VIEW, which removed the generic all-kinds session
 * table from this page — see the note in tests/test_ui_chain_overview_no_shells_static.py
 * for exactly what that requirement still forbids and what REQ-SHELL-6 now permits.
 *
 * ON NOT TRUSTING status=running (iss_18d9822647aee3b2: four dead server sessions still
 * reporting `running` and still holding port 5173). This panel does not treat the stored
 * status as confirmed truth: `status_unknown` — derived from whether the owning bridge is
 * currently connected — is rendered as its own state, and a session no bridge is vouching
 * for gets NO live-preview action, only the indicator that it would support one. The
 * stale rows in that issue are corrected by hub-side convergence, and REQ-SHELL-6 §6 is
 * what makes the correction visible: the adopt/correct path publishes
 * resource_changed/shell_session (shell_session_inventory.odin:427), which the UI used to
 * drop on the floor and now handles.
 */
export function ChainActiveServersPanel({ chainId }: { chainId: string }) {
  const dispatch = useDispatch();
  const [openLogSessionId, setOpenLogSessionId] = React.useState('');

  // The scoped query. No pollingInterval (§6): shell events invalidate the
  // ShellSessions tag this provides, which refetches it.
  const { data, isLoading, error } = useListShellsQuery(
    { chainId, status: 'live' },
    { skip: !chainId },
  );

  /* `status=live` is the server-side narrowing (starting|running). The client-side guard
     below is NOT a substitute for it — it exists because the two sets can legitimately
     disagree for one render: a session that exits between the fetch and the repaint is
     still in this cached page while its row now says `exited`. Showing it would break
     §4's "only ACTIVE servers appear — a terminal server drops off the panel". */
  const servers = React.useMemo(() => activeServersOf(data?.sessions ?? []), [data]);

  return (
    <section data-debug-id="chain-active-servers-panel" className="rounded-xl border border-subtle bg-surface">
      <header className="flex items-center justify-between border-b border-subtle px-3 py-2">
        <h3 className="text-sm font-semibold text-primary">Active servers</h3>
        {servers.length > 0 && (
          <span data-debug-id="chain-active-servers-count" className="text-[11px] text-muted">
            {servers.length} running for this chain
          </span>
        )}
      </header>

      <div className="p-3">
        {isLoading ? (
          <div data-debug-id="chain-active-servers-loading" className="text-xs text-faint italic">Loading…</div>
        ) : error ? (
          <div data-debug-id="chain-active-servers-error" className="text-xs text-danger">
            Could not load this chain's servers.
          </div>
        ) : servers.length === 0 ? (
          /* §4 requires an EMPTY STATE, explicitly not a collapsed or invisible section:
             "no servers are running" is information, and a section that vanishes leaves
             the reader unable to tell it from a panel that failed to load. It also says
             WHO can start one, because server is the one kind either an agent or a user
             may start. */
          <div data-debug-id="chain-active-servers-empty" className="text-xs text-muted">
            <div className="font-medium text-primary">No servers running for this chain</div>
            <div className="mt-0.5">
              A server started by any agent on this chain — or by you — appears here while it runs.
            </div>
          </div>
        ) : (
          <ul className="space-y-1.5">
            {servers.map((session) => (
              <li key={session.session_id}>
                <ServerRow
                  session={session}
                  logOpen={openLogSessionId === session.session_id}
                  onToggleLog={() =>
                    setOpenLogSessionId((current) => (current === session.session_id ? '' : session.session_id))
                  }
                  onOpenPreview={() =>
                    dispatch(
                      openPreviewInWorkbench({
                        sessionId: session.session_id,
                        label: session.label || session.cmd || session.session_id,
                        port: session.server_port,
                      }),
                    )
                  }
                />
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}

interface ServerRowProps {
  session: ShellSession;
  logOpen: boolean;
  onToggleLog: () => void;
  onOpenPreview: () => void;
}

function ServerRow({ session, logOpen, onToggleLog, onOpenPreview }: ServerRowProps) {
  const presentation = statusPresentation(session);
  const previewable = supportsLivePreview(session);
  // The INDICATOR says preview is supported; the ACTION needs a bridge that is actually
  // vouching for the session. Splitting them is what keeps a preview button off a row
  // whose host has vanished, without hiding the fact that it is a previewable server.
  const canOpenPreview = previewable && session.bridge_online && session.status === 'running';

  return (
    <div
      data-debug-id={`chain-active-server-${session.session_id}`}
      className="rounded-lg border border-subtle bg-surface-raised px-2.5 py-2"
    >
      <div className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
        <span className="min-w-0 flex-1 truncate text-[12px] font-medium text-primary" title={session.cmd}>
          {session.label || session.cmd || session.session_id}
        </span>

        <span
          data-debug-id={`chain-active-server-status-${session.session_id}`}
          title={presentation.title}
          className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold ${
            presentation.unknown ? 'bg-warning-soft text-warning' : 'bg-neutral-soft text-muted'
          }`}
        >
          {presentation.label}
        </span>

        {/* §5 LIVE PREVIEW INDICATOR — on the chain summary row as well as the shells
            list. Only for a server that declares a port; a portless server is valid and
            shows nothing here. */}
        {previewable && (
          <span
            data-debug-id={`chain-active-server-preview-indicator-${session.session_id}`}
            title={`Supports live preview — serves on port ${session.server_port}`}
            className="shrink-0 rounded bg-neutral-soft px-1.5 py-0.5 text-[10px] font-semibold text-muted"
          >
            preview :{session.server_port}
          </span>
        )}

        <button
          type="button"
          onClick={onToggleLog}
          aria-expanded={logOpen}
          data-debug-id={`chain-active-server-stream-${session.session_id}`}
          title="Read this server's stdout"
          className="shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold text-accent hover:bg-accent/10"
        >
          {logOpen ? 'Hide output' : 'Stream output'}
        </button>

        {canOpenPreview && (
          <button
            type="button"
            onClick={onOpenPreview}
            data-debug-id={`chain-active-server-open-preview-${session.session_id}`}
            title={`Open the live preview for port ${session.server_port}`}
            className="shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold text-accent hover:bg-accent/10"
          >
            Open preview
          </button>
        )}
      </div>

      {/* Stdout on demand: the viewer mounts only once the row is opened, so no row
          fetches output nobody asked for. */}
      {logOpen && (
        <div className="mt-2">
          <ShellLogViewer session={session} showSessionVerbs={false} onClose={onToggleLog} />
        </div>
      )}
    </div>
  );
}

export default ChainActiveServersPanel;
