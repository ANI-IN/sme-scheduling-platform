// A proposed time from an instructor (decision 302): the proposal on the class week, checked with every schedule
// check as if the classes had moved, with Accept and Reject. Every check is the database's; this only shows it.
import { useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { supabase } from '@/lib/supabase';
import { check, poke, rpc } from '@/lib/rpc';
import { plain } from '@/lib/plain';
import { WarningsDialog, type CheckWarning } from '@/components/WarningsDialog';
import { DrawerGroup } from '@/components/DrawerGroup';
import { STATUS } from './boardBadges';
import {
  Badge,
  Button,
  ErrorText,
  Field,
  Modal,
  Notice,
  SkeletonRows,
  Textarea,
} from '@/components/ui';

type Proposed = { class_id: string; title: string; from: string; to: string; changed: boolean };
type Preview = {
  id: string;
  status: string;
  instructor: string;
  kind: 'Confirmed' | 'Asked';
  note: string | null;
  proposed: Proposed[];
  blocks: string[];
  warnings: (Omit<CheckWarning, 'level'> & { level?: 'Warning' | 'Information' })[];
};

/** The proposed time waiting for a decision on this class week, if any. */
export function ProposalGroup({ weekId }: { weekId: string }) {
  const qc = useQueryClient();
  const pending = useQuery({
    queryKey: ['module_week', 'proposal', weekId],
    queryFn: async () =>
      check(
        await supabase
          .from('time_proposal')
          .select('id')
          .eq('module_week_id', weekId)
          .eq('status', 'Pending')
          .maybeSingle(),
      ),
  });
  const id = pending.data?.id;
  const preview = useQuery({
    queryKey: ['module_week', 'proposal_preview', id],
    enabled: !!id,
    queryFn: async () => (await rpc('time_proposal_preview', { p_id: id! })) as unknown as Preview,
  });
  const [pendingWarn, setPendingWarn] = useState<CheckWarning[] | null>(null);
  const [rejecting, setRejecting] = useState(false);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  if (!id) return null;
  const p = preview.data;

  async function decide(accept: boolean, why?: string) {
    setBusy(true);
    setErr(null);
    try {
      const r = (await rpc('decide_time_proposal', {
        p_id: id!,
        p_accept: accept,
        p_note: accept ? undefined : note.trim() || undefined,
        ...(why === undefined ? {} : { p_accept_warnings: true, p_reason: why || undefined }),
      })) as unknown as {
        ok: boolean;
        needs_confirmation?: boolean;
        blocks?: string[];
        warnings?: Preview['warnings'];
        confirmed?: boolean;
      };
      if (r.needs_confirmation) {
        setPendingWarn(
          (r.warnings ?? []).map((w) => ({ code: w.code, text: w.text, level: w.level })),
        );
        return;
      }
      if (!r.ok) {
        setErr(new Error((r.blocks ?? []).join(' ')));
        await preview.refetch();
        return;
      }
      toast.success(
        accept
          ? r.confirmed
            ? 'Proposed time accepted: the instructor is confirmed'
            : 'Proposed time accepted'
          : 'Proposed time rejected: the instructor is told',
      );
      setRejecting(false);
      await qc.invalidateQueries();
      void poke().then(() => qc.invalidateQueries());
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  }

  return (
    <DrawerGroup
      title="Proposed time"
      description="Accepting moves the classes for the whole cohort. Rejecting tells the instructor the time stays."
    >
      {!p ? (
        <SkeletonRows rows={2} />
      ) : (
        <div className="space-y-3">
          <p>
            <strong>{p.instructor}</strong>{' '}
            <Badge tone={p.kind === 'Confirmed' ? STATUS.Confirmed.tone : STATUS.Waiting.tone}>
              {p.kind === 'Confirmed' ? STATUS.Confirmed.word : STATUS.Waiting.word}
            </Badge>{' '}
            proposes:
          </p>
          <ul className="list-disc space-y-0.5 pl-5" aria-label="Proposed times">
            {p.proposed
              .filter((x) => x.changed)
              .map((x) => (
                <li key={x.class_id}>
                  {plain(x.title)}: {x.to}{' '}
                  <span className="text-muted-foreground">(now {x.from})</span>
                </li>
              ))}
          </ul>
          {p.note && <p className="text-muted-foreground">Their note: {p.note}</p>}
          {p.blocks.length > 0 && (
            <Notice tone="danger">
              <div className="mb-1 font-medium">It can't be accepted:</div>
              <ul className="list-disc space-y-0.5 pl-5">
                {p.blocks.map((b, i) => (
                  <li key={i}>{plain(b)}</li>
                ))}
              </ul>
            </Notice>
          )}
          {p.warnings.length > 0 && (
            <Notice tone="warning">
              <div className="mb-1 font-medium">New problems at the proposed time:</div>
              <ul className="list-disc space-y-0.5 pl-5">
                {p.warnings.map((w, i) => (
                  <li key={i}>{plain(w.text)}</li>
                ))}
              </ul>
            </Notice>
          )}
          <ErrorText error={err} />
          <div className="flex flex-wrap gap-2">
            <Button
              size="sm"
              loading={busy && !rejecting}
              disabled={p.blocks.length > 0}
              onClick={() => void decide(true)}
            >
              Accept proposed time
            </Button>
            <Button size="sm" variant="outline" onClick={() => setRejecting(true)}>
              Reject
            </Button>
          </div>
        </div>
      )}
      <WarningsDialog
        warnings={pendingWarn}
        title="Accept the proposed time anyway?"
        confirmLabel="Accept anyway"
        busy={busy}
        onCancel={() => setPendingWarn(null)}
        onConfirm={(why) => {
          setPendingWarn(null);
          void decide(true, why);
        }}
      />
      <Modal
        open={rejecting}
        onOpenChange={(o) => !o && setRejecting(false)}
        title="Reject the proposed time?"
        description="The instructor is told the time stays, and can answer their request again."
      >
        <Field
          label="Note for the instructor (optional)"
          hint="For example why the time can't move."
        >
          <Textarea value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} />
        </Field>
        <ErrorText error={err} />
        <div className="mt-4 flex justify-end gap-2">
          <Button variant="secondary" onClick={() => setRejecting(false)}>
            Go back
          </Button>
          <Button variant="destructive" loading={busy} onClick={() => void decide(false)}>
            Reject proposed time
          </Button>
        </div>
      </Modal>
    </DrawerGroup>
  );
}
