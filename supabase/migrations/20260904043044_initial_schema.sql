-- Initial schema for Candid: profiles and posts.
--
-- RLS POLICIES BELOW ARE DEV-ONLY AND MUST BE REVISITED BEFORE ANY REAL
-- DEPLOYMENT. Every authenticated user can currently read every profile and
-- every post. That is fine while the app is a single-developer prototype with
-- a public feed, but Candid is meant to show you your friends' posts, so read
-- access will need to narrow to a follow/friend graph once one exists.


-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------

create table public.profiles (
    id         uuid primary key references auth.users (id) on delete cascade,
    username   text not null unique,
    created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Read: any authenticated user can read any profile (dev-only, see header).
create policy "profiles are readable by authenticated users"
    on public.profiles
    for select
    to authenticated
    using (true);

-- Insert: a user may only create their own profile row. In practice the
-- handle_new_user trigger below does this, but the policy keeps the table
-- honest if a client ever inserts directly.
create policy "users can insert their own profile"
    on public.profiles
    for insert
    to authenticated
    with check (id = (select auth.uid()));

-- Update: a user may only modify their own profile.
create policy "users can update their own profile"
    on public.profiles
    for update
    to authenticated
    using (id = (select auth.uid()))
    with check (id = (select auth.uid()));

-- No delete policy: deletes are denied for everyone. Profiles are removed via
-- the cascade from auth.users.


-- ---------------------------------------------------------------------------
-- posts
-- ---------------------------------------------------------------------------

create table public.posts (
    id         uuid primary key default gen_random_uuid(),
    user_id    uuid not null references public.profiles (id) on delete cascade,
    image_url  text not null,
    caption    text,
    created_at timestamptz not null default now()
);

-- The feed reads posts newest-first (SOL-13), and a profile screen will read
-- one user's posts. Index both access paths up front.
create index posts_created_at_idx on public.posts (created_at desc);
create index posts_user_id_created_at_idx on public.posts (user_id, created_at desc);

alter table public.posts enable row level security;

-- Read: any authenticated user can read any post (dev-only, see header).
create policy "posts are readable by authenticated users"
    on public.posts
    for select
    to authenticated
    using (true);

-- Insert: the row's user_id must be the caller's own id. Without this check an
-- authenticated user could create posts attributed to someone else.
create policy "users can insert their own posts"
    on public.posts
    for insert
    to authenticated
    with check (user_id = (select auth.uid()));

-- Update: a user may only modify their own posts, and may not reassign one to
-- another user.
create policy "users can update their own posts"
    on public.posts
    for update
    to authenticated
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));

-- No delete policy: deletes are denied for everyone. Deleting posts is not in
-- the MVP scope; add a policy when it is.


-- ---------------------------------------------------------------------------
-- Auto-provision a profile whenever an auth user is created
-- ---------------------------------------------------------------------------

-- security definer so the insert runs with the function owner's rights rather
-- than the signing-up user's, who has no session at trigger time.
-- search_path is pinned to empty so a caller cannot shadow the objects
-- referenced below; every name here is schema-qualified.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.profiles (id, username)
    values (
        new.id,
        -- Sign-up passes a username in user metadata (SOL-5). Fall back to a
        -- collision-free placeholder so provisioning never fails the sign-up.
        coalesce(
            nullif(trim(new.raw_user_meta_data ->> 'username'), ''),
            'user_' || replace(new.id::text, '-', '')
        )
    );
    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row
    execute function public.handle_new_user();
