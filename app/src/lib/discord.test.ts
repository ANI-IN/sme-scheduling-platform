import { describe, expect, it } from 'vitest';
import { BOT_PERMISSIONS, botInviteUrl, cleanUsername, usernameProblem } from './discord';

describe('Discord helpers', () => {
  it('asks for exactly four permissions', () => {
    // View Channels, Send Messages, Embed Links, Read Message History.
    expect(BOT_PERMISSIONS).toBe(84992);
  });
  it('builds the invite link only from a real application ID', () => {
    expect(botInviteUrl('120000000000000002')).toBe(
      'https://discord.com/oauth2/authorize?client_id=120000000000000002&scope=bot&permissions=84992',
    );
    expect(botInviteUrl('')).toBeNull();
    expect(botInviteUrl('abc')).toBeNull();
  });
  it('cleans a username the way the database stores it', () => {
    expect(cleanUsername('  @Maya.K ')).toBe('maya.k');
  });
  it('explains a username problem in plain words', () => {
    expect(usernameProblem('maya.k')).toBeUndefined();
    expect(usernameProblem('')).toBeUndefined();
    expect(usernameProblem('maya#1234')).toMatch(/without # and numbers/);
    expect(usernameProblem('a')).toMatch(/2 to 32/);
    expect(usernameProblem('maya k')).toMatch(/2 to 32/);
  });
});
