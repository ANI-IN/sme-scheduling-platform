export const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
export const DISCORD_ID_RE = /^\d{17,20}$/;

export function isEmail(v: string): boolean {
  return EMAIL_RE.test(v.trim());
}

export function isDiscordId(v: string): boolean {
  return DISCORD_ID_RE.test(v.trim());
}

/** Extract server and channel IDs from https://discord.com/channels/<server>/<channel>. */
export function parseChannelLink(link: string): { serverId: string; channelId: string } | null {
  const m = link
    .trim()
    .match(
      /^https:\/\/(?:www\.|ptb\.|canary\.)?discord(?:app)?\.com\/channels\/(\d{17,20})\/(\d{17,20})\/?$/,
    );
  return m ? { serverId: m[1]!, channelId: m[2]! } : null;
}

export function isCompanyEmail(email: string | null | undefined, domain: string): boolean {
  if (!email || !domain) return false;
  return email.toLowerCase().split('@')[1] === domain.toLowerCase();
}
