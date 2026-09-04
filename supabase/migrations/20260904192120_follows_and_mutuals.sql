-- The follow graph: one directional edge (SOL-27) and mutuality derived from
-- it (SOL-28). The foundation of Milestone 7 — post visibility tiers, the
-- can_view_post() rule and blocking all read from these two objects.
--
-- One table, one direction. A row (a, b) means a follows b, and nothing
-- more. "Friends" is a mutual follow, and it is *derived*: the mutuals view
-- below is a self-join on this table, not a second relationship type that
-- could drift out of sync with the first. No follower/following counter
-- columns either — count(*) is fine at this scale, and counters need
-- triggers that will be wrong at least once.
--
-- Open follow: anyone can follow anyone, with no approval and no pending
-- state. The insert policy below says only "as yourself"; it is replaced
-- when blocks land (SOL-31) so that an edge across a block is refused too.
--
-- Reads are open to every authenticated user on purpose. Follower counts,
-- the relationship line on a profile ("follows you") and the mutuality join
-- all need to read edges the caller did not create. Revisit if follower
-- lists should ever be private.

create table public.follows (
    follower_id uuid not null references public.profiles (id) on delete cascade,
    followee_id uuid not null references public.profiles (id) on delete cascade,
    created_at  timestamptz not null default now(),
    -- A duplicate follow is impossible at the database, not in app code.
    primary key (follower_id, followee_id),
    constraint follows_no_self_follow check (follower_id <> followee_id)
);

-- The primary key already serves "who does X follow" (follower_id first).
-- This serves the other direction, "who follows X" — what the mutuals
-- self-join, follower counts and the cascade from profiles all look up.
-- The follows half of SOL-25.
create index follows_followee_id_idx on public.follows (followee_id);

alter table public.follows enable row level security;

create policy "follows are readable by authenticated users"
    on public.follows
    for select
    to authenticated
    using (true);

-- Insert: only as yourself. Without this check anyone could make anyone
-- follow anyone.
create policy "users can follow as themselves"
    on public.follows
    for insert
    to authenticated
    with check (follower_id = (select auth.uid()));

-- Delete: only your own edges. You can unfollow someone; you cannot remove
-- one of your followers.
create policy "users can unfollow their own edges"
    on public.follows
    for delete
    to authenticated
    using (follower_id = (select auth.uid()));

-- No update policy. An edge is created or removed, never edited — there is
-- nothing on it to change.


-- ---------------------------------------------------------------------------
-- mutuals: the single definition of "friends"
-- ---------------------------------------------------------------------------
-- An edge a -> b where b -> a also exists. Both (a, b) and (b, a) come back
-- as rows, so "is a mutual with b" is one equality lookup and no caller has
-- to ask twice. The can_view_post() rule (SOL-30) and any future ranking
-- (SOL-21) read this rather than each writing their own join.
--
-- security_invoker: the view runs under the caller's own RLS on follows
-- rather than its owner's (Supabase lint 0010, security_definer_view).
-- Follows are readable by every authenticated user anyway, so this changes
-- nothing today; it keeps the view honest if that policy ever narrows.
--
-- A plain view, not a materialized one. The self-join is cheap at this
-- scale; if it ever shows up in a plan, materialize it behind the same name
-- and no caller changes.
create view public.mutuals
    with (security_invoker = true)
as
select
    f.follower_id as user_id,
    f.followee_id as mutual_id
from public.follows f
join public.follows r
  on r.follower_id = f.followee_id
 and r.followee_id = f.follower_id;

-- The project's default privileges already expose new objects in public to
-- the API roles; saying it explicitly records who is meant to read this.
grant select on public.mutuals to authenticated;
