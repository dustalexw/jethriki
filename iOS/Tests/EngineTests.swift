import XCTest
import JethrikiFFmpeg
@testable import Jethriki

/// End-to-end checks of what runs inside the iOS app: FFmpeg as a library, Python with yt-dlp, the
/// JavaScriptCore runtime, and the shared DownloadManager driving them with the real presets. Test media is
/// generated with the in-app FFmpeg and downloaded through file:// links, so nothing depends on the network.
final class EngineTests: XCTestCase {
    static var work: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jethriki-tests", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static var clip: URL { work.appendingPathComponent("song.mp4") }
    /// Trimming downloads only part of a file, which yt-dlp does over HTTP with range requests, not file://.
    /// The app's Wi-Fi share server serves the clip that way.
    static var server: RingtoneShare?
    static func servedClip() throws -> URL {
        if server == nil { server = try RingtoneShare(path: clip.path) }
        return server!.url.appendingPathComponent("song.m4a")
    }
    let ffmpeg = (PythonEngine.toolsDirectory as NSString).appendingPathComponent("ffmpeg")
    let ffprobe = (PythonEngine.toolsDirectory as NSString).appendingPathComponent("ffprobe")
    let ytdlp = (PythonEngine.toolsDirectory as NSString).appendingPathComponent("yt-dlp")

    override class func setUp() {
        super.setUp()
        XCTAssertNil(PythonEngine.shared.waitUntilReady(), "Python starts")
    }

    private func run(_ tool: String, _ args: [String]) async throws -> ProcessResult {
        try await Shell.run(tool, args, environment: [:])
    }

    private func duration(_ path: String) async throws -> Double {
        let r = try await run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path])
        return Double(r.stdout.trimmed) ?? -1
    }

    /// 50 seconds of a test pattern with a tone, H.264 + AAC: longer than a ringtone may be.
    private func makeClip() async throws {
        if FileManager.default.fileExists(atPath: Self.clip.path) { return }
        let r = try await run(ffmpeg, ["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15:duration=50",
                                       "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=50",
                                       "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-shortest",
                                       "-metadata", "title=Test Song", "-metadata", "artist=Jethriki", Self.clip.path])
        XCTAssertEqual(r.status, 0, r.stderr)
    }

    // MARK: FFmpeg

    func testFFmpegHasTheDesktopEncoders() async throws {
        let r = try await run(ffmpeg, ["-hide_banner", "-encoders"])
        XCTAssertEqual(r.status, 0)
        let encoders = CommandBuilder.parseEncoders(r.stdout)
        for name in ["libx264", "libx265", "libvpx-vp9", "libsvtav1", "libmp3lame", "libvorbis", "libopus",
                     "aac", "alac", "flac", "h264_videotoolbox", "hevc_videotoolbox"] {
            XCTAssertTrue(encoders.contains(name), "FFmpeg has \(name)")
        }
        XCTAssertFalse(String(cString: jt_tool_version()).isEmpty)
    }

    func testFFmpegRunsRepeatedlyWithFreshOptions() async throws {
        let target = Self.work.appendingPathComponent("tone.wav").path
        let first = try await run(ffmpeg, ["-y", "-v", "error", "-f", "lavfi", "-i", "sine=duration=1", target])
        XCTAssertEqual(first.status, 0, first.stderr)
        // -y from the first run must not carry over: without it, an existing file is refused.
        let second = try await run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=duration=1", target])
        XCTAssertTrue(second.stderr.contains("already exists"), second.stderr)
        let probe = try await run(ffprobe, ["-v", "error", "-show_format", "-of", "json", target])
        XCTAssertEqual(probe.status, 0)
        XCTAssertTrue(probe.stdout.contains("\"format_name\": \"wav\""), probe.stdout)
        let missing = try await run(ffprobe, ["-v", "error", "/no/such/file"])
        XCTAssertNotEqual(missing.status, 0)
    }

    func testCancellingFFmpegStopsIt() throws {
        let runner = ProcessRunner(executable: ffmpeg, arguments: [
            "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=600", "-c:v", "libx264", "-f", "null", "-"],
            environment: [:])
        let exited = expectation(description: "ffmpeg exits")
        var status: Int32 = -1
        runner.onExit = { status = $0; exited.fulfill() }
        try runner.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { runner.terminate() }
        wait(for: [exited], timeout: 30)
        XCTAssertEqual(status, 255)
    }

    // MARK: Python, yt-dlp and JavaScript

    func testYtDlpRuns() async throws {
        let r = try await run(ytdlp, ["--version"])
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertFalse(r.stdout.trimmed.isEmpty)
        let bad = try await run(ytdlp, ["--no-such-option"])
        XCTAssertEqual(bad.status, 2)
    }

    func testJavaScriptCoreRunsTheChallengeSolver() async throws {
        XCTAssertEqual(JavaScriptBridge.evaluate("console.log(6 * 7)").output, "42")
        XCTAssertNotNil(JavaScriptBridge.evaluate("throw new Error('boom')").error)
        // yt-dlp lists the in-app runtime when it starts.
        let r = try await run(ytdlp, ["-v", "--simulate", "--no-cache-dir", "https://example.invalid/x"])
        XCTAssertTrue(r.stderr.contains("JS runtimes: jsc"), r.stderr)
        // The real solver script loads and defines its entry point.
        let packages = PythonEngine.resources.appendingPathComponent("app_packages/yt_dlp_ejs/yt/solver")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: packages.path)) ?? []
        let lib = files.first { $0.hasSuffix("lib.min.js") || $0.hasSuffix("lib.js") }
        let core = files.first { $0.hasSuffix("core.min.js") || $0.hasSuffix("core.js") }
        if let lib, let core {
            let script = try String(contentsOf: packages.appendingPathComponent(lib)) + "\nObject.assign(globalThis, lib);\n"
                + String(contentsOf: packages.appendingPathComponent(core)) + "\nconsole.log(typeof jsc);"
            let result = JavaScriptBridge.evaluate(script)
            XCTAssertNil(result.error)
            XCTAssertEqual(result.output, "function")
        }
    }

    // MARK: Downloads through the shared DownloadManager

    @MainActor
    private func download(_ preset: String, edit: (inout DownloadOptions) -> Void = { _ in }) async throws -> DownloadJob {
        try await makeClip()
        var link = Self.clip.absoluteString
        var options = OptionsStore.builtInPresets.first { $0.name == preset }?.options ?? DownloadOptions()
        options.outputDirectory = Self.work.appendingPathComponent(preset.replacingOccurrences(of: " ", with: "-")).path
        options.extraArgs = "--enable-file-urls"
        edit(&options)
        if options.trimEnabled { link = try Self.servedClip().absoluteString }
        let manager = DownloadManager()
        let tools = ToolLocator()
        manager.enqueue(urls: [link], options: options, tools: tools.snapshot()!)
        let job = manager.jobs[0]
        let deadline = Date().addingTimeInterval(300)
        while !job.status.isDone && Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
        XCTAssertTrue(job.status == .finished, "\(preset): \(job.status.label)\n" + job.log.suffix(40).joined(separator: "\n"))
        return job
    }

    func testMP3Preset() async throws {
        let job = try await download("MP3 320 kbps")
        let file = try XCTUnwrap(job.outputFiles.first { $0.hasSuffix(".mp3") })
        let seconds = try await duration(file)
        XCTAssertEqual(seconds, 50, accuracy: 1)
    }

    func testIPhoneRingtonePreset() async throws {
        let job = try await download("iPhone ringtone · M4R")
        let file = try XCTUnwrap(job.outputFiles.first { $0.hasSuffix(".m4r") }, job.log.joined(separator: "\n"))
        let seconds = try await duration(file)
        XCTAssertLessThanOrEqual(seconds, Double(Ringtone.maxSeconds))
        XCTAssertGreaterThan(seconds, 20)
    }

    func testAndroidRingtonePreset() async throws {
        let job = try await download("Android ringtone · OGG")
        let file = try XCTUnwrap(job.outputFiles.first { $0.hasSuffix(".ogg") }, job.log.joined(separator: "\n"))
        let r = try await run(ffprobe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=codec_name", "-of", "csv=p=0", file])
        XCTAssertEqual(r.stdout.trimmed, "vorbis")
    }

    func testVideoReEncode() async throws {
        let job = try await download("Compatible MP4 · H.264 · 1080p") { o in
            o.encodeEnabled = true
            o.encoder = .x264
            o.preset = .ultrafast
        }
        let encoded = try XCTUnwrap(job.outputFiles.first { $0.contains(".encoded.") }, job.log.joined(separator: "\n"))
        let r = try await run(ffprobe, ["-v", "error", "-select_streams", "v", "-show_entries", "stream=codec_name,height", "-of", "csv=p=0", encoded])
        XCTAssertEqual(r.stdout.trimmed, "h264,240")
    }

    func testTrimmedSection() async throws {
        let job = try await download("Compatible MP4 · H.264 · 1080p") { o in
            o.trimEnabled = true
            o.trimStart = "00:00:05"
            o.trimEnd = "00:00:15"
        }
        let file = try XCTUnwrap(job.outputFiles.first)
        let seconds = try await duration(file)
        XCTAssertEqual(seconds, 10, accuracy: 1.5)
    }

    @MainActor
    func testCancellingADownload() async throws {
        try await makeClip()
        var options = DownloadOptions()
        options.mode = .audio
        options.audioFormat = .flac
        options.outputDirectory = Self.work.appendingPathComponent("cancel").path
        // Looping the audio for 10 hours keeps FFmpeg busy far longer than any computer needs to cancel it.
        options.extraArgs = "--enable-file-urls --postprocessor-args \"ExtractAudio:-af aloop=loop=-1:size=2e9,atrim=end=36000\""
        let manager = DownloadManager()
        manager.enqueue(urls: [Self.clip.absoluteString], options: options, tools: ToolLocator().snapshot()!)
        let job = manager.jobs[0]
        // Cancel once FFmpeg is converting, rather than after a fixed wait a fast Mac can outrun.
        let started = Date().addingTimeInterval(60)
        while !job.log.contains(where: { $0.contains("[ExtractAudio] Destination") }) && !job.status.isDone && Date() < started {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        manager.cancel(job)
        let deadline = Date().addingTimeInterval(30)
        while !job.status.isDone && Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
        XCTAssertEqual(job.status, .cancelled, job.log.suffix(20).joined(separator: "\n"))
    }
}
