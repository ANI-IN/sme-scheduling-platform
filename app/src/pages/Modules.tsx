import { useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { GripVertical, Plus, Trash2 } from 'lucide-react';
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
import {
  useInstructors,
  useModules,
  useSettingsMap,
  useTeam,
  useWeeks,
  type Domain,
} from '@/lib/data';
import { fmtPT } from '@/lib/time';
import { isDiscordId } from '@/lib/validation';
import { useConfirm } from '@/components/Confirm';
import {
  Badge,
  Button,
  Card,
  Checkbox,
  Empty,
  ErrorText,
  Field,
  Input,
  Modal,
  PageHeader,
  Select,
  Spinner,
  td,
  th,
} from '@/components/ui';
import { useInstructorContext } from './Instructors';

type ModuleRow = NonNullable<ReturnType<typeof useModules>['data']>[number];
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

export default function Modules() {
  const { domain } = useDomain();
  const modules = useModules(domain?.id);
  const instructors = useInstructors();
  const settings = useSettingsMap(domain?.id);
  const [openId, setOpenId] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const minActive = Number(settings.data?.min_active_instructors ?? 2);

  const warnings = (m: ModuleRow): string[] => {
    const byId = new Map((instructors.data ?? []).map((i) => [i.id, i]));
    const ranked = [...m.module_ranking]
      .sort((a, b) => a.rank - b.rank)
      .map((r) => byId.get(r.instructor_id));
    const active = ranked.filter((i) => i?.status === 'Active').length;
    const w: string[] = [];
    if (active < minActive)
      w.push(`Only ${active} active instructor${active === 1 ? '' : 's'} (minimum ${minActive})`);
    if (ranked[0] && ranked[0].status !== 'Active') w.push('Primary is inactive');
    if (ranked.some((i) => i && !i.verified_at)) w.push('Unverified instructor in ranking');
    if (m.module_owner.length === 0) w.push('No owner');
    if (m.module_resource.length === 0) w.push('No resources');
    if (m.class_pattern_item.length === 0) w.push('No class pattern');
    return w;
  };

  const open = modules.data?.find((m) => m.id === openId) ?? null;

  return (
    <div className="space-y-5">
      <DomainPanel />
      {domain && (
        <>
          <PageHeader title={`Modules — ${domain.name}`}>
            <Button onClick={() => setAdding(true)}>
              <Plus className="h-4 w-4" /> Add module
            </Button>
          </PageHeader>
          {modules.isLoading ? (
            <Spinner />
          ) : (modules.data ?? []).length === 0 ? (
            <Empty title="No modules yet">Add the modules of this domain in rotation order.</Empty>
          ) : (
            <div className="overflow-x-auto rounded-lg border bg-card">
              <table className="w-full">
                <thead className="border-b bg-muted">
                  <tr>
                    <th className={th}>#</th>
                    <th className={th}>Module</th>
                    <th className={th}>Status</th>
                    <th className={th}>Owners</th>
                    <th className={th}>Active in ranking</th>
                    <th className={th}>Warnings</th>
                  </tr>
                </thead>
                <tbody>
                  {modules.data!.map((m) => (
                    <ModuleListRow
                      key={m.id}
                      m={m}
                      warnings={warnings(m)}
                      onOpen={() => setOpenId(m.id)}
                    />
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
      {open && (
        <ModuleDetail module={open} onClose={() => setOpenId(null)} warnings={warnings(open)} />
      )}
      {adding && domain && (
        <AddModule
          domain={domain}
          next={(modules.data?.length ?? 0) + 1}
          onClose={() => setAdding(false)}
        />
      )}
    </div>
  );
}

function ModuleListRow({
  m,
  warnings,
  onOpen,
}: {
  m: ModuleRow;
  warnings: string[];
  onOpen: () => void;
}) {
  const team = useTeam();
  const instructors = useInstructors();
  const names = new Map((team.data ?? []).map((t) => [t.id, t.name]));
  const active = m.module_ranking.filter(
    (r) => instructors.data?.find((i) => i.id === r.instructor_id)?.status === 'Active',
  ).length;
  return (
    <tr className="cursor-pointer border-b last:border-0 hover:bg-muted" onClick={onOpen}>
      <td className={td}>{m.rotation_order}</td>
      <td className={`${td} font-medium`}>{m.name}</td>
      <td className={td}>
        <Badge tone={m.status === 'Active' ? 'green' : 'gray'}>{m.status}</Badge>
      </td>
      <td className={td}>
        {m.module_owner.map((o) => names.get(o.team_member_id)).join(', ') || '—'}
      </td>
      <td className={td}>{active}</td>
      <td className={td}>
        <div className="flex flex-wrap gap-1">
          {warnings.map((w) => (
            <Badge key={w} tone="amber">
              {w}
            </Badge>
          ))}
        </div>
      </td>
    </tr>
  );
}

// ------------------------------------------------------------------ domain panel (DOM-1)
function DomainPanel() {
  const { domain, setDomainId } = useDomain();
  const team = useTeam();
  const qc = useQueryClient();
  const confirm = useConfirm();
  const [err, setErr] = useState<unknown>(null);
  const [newName, setNewName] = useState('');
  const [alert, setAlert] = useState(domain?.alert_discord_channel_id ?? '');
  const roles = useQuery({
    queryKey: ['domain_team', domain?.id],
    enabled: !!domain,
    queryFn: async () =>
      check(await supabase.from('domain_team').select('*').eq('domain_id', domain!.id)),
  });

  async function run(fn: () => Promise<unknown>, ok?: string) {
    setErr(null);
    try {
      await fn();
      if (ok) toast.success(ok);
      await qc.invalidateQueries();
    } catch (e) {
      setErr(e);
    }
  }

  async function setStatus(d: Domain, status: string) {
    if (d.status === 'Test' && status !== 'Test') {
      if (
        !(await confirm({
          title: 'Turn test mode off?',
          body: `${d.name} will contact REAL instructors from the next hourly check.`,
          danger: true,
          confirmLabel: 'Turn test mode off',
        }))
      )
        return;
    }
    await run(
      () => rpc('set_domain_status', { p_domain_id: d.id, p_status: status }),
      `Status: ${status}`,
    );
  }

  async function toggleRole(memberId: string, role: 'Lead' | 'Ops', on: boolean) {
    if (!domain) return;
    await run(async () =>
      on
        ? check(
            await supabase
              .from('domain_team')
              .insert({ domain_id: domain.id, team_member_id: memberId, role }),
          )
        : check(
            await supabase
              .from('domain_team')
              .delete()
              .eq('domain_id', domain.id)
              .eq('team_member_id', memberId)
              .eq('role', role),
          ),
    );
  }

  return (
    <Card className="p-4">
      <div className="flex flex-wrap items-end gap-3">
        {domain && (
          <>
            <Field
              label="Domain status"
              hint="Draft and Paused are skipped by the hourly check. Test sends to test channels only."
            >
              <Select
                value={domain.status}
                onChange={(e) => void setStatus(domain, e.target.value)}
                className="w-40"
              >
                {['Draft', 'Test', 'Live', 'Paused'].map((s) => (
                  <option key={s}>{s}</option>
                ))}
              </Select>
            </Field>
            <Field
              label="Alert Discord channel ID"
              error={alert && !isDiscordId(alert) ? '17–20 digits' : undefined}
            >
              <div className="flex gap-2">
                <Input value={alert} onChange={(e) => setAlert(e.target.value)} className="w-56" />
                <Button
                  variant="outline"
                  disabled={!!alert && !isDiscordId(alert)}
                  onClick={() =>
                    run(
                      async () =>
                        check(
                          await supabase
                            .from('domain')
                            .update({
                              alert_discord_channel_id: alert || null,
                              version: domain.version,
                            })
                            .eq('id', domain.id)
                            .select(),
                        ),
                      'Saved',
                    )
                  }
                >
                  Save
                </Button>
              </div>
            </Field>
          </>
        )}
        <Field label="New domain">
          <div className="flex gap-2">
            <Input
              value={newName}
              placeholder="e.g. Fullstack"
              onChange={(e) => setNewName(e.target.value)}
              className="w-44"
            />
            <Button
              variant="outline"
              disabled={!newName.trim()}
              onClick={() =>
                run(async () => {
                  const d = check(
                    await supabase
                      .from('domain')
                      .insert({ name: newName.trim(), status: 'Draft' })
                      .select()
                      .single(),
                  )!;
                  setNewName('');
                  setDomainId(d.id);
                }, 'Domain created (Draft)')
              }
            >
              Create
            </Button>
          </div>
        </Field>
      </div>
      {domain && (
        <div className="mt-4 grid gap-4 sm:grid-cols-2">
          {(['Lead', 'Ops'] as const).map((role) => (
            <div key={role}>
              <div className="mb-1 text-sm font-medium">
                {role === 'Lead' ? 'Domain leads' : 'Ops contacts'}
              </div>
              <div className="flex flex-wrap gap-3">
                {(team.data ?? [])
                  .filter((t) => t.active)
                  .map((t) => (
                    <Checkbox
                      key={t.id}
                      label={t.name}
                      checked={
                        !!roles.data?.some((r) => r.team_member_id === t.id && r.role === role)
                      }
                      onChange={(v) => void toggleRole(t.id, role, v)}
                    />
                  ))}
                {(team.data ?? []).length === 0 && (
                  <span className="text-sm text-muted-foreground">
                    Add team members in Settings first.
                  </span>
                )}
              </div>
            </div>
          ))}
        </div>
      )}
      <ErrorText error={err} />
    </Card>
  );
}

function AddModule({
  domain,
  next,
  onClose,
}: {
  domain: Domain;
  next: number;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const [name, setName] = useState('');
  const [order, setOrder] = useState(next);
  const [err, setErr] = useState<unknown>(null);
  return (
    <Modal open onOpenChange={(o) => !o && onClose()} title="Add module">
      <div className="space-y-3">
        <Field label="Module name">
          <Input value={name} onChange={(e) => setName(e.target.value)} autoFocus />
        </Field>
        <Field label="Rotation order" hint="1 = first module of the rotation.">
          <Input
            type="number"
            min={1}
            value={order}
            onChange={(e) => setOrder(Number(e.target.value))}
          />
        </Field>
        <ErrorText error={err} />
        <Button
          disabled={!name.trim()}
          onClick={async () => {
            try {
              check(
                await supabase
                  .from('module')
                  .insert({ domain_id: domain.id, name: name.trim(), rotation_order: order }),
              );
              await qc.invalidateQueries();
              onClose();
            } catch (e) {
              setErr(e);
            }
          }}
        >
          Add
        </Button>
      </div>
    </Modal>
  );
}

// ------------------------------------------------------------------ module detail
function ModuleDetail({
  module: m,
  onClose,
  warnings,
}: {
  module: ModuleRow;
  onClose: () => void;
  warnings: string[];
}) {
  const qc = useQueryClient();
  const team = useTeam();
  const confirm = useConfirm();
  const [err, setErr] = useState<unknown>(null);
  const [f, setF] = useState({
    name: m.name,
    rotation_order: m.rotation_order,
    status: m.status,
    same: m.same_instructor_for_module_week,
  });

  async function run(fn: () => Promise<unknown>, ok?: string) {
    setErr(null);
    try {
      await fn();
      if (ok) toast.success(ok);
      await qc.invalidateQueries();
    } catch (e) {
      setErr(e);
    }
  }

  return (
    <Modal open onOpenChange={(o) => !o && onClose()} title={m.name} wide>
      <div className="space-y-5">
        {warnings.length > 0 && (
          <div className="flex flex-wrap gap-1">
            {warnings.map((w) => (
              <Badge key={w} tone="amber">
                {w}
              </Badge>
            ))}
          </div>
        )}
        <section className="grid gap-3 sm:grid-cols-4">
          <Field label="Name">
            <Input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} />
          </Field>
          <Field label="Rotation order">
            <Input
              type="number"
              min={1}
              value={f.rotation_order}
              onChange={(e) => setF({ ...f, rotation_order: Number(e.target.value) })}
            />
          </Field>
          <Field label="Status">
            <Select value={f.status} onChange={(e) => setF({ ...f, status: e.target.value })}>
              {['Active', 'Inactive', 'Archived'].map((s) => (
                <option key={s}>{s}</option>
              ))}
            </Select>
          </Field>
          <div className="flex items-end gap-2">
            <Button
              onClick={() =>
                run(
                  async () =>
                    check(
                      await supabase
                        .from('module')
                        .update({
                          name: f.name.trim(),
                          rotation_order: f.rotation_order,
                          status: f.status,
                          same_instructor_for_module_week: f.same,
                          version: m.version,
                        })
                        .eq('id', m.id)
                        .select(),
                    ),
                  'Module saved',
                )
              }
            >
              Save
            </Button>
          </div>
          <div className="sm:col-span-4">
            <Checkbox
              label="Same instructor teaches the whole module week (live class + review)"
              checked={f.same}
              onChange={(v) => setF({ ...f, same: v })}
            />
          </div>
        </section>

        <section>
          <h3 className="mb-1 font-medium">Owners</h3>
          <div className="flex flex-wrap gap-3">
            {(team.data ?? [])
              .filter((t) => t.active)
              .map((t) => (
                <Checkbox
                  key={t.id}
                  label={t.name}
                  checked={m.module_owner.some((o) => o.team_member_id === t.id)}
                  onChange={(on) =>
                    run(async () =>
                      on
                        ? check(
                            await supabase
                              .from('module_owner')
                              .insert({ module_id: m.id, team_member_id: t.id }),
                          )
                        : check(
                            await supabase
                              .from('module_owner')
                              .delete()
                              .eq('module_id', m.id)
                              .eq('team_member_id', t.id),
                          ),
                    )
                  }
                />
              ))}
          </div>
        </section>

        <PatternEditor module={m} run={run} />
        <RankingEditor module={m} />
        <Resources module={m} run={run} />
        <WhoIsNext moduleId={m.id} />
        <ErrorText error={err} />
        <div className="border-t pt-3">
          <Button
            variant="ghost"
            onClick={async () => {
              if (
                await confirm({
                  title: `Archive ${m.name}?`,
                  body: 'Modules with past classes are archived, not deleted. It stops being used for new plans and outreach.',
                  danger: true,
                })
              )
                await run(
                  async () =>
                    check(
                      await supabase
                        .from('module')
                        .update({ status: 'Archived', version: m.version })
                        .eq('id', m.id)
                        .select(),
                    ),
                  'Archived',
                );
            }}
          >
            Archive module
          </Button>
        </div>
      </div>
    </Modal>
  );
}

type Run = (fn: () => Promise<unknown>, ok?: string) => Promise<void>;

function PatternEditor({ module: m, run }: { module: ModuleRow; run: Run }) {
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

function SortableRow({ id, children }: { id: string; children: React.ReactNode }) {
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
function RankingEditor({ module: m }: { module: ModuleRow }) {
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

function Resources({ module: m, run }: { module: ModuleRow; run: Run }) {
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
function WhoIsNext({ moduleId }: { moduleId: string }) {
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
