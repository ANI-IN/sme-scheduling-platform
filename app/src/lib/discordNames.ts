// Discord tags in message text ("<@1200000000000000008>") are shown as names ("@Andrew Keane"), never as codes.
const names = new Map<string, string>();

export function clearDiscordNames() {
  names.clear();
}

/** Remember who each Discord account is. Team members win over instructors who share an account. */
export function setDiscordNames(
  entries: Array<[string | null | undefined, string | null | undefined]>,
) {
  for (const [id, name] of entries) if (id && name && !names.has(id)) names.set(id, name);
}

/** "<@123>" and "<@!123>" become "@Name" ("@someone on Discord" when the account is not known). */
export function discordNames(text: string | null | undefined): string {
  if (!text) return '';
  return text.replace(
    /<@!?(\d{5,25})>/g,
    (_, id: string) => `@${names.get(id) ?? 'someone on Discord'}`,
  );
}
