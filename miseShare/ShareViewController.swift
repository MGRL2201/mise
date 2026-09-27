import UIKit
import UniformTypeIdentifiers

/// Spike #13: copies the first shared PDF or image into the App Group inbox
/// and closes. No UI.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let match = providers.lazy.compactMap { provider in
            [UTType.pdf, .image].first { provider.hasItemConformingToTypeIdentifier($0.identifier) }
                .map { (provider, $0) }
        }.first
        guard let (provider, type) = match else {
            extensionContext?.cancelRequest(withError: CocoaError(.fileReadUnsupportedScheme))
            return
        }
        // The file at `url` is deleted when the callback returns, so copy inside it.
        _ = provider.loadFileRepresentation(for: type) { url, _, error in
            let result = Result<Void, Error> {
                guard let url else { throw error ?? CocoaError(.fileNoSuchFile) }
                try SharedInbox.importFile(at: url)
            }
            Task { @MainActor in
                switch result {
                case .success: self.extensionContext?.completeRequest(returningItems: nil)
                case .failure(let error): self.extensionContext?.cancelRequest(withError: error)
                }
            }
        }
    }
}
