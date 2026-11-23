// Messages a beta rule stopped (decision 329). A message counts as still blocked until a later message of the same
// kind to the same person about the same class week was queued or went out (Send again, or a new request).
export type MessageLite = {
  id: string;
  created_at: string;
  status: string;
  blocked: boolean;
  direction: string;
  template_id: string;
  channel: string;
  instructor_id: string | null;
  team_member_id?: string | null;
  module_week_id: string | null;
  recipient_label: string | null;
  last_error: string | null;
};

const key = (m: MessageLite) =>
  [
    m.instructor_id ?? m.team_member_id ?? m.recipient_label ?? '',
    m.module_week_id ?? '',
    m.template_id,
    m.channel,
  ].join('|');

/** The blocked messages that nothing later replaced, newest first. */
export function currentBlocked<T extends MessageLite>(messages: readonly T[]): T[] {
  const latest = new Map<string, T>();
  for (const m of messages) {
    if (m.direction !== 'Outbound') continue;
    const k = key(m);
    const seen = latest.get(k);
    if (!seen || m.created_at > seen.created_at) latest.set(k, m);
  }
  return [...latest.values()]
    .filter((m) => m.blocked && m.status === 'Cancelled')
    .sort((a, b) => (a.created_at < b.created_at ? 1 : -1));
}

/** The reasons, each once (several messages usually share one). */
export function blockedReasons(messages: readonly MessageLite[]): string[] {
  return [...new Set(messages.map((m) => m.last_error ?? 'Not sent.'))];
}
