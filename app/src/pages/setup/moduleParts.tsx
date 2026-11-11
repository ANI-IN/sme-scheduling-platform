// Building blocks of a module's setup, shared by the module page and the new module flow.
import { useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { GripVertical, Trash2 } from 'lucide-react';
import {
  DndContext,
  closestCenter,
  PointerSensor,
  KeyboardSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
} from '@dnd-kit/core';
import {
  SortableContext,
  arrayMove,
  sortableKeyboardCoordinates,
  useSortable,
  verticalListSortingStrategy,
} from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import { DateTime } from 'luxon';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useInstructors, useModules, useWeeks } from '@/lib/data';
import { fmtAt, weekRegion } from '@/lib/region';
import {
  Badge,
  Button,
  Checkbox,
  ErrorText,
  Field,
  Input,
  Modal,
  Select,
  td,
  th,
} from '@/components/ui';
import { useInstructorContext } from '../Instructors';
import { useFormErrors } from '@/lib/useFormErrors';

export type ModuleRow = NonNullable<ReturnType<typeof useModules>['data']>[number];
export const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/** A pattern day: days after the first class of the class week. */
export const dayLabel = (o: number) =>
  o === 0 ? 'First day' : `${o} day${o === 1 ? '' : 's'} after the first day`;

export type Run = (fn: () => Promise<unknown>, ok?: string) => Promise<void>;

export function PatternEditor({
  module: m,
  run,
  cohortId,
}: {
  module: ModuleRow;
  run: Run;
  /** Class times for one cohort only (otherwise the module's default times). */
  cohortId?: string;
}) {
  const types = useQuery({
    queryKey: ['class_type', m.domain_id],
    queryFn: async () =>
      check(
        await supabase
          .from('class_type')
          .select('name')
          .eq('domain_id', m.domain_id)
          .order('sort_order')
          .order('name'),
      ),
  });
  const [n, setN] = useState({
    class_type: 'Live class',
    day_offset: 0,
    start_time: '09:00',
    duration_minutes: 240,
  });
  const items = [...m.class_pattern_item]
    .filter((p) => (p.cohort_id ?? undefined) === cohortId)
    .sort((a, b) => a.day_offset - b.day_offset || a.start_time.localeCompare(b.start_time));
  const time = (t: string) => DateTime.fromFormat(t.slice(0, 5), 'HH:mm').toFormat('h:mm a');
  return (
    <section>
      {items.length === 0 ? (
        <p className="mb-3 text-sm text-muted-foreground">
          No classes yet. Add the live class and its review, for example Sunday 9:00 AM for 240
          minutes and Thursday 6:00 PM for 120 minutes.
        </p>
      ) : (
        <table className="mb-4 w-full text-sm">
          <thead>
            <tr className="border-b border-border">
              <th className={th}>Class</th>
              <th className={th}>Day</th>
              <th className={th}>Starts (local time)</th>
              <th className={th}>Length</th>
              <th className={th}>
                <span className="sr-only">Remove</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {items.map((p) => (
              <tr key={p.id} className="border-b border-border last:border-0">
                <td className={td}>{p.class_type}</td>
                <td className={td}>{dayLabel(p.day_offset)}</td>
                <td className={td}>{time(p.start_time)}</td>
                <td className={td}>{p.duration_minutes} minutes</td>
                <td className={`${td} text-right`}>
                  <Button
                    size="icon"
                    variant="ghost"
                    aria-label={`Remove the ${p.class_type.toLowerCase()}`}
                    onClick={() =>
                      run(
                        async () =>
                          check(await supabase.from('class_pattern_item').delete().eq('id', p.id)),
                        'Class removed',
                      )
                    }
                  >
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <div className="flex flex-wrap items-end gap-2">
        <Field label="Class type">
          <Select value={n.class_type} onChange={(e) => setN({ ...n, class_type: e.target.value })}>
            {(types.data?.map((t) => t.name) ?? ['Live class', 'Assignment review']).map((s) => (
              <option key={s}>{s}</option>
            ))}
          </Select>
        </Field>
        <Field label="Day" hint="Counted from the first class of the class week, on any weekday.">
          <Select
            value={n.day_offset}
            onChange={(e) => setN({ ...n, day_offset: Number(e.target.value) })}
          >
            {Array.from({ length: 14 }, (_, i) => (
              <option key={i} value={i}>
                {dayLabel(i)}
              </option>
            ))}
          </Select>
        </Field>
        <Field
          label="Starts (local time)"
          hint="In the time zone of the cohort: US Pacific or India."
        >
          <Input
            type="time"
            value={n.start_time}
            onChange={(e) => setN({ ...n, start_time: e.target.value })}
          />
        </Field>
        <Field label="Length in minutes">
          <Input
            type="number"
            min={15}
            max={720}
            value={n.duration_minutes}
            onChange={(e) => setN({ ...n, duration_minutes: Number(e.target.value) })}
            className="w-24"
          />
        </Field>
        <Button
          variant="secondary"
          onClick={() =>
            run(async () =>
              check(
                await supabase.from('class_pattern_item').insert({
                  module_id: m.id,
                  cohort_id: cohortId ?? null,
                  ...n,
                  title_template: '{module}: {class_type}',
                  sort_order: items.length + 1,
                }),
              ),
            )
          }
        >
          Add class
        </Button>
      </div>
    </section>
  );
}

export function SortableRow({ id, children }: { id: string; children: React.ReactNode }) {
  const { attributes, listeners, setNodeRef, transform, transition } = useSortable({ id });
  return (
    <li
      ref={setNodeRef}
      style={{ transform: CSS.Transform.toString(transform), transition }}
      className="flex items-center gap-2 rounded border bg-card px-2 py-1.5 text-sm"
    >
      <button
        {...attributes}
        {...listeners}
        className="cursor-grab text-muted-foreground"
        aria-label="Drag to reorder"
      >
        <GripVertical className="h-4 w-4" />
      </button>
      {children}
    </li>
  );
}

// RANK-1..3: dropdown to add, drag to order, impact preview before saving.
export function RankingEditor({
  module: m,
  initialExtra = [],
  footer,
  cohortId,
}: {
  module: ModuleRow;
  /** The order for one cohort only (otherwise the module's order). */
  cohortId?: string;
  /** Instructors to add to the end of the order straight away (for example one just created). */
  initialExtra?: string[];
  footer?: React.ReactNode;
}) {
  const qc = useQueryClient();
  const instructors = useInstructors();
  const ctx = useInstructorContext();
  const saved = useMemo(
    () =>
      [...m.module_ranking]
        .filter((r) => (r.cohort_id ?? undefined) === cohortId)
        .sort((a, b) => a.rank - b.rank)
        .map((r) => r.instructor_id),
    [m.module_ranking, cohortId],
  );
  const [order, setOrder] = useState<string[]>(() => [
    ...saved,
    ...initialExtra.filter((x) => !saved.includes(x)),
  ]);
  const [add, setAdd] = useState('');
  const [impact, setImpact] = useState<{
    affected_weeks: number;
    confirmed_weeks: number;
    weeks: { label: string; next_now: string | null; next_after: string | null }[];
  } | null>(null);
  const [err, setErr] = useState<unknown>(null);
  const byId = new Map((instructors.data ?? []).map((i) => [i.id, i]));
  const sensors = useSensors(
    useSensor(PointerSensor),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  );
  const dirty = order.join() !== saved.join();

  const onDragEnd = (e: DragEndEvent) => {
    if (e.over && e.active.id !== e.over.id) {
      setOrder((o) => arrayMove(o, o.indexOf(String(e.active.id)), o.indexOf(String(e.over!.id))));
    }
  };

  return (
    <section>
      <p className="mb-3 text-sm text-muted-foreground">
        Drag to change the order. Changes apply to the next person we ask, never to a request
        already sent.
      </p>
      <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={onDragEnd}>
        <SortableContext items={order} strategy={verticalListSortingStrategy}>
          <ol className="space-y-1">
            {order.map((id, idx) => {
              const i = byId.get(id);
              const greyed = !i || i.status !== 'Active' || !i.verified_at;
              return (
                <SortableRow key={id} id={id}>
                  <span className="w-32 text-xs text-muted-foreground">
                    {idx === 0 ? 'Primary instructor' : `Backup ${idx}`}
                  </span>
                  <span className={greyed ? 'text-muted-foreground' : 'font-medium'}>
                    {i?.full_name ?? 'Unknown'}
                  </span>
                  {i && i.status !== 'Active' && <Badge>{i.status}</Badge>}
                  {i && !i.verified_at && !i.is_test && (
                    <Badge tone="warning">Not checked yet</Badge>
                  )}
                  {i?.is_test && <Badge tone="accent">Test instructor</Badge>}
                  <span
                    className="ml-2 hidden truncate text-xs text-muted-foreground sm:inline"
                    title={(ctx.data?.upcoming.get(id) ?? []).join('\n')}
                  >
                    {(ctx.data?.upcoming.get(id) ?? []).length
                      ? `${(ctx.data?.upcoming.get(id) ?? []).length} upcoming classes`
                      : ''}
                  </span>
                  <button
                    className="ml-auto text-muted-foreground hover:text-danger-strong"
                    aria-label="Remove from the instructor order"
                    onClick={() => setOrder(order.filter((x) => x !== id))}
                  >
                    <Trash2 className="h-4 w-4" />
                  </button>
                </SortableRow>
              );
            })}
          </ol>
        </SortableContext>
      </DndContext>
      <div className="mt-2 flex flex-wrap gap-2">
        <Select
          aria-label="Instructor to add"
          value={add}
          onChange={(e) => setAdd(e.target.value)}
          className="w-64"
        >
          <option value="">Choose an instructor to add</option>
          {(instructors.data ?? [])
            .filter((i) => i.status !== 'Archived' && !order.includes(i.id))
            .map((i) => (
              <option key={i.id} value={i.id}>
                {i.full_name}
                {i.status !== 'Active' ? ` (${i.status.toLowerCase()})` : ''}
                {!i.verified_at && !i.is_test ? ' (contact not checked)' : ''}
              </option>
            ))}
        </Select>
        <Button
          variant="secondary"
          disabled={!add}
          onClick={() => (setOrder([...order, add]), setAdd(''))}
        >
          Add
        </Button>
        {footer}
        <Button
          disabled={!dirty}
          onClick={async () => {
            setErr(null);
            try {
              setImpact(
                (await rpc('ranking_impact', {
                  p_module_id: m.id,
                  p_instructor_ids: order,
                  p_cohort_id: cohortId,
                })) as never,
              );
            } catch (e) {
              setErr(e);
            }
          }}
        >
          Review and save
        </Button>
        {dirty && (
          <Button variant="ghost" onClick={() => setOrder(saved)}>
            Undo changes
          </Button>
        )}
      </div>
      <ErrorText error={err} />
      <Modal
        open={!!impact}
        onOpenChange={(o) => !o && setImpact(null)}
        title="Save this instructor order?"
      >
        {impact && (
          <div className="space-y-3 text-sm">
            <p>
              This changes who we ask next for <strong>{impact.affected_weeks}</strong> upcoming
              class week{impact.affected_weeks === 1 ? '' : 's'} without an instructor. Confirmed
              class weeks ({impact.confirmed_weeks}) stay as they are.
            </p>
            {impact.weeks.length > 0 && (
              <table className="w-full">
                <thead>
                  <tr>
                    <th className={th}>Class week</th>
                    <th className={th}>Asked next now</th>
                    <th className={th}>After saving</th>
                  </tr>
                </thead>
                <tbody>
                  {impact.weeks.map((w) => (
                    <tr key={w.label} className="border-t">
                      <td className={td}>{w.label}</td>
                      <td className={td}>{w.next_now ?? 'Nobody'}</td>
                      <td className={td}>{w.next_after ?? 'Nobody'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
            <div className="flex justify-end gap-2">
              <Button variant="secondary" onClick={() => setImpact(null)}>
                Cancel
              </Button>
              <Button
                onClick={async () => {
                  try {
                    await rpc('save_ranking', {
                      p_module_id: m.id,
                      p_instructor_ids: order,
                      p_expected_ids: saved,
                      p_cohort_id: cohortId,
                    });
                    toast.success('Instructor order saved');
                    setImpact(null);
                    await qc.invalidateQueries();
                  } catch (e) {
                    setErr(e);
                    setImpact(null);
                  }
                }}
              >
                Save order
              </Button>
            </div>
          </div>
        )}
      </Modal>
    </section>
  );
}

export function Resources({ module: m, run }: { module: ModuleRow; run: Run }) {
  const [r, setR] = useState({ title: '', url: '' });
  const items = [...m.module_resource].sort((a, b) => a.sort_order - b.sort_order);
  const v = useFormErrors({
    title: !r.title.trim() ? 'Give the link a short name.' : undefined,
    url: !/^https?:\/\//i.test(r.url) ? 'Paste a full link that starts with https://' : undefined,
  });
  return (
    <section>
      {items.length === 0 ? (
        <p className="mb-3 text-sm text-muted-foreground">
          No materials yet. Add links such as the module page, slides or the assignment.
        </p>
      ) : (
        <ul className="mb-4 divide-y divide-border rounded-md border border-border text-sm">
          {items.map((x) => (
            <li key={x.id} className="flex flex-wrap items-center gap-3 px-3 py-2">
              <a
                href={x.url}
                target="_blank"
                rel="noreferrer"
                className="min-w-0 flex-1 truncate font-medium text-link hover:underline"
              >
                {x.title}
              </a>
              <Checkbox
                label="Send in the confirmation"
                checked={x.include_in_confirmation}
                onChange={(c) =>
                  run(async () =>
                    check(
                      await supabase
                        .from('module_resource')
                        .update({ include_in_confirmation: c, version: x.version })
                        .eq('id', x.id)
                        .select(),
                    ),
                  )
                }
              />
              <Button
                size="sm"
                variant="ghost"
                onClick={() =>
                  run(
                    async () =>
                      check(await supabase.from('module_resource').delete().eq('id', x.id)),
                    'Link removed',
                  )
                }
              >
                Remove
              </Button>
            </li>
          ))}
        </ul>
      )}
      <div className="flex flex-wrap items-start gap-2">
        <Field label="Name" error={v.show('title')}>
          <Input
            placeholder="Module page"
            value={r.title}
            onBlur={v.touch('title')}
            onChange={(e) => setR({ ...r, title: e.target.value })}
            className="w-56"
          />
        </Field>
        <Field label="Link" error={v.show('url')}>
          <Input
            placeholder="https://"
            value={r.url}
            onBlur={v.touch('url')}
            onChange={(e) => setR({ ...r, url: e.target.value })}
            className="w-80"
          />
        </Field>
        <Button
          variant="secondary"
          className="mt-6"
          onClick={() =>
            v.submit() &&
            run(async () => {
              check(
                await supabase.from('module_resource').insert({
                  module_id: m.id,
                  title: r.title.trim(),
                  url: r.url.trim(),
                  sort_order: items.length + 1,
                }),
              );
              setR({ title: '', url: '' });
              v.reset();
            }, 'Link added')
          }
        >
          Add link
        </Button>
      </div>
    </section>
  );
}

// Who we ask next for each upcoming class week: the same function the automation uses.
export function WhoIsNext({ moduleId }: { moduleId: string }) {
  const { domain } = useDomain();
  const weeks = useWeeks(domain?.id);
  const upcoming = (weeks.data ?? []).filter(
    (w) =>
      w.module_id === moduleId &&
      !['Confirmed', 'Completed', 'Cancelled'].includes(w.status) &&
      w.first_class_at &&
      new Date(w.first_class_at) > new Date(),
  );
  const previews = useQuery({
    queryKey: ['request', 'who-next', moduleId, upcoming.map((w) => w.id).join()],
    enabled: upcoming.length > 0,
    queryFn: async () =>
      Promise.all(
        upcoming.slice(0, 12).map(async (w) => ({
          w,
          p: (await rpc('preview_next', { p_module_week_id: w.id })) as {
            asking?: { name: string } | null;
            next?: string | null;
          },
        })),
      ),
  });
  return (
    <section>
      {upcoming.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          Every upcoming class week of this module already has an instructor, or none is planned
          yet.
        </p>
      ) : (
        <ul className="divide-y divide-border rounded-md border border-border text-sm">
          {(previews.data ?? []).map(({ w, p }) => (
            <li key={w.id} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2">
              <span>
                Class week of {fmtAt(w.first_class_at, weekRegion(w.class_session))}
                {w.cohort && ` (${w.cohort})`}
              </span>
              <span>
                {p.asking ? (
                  <>
                    Asking <strong>{p.asking.name}</strong> now, then{' '}
                  </>
                ) : (
                  'Next: '
                )}
                <strong>{p.next ?? 'nobody left to ask'}</strong>
              </span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
