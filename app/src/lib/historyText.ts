// Turns a History entry into a plain sentence plus readable before → after changes, the plain list behind
// "Show details" (historyDetails), and whether the app offers Undo (offersUndo). Ids and raw data are never shown.
import { DateTime } from 'luxon';
import { messageName, plain, plainLabel } from './plain';

/** "Discord (#alerts)" reads "Discord in #alerts"; "Email" reads "email". */
function route(r: string): string {
  return r.replace(/^Discord \((#[^)]+)\)$/, 'Discord in $1').replace(/^Email$/, 'email');
}

function capitalise(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

export type HistoryLike = {
  actor_kind: string;
  actor_label: string | null;
  category: string;
  action: string;
  entity_table: string | null;
  module_id: string | null;
  instructor_id: string | null;
  domain_id: string | null;
  before: unknown;
  after: unknown;
  note: string | null;
  undo_of: number | null;
  entity_label?: string | null;
  actor_team_member_id?: string | null;
};

export type NameBook = {
  /** Any id (instructor, team member, module, domain) to its name. */
  name: (id: string | null | undefined) => string | undefined;
  /** Setting key to its label. */
  settingLabel: (key: string) => string | undefined;
};

export type Change = { label: string; from: string; to: string };
export type Described = { sentence: string; changes: Change[] };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const HIDDEN = new Set([
  'id',
  'created_at',
  'updated_at',
  'updated_by',
  'version',
  'verified_at',
  'last_response_at',
  'email_bounced_at',
  'discord_failed_at',
  'discord_server_id',
  'discord_channel_id',
  'discord_status',
  'discord_problem',
  'discord_checked_at',
  'channel_id',
  'paused_from',
  'test_clock_at',
  'is_placeholder',
  'scope',
  'sort_order',
  'title_template',
  'is_primary',
  'instructor_id',
  'module_id',
  'domain_id',
  'team_member_id',
  'schedule_id',
  'moved',
]);

/** The parts of a standard schedule (decision 298): their label names the schedule, which the row does not. */
const STANDARD_PARTS = new Set([
  'standard_schedule_module',
  'standard_schedule_break',
  'standard_schedule_class',
  // Breaks and cohort holidays (decision 301) carry a label for the same reason.
  'program_break',
  'cohort_break',
  'cohort_holiday',
]);

const FIELD: Record<string, string> = {
  full_name: 'Name',
  name: 'Name',
  primary_email: 'Email',
  email: 'Email',
  discord_user_id: 'Discord account',
  discord_username: 'Discord username',
  discord_channel_link: 'Discord channel',
  channel_name: 'Discord channel',
  phone: 'Phone',
  notes: 'Notes',
  status: 'Status',
  is_test: 'Test instructor',
  rotation_order: 'Order in the rotation',
  same_instructor_for_module_week: 'Same instructor for the whole class week',
  alert_discord_channel_id: 'Alert channel',
  test_discord_channel_id: 'Testing channel',
  test_email: 'Testing email',
  job_title: 'Job title',
  access_removed_at: 'Access removed',
  preferred_contact: 'Preferred contact',
  monthly_class_limit: 'Monthly class limit',
  start_date: 'Start date',
  same_instructor: 'Same instructor for the whole class week',
  receives_digest: 'Gets the daily summary',
  digest_channel: 'Daily summary by',
  active: 'Active',
  title: 'Title',
  url: 'Link',
  include_in_confirmation: 'Included in the confirmation',
  class_type: 'Class type',
  day_offset: 'Day',
  start_time: 'Start time (local time)',
  region: 'Region',
  duration_minutes: 'Length in minutes',
  from_date: 'From',
  to_date: 'To',
  reason: 'Reason',
  value: 'Value',
  date: 'Date',
  role: 'Role',
  discord_guild_id: 'Discord server',
  response_base_url: 'Response page link',
  app_base_url: 'App link',
  admin_discord_channel_id: 'Admin alert channel',
  scheduling_email: 'Sender email',
  scheduling_sender_name: 'Sender name',
  company_email_domain: 'Company email domain',
  key: 'Setting',
  position: 'Place in the order',
  after_position: 'After module',
  weeks: 'Weeks',
};

const STATUS_WORD: Record<string, string> = { Test: 'Testing' };

function value(v: unknown, book: NameBook, key?: string): string {
  if (v === null || v === undefined || v === '') return 'nothing';
  if (typeof v === 'boolean') return v ? 'Yes' : 'No';
  if (Array.isArray(v)) return v.map((x) => value(x, book)).join(', ') || 'nothing';
  if (typeof v === 'object') return 'updated';
  const s = String(v);
  if (UUID.test(s)) return book.name(s) ?? 'another record';
  if (key === 'day_offset')
    return Number(s) === 0
      ? 'the first day'
      : `${s} day${Number(s) === 1 ? '' : 's'} after the first day`;
  if (/^\d{2}:\d{2}(:\d{2})?$/.test(s))
    return DateTime.fromFormat(s.slice(0, 5), 'HH:mm').toFormat('h:mm a');
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return DateTime.fromISO(s).toFormat('ccc LLL d, yyyy');
  if (/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/.test(s)) {
    const t = DateTime.fromISO(s.replace(' ', 'T'));
    if (t.isValid) return t.toLocal().toFormat('ccc LLL d, yyyy, h:mm a');
  }
  if (key === 'status') return STATUS_WORD[s] ?? s;
  if (key === 'role')
    return s === 'Escalation' || s === 'Lead'
      ? 'Escalation contact'
      : s === 'Operations' || s === 'Ops'
        ? 'Operations team'
        : s;
  return plain(s);
}

function rowOf(e: HistoryLike): Record<string, unknown> {
  return ((e.after ?? e.before ?? {}) as Record<string, unknown>) || {};
}

function noun(e: HistoryLike, book: NameBook): string {
  const r = rowOf(e);
  const n = (id: unknown) => book.name(id as string) ?? 'a record that was later removed';
  switch (e.entity_table) {
    case 'instructor':
      return `instructor ${r.full_name ?? n(e.instructor_id)}`;
    case 'instructor_email':
      return `the email ${r.email} for ${n(r.instructor_id)}`;
    case 'instructor_unavailability':
      return `unavailable dates ${value(r.from_date, book)} to ${value(r.to_date, book)} for ${n(r.instructor_id)}`;
    case 'module':
      return `module ${r.name ?? n(e.module_id)}`;
    case 'module_owner':
      return `${n(r.team_member_id)} as an owner of ${n(r.module_id)}`;
    case 'module_resource':
      return `the material "${r.title}" for ${n(r.module_id)}`;
    case 'class_pattern_item':
      return `the ${String(r.class_type ?? 'class').toLowerCase()} on ${value(r.day_offset, book, 'day_offset')} at ${value(r.start_time, book)} (local time) for ${n(r.module_id)}${r.cohort_id ? ` in ${n(r.cohort_id)}` : ''}`;
    case 'instructor_channel':
      return `the Discord channel of ${n(r.instructor_id)} in ${n(r.domain_id)}${r.channel_name ? ` (#${r.channel_name})` : ''}`;
    case 'module_ranking':
      return `${n(r.instructor_id)} in the instructor order for ${n(r.module_id)}`;
    case 'team_member':
      return `team member ${r.name}`;
    case 'domain':
      return `domain ${r.name}`;
    case 'domain_team':
      return `${n(r.team_member_id)} as ${r.role === 'Escalation' || r.role === 'Lead' ? 'an escalation contact' : 'part of the default operations team'} for ${n(r.domain_id)}`;
    case 'module_operations':
      return `${n(r.team_member_id)} in the operations team for ${n(r.module_id)}${r.cohort_id ? ` (${n(r.cohort_id)})` : ''}`;
    case 'cohort':
      return `cohort ${r.name ?? e.entity_label ?? ''}`;
    case 'class_type':
      return `the class type ${r.name}`;
    case 'holiday':
      return `the holiday ${r.name} on ${value(r.date, book)}`;
    case 'setting':
      return `the setting "${book.settingLabel(String(r.key)) ?? r.key}"${
        r.module_week_id
          ? ' for one class week'
          : r.module_id
            ? ` for ${n(r.module_id)}`
            : r.cohort_id
              ? ` for ${n(r.cohort_id)}`
              : r.domain_id
                ? ` for ${n(r.domain_id)}`
                : ' for every domain'
      }`;
    case 'app_config':
      return 'the connection settings';
    case 'standard_schedule':
      return `the standard schedule ${r.name ?? e.entity_label ?? ''}`.trim();
    case 'standard_schedule_module':
      return `${n(r.module_id)} as module ${r.position} of ${standardOf(r, /^(.+?): \d+\. /)}`;
    case 'standard_schedule_break':
      return `the ${value(r.weeks, book)} week break after module ${r.after_position} in ${standardOf(r, /^(.+): \d+ week break after module \d+$/)}`;
    case 'standard_schedule_class':
      return `the ${String(r.class_type ?? 'class').toLowerCase()} on ${value(r.day_offset, book, 'day_offset')} at ${value(r.start_time, book)} (local time) for ${n(r.module_id)} in ${standardOf(r, /^(.+?): /)}`;
    case 'program_break':
      return `the program break ${r.reason ?? ''}`.trim();
    case 'cohort_break':
      return `the break ${r.reason ?? ''} of ${n(r.cohort_id)}`;
    case 'cohort_holiday':
      return `the holiday ${r.name} of ${n(r.cohort_id)} on ${value(r.date, book)}`;
    default:
      return e.entity_label ?? 'a setup record';
  }
}

/** "the standard schedule SWEs", read from the label of one of its parts. */
function standardOf(r: Record<string, unknown>, re: RegExp): string {
  const m = String(r.label ?? '').match(re);
  return m ? `the standard schedule ${m[1]}` : 'a standard schedule';
}

function changesOf(e: HistoryLike, book: NameBook): Change[] {
  if (!e.before || !e.after) return [];
  const b = e.before as Record<string, unknown>;
  const a = e.after as Record<string, unknown>;
  const hidden = (k: string) =>
    HIDDEN.has(k) || (k === 'label' && STANDARD_PARTS.has(e.entity_table ?? ''));
  return Object.keys({ ...b, ...a })
    .filter((k) => !hidden(k) && JSON.stringify(b[k]) !== JSON.stringify(a[k]))
    .map((k) => ({
      label: FIELD[k] ?? k.replace(/_/g, ' '),
      from: value(b[k], book, k),
      to: value(a[k], book, k),
    }));
}

const position = (i: number) => (i === 0 ? 'Primary instructor' : `Backup ${i}`);

function rankingChange(e: HistoryLike, actor: string, book: NameBook): Described {
  const before = ((e.before as { names?: string[] } | null)?.names ?? []) as string[];
  const after = ((e.after as { names?: string[] } | null)?.names ?? []) as string[];
  const module = book.name(e.module_id) ?? 'a module';
  // One person moved and everyone else just shifted: say it in one sentence.
  if (before.length === after.length && before.length > 1 && before.join() !== after.join()) {
    for (const p of after) {
      const rest = (l: string[]) => l.filter((x) => x !== p).join('|');
      if (rest(before) === rest(after) && before.indexOf(p) !== after.indexOf(p)) {
        return {
          sentence: `${actor} moved ${p} from ${position(before.indexOf(p))} to ${position(after.indexOf(p))} in ${module}`,
          changes: [],
        };
      }
    }
  }
  const changes: Change[] = [];
  for (const p of after) {
    const was = before.indexOf(p);
    if (was === -1)
      changes.push({ label: p, from: 'not in the order', to: position(after.indexOf(p)) });
    else if (was !== after.indexOf(p))
      changes.push({ label: p, from: position(was), to: position(after.indexOf(p)) });
  }
  for (const p of before)
    if (!after.includes(p))
      changes.push({ label: p, from: position(before.indexOf(p)), to: 'removed' });
  return { sentence: `${actor} changed the instructor order for ${module}`, changes };
}

const rewrites: [
  RegExp,
  (m: RegExpMatchArray, ctx: { actor: string; module: string }) => string,
][] = [
  [
    /^([A-Z]+\d*) sent to (.+?) via (.+)$/,
    (m) => `${capitalise(messageName[m[1]!] ?? 'message')} sent to ${m[2]} by ${route(m[3]!)}`,
  ],
  [
    /^([A-Z]+\d*) failed to (.+?) via (.+)$/,
    (m) => `Could not send the ${messageName[m[1]!] ?? 'message'} to ${m[2]} by ${route(m[3]!)}`,
  ],
  [/^Nobody left to ask$/, (_m, c) => `Nobody left to ask for ${c.module}`],
  [/^Asking paused$/, (_m, c) => `${c.actor} paused asking for ${c.module}`],
  [/^Asking resumed$/, (_m, c) => `${c.actor} resumed asking for ${c.module}`],
  [
    /^Class at risk task closed$/,
    (_m, c) => `Class at risk task closed for ${c.module}: nobody left to ask`,
  ],
  [/^Asked (.+)$/, (m, c) => `Asked ${m[1]} to teach ${c.module}`],
  [/^(.+) said yes$/, (m, c) => `${m[1]} said yes to ${c.module}`],
  [/^(.+) said no$/, (m, c) => `${m[1]} said no to ${c.module}`],
  [
    /^(.+) said yes, but it could not be booked$/,
    (m, c) => `${m[1]} said yes to ${c.module}, but could not be booked`,
  ],
  [/^Booked (.+)$/, (m, c) => `${m[1]} is confirmed for ${c.module}`],
  [/^Booking released: (.+)$/, (m, c) => `${m[1]} was released from ${c.module}`],
  [
    /^No reply from (.+) [—–] moving on$/,
    (m, c) => `${m[1]} did not reply about ${c.module}, so the next instructor was asked`,
  ],
  [/^Request withdrawn: (.+)$/, (m, c) => `The request to ${m[1]} for ${c.module} was withdrawn`],
  [/^Hourly check: (.+)$/, (m) => `Automatic check ran for ${m[1]}`],
  [/^Hourly check failed: (.+)$/, (m) => `The automatic check failed for ${m[1]}`],
  [/^Needs attention: (.+)$/s, (m) => `New task: ${plainLabel(m[1])}`],
  [/^Resolved automatically: (.+)$/s, (m) => `Task closed automatically: ${plainLabel(m[1])}`],
  [/^Marked done: (.+)$/s, (m, c) => `${c.actor} closed the task: ${plainLabel(m[1])}`],
  [/^I'm on it: (.+)$/s, (m, c) => `${c.actor} took the task: ${plainLabel(m[1])}`],
  [
    /^Assigned to (.+?): (.+)$/s,
    (m, c) => `${c.actor} gave the task to ${m[1]}: ${plainLabel(m[2])}`,
  ],
  [/^Escalated: (.+)$/s, (m) => `Task sent to the leads: ${plainLabel(m[1])}`],
  [/^Readiness check failed$/, (_m, c) => `Setup check needs fixing for ${c.module}`],
  [/^Readiness check passed$/, (_m, c) => `Setup check passed for ${c.module}`],
  [/^Ranking exhausted/, (_m, c) => `No more instructors to ask for ${c.module}`],
  [/^Module week completed$/, (_m, c) => `The class week for ${c.module} finished`],
  [/^Kill switch ON/, (_m, c) => `${c.actor} paused all messages to instructors`],
  [
    /^All messages to instructors paused$/,
    (_m, c) => `${c.actor} paused all messages to instructors`,
  ],
  [
    /^Messages to instructors turned back on$/,
    (_m, c) => `${c.actor} turned messages to instructors back on`,
  ],
  [/^Went live$/, (_m, c) => `${c.actor} took the domain live: real instructors now get messages`],
  [/^Testing turned on$/, (_m, c) => `${c.actor} turned on testing for the domain`],
  [/^Domain paused$/, (_m, c) => `${c.actor} paused the domain`],
  [/^Moved back to Draft$/, (_m, c) => `${c.actor} moved the domain back to Draft`],
  [/^Signed in$/, (_m, c) => `${c.actor} signed in`],
  [/^Sign in refused$/, () => 'A sign in was refused'],
  [/^Access removed$/, (_m, c) => `${c.actor} removed someone's access`],
  [/^Access given back$/, (_m, c) => `${c.actor} gave someone their access back`],
  [/^Downloaded (.+)$/, (m, c) => `${c.actor} downloaded ${m[1]} as a spreadsheet`],
  [/^Warnings accepted$/, (_m, c) => `${c.actor} went ahead despite warnings`],
  [/^Break added: (.+)$/, (m, c) => `${c.actor} added the break ${m[1]}`],
  [/^Program break added: (.+)$/, (m, c) => `${c.actor} added the program break ${m[1]}`],
  [/^Break removed: (.+)$/, (m, c) => `${c.actor} removed the break ${m[1]}`],
  [/^Program break removed: (.+)$/, (m, c) => `${c.actor} removed the program break ${m[1]}`],
  [/^Class shared$/, (_m, c) => `${c.actor} made ${c.module} part of another cohort's class`],
  [
    /^Class shared with (\d+) other class week\(s\)$/,
    (m, c) =>
      `${c.actor} shared the ${c.module} class with ${m[1]} other class week${m[1] === '1' ? '' : 's'}`,
  ],
  [/^Cohorts merged into (.+)$/, (m, c) => `${c.actor} merged cohorts into ${m[1]}`],
  [/^Cohort merge undone$/, (_m, c) => `${c.actor} undid a cohort merge`],
  [/^Class no longer shared$/, (_m, c) => `${c.actor} gave ${c.module} its own class again`],
  [
    /^Proposed time accepted: (.+)$/,
    (m, c) => `${c.actor} accepted the time ${m[1]} proposed for ${c.module}`,
  ],
  [
    /^Proposed time rejected: (.+)$/,
    (m, c) => `${c.actor} kept the time of ${c.module}, not the one ${m[1]} proposed`,
  ],
  [/^(.+) proposed another time$/, (m, c) => `${m[1]} proposed another time for ${c.module}`],
  [
    /^Class kept on a cohort holiday$/,
    (_m, c) => `${c.actor} kept a ${c.module} class on a cohort holiday`,
  ],
  [/^Class added$/, (_m, c) => `${c.actor} added a class to ${c.module}`],
  [
    /^Planned (\d+) class week\(s\)$/,
    (m, c) => `${c.actor} planned ${m[1]} class week${m[1] === '1' ? '' : 's'}`,
  ],
  [
    /^Same instructor turned (on|off) for the class week$/,
    (m, c) =>
      m[1] === 'off'
        ? `${c.actor} let each class of ${c.module} have its own instructor`
        : `${c.actor} set one instructor for the whole class week of ${c.module}`,
  ],
  [
    /^Environment set to (\w+)$/,
    (m) =>
      m[1] === 'Production'
        ? 'The app was switched to live use'
        : m[1] === 'Sandbox'
          ? 'The app was set to not live (messages only to allowed test channels and mailboxes)'
          : 'The app was set up for development on a computer',
  ],
  [/^Kill switch OFF/, (_m, c) => `${c.actor} turned messages to instructors back on`],
  [/^Test clock set to (.+)$/, (m, c) => `${c.actor} set the practice clock to ${m[1]}`],
  [/^Test clock cleared/, (_m, c) => `${c.actor} set the practice clock back to real time`],
  [
    /^Outreach set to (\w+)$/,
    (m, c) =>
      `${c.actor} set who to ask for ${c.module} to ${m[1] === 'Manual' ? 'a chosen list' : 'the instructor order'}`,
  ],
  [/^Outreach paused$/, (_m, c) => `${c.actor} paused asking for ${c.module}`],
  [/^Outreach resumed$/, (_m, c) => `${c.actor} resumed asking for ${c.module}`],
  [/^Class time changed$/, (_m, c) => `${c.actor} moved a ${c.module} class`],
  [/^Class cancelled: (.+)$/, (m, c) => `${c.actor} cancelled ${plain(m[1])}`],
  [/^Module week cancelled$/, (_m, c) => `${c.actor} cancelled the class week for ${c.module}`],
  [
    /^Planned (\d+) module week\(s\)$/,
    (m, c) => `${c.actor} planned ${m[1]} class week${m[1] === '1' ? '' : 's'}`,
  ],
  [
    /^Shifted (\d+) module week\(s\) by (-?\d+) week\(s\)$/,
    (m, c) =>
      `${c.actor} moved ${m[1]} class week${m[1] === '1' ? '' : 's'} by ${m[2]} week${Math.abs(Number(m[2])) === 1 ? '' : 's'}`,
  ],
  [/^Test message sent to (.+)$/, (m, c) => `${c.actor} sent a contact check to ${m[1]}`],
  [/^Marked verified/, (_m, c) => `${c.actor} marked the contact details as checked`],
  [/^(.+) confirmed the test message \(verified\)$/, (m) => `${m[1]} confirmed the contact check`],
  [
    /^(.+): all set \((\d+)-day check-in\)$/,
    (m) => `${m[1]} is all set (reminder ${m[2]} days before class)`,
  ],
  [
    /^(\d+)-day check-in sent$/,
    (m, c) => `Sent the reminder ${m[1]} days before class for ${c.module}`,
  ],
  [/^Help requested by (.+)$/, (m, c) => `${m[1]} asked for help with ${c.module}`],
  [/^Typed reply from (.+)$/, (m) => `Written reply received from ${m[1]}`],
  [/^Seed data loaded$/, () => 'Starting data loaded'],
  [/^Sign-in rejected$/, () => 'Someone outside the company tried to sign in'],
];

const weeks = (n: unknown) => `${Number(n ?? 0)} class week${Number(n ?? 0) === 1 ? '' : 's'}`;

/** Planning cohorts from a standard, Reset to standard and updating cohorts from a standard (decisions 298, 299). */
function standardEvent(e: HistoryLike, actor: string, book: NameBook): Described | null {
  const a = (e.after ?? {}) as Record<string, unknown>;
  const notUpdated = Number(a.not_updated ?? 0);
  const rest = notUpdated ? `, ${notUpdated} not updated` : '';
  if (e.action === 'Cohorts planned from a standard') {
    const cohorts = Array.isArray(a.cohorts) ? (a.cohorts as unknown[]).map(String) : [];
    return {
      sentence: `${actor} planned ${cohorts.join(', ') || 'new cohorts'} from the standard schedule ${a.schedule ?? ''}: ${weeks(a.class_weeks)}`,
      changes: [],
    };
  }
  if (e.action === 'Reset to standard') {
    const cohort = book.name(a.cohort_id as string);
    return {
      sentence: `${actor} reset ${weeks(a.class_weeks_changed)}${cohort ? ` of ${cohort}` : ''} to the standard${rest}`,
      changes: [],
    };
  }
  const m = e.action.match(/^Standard applied: (.+)$/);
  if (m) {
    const added = Number(a.new_class_weeks ?? 0);
    return {
      sentence: `${actor} updated cohorts from the standard schedule ${m[1]}: ${weeks(a.class_weeks_changed)} changed${added ? `, ${added} new` : ''}${rest}`,
      changes: [],
    };
  }
  return null;
}

export function describeHistory(e: HistoryLike, book: NameBook): Described {
  const actor =
    e.actor_kind === 'System'
      ? 'The system'
      : (e.actor_label ?? (e.actor_kind === 'Instructor' ? 'An instructor' : 'Someone'));
  const module = book.name(e.module_id) ?? 'the class';
  if (e.action === 'Ranking saved') return rankingChange(e, actor, book);
  const standard = standardEvent(e, actor, book);
  if (standard) return standard;
  if (e.category === 'Setup changes' && e.entity_table) {
    const undo = e.action.startsWith('Undo: ');
    const verb = e.action.replace(/^Undo: /, '');
    const thing = noun(e, book);
    if (undo)
      return {
        sentence: `${actor} undid an earlier change to ${thing}`,
        changes: changesOf(e, book),
      };
    if (e.entity_table === 'setting') {
      const r = rowOf(e);
      const label = book.settingLabel(String(r.key)) ?? 'a setting';
      const level = r.module_week_id
        ? ' for one class week'
        : r.module_id
          ? ` for ${book.name(r.module_id as string) ?? 'a module'}`
          : r.cohort_id
            ? ` for ${book.name(r.cohort_id as string) ?? 'a cohort'}`
            : '';
      if (verb.endsWith('removed'))
        return {
          sentence: `${actor} reset "${label}"${level} to the ${level ? 'value above it' : 'default'}`,
          changes: [],
        };
      return {
        sentence: `${actor} set "${label}"${level} to ${value((e.after as { value?: unknown })?.value, book)}`,
        changes: changesOf(e, book),
      };
    }
    if (verb.endsWith(' added')) return { sentence: `${actor} added ${thing}`, changes: [] };
    // Archiving and restoring a standard schedule change only when it was archived.
    if (e.entity_table === 'standard_schedule' && verb.endsWith(' changed')) {
      const b = (e.before ?? {}) as Record<string, unknown>;
      const r = rowOf(e);
      if (!b.archived_at !== !r.archived_at)
        return {
          sentence: `${actor} ${r.archived_at ? 'archived' : 'restored'} ${thing}`,
          changes: [],
        };
    }
    if (verb.endsWith(' removed')) return { sentence: `${actor} removed ${thing}`, changes: [] };
    const changes = changesOf(e, book);
    if (changes.length === 1) {
      const c = changes[0]!;
      return {
        sentence: `${actor} changed ${c.label.toLowerCase()} for ${thing} from ${c.from} to ${c.to}`,
        changes: [],
      };
    }
    return { sentence: `${actor} updated ${thing}`, changes };
  }
  for (const [re, fn] of rewrites) {
    const m = e.action.match(re);
    if (m) return { sentence: fn(m, { actor, module }), changes: classTimeChange(e) };
  }
  const text = plainLabel(e.action);
  return { sentence: e.actor_kind === 'TeamMember' ? `${actor}: ${text}` : text, changes: [] };
}

function classTimeChange(e: HistoryLike): Change[] {
  const b = e.before as { shown?: string } | null;
  const a = e.after as { shown?: string } | null;
  if (b?.shown && a?.shown) return [{ label: 'Time', from: plain(b.shown), to: plain(a.shown) }];
  return [];
}

// ------------------------------------------------------------------------------------ Show details
/** One line behind "Show details": a field in plain words and its value, or what it was and what it became. */
export type Detail = { label: string; from?: string; to: string };

/** Fields that end in _id or _ids hold ids: shown only as the name they point to. */
const ID_KEY = /(^|_)ids?$/;

/** Fields that never mean anything to the team (versions, times the database keeps for itself). */
const DETAIL_HIDDEN = new Set([...HIDDEN].filter((k) => !ID_KEY.test(k)));

const DETAIL_FIELD: Record<string, string> = {
  shown: 'Class time',
  names: 'Instructor order',
  cohorts: 'Cohorts',
  schedule: 'Standard schedule',
  class_weeks: 'Class weeks',
  class_weeks_changed: 'Class weeks changed',
  new_class_weeks: 'New class weeks',
  not_updated: 'Not updated',
  archived_at: 'Archived',
  deleted_at: 'Deleted',
  last_sign_in_at: 'Last sign in',
  is_admin: 'Admin',
};

function detailLabel(k: string): string {
  const known = FIELD[k] ?? DETAIL_FIELD[k];
  if (known) return known;
  const words = k
    .replace(/_ids?$/, '')
    .replace(/_at$/, '')
    .replace(/_/g, ' ')
    .trim();
  return capitalise(words || k);
}

const EMPTY = 'nothing';

function isUuid(v: unknown): v is string {
  return typeof v === 'string' && UUID.test(v);
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** The readable name of a nested record, when it has one. */
function nameOf(o: Record<string, unknown>): string | undefined {
  for (const k of ['name', 'full_name', 'title', 'label']) {
    const v = o[k];
    if (typeof v === 'string' && v.trim() && !isUuid(v)) return plain(v);
  }
  return undefined;
}

/**
 * A value in plain words: "nothing" when empty, and undefined when it cannot be said without an id or raw
 * data (an id whose name is not known, a nested record with no name), so the line is left out.
 */
function plainValue(k: string, v: unknown, book: NameBook): string | undefined {
  if (v === null || v === undefined || v === '') return EMPTY;
  if (Array.isArray(v)) {
    if (v.length === 0) return EMPTY;
    const parts = v.map((x) =>
      isRecord(x) ? nameOf(x) : isUuid(x) ? book.name(x) : plainValue(k, x, book),
    );
    if (parts.some((p) => p === undefined)) return undefined;
    return parts.join(', ');
  }
  if (isRecord(v)) return nameOf(v);
  if (isUuid(v)) return book.name(v);
  if (ID_KEY.test(k)) return undefined;
  if (k === 'key') return book.settingLabel(String(v));
  return value(v, book, k);
}

function hiddenKey(k: string, row: Record<string, unknown>, table: string | null): boolean {
  if (k === 'id' || DETAIL_HIDDEN.has(k)) return true;
  if (k === 'label' && STANDARD_PARTS.has(table ?? '')) return true;
  // An instructor order lists names next to their ids: the names say it all.
  if (/_ids$/.test(k) && 'names' in row) return true;
  return false;
}

/** Every field of one record (a new or a removed one), in plain words. */
function fieldsOf(
  row: Record<string, unknown>,
  book: NameBook,
  table: string | null,
  depth = 0,
): Detail[] {
  const out: Detail[] = [];
  for (const [k, v] of Object.entries(row)) {
    if (hiddenKey(k, row, table)) continue;
    if (isRecord(v) && !nameOf(v) && depth < 2) {
      out.push(...fieldsOf(v, book, null, depth + 1));
      continue;
    }
    const to = plainValue(k, v, book);
    if (to === undefined || to === EMPTY) continue;
    out.push({ label: detailLabel(k), to });
  }
  return out;
}

/** What changed between two versions of a record, field by field, in plain words. */
function diffOf(
  b: Record<string, unknown>,
  a: Record<string, unknown>,
  book: NameBook,
  table: string | null,
  depth = 0,
): Detail[] {
  const out: Detail[] = [];
  const both = { ...b, ...a };
  for (const k of Object.keys(both)) {
    if (hiddenKey(k, both, table)) continue;
    const bv = b[k];
    const av = a[k];
    if (JSON.stringify(bv) === JSON.stringify(av)) continue;
    const nested = isRecord(bv) || isRecord(av);
    if (nested && depth < 2 && !nameOf((isRecord(av) ? av : bv) as Record<string, unknown>)) {
      out.push(...diffOf(isRecord(bv) ? bv : {}, isRecord(av) ? av : {}, book, null, depth + 1));
      continue;
    }
    const from = plainValue(k, bv, book);
    const to = plainValue(k, av, book);
    if (from === undefined || to === undefined || from === to) continue;
    out.push({ label: detailLabel(k), from, to });
  }
  return out;
}

/**
 * The plain list behind "Show details": the type of change, then what changed (each field before and after),
 * or the fields of a record that was added or removed. Never ids, raw data or database field names.
 */
export function historyDetails(e: HistoryLike, book: NameBook): Detail[] {
  const out: Detail[] = [{ label: 'Type of change', to: e.category }];
  const b = isRecord(e.before) ? e.before : null;
  const a = isRecord(e.after) ? e.after : null;
  if (b && a) out.push(...diffOf(b, a, book, e.entity_table));
  else if (a) out.push(...fieldsOf(a, book, e.entity_table));
  else if (b) out.push(...fieldsOf(b, book, e.entity_table));
  // Outside setup changes the note is already shown under the sentence; an undo's note only names an entry number.
  if (e.note && e.category === 'Setup changes' && e.undo_of === null)
    out.push({ label: e.entity_table === 'setting' ? 'Reason' : 'Note', to: plain(e.note) });
  return out;
}

// ------------------------------------------------------------------------------------ Undo
/** Changes made by these are never a team member's own edit, whatever kind of actor they are logged as. */
const NOT_A_PERSON = new Set([
  'System',
  'The system',
  'Clock',
  'Automation',
  'Setup command',
  'Test data',
  'Sandbox data',
  'Database admin',
  'Integration test',
]);

/**
 * Whether the app offers Undo. The database checks the same rule (private.can_undo): only a setup change a
 * team member made in the app, not undone and not itself an undo, never creating or removing a domain, cohort
 * or module, and never a change by the system, the clock, the automation, a setup command or test data.
 */
export function offersUndo(e: HistoryLike & { undoable?: boolean | null }): boolean {
  if (!e.undoable) return false;
  if (e.category !== 'Setup changes' || e.undo_of !== null) return false;
  if (e.actor_kind !== 'TeamMember' || !e.actor_team_member_id) return false;
  if (e.actor_label && NOT_A_PERSON.has(e.actor_label)) return false;
  const core = ['domain', 'cohort', 'module'].includes(e.entity_table ?? '');
  if (core && (e.before === null || e.after === null || / (added|removed)$/.test(e.action)))
    return false;
  return true;
}
