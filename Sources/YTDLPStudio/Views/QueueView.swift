import SwiftUI
import AppKit
import QuickLookThumbnailing

struct QueueView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var store: OptionsStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Queue").font(.system(size: 13, weight: .semibold))
                if !downloads.jobs.isEmpty {
                    Text("\(downloads.jobs.count)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.ribbonDiagonal))
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: store.options.outputDirectory))
                } label: { Image(systemName: "folder") }
                .buttonStyle(IconButtonStyle())
                .help("Open download folder")
                Button { downloads.clearFinished() } label: { Image(systemName: "checkmark.circle.badge.xmark") }
                    .buttonStyle(IconButtonStyle())
                    .disabled(!downloads.jobs.contains { $0.status.isDone })
                    .help("Clear finished")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            if downloads.jobs.isEmpty {
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Theme.violet.opacity(0.18))
                            .frame(width: 84, height: 84)
                            .blur(radius: 14)
                        Image(systemName: "arrow.down")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Theme.ribbonDiagonal)
                            .frame(width: 60, height: 60)
                            .background(Circle().strokeBorder(Theme.ribbonDiagonal, lineWidth: 1.5))
                    }
                    Text("Nothing queued")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Paste a link above and press Download.\nAnalyze shows every available format first.")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(downloads.jobs) { job in
                        JobRow(job: job)
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Theme.hairline)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

struct JobRow: View {
    @ObservedObject var job: DownloadJob
    @EnvironmentObject private var downloads: DownloadManager
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                if job.status == .finished {
                    FinishedThumbnail(job: job, fallback: statusIcon)
                } else {
                    statusIcon
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.displayTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(job.status.label)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                    if !job.detailLine.isEmpty {
                        Text(job.detailLine)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                controls
            }
            progressBar
        }
        .padding(.vertical, 4)
        .popover(isPresented: $showLog, arrowEdge: .leading) {
            LogView(job: job)
        }
        .contextMenu {
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.url, forType: .string)
            }
            Button("Show log") { showLog = true }
            if !job.outputFiles.isEmpty { Button("Show in Finder") { downloads.reveal(job) } }
            Divider()
            if job.status.isActive || job.status == .queued { Button("Cancel") { downloads.cancel(job) } }
            if job.status.isDone { Button("Retry") { downloads.retry(job) } }
            Button("Remove", role: .destructive) { downloads.remove(job) }
        }
    }

    @ViewBuilder private var progressBar: some View {
        switch job.status {
        case .downloading, .encoding:
            RibbonProgress(value: job.progress)
        case .starting, .processing:
            RibbonProgress(value: nil)
        default:
            EmptyView()
        }
    }

    private var statusIcon: some View {
        let (symbol, colors): (String, [Color]) = {
            switch job.status {
            case .queued: return ("clock", [Color(white: 0.45), Color(white: 0.28)])
            case .starting, .downloading: return ("arrow.down", [Theme.blue, Theme.cyan])
            case .processing: return ("gearshape.2", [Theme.violet, Theme.pink])
            case .encoding: return ("wand.and.stars", [Theme.ember, Theme.flame])
            case .finished: return ("checkmark", [Color(red: 0.15, green: 0.75, blue: 0.55), Theme.cyan])
            case .warning: return ("exclamationmark", [Theme.flame, .yellow])
            case .failed: return ("xmark", [Theme.ember, Theme.pink])
            case .cancelled: return ("stop.fill", [Color(white: 0.45), Color(white: 0.28)])
            }
        }()
        return IconTile(symbol: symbol, colors: colors, size: 28)
    }

    private var statusColor: Color {
        switch job.status {
        case .failed: return .red
        case .warning: return .orange
        case .finished: return Color(red: 0.35, green: 0.85, blue: 0.65)
        default: return .secondary
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button { showLog = true } label: { Image(systemName: "text.alignleft") }
                .help("Show log")
            if job.status.isActive || job.status == .queued {
                Button { downloads.cancel(job) } label: { Image(systemName: "xmark") }
                    .help("Cancel")
            } else {
                if !job.outputFiles.isEmpty {
                    Button { downloads.reveal(job) } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                }
                Button { downloads.retry(job) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Retry")
                Button { downloads.remove(job) } label: { Image(systemName: "trash") }
                    .help("Remove from queue")
            }
        }
        .buttonStyle(IconButtonStyle(diameter: 24))
    }
}

private let mediaExtensions: Set<String> = [
    "mp4", "mkv", "webm", "mov", "m4v", "avi", "flv", "mp3", "m4a", "m4r", "opus", "ogg", "flac", "wav", "aac", "aiff"]

/// Shown only once a download has finished: a thumbnail of the saved file with the check badge over it.
/// Until the thumbnail is ready (or if none can be made) the plain check tile is shown.
struct FinishedThumbnail<Fallback: View>: View {
    @ObservedObject var job: DownloadJob
    let fallback: Fallback
    @State private var image: NSImage?

    private var mediaPath: String? {
        let existing = job.outputFiles.filter { FileManager.default.fileExists(atPath: $0) }
        return existing.first { mediaExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(LinearGradient(colors: [Color(red: 0.15, green: 0.75, blue: 0.55), Theme.cyan],
                                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
                            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                            .offset(x: 5, y: 5)
                    }
                    .padding([.trailing, .bottom], 5)
            } else {
                fallback
            }
        }
        .task(id: job.outputFiles) {
            guard let path = mediaPath else { image = nil; return }
            let request = QLThumbnailGenerator.Request(
                fileAt: URL(fileURLWithPath: path), size: CGSize(width: 64, height: 40),
                scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

/// Slim progress track filled with the icon's ribbon gradient. `nil` shows an indeterminate shimmer.
struct RibbonProgress: View {
    let value: Double?
    @State private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                if let value {
                    Capsule()
                        .fill(Theme.ribbon)
                        .frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
                        .shadow(color: Theme.violet.opacity(0.6), radius: 4)
                        .animation(.easeOut(duration: 0.25), value: value)
                } else {
                    Capsule()
                        .fill(Theme.ribbon)
                        .frame(width: geo.size.width * 0.35)
                        .offset(x: geo.size.width * phase)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = 0.65 }
                        }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
    }
}

struct LogView: View {
    @ObservedObject var job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.displayTitle).font(.headline).lineLimit(1)
                Spacer()
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.log.joined(separator: "\n"), forType: .string)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(job.log.isEmpty ? "No output yet." : job.log.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: job.log.count) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .padding(12)
        .frame(width: 680, height: 400)
    }
}
