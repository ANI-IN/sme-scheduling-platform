import type { WeekRow } from './data';

type StatusTone = 'success' | 'warning' | 'danger' | 'accent' | 'neutral';

/**
 * The one set of status words for a class week (docs/GLOSSARY.md), by the code the Schedule board's data uses
 * (private.board_status). The board, its side panel and Legend, Upcoming classes, Instructor requests, Home, the
 * filters and the spreadsheet downloads all show these words and no others. The database keeps its own status codes
 * (module_week.status: Planned, NotReady, Ready, Asking, NeedsInstructor and so on); only what people read is here.
 */
export const WEEK_STATUS = {
  Confirmed: { word: 'Confirmed', tone: 'success' },
  Waiting: { word: 'Waiting for an answer', tone: 'warning' },
  'Needs instructor': { word: 'Needs instructor', tone: 'danger' },
  'Proposed time': { word: 'Proposed time', tone: 'accent' },
  'Not asked yet': { word: 'Not asked yet', tone: 'neutral' },
  'Setup incomplete': { word: 'Setup incomplete', tone: 'neutral' },
  Paused: { word: 'Paused', tone: 'neutral' },
  Cancelled: { word: 'Cancelled', tone: 'neutral' },
  Completed: { word: 'Completed', tone: 'neutral' },
} as const satisfies Record<string, { word: string; tone: StatusTone }>;
export type WeekStatus = keyof typeof WEEK_STATUS;
/** The status word of a class week, as people read it. */
export type WeekKind = (typeof WEEK_STATUS)[WeekStatus]['word'];
/** The status words in their natural order, for filters. */
export const WEEK_KINDS: WeekKind[] = Object.values(WEEK_STATUS).map((s) => s.word);
/** A week with no class week because the cohort has a break. */
export const BREAK_WORD = 'Break';
/** Not a status: a flag on a class week that may not have an instructor in time (a filter and a badge). */
export const AT_RISK = 'At risk';
/** The status badge of a confirmed class week that is at risk. */
export const CONFIRMED_AT_RISK = 'Confirmed, at risk';

export type WeekState = {
  status: WeekStatus;
  /** The status word without names (filters). */
  kind: WeekKind;
  /** The status word with the instructor's name, for spreadsheet downloads. */
  label: string;
  /** The badge text without names, shown next to an Instructor column. */
  short: string;
  tone: StatusTone;
  /** Who is being asked now and has not answered yet. */
  asking: string | null;
  confirmed: string | null;
  atRisk: boolean;
  /** Taught together with another cohort's class week (its host), whose instructor is shown. */
  shared: boolean;
};

const OPEN = ['Queued', 'Sent', 'Reminded'];

/** Every class week by its ID, so a shared class week can show its host's status. */
export const weeksById = (weeks: WeekRow[] | undefined) =>
  new Map((weeks ?? []).map((w) => [w.id, w] as const));

/**
 * The status of a class week, in the same order as the Schedule board (private.board_status). A class week taught
 * in another cohort's class takes its instructor and requests from that class week (pass every week by ID).
 */
export function weekState(
  w: WeekRow,
  names: Map<string, string>,
  byId?: Map<string, WeekRow>,
): WeekState {
  const src = (w.shared_with && byId?.get(w.shared_with)) || w;
  const booking = src.booking.find((b) => b.status === 'Active') ?? null;
  const request = src.request.find((r) => r.kind === 'Outreach' && OPEN.includes(r.status)) ?? null;
  const proposal = src.time_proposal.some((p) => p.status === 'Pending');
  const confirmed = booking ? (names.get(booking.instructor_id) ?? '?') : null;
  const asking = request?.instructor_id ? (names.get(request.instructor_id) ?? '?') : null;
  const status: WeekStatus =
    w.status === 'Cancelled'
      ? 'Cancelled'
      : w.status === 'Completed'
        ? 'Completed'
        : booking
          ? 'Confirmed'
          : proposal
            ? 'Proposed time'
            : asking
              ? 'Waiting'
              : w.status === 'NeedsInstructor' || w.at_risk
                ? 'Needs instructor'
                : w.paused && !w.shared_with
                  ? 'Paused'
                  : w.status === 'NotReady'
                    ? 'Setup incomplete'
                    : 'Not asked yet';
  const { word, tone } = WEEK_STATUS[status];
  const who = status === 'Confirmed' ? confirmed : status === 'Waiting' ? asking : null;
  const risky = status === 'Confirmed' && w.at_risk;
  return {
    status,
    kind: word,
    label: `${word}${who ? ` (${who})` : ''}${w.at_risk && status !== 'Cancelled' ? `, ${AT_RISK.toLowerCase()}` : ''}`,
    short: risky ? CONFIRMED_AT_RISK : word,
    tone: risky ? 'warning' : tone,
    asking,
    confirmed,
    atRisk: w.at_risk,
    shared: !!w.shared_with,
  };
}
