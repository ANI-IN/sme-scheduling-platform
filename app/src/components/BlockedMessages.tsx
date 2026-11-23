import { useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { toast } from 'sonner';
import { blockedReasons, type MessageLite } from '../lib/blocked';
import { messageTitle } from '../lib/plain';
import { rpc } from '../lib/rpc';
import { Button, ErrorText, Notice } from './ui';

/**
 * Messages a beta rule stopped, said plainly where Ops works (decision 329): who did not get what, why, and what to
 * do. Send again tries every listed message once more (it goes out if the rule now allows it).
 */
export function BlockedMessages({ messages }: { messages: readonly MessageLite[] }) {
  const qc = useQueryClient();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  if (messages.length === 0) return null;
  const list = messages.slice(0, 6);
  async function again() {
    setBusy(true);
    setErr(null);
    try {
      for (const m of list) await rpc('resend_message', { p_message_id: m.id });
      toast.success('Sent again. If a rule still stops it, it shows here with the reason.');
      void qc.invalidateQueries({ queryKey: ['message'] });
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  }
  return (
    <Notice tone="warning">
      <p className="font-medium">
        {list.length === 1 ? 'A message was not sent' : `${list.length} messages were not sent`}
      </p>
      <ul className="list-disc space-y-1 pl-5">
        {list.map((m) => (
          <li key={m.id}>
            {messageTitle(m.template_id)} to {m.recipient_label ?? 'this person'} by {m.channel}
          </li>
        ))}
      </ul>
      {blockedReasons(list).map((r) => (
        <p key={r} className="mt-2">
          {r}
        </p>
      ))}
      <ErrorText error={err} />
      <Button
        size="sm"
        variant="outline"
        className="mt-2"
        disabled={busy}
        onClick={() => void again()}
      >
        Send again
      </Button>
    </Notice>
  );
}
