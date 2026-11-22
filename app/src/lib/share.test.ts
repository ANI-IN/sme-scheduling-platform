import { describe, expect, it } from 'vitest';
import { timesChoice, withoutGuest } from './share';

describe('timesChoice', () => {
  it('asks for a choice while the times differ and nobody chose', () => {
    expect(timesChoice('', 'host', true)).toEqual({ value: '', needsChoice: true });
  });
  it('choosing this class week sends its own ID, so the database knows it was chosen', () => {
    expect(timesChoice('host', 'host', true)).toEqual({ value: 'host', needsChoice: false });
  });
  it('shows this class week when the times are the same or not known yet', () => {
    expect(timesChoice('', 'host', false)).toEqual({ value: 'host', needsChoice: false });
    expect(timesChoice('', 'host', undefined)).toEqual({ value: 'host', needsChoice: false });
  });
});

describe('withoutGuest', () => {
  it('makes the choice again when the times were those of the class week taken out', () => {
    expect(withoutGuest(['a', 'b'], 'a', 'a')).toEqual({ chosen: ['b'], timesFrom: '' });
  });
  it('keeps another choice', () => {
    expect(withoutGuest(['a', 'b'], 'a', 'host')).toEqual({ chosen: ['b'], timesFrom: 'host' });
  });
});
