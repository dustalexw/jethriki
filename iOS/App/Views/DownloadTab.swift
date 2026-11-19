import SwiftUI

/// Paste links, pick a preset or tweak options, and add them to the queue.
struct DownloadTab: View {
    @EnvironmentObject private var store: OptionsStore
    @EnvironmentObject private var tools: ToolLocator
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var router: AppRouter

    @StateObject private var commentSearch = CommentChapterSearch()
    @State private var commentSelections: [String: String] = [:]
    @State private var commentSelectionSummary: String?
    @State private var urlText = ""
    @State private var inspecting: MediaInfo?
    @State private var isFetching = false
    @State private var errorMessage: String?
    @State private var showSavePreset = false
    @State private var newPresetName = ""
    @State private var showCommand = false
    @State private var category: OptionCategory?
    @State private var columns = NavigationSplitViewVisibility.all
    @FocusState private var linkFocused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var urls: [String] {
        urlText.components(separatedBy: .whitespacesAndNewlines).map(\.trimmed).filter { !$0.isEmpty }
    }

    var body: some View {
        // On iPad the form and the chosen options page sit side by side; on iPhone (and in a narrow iPad
        // window) the split collapses into the familiar stack, with each options page pushed on top.
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $category) {
                Section {
                    linkField
                    Picker("Mode", selection: $store.options.mode) {
                        ForEach(DownloadMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    HStack {
                        Button {
                            analyze()
                        } label: {
                            if isFetching { ProgressView() } else { Label("Analyze", systemImage: "magnifyingglass") }
                        }
                        .buttonStyle(.bordered)
                        .disabled(urls.isEmpty || isFetching)
                        .keyboardShortcut("i", modifiers: .command)
                        Spacer()
                        Button(action: startDownload) {
                            Label(urls.count > 1 ? "Download \(urls.count)" : "Download", systemImage: "arrow.down")
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                        }
                        .buttonStyle(GlowButtonStyle())
                        .disabled(urls.isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                    .listRowSeparator(.hidden)
                } footer: {
                    Text(summary)
                }

                if let problem = tools.startProblem {
                    Section {
                        Warning("yt-dlp couldn't start: \(problem)")
                    }
                }

                Section("Options") {
                    ForEach(OptionCategory.allCases) { category in
                        NavigationLink(value: category) {
                            HStack(spacing: 12) {
                                IconTile(symbol: category.symbol, colors: Theme.tile(category), size: 28)
                                Text(category.title)
                                Spacer()
                                if category.isCustomized(store.options) {
                                    Circle().fill(Theme.ribbonDiagonal).frame(width: 7, height: 7)
                                }
                            }
                        }
                    }
                    if store.options.chapterSource != .youtube {
                        Hint("Comment chapters are prepared before downloading.")
                    }
                }

                Section {
                    DisclosureGroup("yt-dlp command", isExpanded: $showCommand) {
                        let command = CommandBuilder.displayCommand(for: store.options, urls: urls)
                        Text(command)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Copy command") { UIPasteboard.general.string = command }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            // Beside the options on iPad, the brand mark already names the app.
            .navigationTitle(sizeClass == .regular ? "" : "Jethriki")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { BrandMark() }
                ToolbarItem(placement: .navigationBarTrailing) { presetsMenu }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { linkFocused = false }
                }
            }
            .sidebarColumnWidth()
        } detail: {
            NavigationStack {
                if let category {
                    optionsPage(category)
                        .readableWidth()
                        .navigationTitle(category.title)
                        .navigationBarTitleDisplayMode(.inline)
                } else {
                    EmptyDetail(symbol: "slider.horizontal.3", title: "Options",
                                message: "Pick a group of options on the left. Changes apply to the next download.")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            // A wide screen has room to show the first options page straight away.
            if sizeClass == .regular && category == nil { category = .format }
        }
        .sheet(item: $inspecting) { info in
            FormatsSheet(info: info,
                         onUseFormat: { store.options.customFormat = $0 },
                         onDownload: { startDownload() })
                .pageSizedSheet()
        }
        .sheet(item: $commentSearch.preview) { preview in
            CommentChapterSheet(preview: preview) { commentID in
                commentSelections[preview.videoID] = commentID
                if let candidate = preview.candidates.first(where: { $0.id == commentID }) {
                    commentSelectionSummary = "Selected \(candidate.chapters.count) chapters from \(candidate.author) for \(preview.title)."
                }
            }
            .pageSizedSheet()
        }
        .onChange(of: commentSearch.error) { message in
            if let message { errorMessage = message }
        }
        .onChange(of: router.incomingLinks) { links in
            guard !links.isEmpty else { return }
            urlText = ([urlText.trimmed] + links).filter { !$0.isEmpty }.joined(separator: "\n")
            router.incomingLinks = []
        }
        .onAppear {
            if !router.incomingLinks.isEmpty {
                urlText = ([urlText.trimmed] + router.incomingLinks).filter { !$0.isEmpty }.joined(separator: "\n")
                router.incomingLinks = []
            }
        }
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
            Text("Saves every option except the save folder.")
        }
    }

    // MARK: Pieces

    private var linkField: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "link").foregroundStyle(Theme.ribbonDiagonal).padding(.top, 3)
            TextField("Paste a link — or several, one per line", text: $urlText, axis: .vertical)
                .lineLimit(1...5)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($linkFocused)
            if urlText.isEmpty {
                Button {
                    if let s = UIPasteboard.general.string { urlText = s.trimmed }
                } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Paste")
            } else {
                Button { urlText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear")
            }
        }
    }

    private var summary: String {
        let o = store.options
        switch o.mode {
        case .audio:
            return o.audioFormat == .best ? "Original audio" :
                "\(o.audioFormat.label)\(o.audioFormat.isLossless ? "" : " · " + o.audioQuality.label)\(o.makesNotificationSound ? " · notification" : "")"
        case .video, .videoOnly:
            var parts = [o.container.rawValue.uppercased(), o.maxResolution == .best ? "Best quality" : o.maxResolution.label]
            if o.encodeEnabled { parts.append("re-encode") }
            return parts.joined(separator: " · ")
        }
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
            Button("Reset all options", role: .destructive) { store.reset() }
        } label: {
            Label("Presets", systemImage: "slider.horizontal.3")
        }
    }

    @ViewBuilder
    private func optionsPage(_ category: OptionCategory) -> some View {
        switch category {
        case .format: FormatOptionsView(o: $store.options)
        case .audio: AudioOptionsView(o: $store.options)
        case .encode: EncodeOptionsView(o: $store.options)
        case .chapters:
            ChaptersOptionsView(o: $store.options,
                onFindComments: {
                    guard let url = urls.first, let snapshot = tools.snapshot() else { return }
                    commentSearch.search(url: url, options: store.options, tools: snapshot)
                }, onCancelSearch: { commentSearch.cancel() },
                canSearchComments: !urls.isEmpty,
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

    // MARK: Actions

    private func startDownload() {
        let list = urls
        guard !list.isEmpty, let snapshot = tools.snapshot() else { return }
        linkFocused = false
        SaveFolder.beginAccess(store.options.outputDirectory)
        downloads.enqueue(urls: list, options: store.options, tools: snapshot, commentSelections: commentSelections)
        urlText = ""
        Notifier.requestPermissionOnce()
        router.tab = .queue
    }

    private func analyze() {
        guard let first = urls.first, let snapshot = tools.snapshot() else { return }
        linkFocused = false
        isFetching = true
        let cookies = store.options.cookiesFile
        Task { @MainActor in
            do {
                inspecting = try await MetadataFetcher.fetch(url: first, tools: snapshot, cookieBrowser: .none, cookiesFile: cookies)
            } catch {
                errorMessage = error.localizedDescription
            }
            isFetching = false
        }
    }
}
