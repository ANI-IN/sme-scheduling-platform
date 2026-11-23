// An instructor's Discord channel (decision 330): read what someone pasted, and suggest the channel that looks like
// the person's own. The database checks the choice again before it is saved.

/** The channel ID in a channel link (Copy Link in Discord), in <#id>, or the ID itself; null otherwise. */
export function parseChannelInput(text: string): string | null {
  const t = text.trim();
  const link = /discord(?:app)?\.com\/channels\/(?:\d{17,20}|@me)\/(\d{17,20})/.exec(t);
  if (link) return link[1]!;
  const mention = /^<#(\d{17,20})>$/.exec(t);
  if (mention) return mention[1]!;
  return /^\d{17,20}$/.test(t) ? t : null;
}

/** Lowercase letters and digits only: "Victor Palmer" and "#victor-palmer" both become "victorpalmer". */
const squash = (s: string) =>
  s
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]/g, '');

/** The names a person's own channel is usually called by: their username, first name, and full name. */
export function channelNamesFor(person: { fullName: string; username?: string | null }): string[] {
  const words = person.fullName.split(/\s+/).filter(Boolean);
  const names = [
    person.username ?? '',
    words.join(''),
    words[0] ?? '',
    words.length > 1 ? words[0]! + words[words.length - 1]! : '',
  ];
  return [...new Set(names.map(squash).filter((n) => n.length >= 3))];
}

export type ChannelLite = {
  id: string;
  name: string;
  server_id: string;
  bot_can_post?: boolean | null;
};

/**
 * The channel in the domain's server whose name matches the person, best match first: the full name or username
 * exactly, then the first name exactly. Only a single clear match is suggested; channels the bot cannot post in
 * are left out.
 */
export function suggestChannel<T extends ChannelLite>(
  channels: readonly T[],
  person: { fullName: string; username?: string | null },
  serverId: string | null | undefined,
  taken: ReadonlySet<string> = new Set(),
): T | undefined {
  if (!serverId) return undefined;
  const names = channelNamesFor(person);
  const first = squash(person.fullName.split(/\s+/)[0] ?? '');
  const pool = channels.filter(
    (c) => c.server_id === serverId && c.bot_can_post !== false && !taken.has(c.id),
  );
  const strong = pool.filter((c) => names.includes(squash(c.name)) && squash(c.name) !== first);
  if (strong.length === 1) return strong[0];
  if (strong.length > 1) return undefined;
  const weak = pool.filter((c) => squash(c.name) === first);
  return weak.length === 1 ? weak[0] : undefined;
}
