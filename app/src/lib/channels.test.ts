import { describe, expect, it } from 'vitest';
import { channelNamesFor, parseChannelInput, suggestChannel } from './channels';

const SRV = '111111111111111111';
const ch = (id: string, name: string, extra: Partial<{ server_id: string; bot_can_post: boolean }> = {}) => ({
  id,
  name,
  server_id: SRV,
  ...extra,
});

describe('parseChannelInput', () => {
  it('reads a channel link', () => {
    expect(parseChannelInput('https://discord.com/channels/111111111111111111/222222222222222222')).toBe(
      '222222222222222222',
    );
  });
  it('reads a link with a message part and spaces around it', () => {
    expect(
      parseChannelInput('  https://discord.com/channels/111111111111111111/222222222222222222/333333333333333333 '),
    ).toBe('222222222222222222');
  });
  it('reads an ID and a <#id> mention', () => {
    expect(parseChannelInput('222222222222222222')).toBe('222222222222222222');
    expect(parseChannelInput('<#222222222222222222>')).toBe('222222222222222222');
  });
  it('refuses anything else', () => {
    expect(parseChannelInput('#victor')).toBeNull();
    expect(parseChannelInput('12345')).toBeNull();
    expect(parseChannelInput('https://example.com/channels/1/2')).toBeNull();
  });
});

describe('suggestChannel', () => {
  const person = { fullName: 'Victor Palmer', username: 'victor.p' };
  it('lists the usual names', () => {
    expect(channelNamesFor(person)).toEqual(['victorp', 'victorpalmer', 'victor']);
  });
  it('suggests the channel named after the full name', () => {
    const list = [ch('1', 'general'), ch('2', 'victor-palmer'), ch('3', 'alerts')];
    expect(suggestChannel(list, person, SRV)?.id).toBe('2');
  });
  it('suggests the first name when nothing better matches', () => {
    expect(suggestChannel([ch('1', 'general'), ch('2', 'victor')], person, SRV)?.id).toBe('2');
  });
  it('prefers the full name over the first name', () => {
    expect(suggestChannel([ch('2', 'victor'), ch('3', 'victorpalmer')], person, SRV)?.id).toBe('3');
  });
  it('suggests nothing when two channels match equally, or only in another server', () => {
    expect(suggestChannel([ch('2', 'victor-palmer'), ch('3', 'victor_palmer')], person, SRV)).toBeUndefined();
    expect(suggestChannel([ch('2', 'victor', { server_id: '999999999999999999' })], person, SRV)).toBeUndefined();
  });
  it('leaves out channels the bot cannot post in and channels already taken', () => {
    expect(suggestChannel([ch('2', 'victor', { bot_can_post: false })], person, SRV)).toBeUndefined();
    expect(suggestChannel([ch('2', 'victor')], person, SRV, new Set(['2']))).toBeUndefined();
  });
});
