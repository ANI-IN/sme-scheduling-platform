// Values come from Vite env (VITE_*). See app/.env.example.
export const env = {
  supabaseUrl: import.meta.env.VITE_SUPABASE_URL as string | undefined,
  supabaseKey: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined,
  /** Only used to preselect the company account on Google's screen; the database decides access. */
  allowedDomain: (
    (import.meta.env.VITE_ALLOWED_EMAIL_DOMAIN as string | undefined) ??
    (import.meta.env.VITE_COMPANY_EMAIL_DOMAIN as string | undefined) ??
    ''
  ).toLowerCase(),
  pokeUrl: import.meta.env.VITE_N8N_POKE_URL as string | undefined,
  pokeKey: import.meta.env.VITE_N8N_POKE_KEY as string | undefined,
};

export const configMissing = !env.supabaseUrl || !env.supabaseKey;
