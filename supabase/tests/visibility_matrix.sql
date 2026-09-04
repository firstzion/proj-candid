-- Visibility matrix (SOL-30): the authorization rule, checked against the
-- seeded graph from every seat at the table.
--
-- Read-only in effect: everything runs inside one transaction that ends in
-- ROLLBACK, including the temporary rows some cases need. Run it against the
-- hosted project after `supabase db push` and a seed run, with database-owner
-- privileges — the same way the seed itself is run:
--
--   supabase db query --linked -f supabase/tests/visibility_matrix.sql
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
--   each account's post 3 is 'mutuals', posts 1 and 2 are 'followers'.
--
-- Case numbers follow SOL-30's test pass, plus SOL-28's "unfollowing one side
-- removes the pair" (10), the profile and re-follow rules from SOL-31
-- (11, 12) and the feed's own query (13).

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

do $$
declare
    alice constant uuid := '00000000-0000-0000-0000-000000000001';
    bob   constant uuid := '00000000-0000-0000-0000-000000000002';
    carol constant uuid := '00000000-0000-0000-0000-000000000003';
    dave  constant uuid := '00000000-0000-0000-0000-000000000004';
    erin  constant uuid := '00000000-0000-0000-0000-000000000005';
    judy  constant uuid := '00000000-0000-0000-0000-00000000000a';
    n int;
    msg text;
    alice_mutuals_path text;
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
    select image_path into alice_mutuals_path from public.posts where user_id = alice and visibility = 'mutuals';

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
    assert has_function_privilege('authenticated', 'private.can_view_post(uuid,uuid,public.post_visibility)', 'execute'),
        'exposure: authenticated cannot execute can_view_post';
end;
$$;

select 'all checks passed' as result;

rollback;
