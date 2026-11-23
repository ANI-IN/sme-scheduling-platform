// Filters with several choices per field, for Upcoming classes and the Schedule board (Release 3, C13 and C14).
// Fields combine with AND, and the choices within one field with OR: "Cohort is A or B, and Status is Confirmed".
// A field with nothing chosen matches everything. The choices are remembered per person on this device
// (localStorage, keyed by the signed in email), separately for each domain, because cohorts and modules belong to one
// domain. Everything here is pure, so the unit tests (filters.test.ts) cover it without a browser.

/** The choices of each field, by field key. A missing or empty field matches everything. */
export type FilterValues = Record<string, string[]>;

/** One choice in a field's list. The label is what people read; it defaults to the value. */
export type FilterOption = { value: string; label?: string };

/** A field of the filter bar. */
export type FilterField = { key: string; label: string; options: FilterOption[] };

/** What a field reads from an item: one value, several (such as badges), or none. */
export type Getters<T> = Record<string, (item: T) => string | readonly string[] | null | undefined>;

const asList = (v: string | readonly string[] | null | undefined): readonly string[] =>
  v == null ? [] : typeof v === 'string' ? [v] : v;

/**
 * True when the item matches every field that has choices (AND), each by any of its choices (OR). A field the
 * getters do not know is skipped, so one set of choices can be checked against class weeks and, separately, against
 * the classes inside them (Region on Upcoming classes) or the cohort columns (cohort, standard schedule and region on
 * the board).
 */
export function matches<T>(item: T, values: FilterValues, get: Getters<T>): boolean {
  for (const [key, chosen] of Object.entries(values)) {
    if (!chosen || chosen.length === 0) continue;
    const read = get[key];
    if (!read) continue;
    if (!asList(read(item)).some((v) => chosen.includes(v))) return false;
  }
  return true;
}

/** The items that match (see matches). */
export const applyFilters = <T>(items: readonly T[], values: FilterValues, get: Getters<T>): T[] =>
  items.filter((i) => matches(i, values, get));

/** The choices with one value ticked or unticked (on: true ticks, false unticks, nothing flips it). */
export function toggleValue(
  values: FilterValues,
  key: string,
  value: string,
  on?: boolean,
): FilterValues {
  const now = values[key] ?? [];
  const has = now.includes(value);
  const want = on ?? !has;
  if (want === has) return values;
  const next = want ? [...now, value] : now.filter((v) => v !== value);
  return withField(values, key, next);
}

/** The choices with one field set to exactly these values (none clears it). */
export function withField(values: FilterValues, key: string, chosen: string[]): FilterValues {
  const rest = Object.fromEntries(Object.entries(values).filter(([k]) => k !== key));
  return chosen.length ? { ...rest, [key]: [...new Set(chosen)] } : rest;
}

/** How many choices are ticked in every field together. */
export const countChosen = (values: FilterValues): number =>
  Object.values(values).reduce((n, v) => n + (v?.length ?? 0), 0);

/** True when any field has a choice. */
export const hasChoices = (values: FilterValues): boolean => countChosen(values) > 0;

/** The words of a value in a field: its option's label, or the value itself when it is not in the list now. */
export function optionLabel(field: FilterField, value: string): string {
  return field.options.find((o) => o.value === value)?.label ?? value;
}

/**
 * The list a field offers: its options, plus any value still chosen that is not among them (a cohort with no class
 * week in the weeks shown, say), so it can always be unticked.
 */
export function fieldOptions(field: FilterField, chosen: readonly string[] = []): FilterOption[] {
  const known = new Set(field.options.map((o) => o.value));
  return [...field.options, ...chosen.filter((v) => !known.has(v)).map((value) => ({ value }))];
}

/** A removable chip under the bar: one per chosen value, in the order of the fields. */
export type Chip = { key: string; field: string; value: string; label: string };
export function chipsFor(fields: readonly FilterField[], values: FilterValues): Chip[] {
  return fields.flatMap((f) =>
    (values[f.key] ?? []).map((value) => ({
      key: f.key,
      field: f.label,
      value,
      label: optionLabel(f, value),
    })),
  );
}

/** The distinct values the items have in one field, sorted, as options (labels from `label` when given). */
export function optionsFrom<T>(
  items: readonly T[],
  read: (item: T) => string | readonly string[] | null | undefined,
  label?: (value: string) => string,
): FilterOption[] {
  const seen = new Set<string>();
  for (const i of items) for (const v of asList(read(i))) seen.add(v);
  return [...seen]
    .map((value) => ({ value, label: label?.(value) ?? value }))
    .sort((a, b) => a.label.localeCompare(b.label));
}

/** Options in a fixed order (statuses and regions keep their natural order). */
export const fixedOptions = (values: readonly string[]): FilterOption[] =>
  values.map((value) => ({ value }));

// ------------------------------------------------------------------------------------ remembered choices

/** The version of the remembered choices; a newer shape gets a new number and a step in readSaved. */
export const SAVED_VERSION = 1;

/** What is kept in localStorage for one page and one person: the choices of each domain, by domain ID. */
export type SavedFilters = { version: typeof SAVED_VERSION; domains: Record<string, FilterValues> };

export const emptySaved = (): SavedFilters => ({ version: SAVED_VERSION, domains: {} });

/** The localStorage key of a page's filters for the signed in person, like the board's `board:<email>`. */
export const filtersKey = (page: 'classes' | 'board', email: string | null | undefined) =>
  `filters:${page}:${email ?? 'me'}`;

/** Only known fields, each a list of distinct strings with something in it. */
export function cleanValues(raw: unknown, keys: readonly string[]): FilterValues {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {};
  const out: FilterValues = {};
  for (const k of keys) {
    const v = (raw as Record<string, unknown>)[k];
    if (!Array.isArray(v)) continue;
    const list = [...new Set(v.filter((x): x is string => typeof x === 'string' && x !== ''))];
    if (list.length) out[k] = list;
  }
  return out;
}

/**
 * The remembered choices from what localStorage holds. Nothing saved yet, text that is not JSON, or a shape this
 * version does not know all start with nothing chosen, so a first visit and an old browser both open unfiltered.
 */
export function readSaved(raw: string | null | undefined): SavedFilters {
  if (!raw) return emptySaved();
  let v: unknown;
  try {
    v = JSON.parse(raw);
  } catch {
    return emptySaved();
  }
  if (!v || typeof v !== 'object' || (v as { version?: unknown }).version !== SAVED_VERSION)
    return emptySaved();
  const domains = (v as { domains?: unknown }).domains;
  if (!domains || typeof domains !== 'object' || Array.isArray(domains)) return emptySaved();
  return {
    version: SAVED_VERSION,
    domains: Object.fromEntries(
      Object.entries(domains as Record<string, unknown>)
        .filter(([, d]) => d && typeof d === 'object' && !Array.isArray(d))
        .map(([id, d]) => [id, d as FilterValues]),
    ),
  };
}

/** The choices remembered for one domain, keeping only the fields this page has. */
export const savedValues = (
  saved: SavedFilters,
  domainId: string | null | undefined,
  keys: readonly string[],
): FilterValues => cleanValues(saved.domains[domainId ?? ''], keys);

/** The remembered choices with one domain's choices replaced (a domain with nothing chosen is dropped). */
export function withSavedValues(
  saved: SavedFilters,
  domainId: string | null | undefined,
  values: FilterValues,
): SavedFilters {
  const id = domainId ?? '';
  const rest = Object.fromEntries(Object.entries(saved.domains).filter(([k]) => k !== id));
  return {
    version: SAVED_VERSION,
    domains: hasChoices(values) ? { ...rest, [id]: values } : rest,
  };
}
