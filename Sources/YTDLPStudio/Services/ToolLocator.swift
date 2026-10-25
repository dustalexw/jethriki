import Foundation
import Combine

struct ToolSnapshot {
    let ytdlp: String
    let ffmpeg: String?
    let environment: [String: String]
}

/// Finds yt-dlp and ffmpeg. GUI apps don't inherit the shell PATH, so common install locations are scanned.
final class ToolLocator: ObservableObject {
    @Published private(set) var ytdlpPath: String?
    @Published private(set) var ffmpegPath: String?
    @Published private(set) var ytdlpVersion = "—"
    @Published private(set) var ffmpegVersion = "—"

    @Published var ytdlpOverride: String {
        didSet { UserDefaults.standard.set(ytdlpOverride, forKey: "ytdlpOverride") }
    }
    @Published var ffmpegOverride: String {
        didSet { UserDefaults.standard.set(ffmpegOverride, forKey: "ffmpegOverride") }
    }

    static var searchDirectories: [String] {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
                "\(home)/.local/bin", "\(home)/bin", "/usr/bin", "/bin"]
    }

    init() {
        ytdlpOverride = UserDefaults.standard.string(forKey: "ytdlpOverride") ?? ""
        ffmpegOverride = UserDefaults.standard.string(forKey: "ffmpegOverride") ?? ""
        refresh()
    }

    func refresh() {
        ytdlpPath = Self.resolve("yt-dlp", override: ytdlpOverride)
        ffmpegPath = Self.resolve("ffmpeg", override: ffmpegOverride)
        ytdlpVersion = "—"
        ffmpegVersion = "—"
        Task { await loadVersions() }
    }

    private static func resolve(_ name: String, override: String) -> String? {
        let fm = FileManager.default
        let o = (override.trimmed as NSString).expandingTildeInPath
        if !o.isEmpty, fm.isExecutableFile(atPath: o) { return o }
        for dir in searchDirectories {
            let path = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        var dirs = Self.searchDirectories
        if let f = ffmpegPath { dirs.insert((f as NSString).deletingLastPathComponent, at: 0) }
        if let y = ytdlpPath { dirs.insert((y as NSString).deletingLastPathComponent, at: 0) }
        if let existing = env["PATH"] { dirs.append(existing) }
        env["PATH"] = dirs.joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["NO_COLOR"] = "1"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    func snapshot() -> ToolSnapshot? {
        guard let y = ytdlpPath else { return nil }
        return ToolSnapshot(ytdlp: y, ffmpeg: ffmpegPath, environment: environment)
    }

    private func loadVersions() async {
        let env = environment
        var yv = "Not found"
        var fv = "Not found"
        if let y = ytdlpPath, let r = try? await Shell.run(y, ["--version"], environment: env) {
            yv = r.stdout.trimmed.isEmpty ? "Unknown" : r.stdout.trimmed
        }
        if let f = ffmpegPath, let r = try? await Shell.run(f, ["-version"], environment: env) {
            let first = r.stdout.split(separator: "\n").first.map(String.init) ?? "Unknown"
            fv = first.replacingOccurrences(of: "ffmpeg version ", with: "")
                .components(separatedBy: " Copyright").first ?? first
        }
        var encoders: Set<String>?
        if let f = ffmpegPath, let r = try? await Shell.run(f, ["-hide_banner", "-encoders"], environment: env), r.status == 0 {
            encoders = CommandBuilder.parseEncoders(r.stdout)
        }
        let ytdlpText = yv
        let ffmpegText = fv
        let found = encoders
        await MainActor.run {
            self.ytdlpVersion = ytdlpText
            self.ffmpegVersion = ffmpegText
            CommandBuilder.ffmpegEncoders = found
        }
    }

    /// Runs `yt-dlp -U`. Homebrew installs will be told to use `brew upgrade yt-dlp`.
    func updateYtDlp() async -> String {
        guard let y = ytdlpPath else { return "yt-dlp not found." }
        do {
            let r = try await Shell.run(y, ["-U"], environment: environment)
            let text = (r.stdout + "\n" + r.stderr).trimmed
            await MainActor.run { self.refresh() }
            return text.isEmpty ? "Done (exit \(r.status))." : text
        } catch {
            return error.localizedDescription
        }
    }
}
