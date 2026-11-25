import { useState } from 'react';
import { toast } from 'sonner';
import { useAuth } from '@/lib/auth';
import { rpc } from '@/lib/rpc';
import { usernameProblem } from '@/lib/discord';
import { Button, ErrorText, Field, Input, Modal } from '@/components/ui';
import { useBetaLock } from '@/lib/data';
import { BETA_LOCK_NOTE } from '@/lib/betaLock';

/** Asked once after the first sign in: the Discord username is how alerts tag this person. */
export function DiscordPrompt() {
  const { account, refreshAccount } = useAuth();
  const locked = useBetaLock();
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

  // Decision 347: during the beta an admin adds Discord accounts, so there is nothing to type here.
  if (locked)
    return (
      <Modal
        open
        stayOpen
        onOpenChange={(o) => !o && void save(true)}
        title={`Welcome, ${account.member?.name.split(' ')[0] ?? ''}`}
        description="Team alerts reach you by email. To be tagged on Discord too, ask an admin to add your Discord username on Setup, Team."
      >
        <p className="mb-3 text-sm text-muted-foreground">{BETA_LOCK_NOTE}</p>
        <ErrorText error={err} />
        <div className="mt-4 flex justify-end">
          <Button loading={busy} onClick={() => void save(true)}>
            OK
          </Button>
        </div>
      </Modal>
    );

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
