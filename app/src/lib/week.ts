// Review finding R29 (decision 349): every page counts weeks the same way: Sunday to Saturday in US Pacific time,
// and a class week belongs to the week of its Sunday date.
import { DateTime } from 'luxon';
import { PT } from './time';

export const weekStartPT = (now: DateTime = DateTime.now()) => {
  const n = now.setZone(PT);
  return n.minus({ days: n.weekday % 7 }).startOf('day');
};

export const inThisWeek = (weekStartDate: string, now?: DateTime) =>
  weekStartDate === weekStartPT(now).toISODate();
