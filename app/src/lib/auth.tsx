import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from './supabase';
import { env } from './env';
import { isCompanyEmail } from './validation';

type AuthState = {
  session: Session | null;
  loading: boolean;
  rejected: string | null;
  signInWithGoogle: () => Promise<void>;
  signInDev: (email: string) => Promise<string>;
  signOut: () => Promise<void>;
};

const AuthCtx = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [rejected, setRejected] = useState<string | null>(() => {
    // Supabase returns the auth hook's rejection in the URL after the Google redirect.
    const params = new URLSearchParams(window.location.hash.slice(1) || window.location.search);
    return params.get('error_description');
  });

  useEffect(() => {
    const accept = async (s: Session | null) => {
      if (s && !isCompanyEmail(s.user.email, env.companyDomain)) {
        // Second line of defence (the database also rejects non-company accounts).
        await supabase.auth.signOut();
        setRejected(`Only company Google accounts (@${env.companyDomain}) can use SME Scheduling.`);
        setSession(null);
      } else {
        setSession(s);
      }
      setLoading(false);
    };
    supabase.auth.getSession().then(({ data }) => accept(data.session));
    const { data } = supabase.auth.onAuthStateChange((_e, s) => {
      void accept(s);
    });
    return () => data.subscription.unsubscribe();
  }, []);

  const value: AuthState = {
    session,
    loading,
    rejected,
    async signInWithGoogle() {
      setRejected(null);
      await supabase.auth.signInWithOAuth({
        provider: 'google',
        options: {
          redirectTo: window.location.origin,
          queryParams: { hd: env.companyDomain, prompt: 'select_account' },
        },
      });
    },
    async signInDev(email: string) {
      const { error } = await supabase.auth.signInWithOtp({
        email,
        options: { emailRedirectTo: window.location.origin },
      });
      return error ? error.message : 'Check the local mail catcher (Mailpit) for the sign-in link.';
    },
    async signOut() {
      await supabase.auth.signOut();
    },
  };
  return <AuthCtx.Provider value={value}>{children}</AuthCtx.Provider>;
}

export function useAuth(): AuthState {
  const v = useContext(AuthCtx);
  if (!v) throw new Error('useAuth outside AuthProvider');
  return v;
}
