import ProviderSetupSurface from './ProviderSetupSurface';

export interface ProviderEnrollmentSetupPageProps {
  bridgeId?: string;
}

function finishEnrollmentSetup() {
  window.location.hash = '#/home';
}

export function ProviderEnrollmentSetupPage({ bridgeId }: ProviderEnrollmentSetupPageProps) {
  return (
    <div
      data-debug-id="provider-enrollment-page"
      className="mx-auto flex min-h-full w-full max-w-4xl flex-col px-4 py-8 sm:px-8 sm:py-12"
    >
      <header className="mb-7 flex items-center justify-between gap-4" data-debug-id="provider-enrollment-header">
        <div className="flex items-center gap-3">
          <div className="flex h-9 w-9 items-center justify-center rounded-xl bg-accent text-sm font-bold text-on-accent">
            H
          </div>
          <div>
            <div className="text-sm font-semibold text-primary">Ninjy</div>
            <div className="text-xs text-muted">Bridge setup</div>
          </div>
        </div>
        <ol className="hidden items-center gap-2 text-xs text-muted sm:flex" aria-label="Enrollment progress">
          <li className="text-success">1&nbsp; Approved</li>
          <li aria-hidden="true">—</li>
          <li className="text-success">2&nbsp; Connected</li>
          <li aria-hidden="true">—</li>
          <li className="font-semibold text-primary">3&nbsp; Providers</li>
        </ol>
      </header>

      <main className="rounded-2xl border border-subtle bg-surface p-4 shadow-sm sm:p-7">
        <ProviderSetupSurface
          bridgeId={bridgeId}
          mode="enrollment"
          onApply={finishEnrollmentSetup}
        />
      </main>
    </div>
  );
}

export default ProviderEnrollmentSetupPage;
