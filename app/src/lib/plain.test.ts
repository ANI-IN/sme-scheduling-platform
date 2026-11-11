import { describe, expect, it } from 'vitest';
import { messageTitle, plain, plainLabel } from './plain';

describe('plain language layer (docs/GLOSSARY.md)', () => {
  it('removes dashes', () => {
    expect(plain('API Design — Live class')).toBe('API Design: Live class');
    expect(plain('3–10 days')).toBe('3 to 10 days');
  });
  it('uses the glossary terms', () => {
    expect(plain('No reply to the 2-day check-in: API Design')).toBe(
      'No answer to the reminder 2 days before class: API Design',
    );
    expect(plain('Readiness check failed')).toBe('Setup check needs fixing');
    expect(plain('Checklist overdue: API Design')).toBe('Class tasks overdue: API Design');
    expect(plain('the module week ranking')).toBe('the class week instructor order');
    expect(plain('kill switch on')).toBe('pause on all messages on');
  });
  it('uses the words of the team for database values (UI-5)', () => {
    expect(plain('Not verified')).toBe('Contact details not checked');
    expect(plain('Inactive')).toBe('Not in use');
    expect(plain('Help pending')).toBe('Help request open');
    expect(plain('Released by ops')).toBe('Released by the team');
    expect(plain('Maya was deactivated')).toBe('Maya is no longer in use');
    expect(plain('Outreach changed by ops')).toBe('The team changed who is asked');
    expect(plain('Maya did not reply to the last check-in')).toBe(
      'Maya did not reply to the last reminder before class',
    );
  });
  it('joins class dates with "and"', () => {
    expect(plainLabel('Sun Jan 31 + Thu Feb 4')).toBe('Sun Jan 31 and Thu Feb 4');
  });
  it('names messages', () => {
    expect(messageTitle('M6')).toBe('Reminder before class');
    expect(messageTitle('ZZ')).toBe('Message');
  });
});
