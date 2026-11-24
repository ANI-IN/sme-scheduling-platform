import { rpc } from '@/lib/rpc';
import { Button } from './ui';

type Run = (fn: () => Promise<unknown>, ok?: string) => Promise<unknown>;

/**
 * The two answers to "Check needed" (decision 341): the automation took the message but never said whether it was
 * sent, so it is never sent again by itself. Someone looks, then chooses one of these.
 */
export function MessageCheckActions({ messageId, run }: { messageId: string; run: Run }) {
  return (
    <div className="flex flex-wrap items-center gap-1">
      <Button
        size="sm"
        onClick={() =>
          run(
            () => rpc('resolve_message_check', { p_message_id: messageId, p_arrived: true }),
            'Marked as sent',
          )
        }
      >
        It arrived, mark as sent
      </Button>
      <Button
        size="sm"
        variant="secondary"
        onClick={() =>
          run(
            () => rpc('resolve_message_check', { p_message_id: messageId, p_arrived: false }),
            'Sent again',
          )
        }
      >
        Send again
      </Button>
    </div>
  );
}
