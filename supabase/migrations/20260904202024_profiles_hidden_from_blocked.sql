-- Profiles are hidden from the people their owner has blocked — one direction,
-- not two. Corrects the profiles read policy from 20260904200800 (SOL-30) as
-- part of the block UI (SOL-31, SOL-32).
--
-- 20260904200800 hid a profile row from both sides of a block. That is right
-- for posts — can_view_post() still hides them in both directions and is not
-- touched here — but wrong for the profile row: the person who made a block
-- is the one person who needs to reach the blocked profile again, because
-- that is where "Unblock" lives. With both sides hidden, a block could never
-- be lifted from the app.
--
-- So: your own row always; anyone else's unless *they* have blocked *you*.
-- What the blocked person sees is unchanged — the blocker's profile is gone,
-- silently, and a lookup answers "no one by that name" exactly as it does for
-- a typo. The blocker sees the blocked profile with its block state and
-- nothing else of theirs.
--
-- is_blocked_by() joins is_blocked_either_way() in the private schema; see
-- 20260904195544 for why policy helpers live there.

create function private.is_blocked_by(p_viewer uuid, p_owner uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.blocks
        where blocker_id = p_owner
          and blocked_id = p_viewer
    );
$$;

revoke execute on function private.is_blocked_by(uuid, uuid) from public, anon;
grant execute on function private.is_blocked_by(uuid, uuid) to authenticated;

drop policy "profiles are readable unless blocked either way" on public.profiles;

create policy "profiles are readable unless their owner has blocked you"
    on public.profiles
    for select
    to authenticated
    using (
        id = (select auth.uid())
        or not private.is_blocked_by((select auth.uid()), id)
    );
