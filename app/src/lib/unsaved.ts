// "You have unsaved changes": one flag for the whole app. Pages with a save bar set it; the sidebar
// asks before leaving, and the browser asks before closing or reloading the tab.
import { useEffect } from 'react';

let dirty = false;

export function setUnsaved(v: boolean) {
  dirty = v;
}

/** Ask before leaving a page with unsaved changes. Returns true when it is fine to leave. */
export function confirmLeave(): boolean {
  if (!dirty) return true;
  const ok = window.confirm('You have unsaved changes. Leave without saving?');
  if (ok) dirty = false;
  return ok;
}

/** Keep the flag in step with a page's state and warn before the tab is closed. */
export function useUnsavedChanges(isDirty: boolean) {
  useEffect(() => {
    setUnsaved(isDirty);
    if (!isDirty) return;
    const warn = (e: BeforeUnloadEvent) => {
      e.preventDefault();
    };
    window.addEventListener('beforeunload', warn);
    return () => {
      window.removeEventListener('beforeunload', warn);
      setUnsaved(false);
    };
  }, [isDirty]);
}
