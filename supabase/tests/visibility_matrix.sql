-- Visibility matrix (SOL-30): the authorization rule, checked against the
-- seeded graph from every seat at the table.
--
-- Read-only in effect: everything runs inside one transaction that ends in
-- ROLLBACK, including the temporary rows some cases need. Local and CI only
-- now (SOL-86): it asserts against the specific seeded graph (alice, bob,
-- ...), and seed.sql must never run against the hosted project again — the
-- password printed in its own header became public the moment this repo did.
-- Run it with database-owner privileges against the local database
-- `supabase start`/`db reset` seeds:
--
--   psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"$/\1/p')" \
--     -f supabase/tests/visibility_matrix.sql
--
-- or let CI's `schema` job run it for you, which it does on every push.
-- Checking a change against the *hosted* project is a separate, smaller
-- thing now — a targeted `begin; … rollback;` block exercising just the new
-- policy, grant or function, never a full seeded run. See the README's
-- Backend section.
--
-- It prints "all checks passed", or stops at the first failing assertion with
-- the case number in the message. Impersonation works the way PostgREST's
-- does: `request.jwt.claims` carries the user's id and the session runs as
-- the `authenticated` role, so every policy is evaluated exactly as it would
-- be for a request from the app.
--
-- Seeded shapes this relies on (supabase/seed.sql):
--   alice <-> bob mutual; carol -> alice and ivan -> alice one-way;
--   dave blocks erin, with no follows between them; judy unconnected;
--   each account's post 3 is 'mutuals', posts 1 and 2 are 'followers';
--   alice holds three invites — CANDD-SEED2 valid, CANDD-SEED3 redeemed by
--   bob, CANDD-SEED4 expired — against a quota of 5;
--   six likes, three comments (fixed ids c0000000-…-01/02/03) and three
--   comment likes on alice's posts — the seed's Likes and comments block.
--
-- Case numbers follow SOL-30's test pass, plus SOL-28's "unfollowing one side
-- removes the pair" (10), the profile and re-follow rules from SOL-31
-- (11, 12), the feed's own query (13), follower-list privacy from SOL-66
-- (14-16: an edge is readable at either end or by a mutual of either end,
-- and the counts are public through follow_counts()), deleting a post from
-- SOL-38 (17: only the author, and the object only once the row is gone),
-- the profile's post count from SOL-37 (18: counted under RLS, so it is
-- "the posts you can see"), and invite-only onboarding from SOL-60/61/62
-- (19-23: one enum value to the world, own rows only, the gate refuses and
-- rolls back, a good code admits and befriends, the quota holds), and
-- changeable usernames from SOL-41 (24: one change per 30 days, released
-- names reserved 90 days except from their owner, old handles resolve), and
-- search from SOL-39 (25: the view omits you, your blocks and your blockers),
-- and reports from SOL-42 (26: insert-only, only what you could see, filled
-- from the post, a repeat refused, unreadable, surviving the post — and,
-- since SOL-82, surviving the reported account too, and refusing a
-- nonexistent post the same way as a hidden one). Since SOL-68, column
-- grants (27): the quota, feed order and a report's own status are all
-- server-only now, while an ordinary write within your own row still works.
-- Since SOL-88, likes and comments (29-33): readable and writable with their
-- post and nowhere else, hidden across a block in both directions, deletable
-- by their writer or the post's author, counted by computed columns under the
-- caller's own RLS — and cascading with the post (17) and the account (26).

begin;

create function pg_temp.act_as(p_user uuid) returns void
language plpgsql
as $$
begin
    perform set_config(
        'request.jwt.claims',
        json_build_object('sub', p_user, 'role', 'authenticated')::text,
        true
    );
    execute 'set local role authenticated';
end;
$$;

create function pg_temp.act_as_owner() returns void
language plpgsql
as $$
begin
    execute 'reset role';
end;
$$;

-- Nobody: no claims, the anon role — a request from the sign-up form before
-- an account exists.
create function pg_temp.act_as_anon() returns void
language plpgsql
as $$
begin
    perform set_config('request.jwt.claims', '', true);
    execute 'set local role anon';
end;
$$;

-- A sign-up the way GoTrue does it: one insert into auth.users, inside which
-- handle_new_user() fires and either provisions everything or refuses the
-- whole thing. The seed writes the same rows. A null code leaves the key out
-- of the metadata, as a form with an empty field would.
create function pg_temp.sign_up(p_id uuid, p_username text, p_code text) returns void
language plpgsql
as $$
begin
    insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new, email_change
    ) values (
        '00000000-0000-0000-0000-000000000000', p_id, 'authenticated', 'authenticated',
        p_username || '@matrix.candid.test',
        extensions.crypt('CandidSeed123!', extensions.gen_salt('bf')),
        now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_strip_nulls(jsonb_build_object('username', p_username, 'invite_code', p_code)),
        now(), now(), '', '', '', ''
    );
end;
$$;

do $$
declare
    alice constant uuid := '00000000-0000-0000-0000-000000000001';
    bob   constant uuid := '00000000-0000-0000-0000-000000000002';
    carol constant uuid := '00000000-0000-0000-0000-000000000003';
    dave  constant uuid := '00000000-0000-0000-0000-000000000004';
    erin  constant uuid := '00000000-0000-0000-0000-000000000005';
    ivan  constant uuid := '00000000-0000-0000-0000-000000000009';
    judy  constant uuid := '00000000-0000-0000-0000-00000000000a';
    frank constant uuid := '00000000-0000-0000-0000-000000000006';
    -- The seeded comments (SOL-88): carol's on alice's post 1, alice's reply
    -- on it, and bob's on alice's mutuals post.
    c_carol constant uuid := 'c0000000-0000-0000-0000-000000000001';
    c_alice constant uuid := 'c0000000-0000-0000-0000-000000000002';
    c_bob   constant uuid := 'c0000000-0000-0000-0000-000000000003';
    n int;
    m int;
    b boolean;
    msg text;
    alice_mutuals_path text;
    alice_post1 uuid;
    alice_post2 uuid;
    alice_mutuals_post uuid;
    frank_post1 uuid;
    c_temp uuid;
begin
    -- Preconditions: the seed is loaded in the shape the cases assume.
    select count(*) into n from public.posts where user_id = alice and visibility = 'mutuals';
    assert n = 1, format('precondition: alice should have exactly 1 mutuals post, has %s — is the seed loaded?', n);
    select count(*) into n from public.posts where user_id = alice and visibility = 'followers';
    assert n = 2, format('precondition: alice should have 2 followers posts, has %s', n);
    assert exists (select 1 from public.mutuals where user_id = alice and mutual_id = bob),
        'precondition: alice <-> bob should be mutual';
    assert exists (select 1 from public.follows where follower_id = carol and followee_id = alice),
        'precondition: carol should follow alice';
    assert not exists (select 1 from public.follows where follower_id = alice and followee_id = carol),
        'precondition: alice must not follow carol';
    assert exists (select 1 from public.blocks where blocker_id = dave and blocked_id = erin),
        'precondition: dave should block erin';
    assert not exists (select 1 from public.follows where follower_id = judy or followee_id = judy),
        'precondition: judy should be unconnected';
    assert exists (select 1 from public.follows where follower_id = ivan and followee_id = alice),
        'precondition: ivan should follow alice';
    select count(*) into n from public.follows where followee_id = alice;
    assert n = 3, format('precondition: alice should have exactly 3 followers (bob, carol, ivan), has %s', n);
    select count(*) into n from public.invites where inviter_id = alice;
    assert n = 3, format('precondition: alice should hold 3 seeded invites, holds %s — re-run the seed after the invites migration', n);
    assert (select invite_quota from public.profiles where id = alice) = 5, 'precondition: alice''s invite quota should be 5';
    select image_path into alice_mutuals_path from public.posts where user_id = alice and visibility = 'mutuals';
    select id into alice_post1 from public.posts where user_id = alice and caption like 'Seed post 1 %';
    select id into alice_post2 from public.posts where user_id = alice and caption like 'Seed post 2 %';
    select id into alice_mutuals_post from public.posts where user_id = alice and visibility = 'mutuals';
    select id into frank_post1 from public.posts where user_id = frank and caption like 'Seed post 1 %';
    select count(*) into n from public.likes l join public.posts p on p.id = l.post_id where p.user_id = alice;
    assert n = 6, format('precondition: alice''s posts should carry 6 seeded likes, carry %s — re-run the seed after the likes migration', n);
    select count(*) into n from public.comments c join public.posts p on p.id = c.post_id where p.user_id = alice;
    assert n = 3, format('precondition: alice''s posts should carry 3 seeded comments, carry %s', n);
    select count(*) into n from public.comment_likes where comment_id in (c_carol, c_alice, c_bob);
    assert n = 3, format('precondition: the seeded comments should carry 3 likes, carry %s', n);

    -- 1, 2: the author sees their own posts at both tiers.
    perform pg_temp.act_as(alice);
    select count(*) into n from public.posts where user_id = alice and visibility = 'followers';
    assert n = 2, format('case 1: alice should see her 2 followers posts, sees %s', n);
    select count(*) into n from public.posts where user_id = alice and visibility = 'mutuals';
    assert n = 1, format('case 2: alice should see her mutuals post, sees %s', n);

    -- 3, 4: a one-way follower sees followers posts and not mutuals posts.
    perform pg_temp.act_as(carol);
    select count(*) into n from public.posts where user_id = alice and visibility = 'followers';
    assert n = 2, format('case 3: carol should see alice''s 2 followers posts, sees %s', n);
    select count(*) into n from public.posts where user_id = alice and visibility = 'mutuals';
    assert n = 0, format('case 4: carol must not see alice''s mutuals post, sees %s', n);

    -- 9: a direct table query returns only permitted rows.
    select count(*) into n from public.posts;
    assert n = 5, format('case 9: carol should see 5 posts (her 3 + alice''s 2), sees %s', n);
    select count(*) into n from public.posts where user_id not in (carol, alice);
    assert n = 0, format('case 9: carol sees %s posts from people she does not follow', n);

    -- 13: the feed's own query, unchanged, pages over permitted rows only —
    -- RLS filters before the limit applies, so the page is exactly the
    -- permitted rows and the keyset cursor is unaffected.
    select count(*) into n from (
        select id from public.posts order by created_at desc, id desc limit 21
    ) page;
    assert n = 5, format('case 13: carol''s first feed page should hold 5 rows, holds %s', n);

    -- 5: a mutual sees both tiers.
    perform pg_temp.act_as(bob);
    select count(*) into n from public.posts where user_id = alice;
    assert n = 3, format('case 5: bob should see all 3 of alice''s posts, sees %s', n);

    -- 6: an unconnected user sees neither tier — only their own posts.
    perform pg_temp.act_as(judy);
    select count(*) into n from public.posts where user_id = alice;
    assert n = 0, format('case 6: judy must see none of alice''s posts, sees %s', n);
    select count(*) into n from public.posts;
    assert n = 3, format('case 6: judy should see only her own 3 posts, sees %s', n);

    -- 7: blocked in either direction hides everything, even across a follow
    -- edge. The edges are inserted as the owner, past the policy that would
    -- refuse them, to prove the block outranks the edge.
    perform pg_temp.act_as_owner();
    insert into public.follows (follower_id, followee_id) values (dave, erin), (erin, dave);
    perform pg_temp.act_as(dave);
    select count(*) into n from public.posts where user_id = erin;
    assert n = 0, format('case 7a: dave (blocker) must see none of erin''s posts, sees %s', n);
    perform pg_temp.act_as(erin);
    select count(*) into n from public.posts where user_id = dave;
    assert n = 0, format('case 7b: erin (blocked) must see none of dave''s posts, sees %s', n);

    -- 11: the blocked person cannot read the blocker's profile row; the
    -- blocker can still read theirs — that is where Unblock lives; everyone
    -- else is unaffected.
    select count(*) into n from public.profiles where id = dave;
    assert n = 0, format('case 11: erin (blocked) must not read dave''s profile, reads %s', n);
    select count(*) into n from public.profiles where id = erin;
    assert n = 1, 'case 11: erin must still read her own profile';
    perform pg_temp.act_as(dave);
    select count(*) into n from public.profiles where id = erin;
    assert n = 1, format('case 11: dave (blocker) must still read erin''s profile, reads %s', n);
    perform pg_temp.act_as(carol);
    select count(*) into n from public.profiles where id = alice;
    assert n = 1, 'case 11: carol must read alice''s profile';

    -- 12: re-follow across a block is refused. The temporary edges from case
    -- 7 are removed first so the insert is a real attempt.
    perform pg_temp.act_as_owner();
    delete from public.follows
    where (follower_id = dave and followee_id = erin) or (follower_id = erin and followee_id = dave);
    perform pg_temp.act_as(erin);
    begin
        insert into public.follows (follower_id, followee_id) values (erin, dave);
        raise exception 'case 12: erin could follow dave across the block';
    exception when insufficient_privilege then
        get stacked diagnostics msg = message_text;
        assert msg ilike '%row-level security%', format('case 12: unexpected refusal: %s', msg);
    end;

    -- 8: no signed URL for a hidden post. Signing is a SELECT on
    -- storage.objects, so a row that only the policy governs stands in for
    -- the object — the seed has no real objects.
    perform pg_temp.act_as_owner();
    insert into storage.objects (bucket_id, name, owner, owner_id)
    values ('post-images', alice_mutuals_path, alice, alice::text);
    perform pg_temp.act_as(carol);
    select count(*) into n from storage.objects where name = alice_mutuals_path;
    assert n = 0, format('case 8: carol must not be able to sign alice''s mutuals image, sees %s rows', n);
    perform pg_temp.act_as(bob);
    select count(*) into n from storage.objects where name = alice_mutuals_path;
    assert n = 1, format('case 8: bob should be able to sign alice''s mutuals image, sees %s rows', n);
    perform pg_temp.act_as(alice);
    select count(*) into n from storage.objects where name = alice_mutuals_path;
    assert n = 1, format('case 8: alice should see her own object, sees %s rows', n);

    -- 14: follower lists are private (SOL-66). An edge is readable at either
    -- end, or by a mutual of either end, and nowhere else. alice -> bob is on
    -- alice's following list and bob's followers list; judy is a stranger to
    -- both and carol only follows alice one-way, so neither may read it.
    perform pg_temp.act_as(judy);
    select count(*) into n from public.follows where follower_id = alice and followee_id = bob;
    assert n = 0, format('case 14: judy (stranger) must not read alice -> bob, reads %s', n);
    select count(*) into n from public.follows where follower_id = alice or followee_id = alice;
    assert n = 0, format('case 14: judy must read none of alice''s edges, reads %s', n);
    perform pg_temp.act_as(carol);
    select count(*) into n from public.follows where follower_id = alice and followee_id = bob;
    assert n = 0, format('case 14: carol (one-way) must not read alice -> bob, reads %s', n);
    -- Her own edge stays hers to read, which is all the follow button needs:
    -- the relationship query asks for both directions between carol and
    -- alice and finds exactly the one edge that exists.
    select count(*) into n from public.follows
    where (follower_id = carol and followee_id = alice) or (follower_id = alice and followee_id = carol);
    assert n = 1, format('case 14: carol should read her own edge to alice, reads %s', n);
    select count(*) into n from public.follows where follower_id = alice or followee_id = alice;
    assert n = 1, format('case 14: of alice''s edges carol should read only her own, reads %s', n);
    select count(*) into n from public.mutuals;
    assert n = 0, format('case 14: carol has no mutuals, so the view should show her no pairs, shows %s', n);

    -- 15: a mutual reads the whole list, including edges other people made.
    perform pg_temp.act_as(bob);
    select count(*) into n from public.follows where followee_id = alice;
    assert n = 3, format('case 15: bob (mutual) should read all 3 of alice''s followers, reads %s', n);
    assert exists (select 1 from public.follows where follower_id = carol and followee_id = alice),
        'case 15: bob should read carol -> alice';
    assert exists (select 1 from public.follows where follower_id = ivan and followee_id = alice),
        'case 15: bob should read ivan -> alice';
    select count(*) into n from public.mutuals where user_id = bob and mutual_id = alice;
    assert n = 1, format('case 15: bob should see his own pair with alice in mutuals, sees %s', n);

    -- 16: the two counts are public, from follow_counts() rather than from
    -- rows the caller could read: a stranger and a one-way follower get the
    -- same numbers a mutual would.
    perform pg_temp.act_as(judy);
    select f.followers, f.following into n, m from public.follow_counts(alice) f;
    assert n = 3 and m = 1, format('case 16: follow_counts(alice) as judy should be 3 / 1, is %s / %s', n, m);
    perform pg_temp.act_as(carol);
    select f.followers, f.following into n, m from public.follow_counts(alice) f;
    assert n = 3 and m = 1, format('case 16: follow_counts(alice) as carol should be 3 / 1, is %s / %s', n, m);
    select f.followers, f.following into n, m from public.follow_counts(judy) f;
    assert n = 0 and m = 0, format('case 16: follow_counts(judy) should be 0 / 0, is %s / %s', n, m);

    -- 18: the profile's post count is "posts you can see" (SOL-37): a count
    -- of one author's rows under RLS is exact for the author, the followers
    -- tier for a one-way follower and zero for a stranger. The true total is
    -- never computed for anyone else, which is what makes "no posts" and
    -- "posts you can't see" the same screen (SOL-40).
    perform pg_temp.act_as(carol);
    select count(*) into n from public.posts where user_id = alice;
    assert n = 2, format('case 18: carol''s count of alice''s posts should be 2, is %s', n);
    perform pg_temp.act_as(bob);
    select count(*) into n from public.posts where user_id = alice;
    assert n = 3, format('case 18: bob''s count of alice''s posts should be 3, is %s', n);
    perform pg_temp.act_as(judy);
    select count(*) into n from public.posts where user_id = alice;
    assert n = 0, format('case 18: judy''s count of alice''s posts should be 0, is %s', n);

    -- 29: likes and comments read with their post (SOL-88). A one-way follower
    -- sees what sits on the followers posts and nothing on the mutuals post;
    -- a mutual sees all of it; a stranger sees none of it; and the computed
    -- columns agree with the tables from every seat, including the author's.
    perform pg_temp.act_as(carol);
    select count(*) into n from public.likes where post_id = alice_post1;
    assert n = 3, format('case 29: carol should see 3 likes on alice''s post 1 (bob, carol, ivan), sees %s', n);
    select count(*) into n from public.comments where post_id = alice_post1;
    assert n = 2, format('case 29: carol should see 2 comments on post 1, sees %s', n);
    select public.post_like_count(p), public.post_comment_count(p), public.post_liked_by_viewer(p) into n, m, b
    from public.posts p where p.id = alice_post1;
    assert n = 3 and m = 2 and b, format('case 29: carol''s computed columns for post 1 should be 3 / 2 / true, are %s / %s / %s', n, m, b);
    select count(*) into n from public.likes where post_id = alice_mutuals_post;
    assert n = 0, format('case 29: carol must see no likes on the mutuals post, sees %s', n);
    select count(*) into n from public.comments where post_id = alice_mutuals_post;
    assert n = 0, format('case 29: carol must see no comments on the mutuals post, sees %s', n);
    select public.comment_like_count(c), public.comment_liked_by_viewer(c) into n, b from public.comments c where c.id = c_carol;
    assert n = 2 and not b, format('case 29: carol''s own comment should show 2 likes, not hers, shows %s / %s', n, b);
    select public.comment_liked_by_viewer(c) into b from public.comments c where c.id = c_alice;
    assert b, 'case 29: carol should see her own like on alice''s reply';
    perform pg_temp.act_as(ivan);
    select public.post_liked_by_viewer(p) into b from public.posts p where p.id = alice_post1;
    assert b, 'case 29: ivan should see his own like on post 1';
    perform pg_temp.act_as(bob);
    select public.post_like_count(p), public.post_comment_count(p), public.post_liked_by_viewer(p) into n, m, b
    from public.posts p where p.id = alice_mutuals_post;
    assert n = 1 and m = 1 and b, format('case 29: bob''s columns for the mutuals post should be 1 / 1 / true, are %s / %s / %s', n, m, b);
    perform pg_temp.act_as(judy);
    select count(*) into n from public.likes;
    assert n = 0, format('case 29: judy (stranger) sees %s likes', n);
    select count(*) into n from public.comments;
    assert n = 0, format('case 29: judy sees %s comments', n);
    select count(*) into n from public.comment_likes;
    assert n = 0, format('case 29: judy sees %s comment likes', n);
    -- The computed column called RPC-style with a fabricated row: RLS still
    -- answers zero for a post the caller cannot see, so the endpoint is not
    -- an oracle for hidden posts.
    select public.post_like_count(row(alice_post1, alice, 'x'::text, null::text, now(), 'followers'::public.post_visibility)::public.posts) into n;
    assert n = 0, format('case 29: judy''s RPC-style count of a hidden post should be 0, is %s', n);
    perform pg_temp.act_as(alice);
    select public.post_like_count(p), public.post_comment_count(p), public.post_liked_by_viewer(p) into n, m, b
    from public.posts p where p.id = alice_post1;
    assert n = 3 and m = 2 and not b, format('case 29: alice''s columns for her post 1 should be 3 / 2 / false, are %s / %s / %s', n, m, b);

    -- 30: writes refused — a hidden post, someone else's name, a duplicate,
    -- a blank or oversized body, a server-owned column, an edit.
    perform pg_temp.act_as(carol);
    begin
        insert into public.likes (post_id, user_id) values (alice_mutuals_post, carol);
        raise exception 'case 30: carol liked a post she cannot see';
    exception when insufficient_privilege then
        null;
    end;
    begin
        insert into public.likes (post_id, user_id) values (alice_post2, bob);
        raise exception 'case 30: carol liked as bob';
    exception when insufficient_privilege then
        null;
    end;
    begin
        insert into public.likes (post_id, user_id) values (alice_post1, carol);
        raise exception 'case 30: a duplicate like was accepted';
    exception when unique_violation then
        null;
    end;
    begin
        insert into public.comments (post_id, user_id, body) values (alice_mutuals_post, carol, 'x');
        raise exception 'case 30: carol commented on a post she cannot see';
    exception when insufficient_privilege then
        null;
    end;
    begin
        insert into public.comments (post_id, user_id, body) values (alice_post1, carol, '   ');
        raise exception 'case 30: a blank comment was accepted';
    exception when check_violation then
        null;
    end;
    begin
        insert into public.comments (post_id, user_id, body) values (alice_post1, carol, repeat('x', 1001));
        raise exception 'case 30: a 1001-character comment was accepted';
    exception when check_violation then
        null;
    end;
    begin
        insert into public.comments (post_id, user_id, body, created_at) values (alice_post1, carol, 'x', now());
        raise exception 'case 30: comments.created_at is client-settable';
    exception when insufficient_privilege then
        null;
    end;
    begin
        insert into public.comment_likes (comment_id, user_id) values (c_bob, carol);
        raise exception 'case 30: carol liked a comment on a post she cannot see';
    exception when insufficient_privilege then
        null;
    end;
    begin
        update public.comments set body = 'edited' where id = c_carol;
        raise exception 'case 30: a comment was edited';
    exception when insufficient_privilege then
        null;
    end;
    perform pg_temp.act_as(judy);
    begin
        insert into public.likes (post_id, user_id) values (alice_post1, judy);
        raise exception 'case 30: judy liked a stranger''s post';
    exception when insufficient_privilege then
        null;
    end;

    -- 31: deletes — your own; the author's, on their post; nobody else's. Uses
    -- fresh rows on alice's post 2 so the seeded thread on post 1 stays as
    -- later cases expect it.
    perform pg_temp.act_as(carol);
    delete from public.likes where post_id = alice_post2 and user_id = bob;
    get diagnostics n = row_count;
    assert n = 0, format('case 31: carol removed bob''s like (%s)', n);
    delete from public.comments where id = c_alice;
    get diagnostics n = row_count;
    assert n = 0, format('case 31: carol deleted alice''s comment (%s)', n);
    insert into public.comments (post_id, user_id, body) values (alice_post2, carol, 'temporary') returning id into c_temp;
    perform pg_temp.act_as(bob);
    delete from public.comments where id = c_temp;
    get diagnostics n = row_count;
    assert n = 0, format('case 31: bob, neither author nor commenter, deleted carol''s comment (%s)', n);
    insert into public.comment_likes (comment_id, user_id) values (c_temp, bob);
    perform pg_temp.act_as(carol);
    delete from public.comments where id = c_temp;
    get diagnostics n = row_count;
    assert n = 1, format('case 31: carol should delete her own comment, deleted %s', n);
    perform pg_temp.act_as_owner();
    select count(*) into n from public.comment_likes where comment_id = c_temp;
    assert n = 0, format('case 31: the deleted comment''s like should cascade, %s left', n);
    perform pg_temp.act_as(carol);
    insert into public.comments (post_id, user_id, body) values (alice_post2, carol, 'temporary again') returning id into c_temp;
    perform pg_temp.act_as(alice);
    delete from public.comments where id = c_temp;
    get diagnostics n = row_count;
    assert n = 1, format('case 31: alice should delete a comment on her own post, deleted %s', n);
    perform pg_temp.act_as(carol);
    delete from public.likes where post_id = alice_post2 and user_id = carol;
    get diagnostics n = row_count;
    assert n = 1, format('case 31: carol should remove her own like, removed %s', n);
    delete from public.likes where post_id = alice_post2 and user_id = carol;
    get diagnostics n = row_count;
    assert n = 0, 'case 31: a second unlike should match nothing and raise nothing';

    -- 32: comment likes resolve through the comment, and the comment through
    -- the post. bob can like alice's reply on post 1 (carol's seeded like is
    -- already on it) and take it back; bob's own comment on the mutuals post
    -- is out of carol's reach.
    perform pg_temp.act_as(bob);
    insert into public.comment_likes (comment_id, user_id) values (c_alice, bob);
    get diagnostics n = row_count;
    assert n = 1, 'case 32: bob should like a comment he can see';
    select public.comment_like_count(c), public.comment_liked_by_viewer(c) into n, b from public.comments c where c.id = c_alice;
    assert n = 2 and b, format('case 32: alice''s reply should show 2 likes (carol''s and bob''s), his among them, shows %s / %s', n, b);
    delete from public.comment_likes where comment_id = c_alice and user_id = bob;
    get diagnostics n = row_count;
    assert n = 1, format('case 32: bob should remove his comment like, removed %s', n);
    select public.comment_like_count(c) into n from public.comments c where c.id = c_alice;
    assert n = 1, format('case 32: the reply should be back to carol''s 1 like, shows %s', n);
    perform pg_temp.act_as(carol);
    begin
        insert into public.comment_likes (comment_id, user_id) values (c_bob, carol);
        raise exception 'case 32: carol liked a comment on a post she cannot see';
    exception when insufficient_privilege then
        null;
    end;
    perform pg_temp.act_as(judy);
    select public.comment_like_count(row(c_carol, alice_post1, carol, 'x'::text, now())::public.comments) into n;
    assert n = 0, format('case 32: judy''s RPC-style count of a hidden comment should be 0, is %s', n);

    -- 33: a block hides the pair's likes and comments from each other on a
    -- third party's post, in both directions, and from nobody else. dave
    -- blocks erin and follows frank; erin is given a follow of frank for the
    -- case and both react to frank's post 1.
    perform pg_temp.act_as_owner();
    insert into public.follows (follower_id, followee_id) values (erin, frank);
    perform pg_temp.act_as(erin);
    insert into public.comments (post_id, user_id, body) values (frank_post1, erin, 'from erin') returning id into c_temp;
    insert into public.likes (post_id, user_id) values (frank_post1, erin);
    perform pg_temp.act_as(dave);
    insert into public.likes (post_id, user_id) values (frank_post1, dave);
    select count(*) into n from public.comments where post_id = frank_post1;
    assert n = 0, format('case 33: dave (blocker) must not see erin''s comment, sees %s', n);
    select public.post_like_count(p), public.post_comment_count(p) into n, m from public.posts p where p.id = frank_post1;
    assert n = 1 and m = 0, format('case 33: dave''s counts should leave erin out (1 / 0), are %s / %s', n, m);
    begin
        insert into public.comment_likes (comment_id, user_id) values (c_temp, dave);
        raise exception 'case 33: dave liked a comment by someone he blocked';
    exception when insufficient_privilege then
        null;
    end;
    perform pg_temp.act_as(erin);
    select count(*) into n from public.likes where post_id = frank_post1 and user_id = dave;
    assert n = 0, format('case 33: erin (blocked) must not see dave''s like, sees %s', n);
    select public.post_like_count(p) into n from public.posts p where p.id = frank_post1;
    assert n = 1, format('case 33: erin''s like count should leave dave out (1), is %s', n);
    perform pg_temp.act_as(frank);
    select public.post_like_count(p), public.post_comment_count(p) into n, m from public.posts p where p.id = frank_post1;
    assert n = 2 and m = 1, format('case 33: the author should count both (2 / 1), counts %s / %s', n, m);
    perform pg_temp.act_as_owner();
    delete from public.comments where id = c_temp;
    delete from public.likes where post_id = frank_post1;
    delete from public.follows where follower_id = erin and followee_id = frank;

    -- 19: what the world may learn about a code is one enum value (SOL-60).
    -- anon can call invite_status() and nothing else: the table answers no
    -- rows (or refuses outright — either is nothing), and create_invite()
    -- is not executable.
    perform pg_temp.act_as_anon();
    assert public.invite_status('candd-seed2') = 'valid', 'case 19: the seeded valid code should read valid to anon';
    assert public.invite_status('CANDD-SEED3') = 'redeemed', 'case 19: the seeded redeemed code should read redeemed';
    assert public.invite_status('CANDD-SEED4') = 'expired', 'case 19: the seeded expired code should read expired';
    assert public.invite_status('NOPE2-NOPE2') = 'not_found', 'case 19: an unknown code should read not_found';
    begin
        select count(*) into n from public.invites;
        assert n = 0, format('case 19: anon must read no invite rows, reads %s', n);
    exception when insufficient_privilege then
        null;
    end;

    -- 20: invites are readable and revocable by their inviter alone, a
    -- redeemed one is not revocable at all, and nobody inserts rows directly.
    perform pg_temp.act_as(bob);
    select count(*) into n from public.invites where inviter_id = alice;
    assert n = 0, format('case 20: bob must read none of alice''s invites, reads %s', n);
    delete from public.invites where code = 'CANDD-SEED2';
    get diagnostics n = row_count;
    assert n = 0, format('case 20: bob must not revoke alice''s code, deleted %s', n);
    perform pg_temp.act_as(alice);
    select count(*) into n from public.invites where inviter_id = alice;
    assert n = 3, format('case 20: alice should read her 3 invites, reads %s', n);
    delete from public.invites where code = 'CANDD-SEED3';
    get diagnostics n = row_count;
    assert n = 0, format('case 20: a redeemed code must not be deletable, deleted %s', n);
    begin
        insert into public.invites (code, inviter_id) values ('HANDM-ADE22', alice);
        raise exception 'case 20: alice could insert an invite row directly';
    exception when insufficient_privilege then
        null;
    end;

    -- 21: the gate (SOL-61). Without a code, with a used code and with an
    -- expired code the sign-up is refused inside the trigger, and the
    -- auth.users row it was part of goes with it: no orphan, no profile.
    perform pg_temp.act_as_owner();
    declare
        v_code text;
        v_id   uuid;
    begin
        foreach v_code in array array[null, 'CANDD-SEED3', 'CANDD-SEED4'] loop
            v_id := gen_random_uuid();
            begin
                perform pg_temp.sign_up(v_id, 'refused_' || left(replace(v_id::text, '-', ''), 8), v_code);
                raise exception 'case 21: a sign-up with code % was not refused', coalesce(v_code, '(none)');
            exception when check_violation then
                null;
            end;
            assert not exists (select 1 from auth.users where id = v_id),
                format('case 21: the refused sign-up with code %s left an auth.users row', coalesce(v_code, '(none)'));
            assert not exists (select 1 from public.profiles where id = v_id),
                format('case 21: the refused sign-up with code %s left a profile', coalesce(v_code, '(none)'));
        end loop;
    end;

    -- 22: a good code admits the account, spends the code, and makes the pair
    -- friends at once (SOL-62): both edges, the mutuals pair, and — since
    -- can_view_post() reads mutuals — alice's friends-only post on the new
    -- account's very first query, and the new account's post to alice, with
    -- no action from either. The code is typed in lowercase on purpose.
    declare
        v_new uuid := gen_random_uuid();
    begin
        perform pg_temp.sign_up(v_new, 'newcomer', 'candd-seed2');
        assert exists (select 1 from public.profiles where id = v_new and username = 'newcomer'),
            'case 22: the profile should exist';
        assert exists (select 1 from public.invites where code = 'CANDD-SEED2' and redeemed_by = v_new and redeemed_at is not null),
            'case 22: the invite should be redeemed by the new account';
        assert exists (select 1 from public.follows where follower_id = v_new and followee_id = alice),
            'case 22: the newcomer -> alice edge is missing';
        assert exists (select 1 from public.follows where follower_id = alice and followee_id = v_new),
            'case 22: the alice -> newcomer edge is missing';
        assert exists (select 1 from public.mutuals where user_id = v_new and mutual_id = alice),
            'case 22: the pair should be mutual';
        insert into public.posts (user_id, image_path, caption, visibility)
        values (v_new, v_new::text || '/' || gen_random_uuid()::text || '.jpg', 'first post', 'mutuals');

        perform pg_temp.act_as(v_new);
        select count(*) into n from public.posts where user_id = alice;
        assert n = 3, format('case 22: the newcomer should see all 3 of alice''s posts on the first query, sees %s', n);
        select count(*) into n from public.posts;
        assert n = 4, format('case 22: the newcomer''s first feed should hold 4 rows (alice''s 3 plus their own), holds %s', n);
        perform pg_temp.act_as(alice);
        select count(*) into n from public.posts where user_id = v_new;
        assert n = 1, format('case 22: alice should see the newcomer''s friends-only post without acting, sees %s', n);
        select f.followers, f.following into n, m from public.follow_counts(v_new) f;
        assert n = 1 and m = 1, format('case 22: follow_counts(newcomer) should be 1 / 1, is %s / %s', n, m);

        -- Single use: the same code is refused a second time, and reads as
        -- redeemed to the world.
        perform pg_temp.act_as_owner();
        begin
            perform pg_temp.sign_up(gen_random_uuid(), 'newcomer2', 'CANDD-SEED2');
            raise exception 'case 22: the redeemed code was accepted a second time';
        exception when check_violation then
            null;
        end;
        assert public.invite_status('CANDD-SEED2') = 'redeemed', 'case 22: the used code should now read redeemed';

        -- Nothing about the edge is special: the newcomer can unfollow it.
        perform pg_temp.act_as(v_new);
        delete from public.follows where follower_id = v_new and followee_id = alice;
        get diagnostics n = row_count;
        assert n = 1, format('case 22: the newcomer should be able to unfollow alice, deleted %s', n);
    end;

    -- 23: the quota (SOL-60), counted server-side as redeemed plus
    -- outstanding unexpired codes. alice has used two of five — CANDD-SEED2
    -- and SEED3 redeemed, SEED4 expired and returned — so three more mint,
    -- the fourth is refused, and revoking one gives its slot back.
    perform pg_temp.act_as(alice);
    for i in 1..3 loop
        select code into msg from public.create_invite();
        assert msg ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{5}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{5}$',
            format('case 23: minted code %s is not in the expected shape', msg);
    end loop;
    begin
        perform public.create_invite();
        raise exception 'case 23: a sixth invite was minted past the quota';
    exception when check_violation then
        get stacked diagnostics msg = message_text;
        assert msg = 'invite quota reached', format('case 23: unexpected refusal: %s', msg);
    end;
    delete from public.invites
    where code = (
        select code from public.invites
        where inviter_id = alice and redeemed_at is null and (expires_at is null or expires_at > now())
        order by created_at desc limit 1
    );
    get diagnostics n = row_count;
    assert n = 1, format('case 23: alice should revoke one of her unredeemed codes, deleted %s', n);
    perform public.create_invite();
    select count(*) into n from public.invites
    where inviter_id = alice and (redeemed_at is not null or expires_at is null or expires_at > now());
    assert n = 5, format('case 23: alice should be at exactly 5 slots used again, is at %s', n);
    perform pg_temp.act_as_owner();

    -- 24: changeable usernames (SOL-41). One change per 30 days; a released
    -- name is reserved from everyone else for 90 days — at the trigger, to
    -- username_available() and to a sign-up alike — and always reclaimable
    -- by its owner; an old handle resolves to the current profile, except
    -- for someone the owner has blocked; history is the owner's alone.
    perform pg_temp.act_as(alice);
    update public.profiles set username = 'alice' where id = alice;
    get diagnostics n = row_count;
    assert n = 1, 'case 24: a no-op rename should pass';
    select count(*) into n from public.username_history where profile_id = alice;
    assert n = 0, format('case 24: a no-op rename must not write history, wrote %s', n);
    update public.profiles set username = 'alice_renamed' where id = alice;
    get diagnostics n = row_count;
    assert n = 1, format('case 24: alice should rename herself, updated %s', n);
    assert (select username from public.profiles where id = alice) = 'alice_renamed', 'case 24: the new name should be stored';
    select count(*) into n from public.username_history where profile_id = alice and username = 'alice';
    assert n = 1, format('case 24: the old name should be in history once, is there %s times', n);
    begin
        update public.profiles set username = 'alice_again' where id = alice;
        raise exception 'case 24: a second rename inside 30 days was allowed';
    exception when check_violation then
        get stacked diagnostics msg = message_text;
        assert msg ~ 'changed again on \d{4}-\d{2}-\d{2}$', format('case 24: unexpected refusal: %s', msg);
    end;
    perform pg_temp.act_as(bob);
    begin
        update public.profiles set username = 'alice' where id = bob;
        raise exception 'case 24: bob took a name released a moment ago';
    exception when unique_violation then
        null;
    end;
    perform pg_temp.act_as_anon();
    assert not public.username_available('alice'), 'case 24: a released name should read unavailable to anon';
    assert public.username_available('alice_fresh'), 'case 24: an unused name should read available';
    perform pg_temp.act_as_owner();
    select code into msg from public.invites
    where inviter_id = alice and redeemed_at is null and (expires_at is null or expires_at > now())
    limit 1;
    declare
        v_id uuid := gen_random_uuid();
    begin
        begin
            perform pg_temp.sign_up(v_id, 'alice', msg);
            raise exception 'case 24: a sign-up took a name released a moment ago';
        exception when unique_violation then
            null;
        end;
        assert not exists (select 1 from auth.users where id = v_id), 'case 24: the refused sign-up left an auth.users row';
        assert (select redeemed_at from public.invites where code = msg) is null, 'case 24: the refused sign-up must not have spent the code';
    end;
    -- The owner's own old name is theirs; only the rate limit stands in the
    -- way, so the change is backdated past it.
    update public.username_history set changed_at = changed_at - interval '31 days' where profile_id = alice;
    perform pg_temp.act_as(alice);
    assert public.username_available('alice'), 'case 24: the owner should see their released name as available';
    update public.profiles set username = 'alice' where id = alice;
    get diagnostics n = row_count;
    assert n = 1, format('case 24: alice should take her old name back, updated %s', n);
    perform pg_temp.act_as(carol);
    select count(*) into n from public.resolve_username('alice_renamed') r where r.id = alice and r.username = 'alice';
    assert n = 1, format('case 24: the old handle should resolve to alice''s current profile, resolved %s', n);
    select count(*) into n from public.resolve_username(' ALICE ') r where r.id = alice;
    assert n = 1, format('case 24: the current handle should resolve, resolved %s', n);
    select count(*) into n from public.resolve_username('nobody_here');
    assert n = 0, format('case 24: an unknown handle should resolve to nothing, resolved %s', n);
    select count(*) into n from public.username_history where profile_id = alice;
    assert n = 0, format('case 24: carol must read none of alice''s history, reads %s', n);
    perform pg_temp.act_as_owner();
    insert into public.blocks (blocker_id, blocked_id) values (alice, judy);
    perform pg_temp.act_as(judy);
    select count(*) into n from public.resolve_username('alice_renamed');
    assert n = 0, format('case 24: someone alice blocked must resolve nothing, resolved %s', n);
    perform pg_temp.act_as_owner();
    delete from public.blocks where blocker_id = alice and blocked_id = judy;

    -- 25: search (SOL-39). searchable_profiles leaves out the caller and the
    -- caller's blocks, and runs under the profiles policy, which hides anyone
    -- who blocked the caller — so dave and erin never see each other, from
    -- either seat, and nobody is a result of their own search. Exact names
    -- rather than prefixes here, since real accounts share the table.
    perform pg_temp.act_as(erin);
    select count(*) into n from public.searchable_profiles where username = 'dave';
    assert n = 0, format('case 25: erin (blocked by dave) must not find dave, finds %s', n);
    perform pg_temp.act_as(dave);
    select count(*) into n from public.searchable_profiles where username = 'erin';
    assert n = 0, format('case 25: dave must not find erin, whom he blocked, finds %s', n);
    select count(*) into n from public.searchable_profiles where username = 'dave';
    assert n = 0, format('case 25: dave must not find himself, finds %s', n);
    perform pg_temp.act_as(carol);
    assert exists (select 1 from public.searchable_profiles where username like 'ali%' and id = alice),
        'case 25: carol should find alice by prefix';
    select count(*) into n from public.searchable_profiles where username = 'carol';
    assert n = 0, format('case 25: carol must not find herself, finds %s', n);
    select count(*) into n from public.searchable_profiles where username = 'dave';
    assert n = 1, format('case 25: carol should find dave, whom nobody involved has blocked, finds %s', n);
    select count(*) into n from public.searchable_profiles where username = 'erin';
    assert n = 1, format('case 25: carol should find erin too, finds %s', n);
    perform pg_temp.act_as_anon();
    begin
        select count(*) into n from public.searchable_profiles;
        assert n = 0, format('case 25: anon must get nothing from the view, gets %s', n);
    exception when insufficient_privilege then
        null;
    end;
    perform pg_temp.act_as_owner();

    -- 10: breaking mutuality takes effect at once — bob's mutuals post leaves
    -- alice's view the moment bob stops following her, while his followers
    -- posts stay, since alice still follows him.
    perform pg_temp.act_as_owner();
    delete from public.follows where follower_id = bob and followee_id = alice;
    select count(*) into n from public.mutuals;
    assert n = 0, format('case 10: mutuals should be empty once bob unfollows alice, has %s rows', n);
    perform pg_temp.act_as(alice);
    select count(*) into n from public.posts where user_id = bob and visibility = 'mutuals';
    assert n = 0, format('case 10: alice must no longer see bob''s mutuals post, sees %s', n);
    select count(*) into n from public.posts where user_id = bob and visibility = 'followers';
    assert n = 2, format('case 10: alice should still see bob''s 2 followers posts, sees %s', n);

    -- 17: deleting a post (SOL-38). Only the author's own rows match the
    -- delete policy — anyone else's delete affects nothing, with no error —
    -- and the storage guard (20260904160000) refuses the object for as long
    -- as a row references it, which is what forces "row first, then object".
    -- The object row from case 8 stands in for alice's mutuals image. The
    -- hosted project's storage.protect_delete() trigger refuses any direct
    -- SQL delete on storage tables unless this setting is on — the Storage
    -- API sets it for its own deletes — so it is set here, for this
    -- transaction only, to let the *policy* be the thing under test.
    perform pg_temp.act_as_owner();
    perform set_config('storage.allow_delete_query', 'true', true);
    perform pg_temp.act_as(bob);
    delete from public.posts where user_id = alice and visibility = 'mutuals';
    get diagnostics n = row_count;
    assert n = 0, format('case 17: bob must not delete alice''s post, deleted %s', n);
    perform pg_temp.act_as(alice);
    delete from storage.objects where name = alice_mutuals_path;
    get diagnostics n = row_count;
    assert n = 0, format('case 17: the object must stay while its post exists, but %s row(s) went', n);
    delete from public.posts where user_id = alice and visibility = 'mutuals';
    get diagnostics n = row_count;
    assert n = 1, format('case 17: alice should delete her own post, deleted %s', n);
    -- SOL-88: the post's likes and comments went with it — bob's seeded like
    -- and his comment on the mutuals post.
    perform pg_temp.act_as_owner();
    select count(*) into n from public.likes where post_id = alice_mutuals_post;
    assert n = 0, format('case 17: the deleted post''s likes should cascade, %s left', n);
    select count(*) into n from public.comments where post_id = alice_mutuals_post;
    assert n = 0, format('case 17: the deleted post''s comments should cascade, %s left', n);
    perform pg_temp.act_as(alice);
    delete from storage.objects where name = alice_mutuals_path;
    get diagnostics n = row_count;
    assert n = 1, format('case 17: with the row gone alice should delete the object, deleted %s', n);
    select count(*) into n from public.posts where user_id = alice;
    assert n = 2, format('case 17: alice should have 2 posts left, has %s', n);

    -- 27: column grants (SOL-68). Table-level grants gave every authenticated
    -- user every privilege on every column of a row RLS let them touch at
    -- all; only row scoping ever narrowed it. This is the behavioural half —
    -- an attempted write refused; the Exposure block below asserts the
    -- grants themselves. Placed here, before case 26 deletes alice's
    -- account, so alice is still a normal profile for the reports check.
    perform pg_temp.act_as(bob);
    begin
        update public.profiles set invite_quota = 99 where id = bob;
        raise exception 'case 27: bob raised his own invite quota';
    exception when insufficient_privilege then
        null;
    end;
    begin
        insert into public.posts (user_id, image_path, visibility, created_at)
        values (bob, bob::text || '/' || gen_random_uuid()::text || '.jpg', 'followers', now() + interval '10 years');
        raise exception 'case 27: bob dated his own post ten years into the future';
    exception when insufficient_privilege then
        null;
    end;
    perform pg_temp.act_as(carol);
    begin
        insert into public.reports (reporter_id, reported_profile_id, reason, status)
        values (carol, alice, 'spam', 'actioned');
        raise exception 'case 27: carol pre-marked her own report actioned';
    exception when insufficient_privilege then
        null;
    end;
    perform pg_temp.act_as(bob);
    update public.profiles set username = 'bob_renamed' where id = bob;
    get diagnostics n = row_count;
    assert n = 1, format('case 27: bob should still be able to rename himself, updated %s row(s)', n);

    -- 26: reports (SOL-42). Insert-only, and only what the reporter could see:
    -- the reporter is the caller, a reported post must pass can_view_post(),
    -- the person is filled from the post, a repeat is a unique violation the
    -- client treats as success, and nobody reads the table — while deleting a
    -- reported post leaves the report, about the person, without tripping the
    -- one-per-person uniqueness. Runs after 17, so alice still has two
    -- followers posts carol can see; bob's friends-only post is one she can't.
    declare
        v_visible uuid;
        v_hidden  uuid;
    begin
        -- Fetched as owner, deliberately: by this point case 10 has broken
        -- bob and alice's mutual follow, so whichever role happened to be
        -- active last (an accident of the case run immediately before this
        -- one) might not itself be able to see one or both of these posts.
        -- A SELECT INTO that finds nothing assigns NULL rather than raising,
        -- and a null reported_post_id trivially satisfies the insert policy's
        -- "reported_post_id is null or can_view_post(...)" check below — so
        -- a role-dependent NULL here would silently turn every assertion in
        -- this case into a false pass. Found the hard way (SOL-81's first
        -- real CI run): case 27, added later, changed which role was last
        -- active and flipped which sub-case went silently green.
        perform pg_temp.act_as_owner();
        select id into v_visible from public.posts where user_id = alice and visibility = 'followers' order by created_at limit 1;
        select id into v_hidden from public.posts where user_id = bob and visibility = 'mutuals';
        assert v_visible is not null, 'case 26 precondition: v_visible did not resolve to a real post';
        assert v_hidden is not null, 'case 26 precondition: v_hidden did not resolve to a real post';
        perform pg_temp.act_as(carol);
        -- The wrong person on purpose: the trigger fills the author.
        insert into public.reports (reporter_id, reported_profile_id, reported_post_id, reason, details)
        values (carol, bob, v_visible, 'spam', 'seed spam');
        begin
            insert into public.reports (reporter_id, reported_profile_id, reported_post_id, reason) values (carol, alice, v_visible, 'hate');
            raise exception 'case 26: a repeat report of the same post was accepted';
        exception when unique_violation then
            null;
        end;
        begin
            insert into public.reports (reporter_id, reported_profile_id, reported_post_id, reason) values (carol, bob, v_hidden, 'spam');
            raise exception 'case 26: carol reported a post she cannot see';
        exception when insufficient_privilege then
            null;
        end;
        begin
            -- SOL-82: a post id that matches nothing refuses exactly like a
            -- hidden one (42501, not the old foreign_key_violation) — the
            -- table cannot be used to tell "doesn't exist" apart from
            -- "exists but hidden".
            insert into public.reports (reporter_id, reported_profile_id, reported_post_id, reason)
            values (carol, bob, gen_random_uuid(), 'spam');
            raise exception 'case 26: carol reported a nonexistent post';
        exception when insufficient_privilege then
            null;
        end;
        insert into public.reports (reporter_id, reported_profile_id, reason) values (carol, alice, 'impersonation');
        begin
            insert into public.reports (reporter_id, reported_profile_id, reason) values (carol, alice, 'other');
            raise exception 'case 26: a repeat report of the same person was accepted';
        exception when unique_violation then
            null;
        end;
        begin
            insert into public.reports (reporter_id, reported_profile_id, reason) values (carol, carol, 'other');
            raise exception 'case 26: carol reported herself';
        exception when check_violation then
            null;
        end;
        begin
            insert into public.reports (reporter_id, reported_profile_id, reason) values (alice, carol, 'other');
            raise exception 'case 26: carol filed a report as someone else';
        exception when insufficient_privilege then
            null;
        end;
        begin
            -- A report has to be about something. SOL-82 made
            -- reported_profile_id nullable for the on-delete cascade, which
            -- let a raw client file a report with neither target: the
            -- policy short-circuits on a null post, reports_not_self is not
            -- false against NULL, and both partial unique indexes treat NULL
            -- as distinct. fill_reported_profile() refuses it on insert
            -- (20260905160000); the cascade, an UPDATE, never meets that
            -- check — the SOL-82 assertion at the end of this case, which
            -- deletes alice and expects both reports to survive with null
            -- targets, is the proof that a CHECK here would have broken.
            insert into public.reports (reporter_id, reason) values (carol, 'other');
            raise exception 'case 26: carol filed a report about nothing';
        exception when check_violation then
            null;
        end;
        select count(*) into n from public.reports;
        assert n = 0, format('case 26: the reporter must not read reports, reads %s', n);
        perform pg_temp.act_as(alice);
        select count(*) into n from public.reports;
        assert n = 0, format('case 26: the reported account must not read reports, reads %s', n);
        perform pg_temp.act_as_anon();
        begin
            insert into public.reports (reporter_id, reported_profile_id, reason) values (carol, alice, 'other');
            raise exception 'case 26: anon filed a report';
        exception when insufficient_privilege then
            null;
        end;
        perform pg_temp.act_as_owner();
        select count(*) into n from public.reports where reporter_id = carol and reported_profile_id = alice;
        assert n = 2, format('case 26: carol should have 2 reports about alice (a post and the person), has %s', n);
        assert exists (select 1 from public.reports where reporter_id = carol and reported_post_id = v_visible and reported_profile_id = alice and about_post and details = 'seed spam'),
            'case 26: the post report should name alice, filled from the post';
        perform pg_temp.act_as(alice);
        delete from public.posts where id = v_visible;
        get diagnostics n = row_count;
        assert n = 1, format('case 26: alice should still be able to delete a reported post, deleted %s', n);
        perform pg_temp.act_as_owner();
        assert exists (select 1 from public.reports where reporter_id = carol and reported_profile_id = alice and about_post and reported_post_id is null),
            'case 26: the report should outlive the post, about the person';
        assert not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'reports' and cmd <> 'INSERT'),
            'structure: reports must have insert policies only';

        -- SOL-82: reports outlive the reported account, not just the
        -- reported post. reported_profile_id is `on delete set null` now
        -- (was cascade); deleting alice the way auth.users itself is torn
        -- down (see seed.sql) must null it on both of carol's reports about
        -- her rather than deleting the rows.
        delete from auth.users where id = alice;
        select count(*) into n from public.reports
        where reporter_id = carol and reported_profile_id is null;
        assert n = 2, format('case 26: both of carol''s reports about alice should survive with reported_profile_id null, has %s', n);
        -- SOL-88: the account's own likes and comments went with it.
        select count(*) into n from public.likes where user_id = alice;
        assert n = 0, format('case 26: alice''s likes should cascade with her account, %s left', n);
        select count(*) into n from public.comments where user_id = alice;
        assert n = 0, format('case 26: alice''s comments should cascade with her account, %s left', n);
    end;

    -- 28: per-account storage cap (20260905171000). The bucket bounds each
    -- object at 5 MB and image/jpeg; this bounds how many. Runs as judy,
    -- whose folder nothing else touches, inserting stand-in rows the way
    -- case 8 does — storage-api inserts one row per upload as the caller
    -- under RLS, which is exactly this. Reads the cap from the function, so
    -- changing the number changes the test. About a thousand inserts; a
    -- second or two.
    perform pg_temp.act_as(judy);
    select count(*) into n from storage.objects where name like judy::text || '/%';
    assert n = 0, format('case 28 precondition: judy should hold no objects, holds %s', n);
    for i in 1..private.post_image_cap() loop
        insert into storage.objects (bucket_id, name, owner, owner_id)
        values ('post-images', judy::text || '/' || gen_random_uuid()::text || '.jpg', judy, judy::text);
    end loop;
    -- The helper counts as its owner, and what lets that see the whole folder
    -- is postgres having BYPASSRLS — it does not own storage.objects. Were
    -- that ever untrue the count would read 0 and the cap would silently
    -- never bind, so it is checked against what the loop inserted.
    assert private.own_post_image_count() = private.post_image_cap(),
        format('case 28: the cap helper counts %s objects, the loop inserted %s', private.own_post_image_count(), private.post_image_cap());
    begin
        insert into storage.objects (bucket_id, name, owner, owner_id)
        values ('post-images', judy::text || '/' || gen_random_uuid()::text || '.jpg', judy, judy::text);
        raise exception 'case 28: judy stored an object past the cap';
    exception when insufficient_privilege then
        get stacked diagnostics msg = message_text;
        assert msg ilike '%row-level security%', format('case 28: unexpected refusal: %s', msg);
    end;
    -- The cap is per account: bob is unaffected by judy's folder being full.
    perform pg_temp.act_as(bob);
    insert into storage.objects (bucket_id, name, owner, owner_id)
    values ('post-images', bob::text || '/' || gen_random_uuid()::text || '.jpg', bob, bob::text);

    -- Exposure: the rule is callable from policies, and from nowhere the API
    -- reaches.
    perform pg_temp.act_as_owner();
    assert not has_schema_privilege('anon', 'private', 'usage'),
        'exposure: anon has usage on private';
    assert not has_function_privilege('anon', 'private.can_view_post(uuid,uuid,public.post_visibility)', 'execute'),
        'exposure: anon can execute can_view_post';
    assert not has_function_privilege('anon', 'private.can_view_post(uuid,uuid)', 'execute'),
        'exposure: anon can execute can_view_post (by id)';
    assert not has_function_privilege('anon', 'private.can_view_image(uuid,text)', 'execute'),
        'exposure: anon can execute can_view_image';
    assert not has_function_privilege('anon', 'private.is_blocked_by(uuid,uuid)', 'execute'),
        'exposure: anon can execute is_blocked_by';
    assert not has_function_privilege('anon', 'private.is_mutual(uuid,uuid)', 'execute'),
        'exposure: anon can execute is_mutual';
    assert not has_function_privilege('anon', 'public.follow_counts(uuid)', 'execute'),
        'exposure: anon can execute follow_counts';
    assert has_function_privilege('authenticated', 'public.follow_counts(uuid)', 'execute'),
        'exposure: authenticated cannot execute follow_counts';
    assert has_function_privilege('anon', 'public.invite_status(text)', 'execute'),
        'exposure: anon cannot execute invite_status, so the sign-up form cannot check a code';
    assert not has_function_privilege('anon', 'public.create_invite()', 'execute'),
        'exposure: anon can execute create_invite';
    assert has_function_privilege('authenticated', 'public.create_invite()', 'execute'),
        'exposure: authenticated cannot execute create_invite';
    assert not has_function_privilege('anon', 'public.handle_new_user()', 'execute'),
        'exposure: anon can execute handle_new_user';
    assert not has_function_privilege('anon', 'public.resolve_username(text)', 'execute'),
        'exposure: anon can execute resolve_username';
    assert has_function_privilege('authenticated', 'public.resolve_username(text)', 'execute'),
        'exposure: authenticated cannot execute resolve_username';
    assert has_function_privilege('anon', 'public.username_available(text)', 'execute'),
        'exposure: anon cannot execute username_available, so sign-up cannot check a name';
    assert not has_function_privilege('anon', 'public.enforce_username_rules()', 'execute'),
        'exposure: anon can execute enforce_username_rules';
    assert not has_function_privilege('anon', 'public.fill_reported_profile()', 'execute'),
        'exposure: anon can execute fill_reported_profile';
    assert has_function_privilege('authenticated', 'private.can_view_post(uuid,uuid,public.post_visibility)', 'execute'),
        'exposure: authenticated cannot execute can_view_post';

    -- SOL-69: image_is_referenced() moved to private; anon never gets it,
    -- and the old public copy is gone rather than left as a dangling name.
    assert not has_function_privilege('anon', 'private.image_is_referenced(text)', 'execute'),
        'exposure: anon can execute image_is_referenced';
    assert has_function_privilege('authenticated', 'private.image_is_referenced(text)', 'execute'),
        'exposure: authenticated cannot execute image_is_referenced';
    assert not exists (
        select 1 from pg_proc where proname = 'image_is_referenced' and pronamespace = 'public'::regnamespace
    ), 'exposure: image_is_referenced still has a copy in public';

    -- 20260905171000: the storage cap's two helpers, private like every other
    -- policy helper. The count reads auth.uid() itself, so even its caller
    -- can only ever count their own folder.
    assert not has_function_privilege('anon', 'private.own_post_image_count()', 'execute'),
        'exposure: anon can execute own_post_image_count';
    assert has_function_privilege('authenticated', 'private.own_post_image_count()', 'execute'),
        'exposure: authenticated cannot execute own_post_image_count, so no upload can pass the policy';
    assert not has_function_privilege('anon', 'private.post_image_cap()', 'execute'),
        'exposure: anon can execute post_image_cap';

    -- SOL-88: the comment helper stays in private; the five computed columns
    -- are callable by authenticated in public, because a select on posts or
    -- comments has to be able to evaluate them.
    assert not has_function_privilege('anon', 'private.can_view_comment(uuid,uuid)', 'execute'),
        'exposure: anon can execute can_view_comment';
    assert has_function_privilege('authenticated', 'private.can_view_comment(uuid,uuid)', 'execute'),
        'exposure: authenticated cannot execute can_view_comment';
    assert not has_function_privilege('anon', 'public.post_like_count(public.posts)', 'execute'),
        'exposure: anon can execute post_like_count';
    assert has_function_privilege('authenticated', 'public.post_like_count(public.posts)', 'execute'),
        'exposure: authenticated cannot execute post_like_count, so the feed select fails';
    assert has_function_privilege('authenticated', 'public.post_comment_count(public.posts)', 'execute'),
        'exposure: authenticated cannot execute post_comment_count';
    assert has_function_privilege('authenticated', 'public.post_liked_by_viewer(public.posts)', 'execute'),
        'exposure: authenticated cannot execute post_liked_by_viewer';
    assert has_function_privilege('authenticated', 'public.comment_like_count(public.comments)', 'execute'),
        'exposure: authenticated cannot execute comment_like_count';
    assert has_function_privilege('authenticated', 'public.comment_liked_by_viewer(public.comments)', 'execute'),
        'exposure: authenticated cannot execute comment_liked_by_viewer';
    assert not has_function_privilege('anon', 'public.comment_like_count(public.comments)', 'execute'),
        'exposure: anon can execute comment_like_count';
    assert not has_column_privilege('authenticated', 'public.likes', 'created_at', 'INSERT'),
        'exposure: authenticated can insert likes.created_at';
    assert not has_column_privilege('authenticated', 'public.comments', 'id', 'INSERT'),
        'exposure: authenticated can insert comments.id';
    assert not has_column_privilege('authenticated', 'public.comments', 'created_at', 'INSERT'),
        'exposure: authenticated can insert comments.created_at';
    assert has_column_privilege('authenticated', 'public.comments', 'body', 'INSERT'),
        'exposure: authenticated lost insert on comments.body';
    assert not has_column_privilege('authenticated', 'public.comment_likes', 'created_at', 'INSERT'),
        'exposure: authenticated can insert comment_likes.created_at';
    assert not has_table_privilege('authenticated', 'public.comments', 'UPDATE'),
        'exposure: comments are updatable';
    assert not exists (
        select 1 from pg_policies
        where schemaname = 'public' and tablename in ('likes', 'comments', 'comment_likes') and cmd = 'UPDATE'
    ), 'structure: likes, comments and comment_likes must have no update policy';

    -- SOL-68: the column-level grants that replaced "every column in your
    -- own row is writable". Case 27 demonstrates the same facts as refused
    -- writes rather than asserted privileges.
    assert not has_column_privilege('authenticated', 'public.profiles', 'invite_quota', 'UPDATE'),
        'exposure: authenticated can still update profiles.invite_quota';
    assert has_column_privilege('authenticated', 'public.profiles', 'username', 'UPDATE'),
        'exposure: authenticated lost update on profiles.username';
    assert not has_column_privilege('authenticated', 'public.posts', 'created_at', 'INSERT'),
        'exposure: authenticated can still insert posts.created_at';
    assert not has_column_privilege('authenticated', 'public.reports', 'status', 'INSERT'),
        'exposure: authenticated can still insert reports.status';
    assert not has_table_privilege('anon', 'public.posts', 'SELECT'),
        'exposure: anon still holds a table-level grant on posts';
    assert not has_table_privilege('authenticated', 'public.mutuals', 'INSERT'),
        'exposure: authenticated can still write to the mutuals view';

    -- Structure: the two keyset indexes the feed and the profile grid page on.
    assert exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'posts_created_at_id_idx'),
        'structure: posts_created_at_id_idx is missing';
    assert exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'posts_user_id_created_at_id_idx'),
        'structure: posts_user_id_created_at_id_idx is missing';
    assert not exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'posts_user_id_created_at_idx'),
        'structure: the old per-author index posts_user_id_created_at_idx should be gone';
    assert exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'profiles_username_pattern_idx'),
        'structure: profiles_username_pattern_idx is missing, so a prefix search is a scan';
    -- SOL-88: the thread's order, and the cascades from profiles.
    assert exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'comments_post_id_created_at_id_idx'),
        'structure: comments_post_id_created_at_id_idx is missing, so a thread is a sort';
    assert exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'likes_user_id_idx'),
        'structure: likes_user_id_idx is missing';
    assert exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'comment_likes_user_id_idx'),
        'structure: comment_likes_user_id_idx is missing';

    -- Grant hygiene (20260905170000): authenticated holds no privilege a
    -- policy does not use. Every app insert is column-level and the only
    -- update is profiles.username, so neither appears here at table level
    -- at all — information_schema.role_table_grants lists table-level
    -- privileges only. A future table that keeps the defaults, or a future
    -- policy added without its grant, fails here rather than in the app.
    assert not exists (
        select 1 from information_schema.role_table_grants
        where table_schema = 'public' and grantee = 'anon'
    ), 'exposure: anon holds a table-level grant in public';
    assert not exists (
        select 1 from information_schema.role_table_grants
        where table_schema = 'public' and grantee = 'authenticated'
          and privilege_type in ('TRUNCATE', 'TRIGGER', 'REFERENCES', 'INSERT', 'UPDATE')
    ), 'exposure: authenticated holds a table-level TRUNCATE, TRIGGER, REFERENCES, INSERT or UPDATE in public';
    assert not exists (
        select 1 from information_schema.role_table_grants
        where table_schema = 'public' and grantee = 'authenticated'
          and privilege_type = 'DELETE'
          and table_name not in ('posts', 'follows', 'blocks', 'invites', 'likes', 'comments', 'comment_likes')
    ), 'exposure: authenticated can delete from a table the app never deletes from';
    -- The defaults themselves, for the role that runs migrations: a table
    -- created without an explicit grant must start closed.
    assert not exists (
        select 1
        from pg_default_acl d
        join pg_namespace n on n.oid = d.defaclnamespace
        cross join lateral aclexplode(d.defaclacl) as a
        where n.nspname = 'public' and d.defaclobjtype = 'r'
          and d.defaclrole = 'postgres'::regrole
          and a.grantee in ('anon'::regrole::oid, 'authenticated'::regrole::oid)
    ), 'exposure: default privileges for postgres in public still grant anon or authenticated on new tables';
    -- And for functions, including the implicit grant to PUBLIC (grantee 0):
    -- a new function must be closed until its migration opens it.
    assert not exists (
        select 1
        from pg_default_acl d
        join pg_namespace n on n.oid = d.defaclnamespace
        cross join lateral aclexplode(d.defaclacl) as a
        where n.nspname = 'public' and d.defaclobjtype = 'f'
          and d.defaclrole = 'postgres'::regrole
          and a.grantee in (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid)
    ), 'exposure: default privileges for postgres in public still grant execute on new functions to public, anon or authenticated';

    -- Views run as the caller, or RLS on their base tables would not apply:
    -- a plain view runs as its owner, and the owner of every table here
    -- bypasses RLS. Both existing views say security_invoker; any new one
    -- must too.
    assert not exists (
        select 1 from pg_class c
        where c.relkind = 'v' and c.relnamespace = 'public'::regnamespace
          and not coalesce(c.reloptions, '{}') @> array['security_invoker=true']
    ), 'structure: a view in public is not security_invoker and would bypass RLS on its base tables';
end;
$$;

select 'all checks passed' as result;

rollback;
