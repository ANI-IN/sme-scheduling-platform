// Values come from Vite env (VITE_*). See app/.env.example.
export const env = {
  supabaseUrl: import.meta.env.VITE_SUPABASE_URL as string | undefined,
  supabaseKey: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined,
  companyDomain: (
    (import.meta.env.VITE_COMPANY_EMAIL_DOMAIN as string | undefined) ?? ''
  ).toLowerCase(),
  pokeUrl: import.meta.env.VITE_N8N_POKE_URL as string | undefined,
  pokeKey: import.meta.env.VITE_N8N_POKE_KEY as string | undefined,
  devLogin: import.meta.env.VITE_ENABLE_DEV_LOGIN === 'true',
};

export const configMissing = !env.supabaseUrl || !env.supabaseKey;
