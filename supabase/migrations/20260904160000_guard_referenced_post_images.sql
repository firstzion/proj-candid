-- Guard storage deletes against objects a live post still references.
--
-- The delete policy from 20260904155642_post_images_delete_policy.sql lets a
-- user delete any object in their own folder, including one a post row still
-- points at. Today the only caller is PostService's cleanup after a failed
-- insert, which by construction targets an object no row references — so
-- this is a guard against a future mistake, not a fix for a live bug. Delete
-- Post (SOL-38) will add a second delete path, and "row first, then object"
-- is easy to get backwards in a retry or an error branch; this turns that
-- mistake into a loud policy error instead of a feed showing a broken image
-- to every viewer.
--
-- image_is_referenced is SECURITY DEFINER rather than a plain `not exists`
-- subquery so the check is exact once reads narrow to the follow graph
-- (Milestone 7): a subquery running under the caller's RLS on `posts` would
-- see only what that caller is allowed to read, and a referenced object
-- could look unreferenced to its own owner if the row happened to be hidden
-- from them. Cheap to do now rather than revisit later.
--
-- The unique index is what makes both the function and the future
-- Delete-Post / account-deletion flows exact: each object is referenced by
-- at most one post, so "does anything reference this path" is a single
-- index lookup rather than a scan.

create unique index posts_image_path_key on public.posts (image_path);

create function public.image_is_referenced(candidate_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1 from public.posts where image_path = candidate_path
    );
$$;

revoke execute on function public.image_is_referenced(text) from public;
grant execute on function public.image_is_referenced(text) to authenticated;

drop policy "users can delete their own post images" on storage.objects;

create policy "users can delete their own unreferenced post images"
    on storage.objects
    for delete
    to authenticated
    using (
        bucket_id = 'post-images'
        and (storage.foldername(name))[1] = (select auth.uid())::text
        and not public.image_is_referenced(name)
    );
