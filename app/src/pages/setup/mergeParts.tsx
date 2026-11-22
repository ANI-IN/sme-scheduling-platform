// Cohort merges (decision 304): two or more cohorts continue as one combined cohort from a date. Every rule and
// check is the database's: this shows the preview it returns, lets Ops make the choices it asks for, and saves.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { supabase } from '@/lib/supabase';
import { check, poke, rpc } from '@/lib/rpc';
import { plain } from '@/lib/plain';
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
  Select,
  SkeletonRows,
  formatDateValue,
} from '@/components/ui';

type MergeWeek = {
  module_week_id: string;
  cohort: string;
  label: string;
  action: 'move' | 'cancel';
  reason: string | null;
  duplicate_of?: string;
};
type MergeWarning = Omit<CheckWarning, 'level'> & {
  level?: 'Warning' | 'Information';
  module_week_id?: string;
  fixes?: string[];
};
type MergePlan = {
  ok?: boolean;
  needs_confirmation?: boolean;
  moved?: number;
  cancelled?: number;
  weeks: MergeWeek[];
  blocks: string[];
  warnings: MergeWarning[];
  effects: string[];
};

export function MergeCohortsDialog({
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
  const usable = (cohorts.data ?? []).filter((c) => !c.merged_into);
  const [chosen, setChosen] = useState<string[]>(cohortId ? [cohortId] : []);
  const [date, setDate] = useState('');
  const [name, setName] = useState('');
  const [region, setRegion] = useState('US');
  const [sequence, setSequence] = useState('');
  const [order, setOrder] = useState('');
  const [keep, setKeep] = useState<string[]>([]);
  const [cancel, setCancel] = useState<string[]>([]);
  const [pending, setPending] = useState<CheckWarning[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const seq = chosen.includes(sequence) ? sequence : (chosen[0] ?? '');
  const ord = chosen.includes(order) ? order : seq;
  const ready = chosen.length >= 2 && !!date && !!seq;
  const call = async (save: boolean, why?: string) =>
    (await rpc('merge_cohorts', {
      p_cohort_ids: chosen,
      p_date: date,
      p_sequence_from: seq,
      p_order_from: ord,
      p_name: name.trim() || 'Combined cohort',
      p_region: region,
      p_keep: keep,
      p_cancel: cancel,
      p_save: save,
      ...(why === undefined ? {} : { p_accept_warnings: true, p_reason: why || undefined }),
    })) as unknown as MergePlan;
  const preview = useQuery({
    queryKey: [
      'merge_preview',
      chosen.join(),
      date,
      seq,
      ord,
      name.trim(),
      region,
      keep.join(),
      cancel.join(),
    ],
    queryFn: () => call(false),
    enabled: ready,
    retry: false,
    gcTime: 0,
    refetchOnWindowFocus: false,
  });
  const p = preview.data;
  const cohortName = (id: string) => usable.find((c) => c.id === id)?.name ?? 'Cohort';

  async function save(why?: string) {
    setBusy(true);
    setErr(null);
    try {
      const r = await call(true, why);
      if (r.needs_confirmation) {
        setPending(r.warnings.map((w) => ({ code: w.code, text: w.text, level: w.level })));
        return;
      }
      if (!r.ok) {
        setErr(new Error(r.blocks.join(' ')));
        return;
      }
      toast.success(
        `Cohorts merged into ${name.trim()}: ${r.moved} class week${r.moved === 1 ? '' : 's'} moved`,
      );
      onClose();
      await qc.invalidateQueries();
      void poke().then(() => qc.invalidateQueries());
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  }

  const toggle = (list: string[], set: (v: string[]) => void, id: string, v: boolean) =>
    set(v ? [...list, id] : list.filter((x) => x !== id));

  return (
    <Modal
      open
      onOpenChange={(o) => !o && onClose()}
      title="Merge cohorts"
      description="From the merge date the cohorts continue as one combined cohort. Before that date they stay as they are. Nothing is saved until you press Merge cohorts."
      wide
    >
      <div className="space-y-4 text-sm">
        <fieldset>
          <legend className="mb-1 font-medium">Cohorts to merge</legend>
          <div className="flex flex-wrap gap-x-4 gap-y-1">
            {usable.map((c) => (
              <Checkbox
                key={c.id}
                label={c.name}
                checked={chosen.includes(c.id)}
                onChange={(v) => toggle(chosen, setChosen, c.id, v)}
              />
            ))}
          </div>
        </fieldset>
        <div className="flex flex-wrap items-end gap-3">
          <Field label="Name of the combined cohort">
            <Input value={name} onChange={(e) => setName(e.target.value)} className="w-56" />
          </Field>
          <Field label="Merge date" hint="The first day of a class week.">
            <DateInput value={date} onChange={setDate} className="w-56" />
          </Field>
          <Field label="Time zone">
            <Select value={region} onChange={(e) => setRegion(e.target.value)} className="w-48">
              <option value="US">US Pacific time</option>
              <option value="India">India time (IST)</option>
            </Select>
          </Field>
        </div>
        {chosen.length >= 2 && (
          <div className="flex flex-wrap items-end gap-3">
            <Field label="Module sequence of">
              <Select value={seq} onChange={(e) => setSequence(e.target.value)} className="w-56">
                {chosen.map((id) => (
                  <option key={id} value={id}>
                    {cohortName(id)}
                  </option>
                ))}
              </Select>
            </Field>
            <Field label="Instructor order of">
              <Select value={ord} onChange={(e) => setOrder(e.target.value)} className="w-56">
                {chosen.map((id) => (
                  <option key={id} value={id}>
                    {cohortName(id)}
                  </option>
                ))}
              </Select>
            </Field>
          </div>
        )}
        {ready && preview.isLoading && <SkeletonRows rows={3} />}
        {preview.error && <ErrorText error={preview.error} />}
        {ready && p && (
          <div className="space-y-3">
            {p.blocks.length > 0 && (
              <Notice tone="danger">
                <div className="mb-1 font-medium">This can't be saved yet:</div>
                <ul className="list-disc space-y-0.5 pl-5">
                  {p.blocks.map((b, i) => (
                    <li key={i}>{plain(b)}</li>
                  ))}
                </ul>
              </Notice>
            )}
            {p.warnings.length > 0 && (
              <section aria-label="Merge check">
                <h3 className="mb-1 font-semibold">Merge check</h3>
                <ul className="space-y-2">
                  {p.warnings.map((w, i) => (
                    <li
                      key={i}
                      className="rounded-md border border-warning-strong/25 bg-warning-soft px-3 py-2"
                    >
                      <div>{plain(w.text)}</div>
                      {w.code === 'merge_conflict' && w.module_week_id && (
                        <Checkbox
                          label="Keep this cohort's class week and instructor instead"
                          checked={keep.includes(w.module_week_id)}
                          onChange={(v) => toggle(keep, setKeep, w.module_week_id!, v)}
                        />
                      )}
                      {w.code === 'merge_check' && w.module_week_id && /no match/.test(w.text) && (
                        <Checkbox
                          label="Cancel this class week"
                          checked={cancel.includes(w.module_week_id)}
                          onChange={(v) => toggle(cancel, setCancel, w.module_week_id!, v)}
                        />
                      )}
                    </li>
                  ))}
                </ul>
              </section>
            )}
            <section aria-label="Class weeks from the merge date">
              <h3 className="mb-1 font-semibold">Class weeks from the merge date</h3>
              <ul className="space-y-1">
                {p.weeks.map((w) => (
                  <li key={w.module_week_id} className="flex flex-wrap items-center gap-2">
                    <Badge tone={w.action === 'move' ? 'success' : 'neutral'}>
                      {w.action === 'move' ? 'Moves to the combined cohort' : 'Cancelled'}
                    </Badge>
                    <span>
                      {w.cohort}: {plain(w.label)}
                    </span>
                    {w.reason && <span className="text-muted-foreground">{plain(w.reason)}</span>}
                  </li>
                ))}
              </ul>
            </section>
            <ul
              className="list-disc space-y-0.5 pl-5 text-muted-foreground"
              aria-label="What else happens"
            >
              {p.effects.map((e, i) => (
                <li key={i}>{plain(e)}</li>
              ))}
            </ul>
          </div>
        )}
        <ErrorText error={err} />
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>
            Go back
          </Button>
          <Button
            loading={busy}
            disabled={!ready || !p || p.blocks.length > 0 || !name.trim()}
            onClick={() => void save()}
          >
            Merge cohorts
          </Button>
        </div>
      </div>
      <WarningsDialog
        warnings={pending}
        title="Merge the cohorts anyway?"
        confirmLabel="Merge anyway"
        busy={busy}
        onCancel={() => setPending(null)}
        onConfirm={(why) => {
          setPending(null);
          void save(why);
        }}
      />
    </Modal>
  );
}

/** "Merged into X from <date>", with Undo merge until that date. */
export function MergedBadge({
  cohort,
  intoName,
}: {
  cohort: { id: string; merged_into: string | null; merged_from: string | null };
  intoName: string | undefined;
}) {
  const qc = useQueryClient();
  const confirm = useConfirm();
  const [err, setErr] = useState<unknown>(null);
  const merge = useQuery({
    queryKey: ['cohort', 'merge', cohort.merged_into],
    enabled: !!cohort.merged_into,
    queryFn: async () => {
      const m = check(
        await supabase
          .from('cohort_merge')
          .select('id, effective_date')
          .eq('target_cohort_id', cohort.merged_into!)
          .eq('status', 'Done')
          .maybeSingle(),
      );
      // Undo is possible until the merge date.
      return m
        ? { ...m, canUndo: new Date(`${m.effective_date}T00:00:00`).getTime() > Date.now() }
        : null;
    },
  });
  if (!cohort.merged_into || !cohort.merged_from) return null;
  const canUndo = !!merge.data?.canUndo;
  return (
    <span className="flex flex-wrap items-center gap-2">
      <Badge tone="accent">
        Merged into {intoName ?? 'the combined cohort'} from {formatDateValue(cohort.merged_from)}
      </Badge>
      {canUndo && (
        <Button
          size="sm"
          variant="ghost"
          onClick={async () => {
            if (
              !(await confirm({
                title: 'Undo the merge?',
                body: 'The class weeks go back to their cohorts and cancelled ones are planned again. An instructor released by the merge is not brought back; that class week asks its instructor order.',
                confirmLabel: 'Undo merge',
              }))
            )
              return;
            setErr(null);
            try {
              await rpc('undo_cohort_merge', { p_merge_id: merge.data!.id });
              toast.success('Merge undone');
              await qc.invalidateQueries();
            } catch (e) {
              setErr(e);
            }
          }}
        >
          Undo merge
        </Button>
      )}
      <ErrorText error={err} />
    </span>
  );
}
