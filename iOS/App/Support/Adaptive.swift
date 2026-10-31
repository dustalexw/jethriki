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

    /// The sidebar width of the app's two-column layouts (see `SidebarWidth`).
    func sidebarColumnWidth() -> some View {
        modifier(SidebarWidth())
    }
}

/// Centres a form at `maxWidth` on a wide screen. On iPhone Duo held half-open like a book, a form that fills
/// the inner screen moves to the left of the fold instead, so no row's switch or button sits across the crease.
private struct ReadableWidth: ViewModifier {
    let maxWidth: CGFloat
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.windowLayout) private var window
    @State private var width: CGFloat = 0

    private var margins: (leading: CGFloat, trailing: CGFloat) {
        guard sizeClass == .regular else { return (0, 0) }
        // Only a view as wide as the window shares the window's coordinates and can reach across the fold;
        // a page in the right-hand column is already clear of it.
        if let fold = window.fold, fold.isBent, abs(width - window.width) < 1 {
            return (0, max(0, width - fold.minX + 8))
        }
        let centred = max(0, (width - maxWidth) / 2)
        return (centred, centred)
    }

    func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content
                .contentMargins(.leading, margins.leading, for: .scrollContent)
                .contentMargins(.trailing, margins.trailing, for: .scrollContent)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        } else {
            content
        }
    }
}

// MARK: Window size and iPhone Duo's fold

/// A window's width and, on iPhone Duo's inner screen, where its fold runs top to bottom. Measured once at the
/// top of each window (see WindowRoot) and passed down to the views that lay themselves out around it.
struct WindowLayout: Equatable {
    struct Fold: Equatable {
        var minX: CGFloat
        var maxX: CGFloat
        /// Bent rather than lying flat. Flat, content may cross the fold; bent, controls should stay off it.
        var isBent: Bool
        var midX: CGFloat { (minX + maxX) / 2 }
    }
    var width: CGFloat = 0
    var fold: Fold?

    init(width: CGFloat = 0, fold: Fold? = nil) {
        self.width = width
        self.fold = fold
    }

    init(_ proxy: GeometryProxy) {
        width = proxy.size.width
        fold = Self.verticalFold(in: proxy)
    }

    private static func verticalFold(in proxy: GeometryProxy) -> Fold? {
        #if compiler(>=6.4)
        // iPhone Duo's fold is a "division" region, reported (with zero width) even while the phone lies flat.
        if #available(iOS 27.1, *),
           let region = proxy.reservedRegions(kind: .division, options: [.includeInactive]).first,
           region.frame.height > region.frame.width {
            return Fold(minX: region.frame.minX, maxX: region.frame.maxX, isBent: region.isActive)
        }
        #endif
        return nil
    }
}

extension EnvironmentValues {
    @Entry var windowLayout = WindowLayout()
}

/// On iPhone Duo the two columns meet exactly at the fold. Elsewhere, in a window under 1,000 points wide
/// (iPad mini, Split View and Stage Manager windows) they split it evenly; wider windows keep a sidebar of
/// comfortable width.
private struct SidebarWidth: ViewModifier {
    @Environment(\.windowLayout) private var window

    func body(content: Content) -> some View {
        if let fold = window.fold, fold.midX > 0 {
            content.navigationSplitViewColumnWidth(fold.midX.rounded(.down))
        } else if window.width > 0 && window.width < 1000 {
            content.navigationSplitViewColumnWidth((window.width / 2).rounded(.down))
        } else {
            content.navigationSplitViewColumnWidth(min: 340, ideal: 390, max: 460)
        }
    }
}

extension View {
    /// Keeps a sheet's toolbar along the top on iPhone Duo instead of moving it to the side: right for a sheet
    /// whose only control is Done.
    func horizontalToolbar() -> some View {
        modifier(HorizontalToolbar())
    }
}

private struct HorizontalToolbar: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            content.toolbarVerticalBehavior(.disabled)
        } else {
            content
        }
        #else
        content
        #endif
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
