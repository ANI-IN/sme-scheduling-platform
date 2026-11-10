import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { DateTime } from 'luxon';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { useModules, type Domain } from '@/lib/data';
import { isSunday, parseDateList, weeklyDates } from '@/lib/time';
import {
  Badge,
  Button,
  ErrorText,
  Field,
  Input,
  Modal,
  Select,
  Textarea,
  td,
  th,
} from '@/components/ui';

type ProposedClass = {
  pattern_item_id: string;
  class_type: string;
  title: string;
  date: string;
  start_time: string;
  end_time: string;
  holiday: string | null;
};
type ProposedWeek = {
  week_start_date: string;
  module_id: string;
  module_name: string;
  cohort: string;
  classes: ProposedClass[];
  duplicate: boolean;
  holidays: string[];
};

const shiftDate = (d: string, weeks: number) => DateTime.fromISO(d).plus({ weeks }).toISODate()!;

/** Plan classes (PRD 7.4 generator, SCH-1/4/5): propose → review/edit → create. */
export function PlanDialog({ domain, onClose }: { domain: Domain; onClose: () => void }) {
  const qc = useQueryClient();
  const modules = useModules(domain.id);
  const active = (modules.data ?? []).filter((m) => m.status === 'Active');
  const holidays = useQuery({
    queryKey: ['holiday'],
    queryFn: async () => check(await supabase.from('holiday').select('*').order('date')),
  });
  const [startModule, setStartModule] = useState('');
  const [mode, setMode] = useState<'weeks' | 'list'>('weeks');
  const [first, setFirst] = useState('');
  const [weeks, setWeeks] = useState(10);
  const [list, setList] = useState('');
  const [cohort, setCohort] = useState('');
  const [rows, setRows] = useState<ProposedWeek[] | null>(null);
  const [err, setErr] = useState<unknown>(null);
  const [saving, setSaving] = useState(false);
  const holidayOn = (d: string) => holidays.data?.find((h) => h.date === d)?.name ?? null;

  async function propose() {
    setErr(null);
    try {
      let dates: string[];
      if (mode === 'weeks') {
        if (!first) throw new Error('Choose the first Sunday.');
        if (!isSunday(first))
          throw new Error('The first date must be a Sunday (the start of the class week).');
        dates = weeklyDates(first, weeks);
      } else {
        const parsed = parseDateList(list);
        if (parsed.bad.length)
          throw new Error(`These dates couldn’t be read: ${parsed.bad.join(', ')}`);
        const notSunday = parsed.dates.filter((d) => !isSunday(d));
        if (notSunday.length) throw new Error(`These are not Sundays: ${notSunday.join(', ')}`);
        dates = parsed.dates;
      }
      if (dates.length === 0) throw new Error('No dates to plan.');
      const res = (await rpc('generate_classes', {
        p_domain_id: domain.id,
        p_start_module_id: startModule || active[0]?.id || '',
        p_week_starts: dates,
        p_cohort: cohort.trim(),
      })) as unknown as ProposedWeek[];
      setRows(res);
    } catch (e) {
      setErr(e);
    }
  }

  // "Shift this and all later classes by 1 week" for holiday weeks.
  const shiftFrom = (idx: number) =>
    setRows((r) =>
      r!.map((w, j) =>
        j < idx
          ? w
          : {
              ...w,
              week_start_date: shiftDate(w.week_start_date, 1),
              classes: w.classes.map((c) => {
                const date = shiftDate(c.date, 1);
                return { ...c, date, holiday: holidayOn(date) };
              }),
              holidays: [],
            },
      ),
    );

  const setModule = (idx: number, moduleId: string) =>
    setRows((r) =>
      r!.map((w, j) => {
        if (j !== idx) return w;
        const m = active.find((x) => x.id === moduleId)!;
        return {
          ...w,
          module_id: m.id,
          module_name: m.name,
          classes: [...m.class_pattern_item]
            .sort((a, b) => a.weekday_offset - b.weekday_offset)
            .map((p) => {
              const date = DateTime.fromISO(w.week_start_date)
                .plus({ days: p.weekday_offset })
                .toISODate()!;
              const start = DateTime.fromFormat(p.start_time_pt.slice(0, 5), 'HH:mm');
              return {
                pattern_item_id: p.id,
                class_type: p.class_type,
                title: p.title_template
                  .replace('{module}', m.name)
                  .replace('{class_type}', p.class_type),
                date,
                start_time: start.toFormat('HH:mm'),
                end_time: start.plus({ minutes: p.duration_minutes }).toFormat('HH:mm'),
                holiday: holidayOn(date),
              };
            }),
        };
      }),
    );

  const editClass = (wi: number, ci: number, patch: Partial<ProposedClass>) =>
    setRows((r) =>
      r!.map((w, j) =>
        j !== wi
          ? w
          : { ...w, classes: w.classes.map((c, k) => (k === ci ? { ...c, ...patch } : c)) },
      ),
    );

  async function create() {
    setSaving(true);
    setErr(null);
    try {
      const res = (await rpc('create_module_weeks', {
        p_domain_id: domain.id,
        p_rows: rows!.map((w) => ({
          module_id: w.module_id,
          week_start_date: w.week_start_date,
          cohort: w.cohort,
          classes: w.classes,
        })),
      })) as { created: number };
      toast.success(`Created ${res.created} class week${res.created === 1 ? '' : 's'}`);
      await qc.invalidateQueries();
      onClose();
    } catch (e) {
      setErr(e);
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal
      open
      onOpenChange={(o) => !o && onClose()}
      title="Plan classes"
      description="Times are Pacific. Nothing is saved until you press Create."
      wide
    >
      {!rows ? (
        <div className="space-y-3">
          <Field
            label="Start with this module"
            hint="The other modules follow in their usual order."
          >
            <Select value={startModule} onChange={(e) => setStartModule(e.target.value)}>
              {active.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.rotation_order}. {m.name}
                </option>
              ))}
            </Select>
          </Field>
          <div className="flex gap-4 text-sm">
            <label className="flex items-center gap-1">
              <input type="radio" checked={mode === 'weeks'} onChange={() => setMode('weeks')} />{' '}
              First Sunday and number of weeks
            </label>
            <label className="flex items-center gap-1">
              <input type="radio" checked={mode === 'list'} onChange={() => setMode('list')} />{' '}
              Paste a list of dates
            </label>
          </div>
          {mode === 'weeks' ? (
            <div className="flex gap-3">
              <Field label="First Sunday">
                <Input type="date" value={first} onChange={(e) => setFirst(e.target.value)} />
              </Field>
              <Field label="Number of weeks">
                <Input
                  type="number"
                  min={1}
                  max={104}
                  value={weeks}
                  onChange={(e) => setWeeks(Number(e.target.value))}
                />
              </Field>
            </div>
          ) : (
            <Field
              label="Sundays from the official schedule"
              hint="One per line, for example 1/3/2027 or Jan 3, 2027"
            >
              <Textarea
                value={list}
                onChange={(e) => setList(e.target.value)}
                className="min-h-32"
              />
            </Field>
          )}
          <Field
            label="Cohort name (optional)"
            hint="Only needed when two runs of the same module happen in the same week."
          >
            <Input value={cohort} onChange={(e) => setCohort(e.target.value)} />
          </Field>
          <ErrorText error={err} />
          <Button onClick={propose} disabled={active.length === 0}>
            Show proposed classes
          </Button>
          {active.length === 0 && (
            <p className="text-sm text-muted-foreground">
              First add a module that is in use and has class times (Setup, Modules).
            </p>
          )}
        </div>
      ) : (
        <div className="space-y-3">
          <div className="max-h-[60vh] overflow-auto rounded-lg border border-border">
            <table className="w-full">
              <thead className="sticky top-0 z-10 bg-muted">
                <tr>
                  <th className={th}>Week starting</th>
                  <th className={th}>Module</th>
                  <th className={th}>Classes (Pacific)</th>
                  <th className={th}>
                    <span className="sr-only">Actions</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {rows.map((w, wi) => {
                  const holiday = w.classes.some((c) => c.holiday) || w.holidays.length > 0;
                  return (
                    <tr
                      key={wi}
                      className={
                        holiday
                          ? 'border-t border-border bg-warning-soft'
                          : w.duplicate
                            ? 'border-t border-border bg-danger-soft'
                            : 'border-t border-border'
                      }
                    >
                      <td className={td}>
                        {w.week_start_date}
                        {w.duplicate && <Badge tone="danger">Already planned</Badge>}
                        {w.holidays.map((h) => (
                          <Badge key={h} tone="warning">
                            {h}
                          </Badge>
                        ))}
                      </td>
                      <td className={td}>
                        <Select
                          aria-label="Module"
                          value={w.module_id}
                          onChange={(e) => setModule(wi, e.target.value)}
                        >
                          {active.map((m) => (
                            <option key={m.id} value={m.id}>
                              {m.name}
                            </option>
                          ))}
                        </Select>
                      </td>
                      <td className={td}>
                        <div className="space-y-1">
                          {w.classes.map((c, ci) => (
                            <div key={ci} className="flex flex-wrap items-center gap-1 text-xs">
                              <span className="w-28">{c.class_type}</span>
                              <Input
                                type="date"
                                aria-label="Date"
                                value={c.date}
                                className="h-7 w-36"
                                onChange={(e) =>
                                  editClass(wi, ci, {
                                    date: e.target.value,
                                    holiday: holidayOn(e.target.value),
                                  })
                                }
                              />
                              <Input
                                type="time"
                                aria-label="Start time"
                                value={c.start_time}
                                className="h-7 w-28"
                                onChange={(e) => editClass(wi, ci, { start_time: e.target.value })}
                              />
                              <span className="text-muted-foreground">to</span>
                              <Input
                                type="time"
                                aria-label="End time"
                                value={c.end_time}
                                className="h-7 w-28"
                                onChange={(e) => editClass(wi, ci, { end_time: e.target.value })}
                              />
                              {c.holiday && <Badge tone="warning">Holiday: {c.holiday}</Badge>}
                            </div>
                          ))}
                        </div>
                      </td>
                      <td className={td}>
                        <div className="flex flex-col gap-1">
                          <Button
                            size="sm"
                            variant="secondary"
                            onClick={() => shiftFrom(wi)}
                            title="Move this and all later weeks one week later"
                          >
                            Move a week later
                          </Button>
                          <Button
                            size="sm"
                            variant="ghost"
                            onClick={() => setRows(rows.filter((_, j) => j !== wi))}
                          >
                            Remove
                          </Button>
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <ErrorText error={err} />
          <div className="flex justify-between">
            <Button variant="secondary" onClick={() => setRows(null)}>
              Back
            </Button>
            <Button
              onClick={create}
              loading={saving}
              disabled={rows.some((w) => w.duplicate) || rows.length === 0}
            >
              Create {rows.length} class week{rows.length === 1 ? '' : 's'}
            </Button>
          </div>
          {rows.some((w) => w.duplicate) && (
            <p className="text-sm text-danger-strong">
              Remove the weeks marked “Already planned” first.
            </p>
          )}
        </div>
      )}
    </Modal>
  );
}
