import { lazy, Suspense } from 'react';
import { useAuth } from '@/lib/auth';
import { Button, Card } from '@/components/ui';
import { ThemeSwitch } from '@/components/ThemeSwitch';

// Not part of production builds: Vite replaces import.meta.env.DEV with `false` there, so this
// branch and the DevSignIn chunk are removed (checked by `npm run check-build -w scripts`).
const DevSignIn =
  import.meta.env.DEV && import.meta.env.VITE_ENABLE_DEV_LOGIN === 'true'
    ? lazy(() => import('./DevSignIn'))
    : null;

export function Login() {
  const { signInWithGoogle, rejected } = useAuth();
  return (
    <div className="relative flex min-h-screen items-center justify-center bg-background p-4">
      <ThemeSwitch className="absolute top-4 right-4" />
      <Card className="w-full max-w-sm p-6">
        <h1 className="text-xl font-semibold">SME Scheduling</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Sign in with your company Google account.
        </p>
        {rejected && (
          <p role="alert" className="mt-3 rounded bg-danger-soft p-2 text-sm text-danger-strong">
            {rejected}
          </p>
        )}
        <Button className="mt-4 w-full" onClick={() => void signInWithGoogle()}>
          Sign in with Google
        </Button>
        {DevSignIn && (
          <Suspense fallback={null}>
            <DevSignIn />
          </Suspense>
        )}
      </Card>
    </div>
  );
}
