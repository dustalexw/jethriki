import SwiftUI
import UniformTypeIdentifiers

/// Where downloads go. By default the app's Documents folder (Files › On My iPhone › Jethriki); the user can
/// pick another folder (iCloud Drive, a USB drive…), which iOS grants through a security-scoped bookmark.
enum SaveFolder {
    private static let bookmarkKey = "saveFolderBookmark"
    private static var accessed: URL?

    static var appFolder: String { DownloadOptions.defaultOutputDirectory }

    /// Called at launch: the app's container path changes between installs, and a chosen folder must be
    /// reopened through its bookmark.
    static func restore(into store: OptionsStore) {
        if let url = resolveBookmark() {
            beginAccess(url.path)
            if store.options.outputDirectory != url.path { store.options.outputDirectory = url.path }
        } else if store.options.outputDirectory != appFolder {
            store.options.outputDirectory = appFolder
        }
    }

    static func choose(_ url: URL, store: OptionsStore) {
        guard url.startAccessingSecurityScopedResource() else { return }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        accessed?.stopAccessingSecurityScopedResource()
        accessed = url
        store.options.outputDirectory = url.path
    }

    static func useAppFolder(store: OptionsStore) {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
        store.options.outputDirectory = appFolder
    }

    /// Keeps access to a chosen folder open while downloads write to it.
    static func beginAccess(_ path: String) {
        guard path != appFolder, accessed?.path != path, let url = resolveBookmark(), url.path == path else { return }
        if url.startAccessingSecurityScopedResource() {
            accessed?.stopAccessingSecurityScopedResource()
            accessed = url
        }
    }

    private static func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, url.startAccessingSecurityScopedResource(),
           let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }
}

/// The Save to row on the Output options page.
struct SaveFolderRow: View {
    @Binding var o: DownloadOptions
    @EnvironmentObject private var store: OptionsStore
    @State private var choosing = false

    private var isAppFolder: Bool { o.outputDirectory == SaveFolder.appFolder }

    var body: some View {
        HStack {
            Image(systemName: isAppFolder ? "iphone" : "folder.fill").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(isAppFolder ? "\(Device.filesLocation) › Jethriki" : URL(fileURLWithPath: o.outputDirectory).lastPathComponent)
                if !isAppFolder {
                    Text(o.outputDirectory).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        Button("Choose another folder…") { choosing = true }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { SaveFolder.choose(url, store: store) }
            }
        if !isAppFolder {
            Button("Use Jethriki's folder") { SaveFolder.useAppFolder(store: store) }
        }
        Hint("Jethriki's folder is in the Files app under \(Device.filesLocation) › Jethriki. You can also save to iCloud Drive or another location.")
    }
}
