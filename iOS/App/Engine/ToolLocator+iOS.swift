import Foundation
import Combine
import JethrikiFFmpeg

/// The iOS app's tools are built in: yt-dlp runs in the embedded Python, FFmpeg is a framework. This keeps the
/// desktop ToolLocator's interface so the shared code finds them the same way.
final class ToolLocator: ObservableObject {
    @Published private(set) var ytdlpPath: String?
    @Published private(set) var ffmpegPath: String?
    @Published private(set) var ytdlpVersion = "—"
    @Published private(set) var ffmpegVersion = "—"
    @Published private(set) var bundledYtdlpVersion = "—"
    @Published private(set) var startProblem: String?

    // Kept for the shared settings code; there is nothing to locate on iOS.
    @Published var ytdlpOverride = ""
    @Published var ffmpegOverride = ""

    init() {
        let tools = PythonEngine.toolsDirectory
        ytdlpPath = (tools as NSString).appendingPathComponent("yt-dlp")
        ffmpegPath = (tools as NSString).appendingPathComponent("ffmpeg")
        bundledYtdlpVersion = Bundle.main.object(forInfoDictionaryKey: "JethrikiYtDlpVersion") as? String ?? "—"
        refresh()
    }

    func refresh() {
        Task { await loadVersions() }
    }

    var environment: [String: String] { ProcessInfo.processInfo.environment }

    func snapshot() -> ToolSnapshot? {
        guard let y = ytdlpPath else { return nil }
        return ToolSnapshot(ytdlp: y, ffmpeg: ffmpegPath, environment: environment)
    }

    private func loadVersions() async {
        let problem = await Task.detached { PythonEngine.shared.waitUntilReady() }.value
        var yv = problem == nil ? "Unknown" : "Not available"
        if problem == nil, let y = ytdlpPath, let r = try? await Shell.run(y, ["--version"], environment: [:]) {
            let text = r.stdout.trimmed
            if !text.isEmpty { yv = text }
        }
        let fv = String(cString: jt_tool_version())
        var encoders: Set<String>?
        if let f = ffmpegPath, let r = try? await Shell.run(f, ["-hide_banner", "-encoders"], environment: [:]), r.status == 0 {
            encoders = CommandBuilder.parseEncoders(r.stdout)
        }
        let ytdlpText = yv
        let found = encoders
        await MainActor.run {
            self.startProblem = problem
            self.ytdlpVersion = ytdlpText
            self.ffmpegVersion = fv
            CommandBuilder.ffmpegEncoders = found
        }
    }

    /// Downloads the latest yt-dlp release into the app. It takes effect the next time Jethriki starts.
    func updateYtDlp() async -> String {
        do {
            let result = try await YtDlpUpdater.update(current: ytdlpVersion)
            return result
        } catch {
            return error.localizedDescription
        }
    }
}
