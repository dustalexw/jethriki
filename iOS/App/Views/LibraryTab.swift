import SwiftUI
import QuickLook
import CoreImage.CIFilterBuiltins

/// Everything in the save folder: play, share, set as ringtone, send to another phone, delete.
struct LibraryTab: View {
    @EnvironmentObject private var store: OptionsStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var files: [URL] = []
    @State private var search = ""
    @State private var selected: URL?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var folder: URL { URL(fileURLWithPath: store.options.outputDirectory) }
    private var visible: [URL] {
        let q = search.trimmed.lowercased()
        return q.isEmpty ? files : files.filter { $0.lastPathComponent.lowercased().contains(q) }
    }
    /// iPad (full screen or a wide window): picking a file previews it beside the list.
    private var split: Bool { sizeClass == .regular }
    private var selection: Binding<URL?> {
        Binding(get: { split ? selected : nil }, set: { if split { selected = $0 } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                if files.isEmpty && !split {
                    emptyLibrary
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                ForEach(visible, id: \.self) { url in
                    if split {
                        NavigationLink(value: url) { FileRow(url: url, previewOnTap: false, onDelete: { deleted(url) }) }
                    } else {
                        FileRow(url: url, onDelete: { deleted(url) })
                    }
                }
                .onDelete { offsets in
                    let gone = offsets.map { visible[$0] }
                    for url in gone { try? FileManager.default.removeItem(at: url) }
                    if let selected, gone.contains(selected) { self.selected = nil }
                    reload()
                }
            }
            .searchable(text: $search)
            .navigationTitle("Library")
            .refreshable { reload() }
            .onAppear(perform: reload)
            .onReceive(downloads.objectWillChange) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { reload() }
            }
            .sidebarColumnWidth()
        } detail: {
            NavigationStack {
                if let selected, FileManager.default.fileExists(atPath: selected.path) {
                    FilePreview(url: selected, onDelete: { deleted(selected) })
                } else {
                    if files.isEmpty {
                        emptyLibrary
                    } else {
                        EmptyDetail(symbol: "play.rectangle", title: "Pick a file",
                                    message: "It plays here, with sharing and ringtone options at the top.")
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var emptyLibrary: some View {
        EmptyDetail(symbol: "folder", title: "No downloads yet",
                    message: "Finished files appear here, and in the Files app under \(Device.filesLocation) › Jethriki.")
    }

    private func deleted(_ url: URL) {
        if selected == url { selected = nil }
        reload()
    }

    private func reload() {
        let fm = FileManager.default
        var found: [(URL, Date)] = []
        if let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard values?.isRegularFile == true else { continue }
                let name = url.lastPathComponent
                if name == "yt-dlp-archive.txt" || name.hasSuffix(".part") || name.hasSuffix(".ytdl") { continue }
                found.append((url, values?.contentModificationDate ?? .distantPast))
            }
        }
        files = found.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// What can be done with a downloaded file: one list, used by the row's ⋯ menu, its long-press / right-click
/// menu and the iPad preview's toolbar.
struct FileActions {
    let url: URL
    var notification = false

    var ext: String { url.pathExtension.lowercased() }
    var isTone: Bool { ["m4r", "ogg"].contains(ext) }
    var isAudio: Bool { ["mp3", "m4a", "m4r", "aac", "opus", "ogg", "flac", "wav", "alac", "mka"].contains(ext) }
    var isVideo: Bool { ["mp4", "mkv", "webm", "mov", "avi", "flv"].contains(ext) }
    var canBeRingtone: Bool { ext == "m4r" || ext == "m4a" }
    var canSendOverWiFi: Bool { isTone || ext == "m4a" }
    var symbol: String { isTone ? "bell.badge" : isAudio ? "music.note" : isVideo ? "film" : "doc" }
    var sendsNotification: Bool { notification || url.lastPathComponent.lowercased().contains("notification") }

    var details: String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
        let date = values?.contentModificationDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        return [ext.uppercased(), size, date].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A file to drag into Files, Mail or another app on iPad.
    func dragItem() -> NSItemProvider {
        let item = NSItemProvider(contentsOf: url) ?? NSItemProvider()
        item.suggestedName = url.lastPathComponent
        return item
    }
}

/// A downloaded file with the things you can do with it.
struct FileRow: View {
    let url: URL
    var notification = false
    /// Off where tapping the row shows the file beside the list (iPad) instead of full screen.
    var previewOnTap = true
    var onDelete: () -> Void = {}

    @State private var preview: URL?
    @State private var wifiShare = false
    @State private var ringtoneHelp = false

    private var file: FileActions { FileActions(url: url, notification: notification) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.symbol)
                .font(.title3)
                .foregroundStyle(Theme.ribbonDiagonal)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).lineLimit(2)
                Text(file.details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu { actions } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Actions")
        }
        .contentShape(Rectangle())
        .onTapGesture { if previewOnTap { preview = url } }
        .contextMenu { actions }
        .onDrag { file.dragItem() }
        .quickLookPreview($preview)
        .sheet(isPresented: $wifiShare) { WiFiShareSheet(url: url, notification: file.sendsNotification) }
        .sheet(isPresented: $ringtoneHelp) { RingtoneHelpSheet(url: url) }
    }

    @ViewBuilder
    private var actions: some View {
        if previewOnTap {
            Button { preview = url } label: { Label("Open", systemImage: "eye") }
        }
        ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
        if file.canBeRingtone {
            Button { ringtoneHelp = true } label: { Label("Use as Ringtone…", systemImage: "bell") }
        }
        if file.canSendOverWiFi {
            Button { wifiShare = true } label: { Label("Send to a phone over Wi-Fi", systemImage: "qrcode") }
        }
        Divider()
        Button(role: .destructive) {
            try? FileManager.default.removeItem(at: url)
            onDelete()
        } label: { Label("Delete", systemImage: "trash") }
    }
}

/// iPad: a file playing beside the Library list, with its actions in the toolbar.
struct FilePreview: View {
    let url: URL
    var onDelete: () -> Void = {}
    @State private var wifiShare = false
    @State private var ringtoneHelp = false

    private var file: FileActions { FileActions(url: url) }

    var body: some View {
        InlineQuickLook(url: url)
            .id(url)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(url.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if file.canBeRingtone {
                        Button { ringtoneHelp = true } label: { Label("Use as Ringtone", systemImage: "bell") }
                    }
                    if file.canSendOverWiFi {
                        Button { wifiShare = true } label: { Label("Send over Wi-Fi", systemImage: "qrcode") }
                    }
                    ShareLink(item: url)
                    Button(role: .destructive) {
                        try? FileManager.default.removeItem(at: url)
                        onDelete()
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .sheet(isPresented: $wifiShare) { WiFiShareSheet(url: url, notification: file.sendsNotification) }
            .sheet(isPresented: $ringtoneHelp) { RingtoneHelpSheet(url: url) }
    }
}

/// Quick Look's player and viewer, embedded in a view rather than covering the screen.
struct InlineQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

/// How to make a downloaded tone this iPhone's ringtone.
struct RingtoneHelpSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    private var seconds: Double? {
        (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(MP4.durationSeconds)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Tap Share below, then Use as Ringtone. It may be under More.", systemImage: "1.circle")
                    Label("Choose it in Settings › Sounds & Haptics › Ringtone (or Text Tone).", systemImage: "2.circle")
                    Label("If Share doesn't offer it, open the Files app › \(Device.filesLocation) › Jethriki, press and hold the tone, and choose Share › Use as Ringtone.", systemImage: "questionmark.circle")
                } footer: {
                    Text("Use as Ringtone needs iOS 26 or later and a tone under 30 seconds. On older iPhones, send the .m4r from Jethriki on a Mac or PC with the cable.")
                }
                if let seconds, seconds >= RingtoneShare.maxSeconds {
                    Section { Warning("This tone is \(Int(seconds)) seconds long. iOS only offers Use as Ringtone for tones under 30 seconds; trim it shorter and download again.") }
                }
                Section {
                    ShareLink(item: url) { Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up") }
                }
            }
            .navigationTitle("Use as Ringtone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Shares a file with a phone on the same Wi-Fi: it scans the QR code and downloads the file in its browser.
/// Ringtones get a page with the steps to use them (see RingtoneShare).
struct WiFiShareSheet: View {
    let url: URL
    var notification = false
    @Environment(\.dismiss) private var dismiss
    @State private var share: RingtoneShare?
    @State private var problem: String?
    @State private var downloads = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let share {
                    Text(share.forAndroid ? "Scan with the Android phone's camera" : "Scan with the other phone's camera")
                        .font(.headline)
                    QRCodeView(text: share.url.absoluteString)
                        .frame(width: 240, height: 240)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 18).fill(.white))
                    Text(share.url.absoluteString).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                    if downloads > 0 {
                        Label("Downloaded \(downloads == 1 ? "once" : "\(downloads) times")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Hint(share.forAndroid
                         ? (notification ? "On the phone: download the tone, then pick it in Settings › Sound & vibration › Notification sound."
                                         : "On the phone: download the tone, then pick it in Settings › Sound & vibration › Phone ringtone.")
                         : "Both phones need to be on the same Wi-Fi. Keep this screen open until the download finishes.")
                } else if let problem {
                    Warning(problem)
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("Send over Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear(perform: start)
        .onDisappear { share?.stop(); share = nil }
    }

    private func start() {
        do {
            let s = try RingtoneShare(path: url.path, notification: notification)
            s.onDownload = { [weak s] in downloads = s?.downloads ?? downloads }
            share = s
        } catch {
            problem = error.localizedDescription
        }
    }
}

struct QRCodeView: View {
    let text: String
    var body: some View {
        if let image = Self.make(text) {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
        } else {
            Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }
    static func make(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
