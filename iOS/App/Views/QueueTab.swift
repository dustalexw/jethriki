import SwiftUI

/// Downloads in progress and finished, with their logs and files.
struct QueueTab: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var selection: UUID?
    @State private var knownCount = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var selectedJob: DownloadJob? {
        selection.flatMap { id in downloads.jobs.first { $0.id == id } }
    }

    var body: some View {
        // iPad: the queue on the left, the chosen download's progress, files and log on the right.
        NavigationSplitView {
            Group {
                if downloads.jobs.isEmpty {
                    // On iPad the detail column says this, so the list stays clear.
                    if sizeClass == .regular {
                        Color.clear  // something has to be here for the column to show its title
                    } else {
                        emptyQueue.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    List(selection: $selection) {
                        ForEach(downloads.jobs.reversed()) { job in
                            NavigationLink(value: job.id) { JobRowIOS(job: job) }
                                .swipeActions(edge: .trailing) {
                                    if job.status.isActive || job.status == .queued {
                                        Button("Stop", role: .destructive) { downloads.cancel(job) }
                                    } else {
                                        Button("Remove", role: .destructive) { remove(job) }
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    if job.status.isDone {
                                        Button("Retry") { downloads.retry(job) }.tint(Theme.blue)
                                    }
                                }
                                .contextMenu { menu(for: job) }
                        }
                    }
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Clear finished") { clearFinished() }
                        Button("Stop all", role: .destructive) { downloads.cancelAll() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(downloads.jobs.isEmpty)
                }
            }
            .sidebarColumnWidth()
        } detail: {
            NavigationStack {
                if let job = selectedJob {
                    JobDetailView(job: job).id(job.id)
                } else {
                    if downloads.jobs.isEmpty {
                        emptyQueue
                    } else {
                        EmptyDetail(symbol: "arrow.down.circle", title: "Pick a download",
                                    message: "Its progress, files and log appear here.")
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            knownCount = downloads.jobs.count
            selectNewest(added: false)
        }
        .onChange(of: downloads.jobs.count) { count in
            selectNewest(added: count > knownCount)
            knownCount = count
        }
    }

    private var emptyQueue: some View {
        EmptyDetail(symbol: "tray", title: "Nothing in the queue",
                    message: "Paste a link on the Download tab, or share one to Jethriki from Safari or YouTube.")
    }

    /// On a wide screen, show the newest download when one is added (or when nothing is showing). On a
    /// phone this would push the detail page by itself, so there it's left to a tap.
    private func selectNewest(added: Bool) {
        guard sizeClass == .regular, added || selectedJob == nil else { return }
        selection = downloads.jobs.last?.id
    }

    @ViewBuilder
    private func menu(for job: DownloadJob) -> some View {
        if job.status.isActive || job.status == .queued {
            Button(role: .destructive) { downloads.cancel(job) } label: { Label("Stop", systemImage: "stop.circle") }
        }
        if job.status.isDone {
            Button { downloads.retry(job) } label: { Label("Retry", systemImage: "arrow.clockwise") }
        }
        Button { UIPasteboard.general.string = job.url } label: { Label("Copy Link", systemImage: "link") }
        if !(job.status.isActive || job.status == .queued) {
            Button(role: .destructive) { remove(job) } label: { Label("Remove", systemImage: "trash") }
        }
    }

    private func remove(_ job: DownloadJob) {
        if selection == job.id { selection = nil }
        downloads.remove(job)
    }

    private func clearFinished() {
        downloads.clearFinished()
        if selectedJob == nil { selection = nil }
    }
}

struct JobRowIOS: View {
    @ObservedObject var job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.displayTitle).font(.callout.weight(.medium)).lineLimit(2)
                    Text(job.status.label).font(.caption).foregroundStyle(statusColor).lineLimit(2)
                    if !job.detailLine.isEmpty {
                        Text(job.detailLine).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if job.status.isActive {
                ProgressBar(value: job.progress)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: some View {
        Group {
            switch job.status {
            case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
            case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
            default: Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.ribbonDiagonal)
            }
        }
        .font(.title3)
        .frame(width: 26)
    }

    private var statusColor: Color {
        switch job.status {
        case .failed: return .red
        case .warning: return .orange
        case .finished: return .green
        default: return .secondary
        }
    }
}

/// A thin progress bar in the app's ribbon colours.
struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Theme.ribbon).frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

struct JobDetailView: View {
    @ObservedObject var job: DownloadJob
    @EnvironmentObject private var downloads: DownloadManager
    @State private var preview: URL?

    private var files: [URL] {
        job.outputFiles.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.displayTitle).font(.headline).textSelection(.enabled)
                    Text(job.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(job.status.label).font(.subheadline)
                    if job.status.isActive { ProgressBar(value: job.progress) }
                    if !job.detailLine.isEmpty { Text(job.detailLine).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                HStack {
                    if job.status.isActive || job.status == .queued {
                        Button("Stop", role: .destructive) { downloads.cancel(job) }.buttonStyle(.bordered)
                    }
                    if job.status.isDone {
                        Button("Retry") { downloads.retry(job) }.buttonStyle(.bordered)
                    }
                    Spacer()
                    Button { UIPasteboard.general.string = job.url } label: { Label("Copy link", systemImage: "link") }
                        .buttonStyle(.borderless)
                }
            }
            if !files.isEmpty {
                Section("Files") {
                    ForEach(files, id: \.self) { url in
                        FileRow(url: url, notification: job.options.makesNotificationSound)
                    }
                }
            }
            Section {
                ForEach(Array(job.log.suffix(400).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
                }
            } header: {
                HStack {
                    Text("Log")
                    Spacer()
                    Button("Copy") { UIPasteboard.general.string = job.log.joined(separator: "\n") }.font(.caption)
                }
            }
        }
        .navigationTitle("Download")
        .navigationBarTitleDisplayMode(.inline)
    }
}
