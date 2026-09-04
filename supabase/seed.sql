-- Multi-account test data (SOL-26).
--
-- Not migration history — this is fixture data, run on demand against the
-- hosted project rather than applied once. Idempotent: every run deletes and
-- recreates everything it owns, scoped by the @seed.candid.test email suffix,
-- so re-running never accumulates duplicates and touches nothing else.
--
-- @seed.candid.test is a subdomain of .test, reserved by RFC 2606 and
-- guaranteed to never resolve — there is no inbox behind these addresses.
-- That also means signing up with them through the app's own UI would fail
-- GoTrue's email validation; this script writes directly into auth.users and
-- auth.identities instead, the same rows a real sign-up would produce, which
-- is why it needs to run with database-owner privileges (the Dashboard SQL
-- Editor and a direct/CLI connection both have this; the app's publishable
-- key does not, and could not run this).
--
-- Run it:
--   * Dashboard: SQL Editor → paste this file → Run
--   * CLI:       supabase db query --linked -f supabase/seed.sql
--                (or: psql "$(supabase db url --linked)" -f supabase/seed.sql)
--
-- All ten accounts share one password: CandidSeed123!  (14 characters,
-- clears the 10-character minimum in config.toml). Usernames are the account
-- names below, already lowercase [a-z0-9_] as profiles.username requires.

-- -----------------------------------------------------------------------
-- Reset: drop any previous run's seed data before recreating it
-- -----------------------------------------------------------------------
-- auth.users -> profiles -> posts and follows all cascade on delete, so this
-- one statement is the whole reset.
delete from auth.users where email like '%@seed.candid.test';

-- -----------------------------------------------------------------------
-- Accounts
-- -----------------------------------------------------------------------
-- Fixed ids so the follow-graph section (see bottom) can reference these
-- accounts by name instead of re-querying them.
with seed_users (id, username) as (
    values
        ('00000000-0000-0000-0000-000000000001'::uuid, 'alice'),
        ('00000000-0000-0000-0000-000000000002'::uuid, 'bob'),
        ('00000000-0000-0000-0000-000000000003'::uuid, 'carol'),
        ('00000000-0000-0000-0000-000000000004'::uuid, 'dave'),
        ('00000000-0000-0000-0000-000000000005'::uuid, 'erin'),
        ('00000000-0000-0000-0000-000000000006'::uuid, 'frank'),
        ('00000000-0000-0000-0000-000000000007'::uuid, 'grace'),
        ('00000000-0000-0000-0000-000000000008'::uuid, 'heidi'),
        ('00000000-0000-0000-0000-000000000009'::uuid, 'ivan'),
        ('00000000-0000-0000-0000-00000000000a'::uuid, 'judy')
),
new_users as (
    insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new, email_change
    )
    select
        '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
        username || '@seed.candid.test',
        extensions.crypt('CandidSeed123!', extensions.gen_salt('bf')),
        now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_build_object('username', username),
        now(), now(), '', '', '', ''
    from seed_users
    returning id, email
)
-- The identity row is what GoTrue itself writes alongside auth.users on a
-- real sign-up; skipping it leaves an account that exists but cannot
-- authenticate.
insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select
    gen_random_uuid(), id, id::text,
    jsonb_build_object('sub', id::text, 'email', email),
    'email', now(), now(), now()
from new_users;

-- profiles rows are created by the on_auth_user_created trigger (initial
-- schema), reading username from raw_user_meta_data exactly as a real
-- sign-up does — nothing seed-specific needed here.

-- -----------------------------------------------------------------------
-- Posts
-- -----------------------------------------------------------------------
-- 3 posts per account (30 total), scattered over the last 14 days so the
-- feed shows a real range of relative timestamps instead of ten posts that
-- all read "just now".
--
-- image_path points at a well-formed but non-existent object:
-- posts_image_path_owned only checks the path's *shape*, not that anything
-- is actually in storage. FeedService.signedURLs already handles a path
-- that fails to sign (SOL-59) — the row stays, the image renders as the
-- feed's placeholder rather than failing the query. Exercising the graph
-- and visibility logic needs real rows, not real photos; upload through the
-- app on top of this seed data if you also want images that render.
insert into public.posts (user_id, image_path, caption, created_at)
select
    pr.id,
    pr.id::text || '/' || gen_random_uuid()::text || '.jpg',
    'Seed post ' || n || ' from ' || pr.username,
    now() - (random() * interval '14 days')
from public.profiles pr
cross join generate_series(1, 3) as n
where pr.id in (select id from auth.users where email like '%@seed.candid.test');

-- -----------------------------------------------------------------------
-- Follow graph (SOL-27)
-- -----------------------------------------------------------------------
-- Shapes deliberately covered:
--   * mutual pair:    alice <-> bob        (the only rows `mutuals` returns)
--   * one-way follow: carol -> alice       (carol follows alice; not returned)
--   * unconnected:    judy follows no one and is followed by no one
-- dave..ivan get a light scattering of one-way follows so the graph isn't
-- just one clique. The profiles rows these reference exist by now — the
-- on_auth_user_created trigger wrote them during the Accounts step above.
insert into public.follows (follower_id, followee_id) values
    ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002'), -- alice -> bob
    ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001'), -- bob -> alice (completes the mutual)
    ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000001'), -- carol -> alice (one-way)
    ('00000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000006'), -- dave -> frank
    ('00000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-000000000008'), -- grace -> heidi
    ('00000000-0000-0000-0000-000000000009', '00000000-0000-0000-0000-000000000001'); -- ivan -> alice

-- -----------------------------------------------------------------------
-- Blocking — blocked on SOL-31 (Milestone 7)
-- -----------------------------------------------------------------------
-- insert into public.blocks (blocker_id, blocked_id) values
--     ('00000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000005'); -- dave blocks erin

-- -----------------------------------------------------------------------
-- Visibility mix — blocked on SOL-29 (posts.visibility column, Milestone 7)
-- -----------------------------------------------------------------------
-- Once the column exists, split the seed posts across both tiers instead of
-- leaving them all on the default:
-- update public.posts set visibility = case when random() < 0.5 then 'followers' else 'mutuals' end
-- where user_id in (select id from auth.users where email like '%@seed.candid.test');
