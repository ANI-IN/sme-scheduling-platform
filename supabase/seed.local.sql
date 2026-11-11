-- Your own computer only (supabase db reset runs it after seed.sql, see supabase/config.toml).
-- Never paste this into a hosted project: it switches the database to Development, which turns off the
-- Google Workspace check, and points every link at localhost. Hosted projects use `npm run configure`.
update public.app_config
   set company_email_domain = 'example.com',
       environment = 'Development',
       environment_set_at = now(),
       app_base_url = 'http://localhost:5173',
       response_base_url = 'http://localhost:5678/webhook/respond'
 where id = 1;
