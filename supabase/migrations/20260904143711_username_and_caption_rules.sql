-- Rules for profiles.username and posts.caption.
--
-- username was `text not null unique` and nothing more: case-sensitive, so
-- "Alice" and "alice" could coexist as two different people; unbounded, so a
-- ten-thousand-character name was fine; and unrestricted, so newlines,
-- zero-width characters and right-to-left overrides were all valid. The
-- sign-up trigger stores whatever the metadata carries, so client-side
-- validation alone cannot close this — anyone with the publishable key can
-- call the auth API directly.
--
-- Usernames are now lowercase [a-z0-9_], 3 to 30 characters. Storing only
-- lowercase is what makes uniqueness case-insensitive: the existing unique
-- constraint does the work, with no citext or lower() index needed. The
-- trigger normalises (lower, trim) so a client that forgets still produces a
-- valid row; anything the CHECK then rejects fails the sign-up, which GoTrue
-- reports as its sanitised "Database error saving new user" — so the app
-- mirrors these rules (UsernameRules.swift) and says precisely what is wrong
-- before it ever sends the request.
--
-- caption gets a 2,200-character cap. char_length counts characters, not
-- bytes, and a NULL caption passes a CHECK by definition.
--
-- Existing rows: usernames are lowercased and trimmed first, since that is
-- exactly the normalisation the app now applies everywhere and changes nothing
-- anyone logs in with (accounts log in by email). A row that still violates
-- the CHECK — too long, too short, other characters — fails the migration
-- deliberately rather than being edited by guesswork; fix it by hand and
-- re-run. Two rows that collide after lowercasing fail the UPDATE the same way.

update public.profiles
    set username = lower(trim(username))
    where username <> lower(trim(username));

alter table public.profiles
    add constraint profiles_username_format
    check (username ~ '^[a-z0-9_]{3,30}$');

alter table public.posts
    add constraint posts_caption_length
    check (char_length(caption) <= 2200);


-- The trigger has to produce rows the constraint accepts. It now lowercases
-- and trims the supplied username, and the placeholder for a missing one —
-- previously 'user_' plus the full 32-hex id, 37 characters — is cut to fit:
-- 'user_' plus 25 hex characters of the id, 100 random bits. That is no
-- longer provably unique the way the full id was, but a collision is not a
-- realistic event, and if one ever happened the unique constraint would fail
-- that sign-up loudly rather than corrupt anything.
--
-- CREATE OR REPLACE keeps the function's privileges (EXECUTE was revoked from
-- public, anon and authenticated in an earlier migration) and leaves the
-- trigger attached.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.profiles (id, username)
    values (
        new.id,
        coalesce(
            nullif(lower(trim(new.raw_user_meta_data ->> 'username')), ''),
            'user_' || left(replace(new.id::text, '-', ''), 25)
        )
    );
    return new;
end;
$$;
