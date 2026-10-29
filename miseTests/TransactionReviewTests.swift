import Testing
import SwiftData
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import mise

@MainActor
struct TransactionReviewTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let files = AttachmentFileStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let date = Date(timeIntervalSince1970: 1_000_000)

    func attachments() -> [mise.Attachment] { (try? context.fetch(FetchDescriptor<mise.Attachment>())) ?? [] }

    @Test func duplicate() {
        func existing(_ amount: Decimal = -12, currency: String = "SGD", days: Int) -> [mise.Transaction] {
            let transaction = mise.Transaction(amount: amount, currency: currency,
                                               date: Calendar.current.date(byAdding: .day, value: days, to: date)!)
            transaction.merchant = "GRAB*RIDE #4410"
            return [transaction]
        }
        let draft = DraftTransaction(amount: -12, currency: "SGD", date: date, merchant: "Grab Ride")
        #expect(TransactionReview.isDuplicate(draft, in: existing(days: -1)))
        #expect(!TransactionReview.isDuplicate(draft, in: existing(days: -2)))
        #expect(!TransactionReview.isDuplicate(draft, in: existing(-13, days: 0)))
        #expect(!TransactionReview.isDuplicate(draft, in: existing(currency: "USD", days: 0)))
    }

    @Test func commit() throws {
        let sgd = Account(name: "Card", type: .credit, currency: "SGD")
        let food = Category(name: "Food"), transport = Category(name: "Transport")
        context.insert(sgd)
        context.insert(food)
        context.insert(transport)
        let drafts = [
            DraftTransaction(amount: -5, currency: "SGD", date: date, merchant: "Skip", account: sgd, selected: false),
            DraftTransaction(amount: -6, currency: "SGD", date: date, merchant: "No account"),
            DraftTransaction(amount: -10, currency: "USD", date: date, merchant: " Diner ", account: sgd,
                             accountAmount: -13.5, category: food),
            DraftTransaction(amount: -8, currency: "SGD", date: date, merchant: "Grab", account: sgd,
                             accountAmount: -8, category: transport, categoryIsAuto: true),
        ]
        let saved = try TransactionReview.commit(drafts, source: ReviewSource(data: Self.png(), filename: "scan.png"),
                                                 context: context, files: files, defaults: defaults)
        #expect(saved.map(\.merchant) == ["Diner", "Grab"])
        #expect(saved.allSatisfy { $0.source == .imported && $0.attachmentID != nil && $0.homeAmount == nil })
        #expect(saved[0].attachmentID == saved[1].attachmentID)
        #expect(saved[0].accountAmount == -13.5 && saved[1].accountAmount == nil)
        #expect(saved[0].categoryIsAuto == false && saved[1].categoryIsAuto == true)
        #expect(Categorizer.rule(for: "Diner", in: [food, transport], defaults: defaults) === food)
        #expect(Categorizer.rule(for: "Grab", in: [food, transport], defaults: defaults) == nil)

        let attachment = try #require(attachments().first)
        #expect(attachments().count == 1 && attachment.id == saved[0].attachmentID)
        #expect(attachment.filename == "scan.jpg")
        let bytes = try #require(files.read(for: attachment.id))
        let props = try #require(CGImageSourceCreateWithData(bytes as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any])
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0, height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        #expect(width == 2048 && height <= 2048)
    }

    @Test func commitNothingSelected() throws {
        let sgd = Account(name: "Card", type: .credit, currency: "SGD")
        context.insert(sgd)
        let draft = DraftTransaction(amount: -5, currency: "SGD", date: date, account: sgd, selected: false)
        let saved = try TransactionReview.commit([draft], source: ReviewSource(data: Data("pdf".utf8), filename: "a.pdf"),
                                                 context: context, files: files, defaults: defaults)
        #expect(saved.isEmpty && attachments().isEmpty)
    }

    @Test func deleteAttachmentIfUnused() throws {
        let sgd = Account(name: "Card", type: .credit, currency: "SGD")
        context.insert(sgd)
        let draft = DraftTransaction(amount: -5, currency: "SGD", date: date, account: sgd)
        let saved = try TransactionReview.commit([draft, draft], source: ReviewSource(data: Data("pdf".utf8), filename: "a.pdf"),
                                                 context: context, files: files, defaults: defaults)
        let id = try #require(saved[0].attachmentID)
        #expect(attachments().first?.filename == "a.pdf" && files.read(for: id) == Data("pdf".utf8))

        context.delete(saved[0])
        try context.save()
        TransactionReview.deleteAttachmentIfUnused(id, context: context, files: files)
        #expect(attachments().count == 1 && files.read(for: id) != nil)

        context.delete(saved[1])
        try context.save()
        TransactionReview.deleteAttachmentIfUnused(id, context: context, files: files)
        #expect(attachments().isEmpty && files.read(for: id) == nil)
    }

    static func png() -> Data {
        let cg = CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        cg.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
