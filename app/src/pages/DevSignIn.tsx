// DEVELOPMENT ONLY. Loaded only from development builds with VITE_ENABLE_DEV_LOGIN=true; a production
// build never contains it. The database also refuses email link accounts outside Development.
import { useState } from 'react';
import { supabase } from '@/lib/supabase';
import { Button, Input } from '@/components/ui';

export default function DevSignIn() {
  const [email, setEmail] = useState('');
  const [note, setNote] = useState('');
  return (
    <div className="mt-6 border-t border-border pt-4">
      <p className="mb-2 text-xs text-muted-foreground">
        Local development only: email me a link to sign in.
      </p>
      <div className="flex gap-2">
        <Input
          aria-label="Email for the development sign in link"
          placeholder="Your company email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />
        <Button
          variant="secondary"
          onClick={async () => {
            const { error } = await supabase.auth.signInWithOtp({
              email,
              options: { emailRedirectTo: window.location.origin },
            });
            setNote(
              error
                ? error.message
                : 'Check the local mail catcher (Mailpit) for the link to sign in.',
            );
          }}
        >
          Send
        </Button>
      </div>
      {note && <p className="mt-2 text-xs text-muted-foreground">{note}</p>}
    </div>
  );
}
