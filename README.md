# Candid

An iOS-first photo-sharing app built for human connection, not engagement metrics.
No bots, no AI-generated content, no ads — what you see comes from your friends.

Tracked in Linear: [Project Candid](https://linear.app/cspurlock/project/project-candid-c54ab6260b06/overview)

## Status

Three-tab shell (Feed, Post, Profile) with placeholder views, wired to a hosted
Supabase backend. Accounts work: a user can sign up and log in. Feed and Post are
still placeholders.

The app root is session-gated: `RootView` shows the Log In screen when signed out
and the main tabs when signed in, driven by `SessionStore` mirroring the SDK's
`authStateChanges`. Sessions are persisted and refreshed by the Supabase SDK
itself — `defaultLocalStorage` is `KeychainLocalStorage` and `autoRefreshToken`
defaults to true — so there is no custom persistence here. The Profile tab shows
the signed-in user's username from their `profiles` row, plus Log Out.

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
  Resources/          Asset catalog
supabase/             CLI config and versioned migrations
```

Empty folders are held in git by a `.gitkeep` file. These are excluded from the build
via `EXCLUDED_SOURCE_FILE_NAMES`, since Xcode's synchronized folders would otherwise
copy them into the app bundle.

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
| `profiles` | `id` (PK → `auth.users`), `username` (unique), `created_at` |
| `posts` | `id` (PK), `user_id` (→ `profiles`), `image_url`, `caption` (nullable), `created_at` |

A trigger on `auth.users` auto-creates the matching `profiles` row at sign-up,
taking `username` from the sign-up metadata and falling back to a generated
placeholder. Deleting an auth user cascades to their profile and posts.

RLS is enabled on both tables. Reads are open to any authenticated user; inserts
and updates are restricted to the caller's own rows. There are no delete policies,
so deletes are denied outright. **These read policies are dev-only** — Candid is
meant to show you your friends' posts, so reads will need to narrow to a friend
graph once one exists. The migration says so at the top.

### Auth configuration

Hosted auth settings live in `supabase/config.toml` under `[auth]` and are applied
with `supabase config push`. Email confirmation is disabled
(`[auth.email] enable_confirmations = false`) so accounts are usable immediately;
email confirmation is out of scope for the MVP.

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
