// Every badge the Schedule board and its side panel can show, in one place, with the one sentence the Legend gives
// for it. The board, the side panel and the Legend all read their words from here, so a new badge without a Legend
// sentence fails the unit test (boardBadges.test.ts) and does not compile where the sentence is typed.
import {
  AlertTriangle,
  CalendarClock,
  CheckCircle2,
  Circle,
  Clock,
  Pause,
  PauseCircle,
  Wrench,
  XCircle,
} from 'lucide-react';
import type { Tone } from '@/components/ui';
import { REGION_NAME, REGIONS } from '@/lib/region';
import { AT_RISK, BREAK_WORD, CONFIRMED_AT_RISK, WEEK_STATUS, type WeekStatus } from '@/lib/status';

export type Status = WeekStatus;

/** The main statuses of a cell: always colour, icon and word together. The words come from WEEK_STATUS. */
const STATUS_LOOK: Record<Status, { icon: typeof Circle; text: string }> = {
  Confirmed: { icon: CheckCircle2, text: 'An instructor said yes to this class week.' },
  Waiting: { icon: Clock, text: 'An instructor was asked and has not answered yet.' },
  'Needs instructor': {
    icon: AlertTriangle,
    text: 'Nobody is confirmed or being asked, so you need to choose an instructor.',
  },
  'Proposed time': {
    icon: CalendarClock,
    text: 'The instructor proposed another time, which you accept or reject.',
  },
  'Not asked yet': {
    icon: Circle,
    text: 'Nobody was asked yet, and the cell names who is planned first and the day asking starts.',
  },
  'Setup incomplete': {
    icon: Wrench,
    text: 'Something is missing, such as class times or an instructor order, so nobody can be asked yet.',
  },
  Paused: {
    icon: PauseCircle,
    text: 'Requests for this class week are paused, so nobody is asked.',
  },
  Cancelled: { icon: XCircle, text: 'This class week or class will not take place.' },
  Completed: { icon: CheckCircle2, text: 'Every class of this week has finished.' },
};
export const STATUS = Object.fromEntries(
  (Object.keys(WEEK_STATUS) as Status[]).map((s) => [s, { ...WEEK_STATUS[s], ...STATUS_LOOK[s] }]),
) as Record<Status, (typeof WEEK_STATUS)[Status] & (typeof STATUS_LOOK)[Status]>;

/**
 * Exception badges on a cell, by the code the database puts in its badges (schedule_board), in the glossary's words.
 * A code missing here is not shown, so the unit test checks every code the database can send.
 */
export const BADGE = {
  clash: 'Clash',
  tight_gap: 'Tight gap',
  busy_day: 'Full day',
  unavailable: 'Unavailable',
  monthly_limit: 'Monthly limit',
  not_in_use: 'Instructor not in use',
  sooner_class_first: 'Sooner class first',
  unusual_hours: 'Odd hours',
  holiday: 'Holiday',
  cohort_holiday: 'Cohort holiday',
  in_break: 'During a break',
  cohort_overlap: 'Overlaps another class',
  proposed_time: 'Proposed time',
  waiting_new_time: 'Waiting to confirm a new time',
  shared_class: 'Shared class',
  answer_due_soon: 'Answer due soon',
  message_failed: 'Message failed',
  message_blocked: 'Message not sent',
  help_open: 'Help request open',
  tasks_overdue: 'Class tasks overdue',
  moved: 'Moved',
  extra_class: 'Extra class',
  declined: 'Declined or no reply before',
  ambiguous_time: 'Daylight saving',
} as const;
export type BadgeCode = keyof typeof BADGE;

const BADGE_TEXT: Record<BadgeCode, string> = {
  clash: 'The instructor is in two classes at the same time.',
  tight_gap: 'The instructor has very little time between this class and another one.',
  busy_day: 'The instructor already teaches many hours on that day.',
  unavailable: 'The instructor said they are not available at this time.',
  monthly_limit: 'The instructor would go over their limit of classes a month.',
  not_in_use: 'The confirmed instructor is no longer in use but is still on this class week.',
  sooner_class_first:
    'The instructor took a sooner class at the same time, so the next instructor is asked.',
  unusual_hours: 'A class is outside the usual teaching hours.',
  holiday: 'A class falls on a public holiday.',
  cohort_holiday: 'A class falls on a holiday set for this cohort.',
  in_break: 'A class falls during a break of this cohort.',
  cohort_overlap: 'A class overlaps another class of the same cohort.',
  proposed_time: 'The instructor proposed another time, which you accept or reject.',
  waiting_new_time:
    'A class moved and the confirmed instructor has not confirmed the new time yet.',
  shared_class:
    'This class week is taught together with another cohort, and the side panel says which one.',
  answer_due_soon: 'The answer is due within 12 hours (a setting on Settings, Automation).',
  message_failed: 'A message about this class week could not be delivered.',
  message_blocked:
    'A beta rule stopped a message, and the side panel says why and lets you send it again.',
  help_open: 'Someone asked for help with this class week and it is not closed yet.',
  tasks_overdue: 'A task for this class week is past its due date.',
  moved: 'A class moved from its first time, and the side panel shows the time before.',
  extra_class: "This class week is not part of the cohort's standard schedule.",
  declined: 'An instructor said no to this class week or did not answer in time.',
  ambiguous_time: 'A class falls on a daylight saving change, so check its time.',
};

/** Badges in red: something is wrong now. The others are amber. */
export const SERIOUS = new Set<string>([
  'clash',
  'unavailable',
  'message_failed',
  'message_blocked',
]);

/** The words of a badge code, or nothing when the board does not show that code. */
export const badgeLabel = (code: string): string | undefined =>
  (BADGE as Record<string, string>)[code];

/** The words of a Needs a decision count: a badge, or a status such as Needs instructor. */
export function decisionLabel(code: string): string {
  const status = (Object.keys(STATUS) as Status[]).find(
    (s) => s.toLowerCase().replace(/ /g, '_') === code,
  );
  return badgeLabel(code) ?? (status ? STATUS[status].word : code.replace(/_/g, ' '));
}

/** Other marks a cell can carry. Break and Program break are followed by the reason. */
export const MARK = {
  break: BREAK_WORD,
  programBreak: 'Program break',
  notInStandard: 'Not in the standard',
  differs: 'Differs from the standard',
} as const;
/** The badge for the badges a cell has no room for. */
export const moreBadges = (n: number) => `+${n}`;

/** Cohort header badges (Custom also shows in the side panel, and the header adds the number of changes). */
export const COHORT_BADGE = {
  standard: 'Standard',
  custom: 'Custom',
  fullyCustom: 'Fully custom',
  mergedInto: 'Merged into',
} as const;
export const confirmedCount = (confirmed: number, total: number) =>
  `${confirmed} of ${total} confirmed`;

/** Badges only the side panel shows. */
export const PANEL_BADGE = {
  atRisk: AT_RISK,
  chosenList: 'Chosen list',
  instructorOrder: 'Instructor order',
  sharedClass: 'Shared class',
  helpOpen: 'Help request open',
  moved: 'Moved',
} as const;

/** A message's status in the side panel's Activity. */
export const MSG_STATUS: Record<string, string> = {
  Scheduled: 'Scheduled',
  Pending: 'Waiting to send',
  Sending: 'Sending',
  Sent: 'Sent',
  Failed: 'Not delivered',
  Received: 'Received',
  Cancelled: 'Not sent',
};
/** A single class's status in the side panel, when it is not planned. */
export const CLASS_STATUS = ['Cancelled', 'Completed'] as const;

export type LegendItem = { label: string; tone: Tone; text: string; icon?: typeof Circle };
export type LegendGroup = { title: string; items: LegendItem[] };

/** What the Legend shows, by group. A label shown in an earlier group is not repeated. */
export function legendGroups(): LegendGroup[] {
  const groups: LegendGroup[] = [
    {
      title: 'Statuses',
      items: [
        ...(Object.keys(STATUS) as Status[]).map((s) => ({
          label: STATUS[s].word,
          tone: STATUS[s].tone,
          icon: STATUS[s].icon,
          text: STATUS[s].text,
        })),
        {
          label: MARK.break,
          icon: Pause,
          tone: 'neutral',
          text: 'The cohort has a break this week, and the reason follows.',
        },
      ],
    },
    {
      title: 'Badges on a class week',
      items: [
        ...(Object.keys(BADGE) as BadgeCode[]).map((k) => ({
          label: BADGE[k],
          tone: (SERIOUS.has(k) ? 'danger' : 'warning') as Tone,
          text: BADGE_TEXT[k],
        })),
        {
          label: MARK.programBreak,
          icon: Pause,
          tone: 'neutral',
          text: 'Every cohort shown has the same break this week, so it is one row.',
        },
        {
          label: MARK.notInStandard,
          tone: 'warning',
          text: "With Compare to standard ticked, this class week is not in the cohort's standard schedule.",
        },
        {
          label: MARK.differs,
          tone: 'warning',
          text: 'With Compare to standard ticked, this class week was changed from its standard.',
        },
        {
          label: moreBadges(2),
          tone: 'neutral',
          text: 'The class week has more badges, which you see when you open it.',
        },
      ],
    },
    {
      title: 'Cohort headers',
      items: [
        ...REGIONS.map((r) => ({
          label: r as string,
          tone: (r === 'India' ? 'accent' : 'neutral') as Tone,
          text: `Its classes are taught in ${REGION_NAME[r]}.`,
        })),
        {
          label: COHORT_BADGE.standard,
          tone: 'success',
          text: 'The cohort or class week follows its standard schedule with no changes.',
        },
        {
          label: COHORT_BADGE.custom,
          tone: 'warning',
          text: 'The cohort or class week was changed from its standard schedule, and the cohort header shows how many changes.',
        },
        {
          label: COHORT_BADGE.fullyCustom,
          tone: 'neutral',
          text: 'The cohort has no standard schedule, so its class weeks are planned one by one.',
        },
        {
          label: confirmedCount(2, 6),
          tone: 'neutral',
          text: 'How many coming class weeks of the cohort have a confirmed instructor.',
        },
        {
          label: COHORT_BADGE.mergedInto,
          tone: 'accent',
          text: 'The cohort joined another cohort from the date shown.',
        },
      ],
    },
    {
      title: 'Side panel',
      items: [
        {
          label: PANEL_BADGE.atRisk,
          tone: 'danger',
          text: 'The class week may not have an instructor in time.',
        },
        {
          label: CONFIRMED_AT_RISK,
          tone: 'amber',
          text: 'An instructor is confirmed, but something may still stop the class.',
        },
        {
          label: PANEL_BADGE.chosenList,
          tone: 'neutral',
          text: 'Instructors are asked from a list picked by hand for this class week.',
        },
        {
          label: PANEL_BADGE.instructorOrder,
          tone: 'neutral',
          text: "Instructors are asked in the module's instructor order.",
        },
        { label: MSG_STATUS.Scheduled!, tone: 'neutral', text: 'The message will be sent later.' },
        { label: MSG_STATUS.Pending!, tone: 'neutral', text: 'The message is waiting to be sent.' },
        { label: MSG_STATUS.Sending!, tone: 'neutral', text: 'The message is being sent now.' },
        { label: MSG_STATUS.Sent!, tone: 'success', text: 'The message was sent.' },
        { label: MSG_STATUS.Failed!, tone: 'danger', text: 'The message could not be delivered.' },
        {
          label: MSG_STATUS.Received!,
          tone: 'neutral',
          text: 'A message came in from the instructor.',
        },
        {
          label: MSG_STATUS.Cancelled!,
          tone: 'neutral',
          text: 'The message was stopped before it was sent.',
        },
      ],
    },
  ];
  const seen = new Set<string>();
  return groups.map((g) => ({
    ...g,
    items: g.items.filter((i) => !seen.has(i.label) && !!seen.add(i.label)),
  }));
}

/** Every badge word the board and its side panel can render (names of messages and class types aside). */
export function renderableLabels(): string[] {
  return [
    ...Object.values(STATUS).map((s) => s.word),
    ...Object.values(BADGE),
    ...Object.values(MARK),
    moreBadges(2),
    ...Object.values(COHORT_BADGE),
    confirmedCount(2, 6),
    ...REGIONS,
    CONFIRMED_AT_RISK,
    ...Object.values(PANEL_BADGE),
    ...Object.values(MSG_STATUS),
    ...CLASS_STATUS,
  ];
}
