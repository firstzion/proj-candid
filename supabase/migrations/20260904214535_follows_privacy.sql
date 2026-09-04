-- Follower lists are private to mutuals; the counts stay public (SOL-66).
--
-- Replaces the follows read policy from 20260904192120 (SOL-27), which let
-- every authenticated user read every edge and said so: "Revisit if follower
-- lists should ever be private." SOL-43 resolved that revisit. With open
-- follow, a fully readable follows table lets anyone enumerate anyone's
-- entire friend graph — the single largest privacy leak left in the model —
-- and knowing exactly who someone's mutuals are tells you most of what the
-- mutuals tier was protecting.
--
-- The rule, stated per row because a policy has to be: a row (a, b) belongs
-- to a's following list and to b's followers list, so it is readable when
-- the caller is a or b, or is mutual with a, or is mutual with b. That is
-- exactly "your own edges, plus the full lists of the people you're friends
-- with", and nothing else.
--
-- Two definer helpers make it work:
--
--   * private.is_mutual(a, b) answers the policy's own question. It has to
--     be definer because the caller can no longer see the whole table to
--     answer it for themselves — under this very policy. It lives in
--     private like the other policy helpers (20260904195544), so no
--     signed-in user can ask "are alice and bob friends?" as an RPC.
--
--   * public.follow_counts(profile) returns the two numbers a profile
--     shows. Definer because counting needs rows the policy hides; in
--     public because it is an intended endpoint — the counts are public by
--     decision (SOL-43). A counts *view* was rejected: under the caller's
--     RLS it would count only the rows the caller may see.
--
-- Nothing already shipped depends on the broad readability this removes,
-- and supabase/tests/visibility_matrix.sql proves it rather than asserting
-- it. FollowService.relationship(with:) and isFollowing read edges with the
-- caller at one end; isMutual and the security_invoker mutuals view
-- self-join edges that both touch the caller; can_view_post() reads as
-- definer; the block trigger deletes as definer; the seed writes as owner.
-- What does change: the mutuals view, run by a caller, now returns their
-- own pairs and the pairs of the people they are mutual with, rather than
-- everyone's — which is the point.
--
-- Cost: up to two is_mutual() calls per row, each two lookups on the
-- primary key and the followee index of a small table. Fine at this scale,
-- like can_view_post().

create function private.is_mutual(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
               select 1
               from public.follows
               where follower_id = p_a
                 and followee_id = p_b
           )
       and exists (
               select 1
               from public.follows
               where follower_id = p_b
                 and followee_id = p_a
           );
$$;

revoke execute on function private.is_mutual(uuid, uuid) from public, anon;
grant execute on function private.is_mutual(uuid, uuid) to authenticated;


drop policy "follows are readable by authenticated users" on public.follows;

create policy "follows are readable by either end, or a mutual of either end"
    on public.follows
    for select
    to authenticated
    using (
        follower_id = (select auth.uid())
        or followee_id = (select auth.uid())
        or private.is_mutual((select auth.uid()), follower_id)
        or private.is_mutual((select auth.uid()), followee_id)
    );

-- The insert and delete policies are untouched: you can still follow as
-- yourself (unless blocked) and unfollow your own edges, and both only ever
-- concern rows with the caller at one end.


-- ---------------------------------------------------------------------------
-- follow_counts: the two public numbers
-- ---------------------------------------------------------------------------
-- One row: how many people follow p_profile, and how many p_profile follows.
-- Answers for any profile id, including one the caller could not otherwise
-- see, because the numbers themselves are public; nothing about *who* is
-- learnable from it.
create function public.follow_counts(p_profile uuid)
returns table (followers bigint, following bigint)
language sql
stable
security definer
set search_path = ''
as $$
    select
        (select count(*) from public.follows where followee_id = p_profile),
        (select count(*) from public.follows where follower_id = p_profile);
$$;

revoke execute on function public.follow_counts(uuid) from public, anon;
grant execute on function public.follow_counts(uuid) to authenticated;
