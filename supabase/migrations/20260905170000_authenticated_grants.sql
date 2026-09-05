-- Grant authenticated exactly what a policy lets it do, and nothing else.
--
-- Supabase's default privileges hand anon and authenticated every table
-- privilege on every table and view in public — SELECT, INSERT, UPDATE,
-- DELETE, TRUNCATE, REFERENCES, TRIGGER — and RLS has been the only thing
-- narrowing them. 20260905023000 (SOL-68) closed the specific dangerous
-- columns and took everything from anon; authenticated kept the rest.
-- Confirmed live on 2026-09-05: full DML on invites, username_history and
-- searchable_profiles; INSERT on profiles including invite_quota; UPDATE on
-- reports including status; TRUNCATE, TRIGGER and REFERENCES on everything.
--
-- Every one of those is denied today, because no policy exists for that
-- command on that table — and each is exactly one future policy away from
-- not being. A "users can insert their own profile" policy, added for any
-- reason, would silently make invite_quota client-settable again. Grants and
-- policies are two locks; this makes sure both are turned.
--
-- Nothing the app does changes. Before this was committed the whole battery
-- of reads, writes and RPCs the Swift services make was run against the
-- hosted project as alice with these grants applied, inside a rolled-back
-- transaction: every one succeeded, and every write the app never makes was
-- refused with 42501 exactly as before. The visibility matrix, which runs
-- each path as an app user, is the standing regression test; its exposure
-- block now asserts the shape below, so a future table that forgets its
-- grant — or a future policy without one — fails CI rather than the app.
--
-- REVOKE ALL ON TABLE also drops column-level grants, so SOL-68's are
-- restated here. This file is therefore the whole grant model in one place.

revoke all on all tables in schema public from authenticated;
alter default privileges in schema public revoke all on tables from authenticated;

-- Functions too. Postgres grants EXECUTE on a new function to PUBLIC by
-- default, and Supabase's defaults add anon and authenticated directly — a
-- direct grant a `revoke ... from public` does not touch, which is exactly how
-- image_is_referenced() stayed callable by anon until SOL-69. Every callable
-- function here already carries its own explicit grant; from now on a new one
-- starts closed and its migration has to say who may run it.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- profiles: readable unless the owner has blocked you (policy); rename
-- yourself (policy: own row; grant: the username column only — invite_quota
-- is the project owner's). No insert: handle_new_user() is the only
-- inserter. No delete: delete_own_account() is the only path.
grant select on public.profiles to authenticated;
grant update (username) on public.profiles to authenticated;

-- posts: read what can_view_post() allows; post as yourself, with the server
-- owning id and created_at; delete your own. No update — visibility is
-- immutable (20260904194339) and nothing edits a caption yet.
grant select, delete on public.posts to authenticated;
grant insert (user_id, image_path, caption, visibility) on public.posts to authenticated;

-- follows and blocks: read (either end, or a mutual of either end; your own
-- blocks), write an edge as yourself, remove your own. Never updated.
grant select, delete on public.follows to authenticated;
grant insert (follower_id, followee_id) on public.follows to authenticated;
grant select, delete on public.blocks to authenticated;
grant insert (blocker_id, blocked_id) on public.blocks to authenticated;

-- invites: read your own, revoke your own unredeemed. Minted by
-- create_invite() and redeemed by handle_new_user(), both as owner — a
-- client that could insert or update could mint past its quota or un-redeem
-- a code (20260905011241).
grant select, delete on public.invites to authenticated;

-- reports: file one, as yourself, about something you can see. SELECT stays
-- granted although no select policy exists and none should: under RLS the
-- table simply reads as empty, and ReportService's insert relies on
-- PostgREST's return=minimal path, whose behaviour with no SELECT on the
-- table at all is not something to discover in production. The matrix
-- asserts the policies stay insert-only.
grant select on public.reports to authenticated;
grant insert (reporter_id, reported_profile_id, reported_post_id, reason, details)
    on public.reports to authenticated;

-- username_history: read your own. Written by the rename trigger as owner.
grant select on public.username_history to authenticated;

-- The two views. Both are security_invoker, so a read runs as the caller
-- against the base tables' policies and the grants above; select is all a
-- caller has any use for. searchable_profiles' own migration meant exactly
-- this — it revoked from public and anon, but authenticated held the default
-- grant directly, which a revoke from public does not touch.
grant select on public.mutuals to authenticated;
grant select on public.searchable_profiles to authenticated;
