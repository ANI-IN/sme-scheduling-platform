// Autosave for small edits (Release 3, C15): names, notes, channels, toggles and orders save as soon as they change.
// Text waits until the person stops typing for a moment (800 ms) or leaves the field; toggles and choices save at
// once. One save runs at a time; a change made meanwhile is saved right after it.
//
// The form follows the stored data while it has no unsaved edits, so a change by the automation or a teammate shows
// up by itself. A table with a row version (optimistic concurrency) passes it in: a save with unsaved edits made on
// top of an older version is refused by the database, and the reason shows next to the form in plain words.
import { toast } from 'sonner';
import { useCallback, useEffect, useRef, useState } from 'react';

export type SaveState = 'idle' | 'saving' | 'saved' | 'error';
export type SaveStatus = { state: SaveState; error: string | null };

/** Wait this long after the last key press before saving text. */
export const TEXT_DELAY_MS = 800;

type Options<T> = {
  /** What the form shows now (only the fields that autosave). */
  value: T;
  /** The same fields as stored, from the latest data. */
  stored: T;
  /** The stored row version, when the table has one. */
  version?: number;
  /** Store the value. Returns the new row version when the table has one. */
  save: (value: T, version: number | undefined) => Promise<number | void>;
  /** The stored data changed while there were no unsaved edits: show it. */
  onReload: (stored: T) => void;
  /** How long to wait after a change to a text field. */
  delay?: number;
  /** Fields that save at once when they change: toggles, choices and channels. */
  instant?: (keyof T)[];
  /** False while a field has a problem: nothing is saved until it is fixed. */
  valid?: boolean;
  /** False turns autosave off (for example while adding a new record). */
  enabled?: boolean;
};

export function useAutosave<T>({
  value,
  stored,
  version,
  save,
  onReload,
  delay = TEXT_DELAY_MS,
  instant = [],
  valid = true,
  enabled = true,
}: Options<T>) {
  const valueKey = JSON.stringify(value);
  const storedKey = JSON.stringify(stored);
  // What is known to be in the database: the stored data, or what this form saved last.
  const [saved, setSaved] = useState(storedKey);
  const [ver, setVer] = useState(version);
  const [seen, setSeen] = useState({ key: storedKey, version });
  const [status, setStatus] = useState<SaveStatus>({ state: 'idle', error: null });
  const dirty = valueKey !== saved;

  // The stored data changed (the automation, a teammate, or this form's own save coming back).
  if (seen.key !== storedKey || seen.version !== version) {
    setSeen({ key: storedKey, version });
    if (!dirty) {
      setSaved(storedKey);
      setVer(version);
      if (valueKey !== storedKey) onReload(stored);
    }
  }

  const latest = useRef({ value, valueKey, ver, valid, enabled, dirty, instant });
  const saveRef = useRef(save);
  useEffect(() => {
    latest.current = { value, valueKey, ver, valid, enabled, dirty, instant };
    saveRef.current = save;
  });
  const before = useRef(value);
  const busy = useRef(false);
  const again = useRef(false);
  const failed = useRef<string | null>(null);
  const closing = useRef(false);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  const run = useCallback(async (): Promise<void> => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = undefined;
    const l = latest.current;
    if (!l.enabled || !l.valid || !l.dirty) return;
    if (busy.current) {
      again.current = true;
      return;
    }
    busy.current = true;
    setStatus({ state: 'saving', error: null });
    try {
      const next = await saveRef.current(l.value, l.ver);
      const newVer = typeof next === 'number' ? next : l.ver;
      failed.current = null;
      setSaved(l.valueKey);
      setVer(newVer);
      latest.current = {
        ...latest.current,
        ver: newVer,
        dirty: latest.current.valueKey !== l.valueKey,
      };
      setStatus({ state: 'saved', error: null });
    } catch (e) {
      failed.current = l.valueKey;
      const why = e instanceof Error ? e.message : String(e);
      // Review R35: a save that fails as the form closes is said out loud, not lost silently.
      if (closing.current) toast.error(`Your last change was not saved. ${why}`);
      setStatus({ state: 'error', error: why });
    } finally {
      busy.current = false;
      // A change made while saving is saved right after.
      if (again.current) {
        again.current = false;
        timer.current = setTimeout(() => void runNext.current(), 0);
      }
    }
  }, []);
  const runNext = useRef(run);
  useEffect(() => {
    runNext.current = run;
  }, [run]);

  // Save a while after the last change to text (each new change starts the wait again), at once for the rest.
  useEffect(() => {
    const { value: now, instant: quickKeys } = latest.current;
    const was = before.current;
    before.current = now;
    if (!enabled || !valid || !dirty || valueKey === failed.current) return;
    const quick = quickKeys.some((k) => JSON.stringify(now[k]) !== JSON.stringify(was[k]));
    timer.current = setTimeout(() => void run(), quick ? 0 : delay);
    return () => {
      if (timer.current) clearTimeout(timer.current);
      timer.current = undefined;
    };
  }, [valueKey, dirty, valid, enabled, delay, run]);

  // Closing the form does not lose an edit that was still waiting.
  useEffect(() => {
    closing.current = false;
    return () => {
      closing.current = true;
      const l = latest.current;
      if (l.enabled && l.valid && l.dirty && l.valueKey !== failed.current) void run();
    };
  }, [run]);

  return {
    status,
    /** Unsaved edits (waiting, or refused). */
    dirty,
    /** The row version this form saves on top of. */
    version: ver,
    /** Another save of the same row (for example the contact details) returned this version. */
    adoptVersion: setVer,
    /** Save now, for example when the person leaves a text field. */
    flush: () => void run(),
  };
}
