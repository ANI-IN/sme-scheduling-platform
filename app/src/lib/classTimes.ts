// Class times of a module or a standard schedule (batch 4, B10): the default times every new module starts with,
// and the day of a class time as a weekday.
import { DateTime } from 'luxon';

export const WEEKDAY_NAMES = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
] as const;

/**
 * A class time's day as a weekday. class_pattern_item.day_offset counts days from the start of the class week, and
 * planning puts the earliest class on the first date chosen (private.plan_week_row). Class weeks start on Sunday in
 * the usual case (the cohorts, the board's rows and the default class times), so offset 0 is Sunday and 4 is
 * Thursday; 7 to 13 fall in the next week.
 */
export const dayLabel = (o: number) =>
  o < 7 ? WEEKDAY_NAMES[o]! : `${WEEKDAY_NAMES[o % 7]} of the next week`;

/** The one hint where the count of days matters. */
export const DAY_HINT =
  'For a class week that starts on Sunday, as usual. Planned from another day, the classes keep the same gaps.';

/** A class time as the form fills it in. */
export type ClassTimeInput = {
  class_type: string;
  day_offset: number;
  start_time: string;
  duration_minutes: number;
};

/**
 * The class times every new module starts with, filled in and editable: the live class on Sunday from 9:00 AM to
 * 1:00 PM and the assignment review on Thursday from 6:00 PM to 8:00 PM, in the cohort's local time (US Pacific for
 * US cohorts).
 */
export const DEFAULT_CLASS_TIMES: readonly ClassTimeInput[] = [
  { class_type: 'Live class', day_offset: 0, start_time: '09:00', duration_minutes: 240 },
  { class_type: 'Assignment review', day_offset: 4, start_time: '18:00', duration_minutes: 120 },
];

/**
 * What the Add class form starts with: the first default class time whose class type is not there yet, so an empty
 * module or standard gets the live class and then the review. When both are there, the live class default.
 */
export function nextClassTime(have: readonly { class_type: string }[]): ClassTimeInput {
  const missing = DEFAULT_CLASS_TIMES.find((d) => !have.some((h) => h.class_type === d.class_type));
  return { ...(missing ?? DEFAULT_CLASS_TIMES[0]!) };
}

/**
 * The form after choosing another class type: that type's default day and time, but only while the day, time and
 * length are still the defaults of the type chosen before (what the person typed is kept).
 */
export function withClassType(form: ClassTimeInput, classType: string): ClassTimeInput {
  const before = DEFAULT_CLASS_TIMES.find((d) => d.class_type === form.class_type);
  const after = DEFAULT_CLASS_TIMES.find((d) => d.class_type === classType);
  const untouched =
    !!before &&
    before.day_offset === form.day_offset &&
    before.start_time === form.start_time &&
    before.duration_minutes === form.duration_minutes;
  return untouched && after ? { ...after } : { ...form, class_type: classType };
}

/** "9:00 AM" from "09:00" or "09:00:00". */
export const clockTime = (t: string) =>
  DateTime.fromFormat(t.slice(0, 5), 'HH:mm').toFormat('h:mm a');

/** "Live class: Sunday, 9:00 AM to 1:00 PM". */
export function classTimeText(p: ClassTimeInput): string {
  const start = DateTime.fromFormat(p.start_time.slice(0, 5), 'HH:mm');
  const end = start.plus({ minutes: p.duration_minutes });
  return `${p.class_type}: ${dayLabel(p.day_offset)}, ${start.toFormat('h:mm a')} to ${end.toFormat('h:mm a')}`;
}
