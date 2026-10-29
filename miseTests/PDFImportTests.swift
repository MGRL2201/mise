import Testing
import Foundation
import PDFKit
@testable import mise

@MainActor
struct PDFImportTests {
    @Test func readsTextPDF() async throws {
        let data = try #require(TransactionReview.samplePDF()?.data)
        let layer = try #require(PDFDocument(data: data)?.page(at: 0)?.string)
        #expect(layer.contains("SP GROUP"))
        let text = await PDFImport.text(in: data)
        #expect(text == layer, "text path, not OCR")
        #expect(text.contains("SP GROUP"))
        #expect(text.contains("128.50"))
        #expect(TransactionExtraction.prepass(text, now: .now).total == Decimal(string: "128.50"), "\(text)")
    }

    /// Image-only page: no text layer, so the total can only come from OCR.
    @Test func readsScannedPDF() async throws {
        let data = try #require(TransactionReview.samplePDF(scanned: true)?.data)
        let layer = PDFDocument(data: data)?.string ?? ""
        #expect(layer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let text = await PDFImport.text(in: data)
        #expect(text.contains("TOAST BOX"))
        #expect(text.contains("7.40"))
    }

    @Test func garbageGivesEmptyText() async {
        #expect(await PDFImport.text(in: Data("not a pdf".utf8)) == "")
    }
}
