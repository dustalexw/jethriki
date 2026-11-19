import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Import field under the link field: drop (or choose) local video and audio files, then extract their
/// audio or remux them between MKV and MP4 with FFmpeg. Jobs go into the regular queue.
struct ImportField: View {
    @EnvironmentObject private var store: OptionsStore
    @EnvironmentObject private var tools: ToolLocator
    @EnvironmentObject private var downloads: DownloadManager

    @AppStorage("importAction") private var action: ImportAction = .remuxMP4
    @AppStorage("importAudioFormat") private var audioFormat: ImportAudioFormat = .original
    @AppStorage("importToDownloadFolder") private var toDownloadFolder = false

    @State private var files: [String] = []
    @State private var targeted = false
    @State private var rejected: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ribbonDiagonal)

            Group {
                if files.isEmpty {
                    Text(rejected ?? "Import a local file — drop a video or audio file here")
                        .foregroundStyle(rejected == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                } else {
                    Text(files.count == 1 ? (files[0] as NSString).lastPathComponent : "\(files.count) files")
                        .foregroundStyle(.primary)
                        .help(files.joined(separator: "\n"))
                }
            }
            .font(.system(size: 13))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: choose)

            if !files.isEmpty {
                Button { files = []; rejected = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(diameter: 20))
                    .help("Clear")
            }
            Button(action: choose) { Image(systemName: "folder") }
                .buttonStyle(IconButtonStyle(diameter: 24))
                .help("Choose files…")

            Picker("Action", selection: $action) {
                ForEach(ImportAction.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("What to do with the file")

            if action == .extractAudio {
                Picker("Audio format", selection: $audioFormat) {
                    ForEach(ImportAudioFormat.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Original copies the audio track without re-encoding")
            }

            Menu {
                Picker("Save to", selection: $toDownloadFolder) {
                    Text("Next to the original").tag(false)
                    Text("Download folder").tag(true)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: toDownloadFolder ? "arrow.down.circle" : "folder.badge.plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(toDownloadFolder ? "Saving to the download folder" : "Saving next to the original file")

            Button(action: start) {
                HStack(spacing: 5) {
                    Image(systemName: action == .extractAudio ? "waveform" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .bold))
                    Text(files.count > 1 ? "Convert \(files.count)" : "Convert")
                }
            }
            .buttonStyle(IconPillStyle())
            .disabled(files.isEmpty || tools.ffmpegPath == nil)
            .help(tools.ffmpegPath == nil ? "FFmpeg is needed to import files" : "Add to queue")
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .frame(minHeight: 32)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(targeted ? Theme.hoverFill : Theme.fieldFill))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(targeted ? AnyShapeStyle(Theme.ribbonDiagonal) : AnyShapeStyle(Theme.hairline), lineWidth: targeted ? 1.5 : 1))
        .dropDestination(for: URL.self) { urls, _ in
            add(urls.filter(\.isFileURL).map(\.path))
            return true
        } isTargeted: { targeted = $0 }
    }

    private func add(_ paths: [String]) {
        let ok = paths.filter(MediaImport.isImportable)
        rejected = ok.isEmpty && !paths.isEmpty ? "That isn't a video or audio file Jethriki can import." : nil
        guard !ok.isEmpty else { return }
        let wasEmpty = files.isEmpty
        for p in ok where !files.contains(p) { files.append(p) }
        // First file in sets a sensible default: MKV → MP4, MP4 → MKV, audio → extract.
        if wasEmpty, let first = ok.first { action = ImportAction.suggested(for: first) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose video or audio files to extract audio from or remux"
        panel.allowedContentTypes = MediaImport.importableExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        add(panel.urls.map(\.path))
    }

    private func start() {
        guard !files.isEmpty, let snapshot = tools.snapshot() else { return }
        downloads.enqueueImports(files: files,
                                 request: ImportRequest(action: action, audioFormat: audioFormat),
                                 options: store.options, tools: snapshot,
                                 outputDirectory: toDownloadFolder ? store.options.outputDirectory : nil)
        files = []
        rejected = nil
    }
}

/// A compact accent pill for the Import field's Convert button — smaller than the Download glow button.
private struct IconPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PillBody(configuration: configuration) }

    private struct PillBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Capsule().fill(Theme.ribbonDiagonal))
                .overlay(Capsule().strokeBorder(.white.opacity(hovering ? 0.35 : 0.2), lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .saturation(isEnabled ? 1 : 0.3)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}
