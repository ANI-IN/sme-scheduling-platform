// US and India class times. Every class is stored in UTC and planned in one region:
// US classes use US Pacific time (America/Los_Angeles, PST in winter and PDT in summer),
// India classes use India time (Asia/Kolkata, IST, no daylight saving). Conversions always use
// the named time zone, never a fixed offset. The team works in India, so US class times also
// show the matching India time.
import { DateTime } from 'luxon';

export type Region = 'US' | 'India';
export const REGIONS: Region[] = ['US', 'India'];
export const TZ: Record<Region, string> = { US: 'America/Los_Angeles', India: 'Asia/Kolkata' };
export const REGION_NAME: Record<Region, string> = { US: 'US Pacific time', India: 'India time' };

export const asRegion = (r: string | null | undefined): Region => (r === 'India' ? 'India' : 'US');

const at = (iso: string, region: Region) =>
  DateTime.fromISO(iso, { zone: 'utc' }).setZone(TZ[region]);

/** PST or PDT for US (from the date), IST for India. */
export function abbrev(dt: DateTime, region: Region): string {
  if (region === 'India') return 'IST';
  return dt.offset === -420 ? 'PDT' : 'PST';
}

/** "Sun, Jan 24, 9:00 AM PST" in the class's own time zone. */
export function fmtAt(iso: string | null | undefined, region: string | null | undefined): string {
  if (!iso) return 'Not set';
  const r = asRegion(region);
  const d = at(iso, r);
  return `${d.toFormat('ccc, LLL d, h:mm a')} ${abbrev(d, r)}`;
}

/** "Sun, Jan 24, 9:00 AM to 1:00 PM PST" in the class's own time zone. */
export function fmtRange(startIso: string, endIso: string, region: Region): string {
  const s = at(startIso, region);
  const e = at(endIso, region);
  const sameDay = s.hasSame(e, 'day');
  return `${s.toFormat('ccc, LLL d, h:mm a')} to ${e.toFormat(sameDay ? 'h:mm a' : 'ccc, LLL d, h:mm a')} ${abbrev(s, region)}`;
}

/** The same class in India time, for the team: "10:30 PM to 2:30 AM IST", with the day when it differs. */
export function fmtRangeInIndia(startIso: string, endIso: string, fromRegion: Region): string {
  const local = at(startIso, fromRegion);
  const s = at(startIso, 'India');
  const e = at(endIso, 'India');
  const day = s.hasSame(local, 'day') ? '' : `${s.toFormat('ccc, LLL d')}, `;
  return `${day}${s.toFormat('h:mm a')} to ${e.toFormat(s.hasSame(e, 'day') ? 'h:mm a' : 'ccc h:mm a')} IST`;
}

/** What to show for a class: its own time, and for US classes the India time in smaller text. */
export function classTime(
  startIso: string,
  endIso: string,
  region: string | null | undefined,
): { main: string; india?: string } {
  const r = asRegion(region);
  return {
    main: fmtRange(startIso, endIso, r),
    india: r === 'US' ? fmtRangeInIndia(startIso, endIso, r) : undefined,
  };
}

/** One line for exports and plain text: "Sun, Jan 24, 9:00 AM to 1:00 PM PST (10:30 PM to 2:30 AM IST)". */
export function classTimeLine(
  startIso: string,
  endIso: string,
  region: string | null | undefined,
): string {
  const t = classTime(startIso, endIso, region);
  return t.india ? `${t.main} (${t.india})` : t.main;
}

/** Date and wall clock time in the class's region, for editing. */
export function localParts(iso: string, region: Region): { date: string; time: string } {
  const d = at(iso, region);
  return { date: d.toFormat('yyyy-LL-dd'), time: d.toFormat('HH:mm') };
}

/**
 * The real moments a local date and time stand for: none (the clocks move forward past it),
 * one, or two (the clocks move back, so it happens twice).
 */
export function localCandidates(date: string, time: string, region: Region): DateTime[] {
  const wanted = DateTime.fromISO(`${date}T${time}`, { zone: TZ[region] });
  if (!wanted.isValid) return [];
  const out: DateTime[] = [];
  for (const h of [-2, -1, 0, 1, 2]) {
    const c = wanted.toUTC().plus({ hours: h }).setZone(TZ[region]);
    if (c.toFormat('yyyy-LL-dd HH:mm') === `${date} ${time}` && !out.some((o) => o.equals(c)))
      out.push(c);
  }
  return out.sort((a, b) => a.toMillis() - b.toMillis());
}

/** "Time in US Pacific (PDT)" or "Time in India (IST)", with PST or PDT from the chosen date. */
export function timeFieldLabel(region: Region, date?: string): string {
  if (region === 'India') return 'Time in India (IST)';
  const d = date
    ? DateTime.fromISO(`${date}T12:00`, { zone: TZ.US })
    : DateTime.now().setZone(TZ.US);
  return `Time in US Pacific (${abbrev(d, 'US')})`;
}

/** A short note about the chosen time, or a problem: it does not exist, or it happens twice. */
export function timeNote(
  date: string,
  time: string,
  region: Region,
): { problem?: string; twice?: boolean } {
  if (!date || !time) return {};
  const c = localCandidates(date, time, region);
  if (c.length === 0)
    return {
      problem:
        'This time does not exist on that day in US Pacific time: the clocks move forward one hour that night. Choose another time.',
    };
  if (c.length === 2) return { twice: true };
  return {};
}

/** "Sun, Jan 24" in the class's own time zone. */
export function fmtDay(iso: string, region: string | null | undefined): string {
  return at(iso, asRegion(region)).toFormat('ccc, LLL d');
}

/** The region of a class week: the region of its first class that is not cancelled. */
export function weekRegion(
  classes: { starts_at: string; region?: string | null; status?: string }[],
): Region {
  const live = classes.filter((c) => c.status !== 'Cancelled');
  const first = [...(live.length ? live : classes)].sort((a, b) =>
    a.starts_at.localeCompare(b.starts_at),
  )[0];
  return asRegion(first?.region);
}
