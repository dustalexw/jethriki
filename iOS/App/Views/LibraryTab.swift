import SwiftUI
import QuickLook
import CoreImage.CIFilterBuiltins

/// Everything in the save folder: play, share, set as ringtone, send to another phone, delete.
struct LibraryTab: View {
    @EnvironmentObject private var store: OptionsStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var files: [URL] = []
    @State private var search = ""

    private var folder: URL { URL(fileURLWithPath: store.options.outputDirectory) }
    private var visible: [URL] {
        let q = search.trimmed.lowercased()
        return q.isEmpty ? files : files.filter { $0.lastPathComponent.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if files.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "folder").font(.system(size: 40)).foregroundStyle(Theme.ribbonDiagonal)
                        Text("No downloads yet").font(.headline)
                        Text("Finished files appear here, and in the Files app under On My iPhone › Jethriki.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .listRowBackground(Color.clear)
                }
                ForEach(visible, id: \.self) { url in
                    FileRow(url: url, notification: false, onDelete: { reload() })
                }
                .onDelete { offsets in
                    for i in offsets { try? FileManager.default.removeItem(at: visible[i]) }
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
        }
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

/// A downloaded file with the things you can do with it.
struct FileRow: View {
    let url: URL
    var notification = false
    var onDelete: () -> Void = {}

    @State private var preview: URL?
    @State private var sharing = false
    @State private var wifiShare = false
    @State private var ringtoneHelp = false

    private var ext: String { url.pathExtension.lowercased() }
    private var isTone: Bool { ["m4r", "ogg"].contains(ext) }
    private var isAudio: Bool { ["mp3", "m4a", "m4r", "aac", "opus", "ogg", "flac", "wav", "alac", "mka"].contains(ext) }
    private var isVideo: Bool { ["mp4", "mkv", "webm", "mov", "avi", "flv"].contains(ext) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isTone ? "bell.badge" : isAudio ? "music.note" : isVideo ? "film" : "doc")
                .font(.title3)
                .foregroundStyle(Theme.ribbonDiagonal)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).lineLimit(2)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                Button { preview = url } label: { Label("Open", systemImage: "eye") }
                Button { sharing = true } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                if ext == "m4r" || ext == "m4a" {
                    Button { ringtoneHelp = true } label: { Label("Use as Ringtone…", systemImage: "bell") }
                }
                if isTone || ext == "m4a" {
                    Button { wifiShare = true } label: { Label("Send to a phone over Wi-Fi", systemImage: "qrcode") }
                }
                Divider()
                Button(role: .destructive) {
                    try? FileManager.default.removeItem(at: url)
                    onDelete()
                } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture { preview = url }
        .quickLookPreview($preview)
        .sheet(isPresented: $sharing) { ActivitySheet(items: [url]) }
        .sheet(isPresented: $wifiShare) { WiFiShareSheet(url: url, notification: notification || isNotificationName) }
        .sheet(isPresented: $ringtoneHelp) { RingtoneHelpSheet(url: url) }
    }

    private var isNotificationName: Bool { url.lastPathComponent.lowercased().contains("notification") }

    private var details: String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
        let date = values?.contentModificationDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        return [ext.uppercased(), size, date].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The system share sheet. On iOS 26, an audio file's share sheet offers Use as Ringtone.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// How to make a downloaded tone this iPhone's ringtone.
struct RingtoneHelpSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false

    private var seconds: Double? {
        (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(MP4.durationSeconds)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Tap Share below, then Use as Ringtone. It may be under More.", systemImage: "1.circle")
                    Label("Choose it in Settings › Sounds & Haptics › Ringtone (or Text Tone).", systemImage: "2.circle")
                } footer: {
                    Text("Use as Ringtone needs iOS 26 or later and a tone under 30 seconds. On older iPhones, send the .m4r from Jethriki on a Mac or PC with the cable.")
                }
                if let seconds, seconds >= RingtoneShare.maxSeconds {
                    Section { Warning("This tone is \(Int(seconds)) seconds long. iOS only offers Use as Ringtone for tones under 30 seconds; trim it shorter and download again.") }
                }
                Section {
                    Button { sharing = true } label: { Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up") }
                }
            }
            .navigationTitle("Use as Ringtone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $sharing) { ActivitySheet(items: [url]) }
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
            s.onDownload = { downloads = s.downloads }
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
