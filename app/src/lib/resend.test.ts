import { describe, expect, it } from 'vitest';
import { resendCandidate, type ResendMessage } from './resend';

const m = (x: Partial<ResendMessage>): ResendMessage => ({
  id: 'x',
  audience: 'Instructor',
  direction: 'Outbound',
  template_id: 'M1',
  status: 'Sent',
  blocked: false,
  instructor_id: 'a',
  ...x,
});

describe('resendCandidate (review finding R11)', () => {
  it('takes the newest message to the current instructor only', () => {
    const list = [m({ id: 'other', instructor_id: 'b' }), m({ id: 'mine' }), m({ id: 'older' })];
    expect(resendCandidate(list, 'a')?.id).toBe('mine');
  });
  it('never offers a closing or cancellation notice', () => {
    const list = [
      m({ id: 'released', template_id: 'M16' }),
      m({ id: 'cancelled', template_id: 'M11' }),
      m({ id: 'closed', template_id: 'M3' }),
      m({ id: 'withdrawn', template_id: 'M12' }),
      m({ id: 'confirm', template_id: 'M4' }),
    ];
    expect(resendCandidate(list, 'a')?.id).toBe('confirm');
  });
  it('offers only one that went out, failed or was blocked', () => {
    const list = [
      m({ id: 'waiting', status: 'Pending' }),
      m({ id: 'cancelled', status: 'Cancelled' }),
      m({ id: 'blocked', status: 'Cancelled', blocked: true }),
    ];
    expect(resendCandidate(list, 'a')?.id).toBe('blocked');
  });
  it('offers nothing when nobody is booked or being asked', () => {
    expect(resendCandidate([m({})], null)).toBeNull();
  });
});
