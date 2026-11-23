// Cohort breaks, program breaks and cohort holidays (decision 301). Every rule and check is the database's: this
// shows the preview it returns (every class that moves, every instructor affected, every problem the move creates),
// lets Ops release a confirmed instructor who can't teach the new dates, and saves.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { CalendarOff, Pause, Plus } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { plain } from '@/lib/plain';
import { WEEK_STATUS } from '@/lib/status';
import { useCohorts } from '@/lib/data';
import { useConfirm } from '@/components/Confirm';
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
  Section,
  Select,
  SkeletonRows,
  formatDateValue,
} from '@/components/ui';
import { deliverNow, refresh, refreshClasses } from '@/lib/live';

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

type Problem = Omit<CheckWarning, 'level'> & {
  level?: 'Block' | 'Warning' | 'Information';
  new?: boolean;
  instructor_id?: string;
  class_id?: string;
  fixes?: string[];
};
type MovedWeek = {
  module_week_id: string;
  label: string;
  from: string;
  to: string;
  classes: { class_id: string; title: string; from: string; to: string }[];
  instructor: { id: string; name: string; status: 'Confirmed' | 'Asked' } | null;
  problems: Problem[];
};
type CohortPreview = { cohort_id: string; cohort: string; weeks: MovedWeek[]; blocks: string[] };
type BlockItem = string | { text: string; module_week_id?: string; code?: string };
/** What add_break and remove_break answer, in a preview and when saving. */
type BreakResult = {
  ok: boolean;
  preview?: boolean;
  cohorts: CohortPreview[];
  blocks: BlockItem[];
  warnings: Problem[];
  needs_confirmation?: boolean;
  confirmed_instructors?: number;
  dates?: string;
  saved?: number;
  messages?: number;
};
type Call = (o: {
  save: boolean;
  release: string[];
  accept?: boolean;
  reason?: string;
}) => Promise<BreakResult>;

const blockText = (b: BlockItem) => (typeof b === 'string' ? b : b.text);

/** The class weeks whose person can be let go to clear a Block (a clash or unavailable dates after the move). */
function releasable(p: BreakResult | undefined) {
  const out: { week: MovedWeek; cohort: string; why: string }[] = [];
  for (const c of p?.cohorts ?? [])
    for (const w of c.weeks) {
      const hit = w.problems.find(
        (x) =>
          x.new &&
          x.level === 'Block' &&
          w.instructor &&
          x.instructor_id === w.instructor.id &&
          (x.fixes ?? []).some((f) => f === 'ask_next' || f === 'release_and_ask_next'),
      );
      if (hit) out.push({ week: w, cohort: c.cohort, why: hit.text });
    }
  return out;
}

/** Every class that moves, every instructor affected, and every problem the move creates. */
function BreakView({
  p,
  release,
  setRelease,
}: {
  p: BreakResult;
  release: string[];
  setRelease: (r: string[]) => void;
}) {
  const moved = p.cohorts.reduce((n, c) => n + c.weeks.length, 0);
  const options = releasable(p);
  const warnings = p.warnings.filter((w) => w.level !== 'Block');
  return (
    <div className="space-y-4 text-sm">
      {p.blocks.length > 0 && (
        <Notice tone="danger">
          <div className="mb-1 font-medium">This can't be saved yet:</div>
          <ul className="list-disc space-y-0.5 pl-5">
            {p.blocks.map((b, i) => (
              <li key={i}>{plain(blockText(b))}</li>
            ))}
          </ul>
        </Notice>
      )}
      {options.length > 0 && (
        <section aria-label="Instructors who can't teach the new dates">
          <h3 className="mb-1 font-semibold">Instructors who can't teach the new dates</h3>
          <p className="mb-2 text-muted-foreground">
            Let them go from that class week and ask the next instructor, or choose other dates.
          </p>
          <div className="space-y-2">
            {options.map((o) => (
              <Checkbox
                key={o.week.module_week_id}
                checked={release.includes(o.week.module_week_id)}
                onChange={(v) =>
                  setRelease(
                    v
                      ? [...release, o.week.module_week_id]
                      : release.filter((x) => x !== o.week.module_week_id),
                  )
                }
                label={`${o.week.instructor?.status === 'Confirmed' ? 'Release' : 'Stop asking'} ${o.week.instructor?.name} for ${plain(o.week.label)} and ask the next instructor`}
                hint={plain(o.why)}
              />
            ))}
          </div>
        </section>
      )}
      {warnings.length > 0 && (
        <Notice tone="warning">
          <div className="mb-1 font-medium">New problems after the move:</div>
          <ul className="list-disc space-y-0.5 pl-5">
            {warnings.map((w, i) => (
              <li key={i}>{plain(w.text)}</li>
            ))}
          </ul>
        </Notice>
      )}
      {moved === 0 ? (
        <Notice tone="info">
          No class weeks start on or after the first day, so no class moves.
        </Notice>
      ) : (
        p.confirmed_instructors !== undefined && (
          <p className="text-muted-foreground">
            {p.confirmed_instructors === 0
              ? 'No confirmed instructor is affected.'
              : `${plural(p.confirmed_instructors, 'confirmed instructor')} ${p.confirmed_instructors === 1 ? 'gets one message' : 'get one message each'} with all their new dates, and ${p.confirmed_instructors === 1 ? 'answers' : 'answer'} for each class week.`}
          </p>
        )
      )}
      {p.cohorts
        .filter((c) => c.weeks.length > 0)
        .map((c) => (
          <section key={c.cohort_id} aria-label={`What moves in ${c.cohort}`}>
            <h3 className="mb-1 font-semibold">
              {c.cohort}: {plural(c.weeks.length, 'class week')}{' '}
              {c.weeks.length === 1 ? 'moves' : 'move'}
            </h3>
            <ul className="space-y-2">
              {c.weeks.map((w) => (
                <li key={w.module_week_id} className="rounded-md border border-border px-3 py-2">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span className="font-medium">{plain(w.label)}</span>
                    {w.instructor && (
                      <Badge
                        tone={
                          w.instructor.status === 'Confirmed'
                            ? WEEK_STATUS.Confirmed.tone
                            : WEEK_STATUS.Waiting.tone
                        }
                      >
                        {w.instructor.status === 'Confirmed'
                          ? WEEK_STATUS.Confirmed.word
                          : WEEK_STATUS.Waiting.word}
                        : {w.instructor.name}
                      </Badge>
                    )}
                  </div>
                  <div className="text-muted-foreground">
                    Week of {formatDateValue(w.from)} moves to the week of {formatDateValue(w.to)}
                  </div>
                  <ul className="mt-1 list-disc space-y-0.5 pl-5 text-muted-foreground">
                    {w.classes.map((k) => (
                      <li key={k.class_id}>
                        {plain(k.title)}: {k.from} now {k.to}
                      </li>
                    ))}
                  </ul>
                </li>
              ))}
            </ul>
          </section>
        ))}
    </div>
  );
}

/** The preview of a break being added or removed, then the save. */
function BreakChangeDialog({
  title,
  description,
  previewKey,
  ready,
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
  ready: boolean;
  call: Call;
  saveLabel: string;
  anyway: { title: string; label: string };
  done: (r: BreakResult) => string;
  onClose: () => void;
  children?: React.ReactNode;
}) {
  const qc = useQueryClient();
  const [release, setRelease] = useState<string[]>([]);
  const preview = useQuery({
    queryKey: ['break_preview', ...previewKey, release.join()],
    queryFn: () => call({ save: false, release }),
    enabled: ready,
    refetchOnWindowFocus: false,
    retry: false,
    gcTime: 0,
  });
  const [pending, setPending] = useState<CheckWarning[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const p = preview.data;

  async function save(accept: boolean, why?: string) {
    setBusy(true);
    setErr(null);
    try {
      const r = await call({
        save: true,
        release,
        accept,
        reason: accept ? why || undefined : undefined,
      });
      if (r.needs_confirmation) {
        setPending(
          (r.warnings ?? []).flatMap((w) =>
            w.level === 'Block' ? [] : [{ code: w.code, text: w.text, level: w.level }],
          ),
        );
        return;
      }
      if (!r.ok) {
        setErr(new Error(r.blocks.map(blockText).join(' ')));
        await preview.refetch();
        return;
      }
      toast.success(done(r));
      onClose();
      // The preview is for the change just saved (a removed break would be refused), so it is dropped, not fetched again.
      qc.removeQueries({ queryKey: ['break_preview'] });
      refreshClasses(qc);
      deliverNow(qc);
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
        {!ready ? null : preview.isLoading ? (
          <SkeletonRows rows={3} />
        ) : preview.error ? (
          <ErrorText error={preview.error} />
        ) : (
          p && <BreakView p={p} release={release} setRelease={setRelease} />
        )}
        <ErrorText error={err} />
        <div className="flex flex-wrap justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>
            Go back
          </Button>
          <Button
            loading={busy}
            disabled={!ready || !p || p.blocks.length > 0}
            onClick={() => void save(false)}
          >
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

/** Add a break for one or several cohorts, or a program break for every cohort of the domain. */
export function AddBreakDialog({
  domainId,
  program,
  cohortId,
  cohortIds,
  startsOn,
  onClose,
}: {
  domainId: string;
  program: boolean;
  cohortId?: string;
  /** From the Schedule board's selection (M12b): the cohorts of the selected class weeks. */
  cohortIds?: string[];
  /** From the Schedule board's selection: the first selected week. */
  startsOn?: string;
  onClose: () => void;
}) {
  const cohorts = useCohorts(domainId);
  const [reason, setReason] = useState('');
  const [start, setStart] = useState(startsOn ?? '');
  const [weeks, setWeeks] = useState(1);
  const [chosen, setChosen] = useState<string[]>(cohortIds ?? (cohortId ? [cohortId] : []));
  const ready = !!start && (program || chosen.length > 0);
  return (
    <BreakChangeDialog
      title={program ? 'Add a program break' : 'Add a break'}
      description={
        program
          ? 'Every cohort of this domain takes the same break. Every class week from the first day on moves back by the break, at the same clock time. Nothing is saved until you press Add break.'
          : 'Every class week of the cohort from the first day on moves back by the break, at the same clock time. Nothing is saved until you press Add break.'
      }
      previewKey={[domainId, program, chosen.join(), start, weeks]}
      ready={ready}
      call={async (o) =>
        (await rpc('add_break', {
          p_domain_id: domainId,
          p_cohort_ids: program ? [] : chosen,
          p_starts_on: start,
          p_weeks: weeks,
          p_reason: reason.trim() || 'Break',
          p_program: program,
          p_save: o.save,
          p_accept_warnings: o.accept,
          p_accept_reason: o.reason,
          p_release_week_ids: o.release,
        })) as unknown as BreakResult
      }
      saveLabel="Add break"
      anyway={{ title: 'Add the break anyway?', label: 'Add break anyway' }}
      done={(r) => `Break added: ${plural(r.saved ?? 0, 'class week')} moved`}
      onClose={onClose}
    >
      <div className="flex flex-wrap items-end gap-3">
        <Field label="What is the break for?" hint="For example Diwali or a program break.">
          <Input value={reason} onChange={(e) => setReason(e.target.value)} className="w-64" />
        </Field>
        <Field label="First day">
          <DateInput value={start} onChange={setStart} className="w-56" />
        </Field>
        <Field label="Length">
          <Select
            aria-label="Length of the break"
            value={String(weeks)}
            onChange={(e) => setWeeks(Number(e.target.value))}
            className="w-32"
          >
            {Array.from({ length: 26 }, (_, i) => i + 1).map((n) => (
              <option key={n} value={n}>
                {plural(n, 'week')}
              </option>
            ))}
          </Select>
        </Field>
      </div>
      {!program && (
        <fieldset>
          <legend className="mb-1 text-sm font-medium">Cohorts</legend>
          <div className="flex flex-wrap gap-x-4 gap-y-1">
            {(cohorts.data ?? []).map((c) => (
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
        </fieldset>
      )}
    </BreakChangeDialog>
  );
}

/** Remove a cohort's break or a whole program break: the classes after it move back. */
function RemoveBreakDialog({
  breakId,
  programBreakId,
  name,
  onClose,
}: {
  breakId?: string;
  programBreakId?: string;
  name: string;
  onClose: () => void;
}) {
  return (
    <BreakChangeDialog
      title={`Remove the break ${name}?`}
      description="Every class week after the break moves back by the break, at the same clock time. Nothing is saved until you press Remove break."
      previewKey={['remove', breakId ?? programBreakId]}
      ready
      call={async (o) =>
        (await rpc('remove_break', {
          p_break_id: breakId,
          p_program_break_id: programBreakId,
          p_save: o.save,
          p_accept_warnings: o.accept,
          p_accept_reason: o.reason,
          p_release_week_ids: o.release,
        })) as unknown as BreakResult
      }
      saveLabel="Remove break"
      anyway={{ title: 'Remove the break anyway?', label: 'Remove break anyway' }}
      done={(r) => `Break removed: ${plural(r.saved ?? 0, 'class week')} moved back`}
      onClose={onClose}
    />
  );
}

/** A holiday for one cohort: shows the classes on that day, which are then fixed in their class weeks. */
export function AddCohortHolidayDialog({
  domainId,
  cohortId,
  onClose,
}: {
  domainId: string;
  cohortId?: string;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const cohorts = useCohorts(domainId);
  const [cohort, setCohort] = useState(cohortId ?? '');
  const [date, setDate] = useState('');
  const [name, setName] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const [onIt, setOnIt] = useState<{ title: string; when: string }[] | null>(null);
  return (
    <Modal
      open
      onOpenChange={(o) => !o && onClose()}
      title="Add a cohort holiday"
      description="A day off for one cohort only. Domain and region holidays are under Holidays."
    >
      {onIt ? (
        <div className="space-y-3 text-sm">
          {onIt.length === 0 ? (
            <Notice tone="success">Holiday added. No class of this cohort is on that day.</Notice>
          ) : (
            <Notice tone="warning">
              <div className="mb-1 font-medium">
                Holiday added. {plural(onIt.length, 'class is', 'classes are')} on that day:
              </div>
              <ul className="list-disc space-y-0.5 pl-5">
                {onIt.map((k, i) => (
                  <li key={i}>
                    {plain(k.title)}: {k.when}
                  </li>
                ))}
              </ul>
              <p className="mt-2">
                Each shows on its class week: change its time, cancel it, or keep it with a reason.
              </p>
            </Notice>
          )}
          <div className="flex justify-end">
            <Button onClick={onClose}>Done</Button>
          </div>
        </div>
      ) : (
        <div className="space-y-3">
          <Field label="Cohort">
            <Select value={cohort} onChange={(e) => setCohort(e.target.value)}>
              <option value="">Choose a cohort</option>
              {(cohorts.data ?? []).map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </Select>
          </Field>
          <Field label="Day">
            <DateInput value={date} onChange={setDate} />
          </Field>
          <Field label="Name" hint="For example Founders day.">
            <Input value={name} onChange={(e) => setName(e.target.value)} />
          </Field>
          <ErrorText error={err} />
          <div className="flex justify-end gap-2">
            <Button variant="secondary" onClick={onClose}>
              Go back
            </Button>
            <Button
              loading={busy}
              disabled={!cohort || !date || !name.trim()}
              onClick={async () => {
                setBusy(true);
                setErr(null);
                try {
                  const r = (await rpc('add_cohort_holiday', {
                    p_cohort_id: cohort,
                    p_date: date,
                    p_name: name.trim(),
                  })) as unknown as { classes: { title: string; when: string }[] };
                  setOnIt(r.classes);
                  refresh(qc, 'cohort_holiday');
                } catch (e) {
                  setErr(e);
                } finally {
                  setBusy(false);
                }
              }}
            >
              Add holiday
            </Button>
          </div>
        </div>
      )}
    </Modal>
  );
}

type BreakRow = {
  id: string;
  cohort_id: string;
  program_break_id: string | null;
  starts_on: string;
  weeks: number;
  reason: string;
};

const breakDates = (starts: string, weeks: number) => {
  const d = new Date(`${starts}T00:00:00`);
  const end = new Date(d.getTime() + (7 * weeks - 1) * 86_400_000);
  const f = (x: Date) => x.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  return `${f(d)} to ${f(end)} (${plural(weeks, 'week')})`;
};

/** The domain's breaks and cohort holidays, with Add and Remove. */
export function BreaksAndHolidays({ domainId }: { domainId: string }) {
  const qc = useQueryClient();
  const confirm = useConfirm();
  const cohorts = useCohorts(domainId, true);
  const name = (id: string) => (cohorts.data ?? []).find((c) => c.id === id)?.name ?? 'Cohort';
  const breaks = useQuery({
    queryKey: ['cohort_break', domainId],
    queryFn: async () =>
      check(
        await supabase
          .from('cohort_break')
          .select('id, cohort_id, program_break_id, starts_on, weeks, reason')
          .eq('domain_id', domainId)
          .eq('status', 'Active')
          .order('starts_on'),
      ) as BreakRow[],
  });
  const holidays = useQuery({
    queryKey: ['cohort_holiday', domainId],
    queryFn: async () =>
      check(
        await supabase
          .from('cohort_holiday')
          .select('id, cohort_id, date, name')
          .eq('domain_id', domainId)
          .order('date'),
      ),
  });
  const [adding, setAdding] = useState<'break' | 'program' | 'holiday' | null>(null);
  const [removing, setRemoving] = useState<{
    breakId?: string;
    programBreakId?: string;
    name: string;
  } | null>(null);
  const [err, setErr] = useState<unknown>(null);

  // A program break is one row, whatever the number of cohorts.
  const rows: { key: string; text: string; remove: NonNullable<typeof removing> }[] = [];
  const seen = new Set<string>();
  for (const b of breaks.data ?? []) {
    if (b.program_break_id) {
      if (seen.has(b.program_break_id)) continue;
      seen.add(b.program_break_id);
      rows.push({
        key: b.program_break_id,
        text: `Program break: ${b.reason}, ${breakDates(b.starts_on, b.weeks)}, every cohort`,
        remove: { programBreakId: b.program_break_id, name: b.reason },
      });
    } else
      rows.push({
        key: b.id,
        text: `${name(b.cohort_id)}: ${b.reason}, ${breakDates(b.starts_on, b.weeks)}`,
        remove: { breakId: b.id, name: b.reason },
      });
  }

  return (
    <Section
      title="Breaks and cohort holidays"
      description="A break moves every later class week of a cohort back by whole weeks; a program break does it for every cohort. A cohort holiday is a day off for one cohort: classes on it show as a problem to fix."
    >
      {rows.length === 0 && (holidays.data ?? []).length === 0 && (
        <p className="mb-3 text-sm text-muted-foreground">No breaks or cohort holidays yet.</p>
      )}
      {rows.length > 0 && (
        <ul className="mb-3 space-y-2 text-sm" aria-label="Breaks">
          {rows.map((r) => (
            <li
              key={r.key}
              className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-border px-3 py-2"
            >
              <span className="flex items-center gap-2">
                <Pause className="h-4 w-4 text-muted-foreground" aria-hidden />
                {r.text}
              </span>
              <Button size="sm" variant="ghost" onClick={() => setRemoving(r.remove)}>
                Remove <span className="sr-only">the break {r.remove.name}</span>
              </Button>
            </li>
          ))}
        </ul>
      )}
      {(holidays.data ?? []).length > 0 && (
        <ul className="mb-3 space-y-2 text-sm" aria-label="Cohort holidays">
          {(holidays.data ?? []).map((h) => (
            <li
              key={h.id}
              className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-border px-3 py-2"
            >
              <span className="flex items-center gap-2">
                <CalendarOff className="h-4 w-4 text-muted-foreground" aria-hidden />
                {name(h.cohort_id)}: {h.name}, {formatDateValue(h.date)}
              </span>
              <Button
                size="sm"
                variant="ghost"
                onClick={async () => {
                  if (
                    !(await confirm({
                      title: `Remove the holiday ${h.name}?`,
                      body: 'Classes on that day no longer show a problem.',
                      confirmLabel: 'Remove holiday',
                    }))
                  )
                    return;
                  setErr(null);
                  try {
                    await rpc('remove_cohort_holiday', { p_id: h.id });
                    toast.success('Cohort holiday removed');
                    refresh(qc, 'cohort_holiday');
                  } catch (e) {
                    setErr(e);
                  }
                }}
              >
                Remove <span className="sr-only">the holiday {h.name}</span>
              </Button>
            </li>
          ))}
        </ul>
      )}
      <ErrorText error={err} />
      <div className="flex flex-wrap gap-2">
        <Button variant="secondary" onClick={() => setAdding('break')}>
          <Plus className="h-4 w-4" aria-hidden /> Add a break
        </Button>
        <Button variant="outline" onClick={() => setAdding('program')}>
          Add a program break
        </Button>
        <Button variant="outline" onClick={() => setAdding('holiday')}>
          Add a cohort holiday
        </Button>
      </div>
      {(adding === 'break' || adding === 'program') && (
        <AddBreakDialog
          domainId={domainId}
          program={adding === 'program'}
          onClose={() => setAdding(null)}
        />
      )}
      {adding === 'holiday' && (
        <AddCohortHolidayDialog domainId={domainId} onClose={() => setAdding(null)} />
      )}
      {removing && <RemoveBreakDialog {...removing} onClose={() => setRemoving(null)} />}
    </Section>
  );
}

/** On a class week: classes on a cohort holiday or inside a break, with Keep with a reason. */
export function BreakAndHolidayNotices({ weekId }: { weekId: string }) {
  const qc = useQueryClient();
  const problems = useQuery({
    queryKey: ['module_week', 'problems', weekId],
    queryFn: async () =>
      (
        (await rpc('schedule_problems', { p_module_week_ids: [weekId] })) as unknown as Record<
          string,
          Problem[]
        >
      )[weekId] ?? [],
  });
  const [keeping, setKeeping] = useState<Problem | null>(null);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const shown = (problems.data ?? []).filter(
    (x) => x.code === 'cohort_holiday' || x.code === 'in_break' || x.code === 'waiting_new_time',
  );
  if (shown.length === 0) return null;
  return (
    <div className="space-y-2">
      {shown.map((x, i) => (
        <Notice key={i} tone={x.level === 'Information' ? 'info' : 'warning'}>
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span>
              {plain(x.text)}
              {x.level !== 'Information' && ' Change its time or cancel it below, or keep it.'}
            </span>
            {(x.fixes ?? []).includes('keep_with_reason') && (
              <Button size="sm" variant="outline" onClick={() => setKeeping(x)}>
                Keep with a reason
              </Button>
            )}
          </div>
        </Notice>
      ))}
      <Modal
        open={!!keeping}
        onOpenChange={(o) => !o && setKeeping(null)}
        title="Keep the class on the holiday?"
        description="Your reason is saved in Activity history, and the class no longer shows as a problem."
      >
        <Field label="Reason">
          <Input value={reason} onChange={(e) => setReason(e.target.value)} aria-required />
        </Field>
        <ErrorText error={err} />
        <div className="mt-4 flex justify-end gap-2">
          <Button variant="secondary" onClick={() => setKeeping(null)}>
            Go back
          </Button>
          <Button
            loading={busy}
            disabled={!reason.trim()}
            onClick={async () => {
              setBusy(true);
              setErr(null);
              try {
                await rpc('keep_class_on_holiday', {
                  p_class_id: keeping!.class_id!,
                  p_reason: reason.trim(),
                });
                toast.success('Class kept on the holiday');
                setKeeping(null);
                setReason('');
                refresh(qc, 'class_session');
              } catch (e) {
                setErr(e);
              } finally {
                setBusy(false);
              }
            }}
          >
            Keep class
          </Button>
        </div>
      </Modal>
    </div>
  );
}
