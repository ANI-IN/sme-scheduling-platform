import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';
import type { AuthChangeEvent, Session } from '@supabase/supabase-js';
import { supabase } from './supabase';
import { env } from './env';

/** The signed in person, as the database sees them (created on first sign in). */
export type Account = {
  allowed: boolean;
  message?: string;
  member?: {
    id: string;
    name: string;
    email: string;
    discord_user_id: string | null;
    job_title: string | null;
    is_placeholder: boolean;
  };
  needs_discord?: boolean;
  environment?: 'Development' | 'Sandbox' | 'Production';
};

type AuthState = {
  session: Session | null;
  account: Account | null;
  loading: boolean;
  rejected: string | null;
  signInWithGoogle: () => Promise<void>;
  signOut: () => Promise<void>;
  refreshAccount: () => Promise<void>;
};

const AuthCtx = createContext<AuthState | null>(null);
const LAST_SIGN_IN_KEY = 'ik-last-sign-in';

/** True once per real sign in (not on every page load), so Activity history gets one entry. */
function isNewSignIn(event: AuthChangeEvent, s: Session): boolean {
  if (event !== 'SIGNED_IN' && event !== 'INITIAL_SESSION') return false;
  const marker = `${s.user.id}:${s.user.last_sign_in_at ?? ''}`;
  try {
    if (localStorage.getItem(LAST_SIGN_IN_KEY) === marker) return false;
    localStorage.setItem(LAST_SIGN_IN_KEY, marker);
  } catch {
    return event === 'SIGNED_IN';
  }
  return true;
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [account, setAccount] = useState<Account | null>(null);
  const [loading, setLoading] = useState(true);
  const [rejected, setRejected] = useState<string | null>(() => {
    // Supabase returns the sign in hook's refusal in the address after the Google redirect.
    const params = new URLSearchParams(window.location.hash.slice(1) || window.location.search);
    return params.get('error_description');
  });

  const loadAccount = useCallback(async (signedIn: boolean) => {
    const { data, error } = await supabase.rpc('my_account', { p_signed_in: signedIn });
    if (error) throw error;
    return data as unknown as Account;
  }, []);

  useEffect(() => {
    let alive = true;
    const accept = async (event: AuthChangeEvent, s: Session | null) => {
      if (!s) {
        setSession(null);
        setAccount(null);
        setLoading(false);
        return;
      }
      try {
        const a = await loadAccount(isNewSignIn(event, s));
        if (!alive) return;
        if (!a.allowed) {
          await supabase.auth.signOut();
          setRejected(a.message ?? 'Only company Google accounts can use SME Scheduling.');
          setSession(null);
          setAccount(null);
        } else {
          setSession(s);
          setAccount(a);
        }
      } catch {
        if (!alive) return;
        setSession(s);
        setAccount(null);
      }
      setLoading(false);
    };
    const { data } = supabase.auth.onAuthStateChange((event, s) => {
      // Never await Supabase calls inside this callback (it holds the auth lock).
      setTimeout(() => void accept(event, s), 0);
    });
    return () => {
      alive = false;
      data.subscription.unsubscribe();
    };
  }, [loadAccount]);

  const value: AuthState = {
    session,
    account,
    loading,
    rejected,
    async signInWithGoogle() {
      setRejected(null);
      await supabase.auth.signInWithOAuth({
        provider: 'google',
        options: {
          redirectTo: window.location.origin,
          queryParams: {
            prompt: 'select_account',
            ...(env.allowedDomain ? { hd: env.allowedDomain } : {}),
          },
        },
      });
    },
    async signOut() {
      await supabase.auth.signOut();
    },
    async refreshAccount() {
      setAccount(await loadAccount(false));
    },
  };
  return <AuthCtx.Provider value={value}>{children}</AuthCtx.Provider>;
}

export function useAuth(): AuthState {
  const v = useContext(AuthCtx);
  if (!v) throw new Error('useAuth outside AuthProvider');
  return v;
}
