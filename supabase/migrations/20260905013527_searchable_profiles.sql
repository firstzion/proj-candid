-- Search by username (SOL-39), and the index that makes a prefix match cheap.
--
-- The unique index on profiles.username cannot serve `like 'ali%'` under the
-- project's default en_US collation — a btree over a locale collation does
-- not order by byte prefix — so this one, with text_pattern_ops, exists for
-- exactly that query. Cheap now, in the SOL-25 spirit of indexing before the
-- slow query rather than after it.
--
-- searchable_profiles is what the People tab queries: a security_invoker
-- view over profiles that leaves out the caller and anyone the caller has
-- blocked. People who have blocked the caller are already hidden by the
-- profiles read policy (20260904202024), which the view runs under, so both
-- directions of a block are excluded without a second rule — and a blocker's
-- account is simply not in the list, the same silence the exact lookup
-- keeps. Nothing here decides the visibility of anything else: the view
-- exposes id and username, and a result opens a profile whose counts and grid
-- are read under RLS like any other. Search matches current usernames only;
-- a former handle typed in full is answered by resolve_username() (SOL-41).

create index profiles_username_pattern_idx
    on public.profiles (username text_pattern_ops);

create view public.searchable_profiles
    with (security_invoker = true)
as
select p.id, p.username
from public.profiles p
where p.id <> (select auth.uid())
  and not exists (
      select 1
      from public.blocks b
      where b.blocker_id = (select auth.uid())
        and b.blocked_id = p.id
  );

-- For signed-in people; anon would get nothing from it anyway (no profiles
-- policy admits anon), but say so.
revoke all on public.searchable_profiles from public, anon;
grant select on public.searchable_profiles to authenticated;
