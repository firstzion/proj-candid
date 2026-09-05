-- Restrict client writes to the columns the app actually sends (SOL-68).
--
-- Supabase's default privileges grant anon and authenticated every table
-- privilege (SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER)
-- on every table and view in public, and RLS is the only thing that has ever
-- narrowed them. Every write policy so far is row-scoped (id = auth.uid(),
-- user_id = auth.uid(), ...), never column-scoped, so within your own rows
-- every column has been writable with the publishable key plus your own JWT.
--
-- Confirmed live on 2026-09-04 on ztdggewgqaoaixjhttct via
-- information_schema.role_table_grants and role_column_grants: both roles
-- hold all seven privileges on profiles, posts, follows, blocks and mutuals,
-- with column grants on every column. Consequences, in order of severity:
--
--   1. profiles.invite_quota is updatable by its owner through the existing
--      update policy. One PATCH /rest/v1/profiles?id=eq.<me> with
--      {"invite_quota": 1000} removes the quota Milestone 9 rests on. This
--      migration rides the same push as invites (20260905011241) so the
--      column is never live and writable at once.
--   2. posts.created_at is insertable by the author. A post dated years
--      ahead sits at the top of every follower's feed forever.
--   3. reports.status is insertable by the reporter, so a report can be
--      filed pre-marked 'actioned' and hidden from the future moderation
--      queue (SOL-45). about_post is already safe: the fill_reported_profile
--      trigger overwrites it, and the client never sends it.
--   4. follows.created_at, blocks.created_at and profiles.created_at are
--      client-settable too — list ordering and cosmetics only.
--
-- Folded in here because it is the same migration (grant hygiene):
--
--   * anon holds full DML on every table; only the absence of anon policies
--     has ever stopped it.
--   * mutuals has INSERT/UPDATE/DELETE/TRUNCATE/... granted to both roles by
--     the same default privileges; it is a read-only join view.
--   * the profiles insert policy ("users can insert their own profile") is
--     dead surface: handle_new_user is the only inserter, and a second
--     insert would hit the primary key.
--
-- Column-level grants only take effect once the covering table-level grant
-- is gone, hence revoke-then-grant throughout. PostgREST reloads its schema
-- cache on DDL (Supabase's pgrst_ddl_watch event trigger), so no restart is
-- needed after a push.
--
-- Nothing in Swift changes: ProfileService.changeUsername sends only
-- {"username": ...}; NewPost, NewFollow, NewBlock and NewReport send only
-- the columns granted below. Definer functions and triggers
-- (handle_new_user, create_invite, remove_follows_on_block,
-- record_username_change, fill_reported_profile) run as owner and are
-- unaffected; so is the seed, which also runs as owner.

-- Clients may change only their own username. invite_quota is raised by the
-- project owner in the SQL editor (README, Invites), never by a client.
revoke update on public.profiles from anon, authenticated;
grant update (username) on public.profiles to authenticated;

-- The server owns id and created_at on every row a client writes.
revoke insert on public.posts from anon, authenticated;
grant insert (user_id, image_path, caption, visibility) on public.posts to authenticated;

revoke insert on public.follows from anon, authenticated;
grant insert (follower_id, followee_id) on public.follows to authenticated;

revoke insert on public.blocks from anon, authenticated;
grant insert (blocker_id, blocked_id) on public.blocks to authenticated;

-- status and about_post are the server's; ReportService.file never sends
-- either, and relies on `return=minimal` since there is no select policy to
-- answer a `Prefer: return=representation` insert anyway.
revoke insert on public.reports from anon, authenticated;
grant insert (reporter_id, reported_profile_id, reported_post_id, reason, details)
    on public.reports to authenticated;

-- anon has no business touching tables at all; RLS already denies it — say
-- so, and stop the defaults from re-opening it for future tables. Applies to
-- objects created by the migrating role (postgres under db push), which is
-- what future migrations create — so it also covers invites,
-- username_history, reports and searchable_profiles, which is why this
-- migration sorts after all four.
revoke all on all tables in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;

-- mutuals is a read-only join view.
revoke all on public.mutuals from anon, authenticated;
grant select on public.mutuals to authenticated;

-- Dead surface: the sign-up trigger is the only thing that ever inserts a
-- profile.
drop policy "users can insert their own profile" on public.profiles;
