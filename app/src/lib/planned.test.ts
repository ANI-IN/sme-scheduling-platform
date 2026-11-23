import { describe, expect, it } from 'vitest';
import { DateTime } from 'luxon';
import { askingStarts, cannotStart, orderPlace, plannedLine, type Planned } from './planned';

const now = DateTime.fromISO('2026-10-01T12:00:00Z');
const base: Planned = {
  module_week_id: 'w1',
  confirmed: null,
  asking: null,
  planned: { instructor_id: 'i1', name: 'Victor Palmer', source: 'Ranking', rank: 1 },
  // 17:00 UTC on Oct 31 is 10:00 AM in US Pacific and 10:30 PM in India, the same day.
  asking_starts_at: '2026-10-31T17:00:00Z',
  first_class_at: '2026-11-30T17:00:00Z',
  paused: false,
  at_risk: false,
  setup_incomplete: false,
  finished: false,
};

describe('orderPlace', () => {
  it('names the place in the instructor order', () => {
    expect(orderPlace({ ...base.planned!, rank: 1 })).toBe('Primary');
    expect(orderPlace({ ...base.planned!, rank: 2 })).toBe('Backup 1');
    expect(orderPlace({ ...base.planned!, rank: 4 })).toBe('Backup 3');
  });
  it('says Chosen list for a list picked by hand', () => {
    expect(orderPlace({ ...base.planned!, source: 'Manual', rank: null })).toBe('Chosen list');
  });
});

describe('plannedLine', () => {
  it('before anyone is asked: who is planned and the day asking starts', () => {
    expect(plannedLine(base, now, 'US')).toBe(
      'Planned: Victor Palmer (Primary), asking starts Sat, Oct 31',
    );
  });
  it('shows the day in the class week time zone', () => {
    const late = { ...base, asking_starts_at: '2026-10-31T20:00:00Z' };
    expect(plannedLine(late, now, 'US')).toBe(
      'Planned: Victor Palmer (Primary), asking starts Sat, Oct 31',
    );
    expect(plannedLine(late, now, 'India')).toBe(
      'Planned: Victor Palmer (Primary), asking starts Sun, Nov 1',
    );
  });
  it('once asked: waiting for an answer from that person', () => {
    expect(plannedLine({ ...base, asking: 'Victor Palmer' }, now, 'US')).toBe(
      'Waiting for an answer: Victor Palmer',
    );
  });
  it('once confirmed: who is confirmed, even if a request is still open', () => {
    expect(plannedLine({ ...base, asking: 'Maya Rao', confirmed: 'Victor Palmer' }, now)).toBe(
      'Confirmed: Victor Palmer',
    );
  });
  it('says when nobody can be asked, and nothing for a finished week', () => {
    expect(plannedLine({ ...base, planned: null }, now)).toBe('Nobody left to ask');
    expect(plannedLine({ ...base, finished: true }, now)).toBeNull();
  });
});

describe('askingStarts', () => {
  it('a paused week is not asked', () => {
    expect(askingStarts({ ...base, paused: true }, now)).toBe('requests paused');
  });
  it('waits for the setup to be complete', () => {
    expect(askingStarts({ ...base, setup_incomplete: true }, now)).toBe(
      'asking starts once the setup is complete',
    );
  });
  it('soon when the day has come, or the week is at risk', () => {
    expect(askingStarts(base, DateTime.fromISO('2026-11-02T00:00:00Z'))).toBe('asking starts soon');
    expect(askingStarts({ ...base, at_risk: true }, now)).toBe('asking starts soon');
    expect(askingStarts({ ...base, asking_starts_at: null }, now)).toBe('asking starts soon');
  });
});

describe('cannotStart', () => {
  it('lets a week with a planned person start', () => {
    expect(cannotStart(base)).toBeNull();
    expect(cannotStart({ ...base, paused: true })).toBeNull();
  });
  it('gives the reason otherwise', () => {
    expect(cannotStart({ ...base, confirmed: 'Maya Rao' })).toBe('Maya Rao is already confirmed.');
    expect(cannotStart({ ...base, asking: 'Maya Rao' })).toBe('Maya Rao is already being asked.');
    expect(cannotStart({ ...base, planned: null })).toBe('Nobody in its order can be asked.');
    expect(cannotStart({ ...base, finished: true })).toBe('It is over or cancelled.');
  });
});
