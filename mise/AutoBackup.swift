import Foundation
import SwiftData
#if os(iOS)
import BackgroundTasks
#endif

/// Optional weekly automatic backup into a user-picked folder (SPEC §5).
/// Keys are deliberately not in `Backup.settingsKeys`: the folder bookmark is device-specific.
enum AutoBackup {
    static let enabledKey = "autoBackup.enabled"
    static let folderKey = "autoBackup.folder"
    static let lastKey = "autoBackup.last"
    static let keepKey = "autoBackup.keep"
    static let lastErrorKey = "autoBackup.lastError"
    static let taskID = "\(Bundle.main.bundleIdentifier ?? "mise").autobackup"

    #if os(macOS)
    private static let createOptions: URL.BookmarkCreationOptions = .withSecurityScope
    private static let resolveOptions: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    private static let createOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif

    static func keep(_ defaults: UserDefaults = .standard) -> Int {
        let keep = defaults.integer(forKey: keepKey)
        return keep > 0 ? keep : 4
    }

    static func isDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= 7 * 86_400
    }

    static func filesToPrune(_ urls: [URL], keep: Int) -> [URL] {
        let backups = urls
            .filter { $0.lastPathComponent.hasPrefix("mise-auto-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        return Array(backups.dropFirst(keep))
    }

    /// Call with access to `url` already granted (e.g. from a file importer).
    static func setFolder(_ url: URL, defaults: UserDefaults = .standard) throws {
        defaults.set(try url.bookmarkData(options: createOptions), forKey: folderKey)
    }

    static func folderURL(_ defaults: UserDefaults = .standard) -> URL? {
        guard let data = defaults.data(forKey: folderKey) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: resolveOptions, bookmarkDataIsStale: &stale)
    }

    /// Returns whether a backup was written.
    static func runIfDue(context: ModelContext, defaults: UserDefaults = .standard, now: Date = .now) throws -> Bool {
        guard defaults.bool(forKey: enabledKey),
              isDue(last: defaults.object(forKey: lastKey) as? Date, now: now),
              let bookmark = defaults.data(forKey: folderKey) else { return false }
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: resolveOptions, bookmarkDataIsStale: &stale)
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        if stale { try setFolder(folder, defaults: defaults) }

        let data = try BackupService.export(context: context, files: AttachmentFileStore(), defaults: defaults)
        try data.write(to: folder.appending(path: "mise-auto-\(stamp.string(from: now)).json"), options: .atomic)
        let existing = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        for url in filesToPrune(existing, keep: keep(defaults)) { try FileManager.default.removeItem(at: url) }
        defaults.set(now, forKey: lastKey)
        return true
    }

    /// App trigger: never throws, records the outcome for Settings.
    static func run(context: ModelContext) {
        do {
            _ = try runIfDue(context: context)
            UserDefaults.standard.removeObject(forKey: lastErrorKey)
        } catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: lastErrorKey)
        }
    }

    #if os(iOS)
    static func scheduleRefresh() {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = .now.addingTimeInterval(86_400)
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
