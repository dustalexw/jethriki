import SwiftUI

final class CommentChapterSearch: ObservableObject {
    @Published var isSearching = false
    @Published var preview: CommentChapterPreview?
    @Published var error: String?
    private var runner: ProcessRunner?
    private var searchID = UUID()

    func search(url: String, options: DownloadOptions, tools: ToolSnapshot) {
        guard !isSearching else { return }
        error = nil
        searchID = UUID()
        let currentID = searchID
        isSearching = true
        var json = ""
        var lastError = ""
        let process = ProcessRunner(executable: tools.ytdlp,
                                    arguments: CommentChapterService.arguments(url: url, options: options, preview: true),
                                    environment: tools.environment)
        process.onLine = { line, isError in
            if isError { if line.contains("ERROR:") { lastError = line } }
            else { json += line + "\n" }
        }
        process.onExit = { [weak self] code in
            guard let self, self.searchID == currentID else { return }
            self.runner = nil
            guard self.isSearching else { return }
            self.isSearching = false
            do {
                guard code == 0 else { throw SimpleError(lastError.isEmpty ? "Could not fetch comments (exit \(code))." : lastError) }
                self.preview = try CommentChapterService.preview(from: json)
            } catch { self.error = error.localizedDescription }
        }
        runner = process
        do { try process.start() }
        catch { runner = nil; isSearching = false; self.error = error.localizedDescription }
    }

    func cancel() {
        searchID = UUID()
        isSearching = false
        runner?.terminate()
        // Retain the process until onExit drains its pipes.
    }
    deinit { runner?.terminate() }
}

#if os(macOS)
struct CommentChapterPicker: View {
    let preview: CommentChapterPreview
    let onSelect: (String) -> Void
    @State private var selectedID: String?
    @Environment(\.dismiss) private var dismiss

    private var selected: CommentChapterCandidate? {
        preview.candidates.first { $0.id == (selectedID ?? preview.candidates.first?.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose comment chapters").font(.title2)
            Text(preview.title).font(.headline).lineLimit(2)
            HSplitView {
                List(preview.candidates, selection: $selectedID) { candidate in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.author).font(.headline)
                        Text("\(candidate.chapters.count) chapters · \(candidate.likes) likes").foregroundStyle(.secondary)
                    }.padding(.vertical, 4).tag(candidate.id)
                }.frame(minWidth: 200, idealWidth: 230)
                ScrollView {
                    if let selected {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(selected.chapters.enumerated()), id: \.offset) { _, chapter in
                                HStack(alignment: .top) {
                                    Text(MetadataFetcher.formatDuration(chapter.start))
                                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                                    Text(chapter.title)
                                }
                            }
                            Divider()
                            Text("Original comment").font(.headline)
                            Text(selected.text).font(.callout).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                }.frame(minWidth: 350)
            }
            Text("This choice applies to this video. Other videos automatically use the valid list with the most chapters, then the most likes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use these chapters") {
                    if let selected { onSelect(selected.id) }
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selected == nil)
            }
        }.padding(20).frame(width: 760, height: 560)
        .onAppear { selectedID = preview.candidates.first?.id }
    }
}
#endif
