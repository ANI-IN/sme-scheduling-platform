import type { WeekRow } from './data';

export type WeekState = {
  label: string;
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
  if (w.status === 'Cancelled') return { ...base, label: 'Cancelled', tone: 'gray' };
  if (w.status === 'Completed') return { ...base, label: 'Completed', tone: 'gray' };
  if (w.paused) return { ...base, label: 'Paused', tone: 'purple' };
  if (w.at_risk && !booking)
    return {
      ...base,
      label: askingName ? `At risk · asking ${askingName}` : 'At risk',
      tone: 'red',
    };
  if (booking)
    return {
      ...base,
      label: `Confirmed (${confirmed})${w.at_risk ? ' · at risk' : ''}`,
      tone: w.at_risk ? 'amber' : 'green',
    };
  if (askingName) return { ...base, label: `Asking (${askingName})`, tone: 'blue' };
  if (w.status === 'NeedsInstructor') return { ...base, label: 'Needs instructor', tone: 'red' };
  if (w.status === 'Ready') return { ...base, label: 'Ready', tone: 'blue' };
  return { ...base, label: 'Not ready', tone: 'amber' };
}
