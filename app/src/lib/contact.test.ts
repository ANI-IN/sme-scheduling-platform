import { describe, expect, it } from 'vitest';
import { contactResult } from './contact';

describe('what Contact instructor says (review finding R37)', () => {
  it('names the channels the message was queued for', () => {
    expect(
      contactResult('Maya', [
        { channel: 'Discord', status: 'Pending', blocked: false, last_error: null },
        { channel: 'Email', status: 'Pending', blocked: false, last_error: null },
      ]),
    ).toEqual({ ok: true, text: 'Message to Maya is on its way by Discord and email.' });
  });
  it('says when one copy was blocked, and why', () => {
    const r = contactResult('Maya', [
      { channel: 'Discord', status: 'Pending', blocked: false, last_error: null },
      { channel: 'Email', status: 'Cancelled', blocked: true, last_error: 'Not sent: during the beta.' },
    ]);
    expect(r.ok).toBe(false);
    expect(r.text).toBe(
      'Message to Maya is on its way by Discord. The email copy was not sent. Not sent: during the beta.',
    );
  });
  it('says when nothing could be sent', () => {
    expect(contactResult('Maya', []).text).toBe(
      'Nothing was sent to Maya: there is no Discord channel or email to send to.',
    );
  });
});
