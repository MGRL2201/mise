import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Invoice / bank notice PDFs -> text for extraction (#46). Text layer first; scanned pages go through OCR.
enum PDFImport {
    /// Text of the first `maxPages` pages, pages joined by a blank line; "" when unreadable or locked. Off main.
    // ponytail: pages past `maxPages` are ignored; bank notices/invoices put the total on page 1-2. Raise if needed.
    // The < 20 letters/digits OCR threshold counts all pages together, so a text cover page followed by
    // scanned pages skips OCR. Decide per page if mixed PDFs show up.
    @concurrent nonisolated static func text(in data: Data, maxPages: Int = 5) async -> String {
        guard let document = PDFDocument(data: data), !document.isLocked else { return "" }
        // Per page, not document.string, so long statements stay bounded.
        let pages = (0..<min(document.pageCount, maxPages)).compactMap(document.page(at:))
        let text = pages.compactMap(\.string).joined(separator: "\n\n")
        guard text.filter({ $0.isLetter || $0.isNumber }).count < 20 else { return text }
        // Scanned PDF: no text layer, so render each page white-backed at ~2x (longest side ≤ 2,400 px) and OCR it.
        var images: [Data] = []
        for page in pages {
            // draw(with:to:) applies /Rotate, so size the bitmap to the rotated page.
            let bounds = page.bounds(for: .mediaBox)
            let size = page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
            let scale = min(2, 2_400 / max(size.width, size.height, 1))
            let width = Int(size.width * scale), height = Int(size.height * scale)
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            let png = NSMutableData()
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { images.append(png as Data) }
        }
        return await ReceiptScan.text(in: images)
    }
}
