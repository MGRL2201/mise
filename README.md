# mise

Personal all-in-one app for iPhone and Mac: tasks, calendar/planner, finance,
notes, and news, with a Today screen tying them together. One multiplatform
SwiftUI codebase, SwiftData storage, local-first, no backend, no paid services.

Full specification: [SPEC.md](SPEC.md).

## Requirements

- Xcode 26+, macOS 26+ on Apple silicon
- iPhone on iOS 26+
- A free Apple ID (Personal Team) — no paid developer account needed

## Build and sideload (free Apple ID)

1. Open the Xcode project (created in Phase 1).
2. Xcode → Settings → Accounts: add your Apple ID.
3. Target → Signing & Capabilities: Team = "<your name> (Personal Team)";
   change the bundle identifier to something unique to you.
4. Connect the iPhone, enable Developer Mode (Settings → Privacy & Security),
   select it as run destination, press Run.
5. First launch: trust the developer profile in Settings → General →
   VPN & Device Management.
6. The build expires after 7 days — re-run from Xcode (or use SideStore/AltStore
   to auto-refresh). Free accounts allow 3 sideloaded apps and 10 App IDs/week.

For the Mac, select "My Mac" as the destination and Run.

API keys (e.g. stock prices) are entered in the app at runtime and stored in
the Keychain. Never commit keys; `*.xcconfig` files are git-ignored.

## Branch workflow

- `main` — released/stable. Only updated by PR from `develop`.
- `develop` — integration branch and GitHub default branch.
- `feature/<issue#>-<slug>` — one branch per issue, branched from `develop`,
  e.g. `feature/12-eventkit-reminders-layer`.

Both `main` and `develop` are protected: changes land only via pull request,
no force pushes, no deletion, rules apply to admins too. Required approvals are
0 (solo developer).

Flow: pick issue → branch from `develop` → commit → PR into `develop`
("Closes #N") → merge. At a milestone, PR `develop` → `main`.
