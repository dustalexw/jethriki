import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: OptionsStore
    @EnvironmentObject private var tools: ToolLocator
    @EnvironmentObject private var downloads: DownloadManager

    @StateObject private var commentSearch = CommentChapterSearch()
    @State private var commentSelections: [String: String] = [:]
    @State private var commentSelectionSummary: String?
    @State private var urlText = ""
    @State private var category: OptionCategory? = .format
    @State private var inspecting: MediaInfo?
    @State private var isFetching = false
    @State private var errorMessage: String?
    @State private var showSavePreset = false
    @State private var newPresetName = ""

    private var urls: [String] {
        urlText.components(separatedBy: .newlines).map(\.trimmed).filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if tools.ytdlpPath == nil || tools.ffmpegPath == nil {
                toolBanner.padding(.horizontal, 14).padding(.bottom, 10)
            }
            HSplitView {
                optionsPane
                    .glassPanel()
                    .padding(.leading, 14).padding(.trailing, 6)
                    .frame(minWidth: 620, idealWidth: 700)
                QueueView()
                    .glassPanel()
                    .padding(.trailing, 14).padding(.leading, 6)
                    .frame(minWidth: 340, idealWidth: 420)
            }
            if store.options.chapterSource != .youtube {
                Hint("Comment chapters are prepared by the app before downloading. The command below shows download options only.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.top, 8)
            }
            CommandPreviewBar(command: CommandBuilder.displayCommand(for: store.options, urls: urls))
                .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .background(CosmicBackground())
        .sheet(item: $inspecting) { info in
            FormatInspector(info: info,
                            onUseFormat: { store.options.customFormat = $0 },
                            onDownload: { startDownload() })
        }
        .sheet(item: $commentSearch.preview) { preview in
            CommentChapterPicker(preview: preview) { commentID in
                commentSelections[preview.videoID] = commentID
                if let candidate = preview.candidates.first(where: { $0.id == commentID }) {
                    commentSelectionSummary = "Selected \(candidate.chapters.count) chapters from \(candidate.author) for \(preview.title)."
                }
            }
        }
        .onChange(of: commentSearch.error) { message in
            if let message { errorMessage = message }
        }
        .onDisappear { commentSearch.cancel() }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Save preset", isPresented: $showSavePreset) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") { store.saveCurrent(as: newPresetName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves every option except the output folder.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                BrandMark()
                    .padding(.trailing, 4)
                addressField
                Button(action: startDownload) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .bold))
                        Text(urls.count > 1 ? "Download \(urls.count)" : "Download")
                    }
                }
                .buttonStyle(GlowButtonStyle())
                .disabled(urls.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Add to queue (⌘↩)")
            }

            HStack(spacing: 12) {
                Picker("Mode", selection: $store.options.mode) {
                    ForEach(DownloadMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)

                summaryChip

                Spacer()

                presetsMenu
            }
        }
        // Leave room for the window's traffic lights in the hidden title bar.
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    /// Compact, pill-shaped link field. Grows to a few lines when several links are pasted.
    private var addressField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ribbonDiagonal)
            TextField("Paste a link — or several, one per line", text: $urlText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .onSubmit(startDownload)
            if !urlText.isEmpty {
                Button { urlText = "" } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(diameter: 20))
                    .help("Clear")
            }
            Button {
                if let s = NSPasteboard.general.string(forType: .string) {
                    urlText = urlText.trimmed.isEmpty ? s.trimmed : urlText.trimmed + "\n" + s.trimmed
                }
            } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(IconButtonStyle(diameter: 24))
                .help("Paste from clipboard")
            Button(action: analyze) {
                if isFetching { ProgressView().controlSize(.mini) }
                else { Image(systemName: "magnifyingglass") }
            }
            .buttonStyle(IconButtonStyle(diameter: 24))
            .disabled(urls.isEmpty || isFetching || tools.ytdlpPath == nil)
            .keyboardShortcut("i", modifiers: .command)
            .help("Analyze: list formats, chapters and playlist items (⌘I)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .frame(minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Theme.fieldFill))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var summaryChip: some View {
        let o = store.options
        let text: String
        switch o.mode {
        case .audio:
            text = o.audioFormat == .best ? "Original audio" :
                "\(o.audioFormat.rawValue.uppercased())\(o.audioFormat.isLossless ? "" : " · " + o.audioQuality.label)\(o.makesNotificationSound ? " · notification" : "")"
        case .video, .videoOnly:
            var parts = [o.container.rawValue.uppercased(), o.maxResolution == .best ? "Best" : o.maxResolution.label]
            if o.encodeEnabled { parts.append("re-encode") }
            text = parts.joined(separator: " · ")
        }
        return Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Theme.chipFill))
            .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    private var presetsMenu: some View {
        Menu {
            Section("Built-in") {
                ForEach(OptionsStore.builtInPresets) { p in
                    Button(p.name) { store.apply(p) }
                }
            }
            if !store.userPresets.isEmpty {
                Section("My presets") {
                    ForEach(store.userPresets) { p in
                        Button(p.name) { store.apply(p) }
                    }
                }
                Menu("Delete preset") {
                    ForEach(store.userPresets) { p in
                        Button(p.name, role: .destructive) { store.delete(p) }
                    }
                }
            }
            Divider()
            Button("Save current settings as preset…") {
                newPresetName = ""
                showSavePreset = true
            }
            Button("Reset all options") { store.reset() }
        } label: {
            Label("Presets", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Capsule().fill(Theme.chipFill))
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    private var toolBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(tools.ytdlpPath == nil
                 ? "yt-dlp isn't installed or couldn't be found. Run `brew install yt-dlp ffmpeg` in Terminal, or set its location in Settings."
                 : "FFmpeg wasn't found. Merging, audio conversion and encoding need it. Run `brew install ffmpeg`, or set its location in Settings.")
                .font(.callout)
            Spacer()
            Button("Scan again") { tools.refresh() }
            Button("Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.yellow.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.yellow.opacity(0.25)))
    }

    // MARK: Options pane

    private var optionsPane: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(OptionCategory.allCases) { c in
                        SidebarRow(category: c, selected: (category ?? .format) == c,
                                   customized: c.isCustomized(store.options)) { category = c }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .frame(width: 225)

            Rectangle().fill(Theme.hairline).frame(width: 1)

            Group {
                switch category ?? .format {
                case .format: FormatOptionsView(o: $store.options)
                case .audio: AudioOptionsView(o: $store.options)
                case .encode: EncodeOptionsView(o: $store.options)
                case .chapters:
                    ChaptersOptionsView(o: $store.options,
                        onFindComments: {
                            guard let url = urls.first, let snapshot = tools.snapshot() else { return }
                            commentSearch.search(url: url, options: store.options, tools: snapshot)
                        }, onCancelSearch: { commentSearch.cancel() },
                        canSearchComments: !urls.isEmpty && tools.ytdlpPath != nil,
                        searchingComments: commentSearch.isSearching,
                        selectedCommentSummary: commentSelectionSummary)
                case .subtitles: SubtitleOptionsView(o: $store.options)
                case .metadata: MetadataOptionsView(o: $store.options)
                case .trim: TrimOptionsView(o: $store.options)
                case .playlist: PlaylistOptionsView(o: $store.options)
                case .network: NetworkOptionsView(o: $store.options)
                case .output: OutputOptionsView(o: $store.options)
                case .advanced: AdvancedOptionsView(o: $store.options)
                }
            }
            .toggleStyle(.checkbox)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Actions

    private func startDownload() {
        let list = urls
        guard !list.isEmpty else { return }
        guard let snapshot = tools.snapshot() else {
            errorMessage = "yt-dlp wasn't found. Install it with `brew install yt-dlp`, or set its path in Settings."
            return
        }
        downloads.enqueue(urls: list, options: store.options, tools: snapshot, commentSelections: commentSelections)
        urlText = ""
    }

    private func analyze() {
        guard let first = urls.first, let snapshot = tools.snapshot() else { return }
        isFetching = true
        let browser = store.options.cookieBrowser
        Task { @MainActor in
            do {
                inspecting = try await MetadataFetcher.fetch(url: first, tools: snapshot, cookieBrowser: browser)
            } catch {
                errorMessage = error.localizedDescription
            }
            isFetching = false
        }
    }
}

struct CommandPreviewBar: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Theme.ribbonDiagonal)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .fixedSize()
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "square.on.square")
            }
            .buttonStyle(IconButtonStyle(diameter: 22))
            .help(copied ? "Copied" : "Copy command")
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.commandFill))
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }
}


/// Sidebar row with a selection fill from the app's palette. The fill stays violet-blue whether or not
/// the window is active (just softer when inactive) instead of the system's neutral gray.
private struct SidebarRow: View {
    let category: OptionCategory
    let selected: Bool
    let customized: Bool
    let action: () -> Void
    @Environment(\.controlActiveState) private var activeState
    @State private var hovering = false

    private var windowActive: Bool { activeState != .inactive }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconTile(symbol: category.symbol, colors: Theme.tile(category))
                Text(category.title).lineLimit(1)
                    .foregroundStyle(selected || hovering ? .primary : .secondary)
                Spacer(minLength: 2)
                if customized {
                    Circle().fill(Theme.ribbonDiagonal).frame(width: 6, height: 6)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Theme.pink.opacity(selected ? 0.35 : 0), Theme.violet.opacity(selected ? 0.30 : 0), Theme.cyan.opacity(selected ? 0.30 : 0)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var fill: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if selected {
            shape.fill(LinearGradient(colors: [Theme.violet.opacity(windowActive ? 0.34 : 0.20),
                                               Theme.blue.opacity(windowActive ? 0.24 : 0.12)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
        } else if hovering {
            shape.fill(Theme.chipFill)
        }
    }
}
