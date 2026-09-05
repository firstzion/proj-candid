-- Changeable usernames, with a memory (SOL-41).
--
-- posts.user_id references profiles.id, so a rename breaks nothing in the
-- data model; what it breaks is whatever a person copied or remembered — a
-- handle in a text message, a name they meant to look up. Three rules and
-- one lookup keep that from becoming a broken link or an impersonation:
--
--   * One change per 30 days. Keeps history small and handles recognisable.
--   * A released name is reserved from everyone else for 90 days — the
--     anti-impersonation measure. Reserved for a while rather than for ever,
--     because permanent reservation turns every abandoned account into a
--     squatted name; your own old names are always yours to take back.
--   * Both rules live in a BEFORE trigger on profiles, so sign-up obeys them
--     too, and username_available() knows them, so the form can say so
--     before the request — a refusal inside the trigger only reaches the app
--     as a constraint error, or, at sign-up, as GoTrue's sanitised one.
--   * resolve_username() answers an exact current-or-former handle with the
--     current profile, under the same blocked-by rule the profiles policy
--     applies, so an old handle finds the person instead of nobody.
--
-- Decided here, as the ticket asked: the feed shows the *current* username
-- (it joins profiles, so posts follow the person, not the string), and
-- search (SOL-39) matches current names only, with the exact-handle fallback
-- covering "I remember her old name". History is readable by its owner alone
-- and never leaves the database as such. The trade-off, named in the README:
-- a rename does not hide you from someone who knew the old handle — blocking
-- is the tool for that.

create table public.username_history (
    profile_id uuid not null references public.profiles (id) on delete cascade,
    username   text not null,
    changed_at timestamptz not null default now(),
    primary key (profile_id, changed_at)
);

-- The cooldown looks a name up; the primary key serves "my history".
create index username_history_username_idx on public.username_history (username);

alter table public.username_history enable row level security;

-- Your own, and nothing else: no policy for anyone else's rows, and no
-- client writes at all — the trigger below records changes as owner.
create policy "users can see their own username history"
    on public.username_history
    for select
    to authenticated
    using (profile_id = (select auth.uid()));


-- ---------------------------------------------------------------------------
-- The two rules, enforced where every write passes
-- ---------------------------------------------------------------------------
-- BEFORE INSERT OR UPDATE OF username, so sign-up (an insert through
-- handle_new_user) and a rename (an update through the profiles policy) are
-- judged by the same code. Definer, because the cooldown has to read other
-- people's history rows and the read policy above hides them.
--
-- The rate-limit refusal carries the date the next change is allowed, in
-- ISO form, so the app can say "again on 4 October" rather than "not yet".
-- The cooldown refusal is raised as unique_violation on purpose: to the app
-- it is a taken name — which, for 90 days, it is.
create function public.enforce_username_rules()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_last timestamptz;
begin
    if tg_op = 'UPDATE' and new.username = old.username then
        return new;
    end if;

    if tg_op = 'UPDATE' then
        select max(changed_at) into v_last
        from public.username_history
        where profile_id = new.id;
        if v_last is not null and v_last > now() - interval '30 days' then
            raise exception 'username can be changed again on %',
                to_char(v_last + interval '30 days', 'YYYY-MM-DD')
                using errcode = 'check_violation';
        end if;
    end if;

    if exists (
        select 1
        from public.username_history h
        where h.username = new.username
          and h.profile_id <> new.id
          and h.changed_at > now() - interval '90 days'
    ) then
        raise exception 'that username was recently released and is reserved'
            using errcode = 'unique_violation';
    end if;

    return new;
end;
$$;

revoke execute on function public.enforce_username_rules() from public, anon, authenticated;

create trigger profiles_username_rules
    before insert or update of username on public.profiles
    for each row
    execute function public.enforce_username_rules();

-- AFTER UPDATE OF username: the old name goes into history. Definer, since
-- clients cannot write the table. A no-op assignment records nothing.
create function public.record_username_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.username <> old.username then
        insert into public.username_history (profile_id, username)
        values (old.id, old.username);
    end if;
    return new;
end;
$$;

revoke execute on function public.record_username_change() from public, anon, authenticated;

create trigger profiles_username_history
    after update of username on public.profiles
    for each row
    execute function public.record_username_change();


-- ---------------------------------------------------------------------------
-- username_available, now cooldown-aware
-- ---------------------------------------------------------------------------
-- Replaces 20260904143712's version. Still one bit to anon; the caller's own
-- released names count as available, since the rule lets them reclaim.
-- CREATE OR REPLACE keeps the grants (anon and authenticated may execute).
create or replace function public.username_available(candidate text)
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
           )
       and not exists (
               select 1
               from public.username_history
               where username = lower(trim(candidate))
                 and changed_at > now() - interval '90 days'
                 and profile_id is distinct from (select auth.uid())
           );
$$;


-- ---------------------------------------------------------------------------
-- resolve_username: an exact current or former handle -> the current profile
-- ---------------------------------------------------------------------------
-- What the lookup and search's exact-handle fallback call. The current holder
-- of a name wins over a former one (a name released and, after the cooldown,
-- taken by someone else resolves to its new owner). Definer, because history
-- is readable by its owner only; so it applies the profiles policy's rule
-- itself — nothing for someone the owner has blocked — and it exposes the
-- history only as far as "this handle used to be theirs".
create function public.resolve_username(candidate text)
returns table (id uuid, username text)
language sql
stable
security definer
set search_path = ''
as $$
    select p.id, p.username
    from public.profiles p
    where (
            p.username = lower(trim(candidate))
            or p.id = (
                select h.profile_id
                from public.username_history h
                where h.username = lower(trim(candidate))
                order by h.changed_at desc
                limit 1
            )
          )
      and not private.is_blocked_by((select auth.uid()), p.id)
    order by (p.username = lower(trim(candidate))) desc
    limit 1;
$$;

revoke execute on function public.resolve_username(text) from public, anon;
grant execute on function public.resolve_username(text) to authenticated;
