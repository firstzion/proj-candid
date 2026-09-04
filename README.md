# Candid

[![CI](https://github.com/firstzion/proj-candid/actions/workflows/ci.yml/badge.svg)](https://github.com/firstzion/proj-candid/actions/workflows/ci.yml)

An iOS-first photo-sharing app built for human connection, not engagement metrics.
No bots, no AI-generated content, no ads — what you see comes from your friends.

Tracked in Linear: [Project Candid](https://linear.app/cspurlock/project/project-candid-c54ab6260b06/overview)

## Status

Three-tab shell (Feed, Post, Profile) with placeholder views, wired to a hosted
Supabase backend. Accounts work: a user can sign up and log in. Feed and Post are
still placeholders.

The Post tab creates a post end to end: pick from the photo library (or capture
with the camera on a device that has one), preview it, add an optional caption,
and publish. The image is uploaded first and the row written second, so a failure
never leaves a post pointing at an image that does not exist. Blank captions are
stored as NULL rather than an empty string.

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
- No third-party dependencies yet

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

Unit tests live in `CandidTests/` and use Swift Testing. They cover the pure
logic most likely to rot quietly: the error-mapping functions, which translate
opaque Supabase errors into wording a person can act on, and the image
downscaling arithmetic. Both have already regressed once.

## Project layout

```
Candid.xcodeproj      Xcode project (uses synchronized folders — files on disk are
                      picked up automatically, no need to add them to the target)
Config/               Build configuration; Secrets.xcconfig here is gitignored
Candid/
  CandidApp.swift     App entry point
  Models/             Profile
  ViewModels/         SessionStore — mirrors the SDK's auth state
  Services/           SupabaseService, AuthService, ProfileService
  Views/              RootView (session gate), auth screens, RootTabView and tabs
    Components/       Small shared form controls
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
| `posts` | `id` (PK), `user_id` (→ `profiles`), `image_path`, `caption` (nullable, ≤ 2,200 characters), `created_at` |

A trigger on `auth.users` auto-creates the matching `profiles` row at sign-up,
taking `username` from the sign-up metadata and falling back to a generated
placeholder (`user_` plus 25 hex characters of the user's id, to fit the length
limit). Deleting an auth user cascades to their profile and posts.

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

RLS is enabled on both tables. Reads are open to any authenticated user; inserts
and updates are restricted to the caller's own rows. There are no delete policies,
so deletes are denied outright. **These read policies are dev-only** — Candid is
meant to show you your friends' posts, so reads will need to narrow to a friend
graph once one exists. The migration says so at the top.

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
write into another user's folder. A delete policy is scoped the same way, so a
user can remove only their own objects: the client uses it to take back an upload
whose post row failed to be written, and it is what deleting a post or an account
will need. There is no update policy — posts are immutable, and an overwrite of a
referenced object would silently change a post's photo.

Because the bucket is private, reads go through short-lived signed URLs rather
than permanent public ones. The durable identifier for an image is therefore its
object **path**, which is what `posts.image_path` stores; `StorageService.signedURLs(for:)`
mints URLs on demand, a page at a time. Public buckets were the simpler option, but a public bucket
makes every uploaded photo fetchable forever by anyone with the URL, which is hard
to reconcile with an app built around sharing to friends — and it is a one-way
door, since anything already exposed stays exposed.

Uploads are downscaled to a 1600px longest edge and encoded as JPEG at 80%.
Photos are decoded straight to that size when picked (`ImageDownsampler`, via
ImageIO's thumbnailing), so the full-size bitmap — around 200 MB for a
48-megapixel HEIC — is never built; camera captures are downscaled before they
are held. On the read side the feed keeps decoded images in `ImageCache`, keyed
by storage path rather than URL: a signed URL is different every time it is
minted, which defeats `AsyncImage` and `URLCache` and had every refresh
re-downloading every image. A freshly uploaded photo is seeded into the cache so
the poster's own post appears without a download.

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

## Conventions

- Bundle identifier: `com.firstzion.candid`
- Dependencies: [supabase-swift](https://github.com/supabase/supabase-swift) via
  Swift Package Manager, pinned in `Package.resolved` (committed)
- Swift language version: 5.0
- UI is intentionally unstyled — visual design arrives in a later ticket.
