import Foundation
import SwiftData
import ImageIO
import UniformTypeIdentifiers

/// One extracted transaction awaiting review (#43). A value, not a model: nothing is inserted until Import.
struct DraftTransaction: Identifiable {
    var id = UUID()
    var amount: Decimal          // signed, negative = out; 0 = missing
    var currency: String
    var date: Date
    var merchant = ""
    var notes = ""
    var account: Account?
    var accountAmount: Decimal?  // signed charge in the account's currency when the source gives it
    var category: Category?
    var categoryIsAuto = false
    var selected = true
}

/// The imported file (receipt image or PDF) shared by all drafts of one import. `filename` carries the extension.
struct ReviewSource { var data: Data; var filename: String }

/// Shared review step for imports (#43): dedupe, validate, commit drafts with one source attachment.
enum TransactionReview {
    /// Same currency, signed amount and normalized merchant within ±1 calendar day. Any account, any source.
    /// Callers pass only transactions near the drafts' dates (fetch with a #Predicate on date).
    static func isDuplicate(_ draft: DraftTransaction, in transactions: [Transaction]) -> Bool {
        let calendar = Calendar.current
        let key = Categorizer.normalize(draft.merchant)
        let day = calendar.startOfDay(for: draft.date)
        return transactions.contains {
            $0.currency == draft.currency && $0.amount == draft.amount && Categorizer.normalize($0.merchant) == key
                && abs(calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: $0.date)).day ?? 2) <= 1
        }
    }

    static func isValid(_ draft: DraftTransaction) -> Bool {
        draft.amount != 0 && draft.account != nil
    }

    /// Inserts selected valid drafts as `.imported` transactions sharing one attachment for `source`; saves once.
    /// Nothing to import = no writes. On save failure: delete this import's inserts, remove the written file, rethrow.
    @discardableResult
    static func commit(_ drafts: [DraftTransaction], source: ReviewSource?, context: ModelContext,
                       files: AttachmentFileStore = AttachmentFileStore(),
                       defaults: UserDefaults = .standard) throws -> [Transaction] {
        let drafts = drafts.filter { $0.selected && isValid($0) }
        guard !drafts.isEmpty else { return [] }

        var attachment: Attachment?
        if let source {
            var data = source.data, filename = source.filename
            let name = filename as NSString
            if UTType(filenameExtension: name.pathExtension)?.conforms(to: .image) == true,
               let jpeg = compressImage(data) {
                data = jpeg
                filename = name.deletingPathExtension + ".jpg"
            }
            let new = Attachment(filename: filename)
            try files.write(data, for: new.id)
            context.insert(new)
            attachment = new
        }

        var learned: [(merchant: String, category: Category?)] = []
        let inserted = drafts.map { draft in
            let transaction = Transaction(amount: draft.amount, currency: draft.currency, date: draft.date)
            context.insert(transaction)
            transaction.merchant = draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            transaction.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            transaction.account = draft.account
            transaction.category = draft.category
            transaction.categoryIsAuto = draft.categoryIsAuto && draft.category != nil
            transaction.source = .imported
            transaction.attachmentID = attachment?.id
            transaction.accountAmount = draft.account?.currency != draft.currency
                ? draft.accountAmount.flatMap { $0 == 0 ? nil : $0 } : nil
            if draft.category != nil, !draft.categoryIsAuto, draft.amount < 0, !transaction.merchant.isEmpty {
                learned.append((transaction.merchant, draft.category))
            }
            return transaction
        }
        do {
            try context.save()
        } catch {
            inserted.forEach(context.delete)
            if let attachment {
                context.delete(attachment)
                try? files.delete(for: attachment.id)
            }
            throw error
        }
        for (merchant, category) in learned { Categorizer.learn(merchant, category: category, defaults: defaults) }
        return inserted
    }

    private static let maxPixel = 2048, jpegQuality = 0.7

    /// Downscale + re-encode a photo as JPEG so Backup (which embeds attachment bytes) doesn't bloat.
    /// nil when `data` isn't a decodable image.
    static func compressImage(_ data: Data) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Removes the attachment (model + file) once no transaction references it. Call after deleting and saving a transaction.
    static func deleteAttachmentIfUnused(_ id: UUID?, context: ModelContext,
                                         files: AttachmentFileStore = AttachmentFileStore()) {
        guard let id else { return }
        let users = FetchDescriptor<Transaction>(predicate: #Predicate { $0.attachmentID == id })
        guard (try? context.fetchCount(users)) == 0 else { return }
        for attachment in (try? context.fetch(FetchDescriptor<Attachment>(predicate: #Predicate { $0.id == id }))) ?? [] {
            context.delete(attachment)
        }
        do { try context.save(); try? files.delete(for: id) } catch { context.rollback() }
    }
}
