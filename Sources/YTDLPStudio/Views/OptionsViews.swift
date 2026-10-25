import SwiftUI
import AppKit

// MARK: - Shared helpers

struct EnumPicker<T: OptionEnum>: View {
    let title: String
    @Binding var selection: T
    var cases: [T] = Array(T.allCases)

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(cases) { Text($0.label).tag($0) }
        }
    }
}

struct Hint: View {
    let text: String
    var systemImage: String = "info.circle"
    var tint: Color = .secondary
    init(_ text: String, systemImage: String = "info.circle", tint: Color = .secondary) {
        self.text = text; self.systemImage = systemImage; self.tint = tint
    }
    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct Warning: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Hint(text, systemImage: "exclamationmark.triangle.fill", tint: .orange) }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let format: (Double) -> String

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range, step: step)
            Text(format(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
        }
    }
}

// MARK: - Format & quality

struct FormatOptionsView: View {
    @Binding var o: DownloadOptions

    var body: some View {
        Form {
            if o.mode == .audio {
                Section {
                    Hint("Audio Only mode is on. Choose the output format and bitrate on the Audio page.")
                }
            } else {
                Section("Container & quality") {
                    EnumPicker(title: "Container", selection: $o.container)
                    EnumPicker(title: "Maximum resolution", selection: $o.maxResolution)
                    EnumPicker(title: "Frame rate", selection: $o.fpsLimit)
                }
                Section("Codec preference") {
                    EnumPicker(title: "Video codec", selection: $o.videoCodec)
                    if o.mode == .video {
                        EnumPicker(title: "Audio codec", selection: $o.audioCodec)
                    }
                    Toggle("Prefer streams that fit the container without conversion", isOn: $o.preferCompatibleStreams)
                    Toggle("Prefer free formats (VP9/Opus) when quality is equal", isOn: $o.preferFreeFormats)
                    Toggle("Always output the chosen container (remux if needed)", isOn: $o.forceRemux)
                    if o.forceRemux && [.webm, .mov, .avi, .flv].contains(o.container) {
                        Hint("If the downloaded codecs can't go in \(o.container.rawValue.uppercased()) without re-encoding, the closest compatible container is used instead. Turn on FFmpeg Encode to force it.")
                    }
                    if o.mode == .videoOnly {
                        Hint("Sites without a separate video stream fall back to the combined stream, which includes audio.")
                    }
                    Hint("Preferences are soft: if a site doesn't offer a match, the closest available stream is used instead of failing.")
                }
            }
            Section("Exact format selection") {
                TextField("Format (-f)", text: $o.customFormat, prompt: Text("e.g. 137+140 or bv*[height<=720]+ba"))
                    .font(.system(.body, design: .monospaced))
                TextField("Sort order (-S)", text: $o.customSort, prompt: Text("e.g. res:1080,fps,+size"))
                    .font(.system(.body, design: .monospaced))
                Hint("Leave blank to use the settings above. Analyze a link to pick format IDs from a table.")
                if !o.customFormat.isEmpty || !o.customSort.isEmpty {
                    Button("Clear custom selection") { o.customFormat = ""; o.customSort = "" }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Audio

struct AudioOptionsView: View {
    @Binding var o: DownloadOptions

    var body: some View {
        Form {
            Section("Audio extraction") {
                EnumPicker(title: "Format", selection: $o.audioFormat)
                EnumPicker(title: "Quality", selection: $o.audioQuality)
                    .disabled(o.audioFormat.isLossless)
                if o.audioFormat.isRingtone || o.audioFormat.isAndroidRingtone {
                    EnumPicker(title: "Tone type", selection: $o.toneKind)
                    Hint("Notification sounds start instantly (leading silence removed), are at most \(Ringtone.notificationMaxSeconds) seconds and fade out quickly.")
                }
                if o.audioFormat.isAndroidRingtone {
                    Toggle("Send to Android when done", isOn: $o.autoSendToAndroid)
                    Hint("Copies each finished tone to the connected phone (USB first, then Wi-Fi debugging): notification sounds to Notifications, ringtones to Ringtones. It's added to the sound list; the default sound isn't changed. Needs adb: brew install android-platform-tools.")
                }
                if o.mode != .audio {
                    Hint("These apply in Audio Only mode. Switch modes at the top of the window.")
                } else if o.audioFormat.isLossless {
                    Hint("Lossless formats don't use a bitrate. Note that converting a lossy source to FLAC doesn't add quality.")
                } else if o.audioFormat.isRingtone {
                    Hint("Saves an .m4r ringtone ready for iTunes, Apple Devices or Finder: AAC, up to \(Ringtone.maxSeconds) seconds, with a short fade in and out. Use Trim to choose which part of the song plays.")
                } else if o.audioFormat.isAndroidRingtone {
                    Hint("Saves an Ogg Vorbis ringtone, the format Android's own tones use: up to \(Ringtone.androidMaxSeconds) seconds, with a short fade in and out. Copy it to the phone's Ringtones folder, or open it on the phone and choose it in Settings › Sound.")
                }
            }
            Section("FFmpeg audio filters") {
                Toggle("Normalize loudness (EBU R128, −16 LUFS)", isOn: $o.normalizeAudio)
                LabeledSlider(title: "Volume", value: $o.volumeDB, range: -20...20, step: 0.5) {
                    $0 == 0 ? "0 dB" : String(format: "%+.1f dB", $0)
                }
                EnumPicker(title: "Sample rate", selection: $o.sampleRate)
                EnumPicker(title: "Channels", selection: $o.channels)
                if o.audioFiltersActive {
                    if o.mode == .audio && o.audioFormat == .best {
                        Warning("Filters need a specific output format. Choose MP3, M4A, Opus, FLAC, etc. instead of Best.")
                    } else if o.mode != .audio && !o.encodeEnabled {
                        Warning("In video modes, filters are applied during FFmpeg re-encode. Turn it on in FFmpeg Encode.")
                    }
                }
                if o.audioFiltersActive || o.volumeDB != 0 {
                    Button("Reset filters") {
                        o.normalizeAudio = false; o.volumeDB = 0; o.sampleRate = .keep; o.channels = .keep
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - FFmpeg encode

struct EncodeOptionsView: View {
    @Binding var o: DownloadOptions

    var body: some View {
        Form {
            Section {
                Toggle("Re-encode video with FFmpeg after downloading", isOn: $o.encodeEnabled)
                    .disabled(o.mode == .audio)
                Hint(o.mode == .audio
                     ? "Not available in Audio Only mode; use the audio filters instead."
                     : "Runs a separate FFmpeg pass on each downloaded video. Use it to shrink files, change codec, or downscale. Chapter-split files are left as downloaded.")
            }

            if o.encodeEnabled && o.mode != .audio {
                Section("Video") {
                    EnumPicker(title: "Encoder", selection: $o.encoder)
                    if o.encoder.usesCRF {
                        LabeledSlider(title: "Quality (CRF)", value: $o.crf, range: 0...o.encoder.maxCRF) { "\(Int($0))" }
                        Hint("Lower is better quality and bigger files. Default for this encoder: \(Int(o.encoder.defaultCRF)).")
                    }
                    if o.encoder.usesBitrate {
                        LabeledSlider(title: "Bitrate", value: $o.hwBitrateMbps, range: 0.5...50, step: 0.5) {
                            String(format: "%.1f Mbps", $0)
                        }
                        Hint("Apple Silicon/Intel media engine. Rough guide: 720p ≈ 2.5, 1080p ≈ 6, 4K ≈ 20 Mbps.")
                    }
                    if o.encoder.supportsPreset {
                        EnumPicker(title: "Speed preset", selection: $o.preset)
                    }
                    EnumPicker(title: "Resize", selection: $o.scale)
                    if !o.encoder.compatibleContainers.contains(o.container) {
                        Warning("\(o.encoder.label) can't go in \(o.container.rawValue.uppercased()). Pick \(o.encoder.compatibleContainers.map { $0.rawValue.uppercased() }.joined(separator: ", ")) on the Format page.")
                    }
                }
                Section("Audio") {
                    Toggle("Re-encode audio", isOn: $o.encodeAudio)
                    EnumPicker(title: "Audio bitrate", selection: $o.encodeAudioBitrate)
                        .disabled(!o.encodeAudio && !o.audioFiltersActive)
                    if o.audioFiltersActive {
                        Hint("Audio filters from the Audio page will be applied (forces audio re-encode).")
                    }
                }
                Section("Files") {
                    Toggle("Replace the original (moves it to the Trash)", isOn: $o.replaceOriginal)
                    Hint(o.replaceOriginal ? "The encoded file takes the original's name." : "The encoded copy is saved next to the original as “name.encoded.\(o.container.rawValue)”.")
                }
            }

            Section("Raw postprocessor arguments") {
                TextField("--postprocessor-args", text: $o.customPPA, prompt: Text("e.g. Merger+ffmpeg_o:-metadata comment=archived"))
                    .font(.system(.body, design: .monospaced))
                Hint("Passed straight to yt-dlp's FFmpeg postprocessors. Format: NAME[+EXE][_i|_o]:ARGS.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: o.encoder) { newValue in
            o.crf = newValue.defaultCRF
        }
    }
}

// MARK: - Chapters & SponsorBlock

struct ChaptersOptionsView: View {
    @Binding var o: DownloadOptions
    var onFindComments: () -> Void = {}
    var onCancelSearch: () -> Void = {}
    var canSearchComments = false
    var searchingComments = false
    var selectedCommentSummary: String?

    private func binding(for c: SponsorCategory) -> Binding<Bool> {
        Binding(
            get: { o.sponsorCategories.contains(c) },
            set: { on in
                if on { if !o.sponsorCategories.contains(c) { o.sponsorCategories.append(c) } }
                else { o.sponsorCategories.removeAll { $0 == c } }
            })
    }

    var body: some View {
        Form {
            Section("Chapters") {
                Picker("Chapter source", selection: $o.chapterSource) {
                    ForEach(ChapterSource.allCases) { Text($0.label).tag($0) }
                }
                if o.chapterSource != .youtube {
                    HStack {
                        Button("Find chapters in comments", action: onFindComments)
                            .disabled(!canSearchComments || searchingComments)
                        if searchingComments {
                            ProgressView().controlSize(.small)
                            Button("Cancel", action: onCancelSearch)
                        }
                    }
                    if let selectedCommentSummary { Text(selectedCommentSummary).font(.callout) }
                    Hint("Searches the first pasted video’s top 200 comments. Preview a list to choose it, or let each queued video use the list with the most chapters. Lists need at least three increasing timestamps with titles.")
                    if o.chapterSource == .commentsIfMissing {
                        Hint("Existing YouTube chapters take priority. If no comment list is found, the video downloads without chapters.")
                    } else {
                        Hint("If no valid comment list is found, the download stops so you can choose another source.")
                    }
                }
                Toggle("Embed chapter markers in the file", isOn: $o.embedChapters)
                Toggle("Split into one file per chapter", isOn: $o.splitChapters)
                Toggle("Put chapter files in a folder named after the video", isOn: $o.chaptersInFolder)
                    .disabled(!o.splitChapters)
                TextField("Remove chapters matching", text: $o.removeChaptersRegex, prompt: Text("Regex, e.g. (?i)intro|outro|credits"))
                    .font(.system(.body, design: .monospaced))
                Hint("Splitting is great for albums and long mixes uploaded as a single video. The full file is kept too.")
            }
            Section("SponsorBlock") {
                Picker("Segments", selection: $o.sponsorBlockMode) {
                    ForEach(SponsorBlockMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if o.sponsorBlockMode != .off {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                        ForEach(SponsorCategory.allCases) { c in
                            Toggle(c.label, isOn: binding(for: c))
                                .disabled(o.sponsorBlockMode == .remove && !c.removable)
                        }
                    }
                    Hint(o.sponsorBlockMode == .remove
                         ? "Selected segments are cut out with FFmpeg. Segment data comes from the community-run SponsorBlock database (YouTube only)."
                         : "Selected segments are added as named chapters so you can skip them in your player.")
                }
                if o.cutsVideoSegments {
                    Toggle("Cut precisely (prevents repeated or frozen video at cuts)", isOn: $o.preciseCuts)
                    if o.preciseCuts {
                        Hint("The video is re-encoded once so every cut lands on an exact frame. This takes extra time, roughly the length of the video at 1080p.")
                    } else {
                        Warning("Without precise cuts the video can jump back and replay several seconds, or freeze, at each cut while the audio carries on.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Subtitles

struct SubtitleOptionsView: View {
    @Binding var o: DownloadOptions

    var body: some View {
        Form {
            Section("Download") {
                Toggle("Download subtitles", isOn: $o.writeSubs)
                Toggle("Download auto-generated captions", isOn: $o.writeAutoSubs)
                TextField("Languages", text: $o.subLangs, prompt: Text("en.*,es"))
                    .font(.system(.body, design: .monospaced))
                Hint("Comma-separated, regex allowed. Examples: en.* · en,de,ja · all,-live_chat")
                EnumPicker(title: "Convert to", selection: $o.subFormat)
            }
            Section("Embed") {
                Toggle("Embed subtitles in the video", isOn: $o.embedSubs)
                    .disabled(o.mode == .audio)
                if o.embedSubs && !o.container.supportsSubtitleEmbed {
                    Warning("Subtitles can only be embedded in MP4, MKV or WebM.")
                }
                Hint("Embedding downloads the subtitles automatically. Sidecar files are removed afterwards unless “Download subtitles” is also on.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Metadata & thumbnails

struct MetadataOptionsView: View {
    @Binding var o: DownloadOptions

    var body: some View {
        Form {
            Section("Embed in file") {
                Toggle("Embed metadata (title, artist, date, description)", isOn: $o.embedMetadata)
                Toggle("Embed thumbnail as cover art", isOn: $o.embedThumbnail)
                if o.embedThumbnail && !o.thumbnailEmbeddable {
                    Warning("Cover art can't be embedded in this format, so it will be skipped.")
                }
            }
            Section("Music tags") {
                Toggle("Fix tags for music players", isOn: $o.musicTags)
                    .disabled(!o.embedMetadata)
                Group {
                    Toggle("Clean up titles (removes \u{201C}Official Video\u{201D}, \u{201C}Lyrics\u{201D}, \u{201C}[4K]\u{201D}\u{2026})", isOn: $o.cleanTitles)
                    Toggle("Remove track numbers from song titles (\u{201C}01. Song\u{201D} \u{2192} \u{201C}Song\u{201D})", isOn: $o.stripTitleNumbers)
                    Toggle("Split \u{201C}Artist - Song\u{201D} titles into artist and song", isOn: $o.splitArtistTitle)
                    Toggle("Number tracks by playlist position (e.g. 3 of 14)", isOn: $o.trackNumbers)
                    Toggle("Fill in the album from the playlist name", isOn: $o.albumFallback)
                    Toggle("Square cover art (crop the video thumbnail)", isOn: $o.squareCover)
                        .disabled(o.mode != .audio)
                    Toggle("Name and number each track when splitting chapters", isOn: $o.tagChapterTracks)
                        .disabled(!o.splitChapters || o.mode != .audio)
                    TextField("Genre", text: $o.genre, prompt: Text("Optional, e.g. Electronic"))
                    Toggle("Also apply to video downloads", isOn: $o.musicTagsOnVideo)
                        .disabled(o.mode == .audio)
                }
                .disabled(!o.embedMetadata || !o.musicTags)
                if !o.embedMetadata {
                    Hint("Turn on \u{201C}Embed metadata\u{201D} above to use music tags.")
                } else if o.musicTags && o.mode != .audio && !o.musicTagsOnVideo {
                    Hint("Music tags apply to Audio Only downloads unless \u{201C}Also apply to video downloads\u{201D} is on.")
                } else if o.musicTags {
                    Hint("Sets title, artist, album, album artist, year and track number so Apple Music, iTunes and other players sort your files properly. Official artist and album details from YouTube Music are kept. For matching file names, pick \u{201C}Artist - Song\u{201D} or \u{201C}Music library\u{201D} on the Output page. Singles use the song title as the album.")
                }
            }
            Section("Save alongside") {
                Toggle("Save thumbnail image", isOn: $o.writeThumbnail)
                EnumPicker(title: "Thumbnail format", selection: $o.thumbnailFormat)
                    .disabled(!o.writeThumbnail && !o.embedThumbnail)
                Toggle("Save description (.description)", isOn: $o.writeDescription)
                Toggle("Save full metadata (.info.json)", isOn: $o.writeInfoJSON)
                Toggle("Include comments in .info.json", isOn: $o.writeComments)
                if o.writeComments { Hint("Fetching comments can take a long time on popular videos.") }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Trim

struct TrimOptionsView: View {
    @Binding var o: DownloadOptions

    var body: some View {
        Form {
            Section {
                Toggle("Download only part of the video", isOn: $o.trimEnabled)
            }
            Section("Range") {
                TextField("Start", text: $o.trimStart, prompt: Text("00:01:30"))
                    .font(.system(.body, design: .monospaced))
                TextField("End", text: $o.trimEnd, prompt: Text("Leave blank for the end"))
                    .font(.system(.body, design: .monospaced))
                Toggle("Cut precisely (re-encodes around the cut points)", isOn: $o.forceKeyframes)
                Hint("Times can be seconds (90) or timestamps (1:30, 01:02:03.5). Without precise cutting, the clip starts at the nearest keyframe.")
            }
            .disabled(!o.trimEnabled)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Playlist

struct PlaylistOptionsView: View {
    @Binding var o: DownloadOptions

    var body: some View {
        Form {
            Section("When a link is part of a playlist") {
                Picker("Download", selection: $o.playlistMode) {
                    ForEach(PlaylistMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                TextField("Items", text: $o.playlistItems, prompt: Text("All — or e.g. 1-5,8,10:20, -3::"))
                    .font(.system(.body, design: .monospaced))
                Hint("Ranges are 1-based. “-3::” means the last three items; “::2” means every other item.")
            }
            Section("Skip what you already have") {
                Toggle("Keep a download archive", isOn: $o.useArchive)
                if o.useArchive {
                    Text(o.archivePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Hint("Each finished video's ID is recorded, and later runs skip it. Ideal for syncing channels or playlists.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Network & login

struct NetworkOptionsView: View {
    @Binding var o: DownloadOptions

    var body: some View {
        Form {
            Section("Speed") {
                TextField("Rate limit", text: $o.rateLimit, prompt: Text("Unlimited — or e.g. 5M, 800K"))
                Stepper("Parallel fragments: \(o.concurrentFragments)", value: $o.concurrentFragments, in: 1...16)
                Hint("More fragments speeds up HLS/DASH streams (YouTube, Twitch, etc.).")
            }
            Section("Reliability") {
                Stepper("Retries: \(o.retries)", value: $o.retries, in: 0...50)
                Stepper("Wait between downloads: \(o.sleepInterval)s", value: $o.sleepInterval, in: 0...120, step: 5)
                Hint("A short wait helps avoid rate-limiting on large playlists.")
            }
            Section("Login & privacy") {
                EnumPicker(title: "Use cookies from", selection: $o.cookieBrowser)
                Hint("Lets yt-dlp see members-only, age-restricted or private videos you can already watch. Safari requires Full Disk Access for this app in System Settings › Privacy & Security.")
                TextField("Proxy", text: $o.proxy, prompt: Text("e.g. socks5://127.0.0.1:1080"))
                    .font(.system(.body, design: .monospaced))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Output

struct OutputOptionsView: View {
    @Binding var o: DownloadOptions

    var body: some View {
        Form {
            Section("Save to") {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                    Text((o.outputDirectory as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: o.outputDirectory))
                    } label: { Image(systemName: "arrow.up.forward.app") }
                    .help("Open in Finder")
                }
            }
            Section("File names") {
                EnumPicker(title: "Name files as", selection: $o.filenameTemplate)
                if o.filenameTemplate == .custom {
                    TextField("Template", text: $o.customTemplate)
                        .font(.system(.body, design: .monospaced))
                    Hint("Fields: %(title)s %(id)s %(uploader)s %(upload_date)s %(playlist_index)s %(ext)s — use / for subfolders.")
                } else {
                    Text(o.filenameTemplate.template)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Toggle("Use only safe ASCII characters in names", isOn: $o.restrictFilenames)
            }
            Section("Behavior") {
                Toggle("Never overwrite existing files", isOn: $o.noOverwrites)
                Toggle("Set file date to download time (not upload time)", isOn: $o.noMtime)
                Toggle("Keep intermediate files (separate video/audio streams)", isOn: $o.keepIntermediateFiles)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: o.outputDirectory)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            o.outputDirectory = url.path
        }
    }
}

// MARK: - Advanced

struct AdvancedOptionsView: View {
    @Binding var o: DownloadOptions

    var body: some View {
        Form {
            Section("Extra yt-dlp arguments") {
                TextEditor(text: $o.extraArgs)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                Hint("Appended to every command. Quotes work like in a shell, e.g. --match-filter \"duration < 600\" --geo-bypass")
            }
            Section("Handy flags") {
                ForEach(Self.snippets) { snippet in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snippet.flag).font(.system(.body, design: .monospaced))
                            Text(snippet.description).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add") {
                            o.extraArgs = (o.extraArgs.trimmed + " " + snippet.flag).trimmed
                        }
                        .controlSize(.small)
                        .disabled(o.extraArgs.contains(snippet.flag))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    struct Snippet: Identifiable {
        let flag: String
        let description: String
        var id: String { flag }
    }

    static let snippets: [Snippet] = [
        Snippet(flag: "--match-filter \"!is_live\"", description: "Skip live streams"),
        Snippet(flag: "--match-filter \"duration < 3600\"", description: "Only videos shorter than an hour"),
        Snippet(flag: "--dateafter now-7days", description: "Only videos uploaded in the last week"),
        Snippet(flag: "--live-from-start", description: "Record live streams from the beginning"),
        Snippet(flag: "--geo-bypass", description: "Try to bypass geographic restrictions"),
        Snippet(flag: "--xattrs", description: "Write metadata to Finder extended attributes"),
        Snippet(flag: "--write-link", description: "Save a .webloc shortcut to the source page"),
        Snippet(flag: "--abort-on-error", description: "Stop the whole playlist on the first error")
    ]
}
