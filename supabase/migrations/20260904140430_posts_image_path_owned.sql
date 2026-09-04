-- Tie posts.image_path to the row's owner.
--
-- The insert policy on posts checks only that user_id is the caller's own id;
-- image_path was unconstrained. Any authenticated user could therefore insert
-- a row — the publishable key plus their own JWT is all it takes — whose
-- image_path pointed into *another* user's storage folder. The read policy on
-- storage.objects lets any authenticated user sign any object, so the feed
-- rendered the other user's photo under the inserting user's name. Once reads
-- narrow to a friend graph, that is a way to leak a photo outside it. The same
-- gap admitted a path that does not exist at all, which the feed then has to
-- cope with.
--
-- The storage policy already refuses to *upload* into someone else's folder
-- (the first path segment must equal auth.uid()); this is the matching rule on
-- the row that references the upload. Two checks:
--
--   1. The path has exactly the shape the client writes —
--      {user_id}/{uuid}.jpg, lower-case, as StorageService builds it.
--   2. The {user_id} segment is this row's user_id.
--
-- user_id::text renders a uuid lower-case with hyphens, which is what the
-- client writes and what the pattern demands, so the comparison is exact.
--
-- The .jpg suffix mirrors the bucket's allowed_mime_types (image/jpeg only).
-- If that is ever widened, widen the pattern here too.
--
-- Adding the constraint validates every existing row; a violating row fails
-- the migration rather than being waved through.

alter table public.posts
    add constraint posts_image_path_owned
    check (
        image_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
        and split_part(image_path, '/', 1) = user_id::text
    );
