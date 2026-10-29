import SwiftUI

/// What Analyze found: the video's formats (pick one video and one audio stream), chapters, or playlist items.
struct FormatsSheet: View {
    let info: MediaInfo
    var onUseFormat: (String) -> Void
    var onDownload: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<FormatInfo.ID>()
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", video = "Video", audio = "Audio", combined = "A+V"
        var id: String { rawValue }
    }

    private var visibleFormats: [FormatInfo] {
        switch filter {
        case .all: return info.formats
        case .video: return info.formats.filter { $0.hasVideo && !$0.hasAudio }
        case .audio: return info.formats.filter { $0.hasAudio && !$0.hasVideo }
        case .combined: return info.formats.filter { $0.hasVideo && $0.hasAudio }
        }
    }

    /// One video stream + one audio stream, joined the way yt-dlp expects (e.g. "137+140").
    private var selector: String? {
        let picked = info.formats.filter { selection.contains($0.id) }
        guard !picked.isEmpty else { return nil }
        let video = picked.first { $0.hasVideo }
        let audio = picked.first { $0.hasAudio && !$0.hasVideo }
        let ids = [video?.id, (video?.hasAudio == true ? nil : audio?.id)].compactMap { $0 }
        return ids.isEmpty ? picked.first?.id : ids.joined(separator: "+")
    }

    var body: some View {
        NavigationStack {
            List {
                Section { header }
                if info.isPlaylist {
                    Section("\(info.entries.count) items") {
                        ForEach(Array(info.entries.enumerated()), id: \.offset) { index, title in
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
                                Text(title).lineLimit(2)
                            }
                        }
                    }
                    Section { Hint("Use the Playlist options to choose a range of items. Formats are picked per video using your Format options.") }
                } else {
                    Section {
                        Picker("Show", selection: $filter) {
                            ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        ForEach(visibleFormats) { format in
                            Button { toggle(format) } label: { row(format) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Formats")
                    } footer: {
                        Text("Tap one video and one audio stream, or a single combined format.")
                    }
                    if !info.chapters.isEmpty {
                        Section("\(info.chapters.count) chapters") {
                            ForEach(info.chapters) { c in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(c.start).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                                    Text(c.title)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(info.isPlaylist ? "Playlist" : "Formats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selector == nil ? "Download" : "Download \(selector!)") {
                        if let s = selector { onUseFormat(s) }
                        dismiss()
                        onDownload()
                    }
                }
                if !info.isPlaylist {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Use selected format for later downloads") {
                            if let s = selector { onUseFormat(s) }
                            dismiss()
                        }
                        .disabled(selector == nil)
                    }
                }
            }
        }
    }

    private func toggle(_ format: FormatInfo) {
        if selection.contains(format.id) { selection.remove(format.id) } else { selection.insert(format.id) }
    }

    private func row(_ f: FormatInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selection.contains(f.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selection.contains(f.id) ? AnyShapeStyle(Theme.ribbonDiagonal) : AnyShapeStyle(.tertiary))
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(f.kind).font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.chipFill))
                    Text(f.hasVideo ? f.resolution : (f.bitrate.isEmpty ? f.acodec : f.bitrate)).font(.body.weight(.medium))
                    if f.hasVideo, !f.fps.isEmpty { Text("\(f.fps) fps").foregroundStyle(.secondary) }
                    Spacer()
                    Text(f.size).monospacedDigit().foregroundStyle(.secondary)
                }
                Text([f.ext, f.vcodec == "none" ? "" : f.vcodec, f.acodec == "none" ? "" : f.acodec, f.note]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("ID \(f.id)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: info.thumbnail) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: info.isPlaylist ? "music.note.list" : "film").foregroundStyle(.tertiary))
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title).font(.headline).lineLimit(3).textSelection(.enabled)
                if !info.uploader.isEmpty { Text(info.uploader).font(.subheadline).foregroundStyle(.secondary) }
                if !info.duration.isEmpty { Label(info.duration, systemImage: "clock").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Pick which comment's chapter list to use for this video.
struct CommentChapterSheet: View {
    let preview: CommentChapterPreview
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?

    private var selected: CommentChapterCandidate? {
        preview.candidates.first { $0.id == (selectedID ?? preview.candidates.first?.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(preview.candidates) { candidate in
                        Button {
                            selectedID = candidate.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.author).font(.headline)
                                    Text("\(candidate.chapters.count) chapters · \(candidate.likes) likes").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if candidate.id == selected?.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(preview.title)
                } footer: {
                    Text("This choice applies to this video. Other videos use the valid list with the most chapters, then the most likes.")
                }
                if let selected {
                    Section("Chapters") {
                        ForEach(Array(selected.chapters.enumerated()), id: \.offset) { _, chapter in
                            HStack(alignment: .firstTextBaseline) {
                                Text(MetadataFetcher.formatDuration(chapter.start)).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 64, alignment: .trailing)
                                Text(chapter.title)
                            }
                        }
                    }
                    Section("Original comment") {
                        Text(selected.text).font(.callout).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Comment chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        if let selected { onSelect(selected.id) }
                        dismiss()
                    }
                    .disabled(selected == nil)
                }
            }
        }
    }
}
