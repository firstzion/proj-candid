# Candid

An iOS-first photo-sharing app built for human connection, not engagement metrics.
No bots, no AI-generated content, no ads — what you see comes from your friends.

Tracked in Linear: [Project Candid](https://linear.app/cspurlock/project/project-candid-c54ab6260b06/overview)

## Status

Scaffold only. The app builds and launches to a three-tab shell (Feed, Post, Profile)
with placeholder views. No backend, no real functionality yet.

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
Candid/
  CandidApp.swift     App entry point
  Models/             Data types (empty)
  ViewModels/         View state and logic (empty)
  Services/           Backend and platform services (empty)
  Views/              SwiftUI views — RootTabView plus the three tab placeholders
  Resources/          Asset catalog
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
- Swift language version: 5.0
- UI is intentionally unstyled — visual design arrives in a later ticket.
