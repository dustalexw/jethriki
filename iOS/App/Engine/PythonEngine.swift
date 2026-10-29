import Foundation

/// The Python interpreter and yt-dlp bundled in the app. Starts once, in the background, at launch;
/// every yt-dlp run goes through `runYtDlp`.
final class PythonEngine {
    static let shared = PythonEngine()

    private let started = DispatchGroup()
    private let lock = NSLock()
    private var isStarting = false
    private var failure: String?

    private init() {}

    // MARK: Locations

    static var resources: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }
    /// Placeholder files named yt-dlp, ffmpeg and ffprobe. The desktop code passes tool paths around;
    /// on iOS a path's last component picks the in-app tool that runs.
    static var toolsDirectory: String { resources.appendingPathComponent("tools").path }
    static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jethriki", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var cachesDirectory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yt-dlp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var ffmpegLibrary: String {
        Bundle.main.privateFrameworksURL!.appendingPathComponent("JethrikiFFmpeg.framework/JethrikiFFmpeg").path
    }

    // MARK: Starting

    /// Starts Python in the background. Safe to call more than once.
    func start() {
        lock.lock()
        guard !isStarting else { lock.unlock(); return }
        isStarting = true
        started.enter()
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            self.boot()
            self.started.leave()
        }
    }

    /// Waits until Python is running. Returns why it couldn't start, if it couldn't.
    @discardableResult
    func waitUntilReady() -> String? {
        start()
        started.wait()
        return failure
    }

    private func boot() {
        let resources = Self.resources
        let packages = resources.appendingPathComponent("app_packages")
        setenv("SSL_CERT_FILE", packages.appendingPathComponent("certifi/cacert.pem").path, 1)
        setenv("JETHRIKI_TOOLS_LIB", Self.ffmpegLibrary, 1)
        setenv("JETHRIKI_CACHE_DIR", Self.cachesDirectory.path, 1)
        setenv("XDG_CACHE_HOME", Self.cachesDirectory.deletingLastPathComponent().path, 1)
        setenv("NO_COLOR", "1", 1)
        setenv("PYTHON_COLORS", "0", 1)
        setenv("LANG", "en_US.UTF-8", 1)

        let override = YtDlpUpdater.installedPath
        var error: UnsafePointer<CChar>?
        let home = resources.appendingPathComponent("python").path
        let app = resources.appendingPathComponent("app").path
        let status: Int32
        if let override {
            status = jp_start(home, app, packages.path, override, &error)
        } else {
            status = jp_start(home, app, packages.path, nil, &error)
        }
        if status != 0 {
            failure = error.map { String(cString: $0) } ?? "Python couldn't start."
            // A downloaded yt-dlp that breaks start-up shouldn't lock the user out: drop it for next time.
            if override != nil { YtDlpUpdater.removeInstalled() }
            return
        }
        jp_set_javascript(unsafeBitCast(JavaScriptBridge.run, to: UnsafeMutableRawPointer.self),
                          unsafeBitCast(JavaScriptBridge.release, to: UnsafeMutableRawPointer.self))
    }

    // MARK: Running yt-dlp

    private final class Sink {
        let handler: (String, Bool) -> Void
        init(_ handler: @escaping (String, Bool) -> Void) { self.handler = handler }
    }

    private static let lineCallback: jp_line_callback = { context, line, isError in
        guard let context, let line else { return }
        Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue().handler(String(cString: line), isError != 0)
    }

    private static var nextToken = 0
    static func makeToken() -> Int {
        objc_sync_enter(self); defer { objc_sync_exit(self) }
        nextToken += 1
        return nextToken
    }

    /// Runs yt-dlp and blocks until it exits. `onLine` is called on the calling thread for each output line.
    func runYtDlp(_ arguments: [String], token: Int, onLine: @escaping (String, Bool) -> Void) -> Int32 {
        if let failure = waitUntilReady() {
            onLine("ERROR: yt-dlp couldn't start: \(failure)", true)
            return 127
        }
        let sink = Sink(onLine)
        let context = Unmanaged.passRetained(sink).toOpaque()
        defer { Unmanaged<Sink>.fromOpaque(context).release() }
        return withCStrings(arguments) { argv in
            jp_run_ytdlp(Int32(arguments.count), argv, Self.lineCallback, context, token)
        }
    }

    func cancel(token: Int) {
        guard failure == nil else { return }
        jp_cancel(token)
    }

    var pythonVersion: String { String(cString: jp_python_version()) }
}

/// Calls `body` with a NULL-terminated C array of the strings (valid only during the call).
func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    let copies: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    defer { copies.forEach { free($0) } }
    let pointers: [UnsafePointer<CChar>?] = copies.map { $0.map { UnsafePointer($0) } } + [nil]
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
