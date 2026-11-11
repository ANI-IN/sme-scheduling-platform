import { describe, expect, it } from 'vitest';
import {
  classTime,
  classTimeLine,
  fmtRange,
  localCandidates,
  timeFieldLabel,
  timeNote,
} from './region';

describe('US and India class times', () => {
  it('shows a US winter class in PST with the India time', () => {
    // Sun Jan 24, 2027, 9:00 AM PST = 17:00 UTC = 10:30 PM IST.
    const t = classTime('2027-01-24T17:00:00Z', '2027-01-24T21:00:00Z', 'US');
    expect(t.main).toBe('Sun, Jan 24, 9:00 AM to 1:00 PM PST');
    expect(t.india).toBe('10:30 PM to Mon 2:30 AM IST');
  });
  it('keeps 9:00 AM after the March 14, 2027 clock change (PDT)', () => {
    expect(fmtRange('2027-03-14T16:00:00Z', '2027-03-14T20:00:00Z', 'US')).toBe(
      'Sun, Mar 14, 9:00 AM to 1:00 PM PDT',
    );
  });
  it('keeps 9:00 AM after the November 7, 2027 clock change (PST)', () => {
    expect(fmtRange('2027-11-07T17:00:00Z', '2027-11-07T21:00:00Z', 'US')).toBe(
      'Sun, Nov 7, 9:00 AM to 1:00 PM PST',
    );
  });
  it('shows India classes in IST only', () => {
    const t = classTime('2027-01-24T03:30:00Z', '2027-01-24T07:30:00Z', 'India');
    expect(t.main).toBe('Sun, Jan 24, 9:00 AM to 1:00 PM IST');
    expect(t.india).toBeUndefined();
  });
  it('shows the India day when it differs from the US day', () => {
    // Sat Jan 23, 7:30 PM PST = Sun Jan 24, 9:00 AM IST.
    expect(classTimeLine('2027-01-24T03:30:00Z', '2027-01-24T05:30:00Z', 'US')).toBe(
      'Sat, Jan 23, 7:30 PM to 9:30 PM PST (Sun, Jan 24, 9:00 AM to 11:00 AM IST)',
    );
  });
  it('finds a time that does not exist (clocks move forward)', () => {
    expect(localCandidates('2027-03-14', '02:30', 'US')).toHaveLength(0);
    expect(timeNote('2027-03-14', '02:30', 'US').problem).toMatch(/does not exist/);
  });
  it('finds a time that happens twice (clocks move back)', () => {
    const c = localCandidates('2027-11-07', '01:30', 'US');
    expect(c).toHaveLength(2);
    expect(c[0]!.offset).toBe(-420);
    expect(c[1]!.offset).toBe(-480);
    expect(timeNote('2027-11-07', '01:30', 'US').twice).toBe(true);
  });
  it('India has no daylight saving', () => {
    expect(localCandidates('2027-03-14', '02:30', 'India')).toHaveLength(1);
    expect(localCandidates('2027-11-07', '01:30', 'India')).toHaveLength(1);
  });
  it('labels the time field with the zone for that date', () => {
    expect(timeFieldLabel('US', '2027-01-24')).toBe('Time in US Pacific (PST)');
    expect(timeFieldLabel('US', '2027-07-04')).toBe('Time in US Pacific (PDT)');
    expect(timeFieldLabel('India', '2027-07-04')).toBe('Time in India (IST)');
  });
});
