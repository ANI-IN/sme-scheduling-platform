// Settings, Connections: the status of Discord and email (Release 3, A7, decision 310).
export type Status = 'working' | 'ready' | 'off' | 'problem';

/**
 * Discord or email: Working after a message went out, Problem only when the last attempt failed after the last
 * success, Ready when it is set up and nothing was sent yet (Release 3, A7, decision 310).
 */
export function channelStatus(
  ready: boolean,
  lastSent: string | null,
  lastFailed: string | null,
): Status {
  if (lastFailed && (!lastSent || new Date(lastFailed) > new Date(lastSent))) return 'problem';
  if (lastSent) return 'working';
  return ready ? 'ready' : 'off';
}

/** What to do about the last failure, in plain words. */
export function fixFor(channel: 'Discord' | 'Email', error: string | null): string {
  const e = (error ?? '').toLowerCase();
  if (channel === 'Discord') {
    if (/unknown channel|10003/.test(e))
      return 'The channel was deleted. Choose another channel for that domain or instructor.';
    if (/missing (access|permissions)|50001|50013/.test(e))
      return 'The bot is not allowed to post there. Give it View channel and Send messages in that channel, or choose another channel.';
    if (/cannot send messages to this user|50007/.test(e))
      return 'That person does not accept direct messages from the bot. Ask them to allow direct messages from server members, or give them a channel.';
    return 'Open Activity history to see which message failed, fix what it says, then press Send a test.';
  }
  if (/invalid|address|recipient|550|553/.test(e))
    return 'The email address looks wrong. Check it on the person, then press Send a test.';
  return 'Check the Gmail connection in the automation service, then press Send a test.';
}
