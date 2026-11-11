-- Runs on `supabase db reset` (your own computer and the test stack). The app starts empty
-- (decision 251): every domain, module, instructor and team member is added in the app.
-- The company domain, the environment and the two links are set by `npm run configure` on a hosted
-- project, and by supabase/seed.local.sql on your own computer (never pasted into a hosted project).
update public.app_config set scheduling_sender_name = 'SME Scheduling' where id = 1;
