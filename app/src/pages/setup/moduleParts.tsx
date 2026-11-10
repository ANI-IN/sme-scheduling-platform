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
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useInstructors, useModules, useWeeks } from '@/lib/data';
import { fmtPT } from '@/lib/time';
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

export type ModuleRow = NonNullable<ReturnType<typeof useModules>['data']>[number];
export const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

export type Run = (fn: () => Promise<unknown>, ok?: string) => Promise<void>;

export function PatternEditor({ module: m, run }: { module: ModuleRow; run: Run }) {
  const [n, setN] = useState({
    class_type: 'Live class',
    weekday_offset: 0,
    start_time_pt: '09:00',
    duration_minutes: 240,
  });
  const items = [...m.class_pattern_item].sort(
    (a, b) => a.weekday_offset - b.weekday_offset || a.start_time_pt.localeCompare(b.start_time_pt),
  );
  const dayLabel = (o: number) => `${WEEKDAYS[o % 7]}${o >= 7 ? ' (wk 2)' : ''}`;
  return (
    <section>
      <h3 className="mb-1 font-medium">Class pattern (Pacific Time)</h3>
      <table className="mb-2 w-full text-sm">
        <tbody>
          {items.map((p) => (
            <tr key={p.id} className="border-b">
              <td className="py-1">{p.class_type}</td>
              <td>{dayLabel(p.weekday_offset)}</td>
              <td>{p.start_time_pt.slice(0, 5)} PT</td>
              <td>{p.duration_minutes} min</td>
              <td className="text-right">
                <Button
                  size="sm"
                  variant="ghost"
                  aria-label="Remove"
                  onClick={() =>
                    run(async () =>
                      check(await supabase.from('class_pattern_item').delete().eq('id', p.id)),
                    )
                  }
                >
                  <Trash2 className="h-4 w-4" />
                </Button>
              </td>
            </tr>
          ))}
          {items.length === 0 && (
            <tr>
              <td className="py-1 text-muted-foreground">No classes in the pattern yet.</td>
            </tr>
          )}
        </tbody>
      </table>
      <div className="flex flex-wrap items-end gap-2">
        <Field label="Class type">
          <Select value={n.class_type} onChange={(e) => setN({ ...n, class_type: e.target.value })}>
            {['Live class', 'Assignment review', 'Other'].map((s) => (
              <option key={s}>{s}</option>
            ))}
          </Select>
        </Field>
        <Field label="Day" hint="Relative to the week's Sunday">
          <Select
            value={n.weekday_offset}
            onChange={(e) => setN({ ...n, weekday_offset: Number(e.target.value) })}
          >
            {Array.from({ length: 14 }, (_, i) => (
              <option key={i} value={i}>
                {dayLabel(i)}
              </option>
            ))}
          </Select>
        </Field>
        <Field label="Start (PT)">
          <Input
            type="time"
            value={n.start_time_pt}
            onChange={(e) => setN({ ...n, start_time_pt: e.target.value })}
          />
        </Field>
        <Field label="Minutes">
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
          variant="outline"
          onClick={() =>
            run(async () =>
              check(
                await supabase.from('class_pattern_item').insert({
                  module_id: m.id,
                  ...n,
                  title_template: '{module} — {class_type}',
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
export function RankingEditor({ module: m }: { module: ModuleRow }) {
  const qc = useQueryClient();
  const instructors = useInstructors();
  const ctx = useInstructorContext();
  const saved = useMemo(
    () => [...m.module_ranking].sort((a, b) => a.rank - b.rank).map((r) => r.instructor_id),
    [m.module_ranking],
  );
  const [order, setOrder] = useState<string[]>(saved);
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
      <h3 className="mb-1 font-medium">Ranking</h3>
      <p className="mb-2 text-xs text-muted-foreground">
        Rank 1 = Primary, then Backup 1, 2, … Changes apply to the next person asked, never to a
        request already sent.
      </p>
      <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={onDragEnd}>
        <SortableContext items={order} strategy={verticalListSortingStrategy}>
          <ol className="space-y-1">
            {order.map((id, idx) => {
              const i = byId.get(id);
              const greyed = !i || i.status !== 'Active' || !i.verified_at;
              return (
                <SortableRow key={id} id={id}>
                  <span className="w-20 text-xs text-muted-foreground">
                    {idx === 0 ? 'Primary' : `Backup ${idx}`}
                  </span>
                  <span className={greyed ? 'text-muted-foreground' : 'font-medium'}>
                    {i?.full_name ?? 'Unknown'}
                  </span>
                  {i && i.status !== 'Active' && <Badge>{i.status}</Badge>}
                  {i && !i.verified_at && <Badge tone="amber">Not verified</Badge>}
                  {i?.is_test && <Badge tone="purple">TEST</Badge>}
                  <span className="ml-2 truncate text-xs text-muted-foreground">
                    {(ctx.data?.upcoming.get(id) ?? []).slice(0, 2).join(' · ')}
                  </span>
                  <button
                    className="ml-auto text-muted-foreground hover:text-danger-strong"
                    aria-label="Remove from ranking"
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
        <Select value={add} onChange={(e) => setAdd(e.target.value)} className="w-64">
          <option value="">Add an instructor…</option>
          {(instructors.data ?? [])
            .filter((i) => i.status !== 'Archived' && !order.includes(i.id))
            .map((i) => (
              <option key={i.id} value={i.id}>
                {i.full_name}
                {i.status !== 'Active' ? ` (${i.status})` : ''}
                {!i.verified_at ? ' (not verified)' : ''}
              </option>
            ))}
        </Select>
        <Button
          variant="outline"
          disabled={!add}
          onClick={() => (setOrder([...order, add]), setAdd(''))}
        >
          Add
        </Button>
        <Button
          disabled={!dirty}
          onClick={async () => {
            setErr(null);
            try {
              setImpact(
                (await rpc('ranking_impact', {
                  p_module_id: m.id,
                  p_instructor_ids: order,
                })) as never,
              );
            } catch (e) {
              setErr(e);
            }
          }}
        >
          Review & save ranking
        </Button>
        {dirty && (
          <Button variant="ghost" onClick={() => setOrder(saved)}>
            Undo changes
          </Button>
        )}
      </div>
      <ErrorText error={err} />
      <Modal open={!!impact} onOpenChange={(o) => !o && setImpact(null)} title="Save this ranking?">
        {impact && (
          <div className="space-y-3 text-sm">
            <p>
              Affects <strong>{impact.affected_weeks}</strong> upcoming unconfirmed module week
              {impact.affected_weeks === 1 ? '' : 's'}. Confirmed ones ({impact.confirmed_weeks})
              stay as they are.
            </p>
            {impact.weeks.length > 0 && (
              <table className="w-full">
                <thead>
                  <tr>
                    <th className={th}>Module week</th>
                    <th className={th}>Next asked now</th>
                    <th className={th}>After saving</th>
                  </tr>
                </thead>
                <tbody>
                  {impact.weeks.map((w) => (
                    <tr key={w.label} className="border-t">
                      <td className={td}>{w.label}</td>
                      <td className={td}>{w.next_now ?? '—'}</td>
                      <td className={td}>{w.next_after ?? '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
            <div className="flex justify-end gap-2">
              <Button variant="outline" onClick={() => setImpact(null)}>
                Cancel
              </Button>
              <Button
                onClick={async () => {
                  try {
                    await rpc('save_ranking', {
                      p_module_id: m.id,
                      p_instructor_ids: order,
                      p_expected_ids: saved,
                    });
                    toast.success('Ranking saved');
                    setImpact(null);
                    await qc.invalidateQueries();
                  } catch (e) {
                    setErr(e);
                    setImpact(null);
                  }
                }}
              >
                Save ranking
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
  return (
    <section>
      <h3 className="mb-1 font-medium">Resources</h3>
      <ul className="mb-2 space-y-1 text-sm">
        {items.map((x) => (
          <li key={x.id} className="flex flex-wrap items-center gap-3">
            <a href={x.url} target="_blank" rel="noreferrer" className="text-link hover:underline">
              {x.title}
            </a>
            <Checkbox
              label="Include in confirmation"
              checked={x.include_in_confirmation}
              onChange={(v) =>
                run(async () =>
                  check(
                    await supabase
                      .from('module_resource')
                      .update({ include_in_confirmation: v, version: x.version })
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
                run(async () =>
                  check(await supabase.from('module_resource').delete().eq('id', x.id)),
                )
              }
            >
              Remove
            </Button>
          </li>
        ))}
        {items.length === 0 && <li className="text-muted-foreground">No resources yet.</li>}
      </ul>
      <div className="flex flex-wrap gap-2">
        <Input
          placeholder="Title"
          value={r.title}
          onChange={(e) => setR({ ...r, title: e.target.value })}
          className="w-48"
        />
        <Input
          placeholder="https://…"
          value={r.url}
          onChange={(e) => setR({ ...r, url: e.target.value })}
          className="w-72"
        />
        <Button
          variant="outline"
          disabled={!r.title.trim() || !/^https?:\/\//i.test(r.url)}
          onClick={() =>
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
            })
          }
        >
          Add resource
        </Button>
      </div>
    </section>
  );
}

// RANK-4: "Who will be asked next" for each upcoming module week — same function the engine uses.
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
      <h3 className="mb-1 font-medium">Who will be asked next</h3>
      {upcoming.length === 0 ? (
        <p className="text-sm text-muted-foreground">No upcoming unconfirmed module weeks.</p>
      ) : (
        <ul className="space-y-1 text-sm">
          {(previews.data ?? []).map(({ w, p }) => (
            <li key={w.id}>
              {fmtPT(w.first_class_at)}
              {w.cohort && ` (${w.cohort})`}:{' '}
              {p.asking ? (
                <>
                  asking <strong>{p.asking.name}</strong>, then{' '}
                </>
              ) : null}
              <strong>{p.next ?? 'nobody left in line'}</strong>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
