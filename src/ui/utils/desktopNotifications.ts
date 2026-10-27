// Desktop capability is injected by the sandboxed preload before UI startup.
// Electron's native API has no browser permission prompt; OS settings still
// control whether a supported application can actually display banners.
export function desktopNotifications(): { supported: boolean; show: (plan: {
  title: string; body: string; tag: string; route: string;
}) => Promise<boolean> } | undefined {
  if (typeof window === 'undefined') return undefined;
  return (window as any).odinApi?.notifications;
}
