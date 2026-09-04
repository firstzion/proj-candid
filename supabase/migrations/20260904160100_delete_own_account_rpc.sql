-- delete_own_account(): self-service account deletion.
--
-- App Store Review Guideline 5.1.1(v) requires in-app account deletion for
-- any app that supports account creation, and GoTrue has no self-service
-- delete endpoint of its own — only the service role can remove an
-- auth.users row directly. SECURITY DEFINER closes that gap: the function
-- runs with its owner's privileges rather than the caller's, but only ever
-- touches the row matching the caller's own auth.uid().
--
-- Deleting the auth.users row cascades: profiles references it
-- `on delete cascade`, and posts references profiles the same way, so one
-- delete removes the account, its profile, and every post row. Storage
-- objects do not cascade — the client removes those separately (see
-- ProfileService.deleteAccount), and must do so *after* calling this
-- function, not before: 20260904160000_guard_referenced_post_images.sql
-- refuses to delete an object a posts row still references, and until this
-- function runs, every one of the account's images still has one.
create function public.delete_own_account()
returns void
language sql
security definer
set search_path = ''
as $$
    delete from auth.users where id = (select auth.uid());
$$;

revoke execute on function public.delete_own_account() from public, anon;
grant execute on function public.delete_own_account() to authenticated;
