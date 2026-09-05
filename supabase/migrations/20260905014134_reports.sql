-- Reports (SOL-42): capture only. The review surface is SOL-45, deliberately
-- deferred; until it exists, reports accumulate in a table only the owner can
-- read — in the SQL editor — and the README says so.
--
-- A report names a person, always, and optionally one of their posts. The
-- person is filled in from the post's author by a trigger, so the report
-- outlives the post (reported_post_id is `on delete set null`) and the
-- eventual dashboard can group by account. about_post remembers which kind a
-- report was after its post is gone: without it, a post report whose post was
-- deleted would collide with the "one per person" uniqueness below and make
-- deleting one's own post fail.
--
-- Insert-only, and only what the reporter could see: the reporter is the
-- caller, and a reported post must pass can_view_post() for them, so the
-- table cannot be used to probe post ids. No select policy for anyone — not
-- even the reporter — so the reported account learns nothing and the app
-- cannot read reports through the API. A repeat report of the same post or
-- person is refused by a partial unique index, which the client treats as
-- success: the thing asked for already holds.

create type public.report_reason as enum
    ('spam', 'harassment', 'hate', 'nudity', 'violence', 'impersonation', 'other');
create type public.report_status as enum ('open', 'reviewed', 'actioned');

create table public.reports (
    id                  uuid primary key default gen_random_uuid(),
    reporter_id         uuid not null references public.profiles (id) on delete cascade,
    reported_profile_id uuid not null references public.profiles (id) on delete cascade,
    reported_post_id    uuid references public.posts (id) on delete set null,
    about_post          boolean not null default false,
    reason              public.report_reason not null,
    details             text check (char_length(details) <= 500),
    status              public.report_status not null default 'open',
    created_at          timestamptz not null default now(),
    constraint reports_not_self check (reporter_id <> reported_profile_id)
);

create unique index reports_one_per_post
    on public.reports (reporter_id, reported_post_id)
    where reported_post_id is not null;
create unique index reports_one_per_profile
    on public.reports (reporter_id, reported_profile_id)
    where not about_post;
-- What the dashboard (SOL-45) will group by.
create index reports_reported_profile_idx
    on public.reports (reported_profile_id, created_at desc);

alter table public.reports enable row level security;

create policy "users can file their own reports"
    on public.reports
    for insert
    to authenticated
    with check (
        reporter_id = (select auth.uid())
        and (
            reported_post_id is null
            or private.can_view_post((select auth.uid()), reported_post_id)
        )
    );

-- Fills the person from the post and remembers that a post was named.
-- Definer, so the author is read regardless of the reporter's RLS; the policy
-- above still refuses a post the reporter cannot see.
create function public.fill_reported_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    new.about_post := new.reported_post_id is not null;
    if new.about_post then
        select user_id into new.reported_profile_id
        from public.posts
        where id = new.reported_post_id;
        if new.reported_profile_id is null then
            raise exception 'reported post not found' using errcode = 'foreign_key_violation';
        end if;
    end if;
    return new;
end;
$$;

revoke execute on function public.fill_reported_profile() from public, anon, authenticated;

create trigger reports_fill_profile
    before insert on public.reports
    for each row
    execute function public.fill_reported_profile();
