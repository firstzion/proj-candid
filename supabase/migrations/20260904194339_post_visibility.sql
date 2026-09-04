-- Per-post visibility (SOL-29): which of the author's relationships may see
-- a post. Two tiers, chosen when the post is made and fixed from then on.
--
--   followers   anyone who follows the author
--   mutuals     only people the author also follows back — "friends", in the
--               app's vocabulary (see the mutuals view, 20260904192120)
--
-- This column is what the can_view_post() rule (SOL-30) will read. Until that
-- rule replaces the dev-only read policy from the initial schema, every
-- authenticated user still sees every post, and nothing a viewer can observe
-- changes here.
--
-- Default 'followers', deliberately the wider tier. A new account's audience
-- is almost entirely one-way followers at first, so a 'mutuals' default would
-- make its first posts invisible to nearly everyone. The safer default is the
-- less useful one here, and that trade is accepted. NOT NULL with a DEFAULT
-- backfills the existing rows in place — all of them were posted when
-- "everyone" was the only audience there was, and 'followers' is the closest
-- tier to that.
--
-- Immutable after posting. A visibility that can change means a photo someone
-- already saw can vanish from under them, or one they could never see can
-- surface at an old position in their feed. Both are worse than "delete and
-- repost", which stays the escape hatch (SOL-38). Two things enforce it:
--
--   1. The posts update policy is dropped. Nothing in the app updates a post
--      — storage dropped its own update policy for the same reason in
--      20260904155642 — and with no policy, no client can update any column.
--   2. A trigger refuses any change to visibility regardless of policy, so a
--      caption-edit policy added later cannot reopen the door by accident.

create type public.post_visibility as enum ('followers', 'mutuals');

alter table public.posts
    add column visibility public.post_visibility not null default 'followers';

drop policy "users can update their own posts" on public.posts;

-- Fires only for statements that set visibility (`update of visibility`), so
-- any future update path that leaves the column alone never pays for it; a
-- no-op assignment to the same value is allowed through.
create function public.reject_post_visibility_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.visibility <> old.visibility then
        raise exception 'posts.visibility is immutable; delete and repost instead'
            using errcode = 'check_violation';
    end if;
    return new;
end;
$$;

-- A trigger function needs no callers: permission to execute it is checked
-- when the trigger is created, not each time it fires. Keeping it off the API
-- surface is what the security linter wants (0028/0029), as with
-- handle_new_user.
revoke execute on function public.reject_post_visibility_change() from public, anon, authenticated;

create trigger posts_visibility_immutable
    before update of visibility on public.posts
    for each row
    execute function public.reject_post_visibility_change();
