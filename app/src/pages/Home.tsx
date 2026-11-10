import { useMemo } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { DateTime } from 'luxon';
import { CalendarDays } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { check } from '@/lib/rpc';
import { useDomain, useDomainNow } from '@/lib/domain';
import { useInstructors, useWeeks } from '@/lib/data';
import { fmtPT, PT } from '@/lib/time';
import { weekState } from '@/lib/status';
import {
  Badge,
  Empty,
  PageHeader,
  Section,
  SkeletonRows,
  Stat,
  tableWrap,
  td,
  th,
  thead,
  trow,
} from '@/components/ui';
import { TaskList } from './NeedsAttention';

const OPEN = ['Queued', 'Sent', 'Reminded'];

export default function Home() {
  const { domain } = useDomain();
  const now = useDomainNow();
  const weeks = useWeeks(domain?.id);
  const instructors = useInstructors();
  const names = useMemo(
    () => new Map((instructors.data ?? []).map((i) => [i.id, i.full_name])),
    [instructors.data],
  );

  const counts = useQuery({
    queryKey: ['attention_item', 'home-counts', domain?.id],
    enabled: !!domain,
    queryFn: async () => {
      const rows = check(
        await supabase
          .from('attention_item')
          .select('severity, status, done_at')
          .or(`domain_id.eq.${domain!.id},domain_id.is.null`)
          .or(`status.neq.Done,done_at.gte.${DateTime.now().startOf('day').toUTC().toISO()}`),
      );
      return {
        urgent: rows.filter((r) => r.status !== 'Done' && r.severity === 'Urgent').length,
        open: rows.filter((r) => r.status !== 'Done').length,
        doneToday: rows.filter((r) => r.status === 'Done').length,
      };
    },
  });

  // This week in Pacific time, Sunday to Saturday (class weeks start on Sunday).
  const ptNow = now.setZone(PT);
  const weekStart = ptNow.minus({ days: ptNow.weekday % 7 }).startOf('day');
  const weekEnd = weekStart.plus({ days: 7 });
  const upcoming = (weeks.data ?? []).filter(
    (w) =>
      !['Completed', 'Cancelled'].includes(w.status) &&
      (w.last_class_end_at ?? '') > now.toUTC().toISO()!,
  );
  const thisWeek = (weeks.data ?? [])
    .flatMap((w) => w.class_session.filter((c) => c.status !== 'Cancelled').map((c) => ({ w, c })))
    .filter(({ c }) => {
      const t = DateTime.fromISO(c.starts_at);
      return t >= weekStart && t < weekEnd;
    })
    .sort((a, b) => a.c.starts_at.localeCompare(b.c.starts_at));
  const looking = upcoming.filter(
    (w) =>
      !w.booking.some((b) => b.status === 'Active') &&
      w.first_class_at &&
      DateTime.fromISO(w.first_class_at) < now.plus({ days: 31 }),
  );
  const asking = upcoming.filter((w) =>
    w.request.some((r) => r.kind === 'Outreach' && OPEN.includes(r.status)),
  ).length;
  const help = upcoming.filter((w) =>
    w.help_request.some((h) => ['Open', 'InProgress', 'WaitingOnInstructor'].includes(h.status)),
  ).length;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Home"
        description={
          domain ? `What needs doing today for ${domain.name}.` : 'Choose a domain to get started.'
        }
      />
      <div className="flex flex-wrap gap-3">
        <Stat
          label="Urgent tasks"
          value={counts.data?.urgent ?? 0}
          tone="danger"
          hint="Answer these first"
        />
        <Stat
          label="Open tasks"
          value={counts.data?.open ?? 0}
          tone="info"
          hint={`${counts.data?.doneToday ?? 0} done today`}
        />
        <Stat
          label="Classes this week"
          value={thisWeek.length}
          tone="neutral"
          hint={`Week of ${weekStart.toFormat('LLL d')}`}
        />
        <Stat
          label="Still need an instructor"
          value={looking.length}
          tone="warning"
          hint={`In the next 30 days, ${asking} being asked`}
        />
        <Stat label="Open help requests" value={help} tone="accent" />
      </div>

      <Section
        title="Needs your attention"
        description="Tasks the automation could not finish on its own. Urgent tasks are listed first."
      >
        <TaskList />
      </Section>

      <Section
        title="This week's classes"
        description="Times are Pacific."
        actions={
          <Link to="/classes" className="text-sm font-medium text-link hover:underline">
            All upcoming classes
          </Link>
        }
      >
        {weeks.isLoading ? (
          <SkeletonRows rows={3} />
        ) : thisWeek.length === 0 ? (
          <Empty title="No classes this week" icon={<CalendarDays className="h-5 w-5" />}>
            Plan classes on the Upcoming classes page.
          </Empty>
        ) : (
          <div className={tableWrap}>
            <table className="w-full">
              <thead className={thead}>
                <tr>
                  <th className={th}>When</th>
                  <th className={th}>Class</th>
                  <th className={th}>Instructor</th>
                  <th className={th}>Status</th>
                </tr>
              </thead>
              <tbody>
                {thisWeek.map(({ w, c }) => {
                  const st = weekState(w, names);
                  return (
                    <tr key={c.id} className={trow}>
                      <td className={`${td} whitespace-nowrap`}>{fmtPT(c.starts_at)}</td>
                      <td className={td}>
                        <div className="font-medium">{w.module?.name}</div>
                        <div className="text-xs text-muted-foreground">{c.class_type}</div>
                      </td>
                      <td className={td}>
                        {st.confirmed ?? (
                          <span className="text-muted-foreground">Not confirmed</span>
                        )}
                      </td>
                      <td className={td}>
                        <Badge tone={st.tone}>{st.label}</Badge>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Section>
    </div>
  );
}
