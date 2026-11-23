// The planned instructor of a class week (batch 4, B12): who is asked first and from when, before anyone is asked.
// The person and the day come from the database (public.planned_instructors, the same line the engine asks from);
// this file only puts them into words, so Upcoming classes, the Schedule board and Start asking now say the same.
import { DateTime } from 'luxon';
import { WEEK_STATUS } from './status';
import { asRegion, TZ } from './region';

export type PlannedPerson = {
  instructor_id: string;
  name: string;
  /** Ranking: the instructor order. Manual: a chosen list. */
  source: 'Ranking' | 'Manual';
  /** Place in the instructor order: 1 is the Primary instructor (none for a chosen list). */
  rank: number | null;
};

/** What public.planned_instructors answers for one class week. */
export type Planned = {
  module_week_id: string;
  confirmed: string | null;
  asking: string | null;
  planned: PlannedPerson | null;
  asking_starts_at: string | null;
  first_class_at: string | null;
  paused: boolean;
  at_risk: boolean;
  setup_incomplete: boolean;
  finished: boolean;
};

/** "Primary", "Backup 2" or "Chosen list". */
export function orderPlace(p: PlannedPerson): string {
  if (p.source === 'Manual') return 'Chosen list';
  if (p.rank === 1) return 'Primary';
  return p.rank ? `Backup ${p.rank - 1}` : 'Instructor order';
}

/** The words the planned person starts with: "Planned: Victor Palmer (Primary)". */
export const PLANNED_WORD = 'Planned';
export const plannedName = (p: PlannedPerson) => `${PLANNED_WORD}: ${p.name} (${orderPlace(p)})`;

/** When asking starts, in words: "asking starts Sat, Oct 31", "asking starts soon" or why not yet. */
export function askingStarts(p: Planned, now: DateTime, region?: string | null): string {
  if (p.paused) return 'requests paused';
  if (p.setup_incomplete) return 'asking starts once the setup is complete';
  const at = p.asking_starts_at ? DateTime.fromISO(p.asking_starts_at) : null;
  if (!at || !at.isValid || p.at_risk || at <= now) return 'asking starts soon';
  return `asking starts ${at.setZone(TZ[asRegion(region)]).toFormat('ccc, LLL d')}`;
}

/**
 * One line about the instructor of a class week: "Confirmed: name", then "Waiting for an answer: name" while
 * someone is asked, otherwise "Planned: name (Primary), asking starts Sat, Oct 31". Nothing for a finished week.
 */
export function plannedLine(p: Planned, now: DateTime, region?: string | null): string | null {
  if (p.confirmed) return `${WEEK_STATUS.Confirmed.word}: ${p.confirmed}`;
  if (p.asking) return `${WEEK_STATUS.Waiting.word}: ${p.asking}`;
  if (p.finished) return null;
  if (!p.planned) return 'Nobody left to ask';
  return `${plannedName(p.planned)}, ${askingStarts(p, now, region)}`;
}

/** Why Start asking now does nothing for a class week, or nothing when it can start. */
export function cannotStart(p: Planned): string | null {
  if (p.finished) return 'It is over or cancelled.';
  if (p.confirmed) return `${p.confirmed} is already confirmed.`;
  if (p.asking) return `${p.asking} is already being asked.`;
  if (!p.planned) return 'Nobody in its order can be asked.';
  return null;
}
