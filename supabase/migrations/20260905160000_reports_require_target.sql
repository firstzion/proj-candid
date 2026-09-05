-- A report has to be about something: a post, a person, or both.
--
-- 20260905022000 (SOL-82) dropped NOT NULL on reports.reported_profile_id so
-- that deleting the reported account sets it null instead of taking the report
-- with it. That was the intent; it also let a client file a report with
-- *neither* target set. Confirmed live on 2026-09-05, as alice, inside a
-- rolled-back transaction: two rows with reported_profile_id and
-- reported_post_id both null were accepted. Every guard lets it through in
-- turn — the insert policy's WITH CHECK short-circuits on `reported_post_id
-- is null`; fill_reported_profile() only looks anything up when there is a
-- post; reports_not_self compares reporter_id <> NULL, which is not false;
-- and both partial unique indexes treat NULL as distinct, so there is no
-- one-per-anything to trip. Unbounded rows about nobody, into the one table
-- a moderation queue (SOL-45) will read.
--
-- The app cannot send this — ReportService's NewReport carries a non-optional
-- reported_profile_id — so this closes a raw-client path, not a bug anyone
-- has hit through the UI.
--
-- Not a CHECK constraint, on purpose. The whole reason the column is nullable
-- is the `on delete set null` cascade from profiles, and reported_post_id has
-- the same cascade from posts. A report about someone's post, once that
-- someone deletes their account, legitimately ends up with both null — the
-- cascades are UPDATEs, a CHECK would fire on them, and the account deletion
-- would fail. A BEFORE INSERT trigger sees only inserts, so it refuses the
-- client's empty report and never meets the cascade. fill_reported_profile()
-- is already that trigger; the guard is its first statement. The body below
-- is 20260905022000's verbatim, plus that guard.
--
-- check_violation: what the equivalent constraint would have raised, and what
-- reports_not_self raises for the other malformed report.

create or replace function public.fill_reported_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_author uuid;
begin
    if new.reported_post_id is null and new.reported_profile_id is null then
        raise exception 'a report needs a target: a post, a profile, or both'
            using errcode = 'check_violation';
    end if;

    new.about_post := new.reported_post_id is not null;
    if new.about_post then
        select user_id into v_author
        from public.posts
        where id = new.reported_post_id;
        -- A post that no longer resolves keeps the client's own value here
        -- instead of being nulled out by the SELECT INTO above; the insert
        -- policy's can_view_post() check refuses it next, either way.
        new.reported_profile_id := coalesce(v_author, new.reported_profile_id);
    end if;
    return new;
end;
$$;
