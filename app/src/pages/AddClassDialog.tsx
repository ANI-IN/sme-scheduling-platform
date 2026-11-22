import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { useCohorts, useModules, type Domain, type WeekRow } from '@/lib/data';
import { asRegion, timeFieldLabel, type Region } from '@/lib/region';
import { RegionSelect, TimeCheck, timeReady } from '@/components/ClassTime';
import { WarningsDialog, type CheckWarning } from '@/components/WarningsDialog';
import {
  Button,
  DateInput,
  ErrorText,
  Field,
  Input,
  Modal,
  Select,
  formatDateValue,
} from '@/components/ui';

type Warning = CheckWarning;

/**
 * Add one class: an extra, makeup or moved class. Either into an existing class week (taught by the
 * same instructor, who is asked to confirm the new time) or as its own class week.
 */
export function AddClassDialog({
  domain,
  week,
  onClose,
}: {
  domain: Domain;
  /** When given, the class is added to this class week. */
  week?: WeekRow;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const modules = useModules(domain.id);
  const cohorts = useCohorts(domain.id);
  const types = useQuery({
    queryKey: ['class_type', domain.id],
    queryFn: async () =>
      check(
        await supabase
          .from('class_type')
          .select('*')
          .eq('domain_id', domain.id)
          .order('sort_order')
          .order('name'),
      ),
  });
  const active = (modules.data ?? []).filter((m) => m.status === 'Active');
  const [f, setF] = useState({
    module: week?.module_id ?? '',
    cohort: week?.cohort_id ?? '',
    date: '',
    start: '09:00',
    end: '10:00',
    type: '',
    title: '',
  });
  const [touched, setTouched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const [pending, setPending] = useState<Warning[] | null>(null);
  const [regionOverride, setRegionOverride] = useState<Region | null>(null);
  const [fold, setFold] = useState<number | null>(null);
  const moduleId = f.module || active[0]?.id || '';
  const cohortId = f.cohort || cohorts.data?.[0]?.id || '';
  const classType = f.type || types.data?.[0]?.name || '';
  // The class follows its class week, or else its cohort, unless switched under More options.
  const usual = asRegion(
    week
      ? [...week.class_session].sort((a, b) => a.starts_at.localeCompare(b.starts_at))[0]?.region
      : cohorts.data?.find((c) => c.id === cohortId)?.region,
  );
  const region = regionOverride ?? usual;

  const errors = {
    date: !f.date ? 'Choose the date.' : undefined,
    time:
      !f.start || !f.end
        ? 'Choose the start and end time.'
        : f.start === f.end
          ? 'The class must end after it starts.'
          : f.date && !timeReady(f.date, [f.start, f.end], region, fold)
            ? 'Check the time below.'
            : undefined,
    module: !week && !moduleId ? 'Choose a module.' : undefined,
    cohort: !week && !cohortId ? 'Choose a cohort.' : undefined,
  };
  const show = (k: keyof typeof errors) => (touched ? errors[k] : undefined);

  async function save(accept: boolean, why?: string) {
    setTouched(true);
    if (Object.values(errors).some(Boolean)) return;
    setBusy(true);
    setErr(null);
    try {
      const res = (await rpc('add_one_class', {
        p_module_week_id: (week?.id ?? null) as string,
        p_module_id: (week ? null : moduleId) as string,
        p_cohort_id: (week ? null : cohortId) as string,
        p_date: f.date,
        p_start: f.start,
        p_end: f.end,
        p_class_type: classType,
        p_title: f.title.trim() || undefined,
        p_accept_warnings: accept,
        p_reason: accept ? why || undefined : undefined,
        p_region: region,
        p_fold: fold ?? undefined,
      })) as { ok: boolean; needs_confirmation?: boolean; warnings?: Warning[] };
      if (res.needs_confirmation) {
        setPending(res.warnings ?? []);
        return;
      }
      toast.success(`Class added on ${formatDateValue(f.date)}`);
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
      title={week ? `Add a class to ${week.module?.name ?? 'this class week'}` : 'Add one class'}
      description={
        week
          ? 'The same instructor teaches it. A confirmed instructor is asked to confirm the new time.'
          : 'For an extra, makeup or moved class. It becomes its own class week and instructors are asked as usual.'
      }
    >
      <div className="grid gap-4 sm:grid-cols-2">
        {!week && (
          <>
            <Field label="Module" required error={show('module')}>
              <Select value={moduleId} onChange={(e) => setF({ ...f, module: e.target.value })}>
                {active.map((m) => (
                  <option key={m.id} value={m.id}>
                    {m.name}
                  </option>
                ))}
              </Select>
            </Field>
            <Field label="Cohort" required error={show('cohort')}>
              <Select value={cohortId} onChange={(e) => setF({ ...f, cohort: e.target.value })}>
                {(cohorts.data ?? []).map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                  </option>
                ))}
              </Select>
            </Field>
          </>
        )}
        <Field label="Date" required hint="Any day of the week." error={show('date')}>
          <DateInput
            value={f.date}
            onChange={(date) => {
              setF({ ...f, date });
              setFold(null);
            }}
          />
        </Field>
        <Field label={timeFieldLabel(region, f.date || undefined)} required error={show('time')}>
          <div className="flex items-center gap-2">
            <Input
              type="time"
              aria-label="Start time"
              className="min-w-0 flex-1"
              value={f.start}
              onChange={(e) => {
                setF({ ...f, start: e.target.value });
                setFold(null);
              }}
            />
            <span className="text-muted-foreground">to</span>
            <Input
              type="time"
              aria-label="End time"
              className="min-w-0 flex-1"
              value={f.end}
              onChange={(e) => {
                setF({ ...f, end: e.target.value });
                setFold(null);
              }}
            />
          </div>
        </Field>
        <Field label="Class type">
          <Select value={classType} onChange={(e) => setF({ ...f, type: e.target.value })}>
            {(types.data ?? []).map((t) => (
              <option key={t.id} value={t.name}>
                {t.name}
              </option>
            ))}
          </Select>
        </Field>
        <Field label="Title (optional)" hint="Shown to the instructor.">
          <Input value={f.title} onChange={(e) => setF({ ...f, title: e.target.value })} />
        </Field>
      </div>
      {f.date && (
        <div className="mt-3">
          <TimeCheck
            date={f.date}
            times={[f.start, f.end]}
            region={region}
            fold={fold}
            onFold={setFold}
          />
        </div>
      )}
      <details className="mt-3 text-sm">
        <summary className="cursor-pointer text-muted-foreground">More options</summary>
        <div className="mt-2 space-y-1">
          <RegionSelect
            value={region}
            onChange={(r) => {
              setRegionOverride(r);
              setFold(null);
            }}
          />
          <p className="text-xs text-muted-foreground">
            Usually {week ? 'the class week' : 'the cohort'} decides the time zone (
            {usual === 'India' ? 'India' : 'US Pacific'}). Change this only for a class taught in
            the other time zone.
          </p>
        </div>
      </details>
      <ErrorText error={err} />
      <div className="mt-4 flex justify-end gap-2">
        <Button variant="secondary" onClick={onClose}>
          Cancel
        </Button>
        <Button loading={busy} onClick={() => void save(false)}>
          Add class
        </Button>
      </div>
      <WarningsDialog
        warnings={pending}
        title="Add this class anyway?"
        confirmLabel="Add anyway"
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
