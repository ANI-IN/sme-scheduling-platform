-- =====================================================================================
-- Milestone 6: serve confirm pages as real HTML through PostgREST.
-- PostgREST picks the response media type from the function's return type; a domain named
-- "text/html" makes POST /rest/v1/rpc/response_page answer with Content-Type text/html
-- (request it with Accept: text/html). n8n WF2 passes the body straight through.
-- =====================================================================================
create domain public."text/html" as text;

alter function public.response_page(text) rename to response_page_text;
alter function public.submit_response_page(text, jsonb) rename to submit_response_page_text;

create or replace function public.response_page(p_token text)
returns public."text/html" language sql security definer set search_path = ''
as $$ select public.response_page_text(p_token)::public."text/html"; $$;

create or replace function public.submit_response_page(p_token text, p_form jsonb default '{}')
returns public."text/html" language sql security definer set search_path = ''
as $$ select public.submit_response_page_text(p_token, p_form)::public."text/html"; $$;

revoke execute on function public.response_page_text(text) from authenticated, anon, public;
revoke execute on function public.submit_response_page_text(text, jsonb) from authenticated, anon, public;
grant execute on function public.response_page(text) to service_role;
grant execute on function public.submit_response_page(text, jsonb) to service_role;
