// One class shared by several cohorts (decision 303). The class week that keeps the class (its instructor, requests
// and messages) is the host; the other cohorts' class weeks join it. Every rule and check is the database's: this
// shows the preview it returns and saves.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { DateTime } from 'luxon';
import { supabase } from '@/lib/supabase';
import { check, poke, rpc } from '@/lib/rpc';
import { plain } from '@/lib/plain';
import { useConfirm } from '@/components/Confirm';
import { DrawerGroup } from '@/components/DrawerGroup';
import { WarningsDialog, type CheckWarning } from '@/components/WarningsDialog';
import {
  Button,
  Checkbox,
  ErrorText,
  Field,
  Modal,
  Notice,
  Select,
  SkeletonRows,
} from '@/components/ui';

type Week = {
  id: string;
  domain_id: string;
  cohort_id: string | null;
  shared_with: string | null;
  first_class_at: string | null;
  week_start_date: string;
};
type Plan = {
  ok?: boolean;
  needs_confirmation?: boolean;
  saved?: number;
  host: { label: string; cohort: string | null; instructor: string | null };
  guests: { module_week_id: string; label: string; cohort: string | null }[];
  times: { title: string; shown: string; moves: boolean }[];
  different_times: boolean;
  blocks: string[];
  warnings: (Omit<CheckWarning, 'level'> & { level?: 'Warning' | 'Information' })[];
  effects: string[];
};

const weekOf = (d: string) => DateTime.fromISO(d).toFormat('LLL d');

/** The class weeks of other cohorts that could share this class: same domain, close in time, not shared yet. */
function useCandidates(week: Week) {
  return useQuery({
    queryKey: ['module_week', 'share_candidates', week.id],
    queryFn: async () => {
      const from = DateTime.fromISO(week.week_start_date).minus({ days: 7 }).toISODate()!;
      const to = DateTime.fromISO(week.week_start_date).plus({ days: 7 }).toISODate()!;
      const rows = check(
        await supabase
          .from('module_week')
          .select(
            'id, cohort_id, week_start_date, shared_with, status, module(name), cohort_ref:cohort_id(name)',
          )
          .eq('domain_id', week.domain_id)
          .gte('week_start_date', from)
          .lte('week_start_date', to)
          .is('shared_with', null)
          .not('status', 'in', '(Cancelled,Completed)')
          .neq('id', week.id)
          .order('week_start_date'),
      ) as unknown as {
        id: string;
        cohort_id: string | null;
        week_start_date: string;
        module: { name: string } | null;
        cohort_ref: { name: string } | null;
      }[];
      return rows.filter((r) => r.cohort_id && r.cohort_id !== week.cohort_id);
    },
  });
}

function ShareDialog({ week, onClose }: { week: Week; onClose: () => void }) {
  const qc = useQueryClient();
  const candidates = useCandidates(week);
  const [chosen, setChosen] = useState<string[]>([]);
  const [timesFrom, setTimesFrom] = useState<string>('');
  const [release, setRelease] = useState(false);
  const [pending, setPending] = useState<CheckWarning[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const call = async (save: boolean, why?: string) =>
    (await rpc('share_class_weeks', {
      p_host_id: week.id,
      p_guest_ids: chosen,
      p_times_from: timesFrom || undefined,
      p_release_instructors: release,
      p_save: save,
      ...(why === undefined ? {} : { p_accept_warnings: true, p_reason: why || undefined }),
    })) as unknown as Plan;
  const preview = useQuery({
    queryKey: ['share_preview', week.id, chosen.join(), timesFrom, release],
    queryFn: () => call(false),
    enabled: chosen.length > 0,
    retry: false,
    gcTime: 0,
    refetchOnWindowFocus: false,
  });
  const p = preview.data;
  const name = (id: string) => {
    const c = (candidates.data ?? []).find((x) => x.id === id);
    return c
      ? `${c.cohort_ref?.name ?? 'Cohort'}: ${c.module?.name ?? 'class week'}`
      : 'This class week';
  };

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
      toast.success(`Class shared with ${r.saved} other class week${r.saved === 1 ? '' : 's'}`);
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
    <Modal
      open
      onOpenChange={(o) => !o && onClose()}
      title="Share this class with other cohorts"
      description="This class week keeps the class, its instructor and its messages. The other cohorts' class weeks join it and are not asked while they share it. Nothing is saved until you press Share class."
      wide
    >
      <div className="space-y-4 text-sm">
        {candidates.isLoading ? (
          <SkeletonRows rows={3} />
        ) : (candidates.data ?? []).length === 0 ? (
          <Notice tone="info">No class week of another cohort is close to this one.</Notice>
        ) : (
          <fieldset>
            <legend className="mb-1 font-medium">Class weeks of other cohorts</legend>
            <div className="space-y-1">
              {(candidates.data ?? []).map((c) => (
                <Checkbox
                  key={c.id}
                  label={`${c.cohort_ref?.name ?? 'Cohort'}: ${c.module?.name ?? 'class week'}, week of ${weekOf(c.week_start_date)}`}
                  checked={chosen.includes(c.id)}
                  onChange={(v) =>
                    setChosen(v ? [...chosen, c.id] : chosen.filter((x) => x !== c.id))
                  }
                />
              ))}
            </div>
          </fieldset>
        )}
        {chosen.length > 0 && (
          <div className="flex flex-wrap items-end gap-4">
            <Field label="The shared class keeps the times of">
              <Select
                value={timesFrom}
                onChange={(e) => setTimesFrom(e.target.value)}
                className="w-72"
              >
                <option value="">This class week</option>
                {chosen.map((id) => (
                  <option key={id} value={id}>
                    {name(id)}
                  </option>
                ))}
              </Select>
            </Field>
            <Checkbox
              label="Release instructors confirmed for the other class weeks"
              checked={release}
              onChange={setRelease}
              hint="To keep one of them instead, open their class week and share from there."
            />
          </div>
        )}
        {preview.isLoading && chosen.length > 0 && <SkeletonRows rows={2} />}
        {preview.error && <ErrorText error={preview.error} />}
        {p && chosen.length > 0 && (
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
              <Notice tone="warning">
                <div className="mb-1 font-medium">Please check before sharing:</div>
                <ul className="list-disc space-y-0.5 pl-5">
                  {p.warnings.map((w, i) => (
                    <li key={i}>{plain(w.text)}</li>
                  ))}
                </ul>
              </Notice>
            )}
            <section aria-label="The shared class">
              <h3 className="mb-1 font-semibold">The shared class</h3>
              <ul className="list-disc space-y-0.5 pl-5">
                {p.times.map((t, i) => (
                  <li key={i}>
                    {plain(t.title)}: {t.shown}
                    {t.moves ? ' (moves)' : ''}
                  </li>
                ))}
              </ul>
            </section>
            <section aria-label="What happens">
              <h3 className="mb-1 font-semibold">What happens</h3>
              <ul className="list-disc space-y-0.5 pl-5 text-muted-foreground">
                {p.effects.map((e, i) => (
                  <li key={i}>{plain(e)}</li>
                ))}
              </ul>
            </section>
          </div>
        )}
        <ErrorText error={err} />
        <div className="flex justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>
            Go back
          </Button>
          <Button
            loading={busy}
            disabled={!p || chosen.length === 0 || p.blocks.length > 0}
            onClick={() => void save()}
          >
            Share class
          </Button>
        </div>
      </div>
      <WarningsDialog
        warnings={pending}
        title="Share the class anyway?"
        confirmLabel="Share anyway"
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

/** On a class week: whether its class is shared, with Share and Stop sharing. */
export function SharedClassGroup({ week }: { week: Week }) {
  const qc = useQueryClient();
  const confirm = useConfirm();
  const [sharing, setSharing] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const related = useQuery({
    queryKey: ['module_week', 'shared', week.id, week.shared_with],
    queryFn: async () => {
      const q = supabase
        .from('module_week')
        .select('id, week_start_date, module(name), cohort_ref:cohort_id(name)');
      const rows = check(
        week.shared_with ? await q.eq('id', week.shared_with) : await q.eq('shared_with', week.id),
      ) as unknown as {
        id: string;
        week_start_date: string;
        module: { name: string } | null;
        cohort_ref: { name: string } | null;
      }[];
      return rows;
    },
  });
  const started = !!week.first_class_at && new Date(week.first_class_at) <= new Date();
  const label = (r: NonNullable<typeof related.data>[number]) =>
    `${r.cohort_ref?.name ?? 'Cohort'}: ${r.module?.name ?? 'class week'}, week of ${weekOf(r.week_start_date)}`;

  async function stop(id: string, cohort: string) {
    if (
      !(await confirm({
        title: `Stop sharing for ${cohort}?`,
        body: 'That cohort gets its own class week back, at the shared time, and its instructor order is asked.',
        confirmLabel: 'Stop sharing',
      }))
    )
      return;
    setErr(null);
    try {
      const r = (await rpc('stop_sharing', { p_module_week_id: id })) as unknown as {
        asked: boolean;
      };
      toast.success(
        r.asked
          ? 'No longer shared: its instructor order is being asked'
          : 'No longer shared: its instructor order is asked when asking starts',
      );
      await qc.invalidateQueries();
      void poke().then(() => qc.invalidateQueries());
    } catch (e) {
      setErr(e);
    }
  }

  const rows = related.data ?? [];
  return (
    <DrawerGroup
      title="Shared class"
      description="One class for several cohorts: one instructor, one set of messages, each cohort keeps its own lists."
    >
      {week.shared_with ? (
        <div className="space-y-2">
          <p>
            Taught together with <strong>{rows[0] ? label(rows[0]) : 'another class week'}</strong>.
            Its instructor and messages are on that class week.
          </p>
          <Button size="sm" variant="outline" onClick={() => void stop(week.id, 'this cohort')}>
            Stop sharing
          </Button>
        </div>
      ) : rows.length > 0 ? (
        <ul className="space-y-2" aria-label="Cohorts sharing this class">
          {rows.map((r) => (
            <li key={r.id} className="flex flex-wrap items-center justify-between gap-2">
              <span>{label(r)}</span>
              <Button
                size="sm"
                variant="ghost"
                onClick={() => void stop(r.id, r.cohort_ref?.name ?? 'that cohort')}
              >
                Stop sharing <span className="sr-only">for {r.cohort_ref?.name}</span>
              </Button>
            </li>
          ))}
        </ul>
      ) : (
        <p className="text-muted-foreground">Not shared with another cohort.</p>
      )}
      {!week.shared_with && !started && (
        <Button size="sm" variant="outline" onClick={() => setSharing(true)}>
          Share with other cohorts
        </Button>
      )}
      <ErrorText error={err} />
      {sharing && <ShareDialog week={week} onClose={() => setSharing(false)} />}
    </DrawerGroup>
  );
}
