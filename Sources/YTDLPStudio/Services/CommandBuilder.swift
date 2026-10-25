import Foundation

enum CommandBuilder {
    static let progressPrefix = "[[PROG]]"

    // MARK: - yt-dlp

    /// Builds the yt-dlp argument list.
    /// - Parameter includeInternals: include the plumbing the app needs (progress template, ffmpeg path,
    ///   output-path capture). Off for the copyable preview.
    static func arguments(for o: DownloadOptions,
                          urls: [String],
                          ffmpegLocation: String? = nil,
                          pathsFile: String? = nil,
                          chaptersFile: String? = nil,
                          tempDirectory: String? = nil,
                          includeInternals: Bool = true,
                          infoFile: String? = nil) -> [String] {
        var a: [String] = []

        if includeInternals {
            a += ["--newline", "--no-colors", "--progress", "--progress-template",
                  "download:\(progressPrefix)%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress._total_bytes_str)s|%(progress._total_bytes_estimate_str)s|%(info.title)s"]
            if let ff = ffmpegLocation { a += ["--ffmpeg-location", ff] }
            if let pf = pathsFile { a += ["--print-to-file", "after_move:filepath", pf] }
            // Chapter titles + split file paths, so the app can tag each split track itself.
            if let cf = chaptersFile { a += ["--print-to-file", "after_move:%(chapters)j", cf] }
            // Private scratch space per job, so two jobs that resolve to the same file name
            // can't overwrite each other's .part / .temp files mid-download.
            if let tmp = tempDirectory { a += ["-P", "temp:\(tmp)"] }
        }

        // Format selection
        let custom = o.customFormat.trimmed
        switch o.mode {
        case .audio:
            a += ["-f", custom.isEmpty ? "ba/b" : custom]
            if let s = sortString(o) { a += ["-S", s] }
            a += ["-x", "--audio-format", o.audioFormat.ytdlpFormat]
            if !o.audioFormat.isLossless { a += ["--audio-quality", o.audioQuality.arg] }
            let af = audioFilterArgs(o)
            if o.audioFormat.ringtoneMaxSeconds != nil {
                a += ["--postprocessor-args", "ExtractAudio+ffmpeg_o:" + ringtoneArgs(o).joined(separator: " ")]
            } else if !af.isEmpty && o.audioFormat != .best {
                a += ["--postprocessor-args", "ExtractAudio+ffmpeg_o:" + af.joined(separator: " ")]
            }
        case .video, .videoOnly:
            // Video-only falls back to the combined stream on sites that don't offer a separate video track.
            let fallback = o.mode == .video ? "bv*+ba/b" : "bv/bv*"
            a += ["-f", custom.isEmpty ? fallback : custom]
            if let s = sortString(o) { a += ["-S", s] }
            if o.mode == .video { a += ["--merge-output-format", o.container.rawValue] }
            if o.forceRemux { a += ["--remux-video", o.container.remuxRule] }
            if o.preferFreeFormats { a.append("--prefer-free-formats") }
        }
        if o.keepIntermediateFiles { a.append("-k") }
        if !o.customPPA.trimmed.isEmpty { a += ["--postprocessor-args", o.customPPA.trimmed] }

        // Trim / sections
        if o.trimEnabled {
            let start = o.trimStart.trimmed.isEmpty ? "0" : o.trimStart.trimmed
            let end = o.trimEnd.trimmed.isEmpty ? "inf" : o.trimEnd.trimmed
            a += ["--download-sections", "*\(start)-\(end)"]
        }
        if o.forcesKeyframes { a.append("--force-keyframes-at-cuts") }

        // Chapters
        if o.embedChapters { a.append("--embed-chapters") }
        if o.splitChapters {
            a.append("--split-chapters")
            // Ogg (Opus/Vorbis) can't hold a picture stream, so splitting a file that already has
            // embedded cover art fails. Drop the picture while splitting; the app re-adds it per track.
            let oggLike: Set<AudioFormat> = [.opus, .vorbis, .android, .best]
            if o.mode == .audio && o.embedThumbnail && oggLike.contains(o.audioFormat) {
                a += ["--postprocessor-args", "SplitChapters+ffmpeg_o:-map -0:v?"]
            }
        }
        if !o.removeChaptersRegex.trimmed.isEmpty { a += ["--remove-chapters", o.removeChaptersRegex.trimmed] }

        // SponsorBlock
        switch o.sponsorBlockMode {
        case .off: break
        case .mark:
            let cats = o.sponsorCategories.map(\.rawValue)
            if !cats.isEmpty { a += ["--sponsorblock-mark", cats.joined(separator: ",")] }
        case .remove:
            let cats = o.sponsorCategories.filter(\.removable).map(\.rawValue)
            if !cats.isEmpty { a += ["--sponsorblock-remove", cats.joined(separator: ",")] }
        }

        // Subtitles
        if o.writeSubs { a.append("--write-subs") }
        if o.writeAutoSubs { a.append("--write-auto-subs") }
        if o.writeSubs || o.writeAutoSubs || o.embedSubs {
            a += ["--sub-langs", o.subLangs.trimmed.isEmpty ? "en.*" : o.subLangs.trimmed]
            if o.subFormat != .best {
                a += ["--sub-format", "\(o.subFormat.rawValue)/best", "--convert-subs", o.subFormat.rawValue]
            }
        }
        if o.embedSubs && o.mode != .audio { a.append("--embed-subs") }

        // Metadata & thumbnails
        if o.embedMetadata {
            a.append("--embed-metadata")
            if o.musicTagsActive { a += musicTagArgs(o) }
            var metaArgs: [String] = []
            // Ogg keeps tags per stream; stale tags from the source would override the new ones.
            if o.mode == .audio { metaArgs += ["-map_metadata:s:a", "-1"] }
            if o.musicTagsActive && !o.genre.trimmed.isEmpty { metaArgs += ["-metadata", "genre=\(o.genre.trimmed)"] }
            if !metaArgs.isEmpty {
                a += ["--postprocessor-args", "Metadata+ffmpeg_o:" + metaArgs.map(shellQuote).joined(separator: " ")]
            }
        }
        if o.embedThumbnail && o.thumbnailEmbeddable { a.append("--embed-thumbnail") }
        if o.writeThumbnail { a.append("--write-thumbnail") }
        let squareCover = o.musicTagsActive && o.squareCover && o.mode == .audio &&
            ((o.embedThumbnail && o.thumbnailEmbeddable) || o.writeThumbnail)
        if squareCover {
            // Crop the 16:9 video thumbnail to a centred square, like a real album cover.
            // JPEG sources become PNG because yt-dlp skips conversion when the format already matches.
            a += ["--convert-thumbnails", "jpg>png/jpg",
                  "--postprocessor-args", "ThumbnailsConvertor+ffmpeg_o:-q:v 2 -vf crop=\"'min(iw,ih)':'min(iw,ih)'\""]
        } else if o.thumbnailFormat != .original && (o.writeThumbnail || o.embedThumbnail) {
            a += ["--convert-thumbnails", o.thumbnailFormat.rawValue]
        }
        if o.writeDescription { a.append("--write-description") }
        if o.writeInfoJSON { a.append("--write-info-json") }
        if o.writeComments { a.append("--write-comments") }

        // Playlist
        switch o.playlistMode {
        case .auto: break
        case .single: a.append("--no-playlist")
        case .full: a.append("--yes-playlist")
        }
        if !o.playlistItems.trimmed.isEmpty { a += ["-I", o.playlistItems.trimmed] }
        if o.useArchive { a += ["--download-archive", o.archivePath] }

        // Network
        if !o.rateLimit.trimmed.isEmpty { a += ["-r", o.rateLimit.trimmed] }
        if o.concurrentFragments > 1 { a += ["-N", "\(o.concurrentFragments)"] }
        if o.retries != 10 { a += ["-R", "\(o.retries)"] }
        if !o.proxy.trimmed.isEmpty { a += ["--proxy", o.proxy.trimmed] }
        if o.cookieBrowser != .none { a += ["--cookies-from-browser", o.cookieBrowser.rawValue] }
        if o.sleepInterval > 0 { a += ["--sleep-interval", "\(o.sleepInterval)"] }

        // Output
        a += ["-P", o.outputDirectory, "-o", outputTemplate(o)]
        if o.splitChapters && o.chaptersInFolder {
            a += ["-o", "chapter:%(title)s/%(section_number)03d - %(section_title)s.%(ext)s"]
        }
        if o.restrictFilenames { a.append("--restrict-filenames") }
        if o.noOverwrites { a.append("--no-overwrites") }
        if o.noMtime { a.append("--no-mtime") }

        // Anything else the user typed
        a += tokenize(o.extraArgs)

        if let infoFile {
            // Metadata has already been extracted and playlist items already selected.
            if let index = a.firstIndex(of: "-I"), index + 1 < a.count {
                a.removeSubrange(index...index + 1)
            }
            a += ["--no-clean-info-json", "--load-info-json", infoFile]
        } else if !urls.isEmpty { a.append("--"); a += urls }
        return a
    }

    // MARK: - Music tags

    /// Bracketed junk in video titles: "(Official Video)", "[Lyrics]", "(HD)", "(Full Album)"…
    static let junkTitlePattern = #"(?i)\s*[\(\[][^\)\]]*\b(?:official|lyrics?|lyric video|audio|visuali[sz]er|music video|video|hd|hq|4k|remaster(?:ed)?(?: \d{4})?|full album|full ep|album stream)\b[^\)\]]*[\)\]]"#
    /// A leading track number: "01.", "1 -", "03 ", "[04]", "(5)", "#6 -", "Track 7 -", "8)", "09:".
    /// Deliberately strict so real titles that start with a number survive ("7 Rings",
    /// "99 Luftballons", "4:44", "1-800-273-8255", "2 Become 1", "1999"). No anchors or flags,
    /// so it can be embedded in larger patterns.
    static let leadingTrackNumber = #"(?:(?:track|no\.?)\s*)?(?:#?\d{1,3}\s*[.:)\-–—](?!\d)\s*|[\[(]\d{1,3}[\])]\s*|0\d\s+)"#
    /// Captures the title without its leading track number into the named group.
    static func numberStrippingPattern(into group: String) -> String {
        #"(?i)^\s*(?:"# + leadingTrackNumber + #")?(?P<"# + group + #">.+?)\s*$"#
    }
    /// "Artist - Song" (hyphen, en dash or em dash).
    static let artistTitlePattern = #"^(.+?)\s+[-–—]\s+(.+)$"#

    /// yt-dlp metadata rules, applied in order. Parsed values go into meta_* fields so tags
    /// change but file names only change when a template asks for them. Each rule's pattern
    /// requires at least one character, so a missing source field leaves the tag alone.
    static func musicTagArgs(_ o: DownloadOptions) -> [String] {
        var a: [String] = []
        if o.cleanTitles {
            a += ["--replace-in-metadata", "title,track", junkTitlePattern, ""]
            a += ["--replace-in-metadata", "uploader,channel", #"(?i)\s*(?:-\s*topic|vevo|official)$"#, ""]
        }
        // Strip track numbers before splitting, or "01 - Song" would make the artist "01".
        // studio_title is a scratch field: it isn't meta_*, so it is never written into the file.
        var splitSource = "title"
        if o.stripTitleNumbers {
            a += ["--parse-metadata", "title:" + numberStrippingPattern(into: "studio_title")]
            splitSource = "studio_title"
        }
        if o.splitArtistTitle {
            a += ["--parse-metadata", splitSource + #":^(?P<meta_artist>.+?)\s+[-–—]\s+(?P<meta_title>.+)$"#]
        }
        if o.stripTitleNumbers {
            // Catches numbers after the artist ("Artist - 03. Song") and in YouTube Music's own track field.
            a += ["--parse-metadata", "%(meta_title,track,studio_title|)s:" + numberStrippingPattern(into: "meta_title")]
        }
        if o.trackNumbers {
            a += ["--parse-metadata", #"%(track_number,playlist_index|)s/%(n_entries|)s:^(?P<meta_track>\d+(?:/\d+)?)"#]
        }
        if o.albumFallback {
            a += ["--parse-metadata", #"%(album,playlist_title,meta_title,track,title|)s:^(?P<meta_album>.+)$"#]
        }
        a += ["--parse-metadata", #"%(album_artist,meta_artist,artist,uploader|)s:^(?P<meta_album_artist>.+)$"#]
        a += ["--parse-metadata", #"%(release_year,upload_date|)s:^(?P<meta_date>\d{4})"#]
        return a
    }

    static func outputTemplate(_ o: DownloadOptions) -> String {
        if o.filenameTemplate == .custom {
            return o.customTemplate.trimmed.isEmpty ? "%(title)s.%(ext)s" : o.customTemplate.trimmed
        }
        return o.filenameTemplate.template
    }

    static func sortString(_ o: DownloadOptions) -> String? {
        if !o.customSort.trimmed.isEmpty { return o.customSort.trimmed }
        var t: [String] = []
        if o.mode == .audio {
            if let s = o.audioFormat.preferredSourceSort { t.append(s) }
        } else {
            if let h = o.maxResolution.height { t.append("res:\(h)") }
            if let f = o.fpsLimit.sortToken { t.append(f) }
            if let v = o.videoCodec.sortToken { t.append(v) }
            if o.mode == .video, let ac = o.audioCodec.sortToken { t.append(ac) }
            if o.preferCompatibleStreams, let e = o.container.extSort { t.append(e) }
        }
        return t.isEmpty ? nil : t.joined(separator: ",")
    }

    static func audioFilters(_ o: DownloadOptions) -> [String] {
        var filters: [String] = []
        if o.volumeDB != 0 { filters.append("volume=\(String(format: "%.1f", o.volumeDB))dB") }
        if o.normalizeAudio { filters.append("loudnorm=I=-16:TP=-1.5:LRA=11") }
        return filters
    }

    /// FFmpeg output options that turn the extracted audio into a ringtone iOS accepts:
    /// AAC re-encoded (so the filters run even when the source is already AAC, where yt-dlp
    /// would otherwise stream-copy), capped at 40 s, short fade-in, fade-out at the real end,
    /// 44.1 kHz stereo unless the user picked otherwise. The user's volume/loudness filters still apply.
    static func ringtoneArgs(_ o: DownloadOptions) -> [String] {
        let kbps = o.audioQuality.arg.hasSuffix("K") ? o.audioQuality.arg.lowercased() : nil
        var rate = o.sampleRate.value ?? 44100
        let codec: [String]
        switch o.audioFormat.isAndroidRingtone ? androidEncoder : nil {
        case "libvorbis"?:
            // Android tones are Ogg Vorbis; VBR quality 6 is about 192 kbps.
            codec = ["-c:a", "libvorbis"] + (kbps.map { ["-b:a", $0] } ?? ["-q:a", "6"])
        case "libopus"?:
            // Homebrew's FFmpeg has no libvorbis. Opus in Ogg plays as a tone on Android 5 and later;
            // it only runs at 48 kHz (or lower fixed rates).
            codec = ["-c:a", "libopus", "-b:a", kbps ?? "160k"]
            rate = 48000
        case let other?:
            // FFmpeg's own Vorbis encoder: always present, marked experimental.
            codec = ["-c:a", other, "-strict", "experimental"] + (kbps.map { ["-b:a", $0] } ?? ["-q:a", "6"])
        case nil:
            codec = ["-c:a", "aac", "-b:a", kbps ?? Ringtone.defaultBitrate]
        }
        let chain: [String]
        if o.toneKind == .notification {
            // A notification sound must start instantly: drop leading silence, cap at 10 s, tiny click-free
            // fade in, and a quick fade out at the real end.
            chain = ["silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.05",
                     "atrim=end=\(Ringtone.notificationMaxSeconds)", "asetpts=PTS-STARTPTS"] + audioFilters(o) + [
                "afade=t=in:d=0.02",
                "areverse", "afade=t=in:d=0.4", "areverse"
            ]
        } else {
            let cap = o.audioFormat.ringtoneMaxSeconds ?? Ringtone.maxSeconds
            // Fading the reversed clip in fades the real clip out, whatever length the cut ended up.
            chain = ["atrim=end=\(cap)", "asetpts=PTS-STARTPTS"] + audioFilters(o) + [
                "afade=t=in:d=\(Ringtone.fadeInSeconds)",
                "areverse", "afade=t=in:d=\(Ringtone.fadeOutSeconds)", "areverse"
            ]
        }
        return codec + ["-af", chain.joined(separator: ","),
                "-ar", "\(rate)", "-ac", "\(o.channels.value ?? 2)"]
    }

    /// Audio encoders the installed FFmpeg offers (from `ffmpeg -encoders`); nil until known.
    static var ffmpegEncoders: Set<String>?
    /// The encoder for Android ringtones: libvorbis when FFmpeg has it (or before we know), else libopus,
    /// else FFmpeg's built-in Vorbis encoder.
    static var androidEncoder: String {
        guard let e = ffmpegEncoders, !e.contains("libvorbis") else { return "libvorbis" }
        return e.contains("libopus") ? "libopus" : "vorbis"
    }
    /// Parses the encoder names out of `ffmpeg -hide_banner -encoders`.
    static func parseEncoders(_ output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].count == 6, parts[0] != "------" else { return nil }
            return String(parts[1])
        })
    }

    static func audioFilterArgs(_ o: DownloadOptions) -> [String] {
        let filters = audioFilters(o)
        var args: [String] = []
        if !filters.isEmpty { args += ["-af", filters.joined(separator: ",")] }
        if let sr = o.sampleRate.value { args += ["-ar", "\(sr)"] }
        if let ch = o.channels.value { args += ["-ac", "\(ch)"] }
        return args
    }

    // MARK: - FFmpeg re-encode pass

    static func ffmpegEncodeArguments(input: String, output: String, o: DownloadOptions) -> [String] {
        let c = o.container
        let appleContainer = (c == .mp4 || c == .mov)
        let crf = "\(Int(o.crf.rounded()))"
        let bitrate = String(format: "%.1fM", o.hwBitrateMbps)

        var a = ["-hide_banner", "-nostdin", "-y", "-i", input,
                 "-map", "0:v:0", "-map", "0:a?", "-map", "0:s?",
                 "-map_metadata", "0", "-map_chapters", "0",
                 "-c:v", o.encoder.rawValue]

        switch o.encoder {
        case .x264:
            a += ["-crf", crf, "-preset", o.preset.rawValue, "-pix_fmt", "yuv420p"]
        case .x265:
            a += ["-crf", crf, "-preset", o.preset.rawValue]
            if appleContainer { a += ["-tag:v", "hvc1"] }
        case .vtH264:
            a += ["-b:v", bitrate, "-pix_fmt", "yuv420p"]
        case .vtHEVC:
            a += ["-b:v", bitrate]
            if appleContainer { a += ["-tag:v", "hvc1"] }
        case .vp9:
            a += ["-crf", crf, "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "2"]
        case .av1:
            a += ["-crf", crf, "-preset", "\(o.preset.svtAV1Preset)"]
        case .prores:
            a += ["-profile:v", "3", "-pix_fmt", "yuv422p10le"]
        }

        if let h = o.scale.height {
            a += ["-vf", "scale=-2:'min(\(h),ih)'"]
        }

        let af = audioFilterArgs(o)
        if o.encodeAudio || !af.isEmpty {
            a += ["-c:a", c == .webm ? "libopus" : "aac", "-b:a", o.encodeAudioBitrate.value]
            a += af
        } else {
            a += ["-c:a", "copy"]
        }

        switch c {
        case .mp4, .mov: a += ["-c:s", "mov_text"]
        case .webm: a += ["-c:s", "webvtt"]
        case .mkv: a += ["-c:s", "copy"]
        case .avi, .flv: a += ["-sn"]
        }

        if appleContainer { a += ["-movflags", "+faststart"] }
        a += ["-progress", "pipe:1", "-nostats", output]
        return a
    }

    // MARK: - Display helpers

    static func displayCommand(for o: DownloadOptions, urls: [String]) -> String {
        var args = arguments(for: o, urls: [], includeInternals: false)
        args.append("--")
        let list = urls.isEmpty ? ["<URL>"] : urls
        return "yt-dlp " + args.map(shellQuote).joined(separator: " ") + " " + list.map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ s: String) -> String {
        if s == "<URL>" { return s }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=,+@")
        if !s.isEmpty && s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Minimal POSIX-ish tokenizer for the "extra arguments" box.
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character? = nil
        var escaping = false
        var hasToken = false
        for ch in s {
            if escaping { cur.append(ch); escaping = false; continue }
            if ch == "\\" && quote != "'" { escaping = true; hasToken = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; hasToken = true; continue }
            if ch.isWhitespace {
                if hasToken { out.append(cur); cur = ""; hasToken = false }
                continue
            }
            cur.append(ch)
            hasToken = true
        }
        if hasToken { out.append(cur) }
        return out
    }
}
