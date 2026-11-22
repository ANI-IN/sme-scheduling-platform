import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { DateTime } from 'luxon';
import { CalendarDays, CheckCircle2, Circle } from 'lucide-react';
import { supabase } from '@/lib/supabase';
import { check, rpc } from '@/lib/rpc';
import { useDomain, useDomainNow } from '@/lib/domain';
import { LIVE_CHECK_MS, useCohorts, useInstructors, useWeeks } from '@/lib/data';
import { PT } from '@/lib/time';
import { ClassTime, RegionBadge } from '@/components/ClassTime';
import { WEEK_STATUS, weekState, weeksById } from '@/lib/status';
import {
  Badge,
  Empty,
  LoadError,
  PageHeader,
  Section,
  Select,
  SkeletonRows,
  Stat,
  tableWrap,
  td,
  th,
  thead,
  trow,
} from '@/components/ui';
import { inCohort, TaskList } from './NeedsAttention';

const OPEN = ['Queued', 'Sent', 'Reminded'];

const scrollToTasks = () =>
  document.getElementById('tasks')?.scrollIntoView({ behavior: 'smooth', block: 'start' });

export default function Home() {
  const { domain } = useDomain();
  const now = useDomainNow();
  const allWeeks = useWeeks(domain?.id);
  const cohorts = useCohorts(domain?.id);
  const [cohortId, setCohortId] = useState('');
  const weeks = {
    ...allWeeks,
    data: (allWeeks.data ?? []).filter((w) => !cohortId || w.cohort_id === cohortId),
  };
  const instructors = useInstructors();
  const setup = useQuery({
    queryKey: ['domain', 'setup-status', domain?.id],
    enabled: !!domain,
    queryFn: async () =>
      (await rpc('domain_setup_status', { p_domain_id: domain!.id })) as unknown as Step[],
  });
  const missing = (setup.data ?? []).filter((x) => !x.done);
  // The app starts empty (decision 251): the first steps for the whole app, until every one is done.
  const started = useQuery({
    queryKey: ['get-started'],
    queryFn: async () => (await rpc('get_started', {})) as unknown as Step[],
  });
  const firstSteps = started.data ?? [];
  const gettingStarted = firstSteps.some((x) => !x.done);
  const names = useMemo(
    () => new Map((instructors.data ?? []).map((i) => [i.id, i.full_name])),
    [instructors.data],
  );
  const byId = useMemo(() => weeksById(allWeeks.data), [allWeeks.data]);

  const counts = useQuery({
    queryKey: ['attention_item', 'home-counts', domain?.id],
    enabled: !!domain,
    // Checks for new tasks every 30 seconds while open, in case a live update was missed.
    refetchInterval: LIVE_CHECK_MS,
    queryFn: async () => {
      const rows = check(
        await supabase
          .from('attention_item')
          .select('severity, status, done_at, module_week_id')
          .or(`domain_id.eq.${domain!.id},domain_id.is.null`)
          .or(`status.neq.Done,done_at.gte.${DateTime.now().startOf('day').toUTC().toISO()}`),
      );
      return rows;
    },
  });
  // The cards count the same tasks the list below shows for the chosen cohort.
  const cohortWeeks = new Set(
    (allWeeks.data ?? []).filter((w) => w.cohort_id === cohortId).map((w) => w.id),
  );
  const taskRows = (counts.data ?? []).filter((r) =>
    inCohort(r.module_week_id, cohortId || undefined, cohortWeeks),
  );
  const taskCounts = {
    urgent: taskRows.filter((r) => r.status !== 'Done' && r.severity === 'Urgent').length,
    open: taskRows.filter((r) => r.status !== 'Done').length,
    doneToday: taskRows.filter((r) => r.status === 'Done').length,
  };

  // This week in Pacific time, Sunday to Saturday.
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
      >
        {(cohorts.data ?? []).length > 1 && (
          <Select
            aria-label="Cohort"
            value={cohortId}
            onChange={(e) => setCohortId(e.target.value)}
            className="w-56"
          >
            <option value="">All cohorts</option>
            {(cohorts.data ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </Select>
        )}
      </PageHeader>
      {gettingStarted && (
        <Section
          title="Get started"
          description="The app starts empty. Add these in order; each step opens the page where you do it."
        >
          <StepList steps={firstSteps} />
        </Section>
      )}
      {!domain && !gettingStarted && started.isSuccess && (
        <Empty title="No domain chosen">Choose a domain at the top of the menu.</Empty>
      )}
      {domain && missing.length > 0 && (
        <Section
          title={
            domain.status === 'Draft' ? `Set up ${domain.name}` : `Finish setting up ${domain.name}`
          }
          description={
            domain.status === 'Draft'
              ? 'Nothing is sent while a domain is a draft. Work through these steps, then turn on testing.'
              : 'A few things are still missing. The automation may skip classes until they are done.'
          }
        >
          <StepList steps={setup.data ?? []} />
        </Section>
      )}
      {domain && (
        <>
          <div className="flex flex-wrap gap-3">
            <Stat
              label="Urgent tasks"
              value={taskCounts.urgent}
              tone="danger"
              hint="Answer these first"
              onClick={scrollToTasks}
            />
            <Stat
              label="Open tasks"
              value={taskCounts.open}
              tone="info"
              hint={`${taskCounts.doneToday} done today`}
              onClick={scrollToTasks}
            />
            <Stat
              label="Classes this week"
              value={thisWeek.length}
              tone="neutral"
              hint={`Week of ${weekStart.toFormat('LLL d')}`}
              to="/classes"
            />
            <Stat
              label="Still need an instructor"
              value={looking.length}
              tone="warning"
              hint={`In the next 30 days, ${asking} ${WEEK_STATUS.Waiting.word.toLowerCase()}`}
              to="/requests"
            />
            <Stat
              label="Open help requests"
              value={help}
              tone="accent"
              hint="From instructors, not yet resolved"
              onClick={scrollToTasks}
            />
          </div>

          <Section
            id="tasks"
            title="Needs your attention"
            description="Tasks the automation could not finish on its own. Urgent tasks are listed first."
          >
            <TaskList cohortId={cohortId || undefined} />
          </Section>

          <Section
            title="This week's classes"
            description="Each class shows the time where it is taught. US classes also show the India time."
            actions={
              <Link to="/classes" className="text-sm font-medium text-link hover:underline">
                All upcoming classes
              </Link>
            }
          >
            {weeks.isLoading ? (
              <SkeletonRows rows={3} />
            ) : allWeeks.error ? (
              <LoadError what="this week's classes" onRetry={() => allWeeks.refetch()} />
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
                      const st = weekState(w, names, byId);
                      return (
                        <tr key={c.id} className={trow}>
                          <td className={td}>
                            <ClassTime start={c.starts_at} end={c.ends_at} region={c.region} />
                          </td>
                          <td className={td}>
                            <div className="font-medium">{w.module?.name}</div>
                            <div className="flex flex-wrap items-center gap-1 text-xs text-muted-foreground">
                              {c.class_type}
                              {w.cohort && <span>· {w.cohort}</span>}
                              <RegionBadge region={c.region} />
                            </div>
                          </td>
                          <td className={td}>
                            {st.confirmed ??
                              (st.asking ? (
                                `${WEEK_STATUS.Waiting.word}: ${st.asking}`
                              ) : (
                                <span className="text-muted-foreground">Not confirmed</span>
                              ))}
                          </td>
                          <td className={td}>
                            <Badge tone={st.tone}>{st.short}</Badge>
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </Section>
        </>
      )}
    </div>
  );
}

type Step = { key: string; label: string; link: string; done: boolean };

/** A numbered list of setup steps: done ones crossed out, the rest link to where they are done. */
function StepList({ steps }: { steps: Step[] }) {
  return (
    <ol className="space-y-2">
      {steps.map((x) => (
        <li key={x.key} className="flex items-center gap-2 text-sm">
          {x.done ? (
            <CheckCircle2 className="h-4 w-4 shrink-0 text-success-strong" aria-label="Done" />
          ) : (
            <Circle className="h-4 w-4 shrink-0 text-muted-foreground" aria-label="Not done yet" />
          )}
          {x.done ? (
            <span className="text-muted-foreground line-through">{x.label}</span>
          ) : (
            <Link to={x.link} className="font-medium text-link hover:underline">
              {x.label}
            </Link>
          )}
        </li>
      ))}
    </ol>
  );
}
