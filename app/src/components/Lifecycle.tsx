// Archive, restore and permanent delete, the same way on every page (decisions 254 to 260).
// The database decides what a delete affects (delete_preview) and does all of it (delete_item); this only
// shows it in plain words, asks for the name when other data goes with the item, and reports the result.
import { useEffect, useState } from 'react';
import { useQueryClient, type QueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Archive, ArchiveRestore, Trash2 } from 'lucide-react';
import { rpc } from '@/lib/rpc';
import { useConfirm } from './Confirm';
import { Button, ErrorText, Field, Input, Modal, Spinner } from './ui';
import { refresh, refreshAll, refreshClasses } from '@/lib/live';

export type ItemKind =
  'domain' | 'cohort' | 'module' | 'class_week' | 'instructor' | 'team_member' | 'discord_server';

const NOUN: Record<ItemKind, string> = {
  domain: 'domain',
  cohort: 'cohort',
  module: 'module',
  class_week: 'class week',
  instructor: 'instructor',
  team_member: 'team member',
  discord_server: 'Discord server',
};

type Preview = { name: string; lines: string[]; needs_name: boolean; blocked: string | null };

/** "Delete permanently" with a dialog that first shows exactly what goes with the item. */
export function DeleteButton({
  kind,
  id,
  onDeleted,
  size = 'sm',
}: {
  kind: ItemKind;
  id: string;
  onDeleted?: () => void;
  size?: 'sm' | 'md';
}) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <Button variant="outline" size={size} onClick={() => setOpen(true)}>
        <Trash2 className="h-4 w-4" aria-hidden /> Delete permanently
      </Button>
      {open && (
        <DeleteDialog kind={kind} id={id} onClose={() => setOpen(false)} onDeleted={onDeleted} />
      )}
    </>
  );
}

function DeleteDialog({
  kind,
  id,
  onClose,
  onDeleted,
}: {
  kind: ItemKind;
  id: string;
  onClose: () => void;
  onDeleted?: () => void;
}) {
  const qc = useQueryClient();
  const [preview, setPreview] = useState<Preview | null>(null);
  const [loadErr, setLoadErr] = useState<unknown>(null);
  const [typed, setTyped] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  useEffect(() => {
    let live = true;
    rpc('delete_preview', { p_kind: kind, p_id: id }).then(
      (p) => live && setPreview(p as unknown as Preview),
      (e) => live && setLoadErr(e),
    );
    return () => {
      live = false;
    };
  }, [kind, id]);
  const noun = NOUN[kind];
  const ok =
    !!preview &&
    !preview.blocked &&
    (!preview.needs_name || typed.trim().toLowerCase() === preview.name.trim().toLowerCase());
  return (
    <Modal open onOpenChange={(o) => !o && onClose()} title={`Delete this ${noun} permanently?`}>
      {!preview && !loadErr && <Spinner label="Checking what this affects" />}
      <ErrorText error={loadErr} />
      {preview && (
        <div className="space-y-3 text-sm">
          <p>
            <span className="font-medium">{preview.name}</span> is deleted for good. This cannot be
            undone. Activity history keeps a record of it.
          </p>
          {preview.blocked ? (
            <p className="text-danger-strong">{preview.blocked}</p>
          ) : (
            <>
              {preview.lines.length > 0 ? (
                <div>
                  <p className="font-medium">This also happens:</p>
                  <ul className="mt-1 list-disc space-y-1 pl-5 text-muted-foreground">
                    {preview.lines.map((l) => (
                      <li key={l}>{l}</li>
                    ))}
                  </ul>
                </div>
              ) : (
                <p className="text-muted-foreground">Nothing else is linked to it.</p>
              )}
              {kind !== 'discord_server' && kind !== 'team_member' && (
                <p className="text-muted-foreground">
                  To keep it but stop using it, go back and archive it instead.
                </p>
              )}
              {preview.needs_name && (
                <Field label={`Type ${preview.name} to confirm`}>
                  <Input
                    value={typed}
                    onChange={(e) => setTyped(e.target.value)}
                    autoComplete="off"
                    autoFocus
                  />
                </Field>
              )}
            </>
          )}
          <ErrorText error={err} />
        </div>
      )}
      <div className="mt-4 flex justify-end gap-2">
        <Button variant="outline" onClick={onClose}>
          Go back
        </Button>
        <Button
          variant="danger"
          disabled={!ok}
          loading={busy}
          onClick={async () => {
            setBusy(true);
            setErr(null);
            try {
              await rpc('delete_item', { p_kind: kind, p_id: id, p_typed_name: typed });
              toast.success(`${preview!.name} deleted`);
              refreshKind(qc, kind);
              onClose();
              onDeleted?.();
            } catch (e) {
              setErr(e);
              toast.error(`${preview!.name} was not deleted`);
            } finally {
              setBusy(false);
            }
          }}
        >
          Delete permanently
        </Button>
      </div>
    </Modal>
  );
}

/** Archive (hide it and stop its automation) or restore it. Domains, cohorts, modules, Discord servers. */
export function ArchiveButton({
  kind,
  id,
  name,
  archived,
  size = 'sm',
  onDone,
}: {
  kind: 'domain' | 'cohort' | 'module' | 'discord_server';
  id: string;
  name: string;
  archived: boolean;
  size?: 'sm' | 'md';
  onDone?: () => void;
}) {
  const confirm = useConfirm();
  const qc = useQueryClient();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const what: Record<typeof kind, string> = {
    domain: 'Nothing is sent and nobody is asked for its classes until you restore it.',
    cohort:
      'Its class weeks are paused: nobody is asked and no reminders go out until you restore it.',
    module:
      'It is no longer used for new classes, and its class weeks are paused: nobody is asked and no reminders go out until you restore it.',
    discord_server: 'It is hidden from the lists. Channels already chosen in it keep working.',
  };
  return (
    <span className="inline-flex flex-col items-start gap-1">
      <Button
        variant="outline"
        size={size}
        loading={busy}
        onClick={async () => {
          if (
            !archived &&
            !(await confirm({
              title: `Archive ${name}?`,
              body: `${what[kind]} You can restore it at any time.`,
              confirmLabel: 'Archive',
            }))
          )
            return;
          setBusy(true);
          setErr(null);
          try {
            await rpc('set_archived', { p_kind: kind, p_id: id, p_archived: !archived });
            toast.success(archived ? `${name} restored` : `${name} archived`);
            refreshKind(qc, kind);
            onDone?.();
          } catch (e) {
            setErr(e);
            toast.error(archived ? `${name} was not restored` : `${name} was not archived`);
          } finally {
            setBusy(false);
          }
        }}
      >
        {archived ? (
          <>
            <ArchiveRestore className="h-4 w-4" aria-hidden /> Restore
          </>
        ) : (
          <>
            <Archive className="h-4 w-4" aria-hidden /> Archive
          </>
        )}
      </Button>
      <ErrorText error={err} />
    </span>
  );
}

/** What a delete, archive or restore of each kind can change: a domain reaches almost everything. */
function refreshKind(qc: QueryClient, kind: ItemKind) {
  if (kind === 'domain') return refreshAll(qc);
  if (kind === 'class_week' || kind === 'cohort' || kind === 'module') refreshClasses(qc);
  if (kind === 'cohort') refresh(qc, 'cohort', 'setting');
  if (kind === 'module') refresh(qc, 'module', 'module_operations');
  if (kind === 'instructor') refresh(qc, 'instructor', 'booking', 'request', 'module');
  if (kind === 'team_member')
    refresh(qc, 'team_member', 'domain_team', 'module_operations', 'module');
  if (kind === 'discord_server') refresh(qc, 'discord_server', 'domain');
}

/** Ask before removing a small part of an item (a class time, a holiday, a role), then report it. */
export function useRemovePart() {
  const confirm = useConfirm();
  return async (what: string, remove: () => Promise<unknown>, done: string) => {
    if (
      !(await confirm({
        title: `Remove ${what}?`,
        body: 'It is removed for good. Activity history keeps a record of it.',
        confirmLabel: 'Remove',
        danger: true,
      }))
    )
      return false;
    try {
      await remove();
      toast.success(done);
      return true;
    } catch (e) {
      toast.error(`${what} was not removed: ${e instanceof Error ? e.message : String(e)}`);
      return false;
    }
  };
}
