-- Move image_is_referenced() into private and close the anon gap it
-- predates (SOL-69).
--
-- Every later policy helper lives in private, which PostgREST does not
-- expose, and revokes execute from public, anon explicitly — 20260904195544
-- explains why: a function authenticated may call through a policy is also
-- an RPC endpoint at /rest/v1/rpc/<name> if it sits in public.
-- image_is_referenced() (20260904160000) predates that habit: its migration
-- revoked execute from public but not anon, and Supabase's default
-- privileges had already granted anon execute directly — a direct grant
-- survives a revoke from public. The security advisor flags it (lint 0028)
-- right next to the intended username_available.
--
-- Low impact on its own — object names are {user_id}/{uuid}.jpg and
-- unguessable — but it is an unauthenticated oracle for "does a post
-- reference this object", exactly the class of exposure the matrix's
-- exposure block exists to catch; it never checked this function until now.
--
-- Policies reference functions by OID, so the schema move alone would keep
-- the storage policy working, but recreating it keeps the SQL honest about
-- where the function now lives.

drop policy "users can delete their own unreferenced post images" on storage.objects;

alter function public.image_is_referenced(text) set schema private;
revoke execute on function private.image_is_referenced(text) from public, anon;
grant execute on function private.image_is_referenced(text) to authenticated;

create policy "users can delete their own unreferenced post images"
    on storage.objects
    for delete
    to authenticated
    using (
        bucket_id = 'post-images'
        and (storage.foldername(name))[1] = (select auth.uid())::text
        and not private.image_is_referenced(name)
    );
