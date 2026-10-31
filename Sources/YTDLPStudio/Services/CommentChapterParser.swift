import Foundation

enum ChapterSource: String, Codable, CaseIterable, Identifiable {
    case youtube, comments, commentsIfMissing
    var id: Self { self }
    var label: String {
        switch self {
        case .youtube: return "YouTube chapters"
        case .comments: return "Comments"
        case .commentsIfMissing: return "Comments if chapters are missing"
        }
    }
}

struct CommentChapter: Equatable {
    let title: String
    let start: Double
    let end: Double
    var json: [String: Any] { ["title": title, "start_time": start, "end_time": end] }
}

struct CommentChapterCandidate: Identifiable {
    let id: String
    let author: String
    let text: String
    let likes: Int
    let chapters: [CommentChapter]
}

struct CommentChapterPreview: Identifiable {
    let id = UUID()
    let videoID: String
    let title: String
    let candidates: [CommentChapterCandidate]
}

enum CommentChapterParser {
    // One timestamp per line, at either end, optionally enclosed in brackets.
    private static let timestamp = try! NSRegularExpression(pattern: #"(?<![\d:])(?:\d{1,3}:)?\d{1,3}:\d{2}(?![\d:])"#)
    static func parse(_ text: String, duration: Double) -> [CommentChapter] {
        guard duration.isFinite, duration > 0 else { return [] }
        var starts: [(String, Double)] = []
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            let matches = timestamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            guard matches.count == 1, let match = matches.first else { return [] }
            let parts = ns.substring(with: match.range).split(separator: ":").compactMap { Int($0) }
            guard (parts.count == 2 || parts.count == 3), parts.last! < 60,
                  parts.count != 3 || parts[1] < 60 else { return [] }
            let seconds = Double(parts.reduce(0) { $0 * 60 + $1 })
            guard seconds < duration, starts.last.map({ seconds > $0.1 }) ?? true else { return [] }
            let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "[]()–—-:|•"))
            let before = ns.substring(to: match.range.location).trimmingCharacters(in: trim)
            let after = ns.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: trim)
            // Don't treat a timestamp embedded in prose as a chapter heading.
            let trackNumber = before.range(of: #"^#?\d{1,3}[.)]?$"#, options: .regularExpression) != nil
            guard before.isEmpty || after.isEmpty || trackNumber else { return [] }
            let title = (!after.isEmpty && (before.isEmpty || trackNumber)) ? after : before
            guard !title.isEmpty else { return [] }
            starts.append((title, seconds))
        }
        guard starts.count >= 3 else { return [] }
        // Preserve the opening of the video when the supplied list starts later than zero.
        if starts[0].1 > 0 { starts.insert(("Opening", 0), at: 0) }
        return starts.enumerated().map { index, item in
            CommentChapter(title: item.0, start: item.1,
                           end: index + 1 < starts.count ? starts[index + 1].1 : duration)
        }
    }

    static func candidates(in info: [String: Any]) -> [CommentChapterCandidate] {
        guard let duration = info["duration"] as? Double else { return [] }
        return ((info["comments"] as? [[String: Any]]) ?? []).compactMap { comment in
            let text = comment["text"] as? String ?? ""
            let chapters = parse(text, duration: duration)
            guard !chapters.isEmpty, let id = comment["id"] as? String else { return nil }
            return CommentChapterCandidate(id: id, author: comment["author"] as? String ?? "Unknown author",
                                           text: text, likes: comment["like_count"] as? Int ?? 0, chapters: chapters)
        }.sorted {
            if $0.chapters.count != $1.chapters.count { return $0.chapters.count > $1.chapters.count }
            if $0.likes != $1.likes { return $0.likes > $1.likes }
            return $0.id < $1.id
        }
    }
}

/// Shared by the preview and the queue. Metadata is fetched just before downloading,
/// keeping signed media URLs fresh. ProcessRunner makes fetching cancellable.
enum CommentChapterService {
    static func arguments(url: String, options o: DownloadOptions, preview: Bool = false, includeComments: Bool = true) -> [String] {
        var args = ["--ignore-config", "--skip-download", "--dump-single-json", "--no-clean-info-json",
                    "--no-colors"]
        if includeComments {
            args += ["--write-comments", "--extractor-args", "youtube:comment_sort=top;max_comments=200,200,0,0"]
        } else { args += ["--no-write-comments"] }
        if o.cookieBrowser != .none { args += ["--cookies-from-browser", o.cookieBrowser.rawValue] }
        if !o.cookiesFile.trimmed.isEmpty, FileManager.default.fileExists(atPath: o.cookiesFile) { args += ["--cookies", o.cookiesFile] }
        if !o.proxy.trimmed.isEmpty { args += ["--proxy", o.proxy.trimmed] }
        if preview || o.playlistMode == .single { args += ["--no-playlist"] }
        else if o.playlistMode == .full { args += ["--yes-playlist"] }
        if !preview && !o.playlistItems.trimmed.isEmpty { args += ["--playlist-items", o.playlistItems.trimmed] }
        args += ["--", url]
        return args
    }

    static func needsComments(_ info: [String: Any]) -> Bool {
        if let entries = info["entries"] as? [[String: Any]] { return entries.contains(where: needsComments) }
        return ((info["chapters"] as? [[String: Any]]) ?? []).isEmpty
    }

    static func object(from json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let info = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SimpleError("yt-dlp returned unreadable video metadata.")
        }
        return info
    }

    static func preview(from json: String) throws -> CommentChapterPreview {
        let info = try object(from: json)
        guard info["entries"] == nil else { throw SimpleError("Paste an individual video link to preview its comment chapters.") }
        let candidates = CommentChapterParser.candidates(in: info)
        guard !candidates.isEmpty else {
            throw SimpleError("No valid chapter list found in the first 200 top comments. Lists need at least three increasing timestamps with titles. Comments may also be disabled.")
        }
        return CommentChapterPreview(videoID: info["id"] as? String ?? "", title: info["title"] as? String ?? "Video", candidates: candidates)
    }

    static func prepare(_ info: [String: Any], source: ChapterSource,
                        selections: [String: String], keepComments: Bool,
                        log: (String) -> Void) throws -> [[String: Any]] {
        if let entries = info["entries"] as? [Any] {
            // An array of full video objects avoids applying playlist item ranges twice.
            return try entries.flatMap { entry -> [[String: Any]] in
                guard let video = entry as? [String: Any] else { return [] }
                return try prepare(video, source: source, selections: selections, keepComments: keepComments, log: log)
            }
        }
        var video = info
        let existing = (info["chapters"] as? [[String: Any]]) ?? []
        if source == .comments || (source == .commentsIfMissing && existing.isEmpty) {
            let candidates = CommentChapterParser.candidates(in: info)
            let videoID = info["id"] as? String ?? ""
            let selectedID = selections[videoID]
            let selected = selectedID == nil ? candidates.first : candidates.first { $0.id == selectedID }
            if let selected {
                video["chapters"] = selected.chapters.map(\.json)
                log("Using \(selected.chapters.count) comment chapters from \(selected.author) for \(info["title"] as? String ?? videoID).")
            } else if source == .comments || selectedID != nil {
                throw SimpleError(selectedID == nil ? "No valid comment chapter list found for \(info["title"] as? String ?? videoID). Try YouTube chapters or preview another video."
                                  : "The selected comment is no longer available among the first 200 top comments. Search again to select a chapter list.")
            } else {
                log("No comment chapters found; downloading without chapter markers.")
            }
        } else { log("Keeping existing YouTube chapters.") }
        // Let the final invocation select formats and subtitles using current download options.
        for key in ["requested_formats", "requested_downloads", "requested_subtitles"] { video.removeValue(forKey: key) }
        if !keepComments { video.removeValue(forKey: "comments") }
        return [video]
    }
}
