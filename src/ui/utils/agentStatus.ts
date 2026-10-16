// Canonical agent runtime status helpers. Previously these lived only in
// src/ui/components/App.tsx (legacy chrome). They are relocated here so live
// components and tests import them from a stable, dead-code-free location.
// Behavior is unchanged from the original App.tsx implementations.

function agentRuntimeDotTone(status: string): string {
  if (status === 'connected') return 'bg-success shadow-glow-success animate-soft-pulse';
  if (status === 'idle' || status === 'ready') return 'bg-success/80';
  if (status === 'starting') return 'bg-accent shadow-glow-accent animate-soft-pulse';
  if (status === 'startup_blocked' || status === 'stopping') return 'bg-warning shadow-glow-warning animate-soft-pulse';
  if (status === 'startup_failed') return 'bg-danger shadow-glow-danger';
  if (status === 'startup_unknown') return 'bg-info shadow-glow-accent';
  return 'bg-faint/70';
}

export function agentRuntimeDot(agent: any): { color: string; label: string } {
  if (!agent) return { color: 'bg-faint', label: 'unknown' };
  const startup = String(agent.startupStatus || '').toLowerCase();
  const state = String(agent.state || agent.status || '').toLowerCase();
  const activity = String(agent.activityStatus || agent.activity_status || '').toLowerCase();
  const blocked = agent.blockedReason || state === 'blocked' || startup === 'startup_blocked' || startup === 'blocked';
  const live = Boolean(agent.connected || startup === 'ready' || state === 'ready' || state === 'live' || state === 'connected' || state === 'idle');
  if (blocked) return { color: 'bg-danger', label: 'blocked' };
  if (startup === 'startup_failed' || startup === 'startup_unknown') return { color: startup === 'startup_failed' ? 'bg-danger' : 'bg-info', label: startup.replace('startup_', '') };
  if (state === 'missing' || state === 'archived') return { color: 'bg-faint', label: state };
  if (state === 'disconnected' || state === 'offline' || state === 'stopped') return { color: 'bg-faint', label: state };
  if (startup === 'starting' || state === 'starting' || state === 'warming' || state === 'restarting') return { color: 'bg-warning animate-pulse', label: startup || state || 'starting' };
  if (live && activity === 'active') return { color: 'bg-success', label: 'working' };
  if (live && activity === 'idle') return { color: 'bg-warning', label: 'idle' };
  if (live && agent.currentTaskId) return { color: 'bg-accent', label: 'working' };
  if (live) return { color: 'bg-success', label: state || 'connected' };
  return { color: 'bg-faint', label: state || startup || 'unknown' };
}

export function isAgentRunning(agent: any): boolean {
  if (!agent) return false;
  const startup = String(agent.startupStatus || '').toLowerCase();
  const state = String(agent.state || agent.status || '').toLowerCase();
  const mappedStatus = String(agent.status || '').toLowerCase();
  if (agent.blockedReason || state === 'blocked' || startup === 'blocked' || startup === 'startup_blocked') return false;
  // An explicitly stopped/stopping instance is not running even if its durable
  // `state` field is still `idle`. The mapped status is `offline` for stopped
  // agents (see chatSlice), so a disconnected offline instance must not be
  // treated as live — otherwise the conversation thread hides its Start/resume
  // affordance after a stop.
  if (startup === 'stopped' || startup === 'stopping') return false;
  if (mappedStatus === 'offline' && !agent.connected) return false;
  if (agent.currentTaskId || agent.connected) return true;
  return ['ready', 'live', 'connected', 'working', 'active'].includes(state) || ['ready', 'connected'].includes(startup);
}

// REQ-ERR-PROTO-A: a failed instance carries the bridge's typed error as
// `last_error` ({code, class, cause, message}). The class says what happens next,
// so the UI words the failure by class rather than showing a bare "failed".
export function agentFailureSummary(lastError: any): { label: string; detail: string; tone: 'warning' | 'danger' } | null {
  if (!lastError || typeof lastError !== 'object') return null;
  const cause = String(lastError.cause || lastError.code || '').replace(/_/g, ' ');
  const message = String(lastError.message || '');
  const detail = message && message !== lastError.cause ? `${cause}: ${message}` : cause;
  switch (lastError.class) {
    case 'retriable': return { label: 'Retrying automatically', detail, tone: 'warning' };
    case 'recoverable': return { label: 'Needs attention', detail, tone: 'warning' };
    default: return { label: 'Failed', detail, tone: 'danger' };
  }
}

// Keep the tone helper exported for potential reuse; it is intentionally not
// used by the two functions' public contract but mirrors the original module.
export { agentRuntimeDotTone };
