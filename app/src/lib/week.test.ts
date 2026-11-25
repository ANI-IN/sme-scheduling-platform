import { DateTime } from 'luxon';
import { describe, expect, it } from 'vitest';
import { inThisWeek, weekStartPT } from './week';

const at = (iso: string) => DateTime.fromISO(iso, { setZone: true });

describe('one week rule for every page (review finding R29)', () => {
  it('starts on the Sunday in Pacific time', () => {
    expect(weekStartPT(at('2027-01-06T12:00:00-08:00')).toISODate()).toBe('2027-01-03');
  });
  it('is still last week on Sunday morning in India, while it is Saturday in the Pacific', () => {
    expect(weekStartPT(at('2027-01-10T08:00:00+05:30')).toISODate()).toBe('2027-01-03');
  });
  it('turns over at midnight Pacific', () => {
    expect(weekStartPT(at('2027-01-10T00:30:00-08:00')).toISODate()).toBe('2027-01-10');
  });
  it('puts a class week in this week by its week date, the same on every page', () => {
    const now = at('2027-01-10T08:00:00+05:30');
    expect(inThisWeek('2027-01-03', now)).toBe(true);
    expect(inThisWeek('2027-01-10', now)).toBe(false);
  });
});
