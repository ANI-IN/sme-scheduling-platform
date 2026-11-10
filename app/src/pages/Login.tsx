import { useState } from 'react';
import { useAuth } from '@/lib/auth';
import { env } from '@/lib/env';
import { Button, Card, Input } from '@/components/ui';
import { ThemeSwitch } from '@/components/ThemeSwitch';

export function Login() {
  const { signInWithGoogle, signInDev, rejected } = useAuth();
  const [email, setEmail] = useState('');
  const [note, setNote] = useState('');
  return (
    <div className="relative flex min-h-screen items-center justify-center bg-background p-4">
      <ThemeSwitch className="absolute top-4 right-4" />
      <Card className="w-full max-w-sm p-6">
        <h1 className="text-xl font-semibold">SME Scheduling</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Sign in with your company Google account{env.companyDomain && ` (@${env.companyDomain})`}.
        </p>
        {rejected && (
          <p className="mt-3 rounded bg-danger-soft p-2 text-sm text-danger-strong">{rejected}</p>
        )}
        <Button className="mt-4 w-full" onClick={() => void signInWithGoogle()}>
          Sign in with Google
        </Button>
        {env.devLogin && (
          <div className="mt-6 border-t pt-4">
            <p className="mb-2 text-xs text-muted-foreground">
              Local development only: email me a link to sign in.
            </p>
            <div className="flex gap-2">
              <Input
                placeholder={`you@${env.companyDomain || 'company.com'}`}
                value={email}
                onChange={(e) => setEmail(e.target.value)}
              />
              <Button variant="outline" onClick={async () => setNote(await signInDev(email))}>
                Send
              </Button>
            </div>
            {note && <p className="mt-2 text-xs text-muted-foreground">{note}</p>}
          </div>
        )}
      </Card>
    </div>
  );
}
