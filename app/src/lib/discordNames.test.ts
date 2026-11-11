import { describe, expect, it } from 'vitest';
import { discordNames, setDiscordNames } from './discordNames';
import { plain } from './plain';

describe('Discord tags are shown as names', () => {
  setDiscordNames([
    ['1200000000000000008', 'Andrew Keane'],
    ['1200000000000000008', 'Maya Rao'],
  ]);
  it('replaces a known tag with the person, the team member first', () => {
    expect(discordNames('Hi <@1200000000000000008> 👋')).toBe('Hi @Andrew Keane 👋');
  });
  it('handles the nickname form and unknown accounts', () => {
    expect(discordNames('Team: <@!1200000000000000008> <@999999999999999999>')).toBe(
      'Team: @Andrew Keane @someone on Discord',
    );
  });
  it('plain text in history and tasks never shows the codes', () => {
    expect(plain('Confirmed, tagged <@1200000000000000008>')).not.toMatch(/<@/);
  });
});
