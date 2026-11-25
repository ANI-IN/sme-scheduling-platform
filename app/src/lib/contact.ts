// Review finding R37 (decision 349): say what was really queued, not "by Discord and email" every time.
export type ContactCopy = {
  channel: string;
  status: string;
  blocked: boolean | null;
  last_error: string | null;
};

const word = (c: string) => (c === 'Email' ? 'email' : c);
const list = (xs: string[]) => xs.join(' and ');

export function contactResult(name: string, copies: ContactCopy[]): { ok: boolean; text: string } {
  if (!copies.length)
    return {
      ok: false,
      text: `Nothing was sent to ${name}: there is no Discord channel or email to send to.`,
    };
  const stopped = copies.filter((c) => c.status === 'Cancelled' || c.blocked);
  // Discord first, as the page says it.
  const going = copies
    .filter((c) => !stopped.includes(c))
    .sort((a, b) => a.channel.localeCompare(b.channel));
  const parts = [
    going.length
      ? `Message sent to ${name} by ${list(going.map((c) => word(c.channel)))}.`
      : `Nothing was sent to ${name}.`,
    ...stopped.map((c) => `The ${word(c.channel)} copy was not sent. ${c.last_error ?? ''}`.trim()),
  ];
  return { ok: stopped.length === 0, text: parts.join(' ') };
}
