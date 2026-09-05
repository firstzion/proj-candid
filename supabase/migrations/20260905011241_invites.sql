-- Invite-only onboarding (SOL-60, SOL-61, SOL-62): the table, the gate, and
-- the two edges — one migration, because they are one transaction.
--
-- SOL-43 decided that Candid grows by invitation: a new account needs a code
-- from an existing one, and redeeming it makes the pair friends at once, so
-- nobody's first feed is empty. Three pieces, each explained where it lives:
--
--   * invites, and profiles.invite_quota — who has minted what for whom, and
--     how many each account may (SOL-60).
--   * create_invite() and invite_status() — the only two ways in: one mints
--     a code for a signed-in user, the other answers a single enum value to
--     anyone, signed in or not, about a code they already hold (SOL-60).
--   * handle_new_user() — the sign-up trigger, which already creates the
--     profile inside GoTrue's insert, now also requires and consumes the
--     code and writes the follow edges in both directions (SOL-61, SOL-62).
--     A refusal there rolls back GoTrue's insert: no auth user, no profile,
--     no orphan, and no redeemed invite without its edges — atomicity by
--     construction rather than by careful client code.
--
-- Redemption happens at sign-up, not at email confirmation (decided). With
-- confirmations on, a sign-up that is never confirmed still spends the code
-- and leaves the inviter following an inert account; the inviter can see who
-- redeemed on the invites screen, and a later sweep of never-confirmed
-- accounts can release those. Redeeming at confirmation would need a second
-- trigger and a "reserved" state for that edge case.

create type public.invite_state as enum ('valid', 'not_found', 'redeemed', 'expired');

-- Per account, so raising it for one person is an update, not a migration.
-- Five is deliberately conservative for a network that is supposed to grow
-- through people who know each other.
alter table public.profiles
    add column invite_quota integer not null default 5
    check (invite_quota >= 0);

-- A redemption is redeemed_at; redeemed_by is who, for as long as that
-- account exists. The two are not tied by a both-or-neither CHECK on
-- purpose: redeemed_by is `on delete set null`, and such a constraint would
-- make deleting a redeemer's account fail on the invite they used. The
-- invites screen shows that row as redeemed by someone who has since left.
create table public.invites (
    code        text primary key,
    inviter_id  uuid not null references public.profiles (id) on delete cascade,
    redeemed_by uuid references public.profiles (id) on delete set null,
    redeemed_at timestamptz,
    created_at  timestamptz not null default now(),
    expires_at  timestamptz,
    constraint invites_redeemer_implies_redemption
        check (redeemed_by is null or redeemed_at is not null)
);

-- "My invites", and the cascade from profiles.
create index invites_inviter_id_idx on public.invites (inviter_id);

alter table public.invites enable row level security;

-- Read your own. There is no policy at all for anyone else's, and none for
-- anon: what the world may learn about a code is one enum value, through
-- invite_status() below.
create policy "users can see their own invites"
    on public.invites
    for select
    to authenticated
    using (inviter_id = (select auth.uid()));

-- Revoke: delete your own, as long as nobody has used it. A redeemed code is
-- history — the account it admitted exists — and stays.
create policy "users can revoke their own unredeemed invites"
    on public.invites
    for delete
    to authenticated
    using (inviter_id = (select auth.uid()) and redeemed_at is null);

-- No insert or update policy for clients. Codes are minted by create_invite()
-- and consumed by the sign-up trigger, both running as owner; a client that
-- could write its own rows could mint past its quota or un-redeem a code.

-- ---------------------------------------------------------------------------
-- create_invite: mint a code for the caller, within their quota
-- ---------------------------------------------------------------------------
-- Ten glyphs from a 31-glyph alphabet with no 0/O/1/I/L, shown as
-- XXXXX-XXXXX: about 10^15 possibilities, drawn from gen_random_bytes with
-- rejection sampling so every glyph is equally likely, and minted only here
-- — so a known code says nothing about the next one and invite_status() is
-- useless for guessing. The primary key makes a duplicate impossible; at
-- this space a collision is not a realistic event, and if one ever happened
-- the insert would fail loudly rather than reuse a code.
--
-- The quota counts redeemed codes plus outstanding unexpired ones, so a
-- revoked or expired code gives its slot back: the quota limits the people
-- you can bring in, not typos. The caller's profile row is locked first so
-- two simultaneous calls cannot both pass the check.
create function public.create_invite(p_expires_in interval default interval '30 days')
returns public.invites
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_me       uuid := (select auth.uid());
    v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    v_raw      text := '';
    v_byte     integer;
    v_used     integer;
    v_quota    integer;
    v_row      public.invites;
begin
    if v_me is null then
        raise exception 'not signed in' using errcode = 'insufficient_privilege';
    end if;

    select invite_quota into v_quota
    from public.profiles
    where id = v_me
    for update;
    if v_quota is null then
        raise exception 'no profile for this account' using errcode = 'insufficient_privilege';
    end if;

    select count(*) into v_used
    from public.invites
    where inviter_id = v_me
      and (redeemed_at is not null or expires_at is null or expires_at > now());
    if v_used >= v_quota then
        raise exception 'invite quota reached' using errcode = 'check_violation';
    end if;

    -- 248 = 8 * 31: bytes at or above it are redrawn, so no glyph is favoured.
    while length(v_raw) < 10 loop
        v_byte := get_byte(extensions.gen_random_bytes(1), 0);
        if v_byte < 248 then
            v_raw := v_raw || substr(v_alphabet, 1 + v_byte % 31, 1);
        end if;
    end loop;

    insert into public.invites (code, inviter_id, expires_at)
    values (left(v_raw, 5) || '-' || right(v_raw, 5), v_me, now() + p_expires_in)
    returning * into v_row;
    return v_row;
end;
$$;

revoke execute on function public.create_invite(interval) from public, anon;
grant execute on function public.create_invite(interval) to authenticated;


-- ---------------------------------------------------------------------------
-- invite_status: the one thing the world may ask
-- ---------------------------------------------------------------------------
-- Callable by anon, because the person asking has no account yet: the
-- sign-up form checks the code before creating anything so that each of the
-- three failures gets its own sentence. Answers exactly one enum value and
-- never a row — not who minted it, not when. Normalises the way the trigger
-- does (upper, trim), so a code typed in lowercase from a text message works.
create function public.invite_status(p_code text)
returns public.invite_state
language sql
stable
security definer
set search_path = ''
as $$
    select coalesce(
        (
            select case
                when i.redeemed_at is not null then 'redeemed'
                when i.expires_at is not null and i.expires_at <= now() then 'expired'
                else 'valid'
            end::public.invite_state
            from public.invites i
            where i.code = upper(trim(p_code))
        ),
        'not_found'::public.invite_state
    );
$$;

revoke execute on function public.invite_status(text) from public;
grant execute on function public.invite_status(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- handle_new_user: the whole onboarding transaction
-- ---------------------------------------------------------------------------
-- Replaces the version from 20260904143711. GoTrue inserts the auth.users
-- row and this fires inside that insert, so anything it refuses rolls the
-- sign-up back entirely — no auth user, no profile — and anything it writes
-- exists together with the account or not at all. That is where SOL-61's
-- "atomic with account creation" and SOL-62's "no redeemed invite without
-- edges" both come from: there is only one statement.
--
-- The code arrives in the sign-up metadata as invite_code. The row is locked
-- for update so two sign-ups racing for one code serialise, and the loser is
-- refused. GoTrue reports every refusal here as its sanitised "Database
-- error saving new user", so the app asks invite_status() first for the
-- wording; this is the enforcement.
--
-- The seed script creates accounts without invites. It runs as owner and
-- sets candid.allow_uninvited_signup for its own session first; GoTrue has
-- no way to set a setting, and no function exposed to the API does, so this
-- is not a door a client can open.
--
-- Both follow edges, because the inviter chose to invite, which is consent
-- to the connection; one way would leave the invitee with a feed and the
-- inviter with nothing. Never across a block. For a brand-new id a block
-- cannot exist — blocks reference profile ids, and this one was created a
-- moment ago in this very function — so the guard is unreachable by
-- construction; it is one line, and the ticket asks for it. Nothing about an
-- invite-created edge is special: either side unfollows it like any other.
--
-- CREATE OR REPLACE keeps the function's privileges (EXECUTE was revoked
-- from public, anon and authenticated in 20260904043158) and leaves the
-- trigger attached.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_code   text := upper(trim(new.raw_user_meta_data ->> 'invite_code'));
    v_invite public.invites;
begin
    if coalesce(current_setting('candid.allow_uninvited_signup', true), '') <> 'on' then
        if v_code is null or v_code = '' then
            raise exception 'an invite code is required' using errcode = 'check_violation';
        end if;
        select * into v_invite from public.invites i where i.code = v_code for update;
        if not found then
            raise exception 'invite code not found' using errcode = 'check_violation';
        end if;
        if v_invite.redeemed_at is not null then
            raise exception 'invite code already used' using errcode = 'check_violation';
        end if;
        if v_invite.expires_at is not null and v_invite.expires_at <= now() then
            raise exception 'invite code expired' using errcode = 'check_violation';
        end if;
    end if;

    insert into public.profiles (id, username)
    values (
        new.id,
        coalesce(
            nullif(lower(trim(new.raw_user_meta_data ->> 'username')), ''),
            'user_' || left(replace(new.id::text, '-', ''), 25)
        )
    );

    if v_invite.code is not null then
        update public.invites
        set redeemed_by = new.id, redeemed_at = now()
        where code = v_invite.code;

        if not private.is_blocked_either_way(v_invite.inviter_id, new.id) then
            insert into public.follows (follower_id, followee_id)
            values (new.id, v_invite.inviter_id), (v_invite.inviter_id, new.id)
            on conflict do nothing;
        end if;
    end if;

    return new;
end;
$$;
