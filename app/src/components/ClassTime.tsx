import { DateTime } from 'luxon';
import {
  abbrev,
  asRegion,
  classTime,
  localCandidates,
  timeNote,
  TZ,
  type Region,
} from '@/lib/region';
import { Badge, cn, Select } from './ui';

/** US or India, as a small badge. */
export function RegionBadge({ region }: { region: string | null | undefined }) {
  const r = asRegion(region);
  return (
    <Badge
      tone={r === 'India' ? 'accent' : 'neutral'}
      title={r === 'India' ? 'India time (IST)' : 'US Pacific time (PST or PDT)'}
    >
      {r}
    </Badge>
  );
}

/**
 * A class time in its own time zone ("Sun, Jan 24, 9:00 AM to 1:00 PM PST"). For US classes the
 * matching India time is shown underneath in smaller text, because the team works in India.
 */
export function ClassTime({
  start,
  end,
  region,
  cancelled,
  className,
}: {
  start: string;
  end: string;
  region: string | null | undefined;
  cancelled?: boolean;
  className?: string;
}) {
  const t = classTime(start, end, region);
  return (
    <span
      className={cn('inline-block', cancelled && 'text-muted-foreground line-through', className)}
    >
      <span className="whitespace-nowrap">{t.main}</span>
      {t.india && (
        <span className="block text-xs whitespace-nowrap text-muted-foreground">{t.india}</span>
      )}
    </span>
  );
}

/**
 * Checks a local date and time in a region. A time that does not exist (the US clocks move
 * forward past it) is shown as a problem; a time that happens twice (the US clocks move back)
 * asks which one is meant. `fold` is 1 for the first, 2 for the second.
 */
export function TimeCheck({
  date,
  times,
  region,
  fold,
  onFold,
}: {
  date: string;
  times: string[];
  region: string | null | undefined;
  fold: number | null;
  onFold: (f: number) => void;
}) {
  const r = asRegion(region);
  const notes = times.map((t) => ({ t, n: timeNote(date, t, r) }));
  const problem = notes.find((x) => x.n.problem);
  if (problem) return <p className="text-xs text-danger-strong">{problem.n.problem}</p>;
  const twice = notes.find((x) => x.n.twice);
  if (!twice) return null;
  const c = localCandidates(date, twice.t, r);
  return (
    <fieldset className="rounded-md border border-warning-strong/40 bg-warning-soft p-2 text-xs">
      <legend className="px-1 font-medium">
        {DateTime.fromISO(`${date}T${twice.t}`).toFormat('h:mm a')} happens twice on this day,
        because the US clocks move back one hour that night. Which one do you mean?
      </legend>
      {c.map((d, i) => (
        <label key={d.toMillis()} className="mt-1 flex items-center gap-2">
          <input
            type="radio"
            name={`fold-${date}-${twice.t}`}
            checked={fold === i + 1}
            onChange={() => onFold(i + 1)}
          />
          {i === 0 ? 'The first time' : 'The second time'}: {d.toFormat('h:mm a')} {abbrev(d, r)} (
          {d.setZone(TZ.India).toFormat('ccc h:mm a')} IST)
        </label>
      ))}
    </fieldset>
  );
}

/** True when the time can be saved: it exists, and if it happens twice a choice was made. */
export function timeReady(
  date: string,
  times: string[],
  region: string | null | undefined,
  fold: number | null,
) {
  const r = asRegion(region);
  return times.every((t) => {
    const n = timeNote(date, t, r);
    return !n.problem && (!n.twice || fold !== null);
  });
}

/** Choose US or India for one class. */
export function RegionSelect({
  value,
  onChange,
  label = 'Time zone for this class',
}: {
  value: string;
  onChange: (r: Region) => void;
  label?: string;
}) {
  return (
    <label className="flex flex-wrap items-center gap-2 text-sm">
      <span>{label}</span>
      <Select
        className="h-8 w-auto"
        value={asRegion(value)}
        onChange={(e) => onChange(asRegion(e.target.value))}
      >
        <option value="US">US Pacific (PST or PDT)</option>
        <option value="India">India (IST)</option>
      </Select>
    </label>
  );
}
