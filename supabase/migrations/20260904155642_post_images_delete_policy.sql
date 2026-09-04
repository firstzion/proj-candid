-- Let a user delete objects in their own folder; drop the unused update policy.
--
-- PostService uploads the image first and writes the posts row second, so a
-- failed insert leaves an object no row points at. With no delete policy the
-- client could not clean that up, and every failed post leaked one object for
-- good — rare, but permanent. The client now removes the object when the
-- insert fails, and this is the policy that lets it.
--
-- Scoped the same way as insert: only within the caller's own folder. A user
-- can therefore delete only their own images, which is also exactly what
-- deleting a post, and deleting an account, will need.
--
-- The update policy goes. Posts are immutable, nothing uploads with upsert, and
-- an overwrite of an object already referenced by a post would silently change
-- that post's photo. Insert, then delete, is the whole lifecycle.

create policy "users can delete their own post images"
    on storage.objects
    for delete
    to authenticated
    using (
        bucket_id = 'post-images'
        and (storage.foldername(name))[1] = (select auth.uid())::text
    );

drop policy "users can update their own post images" on storage.objects;
