import { createClient } from '@supabase/supabase-js';
import type { Database } from './database.types';
import { env } from './env';

export const supabase = createClient<Database>(
  env.supabaseUrl ?? 'http://localhost:55421',
  env.supabaseKey ?? 'missing-key',
  { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } },
);

export type Tables<T extends keyof Database['public']['Tables']> =
  Database['public']['Tables'][T]['Row'];
