# Candid

[![CI](https://github.com/firstzion/proj-candid/actions/workflows/ci.yml/badge.svg)](https://github.com/firstzion/proj-candid/actions/workflows/ci.yml)

An iOS-first photo-sharing app built for human connection, not engagement metrics.
No bots, no AI-generated content, no ads — what you see comes from your friends.

Tracked in Linear: [Project Candid](https://linear.app/cspurlock/project/project-candid-c54ab6260b06/overview)

## Status

MVP complete: sign up, log in, post a photo, and see it in the feed, all working
end to end against the hosted backend. Also done: a full code-review pass
(in-app account deletion, a real password policy, Swift 6 strict concurrency,
CI, this README). In flight: the social graph and visibility model that will
make the feed actually reflect who you follow, rather than showing every post
to every signed-in user. The graph itself is in — the `follows` table, the
derived `mutuals` view and `FollowService` — and so are per-post visibility,
chosen at posting time and fixed from then on, blocking's data model, and the
rule that ties them together: `can_view_post()`, one Postgres function that
every read of a post or a post image goes through. The feed shows only what
you are permitted to see, and you can follow, unfollow, block and unblock
people from their profile — reached by tapping a username in the feed or
looking one up on the Profile tab. What's left of Milestone 7 is the hands-on
smoke test. Milestone 8 has started with its privacy fix: follower and
following counts are public, but the lists behind them are readable only by
the people at either end of an edge and their mutuals (SOL-66). You can
delete your own posts from the feed — long-press, confirm, and the row and its
image are both gone (SOL-38) — and the upload pipeline is now proven rather
than assumed to strip EXIF, location included (SOL-44). The profile screen is
real now: counts, a grid, and the follow lists where they may be read
(SOL-37). And sign-up is invite-only (Milestone 9, SOL-60–62): a new account
needs a code from someone already here, the trigger that creates its profile
also redeems the code and makes the two friends, and nobody's first feed is
empty. You mint and share invites from your own profile (SOL-63), and you
can change your username there too: once every 30 days, with a name you give
up held for you for 90 days and old handles still finding you (SOL-41).

The Post tab creates a post end to end: pick from the photo library (or capture
with the camera on a device that has one), preview it, add an optional caption,
choose who can see it — everyone who follows you, or friends only — and publish.
The image is uploaded first and the row written second, so a failure never
leaves a post pointing at an image that does not exist. Blank captions are
stored as NULL rather than an empty string. The audience picker starts on
Followers and then keeps whatever was chosen last rather than resetting after
each post: of the two mistakes a reset invites, sending a friends-only photo to
every follower is the one that can't be taken back.

The Feed tab shows the posts you are permitted to see — your own, followers
posts from people you follow, and friends-only posts from people you follow
who follow you back — newest-first with pull-to-refresh and pagination. The
app applies no filter of its own; the database decides which rows exist for
you (see RLS under Schema). The feed refreshes itself when it goes stale
(signed image URLs expire) and also right
after you post, so a just-posted photo does not sit unseen for up to half an
hour. Decoded images are cached by storage path rather than URL, so a refresh
does not re-download every photo already on screen.

Following, unfollowing, blocking or unblocking someone refreshes the feed the
same way posting does: the action marks it stale (`FeedInvalidation`), the
feed refetches its newest page and replaces its list, and rows that are no
longer permitted disappear without a restart — a friend's friends-only posts
when the friendship breaks, everything of theirs when you block them. That
blanket refresh is the whole invalidation strategy, and it is enough at this
scale. What is deliberately *not* invalidated: `ImageCache`, which is keyed by
storage path and only ever drawn through a visible row, so no bitmap renders
for a post that is no longer on screen, and purging it would re-download every
photo after each follow. A change made by the other party — they unfollow or
block you — shows up at your next refresh: pull, returning to the foreground
after the feed has gone stale, or the half-hour mark. That is the same window
signed URLs already have.

The app root is session-gated: `RootView` shows the Log In screen when signed out
and the main tabs when signed in, driven by `SessionStore` mirroring the SDK's
`authStateChanges`. Sessions are persisted and refreshed by the Supabase SDK
itself — `defaultLocalStorage` is `KeychainLocalStorage` and `autoRefreshToken`
defaults to true — so there is no custom persistence here. The one auth option
the app sets is `emitLocalSessionAsInitialSession`, so the Keychain session is
reported at launch even when its access token has expired and the SDK refreshes
it in the background. The SDK's legacy default refreshes *first* and reports no
session at all if that fails, which sent a still-signed-in user launching
offline to the Log In screen — and then bounced them back into the app when the
auto-refresh eventually got through. One `ProfileScreen` serves every profile,
yours and everyone else's (SOL-37): username, three counts — posts, followers,
following — and a three-column grid of the person's posts, paginated like the
feed and opening into `PostDetailView`. Your own adds Edit Username, Invites,
Log Out and Delete Account; someone else's — from a search result on the People
tab, from tapping a username in the feed, or from a follower list — shows where you
stand (following, follows you, friends, blocked) with Follow/Unfollow and
Block/Unblock; every control changes immediately and changes back with a
message if the request fails. The post count and the grid are read under RLS,
so they are the posts *you* can see; the two follow counts are public, and
open into `FollowListView` only on your own profile or a mutual's. The People
tab is where discovery lives (SOL-39, under the SOL-43 decision): a search
field with a debounced prefix match on current usernames, two characters or
more, whose results open profiles, plus "Invite a friend". Results never
include you, anyone you have blocked, or anyone who has blocked you — a
blocker's account is simply absent rather than marked, since a block is
silent — and a whole former handle with no match falls back to the exact
lookup and shows who it belongs to now.

## Requirements

- Xcode 26 or newer
- iOS 17.0+ deployment target

## Opening and running

```bash
git clone git@github.com:firstzion/proj-candid.git
cd proj-candid
open Candid.xcodeproj
```

In Xcode, pick an iOS Simulator destination (e.g. iPhone 17) and press ⌘R.

To build and run from the command line instead:

```bash
xcodebuild -project Candid.xcodeproj -scheme Candid -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Tests

```bash
xcodebuild -project Candid.xcodeproj -scheme Candid \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

CI (`.github/workflows/ci.yml`) runs the same command on every push and pull
request, against whichever iPhone simulator the runner's image happens to
have available — it asks `simctl` rather than hardcoding a device name, so an
image update can't break the build by renaming or dropping one.

Unit tests live in `CandidTests/` and use Swift Testing. Most cover pure logic
most likely to rot quietly: the error-mapping functions, which translate opaque
Supabase errors into wording a person can act on; `UsernameRules`; the
image downscaling and downsampling arithmetic; and, since SOL-44, that the
upload pipeline strips metadata — a JPEG tagged with GPS coordinates, a
capture time and a camera model goes in, and what comes out carries none of
them. The error mappers and the downscaling arithmetic have both already
regressed once.

`FeedServiceDecodingTests` goes further and exercises `FeedService.fetchPosts`
itself against canned PostgREST and Storage responses, stubbed at the
`URLProtocol` level (`CandidTests/Support/`) rather than mocked — what
`FeedService`'s dependency-injected `SupabaseClient` (see Services below)
makes possible. It pins the keyset cursor's byte-for-byte date handling and
the `hasMore` logic, the two places a silent regression would otherwise only
surface against a real project.

`FollowServiceTests` does the same for `FollowService`, pinning the *request*
each method builds — table, HTTP method, filters, body — because a wrong filter
there is a silent bug (unfollowing nobody, or everybody) that only a live
project would otherwise reveal. The signed-in user's id is injected into the
service under test, since a live session is the one thing the stub cannot
stand in for. `PostServiceRequestTests` pins the upload-then-row order of a
new post and, for delete, the row-then-object order and the by-`id`-only
filter; `ProfileServiceRequestTests` pins the exact-username lookup and the
HEAD-with-count request behind a profile's post count the same way; the
follow lists and the grid's author scope are pinned alongside the requests
they extend. `InviteServiceTests` and `AuthServiceSignUpTests` pin the invite
calls and the gate: a code that is not valid stops the sign-up before any
request but the status check, and a valid one travels in the sign-up
metadata. `ProfileServiceSearchTests` pins the prefix request — normalised,
`_` escaped, capped — and the inputs answered empty without one. All of them
build their client with `TestSupabaseClient` in
`CandidTests/Support/`.

The authorization rule itself is tested in SQL, not Swift.
`supabase/tests/visibility_matrix.sql` impersonates each seeded account the
way PostgREST does (`request.jwt.claims` plus the `authenticated` role) and
asserts every case in SOL-30's matrix: both tiers from the author's, a one-way
follower's, a mutual's and a stranger's seat; both directions of a block, even
across a follow edge; the profile rows a blocked pair cannot read; the storage
policy that signing depends on; mutuality breaking the moment one side
unfollows; and, since SOL-66, that a follow edge is readable only at either
end or by a mutual of either end while `follow_counts()` answers for anyone;
and, since Milestone 9, the invite gate itself — sign-ups made the way GoTrue
makes them, refused and rolled back for a missing, used or expired code,
admitted and made mutual for a valid one, and the quota holding at five; and
the username rules — one change a month with the date in the refusal, a
released name reserved from others but not from its owner, a sign-up refused
for a cooling-down name, and an old handle resolving to the current profile
except for someone the owner has blocked; and search, whose view omits you,
your blocks and your blockers.
Everything it touches is rolled back. Run it against the hosted
project after a push and a seed run:

```bash
supabase db query --linked -f supabase/tests/visibility_matrix.sql
```

It prints `all checks passed`, or stops at the first failing case.

## Project layout

```
Candid.xcodeproj      Xcode project (uses synchronized folders — files on disk are
                      picked up automatically, no need to add them to the target)
Config/               Build configuration; Secrets.xcconfig here is gitignored
Candid/
  CandidApp.swift     App entry point
  Models/             FeedPost/FeedPage/FeedCursor, Profile, Relationship,
                      FollowCounts, Invite/InviteState, UsernameRules
  ViewModels/         SessionStore (mirrors the SDK's auth state),
                      FeedInvalidation (tells the feed to refresh after a post),
                      PendingInvite (a code that arrived by deep link)
  Services/           AppServices (DI container built at launch), SupabaseService,
                      AuthService, ProfileService, PostService, FeedService,
                      FollowService, InviteService, StorageService, ImageCache,
                      ImageDownsampler
  Views/              RootView (session gate), ConfigurationErrorView, auth
                      screens, RootTabView and tabs, ProfileScreen (yours and
                      everyone else's), FollowListView, PostDetailView,
                      InvitesView, EditUsernameSheet, PeopleView (the People tab)
    Components/       PostImageView, shared form controls
  Resources/          Asset catalog
CandidTests/          Unit tests (Swift Testing)
supabase/             CLI config, versioned migrations, seed data, and the
                      visibility matrix test (tests/)
```

The project uses Xcode's synchronized folders, which sweep in *every* file under
`Candid/` — dotfiles included. If you ever need to keep an empty folder in git with a
`.gitkeep`, add it to `EXCLUDED_SOURCE_FILE_NAMES` too, or the build fails on
duplicate bundle resources.

## Backend

The backend is a hosted Supabase project (no local stack). Schema changes are written
as migrations under `supabase/migrations/` and pushed with the Supabase CLI.

Migrations are history, not documentation: once applied, a migration's SQL and
comments are never edited, even after a later one changes or drops what it
describes — each new migration explains its own relationship to what came
before in its own comments instead. For how things work *today*, read this
section and Schema/Storage below, not the oldest migration that touches a
table.

| | |
|---|---|
| Project | `proj-candid` |
| Project ref | `ztdggewgqaoaixjhttct` |
| API URL | `https://ztdggewgqaoaixjhttct.supabase.co` |
| Region | us-west-2 |
| Dashboard | https://supabase.com/dashboard/project/ztdggewgqaoaixjhttct |

### Credentials

API keys live in the dashboard under **Project Settings → API**, or via
`supabase projects api-keys --project-ref ztdggewgqaoaixjhttct`.

The app uses the **publishable key** (`sb_publishable_...`). It is designed to be
shipped in a client and is constrained by Row Level Security. A legacy `anon` JWT key
also exists on this project and works interchangeably. These are dev-project
credentials — they are kept out of git regardless, since rotating a committed key is
more annoying than never committing it.

**The service role key is never used in this repo.** It bypasses RLS completely, so it
must never appear in the app, in a migration, or in any committed file.

Local credentials go in `Config/Secrets.xcconfig`, which is gitignored. Copy the
committed template to create it:

```bash
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
```

The build wires them through in three hops: `Config/Base.xcconfig` optionally
includes `Secrets.xcconfig`, `Config/Info.plist` substitutes the values into the
app's Info.plist, and `SupabaseService` reads them back at runtime. The optional
include (`#include?`) means a fresh clone still builds without the secrets file —
the app then reports a clear configuration error instead of failing to compile.

Custom keys need that real `Info.plist`: Xcode only honours `INFOPLIST_KEY_*`
build settings for keys it already knows about, and silently drops unknown ones.
`GENERATE_INFOPLIST_FILE` stays on, so Xcode merges its usual entries on top.

### Schema

| Table | Columns |
|---|---|
| `profiles` | `id` (PK → `auth.users`), `username` (unique, `^[a-z0-9_]{3,30}$`), `invite_quota` (default 5), `created_at` |
| `posts` | `id` (PK), `user_id` (→ `profiles`), `image_path`, `caption` (nullable, ≤ 2,200 characters), `visibility` (`followers` \| `mutuals`, default `followers`, immutable), `created_at` |
| `follows` | `follower_id` (→ `profiles`), `followee_id` (→ `profiles`), `created_at`; PK (`follower_id`, `followee_id`), CHECK `follower_id <> followee_id` |
| `blocks` | `blocker_id` (→ `profiles`), `blocked_id` (→ `profiles`), `created_at`; PK (`blocker_id`, `blocked_id`), CHECK `blocker_id <> blocked_id` |
| `invites` | `code` (PK), `inviter_id` (→ `profiles`, cascade), `redeemed_by` (→ `profiles`, set null), `redeemed_at`, `created_at`, `expires_at` |
| `username_history` | `profile_id` (→ `profiles`, cascade), `username`, `changed_at`; PK (`profile_id`, `changed_at`) |

A trigger on `auth.users` (`handle_new_user`) runs inside GoTrue's insert at
sign-up. Since Milestone 9 it is the whole onboarding transaction: it requires
an `invite_code` in the sign-up metadata and refuses — rolling the sign-up
back, so no auth user and no profile are ever left behind — if the code is
missing, unknown, already used or expired; then it creates the `profiles` row,
taking `username` from the metadata and falling back to a generated
placeholder (`user_` plus 25 hex characters of the user's id, to fit the length
limit), marks the invite redeemed, and inserts a follow edge in each direction
between inviter and invitee, so the two are friends before the first feed
loads. See Invites below. Deleting an auth user cascades to their profile,
posts, follow edges, blocks and the invites they minted, and clears
`redeemed_by` on any invite they used.

`follows` is the social graph: one row per directional edge, where `(a, b)`
means a follows b. Following is open — anyone can follow anyone, with no
approval and no pending state. "Friends" means a mutual follow, and it is
derived, never stored: the `mutuals` view is a self-join on `follows` that
returns both `(user_id, mutual_id)` and its mirror, so "is a mutual with b" is
one equality lookup, and it is the single definition of friendship that the
visibility rule and any future ranking read from. It is a `security_invoker`
view, so it runs under the caller's own RLS on `follows` rather than its
owner's — which, since SOL-66, means a caller sees their own pairs and those
of the people they are mutual with rather than everyone's; `can_view_post()`
reads it as definer and is unaffected. There are no follower/following
counter columns — counters need triggers that will be wrong at least once —
and the two numbers a profile shows come from `follow_counts(profile)`, a
`security definer` function, because since SOL-66 a caller can no longer see
every row to count them (see RLS below).
The composite primary key makes a duplicate follow impossible at the database;
`FollowService.follow` treats that refusal as success, since the state asked
for already holds and a double tap must not read as a failure. `FollowService`
also offers `unfollow`, `isFollowing`, `isMutual` (which reads `mutuals`),
`relationship(with:)`, which fetches both directions in one request plus the
caller's own block, `counts(for:)`, which calls `follow_counts`, and
`followers(of:)` / `following(of:)`, which read `follows` joined with the
profile at the other end — whatever RLS lets through, and nothing more.
`ProfileScreen` is the UI over all of it.

`posts.visibility` is the per-post audience: `followers` (anyone who follows
the author) or `mutuals` ("friends only" in the app — people the author also
follows back). It defaults to `followers`, deliberately the wider tier: a new
account's audience is almost entirely one-way followers at first, so a
`mutuals` default would hide its first posts from nearly everyone. It is
immutable. A tier that could change means a photo someone already saw can
vanish from under them, or one they could never see can surface at an old
position in their feed, both worse than "delete and repost". Two things
enforce that: `posts` has no update policy at all — nothing in the app updates
a post — and a `before update` trigger refuses any change to `visibility`
regardless of policy, so a caption-edit policy added later can't reopen it by
accident. Until the `can_view_post()` rule lands (SOL-30) the column changes
nothing a viewer can see; the feed marks `mutuals` posts "Friends only" so you
can tell which audience a photo went to, and the app mirrors the enum in
`PostVisibility`, whose raw values are the Postgres labels.

`blocks` is the one relationship that overrides the graph: `(a, b)` means a
has blocked b. Everything a block does happens in the database, so no query
has to remember to check. An `after insert` trigger severs the follow in both
directions in the same transaction — a block that left the follow intact
would be a bug waiting to surface — and the `follows` insert policy refuses a
new edge across a block in either direction for as long as it stands. Each
side's posts are hidden from the other by the `can_view_post()` rule (SOL-30),
which is written block-aware. The blocker's *profile* is hidden from the
blocked person too, but the blocker can still see the blocked profile — that
is where Unblock lives, and a block that could never be lifted from the app
would be a bug. Unblocking deletes the row and restores nothing: the severed
follows stay severed, and either side may follow again from scratch.
Blocking is silent. The table is readable only by the person who made the
block, and a refused follow reaches the blocked person as an ordinary RLS
error, which `FollowService` words as "Couldn't follow this account right
now" — never why. `FollowService.block`, `unblock`, `isBlocking` and
`relationship(with:)` (which reports `blocking`) are the client surface;
`ProfileScreen` puts Block behind a confirmation that says what will
happen, and Unblock in its place once blocked.

`invites` is how Candid grows (SOL-60–62, decided in SOL-43): a new account
needs a code from an existing one. Each profile has an `invite_quota` (default
5, raisable per account with an update rather than a migration) that counts
redeemed codes plus outstanding unexpired ones — a revoked or expired code
gives its slot back, so the quota limits people brought in, not typos. Codes
are minted only by `create_invite()`, a definer function callable by
`authenticated`: ten glyphs from a 31-glyph alphabet with no 0/O/1/I/L, shown
as `XXXXX-XXXXX`, drawn from `gen_random_bytes` with rejection sampling, about
10^15 possibilities, expiring after 30 days by default. `invite_status(code)`
is the one thing `anon` may call — the sign-up form asks it before creating
anything, so each failure gets its own sentence — and answers exactly one of
`valid`, `not_found`, `redeemed` or `expired`, never a row. RLS on the table is
read-your-own and delete-your-own-unredeemed (that is "revoke"); there is no
insert or update policy for clients, since minting and redeeming both happen
as owner. Redemption is at sign-up, not at email confirmation, by decision: a
never-confirmed account spends its code and leaves the inviter following an
inert account, which the invites screen shows and a later sweep can clean up.
The seed creates its accounts without invites by setting
`candid.allow_uninvited_signup` for its own session — a setting GoTrue has no
way to set and no API-reachable function sets. `InvitesView`, reached
from your own profile, shows how many invites you have left ("3 of 5 invites
left", or "You've used all 5 invites"), mints one, shares it through the system
share sheet with the deep link and the code in plain text, and lets you swipe
an unused code to revoke it; used codes show who redeemed them and when, or
"someone" when that profile is hidden from you. `InviteService` is the client
surface (`status`, `create`, `mine`, `revoke`, `quota`); `AuthService.signUp`
checks the code first and sends it in the metadata; and `candid://invite/<code>`
opens the sign-up form with the code filled in (`PendingInvite`).

The helpers the policies call — `private.is_blocked_either_way(a, b)` and
`private.is_blocked_by(viewer, owner)` — live in a `private` schema that
PostgREST does not expose. Any function in `public` that `authenticated` may
execute is also an RPC endpoint, and a policy needs `authenticated` to execute
these — so in `public`, any signed-in user could ask "has alice blocked bob?"
in a single request, which is exactly what silent blocking forbids. A function
in `private` is callable from a policy and from nowhere else; `authenticated`
has `usage` on the schema and `execute` on the functions, `anon` has neither.
The `can_view_post()` family lives there too. Trigger functions stay in
`public` with `execute` revoked, as `handle_new_user` does — a trigger needs
no callers.

Usernames are stored lowercase. The trigger lowercases and trims what the
metadata carries, and a CHECK constraint enforces `^[a-z0-9_]{3,30}$`; because
only lowercase is ever stored, the plain unique constraint is case-insensitive
by construction — `Alice` and `alice` cannot be two people. The app mirrors the
rules in `UsernameRules` so the sign-up form can say exactly what is wrong before
sending anything: a CHECK failure inside the trigger only reaches the client as
GoTrue's sanitised "Database error saving new user". Captions are capped at
2,200 characters the same way, checked client-side before the image is uploaded.

Usernames can change (SOL-41), from your own profile. Two triggers on
`profiles` enforce the rules where every write passes, sign-up included: one
change per 30 days — the refusal carries the date the next one is allowed,
which the app shows — and a name someone else released within the last 90
days is unavailable, raised as a unique violation so it reads as taken, while
your own old names are always yours to reclaim. `username_history` records
each old name (readable by its owner only, written by the trigger),
`username_available()` knows the cooldown so the form can say so first, and
`resolve_username(text)` answers an exact current-or-former handle with the
current profile under the profiles policy's blocked-by rule — what the lookup
calls, so a handle remembered from a text message still finds the person. The
feed shows the current name (it joins `profiles`; posts follow the person, not
the string), and search (SOL-39) matches current names only, with the
exact-handle fallback for old ones. The trade-off: a rename does not hide you
from someone who knew the old handle; blocking is the tool for that.

Search (SOL-39) reads `searchable_profiles`, a `security_invoker` view over
`profiles` that leaves out the caller and anyone the caller has blocked;
running under the profiles policy, it also omits anyone who blocked the
caller, so both directions of a block are excluded with one rule and the view
exposes nothing but `id` and `username`. `profiles_username_pattern_idx`
(`text_pattern_ops`) serves the prefix match that the unique index cannot
under the project's `en_US` collation. `ProfileService.search(prefix:limit:)`
asks for two characters or more of username characters only, escapes `_`, and
caps at 20 rows.

Before creating the auth user, sign-up also asks `username_available(text)`
whether the name is still free. The person asking has no session yet and
`profiles` is readable only by `authenticated`, so the function is `security
definer`, callable by `anon`, and returns exactly one bit — the one thing about
the table that sign-up reveals anyway. The answer is advisory: two people can be
told "free" at once and one then loses the race inside the trigger, which is why
the sanitised database error is now reported as a failed creation whose username
*may* have been taken, rather than asserted as taken — that assertion used to
turn every server-side failure into a report of a user mistake.

RLS is enabled on all four tables, and the read policies are where the
product's premise lives. A `posts` row is readable only when
`private.can_view_post(viewer, author, visibility)` says so — see below. A
`profiles` row is readable unless its owner has blocked you; the person who
made a block can still read the profile they blocked, since that is where
Unblock lives. A `follows` row is readable by the people at either end of it
and by anyone mutual with either end — your own edges plus the full lists of
the people you are friends with, and nothing else (SOL-66; it replaced the
"readable by every authenticated user" policy that SOL-27 shipped with a
note to revisit). The relationship line and the follow button only ever read
edges with the caller at one end, so they are unaffected. The two counts a
profile shows come from `follow_counts(profile)`, a `security definer`
function callable by any signed-in user: the numbers are public by decision
(SOL-43), the lists are not, and a counts view under the caller's own RLS
would have counted only the rows they may see.
`blocks` is readable, insertable and deletable only by the blocker, with no
policy at all for the blocked side. On `profiles`, inserts and updates are restricted to the caller's own rows; on
`posts`, inserts are, and there is no update policy at all, since posts are
immutable (see visibility above). `posts` has a delete policy scoped to the
author's own rows (SOL-38) — the first delete path in the schema, and the
escape hatch immutable visibility promised; another account's delete matches
no rows. `profiles` has no delete policy, so a client can never delete a
profile row directly — but `delete_own_account()` deletes the caller's own
`auth.users` row, cascading to their `profiles` row, every `posts` row they
own and every `follows` edge in either direction; see Account deletion below.
On
`follows`, a user may insert and delete only edges where they are the
follower — you can unfollow someone, you cannot remove one of your followers —
the insert is refused across a block in either direction, and there is no
update policy, since nothing on an edge can change.

`can_view_post()` is the one place the visibility rule lives. For a viewer
looking at a post: the author always; otherwise only if the viewer follows the
author, neither has blocked the other, and — for a `mutuals` post — the pair
appears in `mutuals`. It is written once, taking the row's own columns
(`viewer, author, visibility`) so the `posts` policy evaluates it without
looking the post up again; the `(viewer, post_id)` form is a thin wrapper for
callers that only hold an id, and `can_view_image(viewer, object_name)`
resolves a storage object to its one post (`posts.image_path` is unique) and
applies the same rule. All three are `security definer` (the rule has to read
`blocks`, which the blocked side cannot), `stable`, pinned to an empty
`search_path`, and live in the `private` schema for the reason given above.
Nothing in Swift decides whether a post is visible: `FeedService.fetchPosts`
selects with no visibility filter at all, and because RLS filters rows before
`limit` applies, a page is full whenever more rows exist and the keyset cursor
works exactly as before. Likes, comments, profile grids and moderation should
call the same function rather than restate it — a second copy of the rule is
how a photo leaks. `profiles` narrowed in the same migration as `posts`,
deliberately: a post is only ever visible together with its author's profile
row, and narrowing one without the other would leave a feed page embedding a
hidden author and failing to decode.

The policy is a per-row function call along a `created_at` scan — a few
primary-key lookups on small tables per row — which is fine at this scale. If a
large table and a sparse graph ever make the first page slow, the escape hatch
is a `security_invoker` `feed` view that pre-filters to `user_id in (self,
followees)` purely as a planner hint, with authorization still in
`can_view_post()`. The feed's order `(created_at desc, id desc)` is backed by a
matching composite index, `posts_created_at_id_idx`, which replaced the
single-column one from the initial schema. The profile grid pages one author's
posts the same way — the feed query with a `user_id` filter, nothing else
changed — backed by `posts_user_id_created_at_id_idx` `(user_id, created_at
desc, id desc)`, which replaced the initial schema's `(user_id, created_at
desc)` (SOL-37).

`posts.image_path` is CHECK-constrained to the shape `{user_id}/{uuid}.jpg` with
the first segment equal to the row's own `user_id`, so a post can only ever
reference an image in its author's storage folder — the row-level counterpart
of the upload policy under Storage. Without it, any authenticated user could
insert a row pointing at someone else's photo (the publishable key plus their
own JWT is all it takes) and the feed would show that photo under their name.

### Storage

Post images live in the **private** `post-images` bucket (5 MB cap, `image/jpeg`
only). Objects are laid out as `{user_id}/{uuid}.jpg`, and the insert policy
requires the first path segment to equal the caller's `auth.uid()`, so nobody can
write into another user's folder. A delete policy is scoped the same way, and
further requires the object to be **unreferenced** — no `posts` row may still
point at it, checked via a `security definer` `image_is_referenced()` helper
that stays exact now that reads are narrowed to the follow graph. The client uses it
to take back an upload whose post row failed to be written, to remove a
deleted post's image (SOL-38), and in account deletion — see below. Deleting
a post is "row first, then object" for the same reason account deletion is:
the guard refuses the object while a row references it, and the matrix checks
that order from the author's seat. If the object delete then fails, the post
is already out of every feed and the leftover is readable only through its
owner's folder clause — a storage cost, not a privacy one — so
`PostService.deletePost` logs it rather than reporting a failure for a post
that is, in every way that matters, gone. Supabase's storage schema also
carries a `protect_delete` trigger that refuses any *direct SQL* delete on
`storage.objects` unless the transaction has set `storage.allow_delete_query`
— the Storage API sets it for its own deletes, the matrix sets it for its
rolled-back transaction, and a dashboard query that forgets it fails with
"Direct deletion from storage tables is not allowed" rather than deleting
anything. There is no update policy — posts are immutable, and an
overwrite of a referenced object would silently change a post's photo.

Reads follow the same rule as the feed. The `storage.objects` select policy
allows the caller's own folder outright — uploads, failed-insert cleanup and
account deletion all touch objects before or after a post row exists — and
otherwise asks `private.can_view_image(viewer, name)`, which resolves the
object to its one post through the unique `posts.image_path` and applies
`can_view_post()`. Creating a signed URL is a `select` on `storage.objects`,
so this policy is exactly where "no signed URL for a post you cannot see" is
enforced; the matrix test checks it from a one-way follower's seat and a
mutual's.

Because the bucket is private, reads go through short-lived signed URLs rather
than permanent public ones. The durable identifier for an image is therefore its
object **path**, which is what `posts.image_path` stores; `StorageService.signedURLs(for:)`
mints URLs on demand, a page at a time. Public buckets were the simpler option, but a public bucket
makes every uploaded photo fetchable forever by anyone with the URL, which is hard
to reconcile with an app built around sharing to friends — and it is a one-way
door, since anything already exposed stays exposed.

Minted URLs are valid for one hour (`StorageService.signedURLLifetime`) — comfortably
longer than a feed session, while still expiring if one leaks out (a screenshot of a
page, a copied link). An expired URL fails to load like any broken image rather than
crashing; the feed's own staleness refresh (a post older than half the signed-URL
lifetime re-triggers a fetch, which re-signs) is what actually recovers it, rather
than any retry logic in the image view itself. The same lifetime is the window
after a graph change: a URL minted before an unfollow or a block keeps working
until it expires, up to an hour. Closing that would mean shorter lifetimes (a
re-sign round trip more often) or realtime invalidation (a subsystem); neither
is worth it at this stage.

Uploads are downscaled to a 1600px longest edge and encoded as JPEG at 80%.
Photos are decoded straight to that size when picked (`ImageDownsampler`, via
ImageIO's thumbnailing), so the full-size bitmap — around 200 MB for a
48-megapixel HEIC — is never built; camera captures are downscaled before they
are held. What is uploaded is a fresh bitmap redrawn from those pixels, so it
carries none of the original's EXIF — no GPS coordinates, no camera or lens
details, no capture time; the only metadata written is the pixel dimensions
and an upright orientation. `ImageProcessingTests` proves that with a
GPS-tagged fixture rather than assuming it (SOL-44). The original in the photo
library is never touched: `PhotosPicker` and the camera hand over data, and
only the copy that is uploaded is transformed. On the read side the feed keeps
decoded images in `ImageCache`, keyed
by storage path rather than URL: a signed URL is different every time it is
minted, which defeats `AsyncImage` and `URLCache` and had every refresh
re-downloading every image. A freshly uploaded photo is seeded into the cache so
the poster's own post appears without a download.

### Account deletion

`delete_own_account()` is a `security definer` RPC, callable by `authenticated`
only, that deletes the caller's own `auth.users` row — the cascade takes their
`profiles` row and every `posts` row they own with it. `ProfileService.deleteAccount()`
calls it, then removes every object in the caller's storage folder.

Order matters: the delete policy above refuses to remove an object a `posts`
row still references, and every one of the account's images is still
referenced until the RPC cascades those rows away — so storage cleanup has to
happen *after* the RPC, not before. The JWT used for it stays valid regardless
of the account row being gone, since PostgREST and Storage check its signature
and expiry, not a live session row.

A storage-cleanup failure after a successful RPC call isn't surfaced as an
error to the person deleting their account — the account is already gone,
which is what was asked for, and any objects left behind are harmless orphans
nothing references any more.

### Auth configuration

Hosted auth settings live in `supabase/config.toml` under `[auth]` and are applied
with `supabase config push`. Email confirmation is required
(`[auth.email] enable_confirmations = true`) — `AuthService.signUp` reports
whether a session came back, and `SignUpView` shows a "confirm your email"
notice when it didn't. Sign-up also requires an invite code (see Invites under
Schema): the code is checked with `invite_status` before the request and
enforced by the sign-up trigger, and existing accounts log in unaffected.
`minimum_password_length` is 10, with no composition
rules (NIST SP 800-63B favours length over forced character classes).
Confirmation, password-reset, and magic-link emails link to
`candid://auth-callback`, a custom URL scheme registered in
`Config/Info.plist` (`CFBundleURLTypes`) and handled by `CandidApp`'s
`onOpenURL`, which hands the callback URL to `client.auth.session(from:)`. The
same scheme carries invite links: `candid://invite/<code>` is routed to
`PendingInvite` instead, and the sign-up form opens with the code filled in.

Two things this repo does *not* configure, since neither is a `config.toml`
key:

* **Leaked-password protection** (Dashboard → Authentication → Providers →
  Email → "Prevent use of leaked passwords") — turn on by hand if the plan
  allows it.
* **Custom SMTP** (`[auth.email.smtp]`) — the built-in mailer is rate-limited
  (2 emails/hour) and fine for testing, not for real signup volume. Needs a
  provider account before launch.

> **`supabase config push` pushes the whole `[auth]` block, not just what you
> edited, and it applies immediately with no confirmation prompt.** Anything in
> `config.toml` that differs from the hosted project gets overwritten, including
> `init` defaults you never touched. Diff before pushing, and keep this file
> matching the hosted project's intended state rather than the local-stack
> defaults.

### CLI setup

The CLI is installed globally via npm (there is no Homebrew on this machine):

```bash
npm install -g supabase
```

Authenticate once, then link the repo to the hosted project:

```bash
supabase login
supabase link --project-ref ztdggewgqaoaixjhttct
```

`link` asks for the database password set when the project was created. Once linked,
`supabase db push` applies any new migrations to the hosted database.

### Seed data

`supabase/seed.sql` creates ten test accounts (`alice` through `judy`, all
`{username}@seed.candid.test`, password `CandidSeed123!`) and 30 posts spread
across them and over the last two weeks — enough to page through and to
eyeball relative timestamps, unlike the couple of posts real manual testing
produces. `.test` is reserved by RFC 2606 and never resolves, so these
addresses need no confirmation email and could not sign up through the app's
own UI anyway (GoTrue's sign-up validates deliverability); the script writes
directly into `auth.users`/`auth.identities` instead, the same rows a real
sign-up produces.

Run it with database-owner privileges — the publishable key the app uses
cannot do this, by design:

```bash
supabase db query --linked -f supabase/seed.sql
```

or paste the file into the Dashboard's SQL Editor. It's idempotent: every run
deletes and recreates everything scoped to the `@seed.candid.test` suffix
first, so re-running never accumulates duplicates.

The follow graph is seeded too: alice ↔ bob (the one mutual pair, so
`mutuals` returns exactly two rows), carol → alice and ivan → alice (one-way),
a light scattering of one-way edges among dave through heidi, and judy
connected to nobody — the shapes the visibility rules need to be checked
against. Visibility is seeded deterministically: each account's third post is
friends-only and the other two are followers-only, with the tier named in the
caption, so a tester can tell which rows a one-way follower is supposed to be
missing. One block is seeded: dave blocks erin, two accounts with no other tie,
so the visibility rule's "blocked in either direction" check can be tested
from both sides without the block having disturbed the follow graph. Since
the sign-up trigger requires an invite, the seed first sets
`candid.allow_uninvited_signup` for its session, then gives alice three codes:
`CANDD-SEED2` (valid — sign a new account up with it), `CANDD-SEED3` (redeemed
by bob) and `CANDD-SEED4` (expired). Re-seeding recreates alice, which drops
those rows and any follow edges a real account made with her.

## Conventions

- Bundle identifier: `com.firstzion.candid`
- Dependencies: [supabase-swift](https://github.com/supabase/supabase-swift) via
  Swift Package Manager, pinned in `Package.resolved` (committed)
- Swift language version: 6.0, strict concurrency checking on throughout
- UI is intentionally unstyled — visual design arrives in a later ticket.
