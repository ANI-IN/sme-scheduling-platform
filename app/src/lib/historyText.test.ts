import { describe, expect, it } from 'vitest';
import { describeHistory, type HistoryLike } from './historyText';
import { plain } from './plain';

const ids = {
  shelly: '11111111-1111-1111-1111-111111111111',
  api: '22222222-2222-2222-2222-222222222222',
  sienna: '33333333-3333-3333-3333-333333333333',
};
const book = {
  name: (id: string | null | undefined) =>
    ({ [ids.shelly]: 'Shelly Carver', [ids.api]: 'API Design', [ids.sienna]: 'Sienna' })[id ?? ''],
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
