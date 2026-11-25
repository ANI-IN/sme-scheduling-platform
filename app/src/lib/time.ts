import { DateTime } from 'luxon';

export const PT = 'America/Los_Angeles';

const toDt = (iso: string, zone: string) => DateTime.fromISO(iso, { zone: 'utc' }).setZone(zone);

/** "Sun Jan 31, 9:00 AM PST": a time shown in US Pacific. India classes also show India time (lib/region.ts). */
export function fmtPT(iso: string | null | undefined): string {
  if (!iso) return 'Not set';
  return toDt(iso, PT).toFormat('ccc LLL d, h:mm a ZZZZ');
}

/** "Sun Jan 31, 9:00 AM – 1:00 PM PST" */
export function fmtPTRange(startIso: string, endIso: string): string {
  const s = toDt(startIso, PT);
  const e = toDt(endIso, PT);
  return `${s.toFormat('ccc LLL d, h:mm a')} to ${e.toFormat('h:mm a ZZZZ')}`;
}

/** Date and wall-clock parts in PT, for editing. */
export function ptParts(iso: string): { date: string; time: string } {
  const d = toDt(iso, PT);
  return { date: d.toFormat('yyyy-LL-dd'), time: d.toFormat('HH:mm') };
}

/** History and system times: the viewer's local time zone, labelled. */
export function fmtLocal(iso: string | null | undefined): string {
  if (!iso) return 'Not set';
  const d = DateTime.fromISO(iso).toLocal();
  // Browsers label India time as "GMT+5:30"; the team knows it as IST.
  const zone = d.offset === 330 ? 'IST' : d.offsetNameShort;
  return `${d.toFormat('ccc LLL d, h:mm a')} ${zone}`;
}

/** "3h", "2d" since a time. */
export function ago(iso: string | null | undefined, now: DateTime = DateTime.now()): string {
  if (!iso) return '';
  const mins = Math.max(0, Math.round(now.diff(DateTime.fromISO(iso), 'minutes').minutes));
  const n = (v: number, unit: string) => `${v} ${unit}${v === 1 ? '' : 's'}`;
  if (mins < 1) return 'less than a minute';
  if (mins < 60) return n(mins, 'minute');
  const h = Math.round(mins / 60);
  if (h < 48) return n(h, 'hour');
  return n(Math.round(h / 24), 'day');
}

/** Sundays starting at firstSunday (yyyy-mm-dd), for `weeks` weeks. */
export function weeklyDates(firstSunday: string, weeks: number): string[] {
  const start = DateTime.fromISO(firstSunday);
  return Array.from({ length: weeks }, (_, i) => start.plus({ weeks: i }).toISODate()!);
}

const DATE_FORMATS = [
  'yyyy-LL-dd',
  'L/d/yyyy',
  'LL/dd/yyyy',
  'LLL d yyyy',
  'LLL d, yyyy',
  'd LLL yyyy',
  'ccc LLL d yyyy',
  'ccc, LLL d, yyyy',
];

/** Parse a pasted list of dates (one per line or comma/semicolon separated). */
export function parseDateList(text: string): { dates: string[]; bad: string[] } {
  const dates: string[] = [];
  const bad: string[] = [];
  const parts = text
    .split(/[\n;]+|,(?!\s*\d{4})/)
    .map((s) => s.trim())
    .filter(Boolean);
  for (const raw of parts) {
    const parsed =
      DATE_FORMATS.map((f) => DateTime.fromFormat(raw, f)).find((d) => d.isValid) ??
      DateTime.fromISO(raw);
    if (parsed.isValid) dates.push(parsed.toISODate()!);
    else bad.push(raw);
  }
  return { dates: [...new Set(dates)].sort(), bad };
}

export function isSunday(isoDate: string): boolean {
  return DateTime.fromISO(isoDate).weekday === 7;
}
