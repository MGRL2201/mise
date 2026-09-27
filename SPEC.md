# mise — Product & Technical Specification

## 1. Overview

mise is a personal, all-in-one productivity app for a single user. It combines
tasks and reminders, a planner/calendar, personal finance, notes, and a news
reader into one native app, with a "Today" screen that pulls the most relevant
pieces of each module together.

The app is built as a single multiplatform SwiftUI codebase targeting iPhone
and Mac, with an Apple Watch companion app (glance, check-off, voice capture,
complications) added in a later phase. It is local-first: there is no backend
server and no paid service.
Data either lives in Apple's own system stores (Reminders and Calendar via
EventKit) or in the app's own SwiftData store on each device, with an optional
file-based sync between devices.

## 2. Platforms and constraints

### 2.1 Target devices

- **iOS:** iPhone 16 Pro Max, iOS 26 or later.
- **macOS:** macOS 26 or later, Apple silicon.
- **watchOS:** Apple Watch paired with the iPhone, watchOS 26 or later
  (Phase 9).
- One multiplatform SwiftUI project with shared code; platform-specific UI
  where it matters (tab bar on iPhone, sidebar on Mac).
- Local persistence with SwiftData.

### 2.2 Distribution: free Apple ID (Personal Team)

The app is installed with Xcode using a free Personal Team — there is no paid
Apple Developer Program membership. This implies:

- iOS builds expire after **7 days** and must be re-signed. SideStore or
  AltStore can automate refresh later.
- At most **3 sideloaded apps** active at once on a device, and at most
  **10 App IDs per week**. Every extension (widget, share extension, intents)
  consumes an App ID, so extensions must be added deliberately.
- The **watchOS app** (Phase 9) uses about **2 more App IDs**: the watch app
  and its widget/complication extension. The watch needs Developer Mode
  enabled, and the same 7-day re-sign applies to it.
- Everything is local-first. No server, no paid APIs.

### 2.3 Capabilities available on a free account

Per Apple's capability table for free accounts:

| Capability | Status |
|---|---|
| App Groups | Works on free account (verified on device, #10 — §12) |
| Keychain Sharing | Works on free account (verified on device, #10 — §12) |
| iCloud / CloudKit | Not allowed |
| Push notifications | Not allowed |
| Siri (legacy SiriKit) | Not allowed |
| Time-sensitive notifications | Not allowed |
| Local notifications | Fine |
| EventKit | Fine |
| VisionKit, Vision OCR | Fine |
| Foundation Models (on-device) | Fine |
| LocalAuthentication (Face ID / Touch ID) | Fine |
| Background modes | Fine |
| MapKit | Fine |
| WatchConnectivity | Fine (no entitlement) |
| Foundation Models on watchOS | Not available on watchOS (any account); delegated to phone |
| EventKit on watchOS | **VERIFY** |

App Intents / App Shortcuts are not the legacy SiriKit entitlement: they build,
sign, and install on the free account with no entitlement (#12, §12); Siri
invocation is pending a user check on device.

### 2.4 Phase-1 capability spike

Before building features that depend on them, a spike on a real device with
the free account tests:

1. **App Groups** — shared container between app and extensions.
2. **WidgetKit extension** — installs and renders on the Home Screen.
3. **App Intents / App Shortcuts** — e.g. Siri "add task in mise".
4. **Share Extension** — receiving PDFs/images from other apps.

Fallbacks if App Groups are refused:

- The widget reads EventKit directly (tasks and events come from system stores
  anyway).
- The app writes a small snapshot (e.g. budget numbers) to a shared Keychain
  access group that the widget reads.
- PDFs and images come in via registered document types and `fileImporter`
  instead of a share extension.

The spike's findings are recorded in this spec (section 12) and decide which
paths the later phases use.

### 2.5 Future: paid developer account

Paying $99/year would enable CloudKit sync and remove the 7-day signing limit.
The storage layer is designed so it can be moved to CloudKit later (SwiftData
supports CloudKit-backed containers) without rewriting feature modules: feature
code talks to SwiftData models, and sync is a separate layer (section 4).

### 2.6 Secrets and privacy

The repository is public. No secrets, API keys, or personal data are ever
committed. API keys (for example the stock-price provider key) are entered by
the user at runtime in Settings and stored in the **Keychain**. No build
configuration file contains secrets; any local `*.xcconfig` holding secrets is
git-ignored.

## 3. Architecture notes

- **UI:** SwiftUI, multiplatform target. `NavigationSplitView` sidebar on Mac,
  `TabView` on iPhone.
- **Storage:**
  - Tasks and events live in the system stores via **EventKit** (Reminders,
    Calendar). mise does not duplicate them; it stores only app-only extras
    (subtasks, tags, time-block links) keyed by the EventKit identifier.
  - Everything else (finance, notes, news, settings, attachment metadata) is
    in **SwiftData**. Large attachments (images, PDFs, audio) are files on
    disk referenced from SwiftData.
- **On-device AI:** Apple **Foundation Models** framework for classification,
  natural-language parsing, extraction, summaries, and tidy-up. Context window
  is about 4k tokens, so long inputs are chunked. Requires an Apple
  Intelligence-capable device; features degrade gracefully (manual entry)
  where unavailable.
- **Networking:** only free, keyless or user-keyed public endpoints: CoinGecko,
  Finnhub or Alpha Vantage (user key), Frankfurter (ECB FX), RSS/Atom, Google
  News RSS, Reddit and Hacker News public feeds.
- **Security:** LocalAuthentication for Face ID / Touch ID; Keychain for keys
  and per-note encryption keys; CryptoKit for encrypting locked notes.
- **Background work:** BGAppRefreshTask for news, prices, FX, travel-time ETA.
  iOS schedules these opportunistically, so timing is best-effort.
- **Notifications:** local notifications only (no push, no time-sensitive).

## 4. Mac and cross-device sync

### 4.1 Mac app

The same app runs on the Mac. Mac-specific adaptations:

- Sidebar navigation instead of the tab bar.
- Keyboard shortcuts and menu bar commands for common actions (new task,
  new event, new transaction, new note, search).
- Multiple windows are optional.
- Foundation Models features require an Apple Intelligence-capable Mac.

### 4.2 What syncs, and how

- **Reminders and calendars** already sync through the system accounts
  (iCloud, Exchange/Outlook). mise needs nothing extra for them.
- **App-owned data** (finance, notes, news state, settings, attachments) syncs
  through a **sync folder** in a user-chosen shared location — for example an
  iCloud Drive folder picked via the document picker. Access is kept with a
  **security-scoped bookmark**, which needs no iCloud entitlement.

### 4.3 Locking

The user requires that one device not write while the other is editing or
syncing. Design:

- A **lease-based lock file** in the sync folder containing device id,
  timestamp, expiry, and a heartbeat that renews the lease while the holder is
  active.
- All file access through **NSFileCoordinator**.
- When the lease is held by the other device, the app goes **read-only** and
  shows a banner explaining who holds the lock.
- **Stale leases expire** so a crashed or offline device cannot block the
  other forever.

### 4.4 Conflict detection (safety net)

iCloud Drive propagation is eventually consistent: two devices can each see no
lock and both take it before the other's lock file arrives. The lock is
therefore **best-effort**, not a guarantee. As a safety net:

- Each sync payload carries a **version counter and content hash**.
- **NSFileVersion** is used to detect unresolved conflict versions.
- On conflict, a **conflict-resolution UI** lets the user choose which version
  to keep (or keep both where the data type allows).

This ceiling — the lock reduces but cannot eliminate conflicts — is accepted
and documented here.

## 5. Navigation and app-wide features

- **iOS tab bar:** Today · Tasks · Calendar · Money · More. "More" holds Notes,
  News, and Settings.
- **Theming:** follows system light/dark by default. Fully custom palette via
  the native `ColorPicker` (color wheel): accent, background, surface, text,
  and per-module colors, with separate light and dark variants. Contrast
  warnings when text/background contrast is too low. Presets and reset to
  default.
- **Face ID / Touch ID lock:** user chooses whole-app lock, or lock only
  Finance plus locked notes.
- **Home-screen widgets:** Today; tasks with interactive check-off (a "+"
  deep-links to quick-add, since widgets cannot take text input); budget;
  next event.
- **Backup/restore:** full backup to a single file saved via the Files app;
  optional weekly automatic backup.
- **Global search:** across notes, tasks, events, and transactions.

## 6. Module scope (v1)

### 6.1 Today

- Sections:
  - **Agenda + tasks:** today's events and task time blocks, overdue and
    due-today tasks, next-event countdown.
  - **Money snapshot:** month spend vs budget, bills due soon, net worth change.
  - **News:** AI digest and breaking stories.
  - **Daily note + quick capture.**
- Sections can be reordered and hidden.
- **Quick capture:** a single input box. On-device AI classifies the input as an
  expense ("Coffee 5.50"), a task ("call mom tomorrow 6pm"), or a note. The
  user sees the classification and parsed fields and can correct them before
  saving.

### 6.2 Tasks and reminders

- Backed by **Apple Reminders via EventKit**: title, notes, due date/time,
  priority, lists, recurrence, time alarms, completion. Two-way sync with the
  Reminders app, including deletion in both directions.
- **Subtasks and tags** (not exposed by EventKit) are stored in the app, linked
  by reminder identifier. They are not visible in Apple Reminders.
- **Optional time-blocking** per task: pick start, duration, and calendar
  (Apple or Outlook); mise creates an event linked to the task. Completing the
  task updates the linked event.
- **Views:** Today (overdue + due today), Upcoming (7 days), by list/project,
  by tag/priority, completed log.
- **Quick add** with natural language parsed on-device by Foundation Models,
  e.g. "pay rent every 1st 9am !high".
- **Siri / Shortcuts** via App Intents (spike #12, §12).
- **Widget** with interactive check-off.
- Excluded from v1: location-based reminders.

### 6.3 Planner and calendar

- Apple and Outlook calendars via **EventKit**. Outlook is added as an account
  in iOS/macOS Settings → Calendar → Accounts. No Microsoft Graph integration.
- **Views:** day timeline; custom N-day grid (1–7 days, user adjustable, pinch
  to change); month grid with event dots and tap-for-agenda; agenda list.
- **Create/edit/delete events**, including recurring events with "this event /
  all future events".
- **Default calendar** fixed in Settings, overridable per event.
- **Color per calendar**, show/hide individual calendars.
- **Location and travel time** via MapKit ETA; a "leave now" local
  notification. Limitation: the ETA is refreshed only when background refresh
  runs, so it can be stale.
- **Planning:**
  - Drag unscheduled tasks onto the timeline.
  - Auto-suggest free slots from working-hours setting, task duration
    estimate, and gaps in the calendar.
  - Daily planning prompt: configurable morning notification opening a
    review/pick/schedule screen.
  - Weekly review: configurable day/time; shows last week's completed tasks,
    time per calendar, spend; then plan next week.
- Excluded from v1: attendees and invites.

### 6.4 Finance

- **Accounts:** multiple accounts (cash, debit, credit, brokerage), each with
  its own currency and balance. **Transfers** between accounts, including
  credit-card payments, are not counted as spending.
- **Transaction entry:**
  - Manual entry.
  - Receipt scanning with VisionKit document camera + Vision OCR.
  - Import PDF invoices/bank notices: PDFKit text extraction, OCR for scanned
    PDFs.
  - Bank CSV import with column mapping.
  - On-device Foundation Models extracts merchant, date, total, category,
    currency.
  - There is **always a review screen before saving**. The original image/PDF
    is attached to the transaction.
- **Categories and monthly budgets**, with alerts at 80% and 100%.
- **Recurring bills/subscriptions** with reminders some days before and on the
  due date.
- **Income tracking** and **savings goals** with progress.
- **Investments:** holdings (stocks/ETFs, crypto, funds/retirement) with
  quantity and cost basis.
  - Crypto prices via the **CoinGecko** free API (no key).
  - Stocks/ETFs via a free-key provider (**Finnhub or Alpha Vantage**). The user
    supplies the key at runtime; it is stored in the Keychain. Because of rate
    limits, prices refresh a few times a day.
  - Funds/pensions often lack a feed: manual valuation is the fallback.
  - Show current value and gain/loss.
- **Multi-currency:** daily FX rates from ECB data via the Frankfurter API (no
  key). Home currency is chosen on first launch; all totals are shown in home
  currency.
- **Reports/charts** (Swift Charts): spend by category, monthly trends, net
  worth over time. Month-end summary notification.
- **CSV export** of transactions and holdings.
- Deferred to v2: split transactions.

### 6.5 Notes

- Stored as **Markdown**. The editor renders formatted rich text live using the
  iOS 26 SwiftUI `TextEditor` with `AttributedString`, with a formatting toolbar
  and Markdown shortcuts (`# ` for headings, `- ` for bullets, checkboxes).
  A raw-Markdown toggle shows the source.
- Requires an **AttributedString ↔ Markdown round-trip serializer**. Rich
  formatting with no Markdown equivalent (colors, fonts) is dropped.
- **System Writing Tools** enabled.
- **"Tidy" button:** on-device Foundation Models restructures messy text or
  voice transcripts into Markdown (headings, bullets, checklists). Long notes
  are chunked (~4k token context). A before/after diff is shown and the change
  can be undone.
- **AI summarize** and **extract action items**.
- **Organization:** nested folders, tags (shared with tasks), pinned notes,
  automatic daily note.
- **Content:** photo/scan attachments with OCR text that is searchable; voice
  memos with on-device transcription; file/PDF attachments; links to tasks,
  events, and transactions; convert a checklist line into a task.
- **Per-note Face ID lock**; locked notes are encrypted at rest.
- **Export:** Markdown files plus an attachments folder, to Files.

### 6.6 News

- **Sources:** RSS/Atom feeds; topic follows via Google News RSS search;
  holding-related headlines via Google News search on ticker/name; Reddit and
  Hacker News public feeds.
- **Breaking section:** stories covered by 3 or more sources within 2 hours,
  plus items from wire feeds flagged as breaking. In-app only. Refreshes on app
  open and on background refresh.
- **Daily digest:** on-device AI digest shown on Today, with one morning
  notification for the digest. No other news notifications.
- **Timeline** filterable by source/topic; reader mode with fallback to Safari;
  save-for-later with offline text; read/unread state; duplicate-story
  collapsing. Paywalled sites show the summary only.

### 6.7 Apple Watch

A watchOS app target in the same multiplatform Xcode project, installed via
Xcode with the free Personal Team (see §2.2). Built in Phase 9.

- **Today glance:** next event, today's tasks, budget left.
- **Task check-off** from the wrist, synced back to Reminders via the phone,
  or directly via EventKit if the watchOS EventKit spike passes.
- **Voice quick capture:** dictation (e.g. "coffee 5.50", "call mom 6pm") is
  sent to the phone, where Foundation Models classifies it as expense, task,
  or note (as in §6.1). The watch shows the result for confirmation before
  saving. Foundation Models is not available on watchOS.
- **Complications** (WidgetKit accessory families: `accessoryCircular`,
  `accessoryRectangular`, `accessoryInline`, `accessoryCorner`): next event,
  task count, budget left, net worth.
- **Data flow:**
  - The phone pushes a snapshot (next event, today's tasks, budget left, net
    worth) via WatchConnectivity `applicationContext`.
  - The watch sends actions (check-off, capture text) via `sendMessage`, or
    `transferUserInfo` when the phone is unreachable (queued delivery).
  - The phone applies the action and confirms; the next snapshot reflects it.
  - The complication extension cannot receive WatchConnectivity. The watch
    app writes the snapshot into a shared container (App Groups on watchOS,
    **VERIFY**) that complications read. Fallback: Keychain access group (as
    in §2.4); else complications show no data and a tap opens the app.
  - Direct EventKit on the watch: **VERIFY** (spike). Fallback is the
    phone-relayed data above.
- **Lock:** while Finance lock or whole-app lock (§5) is on, the phone omits
  money fields (budget left, net worth) from the snapshot. Watch UI uses
  `privacySensitive()` so amounts redact when the wrist is locked or in
  always-on.
- **Notifications:** local notifications from the phone app mirror to the
  watch automatically (system behavior) when the phone is locked. No watch
  work needed.

## 7. Deferred / v2

- Split transactions (Finance).
- Location-based reminders (Tasks).
- Attendees and invites (Calendar).
- CloudKit sync and removal of 7-day signing (requires paid developer account).

## 8. Known limitations

- iOS builds must be re-signed every 7 days on a free account.
- Max 3 sideloaded apps and 10 App IDs per week limit how many extensions can
  be added and how often they can be rebuilt with new identifiers.
- No push or time-sensitive notifications; all notifications are local and
  scheduled.
- Background refresh timing is controlled by iOS: "leave now" ETA, news, and
  prices can be stale.
- Cross-device lock is best-effort because iCloud Drive is eventually
  consistent; conflict detection and resolution UI is the safety net.
- Subtasks and tags are not visible in Apple Reminders.
- Foundation Models features require Apple Intelligence-capable hardware and
  have a ~4k token context.
- Free stock-price APIs are rate-limited; funds/pensions may need manual
  valuation.
- Paywalled news shows only the summary.
- Markdown round-trip drops unsupported rich formatting.
- Watch data is only as fresh as the last phone sync.
- Watch quick capture needs the phone reachable for AI classification;
  otherwise it is queued until the phone is reachable.
- The 7-day re-sign covers the watch app too.

## 9. Items to verify (spikes)

- App Groups on a free Personal Team account.
- Keychain Sharing on a free account (fallback channel for widget data).
- WidgetKit extension install and interactive widgets on a free account.
- App Intents / App Shortcuts, including Siri invocation, on a free account.
- Share Extension on a free account.
- iOS 26 `TextEditor` + `AttributedString` capability for live Markdown editing.
- Foundation Models quality for quick-capture classification and receipt
  extraction.
- watchOS app install on a free account, plus WatchConnectivity round-trip.
- EventKit access on watchOS (read and complete reminders directly).
- Watch complications (widget) extension on a free account.
- App Groups on watchOS (complication data sharing).

## 10. Phased build plan

Each phase is a GitHub milestone; each task is a GitHub issue.

1. **Foundation & spikes** — multiplatform Xcode project (iOS + macOS),
   SwiftData setup, tab bar/sidebar navigation, theming engine, Face ID lock,
   backup/restore, capability spike (App Groups, widget, App Intents, share
   extension) on device.
2. **Tasks & Calendar** — EventKit layer, tasks module, calendar module,
   planning features.
3. **Finance core** — accounts, transactions, categories/budgets, bills,
   income/goals, reports, CSV export, FX.
4. **Finance imports & investments** — receipt scan, PDF import, CSV import,
   AI extraction, holdings and price feeds.
5. **Notes.**
6. **News.**
7. **Today screen, widgets, quick capture, global search.**
8. **Mac polish & cross-device sync** — Mac UI adaptations, sync folder, lease
   lock, conflict resolution.
9. **watchOS** — watch app target, phone-watch sync via WatchConnectivity,
   Today glance, task check-off, voice quick capture via phone AI,
   complications, spikes (free-account install, EventKit on watch).

## 11. Development workflow

See `README.md` for the branch model (`main`, `develop`, `feature/<issue#>-<slug>`).

## 12. Spike results

To be filled in as capability spikes (Phase 1, Phase 9) complete.

### App Groups and Keychain Sharing (Phase 1 spike, #10)

- **Date / device:** 2026-09-27, iPhone 16 Pro Max, iOS 26.7, Xcode 27, free
  Personal Team. Harness: iOS-only WidgetKit extension `miseWidget`,
  `Shared/SharedStore.swift`, `miseTests/SharedStoreTests.swift`.
- **Provisioning:** `xcodebuild -allowProvisioningUpdates` succeeded, no
  warnings. The free account silently registered the widget App ID
  `<prefix>.mise.widget` and the app group; profiles expire after 7 days.
  `embedded.mobileprovision` grants `application-groups`
  `[group.<prefix>.mise]` and `keychain-access-groups` `[<TEAM>.*]`;
  `codesign -d --entitlements -` shows both entitlements on app and appex.
- **Runtime:** `SharedStoreTests` 3/3 pass on device (group container exists,
  group defaults round-trip, shared keychain round-trip). After launch,
  `devicectl device copy from --domain-type appGroupDataContainer` showed
  `spike.lastLaunch` in the group prefs plist.
- **Widget-side read:** pending user check — the "mise spike" widget should
  show `Group: <launch timestamp>` and `Keychain: <same timestamp>`.
- **Gotcha:** the first `keychain-access-groups` entry is the default group
  for new items. Listing only the shared group moved every new item
  (including the stock API key from `Keychain.swift`) into the
  widget-readable group. Keep the app-private group
  `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)` first;
  `KeychainTests.setUsesAppPrivateGroupNotSharedGroup` guards it.
- **App IDs used:** 1 (widget, reused by #11).
- **Chosen path:** App Group container/defaults for app↔extension data; the
  shared keychain group only for small secrets an extension needs. The
  EventKit-direct and keychain-snapshot fallbacks from §2.4 are not needed.

### WidgetKit (Phase 1 spike, #11)

- **Date / device:** 2026-09-27, iPhone 16 Pro Max, iOS 26.7, Xcode 27, free
  Personal Team. Harness: the #10 widget `miseWidget/MiseWidget.swift`
  (small + medium), `SpikeTapIntent`, calendar request in
  `MiseApp.recordSpikeLaunch`.
- **Provisioning:** `xcodebuild -allowProvisioningUpdates` succeeded, no
  warnings. No new App ID: reuses #10's `<prefix>.mise.widget` profile.
  Calendar access needs only `NSCalendarsFullAccessUsageDescription` (app
  build setting + widget Info.plist), no entitlement.
- **Verified automatically:** device build, macOS build, iOS Simulator suite
  pass; install + launch on device; appex contains `Metadata.appintents`
  (lists `SpikeTapIntent`) and the calendar usage key.
- **Pending user checks** (Result: pending user confirmation):
  1. Widget gallery lists "mise spike"; placed widget shows `Group:` and
     `Keychain:` launch timestamps.
  2. Tapping `Tap` increments `Taps: n` each time without opening the app.
  3. After allowing calendar access in the app, the widget shows
     `Today: <count>, next: <title>` (before: `EventKit: notDetermined`).
- **Timeline:** `.after(+15 min)`; app reloads timelines on launch and after
  the calendar grant.
- **Proposed path (pending user checks above):** WidgetKit + App Group works
  on the free account. Events widgets read EventKit directly in the extension
  (`.event` full access verified in build only); no snapshot needed. Reminders
  access for task widgets not tested — needs its own usage key and grant.

### App Intents / Siri (Phase 1 spike, #12)

- **Date / device:** 2026-09-27, iPhone 16 Pro Max, iOS 26.7, Xcode 27, free
  Personal Team. Harness: `mise/AddTaskIntent.swift` (`AddTaskIntent` +
  `MiseShortcuts` provider) in the main app target,
  `miseTests/AddTaskIntentTests.swift`. Spike store: `UserDefaults.standard`
  key `spike.siriTasks`.
- **Provisioning:** `xcodebuild -allowProvisioningUpdates` succeeded with the
  existing `<prefix>.mise` profile. No new App ID, no Siri entitlement;
  `codesign -d --entitlements` on the app shows only the #10 entitlements.
- **Verified automatically:** iOS Simulator suite and macOS build pass; device
  build, install and launch; `mise.app/Metadata.appintents` lists
  `AddTaskIntent` and the auto shortcut (phrases `Add a task in
  ${applicationName}`, `Add task to ${applicationName}`, short title
  "Add Task", `checklist`) plus `root.ssu.yaml` / `nlu/`;
  `AddTaskIntentTests` passes on device.
- **Parameter in phrase:** App Shortcut phrases can only embed
  `AppEntity`/`AppEnum` parameters, not `String`. Siri asks for the title as a
  follow-up (`requestValueDialog: "What's the task?"`).
- **Gotcha:** an incremental build skipped `AppIntentsSSUTraining` for the app
  (no `nlu/` in `Metadata.appintents`); a clean build generated it. Clean-build
  before testing new Siri phrases.
- **Pending user checks** (Result: pending user confirmation):
  1. Shortcuts app → App Shortcuts (or search "mise") → "Add Task" tile present.
  2. "Hey Siri, add a task in mise" → Siri asks "What's the task?" → "buy
     milk" → Siri replies "Added buy milk to mise."
  3. Optional: tap the "Add Task" tile in Shortcuts, enter a title, same reply.
- **Proposed path (pending user checks above):** App Intents in the main app
  for Siri/Shortcuts; no extension needed. Real add writes to Reminders via
  EventKit (§6.2) in the Tasks phase.

### Share Extension (Phase 1 spike, #13)

- **Date / device:** 2026-09-27, iPhone 16 Pro Max, iOS 26.7, Xcode 27, free
  Personal Team. Harness: iOS-only share extension `miseShare`
  (`miseShare/ShareViewController.swift`, no UI), `Shared/SharedInbox.swift`
  (copies to `<App Group container>/Inbox/<uuid>-<name>`), document types in
  `Config/Info.plist` routed through `ContentView.onOpenURL`,
  `miseTests/SharedInboxTests.swift`, Settings → "Spike: shared inbox" row.
- **Provisioning:** `xcodebuild -allowProvisioningUpdates` succeeded, no
  warnings. The free account silently registered a new App ID
  `<prefix>.mise.share` ("iOS Team Provisioning Profile:
  <prefix>.mise.share"). `codesign -d --entitlements` on the appex shows
  `application-groups` `[group.<prefix>.mise]`. **New App IDs this week:** 2
  (widget #10, share #13), besides the app's own.
- **Verified automatically:** device build, iOS Simulator suite (38/38) and
  macOS build pass; `SharedInboxTests` passes on device; install + launch on
  device. Appex Info.plist has `com.apple.share-services`, principal class
  `miseShare.ShareViewController`, activation rule a `SUBQUERY` predicate
  (exactly one item with one attachment conforming to `com.adobe.pdf` or
  `public.image`, so mise hides for text/URLs/multiple files), display
  name "mise". App Info.plist has `CFBundleDocumentTypes` (`com.adobe.pdf`,
  `public.image`, Viewer, Alternate).
- **Not automated:** `devicectl device process launch --payload-url
  file://…` (2 tries) put nothing in the Inbox and printed nothing; the
  payload doesn't seem to reach `onOpenURL`. Left to the manual check.
  The macOS route (Finder → Open With → mise → `onOpenURL`) is unverified.
  iOS deletes the system's `Documents/Inbox` copy after import; macOS opens in
  place, so the original is never deleted there.
- **Gotcha:** `LSSupportsOpeningDocumentsInPlace = NO` fails the macOS build
  ("not supported on macOS"), and leaving it out with document types present
  counts as NO. Set per SDK: NO on iOS (system copies the file in), YES on
  macOS (build settings `INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace[sdk=…]`).
- **Pending user checks** (Result: pending user confirmation):
  1. Files → any PDF → Share → "mise" in the share sheet (may need "More" /
     Edit Actions) → tap → sheet closes. Open mise → Settings → "Spike:
     shared inbox" shows `Files 1` and the filename (`<uuid>-<name>.pdf`).
     Re-open Settings if the count looks stale.
  2. Mail → PDF attachment → Share → mise → same check, count +1.
  3. Fallback: Files → PDF → Share → mise app icon ("Open in mise"; or
     long-press → Share → app row) → mise opens; Settings inbox count +1.
- **Proposed path (pending user checks above):** share extension + App Group
  inbox as the primary way in; document types kept as the fallback (and the
  macOS route). The Finance importer reads `SharedInbox` later.

### Foundation Models (Phase 1 spike, #14)

- **Date / machine:** 2026-09-27, MacBook Pro M3 Pro, macOS 26.6.2 (25G83),
  Xcode 27.0. Harness: `miseTests/FoundationModelsSpikeTests.swift`, opt-in via
  `TEST_RUNNER_MISE_FM_SPIKE=1` (table saved as the `fm_spike.txt` test
  attachment). Fixed "now" = Sunday 2026-09-27 10:00 +08:00.
- **Availability:** `SystemLanguageModel.default.availability` = `.available`
  on the Mac and on the iPhone 17 Simulator. Unavailable devices get
  `OnDeviceAI.unavailableReason` (shown in Settings → On-device AI), ending
  "Manual entry still works."
- **Mac accuracy (final prompt, 2 runs):** run A kind 8/10, all fields 8/10;
  run B kind 9/10, all fields 9/10. First prompt (no expense/merchant hints):
  kind 8/10, fields 6/10. Run B:

| # | Input | Expected | Got | OK | ms |
|---|---|---|---|---|---|
| 1 | Coffee 5.50 | expense 5.5 | expense 5.5, cur=SGD, merch="Coffee Shop" | yes | 747 |
| 2 | call mom tomorrow 6pm | task, due 09-28 18:00 | task, due 2026-09-28T18:00+08:00 | yes | 800 |
| 3 | Uber to airport 32.40 EUR | expense 32.4 EUR | expense 32.4 EUR, merch=Uber, due=09-28 18:00 (invented) | yes | 1026 |
| 4 | pay rent every 1st 9am !high | task | `guardrailViolation` ("May contain unsafe content") | no | 897 |
| 5 | Ideas for the garden: … | note | note | yes | 590 |
| 6 | Lunch with Sam at Nando's £18.20 | expense 18.2 GBP Nando's | same, cat=Food | yes | 894 |
| 7 | Dentist appointment next Tuesday 3:30pm | task | task, due 2026-09-30 (a Wednesday) | yes | 798 |
| 8 | Book club notes — … | note | note | yes | 847 |
| 9 | TRADER JOE'S #123 … TOTAL 44.46 … | expense 44.46 Trader Joe's | expense 44.46, merch="TRADER JOE'S #123", cur=CNY, title "Groceries" | yes | 1268 |
| 10 | Netflix subscription 15.49 monthly | expense 15.49 | expense 15.49 USD, merch=Netflix | yes | 748 |

- **Mac latency (one fresh session per call, warm):** run A median 834 ms,
  max 1216 ms; run B median 823 ms, max 1268 ms; first prompt median 581 ms,
  max 985 ms.
- **iOS Simulator (iPhone 17, iOS 27.0 runtime, host-Mac model):** availability
  `.available`, but all 10 calls threw `LanguageModelError -1` wrapping
  `ModelManagerError 1026` (0/10; ~170 ms to fail, 2124 ms first call).
  Likely the iOS 27 simulator runtime vs the macOS 26.6 host model; unverified.
- **iPhone 16 Pro Max (iOS 26.7, 23H24), 2 runs on device** (Personal Team
  build, `TEST_RUNNER_MISE_FM_SPIKE=1 xcodebuild test -destination
  'platform=iOS,id=<udid>' -only-testing:miseTests/FoundationModelsSpikeTests`):
  availability `.available`, all 20 calls succeeded (no guardrail hit on #4,
  unlike the Mac). Run 1: kind 10/10, all fields 9/10, median 858 ms, max
  2769 ms (first call, cold). Run 2: kind 9/10, all fields 8/10, median
  863 ms, max 1310 ms. Warm calls 620–1310 ms — same as the Mac. Misses: #9
  merchant kept raw ("Trader Joe's #123"), run 2 picked SUBTOTAL 41.17 over
  TOTAL 44.46; run 2 classified #5 (garden ideas) as a task. Same invented
  due dates and "next Tuesday" off-by-one (09-29 / 09-30) as on the Mac.
- **Failure modes:** kind flips between runs on the same input (task↔note for
  #2 and #7); relative weekdays resolved wrong ("next Tuesday" → Wed/Fri);
  currency and due invented (CNY/SGD from locale, due copied onto expenses);
  literal "nil" strings in optional fields; merchant kept raw ("TRADER JOE'S
  #123"); guardrail false positive on "pay rent … !high"; `availability` can
  say available while calls still fail.
- **Recommendation:** usable for quick-capture drafts. Keep the review screen
  mandatory; treat every call as fallible (guardrail/model errors → prefill
  the raw text into manual entry); compute dates in code (`NSDataDetector` /
  Calendar) instead of trusting model dates; only accept a currency the text
  actually contains, else the user's default; normalise "nil" to nil.
