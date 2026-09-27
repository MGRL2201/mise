# mise

Personal all-in-one app for iPhone, Mac, and Apple Watch: tasks,
calendar/planner, finance, notes, and news, with a Today screen tying them
together. One multiplatform SwiftUI codebase, SwiftData storage, local-first,
no backend, no paid services.

Full specification: [SPEC.md](SPEC.md).

## Requirements

- Xcode 26+, macOS 26+ on Apple silicon
- iPhone on iOS 26+
- Apple Watch on watchOS 26+ (optional, Phase 9)
- A free Apple ID (Personal Team) — no paid developer account needed

## Build and sideload (free Apple ID)

1. Open `mise.xcodeproj`.
2. Xcode → Settings → Accounts: add your Apple ID.
3. Create `Config/Signing.local.xcconfig` (git-ignored) with
   `MISE_BUNDLE_PREFIX = <your.reverse.domain>` and
   `DEVELOPMENT_TEAM = <your team id>` (or pick the team in Signing &
   Capabilities). Bundle ids become `<prefix>.mise`; the committed default
   prefix `com.example` is in `Config/Signing.shared.xcconfig`.
4. Connect the iPhone, enable Developer Mode (Settings → Privacy & Security),
   select it as run destination, press Run.
5. First launch: trust the developer profile in Settings → General →
   VPN & Device Management.
6. The build expires after 7 days — re-run from Xcode (or use SideStore/AltStore
   to auto-refresh). Free accounts allow 3 sideloaded apps and 10 App IDs/week.

For the Mac, select "My Mac" as the destination and Run.

For the Apple Watch, enable Developer Mode on the watch, select the watch app
scheme and the watch as destination, and Run. Same 7-day expiry.

API keys (e.g. stock prices) are entered in the app at runtime and stored in
the Keychain. Never commit keys; `*.xcconfig` files are git-ignored except the committed
defaults in `*.shared.xcconfig`.

## Branch workflow

- `main` — released/stable. Only updated by PR from `develop`.
- `develop` — integration branch and GitHub default branch.
- `feature/<issue#>-<slug>` — one branch per issue, branched from `develop`,
  e.g. `feature/12-eventkit-reminders-layer`.

Both `main` and `develop` are protected: changes land only via pull request,
no force pushes, no deletion, rules apply to admins too. Required approvals are
0 (solo developer).

Flow: pick issue → branch from `develop` → commit → PR into `develop`
("Closes #N") → squash-merge. Branches are deleted automatically on merge.

Merge rules (GitHub rulesets): `develop` accepts squash merges only (one
commit per change); `main` accepts merge commits only, so `main` never drifts
from `develop`.

## Releasing a phase

When every issue in a phase milestone is closed:

1. Open a PR from `develop` into `main` titled `release: phase N`.
2. Merge it with a merge commit.
3. Tag the merge commit and push the tag:
   `git tag -a phase-N -m "Phase N" && git push origin phase-N`.
