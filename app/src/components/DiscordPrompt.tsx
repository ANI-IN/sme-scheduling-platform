import { useState } from 'react';
import { toast } from 'sonner';
import { useAuth } from '@/lib/auth';
import { rpc } from '@/lib/rpc';
import { usernameProblem } from '@/lib/discord';
import { Button, ErrorText, Field, Input, Modal } from '@/components/ui';

/** Asked once after the first sign in: the Discord username is how alerts tag this person. */
export function DiscordPrompt() {
  const { account, refreshAccount } = useAuth();
  const [name, setName] = useState('');
  const [touched, setTouched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  if (!account?.needs_discord) return null;
  const problem = name.trim() === '' ? 'Type your Discord username.' : usernameProblem(name);

  const save = async (dismiss: boolean) => {
    setTouched(true);
    if (!dismiss && problem) return;
    setBusy(true);
    setErr(null);
    try {
      await rpc('update_my_profile', {
        p_discord_username: dismiss ? undefined : name.trim(),
        p_dismiss_discord_prompt: dismiss,
      });
      if (!dismiss) toast.success('Saved. The app is finding your Discord account.');
      await refreshAccount();
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      open
      stayOpen
      onOpenChange={(o) => !o && void save(true)}
      title={`Welcome, ${account.member?.name.split(' ')[0] ?? ''}`}
      description="Add your Discord username so team alerts can tag you and send you direct messages. You only do this once. Without it you get email."
    >
      <p className="mb-3 text-sm text-muted-foreground">
        Your username is under your name in Discord (click your picture at the bottom left), for
        example maya.k.
      </p>
      <Field label="Your Discord username" error={touched ? problem : undefined}>
        <Input
          value={name}
          autoComplete="off"
          onBlur={() => setTouched(true)}
          onChange={(e) => setName(e.target.value)}
        />
      </Field>
      <ErrorText error={err} />
      <div className="mt-4 flex justify-end gap-2">
        <Button variant="ghost" disabled={busy} onClick={() => void save(true)}>
          Later
        </Button>
        <Button loading={busy} onClick={() => void save(false)}>
          Save
        </Button>
      </div>
    </Modal>
  );
}
