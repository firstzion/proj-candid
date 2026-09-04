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
derived `mutuals` view and `FollowService` — and so is per-post visibility,
chosen at posting time and fixed from then on. The authorization rule that
makes the feed honour both, blocking, and the follow UI are still to come.

The Post tab creates a post end to end: pick from the photo library (or capture
with the camera on a device that has one), preview it, add an optional caption,
choose who can see it — everyone who follows you, or friends only — and publish.
The image is uploaded first and the row written second, so a failure never
leaves a post pointing at an image that does not exist. Blank captions are
stored as NULL rather than an empty string. The audience picker starts on
Followers and then keeps whatever was chosen last rather than resetting after
each post: of the two mistakes a reset invites, sending a friends-only photo to
every follower is the one that can't be taken back.

The Feed tab shows posts newest-first with pull-to-refresh and pagination. It
refreshes itself when it goes stale (signed image URLs expire) and also right
after you post, so a just-posted photo does not sit unseen for up to half an
hour. Decoded images are cached by storage path rather than URL, so a refresh
does not re-download every photo already on screen.

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
auto-refresh eventually got through. The Profile tab shows the signed-in user's
username from their `profiles` row, plus Log Out.

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
Supabase errors into wording a person can act on; `UsernameRules`; and the
image downscaling and downsampling arithmetic. The error mappers and the
downscaling arithmetic have both already regressed once.

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
stand in for. Both suites build their client with `TestSupabaseClient` in
`CandidTests/Support/`.

## Project layout

```
Candid.xcodeproj      Xcode project (uses synchronized folders — files on disk are
                      picked up automatically, no need to add them to the target)
Config/               Build configuration; Secrets.xcconfig here is gitignored
Candid/
  CandidApp.swift     App entry point
  Models/             FeedPost/FeedPage/FeedCursor, Profile, Relationship,
                      UsernameRules
  ViewModels/         SessionStore (mirrors the SDK's auth state),
                      FeedInvalidation (tells the feed to refresh after a post)
  Services/           AppServices (DI container built at launch), SupabaseService,
                      AuthService, ProfileService, PostService, FeedService,
                      FollowService, StorageService, ImageCache, ImageDownsampler
  Views/              RootView (session gate), ConfigurationErrorView, auth
                      screens, RootTabView and tabs
    Components/       PostImageView, shared form controls
  Resources/          Asset catalog
CandidTests/          Unit tests (Swift Testing)
supabase/             CLI config and versioned migrations
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
| `profiles` | `id` (PK → `auth.users`), `username` (unique, `^[a-z0-9_]{3,30}$`), `created_at` |
| `posts` | `id` (PK), `user_id` (→ `profiles`), `image_path`, `caption` (nullable, ≤ 2,200 characters), `visibility` (`followers` \| `mutuals`, default `followers`, immutable), `created_at` |
| `follows` | `follower_id` (→ `profiles`), `followee_id` (→ `profiles`), `created_at`; PK (`follower_id`, `followee_id`), CHECK `follower_id <> followee_id` |

A trigger on `auth.users` auto-creates the matching `profiles` row at sign-up,
taking `username` from the sign-up metadata and falling back to a generated
placeholder (`user_` plus 25 hex characters of the user's id, to fit the length
limit). Deleting an auth user cascades to their profile, posts and follow edges.

`follows` is the social graph: one row per directional edge, where `(a, b)`
means a follows b. Following is open — anyone can follow anyone, with no
approval and no pending state. "Friends" means a mutual follow, and it is
derived, never stored: the `mutuals` view is a self-join on `follows` that
returns both `(user_id, mutual_id)` and its mirror, so "is a mutual with b" is
one equality lookup, and it is the single definition of friendship that the
visibility rule and any future ranking read from. It is a `security_invoker`
view, so it runs under the caller's own RLS on `follows` rather than its
owner's. There are no follower/following counter columns — `count(*)` is fine
at this scale, and counters need triggers that will be wrong at least once.
The composite primary key makes a duplicate follow impossible at the database;
`FollowService.follow` treats that refusal as success, since the state asked
for already holds and a double tap must not read as a failure. `FollowService`
also offers `unfollow`, `isFollowing`, `isMutual` (which reads `mutuals`) and
`relationship(with:)`, which fetches both directions in one request. There is
no follow UI yet.

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

Usernames are stored lowercase. The trigger lowercases and trims what the
metadata carries, and a CHECK constraint enforces `^[a-z0-9_]{3,30}$`; because
only lowercase is ever stored, the plain unique constraint is case-insensitive
by construction — `Alice` and `alice` cannot be two people. The app mirrors the
rules in `UsernameRules` so the sign-up form can say exactly what is wrong before
sending anything: a CHECK failure inside the trigger only reaches the client as
GoTrue's sanitised "Database error saving new user". Captions are capped at
2,200 characters the same way, checked client-side before the image is uploaded.

Before creating the auth user, sign-up also asks `username_available(text)`
whether the name is still free. The person asking has no session yet and
`profiles` is readable only by `authenticated`, so the function is `security
definer`, callable by `anon`, and returns exactly one bit — the one thing about
the table that sign-up reveals anyway. The answer is advisory: two people can be
told "free" at once and one then loses the race inside the trigger, which is why
the sanitised database error is now reported as a failed creation whose username
*may* have been taken, rather than asserted as taken — that assertion used to
turn every server-side failure into a report of a user mistake.

RLS is enabled on all three tables. Reads are open to any authenticated user.
On `profiles`, inserts and updates are restricted to the caller's own rows; on
`posts`, inserts are, and there is no update policy at all, since posts are
immutable (see visibility above). Neither has a delete policy, so a client can
never delete a row directly — but `delete_own_account()` deletes the caller's own `auth.users`
row, cascading to their `profiles` row, every `posts` row they own and every
`follows` edge in either direction; see Account deletion below. Deleting a
single post without deleting the whole account isn't possible yet. On
`follows`, a user may insert and delete only edges where they are the
follower — you can unfollow someone, you cannot remove one of your followers —
and there is no update policy, since nothing on an edge can change. **The
`profiles` and `posts` read policies are dev-only** — Candid is meant to show
you your friends' posts, so those reads narrow to the follow graph when the
`can_view_post()` rule lands (SOL-30). Follows themselves stay readable by
every authenticated user on purpose: follower counts and the relationship line
on a profile need edges the caller didn't create.

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
that stays exact even once reads narrow to a friend graph. The client uses it
to take back an upload whose post row failed to be written, and account
deletion uses it too — see below. Deleting a single post isn't possible yet;
when it lands, it needs the same "row first, then object" ordering account
deletion already uses. There is no update policy — posts are immutable, and an
overwrite of a referenced object would silently change a post's photo.

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
than any retry logic in the image view itself.

Uploads are downscaled to a 1600px longest edge and encoded as JPEG at 80%.
Photos are decoded straight to that size when picked (`ImageDownsampler`, via
ImageIO's thumbnailing), so the full-size bitmap — around 200 MB for a
48-megapixel HEIC — is never built; camera captures are downscaled before they
are held. On the read side the feed keeps decoded images in `ImageCache`, keyed
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
notice when it didn't. `minimum_password_length` is 10, with no composition
rules (NIST SP 800-63B favours length over forced character classes).
Confirmation, password-reset, and magic-link emails link to
`candid://auth-callback`, a custom URL scheme registered in
`Config/Info.plist` (`CFBundleURLTypes`) and handled by `CandidApp`'s
`onOpenURL`, which hands the callback URL to `client.auth.session(from:)`.

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
missing. Blocking belongs here as well, but `blocks`
([SOL-31](https://linear.app/cspurlock/issue/SOL-31/blocking)) doesn't exist
yet; that section is written out and commented, ready to uncomment once the
table lands.

## Conventions

- Bundle identifier: `com.firstzion.candid`
- Dependencies: [supabase-swift](https://github.com/supabase/supabase-swift) via
  Swift Package Manager, pinned in `Package.resolved` (committed)
- Swift language version: 6.0, strict concurrency checking on throughout
- UI is intentionally unstyled — visual design arrives in a later ticket.
