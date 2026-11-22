// The Schedule board's bulk move and bulk cancel (Release 3, M12b, decision 314): one combined preview of every
// selected class week, made by the database with the usual checks (bulk_change_weeks), then one save.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { poke, rpc } from '@/lib/rpc';
import { plain } from '@/lib/plain';
import { WarningsDialog, type CheckWarning } from '@/components/WarningsDialog';
import {
  Badge,
  Button,
  ErrorText,
  Field,
  Input,
  Modal,
  Notice,
  Select,
  SkeletonRows,
} from '@/components/ui';

type Problem = { code: string; level: string; text: string; new?: boolean };
type Result = {
  ok: boolean;
  preview?: boolean;
  needs_confirmation?: boolean;
  saved?: number;
  weeks: {
    module_week_id: string;
    label: string;
    cohort: string | null;
    told: string | null;
    problems: Problem[];
  }[];
  blocks: string[];
  warnings: CheckWarning[];
};

const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? '' : 's'}`;

export function BulkChangeDialog({
  action,
  weekIds,
  onClose,
}: {
  action: 'move' | 'cancel';
  weekIds: string[];
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const [by, setBy] = useState(1);
  const [reason, setReason] = useState('');
  const [pending, setPending] = useState<CheckWarning[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const call = async (save: boolean, accept = false, why?: string) =>
    (await rpc('bulk_change_weeks', {
      p_action: action,
      p_week_ids: weekIds,
      p_weeks: action === 'move' ? by : undefined,
      p_reason: (action === 'cancel' ? reason.trim() : why?.trim()) || undefined,
      p_save: save,
      p_accept_warnings: accept,
    })) as unknown as Result;
  const preview = useQuery({
    queryKey: ['bulk_preview', action, weekIds.join(), by],
    queryFn: () => call(false),
    retry: false,
    gcTime: 0,
    refetchOnWindowFocus: false,
  });
  const p = preview.data;

  async function save(accept: boolean, why?: string) {
    setBusy(true);
    setErr(null);
    try {
      const r = await call(true, accept, why);
      if (r.needs_confirmation) {
        setPending(r.warnings);
        return;
      }
      if (!r.ok) {
        setErr(new Error(r.blocks.join(' ')));
        await preview.refetch();
        return;
      }
      toast.success(
        action === 'move'
          ? `${plural(r.saved ?? 0, 'class week')} moved`
          : `${plural(r.saved ?? 0, 'class week')} cancelled`,
      );
      onClose();
      qc.removeQueries({ queryKey: ['bulk_preview'] });
      const others = {
        predicate: (q: { queryKey: readonly unknown[] }) => q.queryKey[0] !== 'bulk_preview',
      };
      await qc.invalidateQueries(others);
      void poke().then(() => qc.invalidateQueries(others));
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  }

  const n = weekIds.length;
  return (
    <Modal
      open
      onOpenChange={(o) => !o && onClose()}
      title={
        action === 'move' ? `Move ${plural(n, 'class week')}` : `Cancel ${plural(n, 'class week')}`
      }
      description={
        action === 'move'
          ? 'Every selected class week moves by the same number of weeks, at the same clock time. Nothing is saved until you press Move.'
          : 'Every selected class week is cancelled, and the people confirmed for them are told. Nothing is saved until you press Cancel class weeks.'
      }
      wide
    >
      <div className="space-y-4">
        {action === 'move' ? (
          <Field label="Move by">
            <Select value={String(by)} onChange={(e) => setBy(Number(e.target.value))}>
              {[-4, -3, -2, -1, 1, 2, 3, 4, 5, 6, 8, 12].map((k) => (
                <option key={k} value={k}>
                  {k < 0 ? `${plural(-k, 'week')} earlier` : `${plural(k, 'week')} later`}
                </option>
              ))}
            </Select>
          </Field>
        ) : (
          <Field label="Reason" required hint="Saved in Activity history with the cancellation.">
            <Input value={reason} onChange={(e) => setReason(e.target.value)} />
          </Field>
        )}
        {preview.isLoading ? (
          <SkeletonRows rows={3} />
        ) : preview.error ? (
          <ErrorText error={preview.error} />
        ) : (
          p && (
            <section aria-label="What changes" className="space-y-3">
              {p.blocks.length > 0 && (
                <Notice tone="danger">
                  <span className="font-medium">This can't be saved yet:</span>
                  <ul className="mt-1 list-disc pl-5">
                    {p.blocks.map((x, i) => (
                      <li key={i}>{plain(x)}</li>
                    ))}
                  </ul>
                </Notice>
              )}
              <ul className="space-y-2" aria-label="Selected class weeks">
                {p.weeks.map((w) => {
                  const fresh = w.problems.filter((x) => x.new && x.level !== 'Information');
                  return (
                    <li
                      key={w.module_week_id}
                      className="rounded-md border border-border p-2 text-sm"
                    >
                      <div className="font-medium">
                        {w.cohort ? `${w.cohort}: ` : ''}
                        {w.label}
                      </div>
                      {w.told && <div className="text-muted-foreground">{w.told}</div>}
                      {fresh.length === 0 ? (
                        <div className="text-muted-foreground">No new problems.</div>
                      ) : (
                        <ul className="mt-1 space-y-1">
                          {fresh.map((x, i) => (
                            <li key={i} className="flex flex-wrap items-center gap-2">
                              <Badge tone={x.level === 'Block' ? 'danger' : 'warning'}>
                                {x.level === 'Block' ? 'Blocks' : 'Warning'}
                              </Badge>
                              {plain(x.text)}
                            </li>
                          ))}
                        </ul>
                      )}
                    </li>
                  );
                })}
              </ul>
            </section>
          )
        )}
        <ErrorText error={err} />
        <div className="flex flex-wrap justify-end gap-2">
          <Button variant="secondary" onClick={onClose}>
            Go back
          </Button>
          <Button
            variant={action === 'cancel' ? 'danger' : 'primary'}
            loading={busy}
            disabled={!p || p.blocks.length > 0 || (action === 'cancel' && !reason.trim())}
            onClick={() => void save(false)}
          >
            {action === 'move' ? 'Move' : 'Cancel class weeks'}
          </Button>
        </div>
      </div>
      <WarningsDialog
        warnings={pending}
        title={action === 'move' ? 'Move anyway?' : 'Cancel anyway?'}
        confirmLabel={action === 'move' ? 'Move anyway' : 'Cancel anyway'}
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
