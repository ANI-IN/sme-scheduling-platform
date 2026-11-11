import type { WeekRow } from './data';

/** The status of a class week without any names, for filters. */
export const WEEK_KINDS = [
  'Not started yet',
  'Setup not finished',
  'Ready to ask',
  'Asking',
  'Needs an instructor',
  'At risk',
  'Confirmed',
  'Requests paused',
  'Completed',
  'Cancelled',
] as const;
export type WeekKind = (typeof WEEK_KINDS)[number];

export type WeekState = {
  label: string;
  /** The status without names (filters). */
  kind: WeekKind;
  /** The badge text without names, shown next to an Instructor column. */
  short: string;
  tone: 'gray' | 'blue' | 'green' | 'amber' | 'red' | 'purple';
  asking: string | null;
  confirmed: string | null;
  atRisk: boolean;
};

const OPEN = ['Queued', 'Sent', 'Reminded'];

/** Outreach status shown in the Schedule grid and Outreach tab (PRD 7.4). */
export function weekState(w: WeekRow, names: Map<string, string>): WeekState {
  const booking = w.booking.find((b) => b.status === 'Active') ?? null;
  const asking = w.request.find((r) => r.kind === 'Outreach' && OPEN.includes(r.status)) ?? null;
  const confirmed = booking ? (names.get(booking.instructor_id) ?? '?') : null;
  const askingName = asking?.instructor_id ? (names.get(asking.instructor_id) ?? '?') : null;
  const base = { asking: askingName, confirmed, atRisk: w.at_risk };
  const same = (kind: WeekKind, tone: WeekState['tone']): WeekState => ({
    ...base,
    label: kind,
    kind,
    short: kind,
    tone,
  });
  if (w.status === 'Cancelled') return same('Cancelled', 'gray');
  if (w.status === 'Completed') return same('Completed', 'gray');
  if (w.paused) return same('Requests paused', 'purple');
  if (w.at_risk && !booking)
    return {
      ...base,
      label: askingName ? `At risk · asking ${askingName}` : 'At risk',
      kind: 'At risk',
      short: 'At risk',
      tone: 'red',
    };
  if (booking)
    return {
      ...base,
      label: `Confirmed (${confirmed})${w.at_risk ? ' · at risk' : ''}`,
      kind: 'Confirmed',
      short: w.at_risk ? 'Confirmed, at risk' : 'Confirmed',
      tone: w.at_risk ? 'amber' : 'green',
    };
  if (askingName)
    return {
      ...base,
      label: `Asking (${askingName})`,
      kind: 'Asking',
      short: 'Asking',
      tone: 'blue',
    };
  if (w.status === 'NeedsInstructor') return same('Needs an instructor', 'red');
  if (w.status === 'Ready') return same('Ready to ask', 'blue');
  if (w.status === 'NotReady') return same('Setup not finished', 'amber');
  return same('Not started yet', 'gray');
}
