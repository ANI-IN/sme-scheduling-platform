import { describe, expect, it } from 'vitest';
import { signInMessage, withRetry } from './signIn';

describe('sign in messages (review finding R41)', () => {
  it('shows the reasons the database gives', () => {
    const m = 'SME Scheduling is in a closed beta. Ask an admin to add you to the beta list.';
    expect(signInMessage(m)).toBe(m);
  });
  it('never shows other text from the address', () => {
    expect(signInMessage('Your account is locked, call 555 0100')).toBe(
      'Sign in did not work. Use your company Google account, or ask an admin.',
    );
    expect(signInMessage(null)).toBeNull();
  });
});

describe('loading the account is retried', () => {
  it('tries again after a failure and returns the answer', async () => {
    let calls = 0;
    const r = await withRetry(
      async () => {
        calls += 1;
        if (calls < 3) throw new Error('network');
        return 'account';
      },
      [0, 0],
    );
    expect(r).toBe('account');
    expect(calls).toBe(3);
  });
  it('gives up after the last wait', async () => {
    await expect(withRetry(async () => Promise.reject(new Error('down')), [0])).rejects.toThrow('down');
  });
});
