import UIKit
import UniformTypeIdentifiers

/// "Jethriki" in other apps' share sheets: takes the shared link(s), leaves them for the app (in the shared
/// app group) and opens Jethriki on the Download tab with the link filled in.
final class ShareViewController: UIViewController {
    private static let appGroup = "group.com.dustalexw.jethriki"
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.text = "Adding to Jethriki…"
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24)
        ])
        Task { await collect() }
    }

    private func collect() async {
        var links: [String] = []
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
               !url.isFileURL {
                links.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                links += Self.links(in: text)
            }
        }
        await MainActor.run { finish(links) }
    }

    /// The http(s) links in shared text (YouTube shares "Title https://youtu.be/…").
    private static func links(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let url = $0.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url.absoluteString
        }
    }

    private func finish(_ links: [String]) {
        guard !links.isEmpty else {
            label.text = "There's no link here to download."
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.extensionContext?.completeRequest(returningItems: nil) }
            return
        }
        if let defaults = UserDefaults(suiteName: Self.appGroup) {
            defaults.set((defaults.stringArray(forKey: "sharedLinks") ?? []) + links, forKey: "sharedLinks")
        }
        label.text = links.count == 1 ? "Added to Jethriki." : "Added \(links.count) links to Jethriki."
        // Open the app with the links as well, for setups where the app group isn't shared.
        var components = URLComponents(string: "jethriki://add")!
        components.queryItems = links.map { URLQueryItem(name: "url", value: $0) }
        if let url = components.url { openContainingApp(url) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.extensionContext?.completeRequest(returningItems: nil) }
    }

    /// Extensions can't open their app directly; the application object up the responder chain can, through
    /// its Objective-C method (the Swift one is marked unavailable to extensions).
    private func openContainingApp(_ url: URL) {
        typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                let open = unsafeBitCast(current.method(for: selector), to: OpenURL.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }
}
