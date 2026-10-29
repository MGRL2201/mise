import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import mise

@MainActor
struct ReceiptScanTests {
    @Test func readsSampleReceipt() async {
        let text = await ReceiptScan.text(in: [TransactionReview.sampleSource()!.data])
        #expect(text.contains("TOAST BOX"))
        #expect(text.contains("7.40"))
        // Label and amount sit in separate Vision observations; lines must be rebuilt from layout.
        #expect(text.split(separator: "\n").contains { $0.contains("TOTAL") && $0.contains("7.40") })
        #expect(TransactionExtraction.prepass(text, now: .now).total == Decimal(string: "7.40"))
    }

    /// fileImporter photos are not deskewed; at 5° the amount column drifts a line and pairs with the wrong label.
    @Test func readsTiltedReceipt() async throws {
        let source = try #require(CGImageSourceCreateWithData(TransactionReview.sampleSource()!.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let angle = 5 * CGFloat.pi / 180, w = CGFloat(image.width), h = CGFloat(image.height)
        let width = Int(w * cos(angle) + h * sin(angle)) + 40, height = Int(w * sin(angle) + h * cos(angle)) + 40
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: angle)
        context.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let text = await ReceiptScan.text(in: [data as Data])
        #expect(text.split(separator: "\n").contains { $0.contains("TOTAL") && $0.contains("7.40") }, "\(text)")
        #expect(TransactionExtraction.prepass(text, now: .now).total == Decimal(string: "7.40"))
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
