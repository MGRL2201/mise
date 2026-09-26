import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct AutoBackupTests {
    private let day: TimeInterval = 86_400

    @Test func isDueAfterSevenDays() {
        let now = Date.now
        #expect(AutoBackup.isDue(last: nil, now: now))
        #expect(!AutoBackup.isDue(last: now.addingTimeInterval(-6.9 * day), now: now))
        #expect(AutoBackup.isDue(last: now.addingTimeInterval(-7 * day), now: now))
    }

    @Test func pruneKeepsNewestAutoBackupsOnly() {
        let dir = URL(filePath: "/tmp/x")
        let names = ["mise-auto-20260103-000000.json", "mise-auto-20260101-000000.json",
                     "other.json", "mise-auto-20260102-000000.json", "mise-backup-2026-01-01.json"]
        let pruned = AutoBackup.filesToPrune(names.map { dir.appending(path: $0) }, keep: 2)
        #expect(pruned.map(\.lastPathComponent) == ["mise-auto-20260101-000000.json"])
    }

    @Test func runIfDueWritesPrunesAndSkipsWhenNotDue() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let other = folder.appending(path: "keep-me.json")
        try Data("x".utf8).write(to: other)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: AutoBackup.enabledKey)
        try AutoBackup.setFolder(folder, defaults: defaults)
        let container = try ModelContainer(for: Schema(Storage.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        func autoFiles() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("mise-auto-") }
        }

        var now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try AutoBackup.runIfDue(context: context, defaults: defaults, now: now))
        #expect(try autoFiles().count == 1)
        #expect(try !AutoBackup.runIfDue(context: context, defaults: defaults, now: now))
        #expect(try autoFiles().count == 1)

        for _ in 0..<4 {
            now += 7 * day
            #expect(try AutoBackup.runIfDue(context: context, defaults: defaults, now: now))
        }
        #expect(try autoFiles().count == 4)
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func runIfDueRecordsLastEvenWhenPruneFails() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stale = folder.appending(path: "mise-auto-20200101-000000.json")
        try Data("x".utf8).write(to: stale)
        // Immutable flag blocks deletion regardless of directory write permission, so
        // pruning this file fails while writing the new backup file still succeeds.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: stale.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: stale.path) }

        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: AutoBackup.enabledKey)
        defaults.set(1, forKey: AutoBackup.keepKey) // keep only the new file, so the stale one must be pruned
        try AutoBackup.setFolder(folder, defaults: defaults)
        let container = try ModelContainer(for: Schema(Storage.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(throws: (any Error).self) {
            try AutoBackup.runIfDue(context: context, defaults: defaults, now: now)
        }
        #expect(defaults.object(forKey: AutoBackup.lastKey) as? Date == now)
    }
}
