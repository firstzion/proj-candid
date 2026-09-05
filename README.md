# Candid

[![CI](https://github.com/firstzion/proj-candid/actions/workflows/ci.yml/badge.svg)](https://github.com/firstzion/proj-candid/actions/workflows/ci.yml)

An iOS-first photo-sharing app built for human connection, not engagement metrics.
No bots, no AI-generated content, no ads — what you see comes from your friends.

Tracked in Linear: [Project Candid](https://linear.app/cspurlock/project/project-candid-c54ab6260b06/overview)

## Status

Milestones 1–7 are done. What is left is two hands-on smoke tests, the tail of
the September 2026 code review, and getting the app onto a physical device.

| Milestone | State |
|---|---|
| 1–4 · Foundation, accounts, posting, feed | Done |
| 5 · Code review follow-ups | Done |
| 6 · Schema and storage hardening | Done |
| 7 · Social graph and visibility | Done |
| 8 · Profiles, discovery and post management | Smoke test left (SOL-67) |
| 9 · Invite-only onboarding | Smoke test left (SOL-64) |
| 10 · On-device testing | Not started |
| 11 · Code review follow-ups (Milestones 7–9) | In progress |

Linear is where the per-card detail lives — what each milestone contains, why
a decision went the way it did, and what is still open. This section says only
where things stand; the sections below say how the parts work.

## What's built

Enough for a small group to use end to end: sign up with an invite, post a
photo to a chosen audience, read a feed filtered by who you follow, find and
follow people, change your username, block or report someone, and delete your
account. Authorization is not the app's business — one Postgres function,
`can_view_post()`, decides every read of a post or a post image, and the
client sends no filter of its own (see Schema). Uploads carry no metadata
(SOL-44), posts can be deleted (SOL-38), reports collect where only the
project owner can read them (SOL-42), and every screen that can be empty says
something deliberate and points somewhere (SOL-40).

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

CI (`.github/workflows/ci.yml`) runs the same command on pushes to `main` and
on pull requests against it, asking `simctl` for a simulator rather than
hardcoding a device name, so a machine with a different set installed still
builds.

The `test` job runs on a **self-hosted macOS runner**, not a GitHub-hosted
one, so jobs queue until that Mac is online. GitHub's macOS runners bill at
ten times the Linux rate on a private repo, which made this one job
effectively the entire Actions budget — around seventy billed minutes per
push, against two for the `schema` job. Markdown-only commits are skipped and
a newer push cancels an older run, for the same reason.

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
`_` escaped, capped — and the inputs answered empty without one.
`ReportServiceTests` pins both report shapes, the repeat treated as success
and the refusal that stays vague. All of them
build their client with `TestSupabaseClient` in
`CandidTests/Support/`.

`PagedPostsTests` is the exception that needs no HTTP at all. `PagedPosts`
(SOL-71) takes a `PostsPaging` rather than a `FeedService`, so a test can
hand over a page on its own schedule — which is the only practical way to
prove the guard that drops a `loadMore` overtaken by a refresh, since staging
that through canned responses means blocking inside a `URLSession` callback.
The same suite covers the id-dedupe on append, the retry after a failed page,
a failed refresh leaving posts on screen, and the staleness boundary.

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
except for someone the owner has blocked; search, whose view omits you, your
blocks and your blockers; and reports — insert-only, only what the reporter
could see, a repeat refused, one about nothing refused, unreadable to
everyone, surviving the post's deletion and the reported account's.
Everything it touches is rolled back. CI (`.github/workflows/ci.yml`,
`schema` job) runs it on every push to `main`, against migrations and seed data applied
fresh to a throwaway database via `supabase start` and `supabase db reset` —
so a migration that breaks a policy or a grant fails in minutes instead of
waiting for the next manual run (SOL-81). That local run is a stand-in: the
way to check the live database itself, after an actual `supabase db push`, is
still to run it there directly:

```bash
supabase db query --linked -f supabase/tests/visibility_matrix.sql
```

It prints `all checks passed`, or stops at the first failing case, either
way.

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
                      PagedPosts (one page-at-a-time list of posts, shared by
                      the feed and the profile grid),
                      FeedInvalidation (tells the feed to refresh after a post),
                      PendingInvite (a code that arrived by deep link),
                      TabSelection (which tab is showing, for empty states)
  Services/           AppServices (DI container built at launch), SupabaseService,
                      AuthService, ProfileService, PostService, FeedService,
                      FollowService, InviteService, ReportService, StorageService,
                      ImageCache, ImageDownsampler, ServiceErrors (shared error
                      mapping), Log
  Views/              RootView (session gate), ConfigurationErrorView, auth
                      screens, RootTabView and tabs, ProfileScreen (yours and
                      everyone else's), FollowListView, PostDetailView,
                      InvitesView, EditUsernameSheet, PeopleView (the People tab),
                      ReportSheet, EmptyStates (the six empty states' copy)
    Components/       PostImageView, LoadMoreFooter, the delete-post and
                      report-then-block flows, shared form controls
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
| `reports` | `id` (PK), `reporter_id` (→ `profiles`, cascade), `reported_profile_id` (→ `profiles`, set null), `reported_post_id` (→ `posts`, set null), `about_post`, `reason` (enum), `details` (≤ 500), `status` (`open` \| `reviewed` \| `actioned`), `created_at`; CHECK `reporter_id <> reported_profile_id` |

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
accident. The feed marks `mutuals` posts "Friends only" so you can tell which
audience a photo went to, and the app mirrors the enum in `PostVisibility`,
whose raw values are the Postgres labels.

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
10^15 possibilities, expiring after 30 days — the server's own constant since
SOL-70, not a caller-supplied argument PostgREST would otherwise pass through
as-is. `invite_status(code)`
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
The `can_view_post()` family lives there too, and so does
`image_is_referenced()` (SOL-69) — moved from `public`, where a direct
default grant had left it callable by `anon` even after its own migration
revoked `execute` from `public`. Trigger functions stay in `public` with
`execute` revoked, as `handle_new_user` does — a trigger needs no callers.

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

`reports` captures a complaint about a post or a person (SOL-42) and nothing
more yet: the review surface is SOL-45, and until it exists reports accumulate
here, readable by nobody through the API — not even the reporter — and by the
project owner in the SQL editor: `select * from reports order by created_at
desc`. That is a known pre-launch state, not an oversight. A report always
names a person (`reported_profile_id`, filled from the post's author by a
trigger when a post is named) and optionally the post; both foreign keys are
`on delete set null`, so a report outlives its post and, since SOL-82, the
reported account too — abuse history should not be erasable by the account
it is about, and before SOL-45's moderation dashboard exists that account has
no other reason to delete itself. `about_post` remembers which kind a report
was once its post is gone, so the one-report-per-person uniqueness cannot
collide with an old post report and make deleting a post fail. A post id
that resolves to nothing refuses the same way a hidden one does (SOL-82),
so the table still cannot be used to tell "doesn't exist" apart from "exists
but hidden". A report naming neither a post nor a person is refused by the
same trigger — a raw-client path the nullable column opened, closed in
`20260905160000`, and deliberately a trigger guard rather than a CHECK:
the set-null cascades are UPDATEs, and a CHECK would fire on them and fail
the very deletions they exist to allow. Insert-only RLS: the reporter is the caller, and a reported post
must pass
`can_view_post()` for them. A repeat report is refused by a partial unique index, which `ReportService`
treats as success. Reporting is silent to the reported account, and the sheet
offers a block right after, since the reporter usually wants the content gone
from their own view now.

Empty states (SOL-40) live in one place, `EmptyState`, with `EmptyStateView`
drawing them. The feed tells its two empties apart with
`FollowService.followingCount()`: following nobody — what you see after
unfollowing everyone, since an invite makes a new account's first feed
non-empty — points to the People tab, and following people who haven't posted
just says so. Your own profile with no posts points to the Post tab; someone
else's with none you can see says one neutral thing for both meanings, on
purpose — the count and the grid are read under RLS, so an account with three
friends-only posts reads exactly like one with none. Search with no results
says which query, and a blocked profile — reachable only by the blocker, since
the profiles policy hides the blocker from the blocked — shows "You've blocked
@name" with Unblock and no grid. `TabSelection`, owned by `RootTabView` and
shared through the environment, is the one piece of plumbing: the two states
that jump set it.

Before creating the auth user, sign-up also asks `username_available(text)`
whether the name is still free. The person asking has no session yet and
`profiles` is readable only by `authenticated`, so the function is `security
definer`, callable by `anon`, and returns exactly one bit — the one thing about
the table that sign-up reveals anyway. The answer is advisory: two people can be
told "free" at once and one then loses the race inside the trigger, which is why
the sanitised database error is now reported as a failed creation whose username
*may* have been taken, rather than asserted as taken — that assertion used to
turn every server-side failure into a report of a user mistake.

RLS is enabled on all seven tables, and the read policies are where the
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

Row scoping alone left every column of a row you could reach writable, not
just the ones the app sends: Supabase's default privileges grant `anon` and
`authenticated` every table privilege on every table and view in `public`,
and RLS was the only thing narrowing them. Two migrations close that. SOL-68
(`20260905023000`) took everything from `anon` and made the app's inserts
and its one update column-level. `20260905170000` finishes the job for
`authenticated`: every privilege is revoked and exactly what a policy uses is
granted back — `select` where a read policy exists, `delete` on `posts`,
`follows`, `blocks` and `invites`, `update` of `profiles.username` only (not
`invite_quota`, which the project owner raises by hand in the SQL editor),
and inserts of `(user_id, image_path, caption, visibility)` on `posts`,
`(follower_id, followee_id)` on `follows`, `(blocker_id, blocked_id)` on
`blocks` and `(reporter_id, reported_profile_id, reported_post_id, reason,
details)` on `reports` — every `id`, every `created_at` and a report's own
`status` are the server's alone. Nothing holds `truncate`, `trigger` or
`references`, and the two views are `select`-only. The default privileges
themselves are revoked for the role that runs migrations, for tables and for
functions, so a new table or function starts closed and its migration has to
say who may use it; the visibility matrix asserts the whole shape, so a
forgotten grant fails CI rather than the app. Grants and policies are two
locks, and a future policy without its grant does nothing — which is the
point.

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
write into another user's folder. The same policy caps an account at
`private.post_image_cap()` objects — 1,000, a product number as much as a
safety one, and one constant to change (`20260905171000`). The count comes
from a `security definer` helper that reads `auth.uid()` itself, because a
policy on `storage.objects` cannot query `storage.objects` — Postgres refuses
the self-reference as recursive — and because the helper must count the
whole folder, not what the caller's own select policy shows. A delete policy is scoped the same way, and
further requires the object to be **unreferenced** — no `posts` row may still
point at it, checked via a `security definer` `private.image_is_referenced()`
helper (moved from `public` in SOL-69, so `anon` cannot call it as an RPC)
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

The cache holds a second keyspace, `path#side`, for the profile grid (SOL-80).
A grid cell is about 130 pt wide and was drawing the full 1600 px upload —
roughly 7 MB of bitmap for a sixteenth of that area — so a page of twenty
cells filled the 100 MB cost limit, evicted itself and re-downloaded on the
way back up. Thumbnails are scaled on their *shorter* edge, because a square
cell covers itself by clipping the overflow; capping the longer edge would
hand the cell an image too small and leave it upscaling. Each is derived from
the full image, which is kept as well, so tapping a cell opens
`PostDetailView` on something already decoded.

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
whether a session came back, and `SignUpView` shows a notice when it didn't.
With confirmations on, GoTrue also answers a sign-up for an address that
*already* has an account with the same no-session success rather than
`email_exists`, so the form can never be used to learn which addresses are
registered — the notice's wording (SOL-84) is written to be true for a new
address and an existing one alike, without saying which happened. Sign-up
also requires an invite code (see Invites under
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
