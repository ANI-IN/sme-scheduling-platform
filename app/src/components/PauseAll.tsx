import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { toast } from 'sonner';
import { poke, rpc } from '@/lib/rpc';
import { useSystem } from '@/lib/data';
import { fmtLocal } from '@/lib/time';
import { useConfirm } from '@/components/Confirm';
import { Badge, Button, ErrorText, Section } from '@/components/ui';

/** Pause or resume every message to instructors, with a confirmation. Used everywhere it appears. */
export function usePauseAll() {
  const { data } = useSystem();
  const qc = useQueryClient();
  const confirm = useConfirm();
  const [err, setErr] = useState<unknown>(null);
  const on = data?.state.outreach_enabled ?? true;
  const toggle = async () => {
    const ok = await confirm({
      title: on ? 'Pause all messages to instructors?' : 'Turn messages back on?',
      body: on
        ? 'No instructor will be messaged in any domain until you turn messages back on. Requests stop moving on. Team alerts continue.'
        : 'Messages to instructors start again at the next automatic check. Nothing waiting is lost.',
      danger: on,
      confirmLabel: on ? 'Pause all messages' : 'Turn messages back on',
    });
    if (!ok) return;
    setErr(null);
    try {
      await rpc('set_kill_switch', { p_outreach_enabled: !on });
      await poke();
      toast.success(on ? 'All messages are paused' : 'Messages are on again');
      await qc.invalidateQueries();
    } catch (e) {
      setErr(e);
      toast.error('Could not change it. Please try again.');
    }
  };
  return { on, loaded: !!data, toggle, err, pausedSince: data?.state.kill_switch_changed_at };
}

export function PauseAllSection() {
  const p = usePauseAll();
  if (!p.loaded) return null;
  return (
    <Section
      tone="danger"
      title="Pause all messages"
      description="Stops every message to instructors in every domain, for example during an incident. Team alerts continue."
      actions={
        <Badge tone={p.on ? 'success' : 'danger'}>
          {p.on ? 'Messages are on' : 'Messages are paused'}
        </Badge>
      }
    >
      {!p.on && (
        <p className="mb-3 text-sm text-muted-foreground">
          Paused since {fmtLocal(p.pausedSince)}. Nothing is lost: waiting messages go out when you
          turn messages back on.
        </p>
      )}
      <Button variant={p.on ? 'destructive' : 'primary'} onClick={() => void p.toggle()}>
        {p.on ? 'Pause all messages' : 'Turn messages back on'}
      </Button>
      <ErrorText error={p.err} />
    </Section>
  );
}
