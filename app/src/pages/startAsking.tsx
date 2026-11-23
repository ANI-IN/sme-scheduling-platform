// The planned instructor of class weeks (batch 4, B12) and Start asking now for several class weeks at once, shared
// by Upcoming classes and the Schedule board. Who is planned comes from the database (public.planned_instructors);
// Start asking now calls public.start_asking_now for each class week, which only asks: nobody is ever confirmed
// without saying yes.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { rpc } from '@/lib/rpc';
import { deliverNow, refreshClasses } from '@/lib/live';
import { cannotStart, orderPlace, type Planned } from '@/lib/planned';
import { Button, ErrorText, Modal, Notice, SkeletonRows } from '@/components/ui';

/** How many class weeks one call asks about (the database allows up to 1,000). */
const PER_CALL = 200;

async function fetchPlanned(ids: string[]): Promise<Planned[]> {
  const parts: string[][] = [];
  for (let i = 0; i < ids.length; i += PER_CALL) parts.push(ids.slice(i, i + PER_CALL));
  const answers = await Promise.all(
    parts.map(
      async (p) =>
        (await rpc('planned_instructors', { p_module_week_ids: p })) as unknown as Planned[],
    ),
  );
  return answers.flat();
}

/**
 * The planned instructor of each class week, by its ID. Read again with the class weeks (the key starts with
 * module_week, which live updates refresh).
 */
export function usePlanned(ids: string[]) {
  const sorted = [...new Set(ids)].sort();
  return useQuery({
    queryKey: ['module_week', 'planned', sorted.join()],
    enabled: sorted.length > 0,
    queryFn: async () => new Map((await fetchPlanned(sorted)).map((p) => [p.module_week_id, p])),
  });
}

type Outcome = { label: string; text: string; ok: boolean };

/**
 * Start asking now for the chosen class weeks: first who will be asked for each (and which cannot start, with the
 * reason), then one confirmation, then start_asking_now for each, and n8n is told to deliver at once.
 */
export function StartAskingDialog({
  weeks,
  onClose,
  onDone,
}: {
  /** The chosen class weeks, with the words that name each one. */
  weeks: { id: string; label: string }[];
  onClose: () => void;
  /** After asking: clear the selection. */
  onDone?: () => void;
}) {
  const qc = useQueryClient();
  const ids = weeks.map((w) => w.id);
  const plan = useQuery({
    queryKey: ['module_week', 'planned', 'start', ids.join()],
    queryFn: () => fetchPlanned(ids),
    refetchOnWindowFocus: false,
    gcTime: 0,
  });
  const [busy, setBusy] = useState(false);
  const [outcome, setOutcome] = useState<Outcome[] | null>(null);
  const label = new Map(weeks.map((w) => [w.id, w.label]));
  const byId = new Map((plan.data ?? []).map((p) => [p.module_week_id, p]));
  const ready = weeks.filter((w) => {
    const p = byId.get(w.id);
    return p && !cannotStart(p);
  });
  const skipped = weeks.filter((w) => {
    const p = byId.get(w.id);
    return !p || cannotStart(p);
  });
  const paused = ready.filter((w) => byId.get(w.id)?.paused).length;

  async function start() {
    setBusy(true);
    const done: Outcome[] = [];
    for (const w of ready) {
      try {
        const r = (await rpc('start_asking_now', { p_module_week_id: w.id })) as {
          ok?: boolean;
          asked?: string | null;
        } | null;
        done.push({
          label: w.label,
          ok: !!r?.ok,
          text: r?.ok ? `Asked ${r.asked ?? 'the next instructor'}` : 'Nobody could be asked',
        });
      } catch (e) {
        done.push({ label: w.label, ok: false, text: e instanceof Error ? e.message : String(e) });
      }
    }
    setBusy(false);
    // Deliver the requests now instead of at the next automatic run; nothing waits for it.
    deliverNow(qc);
    refreshClasses(qc);
    const asked = done.filter((d) => d.ok).length;
    if (asked) toast.success(`Asking started for ${asked} class week${asked === 1 ? '' : 's'}`);
    onDone?.();
    if (done.every((d) => d.ok)) onClose();
    else setOutcome(done);
  }

  return (
    <Modal
      open
      onOpenChange={(o) => !o && !busy && onClose()}
      title="Start asking now?"
      description="Each class week asks its next instructor straight away instead of waiting for the usual day. One person is asked at a time, and nobody is confirmed until they say yes."
    >
      {outcome ? (
        <div className="space-y-3 text-sm">
          <Notice tone="warning">Some class weeks did not start asking.</Notice>
          <ul className="space-y-1.5">
            {outcome.map((o, i) => (
              <li key={i}>
                <span className="font-medium">{o.label}:</span>{' '}
                <span className={o.ok ? 'text-success-strong' : 'text-danger-strong'}>
                  {o.text}
                </span>
              </li>
            ))}
          </ul>
          <div className="flex justify-end">
            <Button onClick={onClose}>Close</Button>
          </div>
        </div>
      ) : plan.isLoading ? (
        <SkeletonRows rows={3} />
      ) : plan.error ? (
        <ErrorText error={plan.error} />
      ) : (
        <div className="space-y-4 text-sm">
          {ready.length > 0 && (
            <section aria-label="Who will be asked">
              <h3 className="mb-1 font-semibold">Who will be asked ({ready.length})</h3>
              <ul className="space-y-1">
                {ready.map((w) => {
                  const p = byId.get(w.id)!;
                  return (
                    <li key={w.id}>
                      {label.get(w.id)}:{' '}
                      <strong>
                        {p.planned!.name} ({orderPlace(p.planned!)})
                      </strong>
                      {p.paused && <span className="text-muted-foreground"> (paused now)</span>}
                    </li>
                  );
                })}
              </ul>
            </section>
          )}
          {paused > 0 && (
            <p className="text-muted-foreground">
              {paused === 1
                ? 'The paused class week is resumed.'
                : `The ${paused} paused class weeks are resumed.`}
            </p>
          )}
          {skipped.length > 0 && (
            <section aria-label="Left as they are">
              <h3 className="mb-1 font-semibold">Left as they are ({skipped.length})</h3>
              <ul className="space-y-1 text-muted-foreground">
                {skipped.map((w) => {
                  const p = byId.get(w.id);
                  return (
                    <li key={w.id}>
                      {w.label}: {p ? cannotStart(p) : 'It could not be found.'}
                    </li>
                  );
                })}
              </ul>
            </section>
          )}
          <div className="flex justify-end gap-2">
            <Button variant="secondary" onClick={onClose} disabled={busy}>
              Go back
            </Button>
            <Button loading={busy} disabled={ready.length === 0} onClick={() => void start()}>
              Start asking ({ready.length})
            </Button>
          </div>
        </div>
      )}
    </Modal>
  );
}
