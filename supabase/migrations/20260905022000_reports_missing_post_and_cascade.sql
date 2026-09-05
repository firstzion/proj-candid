-- Reports: a missing post refuses the same way a hidden one does, and a
-- deleted account's report history survives it (SOL-82).
--
-- Two design questions in 20260905014134_reports.sql:
--
--   * fill_reported_profile() raised foreign_key_violation (23503) for a
--     reported_post_id that matches nothing, while the insert policy refuses
--     an existing-but-hidden post with insufficient_privilege (42501) — the
--     migration's own comment claims the table "cannot be used to probe post
--     ids", which was only true for hidden-vs-visible, not exists-vs-not.
--     Negligible with random v4 ids as the only ones in play, but the claim
--     should hold. Fixed by leaving reported_profile_id as the client sent
--     it (its own best guess of the author, from whatever post data it last
--     loaded) when the lookup finds nothing, rather than raising:
--     private.can_view_post() already returns false for a post that does not
--     exist (20260904200800), so the insert policy's own WITH CHECK refuses
--     it with 42501 — identical to a hidden post, for the same reason. A
--     plain `select ... into new.reported_profile_id` would instead have
--     overwritten the client's value with NULL on no match (SELECT INTO
--     always assigns, even to nothing) and traded one distinguishable error
--     for another — a NOT NULL violation instead of the FK one — which is
--     why the lookup below goes through a local variable and a coalesce
--     rather than assigning straight into NEW.
--
--   * reported_profile_id was `on delete cascade`: deleting the reported
--     account deleted every report about it, so until SOL-45's moderation
--     dashboard exists, an account can erase its own report history by
--     deleting itself. Changed to `on delete set null` — abuse history
--     should outlive the account it is about, the same way reported_post_id
--     already outlives its post. reports_one_per_profile (the partial unique
--     index on (reporter_id, reported_profile_id) where not about_post) and
--     reports_not_self both tolerate a null reported_profile_id without
--     changes. reporter_id stays `on delete cascade`: a reporter leaving
--     takes their own reports with them, which SOL-82 leaves alone.

create or replace function public.fill_reported_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_author uuid;
begin
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

alter table public.reports
    drop constraint reports_reported_profile_id_fkey,
    alter column reported_profile_id drop not null,
    add constraint reports_reported_profile_id_fkey
        foreign key (reported_profile_id) references public.profiles (id) on delete set null;
