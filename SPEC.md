# mise — Product & Technical Specification

## 1. Overview

mise is a personal, all-in-one productivity app for a single user. It combines
tasks and reminders, a planner/calendar, personal finance, notes, and a news
reader into one native app, with a "Today" screen that pulls the most relevant
pieces of each module together.

The app is built as a single multiplatform SwiftUI codebase targeting iPhone
and Mac. It is local-first: there is no backend server and no paid service.
Data either lives in Apple's own system stores (Reminders and Calendar via
EventKit) or in the app's own SwiftData store on each device, with an optional
file-based sync between devices.

## 2. Platforms and constraints

### 2.1 Target devices

- **iOS:** iPhone 16 Pro Max, iOS 26 or later.
- **macOS:** macOS 26 or later, Apple silicon.
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
- Everything is local-first. No server, no paid APIs.

### 2.3 Capabilities available on a free account

Per Apple's capability table for free accounts:

| Capability | Status |
|---|---|
| App Groups | Allowed per Apple's table — **VERIFY** (conflicting third-party reports) |
| Keychain Sharing | Allowed per Apple's table — **VERIFY** |
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

App Intents / App Shortcuts are not the legacy SiriKit entitlement, but whether
Siri invocation works on a free account must be verified on device.

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
- **Siri / Shortcuts** via App Intents (**VERIFY** on free account).
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

## 9. Items to verify (spikes)

- App Groups on a free Personal Team account.
- Keychain Sharing on a free account (fallback channel for widget data).
- WidgetKit extension install and interactive widgets on a free account.
- App Intents / App Shortcuts, including Siri invocation, on a free account.
- Share Extension on a free account.
- iOS 26 `TextEditor` + `AttributedString` capability for live Markdown editing.
- Foundation Models quality for quick-capture classification and receipt
  extraction.

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

## 11. Development workflow

See `README.md` for the branch model (`main`, `develop`, `feature/<issue#>-<slug>`).

## 12. Spike results

To be filled in when the Phase 1 capability spike is complete.
