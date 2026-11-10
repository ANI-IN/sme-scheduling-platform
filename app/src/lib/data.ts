// Shared queries. Every screen reads the latest data from the database; realtime events
// invalidate these caches so changes from n8n or teammates show up immediately.
import { useQuery } from '@tanstack/react-query';
import { supabase, type Tables } from './supabase';
import { check, rpc } from './rpc';
import { useAuth } from './auth';

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

export const useDomains = () =>
  useQuery({
    queryKey: ['domain'],
    queryFn: async () => check(await supabase.from('domain').select('*').order('name')),
  });

export const useTeam = () =>
  useQuery({
    queryKey: ['team_member'],
    queryFn: async () => check(await supabase.from('team_member').select('*').order('name')),
  });

export const useInstructors = () =>
  useQuery({
    queryKey: ['instructor'],
    queryFn: async () =>
      check(
        await supabase
          .from('instructor')
          .select('*, instructor_email(*), instructor_unavailability(*)')
          .order('full_name'),
      ),
  });

export const useCohorts = (domainId: string | undefined) =>
  useQuery({
    queryKey: ['cohort', domainId],
    enabled: !!domainId,
    queryFn: async () =>
      check(
        await supabase
          .from('cohort')
          .select('*')
          .eq('domain_id', domainId!)
          .order('start_date', { ascending: false, nullsFirst: false })
          .order('name'),
      ),
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

export const useWeeks = (domainId: string | undefined) =>
  useQuery({
    queryKey: ['module_week', domainId],
    enabled: !!domainId,
    queryFn: async () =>
      check(
        await supabase
          .from('module_week')
          .select(
            '*, module(name), class_session(*), booking(*), request(*), help_request(id, status), manual_queue_item(*)',
          )
          .eq('domain_id', domainId!)
          .order('week_start_date'),
      ),
  });

export type WeekRow = NonNullable<ReturnType<typeof useWeeks>['data']>[number];

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

/** Name lookup helpers */
export function nameMap<T extends { id: string }>(
  rows: T[] | undefined,
  key: keyof T,
): Map<string, string> {
  return new Map((rows ?? []).map((r) => [r.id, String(r[key])]));
}
