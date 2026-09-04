-- Blocking (SOL-31): the one relationship that overrides the graph.
--
-- A row (a, b) means a has blocked b. Built now rather than later because
-- retrofitting it would mean auditing every query that touches the graph;
-- landing it before the can_view_post() rule (SOL-30) is written means that
-- rule is written once, block-aware from the start.
--
-- What a block does, all of it in the database:
--
--   * Severs the follow in both directions, atomically with the insert (the
--     trigger below). A block that left the follow intact would be a bug
--     waiting to surface.
--   * Refuses a new follow across it, in either direction, for as long as it
--     stands (the replaced follows insert policy, below).
--   * Hides each side's posts and profile from the other — once
--     can_view_post() exists. Until then the dev-only read policies from the
--     initial schema still show every post and profile to every authenticated
--     user, and this migration deliberately leaves both alone: narrowing
--     profiles before posts would leave a feed page embedding a hidden author
--     and failing to decode. The two narrow together in SOL-30's migration.
--
-- Silent. The blocked side must never be able to learn a block exists: the
-- table is readable only by the person who made the block, and the helper
-- that answers "is either of these two blocking the other" lives in a schema
-- PostgREST does not expose (see private, below). Unblocking deletes the row
-- and restores nothing — the severed follows stay severed.

create table public.blocks (
    blocker_id uuid not null references public.profiles (id) on delete cascade,
    blocked_id uuid not null references public.profiles (id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (blocker_id, blocked_id),
    constraint blocks_no_self_block check (blocker_id <> blocked_id)
);

-- The primary key serves "who has X blocked"; this serves "who has blocked
-- X" — the other half of the either-way check — and lets the cascade from
-- profiles find rows without a scan.
create index blocks_blocked_id_idx on public.blocks (blocked_id);

alter table public.blocks enable row level security;

-- Blocker-only, all three ways. There is no select policy for the blocked
-- side, and no update policy at all.
create policy "users can see their own blocks"
    on public.blocks
    for select
    to authenticated
    using (blocker_id = (select auth.uid()));

create policy "users can block as themselves"
    on public.blocks
    for insert
    to authenticated
    with check (blocker_id = (select auth.uid()));

create policy "users can unblock their own blocks"
    on public.blocks
    for delete
    to authenticated
    using (blocker_id = (select auth.uid()));


-- ---------------------------------------------------------------------------
-- private: helpers that policies call and the API cannot
-- ---------------------------------------------------------------------------
-- Any function in public that authenticated may execute is also an endpoint
-- at /rest/v1/rpc/<name>. A policy has to call is_blocked_either_way(), so
-- authenticated must be able to execute it — and if it lived in public, any
-- signed-in user could ask "has alice blocked bob?" in one request, which is
-- exactly what silent blocking forbids. PostgREST serves only the schemas in
-- config.toml's [api] schemas (public, graphql_public); a function here is
-- callable from a policy and from nowhere else.
--
-- The can_view_post() family (SOL-30) lives here too, for the same reason.
-- Trigger functions stay in public with execute revoked, as handle_new_user
-- does: a trigger needs no callers.
create schema if not exists private;

-- A new schema grants PUBLIC nothing by default; said explicitly so the
-- intent is on record. authenticated needs usage to evaluate the policies
-- that call into it; nothing else does.
revoke all on schema private from public;
grant usage on schema private to authenticated;

-- security definer: a caller can only see blocks they made, but the answer
-- has to account for blocks made against them.
create function private.is_blocked_either_way(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.blocks
        where (blocker_id = p_a and blocked_id = p_b)
           or (blocker_id = p_b and blocked_id = p_a)
    );
$$;

revoke execute on function private.is_blocked_either_way(uuid, uuid) from public, anon;
grant execute on function private.is_blocked_either_way(uuid, uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- A block severs the follow, both ways, in the same transaction
-- ---------------------------------------------------------------------------
-- security definer because the reverse edge (blocked -> blocker) belongs to
-- the blocked user, and the blocker's own RLS on follows could not delete it.
create function public.remove_follows_on_block()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    delete from public.follows
    where (follower_id = new.blocker_id and followee_id = new.blocked_id)
       or (follower_id = new.blocked_id and followee_id = new.blocker_id);
    return new;
end;
$$;

revoke execute on function public.remove_follows_on_block() from public, anon, authenticated;

create trigger on_block_remove_follows
    after insert on public.blocks
    for each row
    execute function public.remove_follows_on_block();


-- ---------------------------------------------------------------------------
-- No re-follow across a block, in either direction
-- ---------------------------------------------------------------------------
-- Replaces "users can follow as themselves" from 20260904192120, which knew
-- nothing of blocks. The refusal reaches the client as an ordinary RLS error
-- (42501), which FollowService words generically — the blocked person is not
-- told why.
drop policy "users can follow as themselves" on public.follows;

create policy "users can follow as themselves unless blocked"
    on public.follows
    for insert
    to authenticated
    with check (
        follower_id = (select auth.uid())
        and not private.is_blocked_either_way(follower_id, followee_id)
    );
