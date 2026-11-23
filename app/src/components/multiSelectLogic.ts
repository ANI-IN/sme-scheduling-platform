// The pure rules of the MultiSelect field (batch 4, B11), kept apart from the component so they are unit tested.

/** One choice of a MultiSelect: its ID and the words shown for it. */
export type MultiSelectItem = {
  id: string;
  label: string;
  /** Shown after the label in the list, in small grey text (for example "not in use"). */
  hint?: string;
  /** Cannot be added (a chip for it can still be removed). */
  disabled?: boolean;
};

/** What one change did: the IDs added and the IDs removed. */
export type MultiSelectChange = { added: string[]; removed: string[] };

/** Lower case, without accents and extra spaces, so "José" matches "jose". */
export const normalize = (s: string) =>
  s.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().replace(/\s+/g, ' ').trim();

/** The items whose label (or hint) holds every word typed, in any order. Nothing typed: every item. */
export function matchItems<T extends MultiSelectItem>(items: readonly T[], query: string): T[] {
  const words = normalize(query).split(' ').filter(Boolean);
  if (words.length === 0) return [...items];
  return items.filter((i) => {
    const text = normalize(`${i.label} ${i.hint ?? ''}`);
    return words.every((w) => text.includes(w));
  });
}

/** Select an item that is not selected, or unselect one that is. */
export function toggleId(
  value: readonly string[],
  id: string,
): { next: string[]; change: MultiSelectChange } {
  return value.includes(id)
    ? { next: value.filter((x) => x !== id), change: { added: [], removed: [id] } }
    : { next: [...value, id], change: { added: [id], removed: [] } };
}

/** Add several IDs at once (those already selected are left out of the change). */
export function addIds(
  value: readonly string[],
  ids: readonly string[],
): { next: string[]; change: MultiSelectChange } {
  const added = [...new Set(ids)].filter((id) => !value.includes(id));
  return { next: [...value, ...added], change: { added, removed: [] } };
}

/** Remove one ID. */
export function removeId(
  value: readonly string[],
  id: string,
): { next: string[]; change: MultiSelectChange } {
  return {
    next: value.filter((x) => x !== id),
    change: { added: [], removed: value.includes(id) ? [id] : [] },
  };
}

/**
 * The active option after a key press in a list of `count` options: Down and Up wrap around, Home and End go to the
 * first and last. No options: none is active (-1).
 */
export function moveActive(
  active: number,
  count: number,
  key: 'ArrowDown' | 'ArrowUp' | 'Home' | 'End',
): number {
  if (count <= 0) return -1;
  if (key === 'Home') return 0;
  if (key === 'End') return count - 1;
  if (key === 'ArrowDown') return active < 0 || active >= count - 1 ? 0 : active + 1;
  return active <= 0 ? count - 1 : active - 1;
}

/** The selected IDs with the ones being saved now, so a choice shows at once and cannot be added twice. */
export function withPending(value: readonly string[], pending: readonly string[]): string[] {
  return [...value, ...pending.filter((id) => !value.includes(id))];
}

/** "Nobody yet", "Victor Palmer" or "Victor Palmer and 2 more", for a short summary of the choice. */
export function summary(
  items: readonly MultiSelectItem[],
  value: readonly string[],
  none: string,
): string {
  const first = items.find((i) => i.id === value[0])?.label;
  if (!first) return none;
  return value.length === 1 ? first : `${first} and ${value.length - 1} more`;
}
