// Standard schedules (decisions 298 and 299): the badges, the dialogs that plan cohorts from a standard, and the
// preview and save of Reset to standard and Update cohorts. Shared by the Standard schedules page, the domain's
// cohort list, Plan classes and the class drawer. Every check is the database's; this only shows it.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { DateTime } from 'luxon';
import { Plus, RotateCcw, Trash2 } from 'lucide-react';
import { poke, rpc } from '@/lib/rpc';
import { plain } from '@/lib/plain';
import { asRegion, type Region } from '@/lib/region';
import { useStandards, type CohortScheduleStatus } from '@/lib/data';
import { RegionBadge } from '@/components/ClassTime';
import { WarningsDialog, type CheckWarning } from '@/components/WarningsDialog';
import {
  Badge,
  Button,
  Checkbox,
  DateInput,
  ErrorText,
  Field,
  Input,
  Modal,
  Notice,
  Select,
  SkeletonRows,
  formatDateValue,
  td,
  th,
} from '@/components/ui';
import { dayLabel } from './moduleParts';

/** "Live class: first day, 9:00 AM, 240 minutes". */
export function classTimeText(p: {
  class_type: string;
  day_offset: number;
  start_time: string;
  duration_minutes: number;
}) {
  const t = DateTime.fromFormat(p.start_time.slice(0, 5), 'HH:mm').toFormat('h:mm a');
  return `${p.class_type}: ${dayLabel(p.day_offset).toLowerCase()}, ${t}, ${p.duration_minutes} minutes`;
}

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

/** "Standard: SWEs", "Custom (2 changes)" or "Fully custom" for one cohort. */
export function CohortScheduleBadge({ status }: { status: CohortScheduleStatus | undefined }) {
  if (!status) return null;
  if (status.mode === 'Fully custom')
    return (
      <Badge tone="neutral" title="This cohort was not planned from a standard schedule.">
        Fully custom
      </Badge>
    );
  if (status.mode === 'Standard')
    return (
      <Badge tone="success" title="Every class week follows its standard schedule.">
        Standard: {status.schedule}
      </Badge>
    );
  return (
    <Badge
      tone="warning"
      title={`Follows ${status.schedule}, with ${plural(status.changes, 'class week')} of its own.`}
    >
      Custom ({plural(status.changes, 'change')})
    </Badge>
  );
}

type PlanChange = { module_week_id: string; label: string; actions: string[] };
type NotUpdated = { module_week_id: string; label: string; reason: string };
type NewWeek = { cohort: string; module: string; week_start_date: string };
/** What reset_to_standard and apply_standard answer, in a preview and when saving. */
export type PlanResult = {
  changes: PlanChange[];
  not_updated: NotUpdated[];
  warnings: CheckWarning[];
  new_class_weeks?: NewWeek[];
  ok?: boolean;
  saved?: number;
  needs_confirmation?: boolean;
};
type Call = (o: { save: boolean; accept?: boolean; reason?: string }) => Promise<PlanResult>;

/** What would change, what is not updated and why, and the checks. */
function PlanView({ p }: { p: PlanResult }) {
  const added = p.new_class_weeks ?? [];
  return (
    <div className="space-y-4 text-sm">
      {p.changes.length === 0 && added.length === 0 && (
        <Notice tone="info">
          Nothing to change: these class weeks already follow the standard.
        </Notice>
      )}
      {p.warnings.length > 0 && (
        <Notice tone="warning">
          <div className="mb-1 font-medium">Please check before saving:</div>
          <ul className="list-disc space-y-0.5 pl-5">
            {p.warnings.map((w, i) => (
              <li key={i}>{plain(w.text)}</li>
            ))}
          </ul>
        </Notice>
      )}
      {p.changes.length > 0 && (
        <section>
          <h3 className="mb-1 font-semibold">
            What changes ({plural(p.changes.length, 'class week')})
          </h3>
          <ul className="space-y-2">
            {p.changes.map((c) => (
              <li key={c.module_week_id} className="rounded-md border border-border px-3 py-2">
                <div className="font-medium">{plain(c.label)}</div>
                <ul className="mt-1 list-disc space-y-0.5 pl-5 text-muted-foreground">
                  {c.actions.map((a, i) => (
                    <li key={i}>{plain(a)}</li>
                  ))}
                </ul>
              </li>
            ))}
          </ul>
        </section>
      )}
      {added.length > 0 && (
        <section>
          <h3 className="mb-1 font-semibold">New class weeks ({added.length})</h3>
          <ul className="list-disc space-y-0.5 pl-5">
            {added.map((w, i) => (
              <li key={i}>
                {w.cohort}: {w.module}, week of {formatDateValue(w.week_start_date)}
              </li>
            ))}
          </ul>
        </section>
      )}
      {p.not_updated.length > 0 && (
        <section>
          <h3 className="mb-1 font-semibold">Not updated ({p.not_updated.length})</h3>
          <ul className="space-y-2">
            {p.not_updated.map((n) => (
              <li
                key={n.module_week_id}
                className="rounded-md border border-border bg-muted/40 px-3 py-2"
              >
                <div className="font-medium">{plain(n.label)}</div>
                <div className="text-muted-foreground">{plain(n.reason)}</div>
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}

/**
 * The preview of bringing class weeks back to their standard, then the save: through the one "go ahead anyway?"
 * dialog when the database answers with warnings.
 */
function StandardChangesDialog({
  title,
  description,
  previewKey,
  call,
  saveLabel,
  anyway,
  done,
  onClose,
  children,
}: {
  title: string;
  description: string;
  previewKey: unknown[];
  call: Call;
  saveLabel: string;
  anyway: { title: string; label: string };
  done: (r: PlanResult) => string;
  onClose: () => void;
  children?: React.ReactNode;
}) {
  const qc = useQueryClient();
  const preview = useQuery({
    queryKey: ['standard_preview', ...previewKey],
    queryFn: () => call({ save: false }),
    refetchOnWindowFocus: false,
    retry: false,
    gcTime: 0,
  });
  const [pending, setPending] = useState<CheckWarning[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const p = preview.data;
  const count = (p?.changes.length ?? 0) + (p?.new_class_weeks?.length ?? 0);

  async function save(accept: boolean, why?: string) {
    setBusy(true);
    setErr(null);
    try {
      const r = await call({ save: true, accept, reason: accept ? why || undefined : undefined });
      if (r.needs_confirmation) {
        setPending(r.warnings ?? []);
        return;
      }
      toast.success(done(r));
      // Close first, so the preview is not asked for again once it is saved.
      onClose();
      await qc.invalidateQueries();
      void poke().then(() => qc.invalidateQueries());
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open onOpenChange={(o) => !o && onClose()} title={title} description={description} wide>
      <div className="space-y-4">
        {children}
        {preview.isLoading ? (
          <SkeletonRows rows={3} />
        ) : preview.error ? (
          <ErrorText error={preview.error} />
        ) : (
          p && <PlanView p={p} />
        )}
        <ErrorText error={err} />
        <div className="flex flex-wrap justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>
            Go back
          </Button>
          <Button loading={busy} disabled={!p || count === 0} onClick={() => void save(false)}>
            {saveLabel}
          </Button>
        </div>
      </div>
      <WarningsDialog
        warnings={pending}
        title={anyway.title}
        confirmLabel={anyway.label}
        busy={busy}
        onCancel={() => setPending(null)}
        onConfirm={(why) => {
          setPending(null);
          void save(true, why);
        }}
      />
    </Modal>
  );
}

/** Reset to standard for one class week, or for every class week still to come of a cohort. */
export function ResetToStandard({
  cohortId,
  moduleWeekId,
  name,
  size = 'sm',
}: {
  cohortId?: string;
  moduleWeekId?: string;
  /** The cohort's name (for a whole cohort). */
  name?: string;
  size?: 'sm' | 'md';
}) {
  const [open, setOpen] = useState(false);
  const whole = !!cohortId;
  return (
    <>
      <Button size={size} variant="outline" onClick={() => setOpen(true)}>
        <RotateCcw className="h-4 w-4" aria-hidden /> Reset{' '}
        {whole && name && <span className="sr-only">{name} </span>}to standard
      </Button>
      {open && (
        <StandardChangesDialog
          title={
            whole
              ? `Reset ${name ?? 'this cohort'} to standard?`
              : 'Reset this class week to standard?'
          }
          description={
            whole
              ? 'Every class week still to come goes back to the standard schedule. A confirmed instructor is asked about a new time as usual. Nothing is saved until you press Reset.'
              : 'This class week goes back to the standard schedule. A confirmed instructor is asked about a new time as usual. Nothing is saved until you press Reset.'
          }
          previewKey={['reset', cohortId ?? moduleWeekId]}
          call={async (o) =>
            (await rpc('reset_to_standard', {
              p_cohort_id: cohortId,
              p_module_week_ids: moduleWeekId ? [moduleWeekId] : undefined,
              p_save: o.save,
              p_accept_warnings: o.accept,
              p_reason: o.reason,
            })) as unknown as PlanResult
          }
          saveLabel="Reset"
          anyway={{ title: 'Reset to standard anyway?', label: 'Reset anyway' }}
          done={(r) => `Reset to standard: ${plural(r.saved ?? 0, 'class week')} changed`}
          onClose={() => setOpen(false)}
        />
      )}
    </>
  );
}

/** Update the cohorts that follow a standard after it changed: all of them, or the ones chosen. */
export function UpdateCohortsDialog({
  standard,
  cohorts,
  onClose,
}: {
  standard: { id: string; name: string };
  cohorts: { id: string; name: string }[];
  onClose: () => void;
}) {
  const [all, setAll] = useState(true);
  const [chosen, setChosen] = useState<string[]>(cohorts.map((c) => c.id));
  const ids = all ? undefined : chosen;
  return (
    <StandardChangesDialog
      title={`Update cohorts from ${standard.name}`}
      description="Only class weeks still to come, with no confirmed instructor and no change of their own, are updated. The others are listed under Not updated with the reason. Nothing is saved until you press Update cohorts."
      previewKey={['apply', standard.id, ids?.join() ?? 'all']}
      call={async (o) =>
        (await rpc('apply_standard', {
          p_schedule_id: standard.id,
          p_cohort_ids: ids,
          p_save: o.save,
          p_accept_warnings: o.accept,
          p_reason: o.reason,
        })) as unknown as PlanResult
      }
      saveLabel="Update cohorts"
      anyway={{ title: 'Update cohorts anyway?', label: 'Update anyway' }}
      done={(r) =>
        `Cohorts updated: ${plural(r.saved ?? 0, 'class week')} changed${
          r.new_class_weeks?.length ? `, ${plural(r.new_class_weeks.length, 'new class week')}` : ''
        }`
      }
      onClose={onClose}
    >
      <fieldset className="space-y-2 text-sm">
        <legend className="mb-1 font-medium">Which cohorts</legend>
        <label className="flex items-center gap-2">
          <input type="radio" name="which-cohorts" checked={all} onChange={() => setAll(true)} />
          All cohorts that follow it ({cohorts.length})
        </label>
        <label className="flex items-center gap-2">
          <input type="radio" name="which-cohorts" checked={!all} onChange={() => setAll(false)} />
          Only the cohorts I choose
        </label>
        {!all && (
          <div className="flex flex-wrap gap-x-4 gap-y-1 pl-6">
            {cohorts.map((c) => (
              <Checkbox
                key={c.id}
                label={c.name}
                checked={chosen.includes(c.id)}
                onChange={(v) =>
                  setChosen(v ? [...chosen, c.id] : chosen.filter((x) => x !== c.id))
                }
              />
            ))}
          </div>
        )}
      </fieldset>
    </StandardChangesDialog>
  );
}

type NewCohort = { name: string; start_date: string; region: Region };
type PlannedClass = { title: string; shown: string; ambiguous?: boolean; holiday?: string | null };
type PlannedWeek = {
  week_start_date: string;
  module_name: string;
  standard_position: number;
  classes: PlannedClass[];
  warnings: CheckWarning[];
  problem: string | null;
};
type StandardPlan = {
  schedule: string;
  cohorts: { name: string; start_date: string; region: string; weeks: PlannedWeek[] }[];
  blocks: string[];
  warnings: CheckWarning[];
};

const blankCohort = (region: Region = 'US'): NewCohort => ({ name: '', start_date: '', region });

/** Plan one or more new cohorts from a standard schedule: every class week and every check first. */
export function PlanFromStandardDialog({
  domainId,
  standardId,
  onClose,
}: {
  domainId: string;
  /** The standard to start with (otherwise the first one). */
  standardId?: string;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const standards = useStandards(domainId);
  const usable = (standards.data ?? []).filter(
    (s) => !s.archived_at && s.standard_schedule_module.length > 0,
  );
  const [chosen, setChosen] = useState(standardId ?? '');
  const scheduleId = chosen || usable[0]?.id || '';
  const [rows, setRows] = useState<NewCohort[]>([blankCohort()]);
  const [touched, setTouched] = useState(false);
  const [plan, setPlan] = useState<StandardPlan | null>(null);
  const [fold, setFold] = useState<number | null>(null);
  const [choiceNeeded, setChoiceNeeded] = useState(false);
  const [pending, setPending] = useState<CheckWarning[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);

  const rowErrors = rows.map((r) => ({
    name: !r.name.trim() ? 'Give the cohort a name.' : undefined,
    start: !r.start_date ? 'Choose the start date.' : undefined,
  }));
  const payload = rows.map((r) => ({
    name: r.name.trim(),
    start_date: r.start_date,
    region: r.region,
  }));
  const setRow = (i: number, patch: Partial<NewCohort>) =>
    setRows(rows.map((r, j) => (j === i ? { ...r, ...patch } : r)));

  async function preview() {
    setTouched(true);
    if (!scheduleId || rowErrors.some((e) => e.name || e.start)) return;
    setErr(null);
    setBusy(true);
    try {
      setPlan(
        (await rpc('preview_standard_cohorts', {
          p_schedule_id: scheduleId,
          p_cohorts: payload,
        })) as unknown as StandardPlan,
      );
      setFold(null);
      setChoiceNeeded(false);
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  }

  async function create(accept: boolean, why?: string) {
    setBusy(true);
    setErr(null);
    try {
      const res = (await rpc('create_standard_cohorts', {
        p_schedule_id: scheduleId,
        p_cohorts: payload,
        p_accept_warnings: accept,
        p_reason: accept ? why || undefined : undefined,
        p_fold: fold ?? undefined,
      })) as unknown as {
        ok: boolean;
        class_weeks?: number;
        needs_confirmation?: boolean;
        needs_choice?: boolean;
        warnings?: CheckWarning[];
      };
      if (res.needs_choice) {
        setChoiceNeeded(true);
        return;
      }
      if (res.needs_confirmation) {
        setPending(res.warnings ?? []);
        return;
      }
      toast.success(
        `Planned ${plural(rows.length, 'cohort')} with ${plural(res.class_weeks ?? 0, 'class week')}`,
      );
      await qc.invalidateQueries();
      onClose();
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  }

  const twice =
    choiceNeeded ||
    !!plan?.cohorts.some((c) => c.weeks.some((w) => w.classes.some((k) => k.ambiguous)));
  const weeks = plan?.cohorts.reduce((n, c) => n + c.weeks.length, 0) ?? 0;

  return (
    <Modal
      open
      onOpenChange={(o) => !o && onClose()}
      title="Plan cohorts from a standard"
      description="Each new cohort gets every class week of the standard schedule, in its own time zone. Nothing is saved until you press Create."
      wide
    >
      {standards.isLoading ? (
        <SkeletonRows rows={3} />
      ) : usable.length === 0 ? (
        <Notice tone="info">
          There is no standard schedule with modules yet. Add one on{' '}
          <Link to="/setup/standards" className="font-medium underline" onClick={onClose}>
            Standard schedules
          </Link>{' '}
          first.
        </Notice>
      ) : !plan ? (
        <div className="space-y-4">
          <Field label="Standard schedule" required>
            <Select value={scheduleId} onChange={(e) => setChosen(e.target.value)}>
              {usable.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </Select>
          </Field>
          <fieldset className="space-y-3">
            <legend className="mb-1 text-sm font-medium">New cohorts</legend>
            {rows.map((r, i) => (
              <div
                key={i}
                className="flex flex-wrap items-start gap-2 rounded-md border border-border p-3"
              >
                <Field
                  label={rows.length > 1 ? `Name of cohort ${i + 1}` : 'Name of the new cohort'}
                  required
                  error={touched ? rowErrors[i]!.name : undefined}
                  className="min-w-48 flex-1"
                >
                  <Input value={r.name} onChange={(e) => setRow(i, { name: e.target.value })} />
                </Field>
                <Field
                  label={rows.length > 1 ? `Start date of cohort ${i + 1}` : 'Start date'}
                  required
                  hint="The day of the first class. Any day of the week."
                  error={touched ? rowErrors[i]!.start : undefined}
                >
                  <DateInput
                    value={r.start_date}
                    onChange={(start_date) => setRow(i, { start_date })}
                    className="w-56"
                  />
                </Field>
                <Field label={rows.length > 1 ? `Region of cohort ${i + 1}` : 'Region'}>
                  <Select
                    value={r.region}
                    onChange={(e) => setRow(i, { region: asRegion(e.target.value) })}
                    className="w-48"
                  >
                    <option value="US">US Pacific time</option>
                    <option value="India">India time (IST)</option>
                  </Select>
                </Field>
                {rows.length > 1 && (
                  <Button
                    size="icon"
                    variant="ghost"
                    className="mt-6"
                    aria-label={`Remove cohort ${i + 1}`}
                    onClick={() => setRows(rows.filter((_, j) => j !== i))}
                  >
                    <Trash2 className="h-4 w-4" />
                  </Button>
                )}
              </div>
            ))}
            <Button
              variant="secondary"
              size="sm"
              disabled={rows.length >= 20}
              onClick={() => setRows([...rows, blankCohort(rows[rows.length - 1]?.region)])}
            >
              <Plus className="h-4 w-4" aria-hidden /> Add another cohort
            </Button>
          </fieldset>
          <ErrorText error={err} />
          <Button onClick={() => void preview()} loading={busy} disabled={!scheduleId}>
            Show the plan
          </Button>
        </div>
      ) : (
        <div className="space-y-4">
          <div className="rounded-md border border-border bg-muted/40 p-3 text-sm">
            <strong>{plan.schedule}</strong>: {plural(plan.cohorts.length, 'new cohort')},{' '}
            {plural(weeks, 'class week')}.
          </div>
          {plan.blocks.length > 0 && (
            <Notice tone="danger">
              <div className="mb-1 font-medium">Fix these before creating:</div>
              <ul className="list-disc space-y-0.5 pl-5">
                {plan.blocks.map((b, i) => (
                  <li key={i}>{plain(b)}</li>
                ))}
              </ul>
            </Notice>
          )}
          {plan.warnings.length > 0 && (
            <Notice tone="warning">
              <div className="mb-1 font-medium">Please check before creating:</div>
              <ul className="list-disc space-y-0.5 pl-5">
                {plan.warnings.slice(0, 8).map((x, i) => (
                  <li key={i}>{plain(x.text)}</li>
                ))}
              </ul>
              {plan.warnings.length > 8 && <div>and {plan.warnings.length - 8} more.</div>}
            </Notice>
          )}
          {twice && (
            <fieldset className="rounded-md border border-warning-strong/40 bg-warning-soft p-3 text-sm">
              <legend className="px-1 font-medium">
                A class time happens twice, because the US clocks move back one hour that night.
                Which one do you mean?
              </legend>
              {(
                [
                  [1, 'The first time (PDT, summer time)'],
                  [2, 'The second time (PST, winter time)'],
                ] as const
              ).map(([v, l]) => (
                <label key={v} className="mt-1 flex items-center gap-2">
                  <input
                    type="radio"
                    name="standard-fold"
                    checked={fold === v}
                    onChange={() => setFold(v)}
                  />
                  {l}
                </label>
              ))}
            </fieldset>
          )}
          {plan.cohorts.map((c, ci) => (
            <section
              key={ci}
              className="space-y-2"
              aria-label={`Class weeks of ${c.name || 'the new cohort'}`}
            >
              <h3 className="flex flex-wrap items-center gap-2 text-sm font-semibold">
                {c.name || 'New cohort'} <RegionBadge region={c.region} />
                <span className="font-normal text-muted-foreground">
                  {plural(c.weeks.length, 'class week')}
                  {c.weeks.length > 0 &&
                    `, ${formatDateValue(c.weeks[0]!.week_start_date)} to ${formatDateValue(
                      c.weeks[c.weeks.length - 1]!.week_start_date,
                    )}`}
                </span>
              </h3>
              <div className="overflow-x-auto rounded-lg border border-border">
                <table className="w-full">
                  <thead className="bg-muted">
                    <tr>
                      <th className={th}>Class week</th>
                      <th className={th}>Module</th>
                      <th className={th}>
                        Classes ({c.region === 'India' ? 'India time, IST' : 'US Pacific time'})
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {c.weeks.map((w) => (
                      <tr
                        key={w.standard_position}
                        className={
                          w.problem
                            ? 'border-t border-border bg-danger-soft'
                            : w.warnings.length
                              ? 'border-t border-border bg-warning-soft/50'
                              : 'border-t border-border'
                        }
                      >
                        <td className={`${td} whitespace-nowrap`}>
                          {formatDateValue(w.week_start_date)}
                        </td>
                        <td className={td}>
                          {w.standard_position}. {w.module_name}
                          {w.problem && (
                            <div className="mt-1 text-xs text-danger-strong">
                              {plain(w.problem)}
                            </div>
                          )}
                        </td>
                        <td className={td}>
                          <ul className="space-y-0.5">
                            {w.classes.map((k, i) => (
                              <li key={i}>
                                <span className="font-medium">{plain(k.title)}</span>
                                <span className="text-muted-foreground">: {plain(k.shown)}</span>
                                {k.holiday && (
                                  <Badge tone="warning" className="ml-1">
                                    Holiday: {k.holiday}
                                  </Badge>
                                )}
                              </li>
                            ))}
                          </ul>
                          {w.warnings.length > 0 && (
                            <ul className="mt-1 space-y-0.5 text-xs text-warning-strong">
                              {w.warnings.map((x, i) => (
                                <li key={i}>{plain(x.text)}</li>
                              ))}
                            </ul>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </section>
          ))}
          <ErrorText error={err} />
          <div className="flex justify-between gap-2">
            <Button variant="secondary" onClick={() => setPlan(null)}>
              Back
            </Button>
            <Button
              onClick={() => void create(false)}
              loading={busy}
              disabled={plan.blocks.length > 0 || weeks === 0 || (twice && fold === null)}
            >
              Create {plural(plan.cohorts.length, 'cohort')}
            </Button>
          </div>
        </div>
      )}
      <WarningsDialog
        warnings={pending}
        title="Plan these cohorts anyway?"
        confirmLabel="Plan anyway"
        busy={busy}
        onCancel={() => setPending(null)}
        onConfirm={(why) => {
          setPending(null);
          void create(true, why);
        }}
      />
    </Modal>
  );
}
