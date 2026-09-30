import Testing
import SwiftData
import Foundation
import SwiftUI
@testable import mise

@MainActor
struct BackupTests {
    @MainActor private struct Store {
        let container: ModelContainer
        let files: AttachmentFileStore
        let defaults: UserDefaults
        var context: ModelContext { container.mainContext }
    }

    private func freshStore() throws -> Store {
        Store(
            container: try ModelContainer(
                for: Schema(Storage.models),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            ),
            files: AttachmentFileStore(baseDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
    }

    private func export(_ store: Store) throws -> Data {
        try BackupService.export(context: store.context, files: store.files, defaults: store.defaults)
    }

    private func restore(_ data: Data, into store: Store) throws {
        try BackupService.restore(data, context: store.context, files: store.files, defaults: store.defaults)
    }

    private func add(_ filename: String, bytes: String, to store: Store) throws -> mise.Attachment {
        let attachment = mise.Attachment(filename: filename)
        store.context.insert(attachment)
        try store.files.write(Data(bytes.utf8), for: attachment.id)
        return attachment
    }

    @Test func backupThenRestoreIntoEmptyStoreIsIdentical() throws {
        let source = try freshStore()
        let originals = [try add("a.jpg", bytes: "aaa", to: source), try add("b.pdf", bytes: "bbb", to: source)]
        try source.context.save()
        source.defaults.set("wholeApp", forKey: "lock.mode")
        source.defaults.set(300, forKey: "lock.grace")
        var palette = Palette.default
        palette.light.accent = Color.Resolved(red: 0.1, green: 0.2, blue: 0.3)
        ThemeStore(defaults: source.defaults).palette = palette

        let target = try freshStore()
        try restore(try export(source), into: target)

        let restored = try target.context.fetch(FetchDescriptor<mise.Attachment>())
        #expect(restored.count == 2)
        for original in originals {
            let copy = try #require(restored.first { $0.id == original.id })
            #expect(copy.filename == original.filename)
            #expect(copy.createdAt == original.createdAt)
            #expect(target.files.read(for: copy.id) == source.files.read(for: original.id))
        }
        #expect(target.defaults.string(forKey: "lock.mode") == "wholeApp")
        #expect(target.defaults.integer(forKey: "lock.grace") == 300)
        let restoredPalette = ThemeStore(defaults: target.defaults).palette
        #expect(restoredPalette != .default)
        #expect(restoredPalette == ThemeStore(defaults: source.defaults).palette)
    }

    @Test func corruptSettingsThrowsAndLeavesStoreUntouched() throws {
        let target = try freshStore()
        let existing = try add("old.txt", bytes: "old", to: target)
        try target.context.save()
        target.defaults.set("wholeApp", forKey: "lock.mode")

        let incoming = Backup.AttachmentRecord(id: UUID(), filename: "new.txt", createdAt: .now, data: Data("new".utf8))
        let bad = try JSONEncoder().encode(Backup(version: 1, createdAt: .now, attachments: [incoming],
                                                  settings: Data("garbage".utf8)))
        #expect(throws: BackupError.corruptSettings) { try restore(bad, into: target) }

        #expect(try target.context.fetch(FetchDescriptor<mise.Attachment>()).map(\.id) == [existing.id])
        #expect(target.files.read(for: existing.id) == Data("old".utf8))
        #expect(target.defaults.string(forKey: "lock.mode") == "wholeApp")
    }

    @Test func unknownVersionIsRejected() throws {
        let data = Data(#"{"version": 999}"#.utf8)
        #expect(throws: BackupError.unsupportedVersion(999)) {
            try restore(data, into: try freshStore())
        }
    }

    @Test func restoreReplacesExistingData() throws {
        let source = try freshStore()
        let kept = try add("new.txt", bytes: "new", to: source)
        let backup = try export(source)

        let target = try freshStore()
        let old = try add("old.txt", bytes: "old", to: target)
        try restore(backup, into: target)

        #expect(try target.context.fetch(FetchDescriptor<mise.Attachment>()).map(\.id) == [kept.id])
        #expect(target.files.read(for: old.id) == nil)
    }
}

extension BackupTests {
    @Test func tagsAndTaskExtrasRoundTrip() throws {
        let source = try freshStore()
        let work = try #require(try mise.Tag.named("Work", in: source.context))
        _ = try mise.Tag.named("Unused", in: source.context)
        let extras = TaskExtras(reminderID: "r1", externalID: "e1")
        extras.subtasks = [Subtask(title: "one", done: true), Subtask(title: "two"), Subtask(title: "three")]
        extras.tags = [work]
        extras.eventID = "ev1"
        extras.flagged = true
        extras.estimateMinutes = 45
        source.context.insert(extras)
        source.defaults.set("246", forKey: WorkingHours.daysKey)
        try source.context.save()

        let target = try freshStore()
        target.context.insert(TaskExtras(reminderID: "stale", externalID: nil))
        _ = try mise.Tag.named("Stale", in: target.context)
        try target.context.save()
        try restore(try export(source), into: target)

        #expect(Set(try target.context.fetch(FetchDescriptor<mise.Tag>()).map(\.name)) == ["Work", "Unused"])
        let restored = try target.context.fetch(FetchDescriptor<TaskExtras>())
        let copy = try #require(restored.first)
        #expect(restored.count == 1)
        #expect(copy.reminderID == "r1" && copy.externalID == "e1")
        #expect(copy.subtasks == extras.subtasks)
        #expect(copy.tags?.map(\.name) == ["Work"])
        #expect(copy.eventID == "ev1")
        #expect(copy.flagged)
        #expect(copy.estimateMinutes == 45)
        #expect(target.defaults.string(forKey: WorkingHours.daysKey) == "246")
    }

    @Test func version1BackupStillRestores() throws {
        let target = try freshStore()
        let kept = try #require(try mise.Tag.named("Kept", in: target.context))
        let extras = TaskExtras(reminderID: "r1", externalID: nil)
        target.context.insert(extras)
        extras.tags = [kept]
        try target.context.save()
        let settings = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
        let json = #"{"version":1,"createdAt":0,"attachments":[],"settings":"\#(settings.base64EncodedString())"}"#
        try restore(Data(json.utf8), into: target)
        #expect(try target.context.fetch(FetchDescriptor<mise.Tag>()).map(\.name) == ["Kept"])
        let left = try target.context.fetch(FetchDescriptor<TaskExtras>())
        #expect(left.map(\.reminderID) == ["r1"] && left.first?.tags?.map(\.name) == ["Kept"])
    }

    @Test func duplicateTagNamesRestoreAsOneTag() throws {
        let target = try freshStore()
        let settings = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
        let backup = Backup(version: 2, createdAt: .now, attachments: [], settings: settings,
                            tags: ["Work", " work "],
                            taskExtras: [.init(reminderID: "r1", externalID: nil, subtasks: [], tagNames: ["WORK"])])
        try restore(try JSONEncoder().encode(backup), into: target)
        let tags = try target.context.fetch(FetchDescriptor<mise.Tag>())
        #expect(tags.map(\.name) == ["Work"])
        #expect(try target.context.fetch(FetchDescriptor<TaskExtras>()).first?.tags?.first === tags.first)
    }
    @Test func financeRoundTripsAndReplacesStaleData() throws {
        let source = try freshStore()
        let account = Account(name: "Card", type: .credit, currency: "SGD", openingBalance: Decimal(string: "19.99")!)
        account.archived = true
        let debit = Account(name: "Debit", type: .debit, currency: "SGD")
        let category = mise.Category(name: "Food", icon: "fork.knife", color: 0xFF8800)
        let transaction = mise.Transaction(amount: Decimal(string: "-40.33")!, currency: "SGD", date: Date(timeIntervalSince1970: 1000))
        transaction.merchant = "Hawker"
        transaction.notes = "lunch"
        transaction.categoryIsAuto = true
        transaction.attachmentID = UUID()
        transaction.source = .applePay
        transaction.homeAmount = Decimal(string: "-40.33")!
        let transfer = Transfer(amount: 40, toAmount: 40, date: Date(timeIntervalSince1970: 2000))
        transfer.notes = "pay card"
        [account, debit].forEach(source.context.insert)
        source.context.insert(category)
        source.context.insert(transaction)
        source.context.insert(transfer)
        transaction.account = account
        transaction.category = category
        transfer.from = debit
        transfer.to = account
        try source.context.save()

        let target = try freshStore()
        target.context.insert(Account(name: "Stale", type: .cash, currency: "USD"))
        target.context.insert(mise.Category(name: "Stale", icon: "tag", color: 0))
        try target.context.save()
        try restore(try export(source), into: target)

        let accounts = try target.context.fetch(FetchDescriptor<Account>())
        #expect(Set(accounts.map(\.name)) == ["Card", "Debit"])
        let card = try #require(accounts.first { $0.id == account.id })
        #expect(card.type == .credit && card.currency == "SGD" && card.openingBalance == Decimal(string: "19.99"))
        #expect(card.archived && card.createdAt == account.createdAt)
        let categories = try target.context.fetch(FetchDescriptor<mise.Category>())
        #expect(categories.map(\.name) == ["Food"])
        #expect(categories.first?.id == category.id && categories.first?.icon == "fork.knife" && categories.first?.color == 0xFF8800)
        let copy = try #require(try target.context.fetch(FetchDescriptor<mise.Transaction>()).first)
        #expect(copy.id == transaction.id && copy.amount == Decimal(string: "-40.33") && copy.currency == "SGD" && copy.date == transaction.date)
        #expect(copy.merchant == "Hawker" && copy.notes == "lunch" && copy.categoryIsAuto)
        #expect(copy.attachmentID == transaction.attachmentID && copy.source == .applePay && copy.homeAmount == Decimal(string: "-40.33"))
        #expect(copy.account === card && copy.category === categories.first)
        let transferCopy = try #require(try target.context.fetch(FetchDescriptor<Transfer>()).first)
        #expect(transferCopy.id == transfer.id && transferCopy.amount == 40 && transferCopy.toAmount == 40)
        #expect(transferCopy.date == transfer.date && transferCopy.notes == "pay card")
        #expect(transferCopy.from?.id == debit.id && transferCopy.to === card)
        #expect(Finance.balance(of: card, rates: FXRates()) == Decimal(string: "19.66"))
    }

    @Test func backupWithoutFinanceLeavesAccountsAlone() throws {
        let target = try freshStore()
        target.context.insert(Account(name: "Kept", type: .cash, currency: "SGD"))
        try target.context.save()
        let settings = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
        let json = #"{"version":2,"createdAt":0,"attachments":[],"settings":"\#(settings.base64EncodedString())","tags":[],"taskExtras":[]}"#
        try restore(Data(json.utf8), into: target)
        #expect(try target.context.fetch(FetchDescriptor<Account>()).map(\.name) == ["Kept"])
    }
}
