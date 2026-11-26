// Shared queries. Every screen reads the latest data from the database; realtime events
// invalidate these caches so changes from n8n or teammates show up immediately.
import { betaLocked } from '@/lib/betaLock';
import { useQuery } from '@tanstack/react-query';
import { DateTime } from 'luxon';
import { currentBlocked } from './blocked';
import { supabase, type Tables } from './supabase';
import { check, fetchAll, rpc } from './rpc';
import { useAuth } from './auth';

/** While the automation is checking Discord for someone, look again every few seconds. */
const whileChecking = (q: { state: { data?: { discord_status: string | null }[] } }) =>
  q.state.data?.some((r) => r.discord_status === 'Checking') ? 2000 : false;

export type Domain = Tables<'domain'>;
export type Module = Tables<'module'>;
export type Instructor = Tables<'instructor'>;
export type TeamMember = Tables<'team_member'>;
export type ModuleWeek = Tables<'module_week'>;
export type ClassSession = Tables<'class_session'>;
export type Request = Tables<'request'>;
export type Booking = Tables<'booking'>;
export type AttentionItem = Tables<'attention_item'>;
export type HelpRequest = Tables<'help_request'>;
export type HistoryEvent = Tables<'history_event'>;

/** How often open task lists and Activity history check for news, in case a live update was missed. */
export const LIVE_CHECK_MS = 30_000;

export const useDomains = () =>
  useQuery({
    queryKey: ['domain'],
    refetchInterval: whileChecking,
    queryFn: async () => check(await supabase.from('domain').select('*').order('name')),
  });

export const useTeam = () =>
  useQuery({
    queryKey: ['team_member'],
    refetchInterval: whileChecking,
    queryFn: async () => check(await supabase.from('team_member').select('*').order('name')),
  });

export const useInstructors = () =>
  useQuery({
    queryKey: ['instructor'],
    refetchInterval: whileChecking,
    queryFn: async () =>
      check(
        await supabase
          .from('instructor')
          .select('*, instructor_email(*), instructor_unavailability(*), instructor_channel(*)')
          .order('full_name'),
      ),
  });

/** Messages a beta rule stopped in the last 14 days that nothing later replaced (decision 329). */
export const useBlockedMessages = (by: { instructorId?: string; domainId?: string }) =>
  useQuery({
    queryKey: ['message', 'blocked', by.instructorId ?? null, by.domainId ?? null],
    enabled: !!(by.instructorId || by.domainId),
    refetchInterval: 15000,
    queryFn: async () => {
      let q = supabase
        .from('message')
        .select(
          'id, created_at, status, blocked, direction, template_id, channel, instructor_id, team_member_id, module_week_id, recipient_label, last_error',
        )
        .eq('direction', 'Outbound')
        .gte('created_at', DateTime.now().minus({ days: 14 }).toISO()!)
        .order('created_at', { ascending: false })
        .limit(500);
      if (by.instructorId) q = q.eq('instructor_id', by.instructorId);
      if (by.domainId) q = q.eq('domain_id', by.domainId);
      return currentBlocked(check(await q));
    },
  });

/** A domain's cohorts. Archived ones are left out unless asked for (the domain page lists them). */
export const useCohorts = (domainId: string | undefined, withArchived = false) =>
  useQuery({
    queryKey: ['cohort', domainId, withArchived],
    enabled: !!domainId,
    queryFn: async () =>
      check(
        await supabase
          .from('cohort')
          .select('*')
          .eq('domain_id', domainId!)
          .order('start_date', { ascending: false, nullsFirst: false })
          .order('name'),
      ).filter((c) => withArchived || !c.archived_at),
  });

export const useModules = (domainId: string | undefined) =>
  useQuery({
    queryKey: ['module', domainId],
    enabled: !!domainId,
    queryFn: async () =>
      check(
        await supabase
          .from('module')
          .select(
            '*, module_owner(*), module_resource(*), class_pattern_item(*), module_ranking(*)',
          )
          .eq('domain_id', domainId!)
          .order('rotation_order'),
      ),
  });

const WEEK_COLS =
  'id, domain_id, module_id, cohort, cohort_id, week_start_date, outreach_mode, manual_end_behaviour, status, at_risk, at_risk_reason, paused, first_class_at, last_class_end_at, same_instructor, standard_position, customized_at, shared_with, created_at, updated_at, updated_by, version';
const WEEK_CLASS_COLS =
  'id, module_week_id, class_type, title, starts_at, ends_at, status, region, cancelled_reason, problem_flag, holiday_kept_on, holiday_kept_reason, previous_starts_at, previous_ends_at, moved_at, shared_class_id, notes, version';
const WEEK_BOOKING_COLS =
  'id, module_week_id, instructor_id, status, confirmed_at, confirmed_via, released_at, release_reason';
const WEEK_REQUEST_COLS =
  'id, module_week_id, instructor_id, booking_id, kind, check_in_days, status, answer, close_reason, sent_at, reminded_at, deadline_at, answered_at, created_at';

export const useWeeks = (domainId: string | undefined) =>
  useQuery({
    queryKey: ['module_week', domainId],
    enabled: !!domainId,
    // Every class week of the domain, a page at a time (the database returns at most 1,000 rows at once).
    queryFn: () =>
      fetchAll((from, to) =>
        supabase
          .from('module_week')
          .select(
            // Only the columns the lists use (decision 342): the full rows made this the slowest read at scale.
            `${WEEK_COLS}, module(name), class_session(${WEEK_CLASS_COLS}), booking(${WEEK_BOOKING_COLS}), request(${WEEK_REQUEST_COLS}), help_request(id, status), manual_queue_item(*), time_proposal(id, status)`,
          )
          .eq('domain_id', domainId!)
          .order('week_start_date')
          // Class weeks of the same week in the order of their first class, earliest first.
          .order('first_class_at', { nullsFirst: false })
          .order('id')
          .range(from, to),
      ),
  });

export type WeekRow = NonNullable<ReturnType<typeof useWeeks>['data']>[number];

/** One class week, with the same parts as useWeeks (decision 342): the board opens one without reading them all. */
export const useWeek = (id: string | null | undefined) =>
  useQuery({
    queryKey: ['module_week', 'one', id],
    enabled: !!id,
    queryFn: async (): Promise<WeekRow | null> =>
      check(
        await supabase
          .from('module_week')
          .select(
            `${WEEK_COLS}, module(name), class_session(${WEEK_CLASS_COLS}), booking(${WEEK_BOOKING_COLS}), request(${WEEK_REQUEST_COLS}), help_request(id, status), manual_queue_item(*), time_proposal(id, status)`,
          )
          .eq('id', id!)
          .maybeSingle(),
      ),
  });

/** A domain's standard schedules with their module order, breaks and own class times (decision 298). */
export const useStandards = (domainId: string | undefined) =>
  useQuery({
    queryKey: ['standard_schedule', domainId],
    enabled: !!domainId,
    queryFn: async () =>
      check(
        await supabase
          .from('standard_schedule')
          .select(
            '*, standard_schedule_module(*), standard_schedule_break(*), standard_schedule_class(*)',
          )
          .eq('domain_id', domainId!)
          .order('name'),
      ),
  });

export type StandardRow = NonNullable<ReturnType<typeof useStandards>['data']>[number];

/** "Standard", "Custom" (with the number of changes) or "Fully custom" for one cohort. */
export type CohortScheduleStatus = {
  cohort_id: string;
  standard_schedule_id: string | null;
  schedule: string | null;
  changes: number;
  mode: 'Standard' | 'Custom' | 'Fully custom';
};

/** How each cohort of a domain follows its standard schedule (decision 298). */
export const useCohortScheduleStatus = (domainId: string | undefined) =>
  useQuery({
    queryKey: ['module_week', 'schedule_status', domainId],
    enabled: !!domainId,
    queryFn: async () =>
      (await rpc('cohort_schedule_status', {
        p_domain_id: domainId!,
      })) as unknown as CohortScheduleStatus[],
  });

export const useSystem = () =>
  useQuery({
    queryKey: ['system_state'],
    queryFn: async () => {
      const [s, c] = await Promise.all([
        supabase.from('system_state').select('*').single(),
        supabase.from('app_config').select('*').single(),
      ]);
      return { state: check(s), config: check(c) };
    },
  });

/** Whether this person may not change Test instructor, instructor emails or Discord accounts (decision 347). */
export function useBetaLock() {
  const me = useMe();
  const sys = useSystem();
  return betaLocked(sys.data?.config.message_recipients, !!me?.is_admin);
}

export function useMe() {
  const { session } = useAuth();
  const team = useTeam();
  const email = session?.user.email?.toLowerCase();
  return team.data?.find((t) => t.email.toLowerCase() === email) ?? null;
}

export type SettingRow = {
  key: string;
  group: string;
  label: string;
  type: 'int' | 'bool' | 'enum' | 'time' | 'int_list' | 'text_list' | 'json';
  value: unknown;
  default: unknown;
  min: number | null;
  max: number | null;
  allowed: string[] | null;
  help: string | null;
  overridden: boolean;
  /** Where the value comes from: Default, Global, Domain, Cohort, Module or ModuleWeek. */
  source?: string;
  reason?: string | null;
};

export const useSettings = (domainId: string | undefined) =>
  useQuery({
    queryKey: ['setting', domainId],
    enabled: !!domainId,
    queryFn: async () =>
      (await rpc('effective_settings', { p_domain_id: domainId! })) as unknown as SettingRow[],
  });

export function useSettingsMap(domainId: string | undefined) {
  const q = useSettings(domainId);
  return {
    ...q,
    data: q.data ? Object.fromEntries(q.data.map((s) => [s.key, s.value])) : undefined,
  };
}

/** Every id the app may need to show by name (all domains), for History and other read-only text. */
export function useNameBook() {
  const instructors = useInstructors();
  const team = useTeam();
  const domains = useDomains();
  const extra = useQuery({
    queryKey: ['module', 'names'],
    queryFn: async () => {
      const [m, s, c] = await Promise.all([
        supabase.from('module').select('id, name'),
        supabase.from('setting_definition').select('key, label'),
        supabase.from('cohort').select('id, name'),
      ]);
      return { modules: check(m), settings: check(s), cohorts: check(c) };
    },
  });
  const names = new Map<string, string>();
  (instructors.data ?? []).forEach((x) => names.set(x.id, x.full_name));
  (team.data ?? []).forEach((x) => names.set(x.id, x.name));
  (domains.data ?? []).forEach((x) => names.set(x.id, x.name));
  (extra.data?.modules ?? []).forEach((x) => names.set(x.id, x.name));
  (extra.data?.cohorts ?? []).forEach((x) => names.set(x.id, x.name));
  const labels = new Map((extra.data?.settings ?? []).map((s) => [s.key, s.label]));
  return {
    name: (id: string | null | undefined) => (id ? names.get(id) : undefined),
    settingLabel: (key: string) => labels.get(key),
  };
}
