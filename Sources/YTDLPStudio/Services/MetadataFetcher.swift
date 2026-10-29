import Foundation

struct FormatInfo: Identifiable, Hashable {
    let id: String
    let ext: String
    let resolution: String
    let fps: String
    let vcodec: String
    let acodec: String
    let bitrate: String
    let size: String
    let note: String
    let hasVideo: Bool
    let hasAudio: Bool

    var kind: String {
        switch (hasVideo, hasAudio) {
        case (true, true): return "A+V"
        case (true, false): return "Video"
        case (false, true): return "Audio"
        default: return "Other"
        }
    }
}

struct ChapterInfo: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let start: String
}

struct MediaInfo: Identifiable {
    let id = UUID()
    let url: String
    let title: String
    let uploader: String
    let duration: String
    let thumbnail: URL?
    let isPlaylist: Bool
    let entries: [String]
    let formats: [FormatInfo]
    let chapters: [ChapterInfo]
}

enum MetadataFetcher {
    static func fetch(url: String, tools: ToolSnapshot, cookieBrowser: CookieBrowser, cookiesFile: String = "") async throws -> MediaInfo {
        var args = ["-J", "--flat-playlist", "--no-warnings"]
        if cookieBrowser != .none { args += ["--cookies-from-browser", cookieBrowser.rawValue] }
        if !cookiesFile.trimmed.isEmpty, FileManager.default.fileExists(atPath: cookiesFile) { args += ["--cookies", cookiesFile] }
        args += ["--", url]

        let result = try await Shell.run(tools.ytdlp, args, environment: tools.environment)
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let errLine = result.stderr.split(separator: "\n").last { $0.contains("ERROR") }
            throw SimpleError(errLine.map(String.init) ?? "yt-dlp could not read this URL (exit \(result.status)).")
        }

        let isPlaylist = (obj["_type"] as? String) == "playlist"
        let entries = (obj["entries"] as? [[String: Any]])?.map { ($0["title"] as? String) ?? ($0["url"] as? String) ?? "Untitled" } ?? []

        let formats: [FormatInfo] = ((obj["formats"] as? [[String: Any]]) ?? []).compactMap { f in
            guard let id = f["format_id"] as? String else { return nil }
            let vcodec = (f["vcodec"] as? String) ?? "none"
            let acodec = (f["acodec"] as? String) ?? "none"
            if vcodec == "none" && acodec == "none" && (f["ext"] as? String) == "mhtml" { return nil } // storyboards
            let bytes = (f["filesize"] as? NSNumber)?.int64Value ?? (f["filesize_approx"] as? NSNumber)?.int64Value
            let tbr = (f["tbr"] as? NSNumber)?.doubleValue
            let fps = (f["fps"] as? NSNumber)?.doubleValue
            return FormatInfo(
                id: id,
                ext: (f["ext"] as? String) ?? "?",
                resolution: (f["resolution"] as? String) ?? "—",
                fps: fps.map { "\(Int($0.rounded()))" } ?? "",
                vcodec: vcodec == "none" ? "" : vcodec,
                acodec: acodec == "none" ? "" : acodec,
                bitrate: tbr.map { "\(Int($0.rounded()))k" } ?? "",
                size: bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "",
                note: (f["format_note"] as? String) ?? "",
                hasVideo: vcodec != "none",
                hasAudio: acodec != "none")
        }

        let chapters: [ChapterInfo] = ((obj["chapters"] as? [[String: Any]]) ?? []).map { c in
            ChapterInfo(title: (c["title"] as? String) ?? "Chapter",
                        start: formatDuration((c["start_time"] as? NSNumber)?.doubleValue ?? 0))
        }

        let durationSeconds = (obj["duration"] as? NSNumber)?.doubleValue
        return MediaInfo(
            url: url,
            title: (obj["title"] as? String) ?? url,
            uploader: (obj["uploader"] as? String) ?? (obj["channel"] as? String) ?? "",
            duration: durationSeconds.map(formatDuration) ?? "",
            thumbnail: (obj["thumbnail"] as? String).flatMap(URL.init(string:)),
            isPlaylist: isPlaylist,
            entries: entries,
            formats: formats.reversed(), // best first
            chapters: chapters)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
