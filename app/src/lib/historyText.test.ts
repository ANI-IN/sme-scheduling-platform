import { describe, expect, it } from 'vitest';
import { describeHistory, type HistoryLike } from './historyText';
import { plain } from './plain';

const ids = {
  shelly: '11111111-1111-1111-1111-111111111111',
  api: '22222222-2222-2222-2222-222222222222',
  sienna: '33333333-3333-3333-3333-333333333333',
  weekend: '44444444-4444-4444-4444-444444444444',
};
const book = {
  name: (id: string | null | undefined) =>
    ({
      [ids.shelly]: 'Shelly Carver',
      [ids.api]: 'API Design',
      [ids.sienna]: 'Sienna',
      [ids.weekend]: 'Weekend cohort',
    })[id ?? ''],
  settingLabel: (k: string) =>
    k === 'outreach_days' ? 'Start asking instructors this many days before the class' : undefined,
};
const base: HistoryLike = {
  actor_kind: 'TeamMember',
  actor_label: 'Sienna',
  category: 'Setup changes',
  action: '',
  entity_table: null,
  module_id: null,
  instructor_id: null,
  domain_id: null,
  before: null,
  after: null,
  note: null,
  undo_of: null,
};

describe('History in plain sentences', () => {
  it('describes a single move in the instructor order', () => {
    const d = describeHistory(
      {
        ...base,
        action: 'Ranking saved',
        entity_table: 'module_ranking',
        module_id: ids.api,
        before: { names: ['Robin', 'Tomas', 'Shelly Carver'] },
        after: { names: ['Robin', 'Shelly Carver', 'Tomas'] },
      },
      book,
    );
    expect(d.sentence).toBe('Sienna moved Shelly Carver from Backup 2 to Backup 1 in API Design');
  });

  it('never shows ids or raw field names for an edit', () => {
    const d = describeHistory(
      {
        ...base,
        action: 'module_owner added',
        entity_table: 'module_owner',
        after: { id: 'x', module_id: ids.api, team_member_id: ids.sienna },
      },
      book,
    );
    expect(d.sentence).toBe('Sienna added Sienna as an owner of API Design');
    const e = describeHistory(
      {
        ...base,
        action: 'instructor changed',
        entity_table: 'instructor',
        before: { full_name: 'Shelly Carver', status: 'Active', version: 1 },
        after: { full_name: 'Shelly Carver', status: 'Inactive', version: 2 },
      },
      book,
    );
    expect(e.sentence).toBe(
      'Sienna changed status for instructor Shelly Carver from Active to Inactive',
    );
    expect(JSON.stringify(e)).not.toMatch(/[0-9a-f]{8}-|version/);
  });

  it('names messages instead of template codes', () => {
    const d = describeHistory(
      {
        ...base,
        actor_kind: 'System',
        category: 'Messages',
        action: 'M1 sent to Shelly Carver via Discord',
      },
      book,
    );
    expect(d.sentence).toBe('Request to teach sent to Shelly Carver by Discord');
  });

  it('names messages whose route has several words (decision 272)', () => {
    const say = (action: string) =>
      describeHistory({ ...base, actor_kind: 'System', category: 'Messages', action }, book)
        .sentence;
    expect(say('M4 sent to Maya Rao via Discord (#test-instructor-a)')).toBe(
      'Confirmation sent to Maya Rao by Discord in #test-instructor-a',
    );
    expect(say('T2 sent to Andrew Keane via Discord direct message')).toBe(
      'Confirmation alert sent to Andrew Keane by Discord direct message',
    );
    expect(say('M14 sent to Maya Rao via Email')).toBe('Reply sent to Maya Rao by email');
    expect(say('M4 failed to Maya Rao via Discord (#test-instructor-a)')).toBe(
      'Could not send the confirmation to Maya Rao by Discord in #test-instructor-a',
    );
  });

  it('describes settings with their labels', () => {
    const d = describeHistory(
      {
        ...base,
        action: 'setting added',
        entity_table: 'setting',
        after: { key: 'outreach_days', value: 21 },
      },
      book,
    );
    expect(d.sentence).toBe(
      'Sienna set "Start asking instructors this many days before the class" to 21',
    );
  });
});

describe('plain wording for database text', () => {
  it('removes dashes and applies the glossary', () => {
    expect(plain('At risk: Concurrency · Sun Jan 31 + Thu Feb 4 — Shelly cancelled')).toBe(
      'At risk: Concurrency, Sun Jan 31 + Thu Feb 4: Shelly cancelled',
    );
    expect(plain('Readiness check failed: Concurrency')).toBe(
      'Setup check needs fixing: Concurrency',
    );
    expect(plain('No reply to the 10-day check-in: Shelly')).toBe(
      'No answer to the reminder 10 days before class: Shelly',
    );
  });

  it('describes going live, pausing messages and downloads', () => {
    expect(describeHistory({ ...base, action: 'Went live' }, book).sentence).toBe(
      'Sienna took the domain live: real instructors now get messages',
    );
    expect(
      describeHistory(
        { ...base, category: 'System', action: 'All messages to instructors paused' },
        book,
      ).sentence,
    ).toBe('Sienna paused all messages to instructors');
    expect(
      describeHistory(
        { ...base, category: 'Team actions', action: 'Downloaded Upcoming classes' },
        book,
      ).sentence,
    ).toBe('Sienna downloaded Upcoming classes as a spreadsheet');
  });
  it('names the level of a settings override and escalation contacts', () => {
    const d = describeHistory(
      {
        ...base,
        action: 'setting added',
        entity_table: 'setting',
        after: { key: 'outreach_days', module_id: ids.api, value: 25 },
      },
      book,
    );
    expect(d.sentence).toContain('for API Design');
    const e = describeHistory(
      {
        ...base,
        action: 'domain_team added',
        entity_table: 'domain_team',
        after: { team_member_id: ids.shelly, role: 'Escalation' },
      },
      book,
    );
    expect(e.sentence).toContain('Shelly Carver as an escalation contact');
  });
});

describe('standard schedules in plain sentences (decisions 298 and 299)', () => {
  it('names the parts of a standard schedule', () => {
    expect(
      describeHistory(
        {
          ...base,
          action: 'standard_schedule_module added',
          entity_table: 'standard_schedule_module',
          after: { module_id: ids.api, position: 2, label: 'SWEs: 2. API Design' },
        },
        book,
      ).sentence,
    ).toBe('Sienna added API Design as module 2 of the standard schedule SWEs');
    expect(
      describeHistory(
        {
          ...base,
          action: 'standard_schedule_break added',
          entity_table: 'standard_schedule_break',
          after: { after_position: 1, weeks: 2, label: 'SWEs: 2 week break after module 1' },
        },
        book,
      ).sentence,
    ).toBe('Sienna added the 2 week break after module 1 in the standard schedule SWEs');
    const c = describeHistory(
      {
        ...base,
        action: 'standard_schedule_class changed',
        entity_table: 'standard_schedule_class',
        before: {
          module_id: ids.api,
          class_type: 'Live class',
          day_offset: 0,
          start_time: '09:00:00',
          label: 'SWEs: API Design, Live class',
        },
        after: {
          module_id: ids.api,
          class_type: 'Live class',
          day_offset: 0,
          start_time: '10:00:00',
          label: 'SWEs: API Design, Live class',
        },
      },
      book,
    );
    expect(c.sentence).toBe(
      'Sienna changed start time (local time) for the live class on the first day at 10:00 AM (local time) for API Design in the standard schedule SWEs from 9:00 AM to 10:00 AM',
    );
  });

  it('says when a standard schedule is archived', () => {
    expect(
      describeHistory(
        {
          ...base,
          action: 'standard_schedule changed',
          entity_table: 'standard_schedule',
          before: { name: 'SWEs', archived_at: null },
          after: { name: 'SWEs', archived_at: '2026-11-22T10:00:00Z' },
        },
        book,
      ).sentence,
    ).toBe('Sienna archived the standard schedule SWEs');
  });

  it('describes planning from a standard, Reset to standard and updating cohorts', () => {
    const team = { ...base, category: 'Team actions' };
    expect(
      describeHistory(
        {
          ...team,
          action: 'Cohorts planned from a standard',
          after: { schedule: 'SWEs', cohorts: ['March A', 'March B'], class_weeks: 6 },
        },
        book,
      ).sentence,
    ).toBe('Sienna planned March A, March B from the standard schedule SWEs: 6 class weeks');
    expect(
      describeHistory(
        {
          ...team,
          action: 'Reset to standard',
          after: { cohort_id: null, class_weeks_changed: 1, not_updated: 0 },
        },
        book,
      ).sentence,
    ).toBe('Sienna reset 1 class week to the standard');
    expect(
      describeHistory(
        {
          ...team,
          action: 'Standard applied: SWEs',
          after: { schedule: 'SWEs', new_class_weeks: 1, class_weeks_changed: 2, not_updated: 3 },
        },
        book,
      ).sentence,
    ).toBe(
      'Sienna updated cohorts from the standard schedule SWEs: 2 class weeks changed, 1 new, 3 not updated',
    );
  });
});

describe('breaks and cohort holidays in plain sentences (decision 301)', () => {
  it('names a break and a cohort holiday', () => {
    expect(
      describeHistory(
        {
          ...base,
          action: 'cohort_break added',
          entity_table: 'cohort_break',
          after: {
            cohort_id: ids.weekend,
            reason: 'Diwali',
            starts_on: '2027-10-31',
            weeks: 1,
            moved: [{ module_week_id: ids.api }],
            label: 'Weekend cohort: break, Diwali, Sun, Oct 31 to Sat, Nov 6 (1 week)',
          },
        },
        book,
      ).sentence,
    ).toBe('Sienna added the break Diwali of Weekend cohort');
    expect(
      describeHistory(
        {
          ...base,
          action: 'cohort_holiday added',
          entity_table: 'cohort_holiday',
          after: { cohort_id: ids.weekend, name: 'Founders day', date: '2027-03-11' },
        },
        book,
      ).sentence,
    ).toContain('the holiday Founders day of Weekend cohort on');
  });

  it('says who added or removed a break', () => {
    const team = { ...base, category: 'Team actions' };
    expect(describeHistory({ ...team, action: 'Break added: Diwali' }, book).sentence).toBe(
      'Sienna added the break Diwali',
    );
    expect(
      describeHistory({ ...team, action: 'Program break removed: Week off' }, book).sentence,
    ).toBe('Sienna removed the program break Week off');
  });
});

describe('proposed times in plain sentences (decision 302)', () => {
  it('says who proposed, accepted or rejected a time', () => {
    const team = { ...base, category: 'Team actions', module_id: ids.api };
    expect(
      describeHistory({ ...team, action: 'Proposed time accepted: Shelly Carver' }, book).sentence,
    ).toBe('Sienna accepted the time Shelly Carver proposed for API Design');
    expect(
      describeHistory({ ...team, action: 'Proposed time rejected: Shelly Carver' }, book).sentence,
    ).toBe('Sienna kept the time of API Design, not the one Shelly Carver proposed');
    expect(
      describeHistory(
        { ...team, category: 'Instructor responses', action: 'Shelly Carver proposed another time' },
        book,
      ).sentence,
    ).toBe('Shelly Carver proposed another time for API Design');
  });
});

describe('shared classes in plain sentences (decision 303)', () => {
  it('says who shared a class and who gave a cohort its own class back', () => {
    const team = { ...base, category: 'Team actions', module_id: ids.api };
    expect(
      describeHistory({ ...team, action: 'Class shared with 2 other class week(s)' }, book)
        .sentence,
    ).toBe('Sienna shared the API Design class with 2 other class weeks');
    expect(describeHistory({ ...team, action: 'Class no longer shared' }, book).sentence).toBe(
      'Sienna gave API Design its own class again',
    );
  });
});

describe('cohort merges in plain sentences (decision 304)', () => {
  it('says who merged cohorts and who undid it', () => {
    const team = { ...base, category: 'Team actions' };
    expect(
      describeHistory({ ...team, action: 'Cohorts merged into Weekend AB' }, book).sentence,
    ).toBe('Sienna merged cohorts into Weekend AB');
    expect(describeHistory({ ...team, action: 'Cohort merge undone' }, book).sentence).toBe(
      'Sienna undid a cohort merge',
    );
  });
});
