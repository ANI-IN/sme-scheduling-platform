import { describe, expect, it } from 'vitest';
import { BETA_LOCK_NOTE, betaLocked } from './betaLock';

describe('betaLocked (review finding R3)', () => {
  const beta = 'Test instructors and signed in colleagues';
  it('locks people who are not admins while the beta rule is on', () => {
    expect(betaLocked(beta, false)).toBe(true);
  });
  it('never locks an admin', () => {
    expect(betaLocked(beta, true)).toBe(false);
  });
  it('locks nobody when anyone may receive messages', () => {
    expect(betaLocked('Anyone', false)).toBe(false);
    expect(betaLocked(undefined, false)).toBe(false);
  });
  it('says who to ask', () => {
    expect(BETA_LOCK_NOTE).toMatch(/only an admin/);
  });
});
