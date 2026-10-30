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
        category.sortOrder = 3
        category.budget = Decimal(string: "450.50")!
        let transaction = mise.Transaction(amount: Decimal(string: "-40.33")!, currency: "SGD", date: Date(timeIntervalSince1970: 1000))
        transaction.merchant = "Hawker"
        transaction.notes = "lunch"
        transaction.categoryIsAuto = true
        transaction.attachmentID = UUID()
        transaction.source = .applePay
        transaction.homeAmount = Decimal(string: "-40.33")!
        transaction.accountAmount = Decimal(string: "-41.20")!
        let transfer = Transfer(amount: 40, toAmount: 40, date: Date(timeIntervalSince1970: 2000))
        transfer.notes = "pay card"
        [account, debit].forEach(source.context.insert)
        let salary = mise.Category(name: "Salary")
        salary.isIncome = true
        source.context.insert(category)
        source.context.insert(salary)
        source.context.insert(transaction)
        source.context.insert(transfer)
        transaction.account = account
        transaction.category = category
        transfer.from = debit
        transfer.to = account
        let goal = Goal(name: "Trip", target: Decimal(string: "1200.50")!, currency: "SGD")
        goal.targetDate = Date(timeIntervalSince1970: 3000)
        goal.createdAt = Date(timeIntervalSince1970: 4000)
        goal.contributions = [GoalContribution(amount: 100, date: Date(timeIntervalSince1970: 100)),
                              GoalContribution(amount: Decimal(string: "-20.25")!, date: Date(timeIntervalSince1970: 200))]
        source.context.insert(goal)
        goal.account = debit
        let holding = Holding(symbol: "VWRA", name: "Vanguard All-World", kind: .fund,
                              quantity: Decimal(string: "12.5")!, costBasis: Decimal(string: "1500.10")!, currency: "USD")
        holding.price = Decimal(string: "130.42")!
        holding.priceDate = Date(timeIntervalSince1970: 5000)
        holding.createdAt = Date(timeIntervalSince1970: 6000)
        let unpriced = Holding(symbol: "BTC", name: "Bitcoin", kind: .crypto, quantity: Decimal(string: "0.25")!,
                               costBasis: 9000, currency: "USD")
        unpriced.coinID = "bitcoin"
        source.context.insert(holding)
        source.context.insert(unpriced)
        holding.account = account
        try source.context.save()

        let target = try freshStore()
        target.context.insert(Goal(name: "Stale", target: 1, currency: "USD"))
        target.context.insert(Holding(symbol: "OLD", name: "Stale", kind: .stock, quantity: 1, costBasis: 1, currency: "USD"))
        target.context.insert(Account(name: "Stale", type: .cash, currency: "USD"))
        target.context.insert(mise.Category(name: "Stale", icon: "tag", color: 0))
        try target.context.save()
        try restore(try export(source), into: target)

        let accounts = try target.context.fetch(FetchDescriptor<Account>())
        #expect(Set(accounts.map(\.name)) == ["Card", "Debit"])
        let card = try #require(accounts.first { $0.id == account.id })
        #expect(card.type == .credit && card.currency == "SGD" && card.openingBalance == Decimal(string: "19.99"))
        #expect(card.archived && card.createdAt == account.createdAt)
        let all = try target.context.fetch(FetchDescriptor<mise.Category>())
        #expect(Set(all.map(\.name)) == ["Food", "Salary"])
        #expect(all.filter(\.isIncome).map(\.name) == ["Salary"])
        let categories = all.filter { !$0.isIncome }
        #expect(categories.first?.id == category.id && categories.first?.icon == "fork.knife" && categories.first?.color == 0xFF8800)
        #expect(categories.first?.sortOrder == 3 && categories.first?.budget == Decimal(string: "450.50"))
        let copy = try #require(try target.context.fetch(FetchDescriptor<mise.Transaction>()).first)
        #expect(copy.id == transaction.id && copy.amount == Decimal(string: "-40.33") && copy.currency == "SGD" && copy.date == transaction.date)
        #expect(copy.merchant == "Hawker" && copy.notes == "lunch" && copy.categoryIsAuto)
        #expect(copy.attachmentID == transaction.attachmentID && copy.source == .applePay && copy.homeAmount == Decimal(string: "-40.33"))
        #expect(copy.accountAmount == Decimal(string: "-41.20"))
        #expect(copy.account === card && copy.category === categories.first)
        let transferCopy = try #require(try target.context.fetch(FetchDescriptor<Transfer>()).first)
        #expect(transferCopy.id == transfer.id && transferCopy.amount == 40 && transferCopy.toAmount == 40)
        #expect(transferCopy.date == transfer.date && transferCopy.notes == "pay card")
        #expect(transferCopy.from?.id == debit.id && transferCopy.to === card)
        #expect(Finance.balance(of: card, rates: FXRates()) == Decimal(string: "19.66"))
        let goals = try target.context.fetch(FetchDescriptor<Goal>())
        let goalCopy = try #require(goals.first)
        #expect(goals.count == 1)
        #expect(goalCopy.id == goal.id && goalCopy.name == "Trip" && goalCopy.target == Decimal(string: "1200.50"))
        #expect(goalCopy.currency == "SGD" && goalCopy.targetDate == goal.targetDate && goalCopy.createdAt == goal.createdAt)
        #expect(goalCopy.contributions == goal.contributions && goalCopy.account?.id == debit.id)
        let holdings = try target.context.fetch(FetchDescriptor<Holding>())
        #expect(Set(holdings.map(\.symbol)) == ["VWRA", "BTC"])
        let holdingCopy = try #require(holdings.first { $0.id == holding.id })
        #expect(holdingCopy.kind == .fund && holdingCopy.name == "Vanguard All-World" && holdingCopy.currency == "USD")
        #expect(holdingCopy.quantity == Decimal(string: "12.5") && holdingCopy.costBasis == Decimal(string: "1500.10"))
        #expect(holdingCopy.price == Decimal(string: "130.42") && holdingCopy.priceDate == holding.priceDate)
        #expect(holdingCopy.createdAt == holding.createdAt && holdingCopy.account === card)
        let unpricedCopy = try #require(holdings.first { $0.id == unpriced.id })
        #expect(unpricedCopy.kind == .crypto && unpricedCopy.quantity == Decimal(string: "0.25") && unpricedCopy.costBasis == 9000)
        #expect(unpricedCopy.price == nil && unpricedCopy.priceDate == nil && unpricedCopy.account == nil)
        #expect(unpricedCopy.coinID == "bitcoin" && holdingCopy.coinID == nil)
    }

    @Test func billsRoundTripAndReplaceStale() throws {
        let source = try freshStore()
        let account = Account(name: "Card", type: .credit, currency: "SGD")
        let category = mise.Category(name: "Subs")
        let bill = Bill(name: "Netflix", amount: Decimal(string: "19.98")!, currency: "SGD",
                        nextDue: Date(timeIntervalSince1970: 1_800_000_000))
        bill.cadence = .yearly
        bill.interval = 2
        bill.anchorDay = 31
        bill.remindDays = 0
        bill.active = false
        bill.createdAt = Date(timeIntervalSince1970: 5000)
        source.context.insert(account)
        source.context.insert(category)
        source.context.insert(bill)
        bill.account = account
        bill.category = category
        try source.context.save()

        let target = try freshStore()
        target.context.insert(Bill(name: "Stale", amount: 1, currency: "USD", nextDue: .now))
        try target.context.save()
        try restore(try export(source), into: target)

        let bills = try target.context.fetch(FetchDescriptor<Bill>())
        let copy = try #require(bills.first)
        #expect(bills.count == 1)
        #expect(copy.id == bill.id && copy.name == "Netflix" && copy.amount == Decimal(string: "19.98") && copy.currency == "SGD")
        #expect(copy.cadence == .yearly && copy.interval == 2 && copy.nextDue == bill.nextDue && copy.anchorDay == 31)
        #expect(copy.remindDays == 0 && !copy.active && copy.createdAt == bill.createdAt)
        #expect(copy.account?.id == account.id && copy.category?.id == category.id)
    }

    @Test func backupWithoutFinanceLeavesAccountsAlone() throws {
        let target = try freshStore()
        target.context.insert(Account(name: "Kept", type: .cash, currency: "SGD"))
        target.context.insert(NetWorthSnapshot(date: .now, total: 5, currency: "SGD"))
        try target.context.save()
        let settings = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
        let json = #"{"version":2,"createdAt":0,"attachments":[],"settings":"\#(settings.base64EncodedString())","tags":[],"taskExtras":[]}"#
        try restore(Data(json.utf8), into: target)
        #expect(try target.context.fetch(FetchDescriptor<Account>()).map(\.name) == ["Kept"])
        #expect(try target.context.fetch(FetchDescriptor<NetWorthSnapshot>()).map(\.total) == [5])
    }

    @Test func netWorthSnapshotsRoundTripAndReplaceStale() throws {
        let source = try freshStore()
        let snapshot = NetWorthSnapshot(date: Date(timeIntervalSince1970: 1_800_000_000),
                                        total: Decimal(string: "1234.56")!, currency: "SGD")
        source.context.insert(snapshot)
        try source.context.save()

        let target = try freshStore()
        target.context.insert(NetWorthSnapshot(date: .now, total: 1, currency: "USD"))
        try target.context.save()
        try restore(try export(source), into: target)

        let snapshots = try target.context.fetch(FetchDescriptor<NetWorthSnapshot>())
        let copy = try #require(snapshots.first)
        #expect(snapshots.count == 1)
        #expect(copy.id == snapshot.id && copy.date == snapshot.date)
        #expect(copy.total == Decimal(string: "1234.56") && copy.currency == "SGD")
    }
}
