import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iPhone and iPad differences that aren't just layout.
enum Device {
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    /// The Files app's name for the app's own storage: "On My iPhone" or "On My iPad".
    static var filesLocation: String { isPad ? "On My iPad" : "On My iPhone" }
    static var name: String { isPad ? "iPad" : "iPhone" }
}

extension View {
    /// Keeps forms and lists at a comfortable reading width on a wide iPad screen, centred, while the whole
    /// width still scrolls. Phones and narrow iPad windows (Split View, Slide Over) are unchanged.
    func readableWidth(_ maxWidth: CGFloat = 720) -> some View {
        modifier(ReadableWidth(maxWidth: maxWidth))
    }

    /// Sheets with a lot in them (format lists, the sign-in browser) open page-sized on iPad instead of as a
    /// small card in the middle of the screen.
    func pageSizedSheet() -> some View {
        modifier(PageSizedSheet())
    }

    /// The column widths the app's two-column iPad layouts use.
    func sidebarColumnWidth() -> some View {
        navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
    }
}

private struct ReadableWidth: ViewModifier {
    let maxWidth: CGFloat
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content
                .contentMargins(.horizontal, sizeClass == .regular ? max(0, (width - maxWidth) / 2) : 0, for: .scrollContent)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        } else {
            content
        }
    }
}

private struct PageSizedSheet: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.presentationSizing(.page)
        } else {
            content
        }
    }
}

/// Shown in an iPad detail column before anything is picked.
struct EmptyDetail: View {
    let symbol: String
    let title: String
    var message = ""

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(Theme.ribbonDiagonal)
            Text(title).font(.headline)
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
    }
}

/// Reads links out of things dropped on the app: URLs dragged from Safari, or text with links in it.
enum LinkDrop {
    static let types: [UTType] = [.url, .plainText]

    static func load(_ providers: [NSItemProvider], into receive: @escaping ([String]) -> Void) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, !url.isFileURL else { return }
                    DispatchQueue.main.async { receive([url.absoluteString]) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                    guard let text = text as? String else { return }
                    let links = text.components(separatedBy: .whitespacesAndNewlines)
                        .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
                    DispatchQueue.main.async { receive(links) }
                }
            }
        }
        return accepted
    }
}
