import Foundation
import Combine
#if canImport(AppKit)
import AppKit
#elseif os(iOS)
import AudioToolbox
#endif

enum JobStatus: Equatable {
    case queued, starting, downloading
    case processing(String)
    case encoding(String)
    case finished
    case warning(String)
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .starting, .downloading, .processing, .encoding: return true
        default: return false
        }
    }
    var isDone: Bool {
        switch self {
        case .finished, .warning, .failed, .cancelled: return true
        default: return false
        }
    }
    var label: String {
        switch self {
        case .queued: return "Queued"
        case .starting: return "Starting…"
        case .downloading: return "Downloading"
        case .processing(let step): return step
        case .encoding(let detail): return detail
        case .finished: return "Done"
        case .warning(let msg): return "Done with warnings: \(msg)"
        case .failed(let msg): return "Failed: \(msg)"
        case .cancelled: return "Cancelled"
        }
    }
}

final class DownloadJob: ObservableObject, Identifiable {
    let id = UUID()
    let url: String
    let options: DownloadOptions
    let tools: ToolSnapshot
    var commentSelections: [String: String] = [:]

    @Published var title = ""
    @Published var status: JobStatus = .queued
    @Published var progress: Double = 0
    @Published var speed = ""
    @Published var eta = ""
    @Published var size = ""
    @Published var itemInfo = ""
    @Published var log: [String] = []
    @Published var outputFiles: [String] = []

    var runner: ProcessRunner?
    var wasCancelled = false
    var lastError: String?
    var pendingEncodes: [String] = []
    var encodeDuration: Double?
    var encodeIndex = 0
    var encodeTotal = 0

    init(url: String, options: DownloadOptions, tools: ToolSnapshot) {
        self.url = url
        self.options = options
        self.tools = tools
    }

    var displayTitle: String { title.isEmpty ? url : title }

    var detailLine: String {
        var parts: [String] = []
        if !itemInfo.isEmpty { parts.append(itemInfo) }
        if status == .downloading {
            if !size.isEmpty { parts.append(size) }
            if !speed.isEmpty { parts.append(speed) }
            if !eta.isEmpty { parts.append("ETA \(eta)") }
        }
        if case .encoding = status, !speed.isEmpty { parts.append(speed) }
        return parts.joined(separator: "  ·  ")
    }

    func resetForRun() {
        wasCancelled = false
        lastError = nil
        progress = 0
        speed = ""; eta = ""; size = ""; itemInfo = ""
        outputFiles = []
        pendingEncodes = []
        log = []
    }

    func appendLog(_ line: String) {
        log.append(line)
        if log.count > 4000 { log.removeFirst(log.count - 4000) }
    }

    // MARK: Parsing yt-dlp output

    private static let ppNames: [String: String] = [
        "Merger": "Merging streams", "ExtractAudio": "Extracting audio",
        "VideoRemuxer": "Remuxing", "VideoConvertor": "Converting video",
        "EmbedThumbnail": "Embedding thumbnail", "Metadata": "Writing metadata",
        "SplitChapters": "Splitting chapters", "SponsorBlock": "Fetching SponsorBlock",
        "ModifyChapters": "Cutting segments", "EmbedSubtitle": "Embedding subtitles",
        "FixupM3u8": "Fixing stream", "FixupM4a": "Fixing container",
        "FixupStretched": "Fixing aspect ratio", "ThumbnailsConvertor": "Converting thumbnail",
        "SubtitlesConvertor": "Converting subtitles", "FFmpegConcat": "Concatenating",
        "MetadataParser": "Reading tags"
    ]

    func handleYtdlpLine(_ raw: String) {
        let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        let prefix = CommandBuilder.progressPrefix

        if line.hasPrefix(prefix) {
            let parts = line.dropFirst(prefix.count)
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            func part(_ i: Int) -> String {
                guard i < parts.count else { return "" }
                let v = parts[i]
                return (v == "NA" || v == "N/A" || v == "Unknown") ? "" : v
            }
            if let pct = Double(part(0).replacingOccurrences(of: "%", with: "")) { progress = min(max(pct / 100, 0), 1) }
            speed = part(1)
            eta = part(2)
            size = part(3).isEmpty ? (part(4).isEmpty ? "" : "~" + part(4)) : part(3)
            if title.isEmpty { title = part(5) }
            if status != .downloading { status = .downloading }
            return
        }

        appendLog(line)

        if let r = line.range(of: #"Downloading item \d+ of \d+"#, options: .regularExpression) {
            itemInfo = String(line[r]).replacingOccurrences(of: "Downloading item", with: "Item")
        }
        if line.hasPrefix("ERROR:") {
            lastError = String(line.dropFirst(6)).trimmed
        } else if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            let tag = String(line[line.index(after: line.startIndex)..<close])
            if let friendly = Self.ppNames[tag] { status = .processing(friendly) }
        }
    }

    // MARK: Parsing ffmpeg output

    func handleFFmpegLine(_ line: String, isErr: Bool) {
        if isErr {
            if encodeDuration == nil,
               let r = line.range(of: #"Duration: \d+:\d+:\d+(\.\d+)?"#, options: .regularExpression) {
                let t = line[r].replacingOccurrences(of: "Duration: ", with: "").split(separator: ":")
                if t.count == 3, let h = Double(t[0]), let m = Double(t[1]), let s = Double(t[2]) {
                    encodeDuration = h * 3600 + m * 60 + s
                }
            }
            appendLog(line)
            return
        }
        // -progress pipe:1 key=value lines
        if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
            let v = Double(line.split(separator: "=").last ?? "") ?? 0
            if let d = encodeDuration, d > 0 { progress = min(max(v / 1_000_000 / d, 0), 1) }
        } else if line.hasPrefix("speed=") {
            let s = String(line.dropFirst(6)).trimmed
            speed = s == "N/A" ? "" : "\(s) realtime"
        }
    }
}

extension Ringtone {
    /// Gives finished ringtones their .m4r name, so they can be dropped straight onto an iPhone in
    /// Finder or into iTunes / Apple Devices. Returns the file list with the new paths.
    static func finalize(_ files: [String], keepExisting: Bool, log: (String) -> Void) -> [String] {
        let fm = FileManager.default
        return files.map { path in
            guard (path as NSString).pathExtension.lowercased() == "m4a", fm.fileExists(atPath: path) else { return path }
            let base = (path as NSString).deletingPathExtension
            var target = base + "." + fileExtension
            if keepExisting, fm.fileExists(atPath: target) {
                var n = 2
                while fm.fileExists(atPath: "\(base) \(n).\(fileExtension)") { n += 1 }
                target = "\(base) \(n).\(fileExtension)"
            }
            // rename(2) replaces an existing tone in one step, so a failure can never leave neither file behind
            // (deleting the old tone first and then moving could).
            if rename(path, target) == 0 {
                log("[Ringtone] Saved \((target as NSString).lastPathComponent)")
                return target
            }
            log("[Ringtone] Could not rename to .\(fileExtension): \(String(cString: strerror(errno)))")
            return path
        }
    }
}

final class DownloadManager: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []

    static weak var current: DownloadManager?

    init() { Self.current = self }

    #if os(iOS)
    // yt-dlp runs inside the app's one Python interpreter, which runs one job at a time.
    private var maxConcurrent: Int { 1 }
    #else
    private var maxConcurrent: Int { max(1, UserDefaults.standard.integer(forKey: "maxConcurrent")) }
    #endif

    func enqueue(urls: [String], options: DownloadOptions, tools: ToolSnapshot, commentSelections: [String: String] = [:]) {
        for url in urls {
            let job = DownloadJob(url: url, options: options, tools: tools)
            job.commentSelections = commentSelections
            jobs.append(job)
        }
        pump()
    }

    func pump() {
        var slots = maxConcurrent - jobs.filter { $0.status.isActive }.count
        for job in jobs where job.status == .queued && slots > 0 {
            // Never run two jobs for the same link into the same folder at once.
            let duplicateRunning = jobs.contains {
                $0.id != job.id && $0.status.isActive &&
                $0.url == job.url && $0.options.outputDirectory == job.options.outputDirectory
            }
            if duplicateRunning { continue }
            start(job)
            slots -= 1
        }
    }

    func cancel(_ job: DownloadJob) {
        if job.status == .queued { job.status = .cancelled; return }
        guard job.status.isActive else { return }
        job.wasCancelled = true
        job.pendingEncodes = []
        job.runner?.terminate()
    }

    func retry(_ job: DownloadJob) {
        guard job.status.isDone else { return }
        job.status = .queued
        pump()
    }

    func remove(_ job: DownloadJob) {
        cancel(job)
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.status.isDone }
    }

    func cancelAll() {
        jobs.forEach(cancel)
    }

    #if canImport(AppKit)
    func reveal(_ job: DownloadJob) {
        let existing = job.outputFiles.filter { FileManager.default.fileExists(atPath: $0) }
        if existing.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: job.options.outputDirectory))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing.map { URL(fileURLWithPath: $0) })
        }
    }
    #endif

    // MARK: - yt-dlp stage

    private func start(_ job: DownloadJob) {
        job.resetForRun()
        job.status = .starting

        let pathsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytdlp-studio-\(job.id.uuidString).paths").path
        try? FileManager.default.removeItem(atPath: pathsFile)
        let chaptersFile: String? = job.options.retagsChapters
            ? FileManager.default.temporaryDirectory.appendingPathComponent("ytdlp-studio-\(job.id.uuidString).chapters").path
            : nil
        if let cf = chaptersFile { try? FileManager.default.removeItem(atPath: cf) }
        try? FileManager.default.createDirectory(atPath: job.options.outputDirectory, withIntermediateDirectories: true)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytdlp-studio-\(job.id.uuidString)", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        if job.options.chapterSource != .youtube {
            prepareCommentChapters(job, pathsFile: pathsFile, chaptersFile: chaptersFile, tempDir: tempDir, includeComments: job.options.chapterSource == .comments)
        } else {
            runDownload(job, pathsFile: pathsFile, chaptersFile: chaptersFile, tempDir: tempDir, infoFile: nil)
        }
    }

    private func prepareCommentChapters(_ job: DownloadJob, pathsFile: String, chaptersFile: String?, tempDir: String, includeComments: Bool) {
        job.status = .processing(includeComments ? "Finding chapters in comments" : "Checking YouTube chapters")
        var json = ""
        let runner = ProcessRunner(executable: job.tools.ytdlp,
            arguments: CommentChapterService.arguments(url: job.url, options: job.options, includeComments: includeComments), environment: job.tools.environment)
        runner.onLine = { [weak job] line, isErr in
            if isErr { job?.handleYtdlpLine(line) } else { json += line + "\n" }
        }
        runner.onExit = { [weak self, weak job] code in
            guard let self, let job else { return }
            job.runner = nil
            do {
                guard !job.wasCancelled else { throw SimpleError("Cancelled") }
                guard code == 0 else { throw SimpleError(job.lastError ?? "Could not fetch comments (exit \(code)).") }
                let info = try CommentChapterService.object(from: json)
                if !includeComments && CommentChapterService.needsComments(info) {
                    self.prepareCommentChapters(job, pathsFile: pathsFile, chaptersFile: chaptersFile, tempDir: tempDir, includeComments: true)
                    return
                }
                let videos = try CommentChapterService.prepare(info, source: job.options.chapterSource,
                    selections: job.commentSelections, keepComments: job.options.writeComments, log: job.appendLog)
                guard !videos.isEmpty else { throw SimpleError("No videos available in the selected playlist range.") }
                let path = (tempDir as NSString).appendingPathComponent("comment-chapters.info.json")
                try JSONSerialization.data(withJSONObject: videos).write(to: URL(fileURLWithPath: path), options: .atomic)
                // Fetch warnings should not be mistaken for a later download failure.
                job.lastError = nil
                self.runDownload(job, pathsFile: pathsFile, chaptersFile: chaptersFile, tempDir: tempDir, infoFile: path)
            } catch {
                try? FileManager.default.removeItem(atPath: tempDir)
                job.status = job.wasCancelled ? .cancelled : .failed(error.localizedDescription)
                self.pump()
            }
        }
        job.runner = runner
        do { try runner.start() }
        catch {
            job.runner = nil
            try? FileManager.default.removeItem(atPath: tempDir)
            job.status = .failed(error.localizedDescription)
            pump()
        }
    }

    private func runDownload(_ job: DownloadJob, pathsFile: String, chaptersFile: String?, tempDir: String, infoFile: String?) {
        job.status = .starting
        let ffDir = job.tools.ffmpeg.map { ($0 as NSString).deletingLastPathComponent }
        let args = CommandBuilder.arguments(for: job.options, urls: [job.url],
                                            ffmpegLocation: ffDir, pathsFile: pathsFile,
                                            chaptersFile: chaptersFile, tempDirectory: tempDir, infoFile: infoFile)
        job.appendLog("$ yt-dlp " + args.map(CommandBuilder.shellQuote).joined(separator: " "))

        let runner = ProcessRunner(executable: job.tools.ytdlp, arguments: args, environment: job.tools.environment)
        runner.onLine = { [weak job] line, _ in job?.handleYtdlpLine(line) }
        runner.onExit = { [weak self, weak job] code in
            guard let self, let job else { return }
            try? FileManager.default.removeItem(atPath: tempDir)
            self.ytdlpFinished(job, code: code, pathsFile: pathsFile, chaptersFile: chaptersFile)
        }
        job.runner = runner

        do {
            try runner.start()
        } catch {
            job.runner = nil
            try? FileManager.default.removeItem(atPath: tempDir)
            job.status = .failed(error.localizedDescription)
            pump()
        }
    }

    private func ytdlpFinished(_ job: DownloadJob, code: Int32, pathsFile: String, chaptersFile: String?) {
        job.runner = nil
        let mainFiles = ((try? String(contentsOfFile: pathsFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.trimmed.isEmpty }
        var files: [String] = []
        for line in mainFiles where !files.contains(line) { files.append(line) }
        try? FileManager.default.removeItem(atPath: pathsFile)
        job.outputFiles = files

        // One chapters line per downloaded video, in the same order as the main files.
        var chapterLines: [String] = []
        if let cf = chaptersFile {
            chapterLines = ((try? String(contentsOfFile: cf, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
            try? FileManager.default.removeItem(atPath: cf)
        }

        if job.wasCancelled {
            job.status = .cancelled
            pump()
            return
        }
        if code != 0 {
            let msg = job.lastError ?? "yt-dlp exited with code \(code)"
            job.status = files.isEmpty ? .failed(msg) : .warning(msg)
            if files.isEmpty { pump(); return }
        }

        if job.options.retagsChapters, let ffmpeg = job.tools.ffmpeg {
            var groups: [(main: String?, tracks: [ChapterTagger.Track])] = []
            for (i, line) in chapterLines.enumerated() {
                let tracks = ChapterTagger.tracks(fromChaptersJSON: line, options: job.options)
                if tracks.isEmpty { continue }
                let main: String? = i < mainFiles.count ? mainFiles[i] : nil
                groups.append((main: main, tracks: tracks))
            }
            let tagGroups = groups
            if !groups.isEmpty {
                job.status = .processing("Tagging tracks")
                let env = job.tools.environment
                Task {
                    var collected: [String] = []
                    for g in tagGroups {
                        collected += await ChapterTagger.retag(g.tracks, mainFile: g.main, ffmpeg: ffmpeg, environment: env)
                    }
                    let lines = collected
                    let trackPaths = tagGroups.flatMap { $0.tracks.map(\.path) }
                    DispatchQueue.main.async {
                        lines.forEach(job.appendLog)
                        for p in trackPaths where !job.outputFiles.contains(p) { job.outputFiles.append(p) }
                        if job.wasCancelled { job.status = .cancelled; self.pump() } else { self.complete(job) }
                    }
                }
                return
            }
        }

        let videoExts: Set<String> = ["mp4", "mkv", "webm", "mov", "avi", "flv", "m4v"]
        if job.options.encodeEnabled && job.options.mode != .audio {
            job.pendingEncodes = files.filter { videoExts.contains(($0 as NSString).pathExtension.lowercased()) }
            job.encodeTotal = job.pendingEncodes.count
            job.encodeIndex = 0
            if !job.pendingEncodes.isEmpty {
                if job.tools.ffmpeg == nil {
                    job.status = .failed("FFmpeg not found; cannot re-encode.")
                    pump()
                    return
                }
                encodeNext(job)
                return
            }
        }
        complete(job)
    }

    private func complete(_ job: DownloadJob) {
        if job.options.makesRingtone {
            job.outputFiles = Ringtone.finalize(job.outputFiles, keepExisting: job.options.noOverwrites, log: job.appendLog)
        }
        #if !os(iOS)   // iOS can't run adb
        if job.options.sendsToAndroidWhenDone, !job.wasCancelled {
            let tones = job.outputFiles.filter {
                ["ogg", "mp3", "m4a"].contains(($0 as NSString).pathExtension.lowercased()) && FileManager.default.fileExists(atPath: $0)
            }
            if !tones.isEmpty {
                job.status = .processing("Sending to Android")
                let notification = job.options.makesNotificationSound
                Task {
                    let problem = await Self.sendToAndroid(tones, notification: notification) { line in
                        DispatchQueue.main.async { job.appendLog(line) }
                    }
                    DispatchQueue.main.async {
                        if let problem { job.appendLog("[Android] Not sent: \(problem)"); job.status = .warning("not sent to Android: \(problem)") }
                        self.finish(job)
                    }
                }
                return
            }
        }
        #endif
        finish(job)
    }

    #if !os(iOS)
    /// Copies finished tones to the first ready Android phone, USB before Wi-Fi. Never changes the default
    /// sound. Returns a user-facing reason when nothing could be sent.
    private static func sendToAndroid(_ tones: [String], notification: Bool, log: @escaping (String) -> Void) async -> String? {
        do {
            let phones = try await AndroidSync.list()
            guard let phone = phones.filter(\.ready).sorted(by: { !$0.wifi && $1.wifi }).first else {
                return phones.isEmpty
                    ? "no phone connected. Turn on USB debugging (cable) or Wireless debugging (Wi-Fi)."
                    : "unlock the phone and tap Allow on the USB debugging prompt."
            }
            for tone in tones {
                _ = try await AndroidSync.sendRingtone(path: tone, to: phone, setAsRingtone: false, notification: notification, log: log)
            }
            log("[Android] Sent to \(phone.name) over \(phone.wifi ? "Wi-Fi" : "USB").")
            return nil
        } catch {
            return error.localizedDescription
        }
    }
    #endif

    private func finish(_ job: DownloadJob) {
        if case .warning = job.status {} else { job.status = .finished }
        job.progress = 1
        job.speed = ""; job.eta = ""
        if UserDefaults.standard.bool(forKey: "playSound") {
            #if os(iOS)
            AudioServicesPlaySystemSound(1025)
            #else
            NSSound(named: "Glass")?.play()
            #endif
        }
        pump()
    }

    // MARK: - FFmpeg re-encode stage

    private func encodeNext(_ job: DownloadJob) {
        guard !job.wasCancelled else { job.status = .cancelled; pump(); return }
        guard !job.pendingEncodes.isEmpty, let ffmpeg = job.tools.ffmpeg else { complete(job); return }

        let input = job.pendingEncodes.removeFirst()
        job.encodeIndex += 1
        let base = (input as NSString).deletingPathExtension
        let ext = job.options.container.rawValue
        let output = base + ".encoded." + ext

        job.progress = 0
        job.speed = ""
        job.encodeDuration = nil
        job.status = .encoding(job.encodeTotal > 1 ? "Encoding \(job.encodeIndex)/\(job.encodeTotal)" : "Encoding")

        let args = CommandBuilder.ffmpegEncodeArguments(input: input, output: output, o: job.options)
        job.appendLog("$ ffmpeg " + args.map(CommandBuilder.shellQuote).joined(separator: " "))

        let runner = ProcessRunner(executable: ffmpeg, arguments: args, environment: job.tools.environment)
        runner.onLine = { [weak job] line, isErr in job?.handleFFmpegLine(line, isErr: isErr) }
        runner.onExit = { [weak self, weak job] code in
            guard let self, let job else { return }
            job.runner = nil
            if job.wasCancelled {
                try? FileManager.default.removeItem(atPath: output)
                job.status = .cancelled
                self.pump()
                return
            }
            if code == 0 {
                var final = output
                if job.options.replaceOriginal {
                    let target = base + "." + ext
                    let fm = FileManager.default
                    do {
                        #if os(iOS)   // iOS has no Trash for app files
                        try fm.removeItem(atPath: input)
                        if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
                        #else
                        try fm.trashItem(at: URL(fileURLWithPath: input), resultingItemURL: nil)
                        if fm.fileExists(atPath: target) {
                            try fm.trashItem(at: URL(fileURLWithPath: target), resultingItemURL: nil)
                        }
                        #endif
                        try fm.moveItem(atPath: output, toPath: target)
                        final = target
                    } catch {
                        job.appendLog("Could not replace original: \(error.localizedDescription)")
                    }
                }
                if let idx = job.outputFiles.firstIndex(of: input) {
                    if job.options.replaceOriginal { job.outputFiles[idx] = final } else { job.outputFiles.append(final) }
                } else {
                    job.outputFiles.append(final)
                }
                self.encodeNext(job)
            } else {
                try? FileManager.default.removeItem(atPath: output)
                let lastLine = job.log.last { !$0.hasPrefix("$ ") } ?? ""
                job.status = .failed("FFmpeg exited with code \(code). \(lastLine)")
                self.pump()
            }
        }
        job.runner = runner
        do {
            try runner.start()
        } catch {
            job.status = .failed(error.localizedDescription)
            pump()
        }
    }
}
