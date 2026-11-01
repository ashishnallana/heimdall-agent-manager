type Surface = { flush: () => void | Promise<void>; blocked?: () => boolean };

/** A held freeze; acknowledgements and releases are scoped to one main epoch. */
export function createPreparationRegistry() {
  const surfaces = new Map<object, Surface>();
  let epoch: number | null = null;
  let latest = 0;
  let valid = false;
  const invalidated = new Set<(epoch: number) => void>();
  const invalidate = () => { if (epoch !== null) { valid = false; for (const listener of invalidated) listener(epoch); } };
  const listeners = new Set<(frozen: boolean) => void>();
  const notify = () => { for (const listener of listeners) listener(epoch !== null); };
  return {
    register: (surface: Surface) => { const key = {}; surfaces.set(key, surface); invalidate(); return () => { surfaces.delete(key); invalidate(); }; },
    frozen: () => epoch !== null,
    currentEpoch: () => epoch,
    onInvalidated: (listener: (epoch: number) => void) => { invalidated.add(listener); return () => { invalidated.delete(listener); }; },
    validate: () => { try { return epoch !== null && valid && [...surfaces.values()].every(surface => !surface.blocked?.()); } catch { return false; } },
    subscribe: (listener: (frozen: boolean) => void) => { listeners.add(listener); return () => { listeners.delete(listener); }; },
    async prepare(request: number) {
      if (!Number.isSafeInteger(request) || request <= latest || epoch !== null || surfaces.size === 0) return false;
      latest = request;
      epoch = request;
      valid = true;
      notify(); // Freeze before observing blockers and flushing the latest refs.
      try {
        for (const surface of [...surfaces.values()]) {
          if (surface.blocked?.()) throw new Error('pending work');
          await surface.flush();
          if (epoch !== request) return false;
        }
        return epoch === request && valid && [...surfaces.values()].every(surface => !surface.blocked?.());
      } catch {
        if (epoch === request) { epoch = null; notify(); }
        return false;
      }
    },
    release(request: number) { if (epoch === request) { epoch = null; notify(); } },
  };
}

export const desktopUpdatePreparation = createPreparationRegistry();
export const desktopUpdateFrozen = () => desktopUpdatePreparation.frozen();

/** Known composers register checked flushes; other editable surfaces must close.
 * This includes empty unsaved deletions and focused child-frame editors. */
export function unsupportedUpdateEditorOpen(doc: Document): boolean {
  if (doc.querySelector('.monaco-editor, [contenteditable="true"], iframe')) return true;
  return Array.from(doc.querySelectorAll<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>('input, textarea, select')).some(element => {
    if (element.dataset.debugId === 'conversation-composer-input') return false;
    if (element.disabled || ('readOnly' in element && element.readOnly)) return false;
    if (element.tagName === 'INPUT') {
      const input = element as HTMLInputElement;
      if (input.dataset.debugId === 'conversation-attach-input' && !input.files?.length) return false;
      if (['button', 'submit', 'hidden', 'search'].includes(input.type) || /search/.test(input.dataset.debugId || '')) return false;
    }
    return true;
  });
}

/** Reject mutation dispatch at the store boundary, including delayed callbacks. */
export const desktopUpdateMutationGuard = () => (next: any) => (action: any) => {
  if (desktopUpdateFrozen() && /^(workspaceLayout|workspaceChrome|auxPanes|composerContext)\//.test(String(action?.type))) return action;
  return next(action);
};

export function installDesktopUpdatePreparation(api: any, doc: Document = document) {
  if (api?.schemaVersion !== 1 || typeof api.onPrepare !== 'function' || typeof api.preparationResult !== 'function' || typeof api.onRelease !== 'function') return () => {};
  let overlay: HTMLDivElement | null = null;
  const events = ['beforeinput', 'keydown', 'click', 'pointerdown', 'drop', 'paste', 'submit', 'change', 'input'] as const;
  const prevent = (event: Event) => { if (desktopUpdateFrozen()) { event.preventDefault(); event.stopImmediatePropagation(); } };
  for (const name of events) doc.addEventListener(name, prevent, true);
  const unsubscribe = desktopUpdatePreparation.subscribe(frozen => {
    if (frozen) {
      overlay = doc.createElement('div');
      overlay.dataset.debugId = 'desktop-update-preparing-overlay';
      overlay.setAttribute('role', 'dialog'); overlay.setAttribute('aria-modal', 'true');
      overlay.style.cssText = 'position:fixed;inset:0;z-index:2147483647;display:grid;place-items:center;background:rgba(0,0,0,.8);color:white';
      const status = doc.createElement('p'); status.dataset.debugId = 'desktop-update-preparing-status';
      status.setAttribute('role', 'status'); status.textContent = 'Saving work and preparing to restart. Editing is paused…';
      overlay.append(status); doc.body.append(overlay);
    } else { overlay?.remove(); overlay = null; }
  });
  const offPrepare = api.onPrepare(async (request: any) => {
    const epoch = request?.epoch;
    const ready = await desktopUpdatePreparation.prepare(epoch);
    await api.preparationResult({ epoch, ready });
  });
  const offInvalidated = desktopUpdatePreparation.onInvalidated(epoch => { void api.preparationResult({ epoch, ready: false }); });
  const validation = setInterval(() => {
    const epoch = desktopUpdatePreparation.currentEpoch();
    if (epoch !== null && !desktopUpdatePreparation.validate()) void api.preparationResult({ epoch, ready: false });
  }, 100);
  const offRelease = api.onRelease((request: any) => desktopUpdatePreparation.release(request?.epoch));
  return () => { clearInterval(validation); offInvalidated(); offPrepare(); offRelease(); unsubscribe(); overlay?.remove(); for (const name of events) doc.removeEventListener(name, prevent, true); };
}
