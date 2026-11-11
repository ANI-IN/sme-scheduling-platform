import { useMemo, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { DateTime } from 'luxon';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { useDomain } from '@/lib/domain';
import {
  LIVE_CHECK_MS,
  useCohorts,
  useInstructors,
  useModules,
  useNameBook,
  useTeam,
  type HistoryEvent,
} from '@/lib/data';
import { describeHistory } from '@/lib/historyText';
import { plain } from '@/lib/plain';
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
  SkeletonRows,
  Toolbar,
  td,
  th,
} from '@/components/ui';

/** Activity history loads 100 entries at a time. */
const PAGE = 100;

export default function History() {
  const { domain } = useDomain();
  const modules = useModules(domain?.id);
  const cohorts = useCohorts(domain?.id, true);
  const [limit, setLimit] = useState(PAGE);
  const instructors = useInstructors();
  const team = useTeam();
  const qc = useQueryClient();
  const confirm = useConfirm();
  const [f, setF] = useState({
    scope: 'domain',
    category: '',
    cohort: '',
    module: '',
    instructor: '',
    actor: '',
    from: '',
    to: '',
    q: '',
  });
  const [err, setErr] = useState<unknown>(null);
  const book = useNameBook();
  const [open, setOpen] = useState<Set<number>>(new Set());

  const events = useQuery({
    queryKey: [
      'history_event',
      domain?.id,
      f.scope,
      f.category,
      f.cohort,
      f.module,
      f.instructor,
      f.actor,
      f.from,
      f.to,
      limit,
    ],
    // Checks for new tasks every 30 seconds while open, in case a live update was missed.
    refetchInterval: LIVE_CHECK_MS,
    queryFn: async () => {
      let q = supabase
        .from('history_event')
        .select('*, undoable')
        .order('id', { ascending: false })
        .limit(limit);
      if (f.scope === 'domain' && domain) q = q.or(`domain_id.eq.${domain.id},domain_id.is.null`);
      if (f.category) q = q.eq('category', f.category);
      if (f.cohort) q = q.eq('cohort_id', f.cohort);
      if (f.module) q = q.eq('module_id', f.module);
      if (f.instructor) q = q.eq('instructor_id', f.instructor);
      if (f.actor) q = q.eq('actor_team_member_id', f.actor);
      if (f.from) q = q.gte('at', DateTime.fromISO(f.from).startOf('day').toUTC().toISO()!);
      if (f.to) q = q.lte('at', DateTime.fromISO(f.to).endOf('day').toUTC().toISO()!);
      return check(await q) as (HistoryEvent & { undoable: boolean | null })[];
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

  const exportCsv = () => {
    void rpc('log_export', {
      p_what: 'Activity history',
      p_rows: rows.length,
      p_filters: f,
      p_domain_id: domain?.id,
    }).catch(() => {});
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
          what: describeHistory(e, book).sentence,
          module: e.module_id ? names.get(e.module_id) : '',
          instructor: e.instructor_id ? names.get(e.instructor_id) : '',
          note: e.note,
          before: e.before,
          after: e.after,
        })),
      ),
    );
  };

  // The database decides what can be undone (never creating or deleting a domain, cohort or module).
  const canUndo = (e: HistoryEvent & { undoable?: boolean | null }) =>
    !!e.undoable && !undone.has(e.id);

  return (
    <div>
      <PageHeader
        title="Activity history"
        description="Everything that happened: changes, messages, answers and automatic checks. It cannot be edited or deleted."
      >
        <Button variant="secondary" onClick={exportCsv} disabled={rows.length === 0}>
          Download as spreadsheet
        </Button>
      </PageHeader>
      <Toolbar>
        <Select
          aria-label="Domains"
          value={f.scope}
          onChange={(e) => setF({ ...f, scope: e.target.value })}
          className="w-40"
        >
          <option value="domain">This domain</option>
          <option value="all">All domains</option>
        </Select>
        <Select
          aria-label="Type of change"
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
          aria-label="Cohort"
          value={f.cohort}
          onChange={(e) => setF({ ...f, cohort: e.target.value })}
          className="w-44"
        >
          <option value="">All cohorts</option>
          {(cohorts.data ?? []).map((c) => (
            <option key={c.id} value={c.id}>
              {c.name}
            </option>
          ))}
        </Select>
        <Select
          aria-label="Module"
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
          aria-label="Instructor"
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
          aria-label="Changed by"
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
        <label className="flex items-center gap-2 text-sm text-muted-foreground">
          From
          <Input
            type="date"
            value={f.from}
            onChange={(e) => setF({ ...f, from: e.target.value })}
            className="w-40"
          />
        </label>
        <label className="flex items-center gap-2 text-sm text-muted-foreground">
          To
          <Input
            type="date"
            value={f.to}
            onChange={(e) => setF({ ...f, to: e.target.value })}
            className="w-40"
          />
        </label>
        <Input
          placeholder="Search"
          value={f.q}
          onChange={(e) => setF({ ...f, q: e.target.value })}
          className="w-48"
          aria-label="Search activity"
        />
      </Toolbar>
      <ErrorText error={err ?? events.error} />
      {events.isLoading ? (
        <SkeletonRows rows={8} />
      ) : rows.length === 0 ? (
        <Empty title="Nothing here yet">
          Every change, message and decision appears here. History can’t be edited or deleted.
        </Empty>
      ) : (
        <div className="overflow-x-auto rounded-lg border bg-card">
          <table className="w-full">
            <thead className="border-b bg-muted">
              <tr>
                <th className={th}>When (your time)</th>
                <th className={th}>Who</th>
                <th className={th}>What happened</th>
                <th className={th}></th>
              </tr>
            </thead>
            <tbody>
              {rows.map((e) => (
                <tr key={e.id} className="border-b last:border-0">
                  <td className={`${td} whitespace-nowrap`} title={`PT: ${fmtPT(e.at)}`}>
                    {fmtLocal(e.at)}
                    {e.sim_at && (
                      <div className="text-xs text-warning-strong">
                        practice clock: {fmtPT(e.sim_at)}
                      </div>
                    )}
                  </td>
                  <td className={td}>
                    {e.actor_label}
                    <div className="text-xs text-muted-foreground">
                      {e.actor_kind === 'TeamMember' ? 'Team' : e.actor_kind}
                    </div>
                  </td>
                  <td className={`${td} max-w-xl`}>
                    {(() => {
                      const d = describeHistory(e, book);
                      return (
                        <>
                          <div>
                            {d.sentence}
                            {e.is_test && <Badge tone="amber">Testing</Badge>}
                            {undone.has(e.id) && <Badge tone="purple">Undone</Badge>}
                          </div>
                          {d.changes.length > 0 && (
                            <ul className="mt-1 space-y-0.5 text-xs text-muted-foreground">
                              {d.changes.map((c) => (
                                <li key={c.label}>
                                  <span className="font-medium">{c.label}:</span> {c.from} → {c.to}
                                </li>
                              ))}
                            </ul>
                          )}
                          {e.note && e.category !== 'Setup changes' && (
                            <div className="mt-1 text-xs whitespace-pre-line text-muted-foreground">
                              {plain(e.note)}
                            </div>
                          )}
                          <button
                            className="mt-1 text-xs text-link hover:underline"
                            onClick={() => {
                              const n = new Set(open);
                              if (n.has(e.id)) n.delete(e.id);
                              else n.add(e.id);
                              setOpen(n);
                            }}
                          >
                            {open.has(e.id) ? 'Hide details' : 'Show details'}
                          </button>
                          {open.has(e.id) && (
                            <pre className="mt-1 max-h-48 overflow-auto rounded bg-muted p-2 text-[11px] whitespace-pre-wrap text-muted-foreground">
                              {JSON.stringify(
                                {
                                  type: e.category,
                                  record: e.entity_table,
                                  action: e.action,
                                  note: e.note,
                                  before: e.before,
                                  after: e.after,
                                },
                                null,
                                2,
                              )}
                            </pre>
                          )}
                        </>
                      );
                    })()}
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
          {(events.data ?? []).length >= limit && (
            <div className="border-t border-border p-3 text-center">
              <Button variant="secondary" onClick={() => setLimit(limit + PAGE)}>
                Show more
              </Button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
