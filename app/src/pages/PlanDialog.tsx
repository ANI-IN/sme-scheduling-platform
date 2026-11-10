import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { DateTime } from 'luxon';
import { rpc } from '@/lib/rpc';
import { useCohorts, useModules, type Domain } from '@/lib/data';
import { parseDateList } from '@/lib/time';
import {
  Badge,
  Button,
  DateInput,
  ErrorText,
  Field,
  Input,
  Modal,
  Notice,
  Select,
  Textarea,
  formatDateValue,
  td,
  th,
} from '@/components/ui';

type ProposedClass = {
  pattern_item_id: string | null;
  class_type: string;
  title: string;
  date: string;
  start_time: string;
  end_time: string;
  holiday: string | null;
};
type Warning = { code: string; text: string };
type ProposedWeek = {
  week_start_date: string;
  module_id: string;
  module_name: string;
  cohort: string;
  classes: ProposedClass[];
  warnings: Warning[];
  problem: string | null;
  duplicate: boolean;
  holidays: string[];
};

const NEW = '__new__';
const addDays = (d: string, days: number) => DateTime.fromISO(d).plus({ days }).toISODate()!;

/** Plan classes: choose a cohort and dates (any day), review every class, then create. */
export function PlanDialog({ domain, onClose }: { domain: Domain; onClose: () => void }) {
  const qc = useQueryClient();
  const modules = useModules(domain.id);
  const cohorts = useCohorts(domain.id);
  const active = (modules.data ?? []).filter((m) => m.status === 'Active');
  const noTimes = active.filter((m) => !m.class_pattern_item.some((p) => !p.cohort_id));

  const [chosenCohort, setCohortChoice] = useState('');
  // Default: the newest cohort, or a new one when there is none.
  const cohortChoice = chosenCohort || (cohorts.data ? (cohorts.data[0]?.id ?? NEW) : '');
  const [newCohort, setNewCohort] = useState('');
  const [startModule, setStartModule] = useState('');
  const [repeat, setRepeat] = useState<'1' | '2' | 'list'>('1');
  const [first, setFirst] = useState('');
  const [count, setCount] = useState(10);
  const [list, setList] = useState('');
  const [rows, setRows] = useState<ProposedWeek[] | null>(null);
  const [err, setErr] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const [touched, setTouched] = useState(false);
  const [pending, setPending] = useState<Warning[] | null>(null);
  const [reason, setReason] = useState('');

  // Suggest a name for a new cohort from the first date.
  useEffect(() => {
    if (cohortChoice !== NEW || newCohort) return;
    void rpc('suggest_cohort_name', {
      p_domain_id: domain.id,
      p_first_date: first || DateTime.now().toISODate()!,
    }).then(
      (n) => setNewCohort(String(n)),
      () => {},
    );
  }, [cohortChoice, first, newCohort, domain.id]);

  const cohortName =
    cohortChoice === NEW
      ? newCohort.trim()
      : ((cohorts.data ?? []).find((c) => c.id === cohortChoice)?.name ?? '');
  const startModuleId = startModule || active[0]?.id || '';
  const startHasTimes = !noTimes.some((m) => m.id === startModuleId);

  const errors = {
    cohort: cohortChoice === NEW && !newCohort.trim() ? 'Give the new cohort a name.' : undefined,
    first: repeat !== 'list' && !first ? 'Choose the date of the first class.' : undefined,
    count:
      repeat !== 'list' && (count < 1 || count > 104)
        ? 'Plan between 1 and 104 class weeks.'
        : undefined,
    list: repeat === 'list' && !list.trim() ? 'Paste at least one date.' : undefined,
  };
  const show = (k: keyof typeof errors) => (touched ? errors[k] : undefined);

  async function propose() {
    setTouched(true);
    if (Object.values(errors).some(Boolean)) return;
    setErr(null);
    setBusy(true);
    try {
      let dates: string[];
      if (repeat === 'list') {
        const parsed = parseDateList(list);
        if (parsed.bad.length)
          throw new Error(`These dates could not be read: ${parsed.bad.join(', ')}`);
        dates = parsed.dates;
      } else {
        dates = Array.from({ length: count }, (_, i) => addDays(first, i * 7 * Number(repeat)));
      }
      if (dates.length === 0) throw new Error('There are no dates to plan.');
      setRows(
        (await rpc('generate_classes', {
          p_domain_id: domain.id,
          p_start_module_id: startModuleId,
          p_week_starts: dates,
          p_cohort: cohortName,
        })) as unknown as ProposedWeek[],
      );
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  }

  /** Re-propose one class week (another module or another first date) with the database's rules. */
  async function refresh(idx: number, moduleId: string, date: string) {
    const [w] = (await rpc('generate_classes', {
      p_domain_id: domain.id,
      p_start_module_id: moduleId,
      p_week_starts: [date],
      p_cohort: cohortName,
    })) as unknown as ProposedWeek[];
    if (w) setRows((r) => r!.map((x, j) => (j === idx ? w : x)));
  }

  // Move this class week and every later one by one week (for example around a holiday).
  const moveLater = (idx: number) =>
    setRows((r) =>
      r!.map((w, j) =>
        j < idx
          ? w
          : {
              ...w,
              week_start_date: addDays(w.week_start_date, 7),
              classes: w.classes.map((c) => ({ ...c, date: addDays(c.date, 7), holiday: null })),
              warnings: w.warnings.filter((x) => x.code !== 'holiday'),
              holidays: [],
            },
      ),
    );

  const editClass = (wi: number, ci: number, patch: Partial<ProposedClass>) =>
    setRows((r) =>
      r!.map((w, j) =>
        j === wi
          ? { ...w, classes: w.classes.map((c, k) => (k === ci ? { ...c, ...patch } : c)) }
          : w,
      ),
    );

  const summary = useMemo(() => {
    if (!rows) return null;
    const dates = rows.flatMap((w) => w.classes.map((c) => c.date)).sort();
    return {
      weeks: rows.length,
      classes: rows.reduce((n, w) => n + w.classes.length, 0),
      from: dates[0],
      to: dates[dates.length - 1],
      warnings: rows.flatMap((w) => w.warnings ?? []),
      blocked: rows.filter((w) => w.problem || w.duplicate),
    };
  }, [rows]);

  async function create(accept: boolean) {
    setBusy(true);
    setErr(null);
    try {
      const res = (await rpc('create_module_weeks', {
        p_domain_id: domain.id,
        p_rows: rows!.map((w) => ({
          module_id: w.module_id,
          cohort: cohortName,
          classes: w.classes,
        })),
        p_accept_warnings: accept,
        p_reason: accept ? reason.trim() || undefined : undefined,
      })) as { created?: number; needs_confirmation?: boolean; warnings?: Warning[] };
      if (res.needs_confirmation) {
        setPending(res.warnings ?? []);
        return;
      }
      toast.success(
        `Planned ${res.created} class week${res.created === 1 ? '' : 's'} for ${cohortName}`,
      );
      await qc.invalidateQueries();
      onClose();
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
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
        <div className="space-y-4">
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="Cohort" required error={show('cohort')}>
              <Select value={cohortChoice} onChange={(e) => setCohortChoice(e.target.value)}>
                {(cohorts.data ?? []).map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                  </option>
                ))}
                <option value={NEW}>New cohort</option>
              </Select>
            </Field>
            {cohortChoice === NEW && (
              <Field
                label="Name of the new cohort"
                required
                hint="For example the month it starts, or Weekend and Weekday."
                error={show('cohort')}
              >
                <Input value={newCohort} onChange={(e) => setNewCohort(e.target.value)} />
              </Field>
            )}
            <Field label="Start with this module" hint="The other modules follow in their order.">
              <Select value={startModuleId} onChange={(e) => setStartModule(e.target.value)}>
                {active.map((m) => (
                  <option key={m.id} value={m.id}>
                    {m.rotation_order}. {m.name}
                    {noTimes.some((x) => x.id === m.id) ? ' (no class times yet)' : ''}
                  </option>
                ))}
              </Select>
            </Field>
          </div>
          {noTimes.length > 0 && (
            <Notice tone="warning">
              {noTimes.length === 1 ? 'This module has' : 'These modules have'} no class times yet
              and cannot be planned:{' '}
              {noTimes.map((m, i) => (
                <span key={m.id}>
                  {i > 0 && ', '}
                  <Link
                    to={`/setup/modules/${m.id}?tab=times`}
                    className="font-medium underline"
                    onClick={onClose}
                  >
                    {m.name}
                  </Link>
                </span>
              ))}
              . Add their class times first.
            </Notice>
          )}
          <fieldset className="space-y-2">
            <legend className="mb-1 text-sm font-medium">Dates</legend>
            <div className="flex flex-wrap gap-4 text-sm">
              {(
                [
                  ['1', 'Every week'],
                  ['2', 'Every 2 weeks'],
                  ['list', 'Paste a list of dates'],
                ] as const
              ).map(([v, l]) => (
                <label key={v} className="flex items-center gap-1.5">
                  <input
                    type="radio"
                    name="repeat"
                    checked={repeat === v}
                    onChange={() => setRepeat(v)}
                  />
                  {l}
                </label>
              ))}
            </div>
            {repeat === 'list' ? (
              <Field
                label="Date of the first class of each class week"
                hint="One per line, for example Nov 18, 2026 or 11/18/2026. Any day of the week."
                error={show('list')}
              >
                <Textarea
                  value={list}
                  onChange={(e) => setList(e.target.value)}
                  className="min-h-32"
                />
              </Field>
            ) : (
              <div className="flex flex-wrap gap-4">
                <Field
                  label="Date of the first class"
                  hint="Any day of the week."
                  error={show('first')}
                >
                  <DateInput value={first} onChange={setFirst} className="w-56" />
                </Field>
                <Field label="Number of class weeks" error={show('count')}>
                  <Input
                    type="number"
                    min={1}
                    max={104}
                    value={count}
                    onChange={(e) => setCount(Number(e.target.value))}
                    className="w-28"
                  />
                </Field>
              </div>
            )}
          </fieldset>
          <ErrorText error={err} />
          <Button
            onClick={() => void propose()}
            loading={busy}
            disabled={active.length === 0 || !startHasTimes}
          >
            Show the plan
          </Button>
          {active.length === 0 && (
            <p className="text-sm text-muted-foreground">
              Add a module that is in use first (Setup, Modules).
            </p>
          )}
        </div>
      ) : (
        <div className="space-y-3">
          {summary && (
            <div className="rounded-md border border-border bg-muted/40 p-3 text-sm">
              <strong>{cohortName}</strong>: {summary.weeks} class week
              {summary.weeks === 1 ? '' : 's'}, {summary.classes} class
              {summary.classes === 1 ? '' : 'es'}
              {summary.from && (
                <>
                  , {formatDateValue(summary.from)} to {formatDateValue(summary.to!)}
                </>
              )}
              .
            </div>
          )}
          {summary && summary.blocked.length > 0 && (
            <Notice tone="danger">
              {summary.blocked.length} class week{summary.blocked.length === 1 ? '' : 's'} cannot be
              planned (marked below). Remove them or fix the module first.
            </Notice>
          )}
          {summary && summary.warnings.length > 0 && (
            <Notice tone="warning">
              <div className="mb-1 font-medium">Please check before creating:</div>
              <ul className="list-disc space-y-0.5 pl-5">
                {summary.warnings.slice(0, 8).map((x, i) => (
                  <li key={i}>{x.text}</li>
                ))}
              </ul>
              {summary.warnings.length > 8 && <div>and {summary.warnings.length - 8} more.</div>}
            </Notice>
          )}
          <div className="max-h-[55vh] overflow-auto rounded-lg border border-border">
            <table className="w-full">
              <thead className="sticky top-0 z-10 bg-muted">
                <tr>
                  <th className={th}>Class week</th>
                  <th className={th}>Module</th>
                  <th className={th}>Classes (Pacific)</th>
                  <th className={th}>
                    <span className="sr-only">Actions</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {rows.map((w, wi) => (
                  <tr
                    key={wi}
                    className={
                      w.problem || w.duplicate
                        ? 'border-t border-border bg-danger-soft'
                        : w.warnings?.length
                          ? 'border-t border-border bg-warning-soft/50'
                          : 'border-t border-border'
                    }
                  >
                    <td className={`${td} whitespace-nowrap`}>
                      {formatDateValue(w.week_start_date)}
                      {w.duplicate && (
                        <div>
                          <Badge tone="danger">Already planned</Badge>
                        </div>
                      )}
                    </td>
                    <td className={td}>
                      <Select
                        aria-label="Module"
                        value={w.module_id}
                        onChange={(e) => void refresh(wi, e.target.value, w.week_start_date)}
                      >
                        {active.map((m) => (
                          <option key={m.id} value={m.id}>
                            {m.name}
                          </option>
                        ))}
                      </Select>
                      {w.problem && (
                        <div className="mt-1 text-xs text-danger-strong">
                          {w.problem}{' '}
                          <Link
                            to={`/setup/modules/${w.module_id}?tab=times`}
                            className="underline"
                            onClick={onClose}
                          >
                            Add class times
                          </Link>
                        </div>
                      )}
                    </td>
                    <td className={td}>
                      <div className="space-y-1.5">
                        {w.classes.map((c, ci) => (
                          <div key={ci} className="flex flex-wrap items-center gap-1.5 text-xs">
                            <span className="w-32 truncate font-medium" title={c.title}>
                              {c.class_type}
                            </span>
                            <DateInput
                              aria-label={`Date of ${c.class_type}`}
                              value={c.date}
                              onChange={(date) => editClass(wi, ci, { date, holiday: null })}
                              className="w-48"
                            />
                            <Input
                              type="time"
                              aria-label="Start time"
                              value={c.start_time}
                              className="h-9 w-28"
                              onChange={(e) => editClass(wi, ci, { start_time: e.target.value })}
                            />
                            <span className="text-muted-foreground">to</span>
                            <Input
                              type="time"
                              aria-label="End time"
                              value={c.end_time}
                              className="h-9 w-28"
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
                          onClick={() => moveLater(wi)}
                          title="Move this and all later class weeks one week later"
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
                ))}
              </tbody>
            </table>
          </div>
          <ErrorText error={err} />
          <div className="flex justify-between gap-2">
            <Button variant="secondary" onClick={() => setRows(null)}>
              Back
            </Button>
            <Button
              onClick={() => void create(false)}
              loading={busy}
              disabled={rows.length === 0 || (summary?.blocked.length ?? 0) > 0}
            >
              Create {rows.length} class week{rows.length === 1 ? '' : 's'}
            </Button>
          </div>
        </div>
      )}
      <Modal
        open={!!pending}
        onOpenChange={(o) => !o && setPending(null)}
        title="Plan these classes anyway?"
        description="These are unusual but allowed. Your reason is saved in Activity history."
      >
        <ul className="mb-3 list-disc space-y-1 pl-5 text-sm">
          {(pending ?? []).map((x, i) => (
            <li key={i}>{x.text}</li>
          ))}
        </ul>
        <Field label="Reason (optional)">
          <Input value={reason} onChange={(e) => setReason(e.target.value)} />
        </Field>
        <div className="mt-4 flex justify-end gap-2">
          <Button variant="secondary" onClick={() => setPending(null)}>
            Go back
          </Button>
          <Button
            loading={busy}
            onClick={() => {
              setPending(null);
              void create(true);
            }}
          >
            Plan anyway
          </Button>
        </div>
      </Modal>
    </Modal>
  );
}
