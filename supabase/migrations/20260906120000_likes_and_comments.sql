-- Likes and comments (SOL-88): three tables, the one rule they inherit, and
-- five computed columns so the feed stays one request.
--
-- What is here, and why it is shaped this way:
--
--   * likes (post_id, user_id) and comment_likes (comment_id, user_id) are
--     binary by construction: the primary key makes a second like the same
--     unique_violation a duplicate follow is, which the client treats as
--     success. No reaction types, no counter columns — counters need
--     triggers that will be wrong at least once, the same call follows made.
--   * comments are flat: no parent_comment_id, by decision (milestone
--     description, 2026-09-06). A body is 1–1000 characters and not blank;
--     the app trims first and words the refusal. Immutable, like posts:
--     there is no update policy and no update grant, so nothing edits one.
--   * Authorization is can_view_post(), not a second rule. A like or a
--     comment is readable and writable exactly when its post is — plus one
--     thing the post rule cannot say: across a block, in either direction,
--     the pair's likes and comments are hidden from each other on anyone's
--     post ("hides content both ways", project description). Nothing is
--     deleted by a block; unblocking restores the view, as it does for
--     profiles.
--   * Delete: your own like or comment anywhere, and — for comments — any
--     comment on your own post, so an author moderates their own thread
--     (decided 2026-09-06). The delete policy is the only thing that decides
--     this; the app offers the menu where the statement would match rows.
--   * Every foreign key cascades. A deleted post takes its likes and
--     comments (and their likes) with it, as 20260904220029 asked for, and
--     delete_own_account() takes everything the account wrote.
--
-- The computed columns — post_like_count, post_comment_count and
-- post_liked_by_viewer on posts; comment_like_count and
-- comment_liked_by_viewer on comments. PostgREST exposes a function whose
-- first argument is a table's row type as a virtual column of that table,
-- selectable by name (`select=…,post_like_count`) and never part of `*`.
-- The feed adds three names to the select it already makes and stays one
-- request for twenty posts instead of sixty-one; the profile grid and the
-- detail view get the same fields through the same query. They run as the
-- caller on purpose: each count is taken under the caller's own RLS on
-- likes and comments, so it is "the likes you can see" — the principle the
-- profile's post count already follows (SOL-37) — and a blocked pair's
-- likes are left out of each other's numbers. Named with the table as a
-- prefix rather than overloaded on the row type, so each is one unambiguous
-- function to PostgREST and one unambiguous name in a select. They are
-- callable as RPC too (/rpc/post_like_count, with a posts row as the
-- argument); harmless, since every read inside runs under RLS and a post
-- the caller cannot see counts zero whether it exists or not.
--
-- Cost: one can_view_post() per like row per post on a page, a few
-- primary-key lookups each — fine at this scale, like the posts policy
-- itself. If it ever shows in a plan, the escape hatch is a definer count
-- that checks can_view_post() once per post and counts without RLS.
--
-- Grants: since 20260905170000 a new table and a new function start closed,
-- so each is opened here to exactly what a policy uses — select and delete,
-- and a column-level insert of the columns the app sends. id and created_at
-- are the server's. can_view_comment() joins the other policy helpers in
-- private, where PostgREST cannot reach it (20260904195544).
--
-- Checked by supabase/tests/visibility_matrix.sql cases 29–33, plus the
-- cascade asserts added to cases 17 and 26, against the likes and comments
-- seed.sql now carries.


-- ---------------------------------------------------------------------------
-- likes
-- ---------------------------------------------------------------------------
create table public.likes (
    post_id    uuid not null references public.posts (id) on delete cascade,
    user_id    uuid not null references public.profiles (id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (post_id, user_id)
);

-- The primary key already serves "who liked this post" (post_id leading)
-- and "did I like this post" (a lookup on both columns). This serves the
-- cascade from profiles, and a future "posts I liked".
create index likes_user_id_idx on public.likes (user_id);

alter table public.likes enable row level security;


-- ---------------------------------------------------------------------------
-- comments
-- ---------------------------------------------------------------------------
create table public.comments (
    id         uuid primary key default gen_random_uuid(),
    post_id    uuid not null references public.posts (id) on delete cascade,
    user_id    uuid not null references public.profiles (id) on delete cascade,
    body       text not null,
    created_at timestamptz not null default now(),
    -- char_length counts what Postgres counts; the app measures the same way
    -- (unicode scalars) before sending. A blank body from a raw client is
    -- refused here as well as by the app's trim.
    constraint comments_body_length check (char_length(body) between 1 and 1000),
    constraint comments_body_not_blank check (btrim(body) <> '')
);

-- The thread reads one post's comments oldest-first, id as the tiebreaker;
-- this matches that order exactly. The cascade from profiles has its own.
create index comments_post_id_created_at_id_idx on public.comments (post_id, created_at, id);
create index comments_user_id_idx on public.comments (user_id);

alter table public.comments enable row level security;


-- ---------------------------------------------------------------------------
-- comment_likes
-- ---------------------------------------------------------------------------
create table public.comment_likes (
    comment_id uuid not null references public.comments (id) on delete cascade,
    user_id    uuid not null references public.profiles (id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (comment_id, user_id)
);

create index comment_likes_user_id_idx on public.comment_likes (user_id);

alter table public.comment_likes enable row level security;


-- ---------------------------------------------------------------------------
-- private.can_view_comment: the post rule, resolved through the comment
-- ---------------------------------------------------------------------------
-- A comment is visible when its post is and the viewer and the commenter
-- have not blocked each other. Definer, like can_view_post(): it has to
-- read the comment regardless of the caller's RLS on comments, and the
-- block check reads a table the blocked side cannot. A comment that does
-- not exist is not visible.
create function private.can_view_comment(p_viewer uuid, p_comment uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select coalesce(
        (
            select private.can_view_post(p_viewer, c.post_id)
               and not private.is_blocked_either_way(p_viewer, c.user_id)
            from public.comments c
            where c.id = p_comment
        ),
        false
    );
$$;

revoke execute on function private.can_view_comment(uuid, uuid) from public, anon;
grant execute on function private.can_view_comment(uuid, uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------------
-- likes: readable with the post, except across a block; written as yourself
-- on a post you can see; removed only by whoever made it.
create policy "likes are readable with their post, except across a block"
    on public.likes
    for select
    to authenticated
    using (
        private.can_view_post((select auth.uid()), post_id)
        and not private.is_blocked_either_way((select auth.uid()), user_id)
    );

create policy "users can like posts they can see"
    on public.likes
    for insert
    to authenticated
    with check (
        user_id = (select auth.uid())
        and private.can_view_post((select auth.uid()), post_id)
    );

create policy "users can remove their own likes"
    on public.likes
    for delete
    to authenticated
    using (user_id = (select auth.uid()));

-- comments: the same three rules, and a fourth party to the delete — the
-- post's author, who may remove any comment on their own post. The posts
-- lookup runs under the posts policy as the caller, and an author can
-- always see their own post; there is no update policy, on purpose.
create policy "comments are readable with their post, except across a block"
    on public.comments
    for select
    to authenticated
    using (
        private.can_view_post((select auth.uid()), post_id)
        and not private.is_blocked_either_way((select auth.uid()), user_id)
    );

create policy "users can comment on posts they can see"
    on public.comments
    for insert
    to authenticated
    with check (
        user_id = (select auth.uid())
        and private.can_view_post((select auth.uid()), post_id)
    );

create policy "users can delete their own comments and comments on their own posts"
    on public.comments
    for delete
    to authenticated
    using (
        user_id = (select auth.uid())
        or exists (
            select 1
            from public.posts p
            where p.id = post_id
              and p.user_id = (select auth.uid())
        )
    );

-- comment_likes: resolved through the comment, which resolves through the
-- post. The block check on the liker is separate from the one inside
-- can_view_comment(), which concerns the commenter.
create policy "comment likes are readable with their comment, except across a block"
    on public.comment_likes
    for select
    to authenticated
    using (
        private.can_view_comment((select auth.uid()), comment_id)
        and not private.is_blocked_either_way((select auth.uid()), user_id)
    );

create policy "users can like comments they can see"
    on public.comment_likes
    for insert
    to authenticated
    with check (
        user_id = (select auth.uid())
        and private.can_view_comment((select auth.uid()), comment_id)
    );

create policy "users can remove their own comment likes"
    on public.comment_likes
    for delete
    to authenticated
    using (user_id = (select auth.uid()));


-- ---------------------------------------------------------------------------
-- Computed columns
-- ---------------------------------------------------------------------------
-- Invoker, stable, pinned search_path. Each takes the table's row type,
-- which is what makes PostgREST treat it as a column of that table.
create function public.post_like_count(p public.posts)
returns bigint
language sql
stable
set search_path = ''
as $$
    select count(*) from public.likes l where l.post_id = p.id;
$$;

create function public.post_comment_count(p public.posts)
returns bigint
language sql
stable
set search_path = ''
as $$
    select count(*) from public.comments c where c.post_id = p.id;
$$;

create function public.post_liked_by_viewer(p public.posts)
returns boolean
language sql
stable
set search_path = ''
as $$
    select exists (
        select 1
        from public.likes l
        where l.post_id = p.id
          and l.user_id = (select auth.uid())
    );
$$;

create function public.comment_like_count(c public.comments)
returns bigint
language sql
stable
set search_path = ''
as $$
    select count(*) from public.comment_likes cl where cl.comment_id = c.id;
$$;

create function public.comment_liked_by_viewer(c public.comments)
returns boolean
language sql
stable
set search_path = ''
as $$
    select exists (
        select 1
        from public.comment_likes cl
        where cl.comment_id = c.id
          and cl.user_id = (select auth.uid())
    );
$$;

revoke execute on function public.post_like_count(public.posts) from public, anon;
revoke execute on function public.post_comment_count(public.posts) from public, anon;
revoke execute on function public.post_liked_by_viewer(public.posts) from public, anon;
revoke execute on function public.comment_like_count(public.comments) from public, anon;
revoke execute on function public.comment_liked_by_viewer(public.comments) from public, anon;
grant execute on function public.post_like_count(public.posts) to authenticated;
grant execute on function public.post_comment_count(public.posts) to authenticated;
grant execute on function public.post_liked_by_viewer(public.posts) to authenticated;
grant execute on function public.comment_like_count(public.comments) to authenticated;
grant execute on function public.comment_liked_by_viewer(public.comments) to authenticated;


-- ---------------------------------------------------------------------------
-- Grants: exactly what the policies above use
-- ---------------------------------------------------------------------------
grant select, delete on public.likes to authenticated;
grant insert (post_id, user_id) on public.likes to authenticated;

grant select, delete on public.comments to authenticated;
grant insert (post_id, user_id, body) on public.comments to authenticated;

grant select, delete on public.comment_likes to authenticated;
grant insert (comment_id, user_id) on public.comment_likes to authenticated;
