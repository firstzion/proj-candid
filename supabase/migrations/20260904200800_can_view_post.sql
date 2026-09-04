-- can_view_post() (SOL-30): the authorization model. One rule, in Postgres,
-- that every read of a post — and of a post's image — goes through.
--
-- Until now visibility was "any authenticated user sees everything", which
-- was not a permissive policy so much as the absence of one; the initial
-- schema said so at the top, and this migration is what it was waiting for.
--
-- The rule, for a viewer looking at a post by author with a visibility tier:
--
--   * the author always sees their own posts;
--   * otherwise, neither may have blocked the other (SOL-31), the viewer must
--     follow the author (SOL-27), and for a 'mutuals' post the pair must
--     appear in the mutuals view (SOL-28) — the single definition of
--     "friends", read here rather than re-derived.
--
-- Written once, taking the row's own columns (viewer, author, visibility) so
-- the posts policy evaluates it without looking the same post up again. The
-- (viewer, post_id) signature the ticket names is a thin wrapper for callers
-- that only hold an id — storage below; likes, comments, a profile grid and
-- moderation later — and can_view_image() resolves a storage object to its
-- one post the same way. Three entry points, one rule body: a second copy of
-- the rule, in SQL or in Swift, is how a photo leaks.
--
-- All three are SECURITY DEFINER, because the rule has to read blocks and the
-- blocked side must not be able to; STABLE; pinned to an empty search_path;
-- and in the private schema (20260904195544) that PostgREST does not expose,
-- so no signed-in user can probe them as RPC — can_view_post(erin, <a post
-- of dave's>) answering false while erin follows dave would reveal a block.
--
-- profiles narrows in the same migration as posts, deliberately: a post is
-- only ever visible together with its author's profile row, and narrowing one
-- without the other would leave a feed page embedding a hidden author and
-- failing to decode.
--
-- Storage: creating a signed URL is a SELECT on storage.objects, so the read
-- policy there is exactly where "no signed URL for a post you cannot see" is
-- enforced. The caller's own folder stays readable outright — uploads,
-- failed-insert cleanup and account deletion all touch objects before or
-- after a post row exists. A URL already minted stays valid for up to an hour
-- (StorageService.signedURLLifetime) after an unfollow or a block; accepted,
-- and documented in the README.
--
-- Checked by supabase/tests/visibility_matrix.sql, which impersonates each
-- seeded account and asserts every case from every seat, then rolls back.

create function private.can_view_post(
    p_viewer     uuid,
    p_author     uuid,
    p_visibility public.post_visibility
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select p_viewer is not null and (
        p_viewer = p_author
        or (
            not private.is_blocked_either_way(p_viewer, p_author)
            and exists (
                select 1
                from public.follows f
                where f.follower_id = p_viewer
                  and f.followee_id = p_author
            )
            and (
                p_visibility = 'followers'
                or exists (
                    select 1
                    from public.mutuals m
                    where m.user_id = p_viewer
                      and m.mutual_id = p_author
                )
            )
        )
    );
$$;

-- For callers that only hold a post id. Delegates; there is no second rule.
-- A post that does not exist is not visible.
create function private.can_view_post(p_viewer uuid, p_post uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select coalesce(
        (
            select private.can_view_post(p_viewer, p.user_id, p.visibility)
            from public.posts p
            where p.id = p_post
        ),
        false
    );
$$;

-- For storage. posts.image_path is unique (posts_image_path_key), so an
-- object name resolves to at most one post. An object no post references —
-- an upload whose row was never written — is visible to its owner alone,
-- through the folder clause of the storage policy below.
create function private.can_view_image(p_viewer uuid, p_object_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select coalesce(
        (
            select private.can_view_post(p_viewer, p.user_id, p.visibility)
            from public.posts p
            where p.image_path = p_object_name
        ),
        false
    );
$$;

revoke execute on function private.can_view_post(uuid, uuid, public.post_visibility) from public, anon;
revoke execute on function private.can_view_post(uuid, uuid) from public, anon;
revoke execute on function private.can_view_image(uuid, text) from public, anon;
grant execute on function private.can_view_post(uuid, uuid, public.post_visibility) to authenticated;
grant execute on function private.can_view_post(uuid, uuid) to authenticated;
grant execute on function private.can_view_image(uuid, text) to authenticated;


-- ---------------------------------------------------------------------------
-- The dev-only read policies, retired
-- ---------------------------------------------------------------------------
drop policy "posts are readable by authenticated users" on public.posts;

create policy "posts are readable by permitted viewers"
    on public.posts
    for select
    to authenticated
    using (private.can_view_post((select auth.uid()), user_id, visibility));

drop policy "profiles are readable by authenticated users" on public.profiles;

-- Your own row always; anyone else's unless one of you has blocked the other.
-- What the profile screen and search (Milestone 8) inherit rather than each
-- filtering for themselves.
create policy "profiles are readable unless blocked either way"
    on public.profiles
    for select
    to authenticated
    using (
        id = (select auth.uid())
        or not private.is_blocked_either_way((select auth.uid()), id)
    );

drop policy "post images are readable by authenticated users" on storage.objects;

create policy "post images are readable by their owner and permitted viewers"
    on storage.objects
    for select
    to authenticated
    using (
        bucket_id = 'post-images'
        and (
            (storage.foldername(name))[1] = (select auth.uid())::text
            or private.can_view_image((select auth.uid()), name)
        )
    );


-- ---------------------------------------------------------------------------
-- The feed's keyset index (the SOL-25 follow-up)
-- ---------------------------------------------------------------------------
-- FeedService orders by (created_at desc, id desc) and pages with
-- created_at < :c or (created_at = :c and id < :id). The single-column index
-- from the initial schema matched that sort only approximately; this one
-- matches it exactly, so a page is an index-range scan with no incremental
-- sort on id. Under the policy above each row on that scan costs one
-- can_view_post() call — a few primary-key lookups on small tables — which is
-- fine at this scale. If a large table and a sparse graph ever make the first
-- page slow, the escape hatch is a security_invoker `feed` view that
-- pre-filters to user_id in (self, followees) as a planner hint only, with
-- authorization still in can_view_post().
create index posts_created_at_id_idx on public.posts (created_at desc, id desc);
drop index public.posts_created_at_idx;
