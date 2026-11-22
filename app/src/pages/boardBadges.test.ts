/// <reference types="node" />
// The Legend on the Schedule board explains every badge the board and its side panel can show (Release 3 review,
// item 6). The words come from boardBadges.ts, which the board, the side panel and the Legend all use.
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { WeekRow } from '@/lib/data';
import { WEEK_KINDS, weekState, weeksById } from '@/lib/status';
import { BADGE, STATUS, decisionLabel, legendGroups, renderableLabels } from './boardBadges';

const MIGRATIONS = join(__dirname, '..', '..', '..', 'supabase', 'migrations');
const sqlFiles = readdirSync(MIGRATIONS)
  .filter((f) => f.endsWith('.sql'))
  .sort()
  .map((f) => readFileSync(join(MIGRATIONS, f), 'utf8'));

/**
 * Problem codes the database makes that never reach a board cell's badges, each with the reason. A new code that is
 * neither here nor in BADGE fails the test below, so it cannot reach the board without words and a Legend sentence.
 */
const NOT_ON_THE_BOARD: Record<string, string> = {
  short_notice: 'week_problems leaves it out',
  no_classes: 'a setup check before asking, shown as Setup incomplete',
  module_inactive: 'a setup check before asking, shown as Setup incomplete',
  no_owner: 'a setup check before asking, shown as Setup incomplete',
  no_instructor: 'a setup check before asking, shown as Setup incomplete',
  no_resources: 'a setup check before asking',
  asked_clash: 'a warning in the standard schedule preview only',
  primary_busy: 'a note in the standard schedule preview only',
  different_modules: 'a warning in the share dialog only',
  merge_check: 'a warning in the merge dialog only',
  merge_conflict: 'a warning in the merge dialog only',
};

describe('Schedule board legend', () => {
  const items = legendGroups().flatMap((g) => g.items);
  const legend = new Set(items.map((i) => i.label));

  it('has an entry for every badge the board and its side panel can render', () => {
    const missing = [...new Set(renderableLabels())].filter((l) => !legend.has(l));
    expect(missing).toEqual([]);
  });

  it('names every badge the task list asks for', () => {
    for (const label of [
      'Answer due soon',
      'Help request open',
      'Declined or no reply before',
      'Clash',
      'Shared class',
      'Merged into',
      'Moved',
      'Holiday',
      'Extra class',
      'Custom',
      'Message failed',
      'Sooner class first',
      'Break',
    ])
      expect(legend, label).toContain(label);
  });

  it('shows each label once', () => {
    expect(items.length).toBe(legend.size);
  });

  it('explains each badge in one short plain sentence', () => {
    for (const i of items) {
      const where = `${i.label}: ${i.text}`;
      expect(i.text, where).toMatch(/^[A-Z][^.!?]*\.$/);
      expect(i.text.split(' ').length, where).toBeLessThanOrEqual(20);
      expect(i.text, where).not.toMatch(/[‐‑‒–—―]|\w-\w| - |\be\.g\./i);
    }
  });

  it('has words for every badge code the database can put on a cell', () => {
    const codes = new Set<string>();
    for (const sql of sqlFiles) {
      for (const m of sql.matchAll(/jsonb_build_object\('code', '([a-z_]+)'/g)) codes.add(m[1]!);
    }
    // The badges schedule_board adds on top of the problems (the latest definition counts).
    const board = sqlFiles.filter((s) => s.includes('function public.schedule_board(')).at(-1)!;
    for (const m of board.matchAll(/select '([a-z_]+)' where/g)) codes.add(m[1]!);
    expect(codes.size).toBeGreaterThan(20);
    const missing = [...codes].filter((c) => !(c in BADGE) && !(c in NOT_ON_THE_BOARD));
    expect(missing).toEqual([]);
  });

  it('counts in Needs a decision use the badge or status words', () => {
    expect(decisionLabel('clash')).toBe('Clash');
    expect(decisionLabel('needs_instructor')).toBe('Needs instructor');
    expect(decisionLabel('proposed_time')).toBe('Proposed time');
  });
});

/** The status words of a class week, everywhere a person sees them (owner's item 1), in this order. */
const STATUS_WORDS = [
  'Confirmed',
  'Waiting for an answer',
  'Needs instructor',
  'Proposed time',
  'Not asked yet',
  'Setup incomplete',
  'Paused',
  'Cancelled',
  'Completed',
  'Break',
];
/** Words for the same states that are not used any more (docs/GLOSSARY.md). */
const OLD_WORDS = [
  'Asking',
  'Asking now',
  'Being asked',
  'Ready to ask',
  'Not started yet',
  'Setup not finished',
  'Needs an instructor',
  'Requests paused',
  'Waiting for a reply',
];

describe('class week status words', () => {
  it('the Legend lists exactly the agreed statuses, in order', () => {
    const statuses = legendGroups().find((g) => g.title === 'Statuses')!;
    expect(statuses.items.map((i) => i.label)).toEqual(STATUS_WORDS);
    expect(WEEK_KINDS).toEqual(STATUS_WORDS.slice(0, -1));
    expect(Object.values(STATUS).map((s) => s.word)).toEqual(STATUS_WORDS.slice(0, -1));
  });

  it('no badge or Legend entry uses an old status word', () => {
    const shown = new Set([
      ...renderableLabels(),
      ...legendGroups().flatMap((g) => g.items.map((i) => i.label)),
    ]);
    for (const old of OLD_WORDS) expect(shown, old).not.toContain(old);
  });
});

describe('weekState', () => {
  const names = new Map([
    ['i1', 'Priya'],
    ['i2', 'Sam'],
  ]);
  const week = (over: Record<string, unknown> = {}) =>
    ({
      id: 'w1',
      status: 'Ready',
      at_risk: false,
      paused: false,
      shared_with: null,
      booking: [],
      request: [],
      time_proposal: [],
      ...over,
    }) as unknown as WeekRow;
  const asked = [{ kind: 'Outreach', status: 'Sent', instructor_id: 'i1' }];
  const booked = [{ status: 'Active', instructor_id: 'i2' }];
  const kind = (over: Record<string, unknown>) => weekState(week(over), names).kind;

  it('gives every database status the agreed word', () => {
    expect(kind({ status: 'Planned' })).toBe('Not asked yet');
    expect(kind({ status: 'Ready' })).toBe('Not asked yet');
    expect(kind({ status: 'NotReady' })).toBe('Setup incomplete');
    expect(kind({ status: 'NeedsInstructor' })).toBe('Needs instructor');
    expect(kind({ status: 'Ready', at_risk: true })).toBe('Needs instructor');
    expect(kind({ status: 'Asking', request: asked })).toBe('Waiting for an answer');
    expect(kind({ status: 'Asking', request: asked, time_proposal: [{ status: 'Pending' }] })).toBe(
      'Proposed time',
    );
    expect(kind({ status: 'Confirmed', booking: booked })).toBe('Confirmed');
    expect(kind({ status: 'Ready', paused: true })).toBe('Paused');
    expect(kind({ status: 'Cancelled', booking: booked })).toBe('Cancelled');
    expect(kind({ status: 'Completed', booking: booked })).toBe('Completed');
  });

  it('names the instructor in the download words, and keeps at risk as a flag', () => {
    const waiting = weekState(week({ status: 'Asking', request: asked }), names);
    expect(waiting.label).toBe('Waiting for an answer (Priya)');
    expect(waiting.asking).toBe('Priya');
    const risky = weekState(week({ status: 'Confirmed', booking: booked, at_risk: true }), names);
    expect(risky.label).toBe('Confirmed (Sam), at risk');
    expect(risky.short).toBe('Confirmed, at risk');
    expect(risky.atRisk).toBe(true);
  });

  it('shows a shared class week with the status of the class week it is taught in', () => {
    const host = week({ id: 'h1', status: 'Confirmed', booking: booked });
    const guest = week({ id: 'g1', shared_with: 'h1', paused: true });
    const st = weekState(guest, names, weeksById([host, guest]));
    expect(st.kind).toBe('Confirmed');
    expect(st.confirmed).toBe('Sam');
    expect(st.shared).toBe(true);
  });
});
