# Issue definitions for mise, sourced by bootstrap-github.sh. Order = phase order.
# Each: issue "Title" "labels" "$Mn" <<'EOF' description + acceptance criteria EOF

# ============================ Phase 1 ============================
issue "Create multiplatform Xcode project (iOS + macOS)" "module:foundation,infra,priority:high" "$M1" <<'EOF'
Single multiplatform SwiftUI app target for iOS 26+ and macOS 26+ (Apple silicon), signed with a free Personal Team. See SPEC.md §2, §3.

## Acceptance criteria
- [ ] Xcode project `mise` with one multiplatform app target (iPhone + Mac)
- [ ] Deployment targets iOS 26 / macOS 26
- [ ] Builds and runs on iPhone 16 Pro Max and on Mac with Personal Team signing
- [ ] Unit test target runs (`xcodebuild test`) on both platforms
- [ ] No team ID or secrets committed (bundle id prefix documented in README)
EOF

issue "SwiftData container and attachment file storage" "module:foundation,infra,priority:high" "$M1" <<'EOF'
Shared SwiftData `ModelContainer` for app-owned data, plus a convention for large attachments stored as files on disk referenced from models. Keep the layer swappable to CloudKit later (SPEC §2.5, §3).

## Acceptance criteria
- [ ] ModelContainer created at app start and injected into the environment
- [ ] Attachment helper: save/load/delete file by id in app support directory
- [ ] Test: model insert/fetch round-trip in an in-memory container
- [ ] Test: attachment write/read/delete
EOF

issue "Navigation shell: iOS tab bar and Mac sidebar" "module:foundation,feature" "$M1" <<'EOF'
iOS tab bar Today · Tasks · Calendar · Money · More (Notes, News, Settings); Mac uses a sidebar with the same destinations (SPEC §5, §4.1). Placeholder screens only.

## Acceptance criteria
- [ ] iOS: 5 tabs; More lists Notes, News, Settings
- [ ] macOS: NavigationSplitView sidebar with all destinations
- [ ] Deep-link routing enum usable by widgets/intents later (e.g. `mise://tasks/new`)
EOF

issue "Theming engine: custom palette with light/dark variants" "module:foundation,feature" "$M1" <<'EOF'
Follows system light/dark by default. Custom palette via native ColorPicker: accent, background, surface, text, per-module colors; separate light and dark variants; presets; reset (SPEC §5).

## Acceptance criteria
- [ ] Palette model persisted; applied app-wide through the environment
- [ ] Settings screen with ColorPicker per role, per light/dark variant
- [ ] At least 2 presets + reset to default
- [ ] Changes apply live without restart
EOF

issue "Theme contrast warnings" "module:foundation,feature" "$M1" <<'EOF'
Warn when text/background (and text/surface) contrast is too low in the custom palette (SPEC §5).

## Acceptance criteria
- [ ] WCAG contrast ratio computed for text vs background/surface, both variants
- [ ] Warning shown in theme settings below 4.5:1
- [ ] Unit test for contrast ratio (black/white = 21:1)
EOF

issue "Keychain storage for runtime secrets" "module:foundation,infra" "$M1" <<'EOF'
Small Keychain wrapper for user-entered secrets (e.g. stock price API key). Keys are never committed or bundled (SPEC §2.6).

## Acceptance criteria
- [ ] Set/get/delete string by key in Keychain
- [ ] Settings field to enter/clear an API key (masked)
- [ ] Test: set/get/delete round-trip
EOF

issue "Face ID / Touch ID app lock" "module:foundation,feature" "$M1" <<'EOF'
LocalAuthentication lock with two modes: whole app, or only Finance + locked notes (SPEC §5).

## Acceptance criteria
- [ ] Setting: off / whole app / Finance + locked notes
- [ ] Lock on launch and after returning from background (grace period setting)
- [ ] Privacy cover in app switcher when locked
- [ ] Passcode/password fallback works; works on Mac with Touch ID
EOF

issue "Backup and restore to a single file" "module:foundation,feature" "$M1" <<'EOF'
Export all app-owned data (SwiftData + attachments + settings) to one file via Files; restore from it (SPEC §5). EventKit data is not included (lives in system stores).

## Acceptance criteria
- [ ] Export produces one archive file via fileExporter
- [ ] Restore via fileImporter replaces data after confirmation
- [ ] Format has a version number; restore rejects unknown versions
- [ ] Test: backup then restore into empty store yields identical data
EOF

issue "Weekly automatic backup" "module:foundation,feature" "$M1" <<'EOF'
Optional weekly auto-backup to a user-chosen folder (SPEC §5).

## Acceptance criteria
- [ ] Setting to enable + pick destination folder (security-scoped bookmark)
- [ ] Runs on launch/background refresh when last backup > 7 days old
- [ ] Keeps last N backups (default 4)
EOF

issue "Spike: App Groups and Keychain Sharing on free account" "module:foundation,spike,priority:high" "$M1" <<'EOF'
VERIFY whether App Groups and Keychain Sharing work on a free Personal Team (conflicting reports). SPEC §2.3–2.4.

## Acceptance criteria
- [ ] Add App Group capability; record whether provisioning succeeds on device
- [ ] Write/read a value between app and an extension via the group container
- [ ] Same test for a shared Keychain access group
- [ ] Results + chosen fallback written to SPEC.md §12
EOF

issue "Spike: WidgetKit extension on free account" "module:widgets,spike,priority:high" "$M1" <<'EOF'
VERIFY a WidgetKit extension installs and renders on a free account, including an interactive (App Intent button) widget. Note App ID usage (10/week limit). SPEC §2.4.

## Acceptance criteria
- [ ] Minimal widget shows on Home Screen from a Personal Team build
- [ ] Interactive button widget triggers an intent
- [ ] Widget reads EventKit directly (fallback path) works
- [ ] Results written to SPEC.md §12
EOF

issue "Spike: App Intents / Siri add-task on free account" "module:tasks,spike,priority:high" "$M1" <<'EOF'
VERIFY App Intents + App Shortcuts (Siri "add task in mise") on a free account. SPEC §2.4, §6.2.

## Acceptance criteria
- [ ] Minimal AppShortcut appears in Shortcuts app
- [ ] Siri phrase invokes it with a parameter
- [ ] Results written to SPEC.md §12
EOF

issue "Spike: Share Extension on free account" "module:finance,spike" "$M1" <<'EOF'
VERIFY a Share Extension can receive a PDF/image on a free account. Fallback: document types + fileImporter. SPEC §2.4.

## Acceptance criteria
- [ ] Share a PDF from Files/Mail into the extension; payload reaches the app
- [ ] Fallback verified: "Open in mise" via registered document types
- [ ] Results + chosen path written to SPEC.md §12
EOF

issue "Spike: Foundation Models availability and parsing quality" "module:foundation,spike" "$M1" <<'EOF'
Check on-device Foundation Models on iPhone and Mac: availability API, guided generation for structured output, ~4k context, quality on sample inputs (task NL, expense text, receipt text). SPEC §3.

## Acceptance criteria
- [ ] Availability check + graceful fallback message when unavailable
- [ ] @Generable struct extraction works for 10 sample inputs; accuracy noted
- [ ] Latency noted on iPhone and Mac
- [ ] Results written to SPEC.md §12
EOF

# ============================ Phase 2 ============================
issue "EventKit reminders layer" "module:tasks,infra,priority:high" "$M2" <<'EOF'
Access layer for Apple Reminders: permission, fetch, create, update, complete, delete; observe EKEventStoreChanged for two-way sync. SPEC §6.2.

## Acceptance criteria
- [ ] Full-access permission request with denied-state UI
- [ ] CRUD + completion for reminders incl. lists, priority, due, recurrence, alarms
- [ ] UI refreshes on external changes (edit in Reminders app shows up)
- [ ] Deletion syncs both ways
EOF

issue "EventKit calendar events layer" "module:calendar,infra,priority:high" "$M2" <<'EOF'
Access layer for calendar events (Apple + Outlook accounts from system settings): permission, fetch range, create/update/delete with span (this/future). SPEC §6.3.

## Acceptance criteria
- [ ] Fetch events for a date range across visible calendars
- [ ] Create/update/delete with `.thisEvent` / `.futureEvents`
- [ ] Lists calendars incl. Exchange/Outlook sources
- [ ] Refreshes on EKEventStoreChanged
EOF

issue "Task list views: Today, Upcoming, by list, completed" "module:tasks,feature" "$M2" <<'EOF'
Views: Today (overdue + due today), Upcoming (7 days), by list/project, by priority, completed log. SPEC §6.2.

## Acceptance criteria
- [ ] Each view lists correct reminders; check-off completes
- [ ] Overdue highlighted
- [ ] Completed log grouped by day
EOF

issue "Task create/edit screen" "module:tasks,feature" "$M2" <<'EOF'
Edit title, notes, due date/time, priority, list, recurrence, time alarms; delete. SPEC §6.2.

## Acceptance criteria
- [ ] All fields round-trip to Reminders app
- [ ] Recurrence presets + custom rule
- [ ] Delete with confirmation
EOF

issue "Subtasks and tags stored in app" "module:tasks,feature" "$M2" <<'EOF'
Subtasks and tags (not in EventKit) stored in SwiftData, linked by reminder identifier; tags shared with notes. SPEC §6.2.

## Acceptance criteria
- [ ] Add/reorder/check subtasks on a task
- [ ] Add/remove tags; tag filter view
- [ ] Orphaned extras cleaned when reminder is deleted
- [ ] Handles identifier changes (fallback match by externalIdentifier)
EOF

issue "Natural-language quick add for tasks" "module:tasks,feature" "$M2" <<'EOF'
On-device Foundation Models parses e.g. "pay rent every 1st 9am !high" into title, due, recurrence, priority, list. Preview before saving. SPEC §6.2.

## Acceptance criteria
- [ ] Parsed fields shown for confirmation/edit
- [ ] Handles relative dates, recurrence, priority markers
- [ ] Falls back to plain title when model unavailable
- [ ] Test fixture of sample phrases with expected fields
EOF

issue "Task time-blocking with linked calendar event" "module:tasks,feature" "$M2" <<'EOF'
Per task: pick start, duration, calendar (Apple/Outlook) → create linked event. Completing task updates the event. SPEC §6.2.

## Acceptance criteria
- [ ] Link stored (reminder id ↔ event id)
- [ ] Completing task marks event (e.g. title prefix ✓) per spec
- [ ] Deleting task offers to delete event
EOF

issue "App Intent: add task via Siri / Shortcuts" "module:tasks,feature" "$M2" <<'EOF'
Depends on App Intents spike result. AddTask intent + AppShortcut phrase. SPEC §6.2.

## Acceptance criteria
- [ ] "Add task" intent with title + optional due date
- [ ] Siri phrase works (if spike passed) and Shortcuts action works
- [ ] Complete-task intent for widget reuse
EOF

issue "Calendar day timeline view" "module:calendar,feature" "$M2" <<'EOF'
Day timeline with events, all-day row, current-time line. SPEC §6.3.

## Acceptance criteria
- [ ] Overlapping events laid out side by side
- [ ] Tap event opens detail/edit
- [ ] Scrolls to current time
EOF

issue "Calendar N-day grid view (1-7 days)" "module:calendar,feature" "$M2" <<'EOF'
Custom N-day grid, user adjustable 1–7, pinch to change. SPEC §6.3.

## Acceptance criteria
- [ ] Stepper/setting and pinch gesture change N
- [ ] N persists
- [ ] Reuses day-timeline layout
EOF

issue "Calendar month grid and agenda list" "module:calendar,feature" "$M2" <<'EOF'
Month grid with event dots, tap a day for its agenda; separate agenda list view. SPEC §6.3.

## Acceptance criteria
- [ ] Dots colored by calendar
- [ ] Tap day shows agenda
- [ ] Agenda list scrolls forward by day
EOF

issue "Event create/edit/delete incl. recurring" "module:calendar,feature" "$M2" <<'EOF'
Event editor: title, time, all-day, calendar, location, recurrence, alarms; edit/delete recurring with "this / all future". SPEC §6.3. No attendees (v2).

## Acceptance criteria
- [ ] Create/edit/delete round-trip to Calendar app
- [ ] Recurring edit/delete prompts this vs future
- [ ] Default calendar preselected, overridable
EOF

issue "Calendar settings: default calendar, colors, visibility" "module:calendar,feature" "$M2" <<'EOF'
Fixed default calendar, color per calendar, show/hide calendars. SPEC §6.3.

## Acceptance criteria
- [ ] Default calendar setting used by new events and time blocks
- [ ] Per-calendar color override stored in app
- [ ] Hidden calendars excluded from all views
EOF

issue "Event travel time and leave-now notification" "module:calendar,feature" "$M2" <<'EOF'
Event location via MapKit search; ETA via MKDirections; local "leave now" notification. ETA refreshes only on background refresh (known limitation). SPEC §6.3.

## Acceptance criteria
- [ ] Location picker with MapKit search
- [ ] ETA shown on event; notification scheduled at start − ETA − buffer
- [ ] Background refresh reschedules with new ETA
EOF

issue "Drag unscheduled tasks onto timeline" "module:calendar,feature" "$M2" <<'EOF'
Unscheduled tasks tray on day view; drag onto timeline creates a time block. SPEC §6.3.

## Acceptance criteria
- [ ] Drag creates linked event at drop time with default/estimated duration
- [ ] Works on iPhone and Mac
EOF

issue "Free-slot suggestions" "module:calendar,feature" "$M2" <<'EOF'
Suggest free slots from working-hours setting, task duration estimate, and calendar gaps. SPEC §6.3.

## Acceptance criteria
- [ ] Working hours setting + per-task duration estimate
- [ ] Suggest top 3 slots for a task
- [ ] Unit test of gap-finding with overlapping events
EOF

issue "Daily planning prompt" "module:calendar,feature" "$M2" <<'EOF'
Configurable morning local notification → review/pick/schedule screen. SPEC §6.3.

## Acceptance criteria
- [ ] Time setting; notification opens planning screen
- [ ] Screen: overdue/today tasks, pick, schedule via free-slot suggestions
EOF

issue "Weekly review" "module:calendar,feature" "$M2" <<'EOF'
Configurable day/time; shows last week's completed tasks, time per calendar, spend; plan next week. Spend section appears once Finance exists. SPEC §6.3.

## Acceptance criteria
- [ ] Notification at configured day/time opens review
- [ ] Completed tasks count/list, hours per calendar
- [ ] Hook for spend summary (filled when Finance lands)
EOF

# ============================ Phase 3 ============================
issue "Finance data model: accounts, transactions, categories" "module:finance,infra,priority:high" "$M3" <<'EOF'
SwiftData models: Account (type cash/debit/credit/brokerage, currency, opening balance), Transaction (amount, currency, date, merchant, category, account, attachment), Category, Transfer. Money as Decimal. SPEC §6.4.

## Acceptance criteria
- [ ] Models + balance computation per account
- [ ] Transfers (incl. credit card payment) excluded from spending
- [ ] Tests: balance and spend-excludes-transfers
EOF

issue "Home currency and daily FX rates (Frankfurter)" "module:finance,feature,priority:high" "$M3" <<'EOF'
Choose home currency on first launch; fetch daily ECB rates from Frankfurter (no key), cache, convert all totals. SPEC §6.4.

## Acceptance criteria
- [ ] First-launch currency picker
- [ ] Daily fetch with cached fallback when offline
- [ ] Conversion uses the rate for the transaction date
- [ ] Test: conversion with fixture rates
EOF

issue "Accounts screen" "module:finance,feature" "$M3" <<'EOF'
List/create/edit/archive accounts with balances in native and home currency. SPEC §6.4.

## Acceptance criteria
- [ ] CRUD accounts; archive instead of delete when transactions exist
- [ ] Total balance in home currency
EOF

issue "Manual transaction entry and transfers" "module:finance,feature" "$M3" <<'EOF'
Add/edit/delete expense, income, transfer; list with filters. SPEC §6.4.

## Acceptance criteria
- [ ] Fast entry form (amount, category, account, date, note)
- [ ] Transfer between accounts incl. cross-currency
- [ ] Transaction list filter by account/category/month
EOF

issue "Categories and monthly budgets with alerts" "module:finance,feature" "$M3" <<'EOF'
Category management; monthly budget per category; local notification at 80% and 100%. SPEC §6.4.

## Acceptance criteria
- [ ] Default categories + CRUD
- [ ] Budget progress per category for current month
- [ ] Alerts fire once per threshold per month
- [ ] Test: threshold crossing logic
EOF

issue "Recurring bills and subscriptions" "module:finance,feature" "$M3" <<'EOF'
Bills with amount, cadence, next due; reminders N days before and on due date; mark paid creates transaction. SPEC §6.4.

## Acceptance criteria
- [ ] CRUD bills with cadence (weekly/monthly/yearly)
- [ ] Local notifications before + on due date
- [ ] Mark paid → transaction + next due advanced
EOF

issue "Income tracking and savings goals" "module:finance,feature" "$M3" <<'EOF'
Income categories/summary; savings goals with target, date, progress. SPEC §6.4.

## Acceptance criteria
- [ ] Monthly income vs spend summary
- [ ] Goals with progress bar, linked account or manual contributions
EOF

issue "Finance reports and charts" "module:finance,feature" "$M3" <<'EOF'
Swift Charts: spend by category, monthly trends, net worth over time. SPEC §6.4.

## Acceptance criteria
- [ ] Three charts with month/range selector
- [ ] Net worth snapshots stored daily for history
EOF

issue "Month-end summary notification" "module:finance,feature" "$M3" <<'EOF'
Local notification at month end summarizing spend vs budget. SPEC §6.4.

## Acceptance criteria
- [ ] Scheduled for last day of month; opens summary screen
EOF

issue "CSV export of transactions" "module:finance,feature" "$M3" <<'EOF'
Export transactions to CSV via Files. Holdings export is in the holdings issue. SPEC §6.4.

## Acceptance criteria
- [ ] RFC 4180 quoting; ISO dates; amount + currency + home amount columns
- [ ] Test: fields with commas/quotes escape correctly
EOF

# ============================ Phase 4 ============================
issue "Transaction review screen and source attachment" "module:finance,feature,priority:high" "$M4" <<'EOF'
Shared review screen used by all imports: shows extracted fields, editable, original image/PDF attached on save. SPEC §6.4.

## Acceptance criteria
- [ ] Nothing saves without passing review
- [ ] Original file stored as attachment and viewable from transaction
EOF

issue "AI extraction of transaction fields" "module:finance,feature" "$M4" <<'EOF'
Foundation Models extracts merchant, date, total, category, currency from OCR/PDF text (chunked if long). SPEC §6.4.

## Acceptance criteria
- [ ] @Generable output struct; missing fields left blank, not guessed
- [ ] Category mapped to existing categories
- [ ] Fixture test set of sample receipt texts
EOF

issue "Receipt scanning (VisionKit + Vision OCR)" "module:finance,feature" "$M4" <<'EOF'
Document camera scan → Vision OCR → AI extraction → review. SPEC §6.4.

## Acceptance criteria
- [ ] Scan on iPhone; import image on Mac
- [ ] OCR text passed to extraction; review screen opens
EOF

issue "PDF invoice / bank notice import" "module:finance,feature" "$M4" <<'EOF'
PDFKit text extraction, OCR fallback for scanned PDFs; entry via share extension or document types/fileImporter per spike result. SPEC §6.4.

## Acceptance criteria
- [ ] Text PDFs and scanned PDFs both produce extraction
- [ ] Entry path from Files works on iPhone and Mac
EOF

issue "Bank CSV import with column mapping" "module:finance,feature" "$M4" <<'EOF'
Import CSV, map columns (date, amount, description, currency), remember mapping per account, preview + dedupe before import. SPEC §6.4.

## Acceptance criteria
- [ ] Mapping UI with preview rows; saved per account
- [ ] Date/decimal format options; duplicate detection
- [ ] Test: parse fixture CSV with quoted fields
EOF

issue "Holdings model, UI, manual valuation, CSV export" "module:finance,feature" "$M4" <<'EOF'
Holdings (stock/ETF, crypto, fund/retirement) with quantity, cost basis; manual valuation fallback; value and gain/loss in home currency; CSV export of holdings. SPEC §6.4.

## Acceptance criteria
- [ ] CRUD holdings under brokerage accounts
- [ ] Manual price/valuation entry with date
- [ ] Gain/loss and total value; included in net worth
- [ ] Holdings CSV export
EOF

issue "Crypto prices via CoinGecko" "module:finance,feature" "$M4" <<'EOF'
Free CoinGecko API (no key); map holdings to coin ids; cache prices. SPEC §6.4.

## Acceptance criteria
- [ ] Coin search/mapping when adding holding
- [ ] Batch price fetch; last-updated shown; offline uses cache
EOF

issue "Stock/ETF prices via Finnhub or Alpha Vantage" "module:finance,feature" "$M4" <<'EOF'
User enters provider API key at runtime (Keychain). Refresh a few times/day within rate limits; background refresh. SPEC §6.4, §2.6.

## Acceptance criteria
- [ ] Provider choice + key entry in Settings (Keychain only)
- [ ] Rate-limit aware batching; last-updated shown
- [ ] Clear message when no key configured
EOF

# ============================ Phase 5 ============================
issue "Spike: iOS 26 TextEditor with AttributedString for live Markdown" "module:notes,spike,priority:high" "$M5" <<'EOF'
VERIFY the SwiftUI TextEditor + AttributedString API supports live formatting, selection-based toolbar actions, and input transforms for Markdown shortcuts on iOS and Mac. SPEC §6.5, §9.

## Acceptance criteria
- [ ] Prototype: bold/italic/heading/list/checkbox applied live
- [ ] `# ` and `- ` typed shortcuts transform in place
- [ ] Findings + gaps written to SPEC.md §12
EOF

issue "Notes data model: folders, tags, pinned" "module:notes,infra" "$M5" <<'EOF'
Note (markdown body, timestamps), nested Folder, shared Tag, pinned flag. SPEC §6.5.

## Acceptance criteria
- [ ] Nested folders CRUD + move notes
- [ ] Tags shared with tasks
- [ ] Pinned notes sort first
EOF

issue "AttributedString <-> Markdown serializer" "module:notes,feature,priority:high" "$M5" <<'EOF'
Round-trip serializer between Markdown and AttributedString; unsupported rich formatting (colors, fonts) is dropped. SPEC §6.5.

## Acceptance criteria
- [ ] Headings, bold, italic, code, links, bullets, numbered, checkboxes, quotes
- [ ] Round-trip test: md → attr → md is stable on fixture set
EOF

issue "Rich note editor with toolbar and Markdown shortcuts" "module:notes,feature" "$M5" <<'EOF'
Live-rendered editor, formatting toolbar, Markdown shortcuts, raw Markdown toggle, System Writing Tools enabled. SPEC §6.5.

## Acceptance criteria
- [ ] Toolbar actions + typed shortcuts
- [ ] Raw toggle shows/edits source
- [ ] Writing Tools available
EOF

issue "Automatic daily note" "module:notes,feature" "$M5" <<'EOF'
One note per day created on first access, in a Daily folder. SPEC §6.5.

## Acceptance criteria
- [ ] Opening "Today's note" creates or opens it
- [ ] Optional template
EOF

issue "Tidy button: AI restructure to Markdown" "module:notes,feature" "$M5" <<'EOF'
Foundation Models turns messy text/transcripts into structured Markdown; chunked (~4k context); before/after diff; undo. SPEC §6.5.

## Acceptance criteria
- [ ] Chunks long notes on paragraph boundaries
- [ ] Diff view, accept/reject, undo after accept
EOF

issue "AI summarize and extract action items" "module:notes,feature" "$M5" <<'EOF'
Summarize a note; extract action items with option to create tasks. SPEC §6.5.

## Acceptance criteria
- [ ] Summary inserted or shown
- [ ] Action items list with "create task" per item
EOF

issue "Photo/scan attachments with OCR search" "module:notes,feature" "$M5" <<'EOF'
Attach photos/scans; Vision OCR text stored and included in search. SPEC §6.5.

## Acceptance criteria
- [ ] Attach from camera/photos/scanner
- [ ] OCR text indexed; search finds note by text in image
EOF

issue "Voice memos with on-device transcription" "module:notes,feature" "$M5" <<'EOF'
Record audio in a note; on-device transcription inserted as text. SPEC §6.5.

## Acceptance criteria
- [ ] Record/play audio attachment
- [ ] On-device transcript inserted; works offline
EOF

issue "File/PDF attachments and links to tasks/events/transactions" "module:notes,feature" "$M5" <<'EOF'
Attach files/PDFs; insert links to tasks, events, transactions that open them. SPEC §6.5.

## Acceptance criteria
- [ ] File attachments open in Quick Look
- [ ] Link picker for task/event/transaction; tap navigates
EOF

issue "Convert checklist line to task" "module:notes,module:tasks,feature" "$M5" <<'EOF'
Action on a checklist line creates a reminder and links it back. SPEC §6.5.

## Acceptance criteria
- [ ] Creates reminder with line text; line shows link
EOF

issue "Per-note lock with encryption" "module:notes,feature" "$M5" <<'EOF'
Lock individual notes with Face ID; body encrypted at rest (CryptoKit, key in Keychain). SPEC §6.5.

## Acceptance criteria
- [ ] Locked notes encrypted in store; excluded from search while locked
- [ ] Unlock with biometrics; relocks on background
- [ ] Test: encrypt/decrypt round-trip
EOF

issue "Notes Markdown export" "module:notes,feature" "$M5" <<'EOF'
Export notes as Markdown files + attachments folder to Files, preserving folder structure. SPEC §6.5.

## Acceptance criteria
- [ ] Export all or a folder; relative attachment links work
- [ ] Locked notes require unlock or are skipped (user choice)
EOF

# ============================ Phase 6 ============================
issue "Feed sources and RSS/Atom parsing" "module:news,infra,priority:high" "$M6" <<'EOF'
Source management and RSS/Atom parser (XMLParser); article model. SPEC §6.6.

## Acceptance criteria
- [ ] Add/remove feeds by URL
- [ ] Parses RSS 2.0 and Atom fixtures
- [ ] Articles stored with source, date, link, summary
EOF

issue "Google News topics and holding headlines" "module:news,feature" "$M6" <<'EOF'
Topic follows via Google News RSS search; auto-follow tickers/names of holdings. SPEC §6.6.

## Acceptance criteria
- [ ] Add topic → search feed URL
- [ ] Holdings generate feeds automatically
EOF

issue "Reddit and Hacker News feeds" "module:news,feature" "$M6" <<'EOF'
Public Reddit (.rss) and Hacker News feeds as source types. SPEC §6.6.

## Acceptance criteria
- [ ] Add subreddit and HN (front page/best) sources
EOF

issue "News timeline: filters, read state, duplicate collapsing" "module:news,feature" "$M6" <<'EOF'
Timeline filterable by source/topic; read/unread; collapse duplicate stories. SPEC §6.6.

## Acceptance criteria
- [ ] Filters by source/topic
- [ ] Read/unread toggling
- [ ] Similar-title clustering collapses duplicates (test with fixtures)
EOF

issue "Reader mode and save for later" "module:news,feature" "$M6" <<'EOF'
Reader view with Safari fallback; save for later with offline text; paywalled sites show summary only. SPEC §6.6.

## Acceptance criteria
- [ ] Reader extraction; fallback opens SFSafariViewController/Safari
- [ ] Saved articles readable offline
EOF

issue "Breaking news detection" "module:news,feature" "$M6" <<'EOF'
Breaking = covered by 3+ sources within 2 hours, or wire items flagged breaking. In-app only. SPEC §6.6.

## Acceptance criteria
- [ ] Breaking section in News
- [ ] Test: clustering fixture yields breaking at 3 sources/2h, not at 2
EOF

issue "News background refresh" "module:news,infra" "$M6" <<'EOF'
Refresh on app open and via BGAppRefreshTask. SPEC §6.6.

## Acceptance criteria
- [ ] Refresh on foreground; background task registered and reschedules
- [ ] Conditional GET (ETag/Last-Modified)
EOF

issue "AI daily news digest and morning notification" "module:news,feature" "$M6" <<'EOF'
Foundation Models digest of top stories; one morning local notification (the only news notification). SPEC §6.6.

## Acceptance criteria
- [ ] Digest generated from top clusters, chunked to fit context
- [ ] Morning notification time setting; opens digest
EOF

# ============================ Phase 7 ============================
issue "Today screen with reorderable sections" "module:today,feature,priority:high" "$M7" <<'EOF'
Today screen hosting sections; reorder and hide sections. SPEC §6.1.

## Acceptance criteria
- [ ] Section order/visibility persisted
- [ ] Edit mode to reorder/hide
EOF

issue "Today: agenda and tasks section" "module:today,feature" "$M7" <<'EOF'
Today's events and task blocks, overdue/due-today tasks, next-event countdown. SPEC §6.1.

## Acceptance criteria
- [ ] Merged timeline of events + task blocks
- [ ] Overdue/due-today with check-off
- [ ] Live countdown to next event
EOF

issue "Today: money snapshot section" "module:today,module:finance,feature" "$M7" <<'EOF'
Month spend vs budget, bills due soon, net worth change. Respects Finance lock. SPEC §6.1.

## Acceptance criteria
- [ ] Figures match Finance module
- [ ] Hidden/blurred when Finance is locked
EOF

issue "Today: news digest and daily note sections" "module:today,feature" "$M7" <<'EOF'
AI digest + breaking stories; daily note preview. SPEC §6.1.

## Acceptance criteria
- [ ] Digest and breaking shown
- [ ] Daily note preview opens editor
EOF

issue "Quick capture with AI classification" "module:today,feature" "$M7" <<'EOF'
Single input box; Foundation Models classifies as expense ("Coffee 5.50"), task ("call mom tomorrow 6pm"), or note; user can correct before saving. SPEC §6.1.

## Acceptance criteria
- [ ] Shows type + parsed fields; type switchable
- [ ] Saves to the right module
- [ ] Fixture test of sample inputs
EOF

issue "Tasks widget with interactive check-off" "module:widgets,module:tasks,feature" "$M7" <<'EOF'
Interactive widget listing due tasks with check-off; "+" deep-links to quick-add. Data path per spike result. SPEC §5, §6.2.

## Acceptance criteria
- [ ] Check-off completes reminder and refreshes widget
- [ ] "+" opens app quick-add
EOF

issue "Today, budget and next-event widgets" "module:widgets,feature" "$M7" <<'EOF'
Widgets: Today summary, budget, next event. Budget data via App Group or Keychain snapshot per spike result. SPEC §5.

## Acceptance criteria
- [ ] Three widget kinds, small/medium sizes
- [ ] Timeline reloads when data changes
EOF

issue "Global search" "module:foundation,feature" "$M7" <<'EOF'
Search across notes (incl. OCR text), tasks, events, transactions. SPEC §5.

## Acceptance criteria
- [ ] Results grouped by type; tap navigates
- [ ] Locked notes/Finance excluded while locked
EOF

# ============================ Phase 8 ============================
issue "Mac UI polish: sidebar, keyboard shortcuts, menu commands" "module:mac,feature" "$M8" <<'EOF'
Mac adaptations: sidebar layout polish, keyboard shortcuts, menu bar commands (new task/event/transaction/note, search). SPEC §4.1.

## Acceptance criteria
- [ ] Commands menu with shortcuts
- [ ] Mac-appropriate list/detail layouts per module
EOF

issue "Mac multi-window support (optional)" "module:mac,feature" "$M8" <<'EOF'
Optional: open notes/modules in separate windows. SPEC §4.1.

## Acceptance criteria
- [ ] Open note in new window; state stays consistent
EOF

issue "Sync folder selection with security-scoped bookmark" "module:sync,infra,priority:high" "$M8" <<'EOF'
User picks a shared folder (e.g. iCloud Drive) via document picker; persisted as security-scoped bookmark; no iCloud entitlement. SPEC §4.2.

## Acceptance criteria
- [ ] Pick/change folder on iPhone and Mac
- [ ] Bookmark resolves after relaunch; stale bookmark prompts re-pick
EOF

issue "Sync payload export/import with version and hash" "module:sync,feature" "$M8" <<'EOF'
Write/read app-owned data (finance, notes, news state, settings, attachments) to the sync folder via NSFileCoordinator, with version counter + content hash. SPEC §4.2, §4.4.

## Acceptance criteria
- [ ] Coordinated write and read
- [ ] Newer version imported; identical hash skipped
- [ ] Test: export on A, import on B yields same data
EOF

issue "Lease-based sync lock with read-only mode" "module:sync,feature" "$M8" <<'EOF'
Lock file with device id, timestamp, expiry, heartbeat renewal; other device goes read-only with banner; stale leases expire. Best-effort (iCloud eventually consistent). SPEC §4.3.

## Acceptance criteria
- [ ] Acquire/renew/release lease
- [ ] Read-only mode + banner naming holder device
- [ ] Stale lease takeover after expiry
- [ ] Test: lease state machine incl. clock skew tolerance
EOF

issue "Sync conflict detection and resolution UI" "module:sync,feature" "$M8" <<'EOF'
Detect conflicts via NSFileVersion and version counter/hash mismatch; UI to pick a version. Safety net for best-effort lock. SPEC §4.4.

## Acceptance criteria
- [ ] Conflict versions detected and listed
- [ ] Keep mine / keep theirs; resolved versions cleaned up
EOF

# ============================ Phase 9 ============================
issue "Spike: watchOS install on free account and WatchConnectivity" "module:watch,spike,priority:high" "$M9" <<'EOF'
VERIFY a watchOS app installs from a free Personal Team build and can round-trip a WatchConnectivity message with the phone. SPEC §2.2, §2.3, §6.7.

## Acceptance criteria
- [ ] Watch app installs and launches on the watch with Personal Team signing
- [ ] Developer Mode on the watch enabled; steps noted
- [ ] App IDs consumed by watch app + extension counted (10/week limit)
- [ ] `sendMessage` phone → watch → phone reply round-trip works
- [ ] Results written to SPEC.md §12
EOF

issue "Spike: EventKit access on watchOS" "module:watch,spike" "$M9" <<'EOF'
VERIFY whether the watch app can read reminders/events and complete a reminder directly via EventKit. Decides direct vs phone-relayed data. SPEC §2.3, §6.7.

## Acceptance criteria
- [ ] Permission prompt on watch; record granted/denied behavior
- [ ] Read today's reminders and events on the watch
- [ ] Complete a reminder on the watch; change shows in Reminders on iPhone
- [ ] Decision (direct or phone-relayed) + results written to SPEC.md §12
EOF

issue "watchOS app target, navigation shell and theming" "module:watch,infra,priority:high" "$M9" <<'EOF'
watchOS 26+ app target in the same Xcode project; navigation shell for glance, tasks, capture; palette from the phone theme. SPEC §2.1, §6.7.

## Acceptance criteria
- [ ] Watch app target builds and runs with Personal Team signing
- [ ] Shell with Today, Tasks, Capture screens (placeholders ok)
- [ ] Accent/module colors match the phone palette (synced or shared code)
- [ ] Shared model code compiles for watchOS without iOS-only APIs
EOF

issue "Phone-watch sync layer: snapshot and actions" "module:watch,infra,priority:high" "$M9" <<'EOF'
Codable snapshot (next event, today's tasks, budget left, net worth) pushed phone → watch via `applicationContext`; action channel watch → phone via `sendMessage`, queued with `transferUserInfo` when unreachable. SPEC §6.7.

## Acceptance criteria
- [ ] Phone pushes a new snapshot when tasks, events, or budget change
- [ ] Watch persists last snapshot and shows it on launch without the phone
- [ ] Actions queued when phone unreachable and delivered once reachable
- [ ] Phone confirms each action; watch updates state
- [ ] Unit test: snapshot encode/decode round-trip
EOF

issue "Watch Today glance" "module:watch,module:today,feature" "$M9" <<'EOF'
Glance screen: next event, today's tasks, budget left, from the synced snapshot. SPEC §6.7, §6.1.

## Acceptance criteria
- [ ] Shows next event with time/countdown, today's tasks, budget left
- [ ] Shows last-synced time; stale data marked
- [ ] Budget hidden when Finance lock mode is on
EOF

issue "Watch task check-off synced to Reminders" "module:watch,module:tasks,feature" "$M9" <<'EOF'
Check off today's tasks on the watch; completion reaches Apple Reminders via the phone, or directly via EventKit per spike result. SPEC §6.7, §6.2.

## Acceptance criteria
- [ ] Tap completes task on the watch with immediate UI feedback
- [ ] Reminder marked complete in Reminders app on iPhone
- [ ] Check-off while phone unreachable is queued and applied later
- [ ] Failed completion reverts the watch UI state
EOF

issue "Watch voice quick capture via phone AI" "module:watch,feature" "$M9" <<'EOF'
Dictation on the watch ("coffee 5.50", "call mom 6pm") sent to the phone; Foundation Models classifies as expense, task, or note (reuses §6.1 quick capture). SPEC §6.7.

## Acceptance criteria
- [ ] Dictation input produces text on the watch
- [ ] Phone classifies and returns type + parsed fields
- [ ] Watch shows result for confirmation; saves only after confirm
- [ ] Captures queued when phone unreachable, classified once reachable
EOF

issue "Complications: next event and task count" "module:watch,module:widgets,feature" "$M9" <<'EOF'
WidgetKit complications for next event and today's task count, in all four accessory families. Uses the synced snapshot. SPEC §6.7.

## Acceptance criteria
- [ ] Next event in `accessoryCircular`, `accessoryRectangular`, `accessoryInline`, `accessoryCorner`
- [ ] Task count in the same four families
- [ ] Timelines reload when a new snapshot arrives
- [ ] Tap opens the matching watch screen
EOF

issue "Complications: budget left and net worth" "module:watch,module:widgets,module:finance,feature" "$M9" <<'EOF'
WidgetKit complications for budget left and net worth, in all four accessory families. Respects the Finance Face ID lock setting. SPEC §6.7, §5.

## Acceptance criteria
- [ ] Budget left in `accessoryCircular`, `accessoryRectangular`, `accessoryInline`, `accessoryCorner`
- [ ] Net worth in the same four families
- [ ] Amounts hidden (placeholder shown) when Finance locked mode is on
- [ ] Timelines reload when a new snapshot arrives
EOF

issue "Verify phone notifications mirror to watch" "module:watch,spike" "$M9" <<'EOF'
Confirm the phone's local notifications mirror to the watch (system behavior). No code expected. SPEC §6.7.

## Acceptance criteria
- [ ] Reminder alarm appears on the watch when the phone is locked
- [ ] Bill reminder notification appears on the watch
- [ ] News digest notification appears on the watch
- [ ] Results written to SPEC.md §12
EOF
