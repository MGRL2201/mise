import Foundation
import ImageIO
import Vision

/// Receipt photos -> OCR text -> extraction drafts (#45).
enum ReceiptScan {
    /// Vision OCR of each image (PNG/JPEG/HEIC data), pages joined by a blank line. Unreadable images skipped. Off main.
    @concurrent nonisolated static func text(in images: [Data]) async -> String {
        var pages: [String] = []
        for data in images {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            // Camera JPEG/HEIC store rotation in EXIF; Vision reads sideways text badly without it.
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init)
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true // default is en-US only; CJK receipts need detection
            guard let observations = try? await request.perform(on: image, orientation: orientation) else { continue }
            // Vision splits receipt columns ("TOTAL" | "7.40") into separate observations; rebuild lines from layout
            // (normalized coords, origin bottom-left) so the line-based prepass sees label and amount together.
            // ponytail: rows grouped by midY within half the row's first box height; skewed/tilted photos may merge
            // or split rows. Upgrade: group along the text baseline angle.
            var rows: [[RecognizedTextObservation]] = []
            for observation in observations.sorted(by: { $0.boundingBox.cgRect.midY > $1.boundingBox.cgRect.midY }) {
                if let first = rows.last?.first,
                   abs(first.boundingBox.cgRect.midY - observation.boundingBox.cgRect.midY) <= first.boundingBox.cgRect.height / 2 {
                    rows[rows.count - 1].append(observation)
                } else {
                    rows.append([observation])
                }
            }
            let page = rows.map { row in
                row.sorted { $0.boundingBox.cgRect.minX < $1.boundingBox.cgRect.minX }
                    .compactMap { $0.topCandidates(1).first?.string }.joined(separator: "  ")
            }.joined(separator: "\n")
            if !page.isEmpty { pages.append(page) }
        }
        return pages.joined(separator: "\n\n")
    }

    /// OCR then TransactionExtraction.extract; blank text gives one empty draft so review still opens.
    static func drafts(from images: [Data], categories: [Category]) async -> [DraftTransaction] {
        let drafts = await TransactionExtraction.extract(await text(in: images), categories: categories)
        return drafts.isEmpty ? [DraftTransaction(amount: 0, currency: FX.home(), date: .now)] : drafts
    }
}

#if os(iOS)
import SwiftUI
import VisionKit

/// VisionKit document camera; hands back one JPEG per page ([] on cancel/failure). Caller dismisses.
struct DocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([Data]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([Data]) -> Void
        init(onFinish: @escaping ([Data]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            // JPEG, not PNG: keeps the page orientation.
            onFinish((0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.9) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { onFinish([]) }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { onFinish([]) }
    }
}
#endif
