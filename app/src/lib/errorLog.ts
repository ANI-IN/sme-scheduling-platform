// Sends errors people run into to the private error log (shown on Connections). Never throws and
// never logs its own failures, so a broken connection cannot cause a loop.
import { supabase } from './supabase';

let sending = 0;

export function reportError(error: unknown, context?: string) {
  if (sending > 5) return;
  const e = error instanceof Error ? error : new Error(String(error));
  const message = (context ? `${context}: ` : '') + (e.message || 'Unknown error');
  sending += 1;
  void supabase
    .rpc('log_app_error', {
      p_message: message.slice(0, 500),
      p_detail: (e.stack ?? '').slice(0, 4000),
      p_page: window.location.pathname + window.location.search,
      p_browser: navigator.userAgent.slice(0, 300),
    })
    .then(
      () => {
        sending -= 1;
      },
      () => {
        sending -= 1;
      },
    );
}

/** Catch errors that nothing else handled. */
export function installGlobalErrorReporting() {
  window.addEventListener('error', (ev) => reportError(ev.error ?? ev.message, 'Page error'));
  window.addEventListener('unhandledrejection', (ev) => reportError(ev.reason, 'Unhandled error'));
}
