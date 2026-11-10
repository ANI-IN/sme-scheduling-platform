// Turns a History entry into a plain sentence plus readable before → after changes.
// Raw values (ids, JSON) are only shown behind "Show details".
import { DateTime } from 'luxon';
import { messageName, plain, plainLabel } from './plain';

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
const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

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
]);

const FIELD: Record<string, string> = {
  full_name: 'Name',
  name: 'Name',
  primary_email: 'Email',
  email: 'Email',
  discord_user_id: 'Discord user ID',
  discord_channel_link: 'Discord channel',
  phone: 'Phone',
  notes: 'Notes',
  status: 'Status',
  is_test: 'Test instructor',
  rotation_order: 'Order in the rotation',
  same_instructor_for_module_week: 'Same instructor for the whole class week',
  alert_discord_channel_id: 'Alert channel',
  test_discord_channel_id: 'Testing channel',
  test_email: 'Testing email',
  label: 'Role',
  receives_digest: 'Gets the daily summary',
  digest_channel: 'Daily summary by',
  active: 'Active',
  title: 'Title',
  url: 'Link',
  include_in_confirmation: 'Included in the confirmation',
  class_type: 'Class type',
  weekday_offset: 'Day',
  start_time_pt: 'Start time (Pacific)',
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
};

const STATUS_WORD: Record<string, string> = { Test: 'Testing' };

function value(v: unknown, book: NameBook, key?: string): string {
  if (v === null || v === undefined || v === '') return 'nothing';
  if (typeof v === 'boolean') return v ? 'Yes' : 'No';
  if (Array.isArray(v)) return v.map((x) => value(x, book)).join(', ') || 'nothing';
  if (typeof v === 'object') return 'updated';
  const s = String(v);
  if (UUID.test(s)) return book.name(s) ?? 'another record';
  if (key === 'weekday_offset')
    return WEEKDAYS[Number(s) % 7] + (Number(s) >= 7 ? ' of the next week' : '');
  if (/^\d{2}:\d{2}(:\d{2})?$/.test(s))
    return DateTime.fromFormat(s.slice(0, 5), 'HH:mm').toFormat('h:mm a');
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return DateTime.fromISO(s).toFormat('ccc LLL d, yyyy');
  if (key === 'status' || key === 'label') return STATUS_WORD[s] ?? s;
  if (key === 'role') return s === 'Lead' ? 'Domain lead' : s === 'Ops' ? 'Operations team' : s;
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
      return `the ${String(r.class_type ?? 'class').toLowerCase()} on ${value(r.weekday_offset, book, 'weekday_offset')} at ${value(r.start_time_pt, book)} (Pacific) for ${n(r.module_id)}`;
    case 'module_ranking':
      return `${n(r.instructor_id)} in the instructor order for ${n(r.module_id)}`;
    case 'team_member':
      return `team member ${r.name}`;
    case 'domain':
      return `domain ${r.name}`;
    case 'domain_team':
      return `${n(r.team_member_id)} as ${r.role === 'Lead' ? 'a domain lead' : 'part of the operations team'} for ${n(r.domain_id)}`;
    case 'holiday':
      return `the holiday ${r.name} on ${value(r.date, book)}`;
    case 'setting':
      return `the setting "${book.settingLabel(String(r.key)) ?? r.key}"${r.domain_id ? ` for ${n(r.domain_id)}` : ''}`;
    case 'app_config':
      return 'the connection settings';
    default:
      return 'a setup record';
  }
}

function changesOf(e: HistoryLike, book: NameBook): Change[] {
  if (!e.before || !e.after) return [];
  const b = e.before as Record<string, unknown>;
  const a = e.after as Record<string, unknown>;
  return Object.keys({ ...b, ...a })
    .filter((k) => !HIDDEN.has(k) && JSON.stringify(b[k]) !== JSON.stringify(a[k]))
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
    /^(\w+) sent to (.+) via (\w+)$/,
    (m) => `Sent the ${messageName[m[1]!] ?? 'message'} to ${m[2]} by ${m[3]}`,
  ],
  [
    /^(\w+) failed to (.+) via (\w+)$/,
    (m) => `Could not send the ${messageName[m[1]!] ?? 'message'} to ${m[2]} by ${m[3]}`,
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
  [/^Kill switch OFF/, (_m, c) => `${c.actor} turned messages to instructors back on`],
  [/^Test clock set to (.+)$/, (m, c) => `${c.actor} set the practice clock to ${m[1]}`],
  [/^Test clock cleared/, (_m, c) => `${c.actor} set the practice clock back to real time`],
  [
    /^Outreach set to (\w+)$/,
    (m, c) =>
      `${c.actor} set who to ask for ${c.module} to ${m[1] === 'Manual' ? 'a chosen list' : 'the instructor order'}`,
  ],
  [/^Outreach paused$/, (_m, c) => `${c.actor} paused instructor requests for ${c.module}`],
  [/^Outreach resumed$/, (_m, c) => `${c.actor} resumed instructor requests for ${c.module}`],
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

export function describeHistory(e: HistoryLike, book: NameBook): Described {
  const actor =
    e.actor_kind === 'System'
      ? 'The system'
      : (e.actor_label ?? (e.actor_kind === 'Instructor' ? 'An instructor' : 'Someone'));
  const module = book.name(e.module_id) ?? 'the class';
  if (e.action === 'Ranking saved') return rankingChange(e, actor, book);
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
      const label = book.settingLabel(String(rowOf(e).key)) ?? 'a setting';
      if (verb.endsWith('removed'))
        return { sentence: `${actor} reset "${label}" to the default`, changes: [] };
      return {
        sentence: `${actor} set "${label}" to ${value((e.after as { value?: unknown })?.value, book)}`,
        changes: changesOf(e, book),
      };
    }
    if (verb.endsWith(' added')) return { sentence: `${actor} added ${thing}`, changes: [] };
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
