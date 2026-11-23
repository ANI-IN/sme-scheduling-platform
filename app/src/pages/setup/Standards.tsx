// Standard schedules (decisions 298 and 299): a domain's named tracks, each with a module order, its own class times
// per module (else the module's own) and regular break weeks. Cohorts are planned from them, and updated from them
// when they change.
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Archive, ArchiveRestore, CalendarPlus, ListOrdered, Plus, Trash2 } from 'lucide-react';
import {
  DndContext,
  closestCenter,
  KeyboardSensor,
  PointerSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
} from '@dnd-kit/core';
import {
  SortableContext,
  arrayMove,
  sortableKeyboardCoordinates,
  verticalListSortingStrategy,
} from '@dnd-kit/sortable';
import { rpc } from '@/lib/rpc';
import { reorderA11y } from '@/lib/reorder';
import { moduleStatusLabel } from '@/lib/labels';
import { useDomain } from '@/lib/domain';
import {
  useCohortScheduleStatus,
  useCohorts,
  useModules,
  useStandards,
  type StandardRow,
} from '@/lib/data';
import { useConfirm } from '@/components/Confirm';
import {
  Badge,
  Button,
  Checkbox,
  Drawer,
  Empty,
  ErrorText,
  Field,
  Input,
  Modal,
  Notice,
  PageHeader,
  Section,
  Select,
  SkeletonRows,
  Textarea,
  tableWrap,
  td,
  th,
  thead,
  trowClick,
} from '@/components/ui';
import { classTimeText } from '@/lib/classTimes';
import { PatternEditor, SortableRow, type ModuleRow } from './moduleParts';
import {
  CohortScheduleBadge,
  PlanFromStandardDialog,
  ResetToStandard,
  UpdateCohortsDialog,
} from './standardParts';
import { refresh } from '@/lib/live';

type Break = { after_position: number; weeks: number };

const orderOf = (s: StandardRow) =>
  [...s.standard_schedule_module].sort((a, b) => a.position - b.position).map((x) => x.module_id);
const breaksOf = (s: StandardRow): Break[] =>
  [...s.standard_schedule_break]
    .sort((a, b) => a.after_position - b.after_position)
    .map((b) => ({ after_position: b.after_position, weeks: b.weeks }));
const breakText = (b: Break) =>
  `${b.weeks} week${b.weeks === 1 ? '' : 's'} after module ${b.after_position}`;

export default function Standards() {
  const { domain } = useDomain();
  const standards = useStandards(domain?.id);
  const modules = useModules(domain?.id);
  const status = useCohortScheduleStatus(domain?.id);
  const [showArchived, setShowArchived] = useState(false);
  const [open, setOpen] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [planning, setPlanning] = useState(false);
  const names = new Map((modules.data ?? []).map((m) => [m.id, m.name]));
  const all = standards.data ?? [];
  const archivedCount = all.filter((s) => s.archived_at).length;
  const shown = all.filter((s) => showArchived || !s.archived_at);
  const following = (id: string) =>
    (status.data ?? []).filter((c) => c.standard_schedule_id === id).length;
  const current = all.find((s) => s.id === open);

  return (
    <div>
      <PageHeader
        title="Standard schedules"
        description={
          domain
            ? `The usual plans of ${domain.name}: a module order, class times and breaks. Plan new cohorts from them.`
            : 'Choose a domain first.'
        }
      >
        {domain && (
          <>
            <Button
              variant="secondary"
              onClick={() => setPlanning(true)}
              disabled={!all.some((s) => !s.archived_at)}
            >
              <CalendarPlus className="h-4 w-4" aria-hidden /> Plan cohorts
            </Button>
            <Button onClick={() => setCreating(true)}>
              <Plus className="h-4 w-4" aria-hidden /> Add standard schedule
            </Button>
          </>
        )}
      </PageHeader>
      <ErrorText error={standards.error} />
      {archivedCount > 0 && (
        <div className="mb-3">
          <Checkbox
            label={`Show archived standard schedules (${archivedCount})`}
            checked={showArchived}
            onChange={setShowArchived}
          />
        </div>
      )}
      {!domain ? (
        <Empty title="No domain yet">Create a domain on the Domains page first.</Empty>
      ) : standards.isLoading ? (
        <SkeletonRows />
      ) : shown.length === 0 ? (
        <Empty
          title="No standard schedules yet"
          icon={<ListOrdered className="h-5 w-5" />}
          action={<Button onClick={() => setCreating(true)}>Add standard schedule</Button>}
        >
          A standard schedule is the usual plan for a cohort of {domain.name}: which modules, in
          which order, and any break weeks. Add one, then plan cohorts from it.
        </Empty>
      ) : (
        <div className={tableWrap}>
          <table className="w-full">
            <thead className={thead}>
              <tr>
                <th className={th}>Standard schedule</th>
                <th className={th}>Modules in order</th>
                <th className={th}>Breaks</th>
                <th className={th}>Cohorts following it</th>
              </tr>
            </thead>
            <tbody>
              {shown.map((s) => (
                <tr key={s.id} className={trowClick} onClick={() => setOpen(s.id)}>
                  <td className={td}>
                    <button
                      type="button"
                      className="text-left font-medium text-link hover:underline"
                      onClick={(e) => {
                        e.stopPropagation();
                        setOpen(s.id);
                      }}
                    >
                      {s.name}
                    </button>
                    {s.archived_at && (
                      <div>
                        <Badge tone="neutral">Archived</Badge>
                      </div>
                    )}
                  </td>
                  <td className={td}>
                    <ol className="list-decimal space-y-0.5 pl-5">
                      {orderOf(s).map((id) => (
                        <li key={id}>{names.get(id) ?? 'A module that was removed'}</li>
                      ))}
                    </ol>
                  </td>
                  <td className={td}>
                    {breaksOf(s).length === 0 ? (
                      <span className="text-muted-foreground">No breaks</span>
                    ) : (
                      <ul className="space-y-0.5">
                        {breaksOf(s).map((b) => (
                          <li key={b.after_position}>{breakText(b)}</li>
                        ))}
                      </ul>
                    )}
                  </td>
                  <td className={`${td} tabular-nums`}>{following(s.id)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {current && domain && (
        <StandardDrawer
          key={current.id}
          standard={current}
          modules={modules.data ?? []}
          onClose={() => setOpen(null)}
        />
      )}
      {creating && domain && (
        <Modal
          open
          onOpenChange={(o) => !o && setCreating(false)}
          title="Add standard schedule"
          description="Choose its modules in order and any break weeks. You can add its own class times next."
          wide
        >
          <StandardForm
            domainId={domain.id}
            modules={modules.data ?? []}
            onSaved={(id) => {
              setCreating(false);
              setOpen(id);
            }}
            onCancel={() => setCreating(false)}
          />
        </Modal>
      )}
      {planning && domain && (
        <PlanFromStandardDialog domainId={domain.id} onClose={() => setPlanning(false)} />
      )}
    </div>
  );
}

/** Name, notes, module order and breaks: saved together and checked by the database. */
function StandardForm({
  domainId,
  standard,
  modules,
  onSaved,
  onCancel,
}: {
  domainId: string;
  standard?: StandardRow;
  modules: ModuleRow[];
  onSaved?: (id: string) => void;
  onCancel?: () => void;
}) {
  const qc = useQueryClient();
  const savedOrder = standard ? orderOf(standard) : [];
  const savedBreaks = standard ? breaksOf(standard) : [];
  const [name, setName] = useState(standard?.name ?? '');
  const [notes, setNotes] = useState(standard?.notes ?? '');
  const [order, setOrder] = useState<string[]>(savedOrder);
  const [breaks, setBreaks] = useState<Break[]>(savedBreaks);
  const [add, setAdd] = useState('');
  const [touched, setTouched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const byId = new Map(modules.map((m) => [m.id, m]));
  const sensors = useSensors(
    useSensor(PointerSensor),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  );
  const errors = {
    name: !name.trim() ? 'Give the standard schedule a name, for example SWEs.' : undefined,
    order: order.length === 0 ? 'Add at least one module.' : undefined,
  };
  const dirty =
    !standard ||
    name !== standard.name ||
    notes !== (standard.notes ?? '') ||
    order.join() !== savedOrder.join() ||
    JSON.stringify(breaks) !== JSON.stringify(savedBreaks);
  const free = Array.from({ length: Math.max(order.length - 1, 0) }, (_, i) => i + 1).filter(
    (p) => !breaks.some((b) => b.after_position === p),
  );

  const onDragEnd = (e: DragEndEvent) => {
    if (e.over && e.active.id !== e.over.id)
      setOrder((o) => arrayMove(o, o.indexOf(String(e.active.id)), o.indexOf(String(e.over!.id))));
  };

  async function save() {
    setTouched(true);
    if (errors.name || errors.order) return;
    setBusy(true);
    setErr(null);
    try {
      const r = (await rpc('save_standard_schedule', {
        p_id: (standard?.id ?? null) as string,
        p_domain_id: domainId,
        p_name: name.trim(),
        p_module_ids: order,
        p_breaks: [...breaks].sort((a, b) => a.after_position - b.after_position),
        p_notes: notes.trim() || undefined,
        p_expected_version: standard?.version,
      })) as { id: string };
      toast.success(
        standard ? 'Standard schedule saved' : `Standard schedule ${name.trim()} added`,
      );
      // The page opens the saved schedule from the list, so only that list is waited for.
      await qc.invalidateQueries({ queryKey: ['standard_schedule'] });
      onSaved?.(r.id);
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-4">
      <Field label="Name" required error={touched ? errors.name : undefined}>
        <Input value={name} maxLength={80} onChange={(e) => setName(e.target.value)} />
      </Field>
      <Field label="Notes (optional)" hint="For example who this track is for.">
        <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} className="min-h-16" />
      </Field>
      <fieldset className="space-y-2">
        <legend className="text-sm font-medium">Modules in order</legend>
        <p className="text-xs text-muted-foreground">
          Each module is one class week, in this order. Drag to change the order.
        </p>
        {order.length > 0 && (
          <DndContext
            sensors={sensors}
            collisionDetection={closestCenter}
            onDragEnd={onDragEnd}
            accessibility={reorderA11y(
              order,
              (id) => byId.get(id)?.name ?? 'A module',
              (idx) => `module ${idx + 1}`,
              'a module',
            )}
          >
            <SortableContext items={order} strategy={verticalListSortingStrategy}>
              <ol className="space-y-1">
                {order.map((id, idx) => {
                  const m = byId.get(id);
                  return (
                    <SortableRow key={id} id={id} label={m?.name ?? 'module'}>
                      <span className="w-6 text-xs text-muted-foreground tabular-nums">
                        {idx + 1}.
                      </span>
                      <span className="font-medium">{m?.name ?? 'A module that was removed'}</span>
                      {m && m.status !== 'Active' && <Badge>{moduleStatusLabel(m.status)}</Badge>}
                      <button
                        type="button"
                        className="ml-auto text-muted-foreground hover:text-danger-strong"
                        aria-label={`Remove ${m?.name ?? 'this module'} from the standard schedule`}
                        onClick={() => {
                          const n = order.length - 1;
                          setOrder(order.filter((x) => x !== id));
                          setBreaks(breaks.filter((b) => b.after_position < n));
                        }}
                      >
                        <Trash2 className="h-4 w-4" />
                      </button>
                    </SortableRow>
                  );
                })}
              </ol>
            </SortableContext>
          </DndContext>
        )}
        <div className="flex flex-wrap gap-2">
          <Select
            aria-label="Module to add"
            value={add}
            onChange={(e) => setAdd(e.target.value)}
            className="w-64"
          >
            <option value="">Choose a module to add</option>
            {modules
              .filter((m) => m.status === 'Active' && !order.includes(m.id))
              .map((m) => (
                <option key={m.id} value={m.id}>
                  {m.name}
                </option>
              ))}
          </Select>
          <Button
            variant="secondary"
            disabled={!add}
            onClick={() => {
              setOrder([...order, add]);
              setAdd('');
            }}
          >
            Add module
          </Button>
        </div>
        {touched && errors.order && <p className="text-xs text-danger-strong">{errors.order}</p>}
      </fieldset>
      <fieldset className="space-y-2">
        <legend className="text-sm font-medium">Breaks</legend>
        <p className="text-xs text-muted-foreground">
          Weeks without classes between two modules, for example a holiday week.
        </p>
        {breaks.length === 0 && <p className="text-sm text-muted-foreground">No breaks.</p>}
        {breaks.map((b, i) => (
          <div key={i} className="flex flex-wrap items-end gap-2">
            <Field label="After module">
              <Select
                value={b.after_position}
                onChange={(e) =>
                  setBreaks(
                    breaks.map((x, j) =>
                      j === i ? { ...x, after_position: Number(e.target.value) } : x,
                    ),
                  )
                }
                className="w-64"
              >
                {Array.from({ length: Math.max(order.length - 1, 0) }, (_, k) => k + 1)
                  .filter((p) => p === b.after_position || free.includes(p))
                  .map((p) => (
                    <option key={p} value={p}>
                      {p}. {byId.get(order[p - 1]!)?.name ?? 'module'}
                    </option>
                  ))}
              </Select>
            </Field>
            <Field label="Length">
              <Select
                value={b.weeks}
                onChange={(e) =>
                  setBreaks(
                    breaks.map((x, j) => (j === i ? { ...x, weeks: Number(e.target.value) } : x)),
                  )
                }
                className="w-36"
              >
                {Array.from({ length: 8 }, (_, k) => k + 1).map((w) => (
                  <option key={w} value={w}>
                    {w} week{w === 1 ? '' : 's'}
                  </option>
                ))}
              </Select>
            </Field>
            <Button
              variant="ghost"
              onClick={() => setBreaks(breaks.filter((_, j) => j !== i))}
              aria-label={`Remove the break after module ${b.after_position}`}
            >
              Remove
            </Button>
          </div>
        ))}
        <Button
          variant="secondary"
          size="sm"
          disabled={free.length === 0}
          onClick={() => setBreaks([...breaks, { after_position: free[0]!, weeks: 1 }])}
        >
          <Plus className="h-4 w-4" aria-hidden /> Add a break
        </Button>
      </fieldset>
      <ErrorText error={err} />
      <div className="flex flex-wrap justify-end gap-2">
        {onCancel && (
          <Button variant="secondary" onClick={onCancel}>
            Go back
          </Button>
        )}
        {standard && dirty && (
          <Button
            variant="ghost"
            onClick={() => {
              setName(standard.name);
              setNotes(standard.notes ?? '');
              setOrder(savedOrder);
              setBreaks(savedBreaks);
            }}
          >
            Undo changes
          </Button>
        )}
        <Button loading={busy} disabled={!dirty} onClick={() => void save()}>
          {standard ? 'Save changes' : 'Add standard schedule'}
        </Button>
      </div>
    </div>
  );
}

function StandardDrawer({
  standard: s,
  modules,
  onClose,
}: {
  standard: StandardRow;
  modules: ModuleRow[];
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const confirm = useConfirm();
  const status = useCohortScheduleStatus(s.domain_id);
  const cohorts = useCohorts(s.domain_id);
  const [updating, setUpdating] = useState(false);
  const [planning, setPlanning] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const byId = new Map(modules.map((m) => [m.id, m]));
  const cohortName = new Map((cohorts.data ?? []).map((c) => [c.id, c.name]));
  const followers = (status.data ?? []).filter((c) => c.standard_schedule_id === s.id);
  const archived = !!s.archived_at;

  async function archive() {
    if (
      !archived &&
      !(await confirm({
        title: `Archive ${s.name}?`,
        body: 'It is no longer offered for planning or updating cohorts. Cohorts that follow it keep their classes. You can restore it at any time.',
        confirmLabel: 'Archive',
      }))
    )
      return;
    setErr(null);
    try {
      await rpc('archive_standard_schedule', { p_id: s.id, p_archived: !archived });
      toast.success(archived ? `${s.name} restored` : `${s.name} archived`);
      refresh(qc, 'standard_schedule');
    } catch (e) {
      setErr(e);
    }
  }

  return (
    <Drawer
      open
      onOpenChange={(o) => !o && onClose()}
      title={s.name}
      description="A standard schedule of this domain. Cohorts planned from it follow it until they are changed on their own."
    >
      <div className="space-y-5">
        {archived && (
          <Notice tone="warning">
            This standard schedule is archived. Restore it to plan or update cohorts from it.
          </Notice>
        )}
        <Section title="Details">
          <StandardForm
            key={`${s.version}:${orderOf(s).join()}:${JSON.stringify(breaksOf(s))}`}
            domainId={s.domain_id}
            standard={s}
            modules={modules}
          />
        </Section>
        <Section
          title="Class times"
          description="The classes of each module's class week in this standard, in the local time of each cohort. A module without class times of its own here uses the module's class times."
        >
          <div className="space-y-5">
            {orderOf(s).map((id, idx) => {
              const m = byId.get(id);
              if (!m) return null;
              const own = m.class_pattern_item.filter((p) => !p.cohort_id);
              return (
                <section
                  key={id}
                  className="space-y-2"
                  aria-label={`Class times of ${m.name} in this standard`}
                >
                  <h3 className="text-sm font-semibold">
                    {idx + 1}. {m.name}
                  </h3>
                  <PatternEditor
                    module={m}
                    standard={{ scheduleId: s.id, items: s.standard_schedule_class }}
                    run={async (fn, ok) => {
                      setErr(null);
                      try {
                        await fn();
                        if (ok) toast.success(ok);
                        refresh(qc, 'standard_schedule');
                      } catch (e) {
                        setErr(e);
                      }
                    }}
                    empty={
                      own.length > 0 ? (
                        <>
                          <p>Uses the module's own class times:</p>
                          <ul className="mt-1 list-disc pl-5">
                            {[...own]
                              .sort(
                                (a, b) =>
                                  a.day_offset - b.day_offset ||
                                  a.start_time.localeCompare(b.start_time),
                              )
                              .map((p) => (
                                <li key={p.id}>{classTimeText(p)}</li>
                              ))}
                          </ul>
                          <p className="mt-1">
                            Add class times here to give this standard its own.
                          </p>
                        </>
                      ) : (
                        "Neither this standard nor the module has class times yet. Add them here, or on the module's page."
                      )
                    }
                  />
                </section>
              );
            })}
          </div>
        </Section>
        <Section
          title="Cohorts following it"
          description="Changes to this standard reach its cohorts only when you press Update cohorts. You see what would change first."
          actions={
            !archived && (
              <>
                <Button size="sm" variant="secondary" onClick={() => setPlanning(true)}>
                  <CalendarPlus className="h-4 w-4" aria-hidden /> Plan cohorts
                </Button>
                <Button
                  size="sm"
                  disabled={followers.length === 0}
                  onClick={() => setUpdating(true)}
                >
                  Update cohorts
                </Button>
              </>
            )
          }
        >
          {followers.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              No cohort follows it yet. Press Plan cohorts to plan new cohorts from it.
            </p>
          ) : (
            <ul className="space-y-2 text-sm">
              {followers.map((c) => (
                <li
                  key={c.cohort_id}
                  className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-border px-3 py-2"
                >
                  <span className="flex flex-wrap items-center gap-2">
                    <span className="font-medium">{cohortName.get(c.cohort_id) ?? 'A cohort'}</span>
                    <CohortScheduleBadge status={c} />
                  </span>
                  {c.mode === 'Custom' && (
                    <ResetToStandard cohortId={c.cohort_id} name={cohortName.get(c.cohort_id)} />
                  )}
                </li>
              ))}
            </ul>
          )}
        </Section>
        <ErrorText error={err} />
        <Section
          title={archived ? 'Archived' : 'Archive'}
          description={
            archived
              ? 'Restore it to plan cohorts from it again.'
              : 'Archive hides it from planning. Cohorts that follow it keep their classes.'
          }
        >
          <Button variant="outline" size="sm" onClick={() => void archive()}>
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
        </Section>
      </div>
      {updating && (
        <UpdateCohortsDialog
          standard={{ id: s.id, name: s.name }}
          cohorts={followers.map((c) => ({
            id: c.cohort_id,
            name: cohortName.get(c.cohort_id) ?? 'A cohort',
          }))}
          onClose={() => setUpdating(false)}
        />
      )}
      {planning && (
        <PlanFromStandardDialog
          domainId={s.domain_id}
          standardId={s.id}
          onClose={() => setPlanning(false)}
        />
      )}
    </Drawer>
  );
}
