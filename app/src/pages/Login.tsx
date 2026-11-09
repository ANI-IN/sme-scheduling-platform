import { useState } from 'react';
import { useAuth } from '@/lib/auth';
import { env } from '@/lib/env';
import { Button, Card, Input } from '@/components/ui';

export function Login() {
  const { signInWithGoogle, signInDev, rejected } = useAuth();
  const [email, setEmail] = useState('');
  const [note, setNote] = useState('');
  return (
    <div className="flex min-h-screen items-center justify-center bg-slate-50 p-4">
      <Card className="w-full max-w-sm p-6">
        <h1 className="text-xl font-semibold">SME Scheduling</h1>
        <p className="mt-1 text-sm text-slate-600">
          Sign in with your company Google account{env.companyDomain && ` (@${env.companyDomain})`}.
        </p>
        {rejected && <p className="mt-3 rounded bg-red-50 p-2 text-sm text-red-700">{rejected}</p>}
        <Button className="mt-4 w-full" onClick={() => void signInWithGoogle()}>
          Sign in with Google
        </Button>
        {env.devLogin && (
          <div className="mt-6 border-t pt-4">
            <p className="mb-2 text-xs text-slate-500">
              Local development only: email sign-in link.
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
            {note && <p className="mt-2 text-xs text-slate-600">{note}</p>}
          </div>
        )}
      </Card>
    </div>
  );
}
