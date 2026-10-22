// Provider extension badges (REQ-EXT-DET-2). The state logic lives in
// extensionBadgeModel.ts; these components only render it.
import { useEffect, useState } from 'react';
import { Icon, StatusPill } from '@ui';
import { copyTextToClipboard } from '../../utils/artifactAnnotations';
import {
  instanceSignalBadge,
  providerExtensionBadge,
  type ProviderExtensionStatus,
} from './extensionBadgeModel';

/** Inline pill for the provider card header; null when the provider has no extension. */
export function ProviderExtensionPill({ providerName, extension }: { providerName: string; extension: ProviderExtensionStatus | null }) {
  const badge = providerExtensionBadge(extension);
  if (!badge) return null;
  return (
    <span data-debug-id={`provider-extension-badge-${providerName}`} data-extension-state={badge.kind} title={badge.detail}>
      <StatusPill tone={badge.tone}>{badge.label}</StatusPill>
    </span>
  );
}

/**
 * The badge's helper line plus, for "Not found" / "Update available", the
 * install command with a copy button. Renders nothing for an installed or
 * unsupported extension.
 */
export function ProviderExtensionBadge({ providerName, extension, className = '' }: { providerName: string; extension: ProviderExtensionStatus | null; className?: string }) {
  const badge = providerExtensionBadge(extension);
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return undefined;
    const handle = setTimeout(() => setCopied(false), 1500);
    return () => clearTimeout(handle);
  }, [copied]);
  if (!badge || badge.kind === 'installed') return null;
  return (
    <div data-debug-id={`provider-extension-help-${providerName}`} className={`text-xs text-muted ${className}`}>
      <p>{badge.detail}</p>
      {badge.installHint ? (
        <div className="mt-1.5 flex min-w-0 items-stretch gap-1.5">
          <code
            data-debug-id={`provider-extension-install-hint-${providerName}`}
            className="min-w-0 flex-1 overflow-x-auto whitespace-nowrap rounded-lg border border-subtle bg-surface-raised px-2 py-1.5 font-mono text-[11px] text-primary"
          >
            {badge.installHint}
          </code>
          <button
            type="button"
            data-debug-id={`provider-extension-install-copy-btn-${providerName}`}
            aria-label="Copy install command"
            title={copied ? 'Copied' : 'Copy install command'}
            onClick={(event) => {
              event.stopPropagation();
              void copyTextToClipboard(badge.installHint).then(() => setCopied(true));
            }}
            className="grid min-h-9 min-w-9 shrink-0 place-items-center rounded-lg border border-subtle bg-surface text-muted hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name={copied ? 'check' : 'copy'} size={14} />
          </button>
        </div>
      ) : null}
    </div>
  );
}

/** Per-instance "Native signals" / "Screen detection" badge for the conversation header. */
export function InstanceSignalBadge({ extension, compact = false }: { extension: unknown; compact?: boolean }) {
  const badge = instanceSignalBadge(extension);
  return (
    <span
      data-debug-id="conversation-signal-badge"
      data-signal-source={badge.kind}
      title={badge.tooltip}
      aria-label={`${badge.label}. ${badge.tooltip}`}
      className={`inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium ${
        badge.kind === 'native' ? 'border-success/30 bg-success-soft text-success' : 'border-subtle bg-surface-raised text-muted'
      }`}
    >
      <Icon name={badge.kind === 'native' ? 'zap' : 'terminal'} size={12} />
      {compact ? null : <span className="hidden sm:inline">{badge.label}</span>}
    </span>
  );
}
