-- username_available(text): can this username still be claimed?
--
-- The sign-up form asks before creating the auth user, so a taken name is
-- reported as exactly that — before a request that would otherwise fail
-- inside the sign-up trigger and come back as GoTrue's sanitised "Database
-- error saving new user", wording that says nothing about why.
--
-- The person asking has no session yet, so the call arrives as `anon`, and
-- profiles is readable only by `authenticated`. Hence SECURITY DEFINER: the
-- function reads on the definer's behalf and returns exactly one bit. It
-- applies the same normalisation the trigger does (lower, trim), so "Alice"
-- and "alice " both ask about "alice".
--
-- Exposing a function to anon is what the security linter flags (0028/0029)
-- and what an earlier migration revoked for handle_new_user; here it is the
-- point. Whether a given username exists is learnable through sign-up anyway,
-- and this cannot be used to learn anything else about the table.
--
-- The answer is advisory. Two people can both be told a name is free and one
-- of them then loses the race in the trigger; the app words that outcome as a
-- possibly-taken username rather than asserting it.
create function public.username_available(candidate text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select not exists (
        select 1
        from public.profiles
        where username = lower(trim(candidate))
    );
$$;

-- Postgres grants EXECUTE to public by default; say exactly who may call.
revoke execute on function public.username_available(text) from public;
grant execute on function public.username_available(text) to anon, authenticated;
