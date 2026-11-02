import React from 'react';
import { isChunkLoadError, tryChunkReload } from '../../utils/chunkReload';

type ErrorBoundaryProps = {
  children: React.ReactNode;
  /** Remounts the boundary (clears the error) when this value changes. */
  resetKey?: string | number;
  /** Optional label for the surface that failed, shown in the fallback. */
  label?: string;
};

type ErrorBoundaryState = {
  error: Error | null;
};

/**
 * Catches render/lifecycle exceptions in its subtree and shows an inline
 * fallback instead of letting the whole React root unmount to a blank page.
 * Without a boundary, one bad piece of data (e.g. an object rendered as a React
 * child) takes down the entire app.
 */
export default class ErrorBoundary extends React.Component<ErrorBoundaryProps, ErrorBoundaryState> {
  constructor(props: ErrorBoundaryProps) {
    super(props);
    this.state = { error: null };
  }

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { error };
  }

  componentDidCatch(error: Error, info: React.ErrorInfo) {
    // Surface to the console for diagnosis; never rethrow.
    // eslint-disable-next-line no-console
    console.error('[ErrorBoundary] caught render error', error, info?.componentStack);
    // A missing lazy chunk (stale build after a deploy) is fixed by a reload; the
    // fallback below stays if the reload is skipped (offline / just reloaded).
    if (isChunkLoadError(error) && typeof window !== 'undefined') tryChunkReload(window);
  }

  componentDidUpdate(prev: ErrorBoundaryProps) {
    if (this.state.error && prev.resetKey !== this.props.resetKey) {
      this.setState({ error: null });
    }
  }

  // React.lazy caches a failed import, so re-rendering can never recover a chunk
  // error; only a reload fetches the current build.
  private handleReset = () => {
    if (isChunkLoadError(this.state.error)) window.location.reload();
    else this.setState({ error: null });
  };

  render() {
    const { error } = this.state;
    if (!error) return this.props.children;

    const where = this.props.label ? ` in ${this.props.label}` : '';
    return (
      <div
        data-debug-id="error-boundary-fallback"
        className="m-4 rounded-2xl border border-danger/30 bg-danger-soft p-6 text-sm text-primary"
        role="alert"
      >
        <h2 className="mb-1 text-base font-bold text-danger">Something went wrong{where}.</h2>
        <p className="mb-3 text-muted">
          This section hit an unexpected error and was contained so the rest of the app keeps working.
        </p>
        {error?.message ? (
          <pre className="mb-3 max-h-40 overflow-auto whitespace-pre-wrap rounded-lg border border-subtle bg-surface-raised p-3 font-mono text-[11px] text-danger">
            {error.message}
          </pre>
        ) : null}
        <div className="flex gap-2">
          <button
            type="button"
            data-debug-id="error-boundary-retry"
            onClick={this.handleReset}
            className="rounded-xl bg-accent px-4 py-2 text-sm font-semibold text-accent-fg hover:opacity-90"
          >
            Try again
          </button>
          <button
            type="button"
            data-debug-id="error-boundary-reload"
            onClick={() => window.location.reload()}
            className="rounded-xl border border-subtle bg-surface px-4 py-2 text-sm font-semibold text-muted hover:bg-surface-raised hover:text-primary"
          >
            Reload page
          </button>
        </div>
      </div>
    );
  }
}
