import Foundation

/// What to do with a local file dropped on the Import field.
enum ImportAction: String, CaseIterable, Identifiable, Codable {
    case extractAudio, remuxMP4, remuxMKV
    var id: Self { self }
    var label: String {
        switch self {
        case .extractAudio: return "Extract audio"
        case .remuxMP4: return "Remux to MP4"
        case .remuxMKV: return "Remux to MKV"
        }
    }
    var verb: String {
        switch self {
        case .extractAudio: return "Extracting audio"
        case .remuxMP4, .remuxMKV: return "Remuxing"
        }
    }
    /// A sensible first choice for a file: MKV goes to MP4, MP4 (and friends) to MKV, audio-only files have
    /// nothing to remux.
    static func suggested(for path: String) -> ImportAction {
        switch (path as NSString).pathExtension.lowercased() {
        case "mkv", "webm", "avi", "ts", "m2ts", "mts", "flv": return .remuxMP4
        case "mp4", "m4v", "mov": return .remuxMKV
        default: return .extractAudio
        }
    }
}

/// Audio format for "Extract audio". `.original` copies the stream without re-encoding.
enum ImportAudioFormat: String, CaseIterable, Identifiable, Codable {
    case original, mp3, m4a, flac, wav, opus
    var id: Self { self }
    var label: String {
        switch self {
        case .original: return "Original (no re-encode)"
        case .mp3: return "MP3"
        case .m4a: return "M4A (AAC)"
        case .flac: return "FLAC (lossless)"
        case .wav: return "WAV"
        case .opus: return "Opus"
        }
    }
}

struct ImportRequest: Equatable, Codable {
    var action: ImportAction
    var audioFormat: ImportAudioFormat = .original
}

/// One stream as reported by ffprobe.
struct ProbedStream: Equatable {
    let index: Int
    let type: String        // video, audio, subtitle, data, attachment
    let codec: String
    let attachedPicture: Bool
}

struct ProbedMedia: Equatable {
    let streams: [ProbedStream]
    let duration: Double?
}

/// Works out the FFmpeg command for an import. Pure functions, so they're testable without FFmpeg.
enum MediaImport {
    static let importableExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "webm", "avi", "ts", "m2ts", "mts", "flv", "wmv", "mpg", "mpeg", "3gp",
        "m4a", "mp3", "aac", "flac", "wav", "ogg", "opus", "mka", "wma", "ac3", "eac3", "dts", "aiff", "aif"
    ]

    static func isImportable(_ path: String) -> Bool {
        importableExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func probeArguments(input: String) -> [String] {
        ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", input]
    }

    static func parseProbe(_ json: String) throws -> ProbedMedia {
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw SimpleError("FFprobe returned no information about this file.")
        }
        let streams = (obj["streams"] as? [[String: Any]] ?? []).compactMap { s -> ProbedStream? in
            guard let index = s["index"] as? Int else { return nil }
            let disposition = s["disposition"] as? [String: Any]
            return ProbedStream(index: index,
                                type: s["codec_type"] as? String ?? "data",
                                codec: (s["codec_name"] as? String ?? "").lowercased(),
                                attachedPicture: (disposition?["attached_pic"] as? Int ?? 0) == 1)
        }
        let duration = Double((obj["format"] as? [String: Any])?["duration"] as? String ?? "")
        return ProbedMedia(streams: streams, duration: duration)
    }

    /// File extension for an audio stream copied as-is.
    static func copyExtension(forAudioCodec codec: String) -> String {
        switch codec {
        case "aac", "alac": return "m4a"
        case "mp3": return "mp3"
        case "opus": return "opus"
        case "vorbis": return "ogg"
        case "flac": return "flac"
        case "ac3": return "ac3"
        case "eac3": return "eac3"
        case "dts": return "dts"
        case _ where codec.hasPrefix("pcm_"): return "wav"
        default: return "mka"
        }
    }

    // What MP4 can hold without re-encoding. Anything else is either converted (audio, text subtitles) or refused.
    static let mp4VideoCodecs: Set<String> = ["h264", "hevc", "av1", "vp9", "mpeg4", "mpeg2video", "mpeg1video", "mjpeg"]
    static let mp4AudioCodecs: Set<String> = ["aac", "mp3", "alac", "ac3", "eac3", "opus", "flac", "dts", "truehd", "mp2"]
    static let textSubtitleCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"]

    struct Plan: Equatable {
        let output: String
        let arguments: [String]
        /// Things the user should know: streams that were dropped or converted.
        let notes: [String]
    }

    /// Builds the FFmpeg arguments. Never writes over the input or an existing file.
    static func plan(input: String, media: ProbedMedia, request: ImportRequest, outputDirectory: String,
                     fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) throws -> Plan {
        let base = ((input as NSString).lastPathComponent as NSString).deletingPathExtension
        var notes: [String] = []
        var a = ["-hide_banner", "-nostdin", "-n", "-i", input]
        let ext: String

        switch request.action {
        case .extractAudio:
            let audio = media.streams.filter { $0.type == "audio" }
            guard let first = audio.first else { throw SimpleError("This file has no audio track to extract.") }
            if audio.count > 1 { notes.append("Extracted the first of \(audio.count) audio tracks.") }
            a += ["-map", "0:\(first.index)", "-vn", "-sn", "-dn", "-map_metadata", "0"]
            switch request.audioFormat {
            case .original:
                ext = copyExtension(forAudioCodec: first.codec)
                a += ["-c:a", "copy"]
                if ext == "m4a" { a += ["-movflags", "+faststart"] }
            case .mp3: ext = "mp3"; a += ["-c:a", "libmp3lame", "-q:a", "0"]
            case .m4a: ext = "m4a"; a += ["-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart"]
            case .flac: ext = "flac"; a += ["-c:a", "flac"]
            case .wav: ext = "wav"; a += ["-c:a", "pcm_s16le"]
            case .opus: ext = "opus"; a += ["-c:a", "libopus", "-b:a", "160k"]
            }

        case .remuxMP4, .remuxMKV:
            let toMP4 = request.action == .remuxMP4
            ext = toMP4 ? "mp4" : "mkv"
            var maps: [String] = []
            var codecs: [String] = []
            var out = 0
            var droppedPictures = 0, droppedBitmapSubs = 0, droppedOther = 0
            for s in media.streams {
                switch s.type {
                case "video":
                    if s.attachedPicture { droppedPictures += 1; continue }
                    if toMP4 && !mp4VideoCodecs.contains(s.codec) {
                        throw SimpleError("\(s.codec.uppercased()) video can't go into an MP4 without re-encoding. Remux to MKV instead, or download with FFmpeg Encode.")
                    }
                    maps += ["-map", "0:\(s.index)"]
                    if toMP4 && s.codec == "hevc" { codecs += ["-tag:\(out)", "hvc1"] }
                    out += 1
                case "audio":
                    maps += ["-map", "0:\(s.index)"]
                    if toMP4 && !mp4AudioCodecs.contains(s.codec) {
                        codecs += ["-c:\(out)", "aac", "-b:\(out)", "256k"]
                        notes.append("Converted \(s.codec) audio to AAC, which MP4 supports.")
                    }
                    out += 1
                case "subtitle":
                    if toMP4 {
                        guard textSubtitleCodecs.contains(s.codec) else { droppedBitmapSubs += 1; continue }
                        maps += ["-map", "0:\(s.index)"]
                        if s.codec != "mov_text" { codecs += ["-c:\(out)", "mov_text"] }
                    } else {
                        maps += ["-map", "0:\(s.index)"]
                        if s.codec == "mov_text" { codecs += ["-c:\(out)", "srt"] }
                    }
                    out += 1
                default:
                    droppedOther += 1
                }
            }
            guard out > 0 else { throw SimpleError("This file has no audio or video streams to remux.") }
            if droppedPictures > 0 { notes.append("Left out the embedded cover image.") }
            if droppedBitmapSubs > 0 { notes.append("Left out \(droppedBitmapSubs) picture-based subtitle track\(droppedBitmapSubs == 1 ? "" : "s") (MP4 only holds text subtitles).") }
            if droppedOther > 0 && !toMP4 { notes.append("Left out \(droppedOther) data stream\(droppedOther == 1 ? "" : "s").") }
            if droppedOther > 0 && toMP4 { notes.append("Left out \(droppedOther) attachment or data stream\(droppedOther == 1 ? "" : "s") (such as fonts).") }
            a += maps + ["-map_metadata", "0", "-map_chapters", "0", "-c", "copy"] + codecs
            if toMP4 { a += ["-movflags", "+faststart"] }
        }

        let output = uniquePath(directory: outputDirectory, base: base, ext: ext, avoiding: input, fileExists: fileExists)
        a += ["-progress", "pipe:1", "-nostats", output]
        return Plan(output: output, arguments: a, notes: notes)
    }

    /// "name.ext", then "name (2).ext", "name (3).ext"… — skipping the input itself and anything already there.
    static func uniquePath(directory: String, base: String, ext: String, avoiding input: String,
                           fileExists: (String) -> Bool) -> String {
        let inputStd = (input as NSString).standardizingPath.lowercased()
        func candidate(_ n: Int) -> String {
            (directory as NSString).appendingPathComponent(n == 1 ? "\(base).\(ext)" : "\(base) (\(n)).\(ext)")
        }
        var n = 1
        while (candidate(n) as NSString).standardizingPath.lowercased() == inputStd || fileExists(candidate(n)) { n += 1 }
        return candidate(n)
    }

    /// Sibling ffprobe for an ffmpeg path (Homebrew, MacPorts and static builds ship them together).
    static func ffprobePath(nextTo ffmpeg: String) -> String? {
        let p = ((ffmpeg as NSString).deletingLastPathComponent as NSString).appendingPathComponent("ffprobe")
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
}
