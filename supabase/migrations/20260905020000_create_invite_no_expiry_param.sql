-- create_invite() takes no expiry argument (SOL-70): the 30 days are the
-- server's decision, not the caller's.
--
-- Replaces the (interval) version from 20260905011241_invites.sql. PostgREST
-- passes named RPC arguments straight through, so any signed-in user could
-- POST /rest/v1/rpc/create_invite with {"p_expires_in": "100 years"} and mint
-- a code that never meaningfully expires — holding one of the caller's five
-- quota slots forever — or a negative interval, minting one already expired.
-- The app never sent the parameter (InviteService.create() calls .rpc with
-- none), so this is purely a rule enforced by the client's silence until now.
--
-- A changed argument list is a different function to Postgres, so this drops
-- the old signature and creates a zero-argument one rather than altering it;
-- grants are per signature and have to be redone. Declare block and body are
-- copied verbatim from 20260905011241 except the expiry, now a constant.

drop function public.create_invite(interval);

create function public.create_invite()
returns public.invites
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_expires_in constant interval := interval '30 days';
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
    values (left(v_raw, 5) || '-' || right(v_raw, 5), v_me, now() + v_expires_in)
    returning * into v_row;
    return v_row;
end;
$$;

revoke execute on function public.create_invite() from public, anon;
grant execute on function public.create_invite() to authenticated;
