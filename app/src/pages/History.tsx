import { useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { DateTime } from 'luxon';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import { useInstructors, useModules, useTeam, type HistoryEvent } from '@/lib/data';
import { fmtLocal, fmtPT } from '@/lib/time';
import { historyCategories } from '@/lib/labels';
import { downloadCsv, toCsv } from '@/lib/csv';
import { useConfirm } from '@/components/Confirm';
import {
  Badge,
  Button,
  Empty,
  ErrorText,
  Input,
  PageHeader,
  Select,
  Spinner,
  td,
  th,
} from '@/components/ui';

const IGNORED = new Set(['updated_at', 'updated_by', 'version', 'created_at', 'id']);

function diff(before: unknown, after: unknown): string[] {
  const b = (before ?? {}) as Record<string, unknown>;
  const a = (after ?? {}) as Record<string, unknown>;
  const keys = [...new Set([...Object.keys(b), ...Object.keys(a)])].filter((k) => !IGNORED.has(k));
  return keys
    .filter((k) => JSON.stringify(b[k]) !== JSON.stringify(a[k]))
    .map(
      (k) =>
        `${k}: ${before ? JSON.stringify(b[k] ?? null) : '—'} → ${after ? JSON.stringify(a[k] ?? null) : '—'}`,
    );
}

export default function History() {
  const { domain } = useDomain();
  const modules = useModules(domain?.id);
  const instructors = useInstructors();
  const team = useTeam();
  const qc = useQueryClient();
  const confirm = useConfirm();
  const [f, setF] = useState({
    scope: 'domain',
    category: '',
    module: '',
    instructor: '',
    actor: '',
    from: '',
    to: '',
    q: '',
  });
  const [err, setErr] = useState<unknown>(null);

  const events = useQuery({
    queryKey: [
      'history_event',
      domain?.id,
      f.scope,
      f.category,
      f.module,
      f.instructor,
      f.actor,
      f.from,
      f.to,
    ],
    queryFn: async () => {
      let q = supabase
        .from('history_event')
        .select('*')
        .order('id', { ascending: false })
        .limit(1000);
      if (f.scope === 'domain' && domain) q = q.or(`domain_id.eq.${domain.id},domain_id.is.null`);
      if (f.category) q = q.eq('category', f.category);
      if (f.module) q = q.eq('module_id', f.module);
      if (f.instructor) q = q.eq('instructor_id', f.instructor);
      if (f.actor) q = q.eq('actor_team_member_id', f.actor);
      if (f.from) q = q.gte('at', DateTime.fromISO(f.from).startOf('day').toUTC().toISO()!);
      if (f.to) q = q.lte('at', DateTime.fromISO(f.to).endOf('day').toUTC().toISO()!);
      return check(await q);
    },
  });

  const undone = useMemo(
    () => new Set((events.data ?? []).map((e) => e.undo_of).filter(Boolean) as number[]),
    [events.data],
  );
  const names = useMemo(() => {
    const m = new Map<string, string>();
    (modules.data ?? []).forEach((x) => m.set(x.id, x.name));
    (instructors.data ?? []).forEach((x) => m.set(x.id, x.full_name));
    return m;
  }, [modules.data, instructors.data]);

  const rows = (events.data ?? []).filter((e) =>
    f.q
      ? `${e.action} ${e.note ?? ''} ${e.actor_label ?? ''} ${JSON.stringify(e.after ?? '')}`
          .toLowerCase()
          .includes(f.q.toLowerCase())
      : true,
  );

  const exportCsv = () =>
    downloadCsv(
      `history-${DateTime.now().toFormat('yyyy-LL-dd')}.csv`,
      toCsv(
        rows.map((e) => ({
          id: e.id,
          when_local: fmtLocal(e.at),
          when_utc: e.at,
          simulated_time: e.sim_at ?? '',
          who: e.actor_label,
          actor_kind: e.actor_kind,
          category: e.category,
          action: e.action,
          module: e.module_id ? names.get(e.module_id) : '',
          instructor: e.instructor_id ? names.get(e.instructor_id) : '',
          note: e.note,
          before: e.before,
          after: e.after,
        })),
      ),
    );

  const canUndo = (e: HistoryEvent) =>
    e.category === 'Setup changes' && !e.undo_of && !undone.has(e.id) && !!e.entity_table;

  return (
    <div>
      <PageHeader title="History">
        <Button variant="outline" onClick={exportCsv} disabled={rows.length === 0}>
          Export CSV
        </Button>
      </PageHeader>
      <div className="mb-3 flex flex-wrap gap-2">
        <Select
          value={f.scope}
          onChange={(e) => setF({ ...f, scope: e.target.value })}
          className="w-40"
        >
          <option value="domain">This domain</option>
          <option value="all">All domains</option>
        </Select>
        <Select
          value={f.category}
          onChange={(e) => setF({ ...f, category: e.target.value })}
          className="w-44"
        >
          <option value="">All types</option>
          {historyCategories.map((c) => (
            <option key={c}>{c}</option>
          ))}
        </Select>
        <Select
          value={f.module}
          onChange={(e) => setF({ ...f, module: e.target.value })}
          className="w-44"
        >
          <option value="">All modules</option>
          {(modules.data ?? []).map((m) => (
            <option key={m.id} value={m.id}>
              {m.name}
            </option>
          ))}
        </Select>
        <Select
          value={f.instructor}
          onChange={(e) => setF({ ...f, instructor: e.target.value })}
          className="w-44"
        >
          <option value="">All instructors</option>
          {(instructors.data ?? []).map((i) => (
            <option key={i.id} value={i.id}>
              {i.full_name}
            </option>
          ))}
        </Select>
        <Select
          value={f.actor}
          onChange={(e) => setF({ ...f, actor: e.target.value })}
          className="w-44"
        >
          <option value="">Anyone</option>
          {(team.data ?? []).map((t) => (
            <option key={t.id} value={t.id}>
              {t.name}
            </option>
          ))}
        </Select>
        <Input
          type="date"
          value={f.from}
          onChange={(e) => setF({ ...f, from: e.target.value })}
          className="w-40"
          title="From"
        />
        <Input
          type="date"
          value={f.to}
          onChange={(e) => setF({ ...f, to: e.target.value })}
          className="w-40"
          title="To"
        />
        <Input
          placeholder="Search"
          value={f.q}
          onChange={(e) => setF({ ...f, q: e.target.value })}
          className="w-48"
        />
      </div>
      <ErrorText error={err ?? events.error} />
      {events.isLoading ? (
        <Spinner />
      ) : rows.length === 0 ? (
        <Empty title="Nothing here yet">
          Every change, message and decision appears here. History can’t be edited or deleted.
        </Empty>
      ) : (
        <div className="overflow-x-auto rounded-lg border bg-white">
          <table className="w-full">
            <thead className="border-b bg-slate-50">
              <tr>
                <th className={th}>When (your time)</th>
                <th className={th}>Who</th>
                <th className={th}>What</th>
                <th className={th}>Related</th>
                <th className={th}>Details</th>
                <th className={th}></th>
              </tr>
            </thead>
            <tbody>
              {rows.map((e) => (
                <tr key={e.id} className="border-b last:border-0">
                  <td className={`${td} whitespace-nowrap`} title={`PT: ${fmtPT(e.at)}`}>
                    {fmtLocal(e.at)}
                    {e.sim_at && (
                      <div className="text-xs text-amber-700">test clock: {fmtPT(e.sim_at)}</div>
                    )}
                  </td>
                  <td className={td}>
                    {e.actor_label}
                    <div className="text-xs text-slate-500">
                      {e.actor_kind === 'TeamMember' ? 'Team' : e.actor_kind}
                    </div>
                  </td>
                  <td className={td}>
                    <Badge>{e.category}</Badge> <span className="ml-1">{e.action}</span>
                    {e.is_test && <Badge tone="amber">TEST</Badge>}
                    {undone.has(e.id) && <Badge tone="purple">Undone</Badge>}
                  </td>
                  <td className={`${td} text-xs`}>
                    {[
                      e.module_id && names.get(e.module_id),
                      e.instructor_id && names.get(e.instructor_id),
                    ]
                      .filter(Boolean)
                      .join(' · ')}
                  </td>
                  <td className={`${td} max-w-md text-xs`}>
                    {e.note && <div className="whitespace-pre-line">{e.note}</div>}
                    {e.category === 'Setup changes' &&
                      diff(e.before, e.after)
                        .slice(0, 6)
                        .map((d) => (
                          <div
                            key={d}
                            className="truncate font-mono text-[11px] text-slate-600"
                            title={d}
                          >
                            {d}
                          </div>
                        ))}
                  </td>
                  <td className={td}>
                    {canUndo(e) && (
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={async () => {
                          if (
                            !(await confirm({
                              title: 'Undo this change?',
                              body: 'Restores the previous values. Messages already sent are not recalled.',
                            }))
                          )
                            return;
                          setErr(null);
                          try {
                            await rpc('undo_history_event', { p_event_id: e.id });
                            toast.success('Undone');
                            await qc.invalidateQueries();
                          } catch (x) {
                            setErr(x);
                          }
                        }}
                      >
                        Undo
                      </Button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
