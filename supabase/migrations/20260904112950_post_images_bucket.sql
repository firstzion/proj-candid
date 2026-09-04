-- Storage bucket for post images.
--
-- PRIVATE (public = false), not public-read. The ticket offered either, but
-- Candid's whole premise is that your photos go to your friends rather than to
-- the world: a public bucket makes every uploaded image fetchable forever by
-- anyone who has or guesses the URL, with no way to walk that back for images
-- already out there. Reads therefore go through short-lived signed URLs.
--
-- To switch to public later: set public = true here, and have StorageService
-- return the public URL instead of a signed one. Doing it the other way round
-- (public now, private later) does not really work — anything already exposed
-- stays exposed.
--
-- file_size_limit is 5 MB, comfortably above what the client produces after
-- downscaling to 1600px at JPEG 80%. allowed_mime_types is image/jpeg only,
-- because that is the single format the client uploads; widen it here if that
-- ever changes.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('post-images', 'post-images', false, 5242880, array['image/jpeg'])
on conflict (id) do nothing;


-- RLS is already enabled on storage.objects by Supabase; only policies are
-- needed. Objects are laid out as {user_id}/{uuid}.jpg, so the first path
-- segment identifies the owner.

-- Read: any authenticated user can read any post image. Dev-only and matching
-- the posts table policy from the initial schema — this narrows to a friend
-- graph at the same time that one does.
create policy "post images are readable by authenticated users"
    on storage.objects
    for select
    to authenticated
    using (bucket_id = 'post-images');

-- Insert: the first path segment must be the caller's own user id, so nobody
-- can write into another user's folder.
create policy "users can upload post images to their own folder"
    on storage.objects
    for insert
    to authenticated
    with check (
        bucket_id = 'post-images'
        and (storage.foldername(name))[1] = (select auth.uid())::text
    );

-- Update: same ownership restriction, and it cannot be used to move an object
-- into someone else's folder.
create policy "users can update their own post images"
    on storage.objects
    for update
    to authenticated
    using (
        bucket_id = 'post-images'
        and (storage.foldername(name))[1] = (select auth.uid())::text
    )
    with check (
        bucket_id = 'post-images'
        and (storage.foldername(name))[1] = (select auth.uid())::text
    );

-- No delete policy: deletes are denied outright, matching the posts table.
