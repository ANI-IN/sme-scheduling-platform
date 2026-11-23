import { describe, expect, it } from 'vitest';
import { blockedReasons, currentBlocked, type MessageLite } from './blocked';

const m = (o: Partial<MessageLite>): MessageLite => ({
  id: 'x',
  created_at: '2026-11-23T08:00:00Z',
  status: 'Cancelled',
  blocked: true,
  direction: 'Outbound',
  template_id: 'M1',
  channel: 'Email',
  instructor_id: 'vin',
  module_week_id: 'w1',
  recipient_label: 'Victor Palmer',
  last_error: 'Not sent: during the beta, messages go only to test instructors.',
  ...o,
});

describe('currentBlocked', () => {
  it('keeps a blocked message nothing replaced', () => {
    expect(currentBlocked([m({ id: 'a' })]).map((x) => x.id)).toEqual(['a']);
  });
  it('drops it once a later copy went out or is queued', () => {
    const later = m({
      id: 'b',
      status: 'Sent',
      blocked: false,
      created_at: '2026-11-23T09:00:00Z',
    });
    expect(currentBlocked([m({ id: 'a' }), later])).toEqual([]);
  });
  it('keeps it when only an older copy went out', () => {
    const older = m({
      id: 'b',
      status: 'Sent',
      blocked: false,
      created_at: '2026-11-23T07:00:00Z',
    });
    expect(currentBlocked([older, m({ id: 'a' })]).map((x) => x.id)).toEqual(['a']);
  });
  it('treats each channel, kind and class week on its own, newest first', () => {
    const r = currentBlocked([
      m({ id: 'a' }),
      m({ id: 'b', channel: 'Discord', created_at: '2026-11-23T08:01:00Z' }),
      m({ id: 'c', module_week_id: 'w2', created_at: '2026-11-23T08:02:00Z' }),
    ]);
    expect(r.map((x) => x.id)).toEqual(['c', 'b', 'a']);
  });
  it('ignores cancelled messages that no rule blocked, and replies', () => {
    expect(currentBlocked([m({ blocked: false }), m({ id: 'r', direction: 'Inbound' })])).toEqual(
      [],
    );
  });
});

describe('blockedReasons', () => {
  it('lists each reason once', () => {
    expect(blockedReasons([m({ id: 'a' }), m({ id: 'b', channel: 'Discord' })])).toHaveLength(1);
  });
});
