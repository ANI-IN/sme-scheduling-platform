// Discord in the app: the bot invite link, and plain words for each Discord status.
// The bot only needs four permissions: View Channels, Send Messages, Embed Links, Read Message History.
import type { Tone } from '@/components/ui';

/** The bot's application (client) ID from the Discord Developer Portal. Not a secret. */
export const discordClientId = (
  import.meta.env.VITE_DISCORD_CLIENT_ID as string | undefined
)?.trim();

/** View Channels (1024) + Send Messages (2048) + Embed Links (16384) + Read Message History (65536). */
export const BOT_PERMISSIONS = 1024 + 2048 + 16384 + 65536;

/** The link that adds the bot to a server, with exactly the permissions it needs. */
export function botInviteUrl(clientId = discordClientId): string | null {
  if (!clientId || !/^\d{17,20}$/.test(clientId)) return null;
  return `https://discord.com/oauth2/authorize?client_id=${clientId}&scope=bot&permissions=${BOT_PERMISSIONS}`;
}

export type PersonDiscordStatus = 'NotSet' | 'Checking' | 'Found' | 'NotFound' | 'Problem';
export type ServerDiscordStatus = 'NotSet' | 'Checking' | 'Ready' | 'Problem';

export const personStatus: Record<PersonDiscordStatus, { label: string; tone: Tone }> = {
  NotSet: { label: 'No Discord username', tone: 'neutral' },
  Checking: { label: 'Checking Discord', tone: 'info' },
  Found: { label: 'Discord found', tone: 'success' },
  NotFound: { label: 'Not found on Discord', tone: 'warning' },
  Problem: { label: 'Discord problem', tone: 'danger' },
};

export const serverStatus: Record<ServerDiscordStatus, { label: string; tone: Tone }> = {
  NotSet: { label: 'No server chosen', tone: 'neutral' },
  Checking: { label: 'Checking', tone: 'info' },
  Ready: { label: 'Ready', tone: 'success' },
  Problem: { label: 'Needs a fix', tone: 'danger' },
};

/** "maya.k" from "@Maya.K " (what the database stores). */
export const cleanUsername = (v: string) => v.trim().replace(/^@/, '').toLowerCase();

/** Empty, or a problem with the username in plain words. */
export function usernameProblem(v: string): string | undefined {
  const u = cleanUsername(v);
  if (!u) return undefined;
  if (u.includes('#'))
    return 'Use the new Discord username (without # and numbers), for example maya.k.';
  if (!/^[a-z0-9_.]{2,32}$/.test(u))
    return 'A Discord username has 2 to 32 lowercase letters, numbers, dots or underscores, for example maya.k.';
  return undefined;
}
