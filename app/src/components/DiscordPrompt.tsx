import { useState } from 'react';
import { toast } from 'sonner';
import { useAuth } from '@/lib/auth';
import { rpc } from '@/lib/rpc';
import { isDiscordId } from '@/lib/validation';
import { Button, ErrorText, Field, Input, Modal } from '@/components/ui';

/** Asked once after the first sign in: the Discord user ID is how alerts tag this person. */
export function DiscordPrompt() {
  const { account, refreshAccount } = useAuth();
  const [id, setId] = useState('');
  const [touched, setTouched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  if (!account?.needs_discord) return null;
  const invalid = id.trim() !== '' && !isDiscordId(id);

  const save = async (dismiss: boolean) => {
    setTouched(true);
    if (!dismiss && (id.trim() === '' || invalid)) return;
    setBusy(true);
    setErr(null);
    try {
      await rpc('update_my_profile', {
        p_discord_user_id: dismiss ? undefined : id.trim(),
        p_dismiss_discord_prompt: dismiss,
      });
      if (!dismiss) toast.success('Discord user ID saved');
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
      description="Add your Discord user ID so the team alerts can tag you. You only do this once."
    >
      <ol className="mb-4 list-decimal space-y-1 pl-5 text-sm">
        <li>In Discord, open User Settings (the gear next to your name).</li>
        <li>Choose Advanced and turn on Developer Mode.</li>
        <li>Right click your name in any server and choose Copy User ID.</li>
        <li>Paste it below.</li>
      </ol>
      <Field
        label="Your Discord user ID"
        hint="17 to 20 digits."
        error={
          touched && (id.trim() === '' || invalid)
            ? 'Paste a Discord user ID of 17 to 20 digits.'
            : undefined
        }
      >
        <Input
          inputMode="numeric"
          value={id}
          onBlur={() => setTouched(true)}
          onChange={(e) => setId(e.target.value)}
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
