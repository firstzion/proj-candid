-- Delete your own posts (SOL-38): the first delete path in the schema.
--
-- Until now no client could delete a post at all. The initial schema said
-- "add a policy when it is in scope", and 20260904194339 made visibility
-- immutable on the promise that "delete and repost" would be the escape
-- hatch. This is that hatch.
--
-- One policy: the author's own rows. Another account's delete matches no
-- rows and affects nothing — RLS filters a delete rather than refusing it —
-- which the matrix checks from bob's seat against alice's post.
--
-- The storage object is not touched here. The client removes it second,
-- and the order is forced: the storage delete policy from 20260904160000
-- refuses an object a posts row still references, exactly so that "object
-- first" fails loudly instead of leaving a live post with a broken image.
-- Row first, object second — the same order account deletion already uses.
-- If the object delete then fails, the post is already gone from every
-- feed, and with no row can_view_image() answers no to everyone but the
-- owner's own folder clause: the leftover is a storage cost, not a privacy
-- one, and the client logs it rather than reporting a failed delete.
--
-- Future likes or comments should reference posts with on delete cascade,
-- so a deleted post takes its reactions with it. Nothing to do for that
-- today.

create policy "users can delete their own posts"
    on public.posts
    for delete
    to authenticated
    using (user_id = (select auth.uid()));
