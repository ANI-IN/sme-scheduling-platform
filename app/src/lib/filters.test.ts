import { describe, expect, it } from 'vitest';
import {
  SAVED_VERSION,
  applyFilters,
  chipsFor,
  cleanValues,
  countChosen,
  emptySaved,
  fieldOptions,
  filtersKey,
  fixedOptions,
  hasChoices,
  matches,
  optionsFrom,
  readSaved,
  savedValues,
  toggleValue,
  withField,
  withSavedValues,
  type FilterField,
  type Getters,
} from './filters';

type Week = { cohort: string; status: string; region: string; badges: string[] };
const weeks: Week[] = [
  { cohort: 'A', status: 'Confirmed', region: 'US', badges: [] },
  { cohort: 'A', status: 'Needs instructor', region: 'India', badges: ['clash'] },
  { cohort: 'B', status: 'Confirmed', region: 'India', badges: ['clash', 'holiday'] },
  { cohort: 'C', status: 'Waiting for an answer', region: 'US', badges: ['message_failed'] },
];
const get: Getters<Week> = {
  cohort: (w) => w.cohort,
  status: (w) => w.status,
  region: (w) => w.region,
  badge: (w) => w.badges,
};
const cohorts = (ws: Week[]) => ws.map((w) => `${w.cohort} ${w.status}`);

describe('matching', () => {
  it('nothing chosen matches everything', () => {
    expect(applyFilters(weeks, {}, get)).toEqual(weeks);
    expect(applyFilters(weeks, { cohort: [] }, get)).toEqual(weeks);
  });

  it('choices within one field are OR', () => {
    expect(cohorts(applyFilters(weeks, { cohort: ['A', 'C'] }, get))).toEqual([
      'A Confirmed',
      'A Needs instructor',
      'C Waiting for an answer',
    ]);
  });

  it('fields are AND', () => {
    expect(
      cohorts(applyFilters(weeks, { cohort: ['A', 'B'], status: ['Confirmed'] }, get)),
    ).toEqual(['A Confirmed', 'B Confirmed']);
    expect(
      cohorts(
        applyFilters(weeks, { cohort: ['A'], status: ['Confirmed'], region: ['India'] }, get),
      ),
    ).toEqual([]);
  });

  it('a field with several values per item (badges) matches when any of them is chosen', () => {
    expect(cohorts(applyFilters(weeks, { badge: ['holiday', 'message_failed'] }, get))).toEqual([
      'B Confirmed',
      'C Waiting for an answer',
    ]);
    expect(cohorts(applyFilters(weeks, { badge: ['clash'], region: ['India'] }, get))).toEqual([
      'A Needs instructor',
      'B Confirmed',
    ]);
  });

  it('an item with no value in a chosen field does not match', () => {
    const g: Getters<Week> = { ...get, instructor: () => null };
    expect(matches(weeks[0]!, { instructor: ['Ann'] }, g)).toBe(false);
  });

  it('a field the getters do not know is skipped (checked elsewhere, such as each class)', () => {
    const onlyCohort: Getters<Week> = { cohort: (w) => w.cohort };
    expect(matches(weeks[0]!, { cohort: ['A'], region: ['India'] }, onlyCohort)).toBe(true);
    expect(matches(weeks[0]!, { cohort: ['B'], region: ['US'] }, onlyCohort)).toBe(false);
  });
});

describe('changing the choices', () => {
  it('ticks, unticks and flips one value', () => {
    let v = toggleValue({}, 'cohort', 'A');
    expect(v).toEqual({ cohort: ['A'] });
    v = toggleValue(v, 'cohort', 'B', true);
    expect(v).toEqual({ cohort: ['A', 'B'] });
    expect(toggleValue(v, 'cohort', 'B', true)).toBe(v);
    v = toggleValue(v, 'cohort', 'A');
    expect(v).toEqual({ cohort: ['B'] });
    // The last value of a field removes the field, so nothing is left behind.
    expect(toggleValue(v, 'cohort', 'B', false)).toEqual({});
  });

  it('sets or clears one field and leaves the others', () => {
    const v = { cohort: ['A'], status: ['Confirmed'] };
    expect(withField(v, 'cohort', ['B', 'B', 'C'])).toEqual({
      cohort: ['B', 'C'],
      status: ['Confirmed'],
    });
    expect(withField(v, 'cohort', [])).toEqual({ status: ['Confirmed'] });
  });

  it('counts the choices', () => {
    expect(countChosen({})).toBe(0);
    expect(hasChoices({ cohort: [] })).toBe(false);
    expect(countChosen({ cohort: ['A', 'B'], status: ['Confirmed'] })).toBe(3);
    expect(hasChoices({ status: ['Confirmed'] })).toBe(true);
  });
});

describe('options and chips', () => {
  const field: FilterField = {
    key: 'badge',
    label: 'Badge',
    options: [
      { value: 'clash', label: 'Clash' },
      { value: 'holiday', label: 'Holiday' },
    ],
  };

  it('a chosen value missing from the list is still offered, so it can be unticked', () => {
    expect(fieldOptions(field, ['holiday', 'gone']).map((o) => o.value)).toEqual([
      'clash',
      'holiday',
      'gone',
    ]);
  });

  it('chips follow the field order and read the option label', () => {
    const status: FilterField = { key: 'status', label: 'Status', options: [] };
    expect(chipsFor([status, field], { badge: ['clash', 'gone'], status: ['Paused'] })).toEqual([
      { key: 'status', field: 'Status', value: 'Paused', label: 'Paused' },
      { key: 'badge', field: 'Badge', value: 'clash', label: 'Clash' },
      { key: 'badge', field: 'Badge', value: 'gone', label: 'gone' },
    ]);
  });

  it('options from the data are distinct and sorted by label; fixed options keep their order', () => {
    expect(
      optionsFrom(
        weeks,
        (w) => w.badges,
        (v) => v.toUpperCase(),
      ),
    ).toEqual([
      { value: 'clash', label: 'CLASH' },
      { value: 'holiday', label: 'HOLIDAY' },
      { value: 'message_failed', label: 'MESSAGE_FAILED' },
    ]);
    expect(fixedOptions(['US', 'India'])).toEqual([{ value: 'US' }, { value: 'India' }]);
  });
});

describe('remembered choices', () => {
  const keys = ['cohort', 'status'];

  it('each page has its own key per signed in person', () => {
    expect(filtersKey('classes', 'ops@example.com')).toBe('filters:classes:ops@example.com');
    expect(filtersKey('board', 'ops@example.com')).toBe('filters:board:ops@example.com');
    expect(filtersKey('board', undefined)).toBe('filters:board:me');
  });

  it('nothing saved yet starts with nothing chosen', () => {
    expect(readSaved(null)).toEqual(emptySaved());
    expect(readSaved(undefined)).toEqual(emptySaved());
    expect(readSaved('')).toEqual(emptySaved());
    expect(savedValues(readSaved(null), 'd1', keys)).toEqual({});
  });

  it('broken or unknown saved text starts with nothing chosen', () => {
    for (const raw of [
      'not json',
      'null',
      '[]',
      '{"cohort":["A"]}',
      `{"version":${SAVED_VERSION + 1},"domains":{"d1":{"cohort":["A"]}}}`,
      `{"version":${SAVED_VERSION},"domains":[]}`,
    ])
      expect(readSaved(raw), raw).toEqual(emptySaved());
  });

  it('keeps the shape { version, domains: { domain ID: { field: values } } }', () => {
    let s = withSavedValues(emptySaved(), 'd1', { cohort: ['A'], status: ['Confirmed'] });
    s = withSavedValues(s, 'd2', { cohort: ['X'] });
    expect(s).toEqual({
      version: 1,
      domains: { d1: { cohort: ['A'], status: ['Confirmed'] }, d2: { cohort: ['X'] } },
    });
    const back = readSaved(JSON.stringify(s));
    expect(savedValues(back, 'd1', keys)).toEqual({ cohort: ['A'], status: ['Confirmed'] });
    expect(savedValues(back, 'd2', keys)).toEqual({ cohort: ['X'] });
    expect(savedValues(back, 'd3', keys)).toEqual({});
  });

  it('a domain with nothing chosen is dropped', () => {
    const s = withSavedValues(emptySaved(), 'd1', { cohort: ['A'] });
    expect(withSavedValues(s, 'd1', {})).toEqual(emptySaved());
  });

  it('reads only the fields of the page, as distinct strings', () => {
    expect(
      cleanValues(
        { cohort: ['A', 'A', 3, '', 'B'], status: 'Confirmed', other: ['x'], region: [] },
        [...keys, 'region'],
      ),
    ).toEqual({ cohort: ['A', 'B'] });
    expect(cleanValues(null, keys)).toEqual({});
    expect(cleanValues(['A'], keys)).toEqual({});
    const s = readSaved(
      JSON.stringify({ version: 1, domains: { d1: { cohort: ['A'], badge: ['clash'] }, d2: 5 } }),
    );
    expect(savedValues(s, 'd1', keys)).toEqual({ cohort: ['A'] });
    expect(s.domains.d2).toBeUndefined();
  });
});
