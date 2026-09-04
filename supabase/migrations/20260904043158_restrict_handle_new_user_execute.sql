-- Postgres grants EXECUTE on new functions to PUBLIC by default, which left
-- public.handle_new_user() callable by the anon and authenticated roles through
-- PostgREST at /rest/v1/rpc/handle_new_user. Flagged by the Supabase security
-- linter (lints 0028 and 0029).
--
-- A direct call would error ("trigger functions can only be called as
-- triggers") rather than do damage, but the function is SECURITY DEFINER and
-- has no business being reachable from the API at all.
--
-- Revoking EXECUTE does not affect the trigger: permission to execute a trigger
-- function is checked when the trigger is created, not each time it fires.

revoke execute on function public.handle_new_user() from public;
revoke execute on function public.handle_new_user() from anon;
revoke execute on function public.handle_new_user() from authenticated;
