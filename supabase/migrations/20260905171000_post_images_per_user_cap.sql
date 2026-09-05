-- Cap how many objects one account can hold in post-images.
--
-- The bucket already bounds each object — 5 MB, image/jpeg — but nothing
-- bounded how many. One account with the publishable key and a loop could
-- fill the project's storage, and until SOL-86 is done there are ten such
-- accounts whose password is in this repository. A per-account ceiling turns
-- "unbounded" into "at most the cap times 5 MB", which is a number.
--
-- 1,000 objects per account. Generous for a friends-only photo app — three a
-- day for a year — and one constant, private.post_image_cap(), to change.
-- This is a product number as much as a safety one; it is here so that there
-- is one rather than none.
--
-- Enforced in the upload policy, the same layer as "your own folder only":
-- storage-api runs each upload's INSERT as the caller under RLS, so this is
-- checked per upload, with the caller's identity. The count itself lives in
-- private.own_post_image_count(), a security definer helper, because a policy
-- on storage.objects cannot contain a subquery on storage.objects: Postgres
-- expands row security per relation, whatever the command, and refuses the
-- self-reference as "infinite recursion detected in policy" (42P17) — met on
-- the first attempt at this, which inlined the count. A definer function is
-- the standard way through, and the shape image_is_referenced() already
-- takes for the delete policy. Its query runs as the function's owner —
-- postgres, which does not own storage.objects but has BYPASSRLS, and that
-- attribute rather than ownership is what lets it count the whole folder
-- instead of what the caller's select policy shows. The matrix checks the
-- helper against the raw count, because a postgres without BYPASSRLS would
-- count zero and the cap would silently never bind. It reads the caller from
-- auth.uid() rather than taking a parameter, so it can only ever count the
-- caller's own folder, and it lives in private, which the API does not reach.
--
-- The predicate is `name like '<uid>/%'` rather than
-- (storage.foldername(name))[1] = '<uid>' because storage ships an index for
-- exactly that shape (name_prefix_search, text_pattern_ops); a uuid holds no
-- LIKE metacharacter and every object here is {uid}/{uuid}.jpg
-- (StorageService), so the two are equivalent. The count sees committed rows,
-- and storage-api inserts one object per upload — the only path a client
-- has, since storage is not an exposed schema and nothing can bulk-insert
-- around it.
--
-- The app has no wording for the cap yet: StorageService maps the refusal to
-- "Upload rejected: <policy message>". At a thousand posts that is rare, and
-- a friendlier sentence is a small follow-up. Account deletion's storage
-- cleanup (ProfileService) pages a hundred at a time with a thousand-page
-- ceiling; under this cap it needs at most ten.

create function private.post_image_cap()
returns integer
language sql
immutable
set search_path = ''
as $$
    select 1000;
$$;

create function private.own_post_image_count()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
    select count(*)::integer
    from storage.objects o
    where o.bucket_id = 'post-images'
      and o.name like ((select auth.uid())::text || '/%');
$$;

-- The policy evaluates as the uploading role, so that role must be able to
-- call both; nothing else has any use for either.
revoke execute on function private.post_image_cap() from public, anon;
grant execute on function private.post_image_cap() to authenticated;
revoke execute on function private.own_post_image_count() from public, anon;
grant execute on function private.own_post_image_count() to authenticated;

drop policy "users can upload post images to their own folder" on storage.objects;

create policy "users can upload post images to their own folder"
    on storage.objects
    for insert
    to authenticated
    with check (
        bucket_id = 'post-images'
        and (storage.foldername(name))[1] = (select auth.uid())::text
        and private.own_post_image_count() < private.post_image_cap()
    );
