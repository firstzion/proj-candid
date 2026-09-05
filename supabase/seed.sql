-- Multi-account test data (SOL-26).
--
-- Local and CI only — never against the hosted project. Every account below
-- shares one password, printed further down in this same file, so anyone who
-- can read this repo can sign in as any of them; that was fine while the repo
-- was private and became a launch-blocking problem the moment it wasn't
-- (SOL-86). The hosted project is production — SOL-35 (a separate dev
-- project) was declined as unneeded overhead for a solo project, so
-- production is the only hosted project there is. `supabase start`/`db
-- reset` applies this automatically ([db.seed] in config.toml), which is all
-- this file is for now: the throwaway local database, and the schema job in
-- CI. Not migration history — fixture data, idempotent: every run deletes and
-- recreates everything it owns, scoped by the @seed.candid.test email suffix,
-- so re-running never accumulates duplicates and touches nothing else.
--
-- @seed.candid.test is a subdomain of .test, reserved by RFC 2606 and
-- guaranteed to never resolve — there is no inbox behind these addresses.
-- That also means signing up with them through the app's own UI would fail
-- GoTrue's email validation; this script writes directly into auth.users and
-- auth.identities instead, the same rows a real sign-up would produce, which
-- is why it needs to run with database-owner privileges (the local database
-- and CI both give the process that; the app's publishable key does not, and
-- could not run this).
--
-- All ten accounts share one password: CandidSeed123!  (14 characters,
-- clears the 10-character minimum in config.toml). Usernames are the account
-- names below, already lowercase [a-z0-9_] as profiles.username requires.
-- alice also holds three invite codes (see the bottom): CANDD-SEED2 is the
-- valid one to sign a new account up with.

-- -----------------------------------------------------------------------
-- Reset: drop any previous run's seed data before recreating it
-- -----------------------------------------------------------------------
-- auth.users -> profiles -> posts, follows and blocks all cascade on delete,
-- so this one statement is the whole reset.
delete from auth.users where email like '%@seed.candid.test';

-- -----------------------------------------------------------------------
-- Uninvited sign-ups, for this session only
-- -----------------------------------------------------------------------
-- Since SOL-61 the sign-up trigger requires a valid invite code and would
-- refuse every account below. This setting is the owner's way past that,
-- read by handle_new_user(); it lasts for this session, and nothing a client
-- can reach is able to set it — see the invites migration.
select set_config('candid.allow_uninvited_signup', 'on', false);

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
-- Visibility (SOL-29) is deterministic rather than random, so a tester can
-- tell the tiers apart: each account's third post is friends-only
-- ('mutuals'), the other two are 'followers', and the caption says which. A
-- random split would leave you guessing which rows a one-way follower is
-- supposed to be missing.
--
-- image_path points at a well-formed but non-existent object:
-- posts_image_path_owned only checks the path's *shape*, not that anything
-- is actually in storage. FeedService.signedURLs already handles a path
-- that fails to sign (SOL-59) — the row stays, the image renders as the
-- feed's placeholder rather than failing the query. Exercising the graph
-- and visibility logic needs real rows, not real photos; upload through the
-- app on top of this seed data if you also want images that render.
insert into public.posts (user_id, image_path, caption, visibility, created_at)
select
    pr.id,
    pr.id::text || '/' || gen_random_uuid()::text || '.jpg',
    'Seed post ' || n || ' from ' || pr.username
        || case when n = 3 then ' (friends only)' else ' (followers)' end,
    (case when n = 3 then 'mutuals' else 'followers' end)::public.post_visibility,
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
-- Blocking (SOL-31)
-- -----------------------------------------------------------------------
-- One block, in one direction, between two accounts with no other tie: the
-- shape the visibility rule's "blocked in either direction" check needs,
-- tested from both sides. Inserting a block severs any follows between the
-- pair (trigger); dave and erin have none, so the graph above is unchanged.
insert into public.blocks (blocker_id, blocked_id) values
    ('00000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000005'); -- dave blocks erin

-- -----------------------------------------------------------------------
-- Invites (SOL-60)
-- -----------------------------------------------------------------------
-- Three of alice's five: one valid with a fixed value so the SOL-64 walk has
-- a code to type, one redeemed by bob so the invites screen has a "who
-- redeemed" row, one expired. The codes use create_invite()'s alphabet (no
-- 0/O/1/I/L). The expired one gives its slot back, so alice can still mint
-- three more. Re-running the seed deletes and recreates alice, which
-- cascades to these rows and to any follow edges a walk's real account made
-- with her; that account itself is untouched.
insert into public.invites (code, inviter_id, redeemed_by, redeemed_at, created_at, expires_at) values
    ('CANDD-SEED2', '00000000-0000-0000-0000-000000000001', null, null,
        now(), now() + interval '30 days'),                                          -- valid
    ('CANDD-SEED3', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002',
        now() - interval '3 days', now() - interval '5 days', now() + interval '25 days'), -- redeemed by bob
    ('CANDD-SEED4', '00000000-0000-0000-0000-000000000001', null, null,
        now() - interval '40 days', now() - interval '10 days');                    -- expired
