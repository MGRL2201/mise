import Testing
import Foundation
@testable import mise

@MainActor
struct ReceiptScanTests {
    @Test func readsSampleReceipt() async {
        let text = await ReceiptScan.text(in: [TransactionReview.sampleSource()!.data])
        #expect(text.contains("TOAST BOX"))
        #expect(text.contains("7.40"))
    }

    @Test func skipsUnreadableImage() async {
        #expect(await ReceiptScan.text(in: [Data()]) == "")
    }

    @Test func blankOCRGivesOneEmptyDraft() async {
        let drafts = await ReceiptScan.drafts(from: [Data()], categories: [])
        #expect(drafts.count == 1)
        #expect(drafts.first?.amount == 0)
    }
}
