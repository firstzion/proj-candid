-- The profile grid's page index (SOL-37).
--
-- The profile screen lists one author's posts newest-first, paginated with
-- the feed's own keyset — created_at desc, id desc — through the feed query
-- with an author filter added. The initial schema indexed the per-author
-- path as (user_id, created_at desc), which matches that order only
-- approximately: a page is an index-range scan followed by an incremental
-- sort on id. This index matches it exactly, the way posts_created_at_id_idx
-- (20260904200800) does for the feed, and replaces the old one.
--
-- Nothing about who may see a row changes here. The grid is a *scope* on the
-- feed query, not a rule: can_view_post() still governs every row, so a
-- one-way follower's grid of an author shows exactly the posts their feed
-- would, and a count under RLS is "the posts you can see".

drop index public.posts_user_id_created_at_idx;

create index posts_user_id_created_at_id_idx
    on public.posts (user_id, created_at desc, id desc);
