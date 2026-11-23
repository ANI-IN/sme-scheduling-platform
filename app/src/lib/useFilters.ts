import { useMemo, useState } from 'react';
import {
  readSaved,
  savedValues,
  withSavedValues,
  type FilterValues,
  type SavedFilters,
} from './filters';

function load(key: string): SavedFilters {
  try {
    return readSaved(localStorage.getItem(key));
  } catch {
    return readSaved(null);
  }
}

/**
 * A page's filter choices for the current domain, remembered on this device under `key` (see filtersKey). The key
 * follows the signed in person, so a different person on the same browser starts with their own choices.
 */
export function useRememberedFilters(
  key: string,
  domainId: string | null | undefined,
  keys: readonly string[],
) {
  const [state, setState] = useState(() => ({ key, saved: load(key) }));
  let saved = state.saved;
  if (state.key !== key) {
    // The person changed (or their email arrived): read their own choices.
    saved = load(key);
    setState({ key, saved });
  }
  const values = useMemo(() => savedValues(saved, domainId, keys), [saved, domainId, keys]);
  const set = (next: FilterValues) => {
    const s = withSavedValues(saved, domainId, next);
    try {
      localStorage.setItem(key, JSON.stringify(s));
    } catch {
      /* storage full or turned off: the choices still apply until the page is closed */
    }
    setState({ key, saved: s });
  };
  return [values, set] as const;
}
