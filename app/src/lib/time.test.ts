import { describe, expect, it } from 'vitest';
import { fmtPT, fmtPTRange, isSunday, parseDateList, ptParts, weeklyDates } from './time';
import { isCompanyEmail, isDiscordId, isEmail, parseChannelLink } from './validation';
import { toCsv } from './csv';

describe('Pacific time display (PRD §12)', () => {
  it('shows PST in winter', () => {
    expect(fmtPT('2027-01-31T17:00:00Z')).toBe('Sun Jan 31, 9:00 AM PST');
  });
  it('shows PDT on the first PDT Sunday, same wall-clock time', () => {
    expect(fmtPT('2027-03-14T16:00:00Z')).toBe('Sun Mar 14, 9:00 AM PDT');
  });
  it('formats ranges', () => {
    expect(fmtPTRange('2027-02-05T02:00:00Z', '2027-02-05T04:00:00Z')).toBe(
      'Thu Feb 4, 6:00 PM – 8:00 PM PST',
    );
  });
  it('extracts PT date/time for editing', () => {
    expect(ptParts('2027-03-14T16:00:00Z')).toEqual({ date: '2027-03-14', time: '09:00' });
  });
});

describe('planner dates', () => {
  it('builds weekly Sundays', () => {
    expect(weeklyDates('2027-01-03', 3)).toEqual(['2027-01-03', '2027-01-10', '2027-01-17']);
  });
  it('parses a pasted date list in several formats', () => {
    const r = parseDateList('2027-01-03\n1/10/2027\nJan 17, 2027; nonsense');
    expect(r.dates).toEqual(['2027-01-03', '2027-01-10', '2027-01-17']);
    expect(r.bad).toEqual(['nonsense']);
  });
  it('knows Sundays', () => {
    expect(isSunday('2027-01-31')).toBe(true);
    expect(isSunday('2027-02-01')).toBe(false);
  });
});

describe('validation (PRD 7.7)', () => {
  it('checks emails', () => {
    expect(isEmail('a@b.co')).toBe(true);
    expect(isEmail('not an email')).toBe(false);
  });
  it('checks Discord IDs are 17–20 digits', () => {
    expect(isDiscordId('120000000000000002')).toBe(true);
    expect(isDiscordId('1234')).toBe(false);
    expect(isDiscordId('123456789012345678901')).toBe(false);
  });
  it('extracts server and channel IDs from a channel link', () => {
    expect(
      parseChannelLink('https://discord.com/channels/111111111111111111/222222222222222222'),
    ).toEqual({
      serverId: '111111111111111111',
      channelId: '222222222222222222',
    });
    expect(parseChannelLink('https://example.com/x')).toBeNull();
  });
  it('restricts sign-in to the company domain', () => {
    expect(isCompanyEmail('ops@acme.com', 'acme.com')).toBe(true);
    expect(isCompanyEmail('ops@gmail.com', 'acme.com')).toBe(false);
    expect(isCompanyEmail('ops@acme.com.evil.io', 'acme.com')).toBe(false);
  });
});

describe('CSV export', () => {
  it('quotes commas, quotes and newlines', () => {
    expect(toCsv([{ a: 'x,y', b: 'say "hi"', c: 'l1\nl2' }])).toBe(
      'a,b,c\n"x,y","say ""hi""","l1\nl2"',
    );
  });
});
