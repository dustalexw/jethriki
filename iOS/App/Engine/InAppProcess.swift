import Foundation
import JethrikiFFmpeg

/// iOS stand-ins for the desktop app's ProcessRunner and Shell. iOS apps can't start other programs, so the
/// "executable" path only names the tool (yt-dlp, ffmpeg or ffprobe, see PythonEngine.toolsDirectory) and the
/// tool runs inside the app: yt-dlp in the embedded Python, ffmpeg and ffprobe through JethrikiFFmpeg.
/// The interface and timing match the desktop classes, so DownloadManager and friends work unchanged.
enum InAppTool {
    case ytdlp, ffmpeg, ffprobe

    init?(executable: String) {
        switch (executable as NSString).lastPathComponent {
        case "yt-dlp": self = .ytdlp
        case "ffmpeg": self = .ffmpeg
        case "ffprobe": self = .ffprobe
        default: return nil
        }
    }

    /// Runs ffmpeg or ffprobe and blocks until it exits, passing on what it writes to standard output and error.
    static func runFFmpeg(_ name: String, _ arguments: [String],
                          onOutput: @escaping (Data) -> Void, onError: @escaping (Data) -> Void) -> Int32 {
        let out = Pipe(), err = Pipe()
        let readers = DispatchGroup()
        for (pipe, handler) in [(out, onOutput), (err, onError)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                let handle = pipe.fileHandleForReading
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    handler(data)
                }
                readers.leave()
            }
        }
        let nullInput = open("/dev/null", O_RDONLY)
        let status = withCStrings([name] + arguments) { argv in
            jt_tool_run(name, Int32(arguments.count + 1), argv, nullInput,
                        out.fileHandleForWriting.fileDescriptor, err.fileHandleForWriting.fileDescriptor)
        }
        close(nullInput)
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        readers.wait()
        try? out.fileHandleForReading.close()
        try? err.fileHandleForReading.close()
        return status
    }
}

/// Runs a long-lived tool and delivers each output line on the main queue.
final class ProcessRunner {
    private let executable: String
    private let arguments: [String]
    private let token = PythonEngine.makeToken()
    private let tool: InAppTool?
    private var running = false
    private let stateLock = NSLock()

    /// (line, isStandardError) — always called on the main queue.
    var onLine: ((String, Bool) -> Void)?
    /// Exit status — always called on the main queue, after all output has been delivered.
    var onExit: ((Int32) -> Void)?

    init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        tool = InAppTool(executable: executable)
    }

    func start() throws {
        guard let tool else {
            throw SimpleError("\((executable as NSString).lastPathComponent) can't run on iOS.")
        }
        setRunning(true)
        let thread = Thread { [self] in
            let status: Int32
            switch tool {
            case .ytdlp:
                status = PythonEngine.shared.runYtDlp(arguments, token: token) { [weak self] line, isError in
                    DispatchQueue.main.async { self?.onLine?(line, isError) }
                }
            case .ffmpeg, .ffprobe:
                let lock = NSLock()
                var outBuffer = LineBuffer(), errBuffer = LineBuffer()
                func deliver(_ data: Data, _ isError: Bool) {
                    lock.lock()
                    let lines = isError ? errBuffer.append(data) : outBuffer.append(data)
                    lock.unlock()
                    guard !lines.isEmpty else { return }
                    DispatchQueue.main.async { [weak self] in lines.forEach { self?.onLine?($0, isError) } }
                }
                status = InAppTool.runFFmpeg(tool == .ffmpeg ? "ffmpeg" : "ffprobe", arguments,
                                             onOutput: { deliver($0, false) }, onError: { deliver($0, true) })
                let tail = [outBuffer.flush().map { ($0, false) }, errBuffer.flush().map { ($0, true) }].compactMap { $0 }
                DispatchQueue.main.async { [weak self] in tail.forEach { self?.onLine?($0.0, $0.1) } }
            }
            self.setRunning(false)
            DispatchQueue.main.async { self.onExit?(status) }
        }
        thread.name = "jethriki-\((executable as NSString).lastPathComponent)"
        thread.stackSize = 8 << 20   // FFmpeg and Python both like deep stacks
        thread.start()
    }

    private func setRunning(_ value: Bool) { stateLock.lock(); running = value; stateLock.unlock() }

    var isRunning: Bool { stateLock.lock(); defer { stateLock.unlock() }; return running }
    var pid: Int32 { Int32(truncatingIfNeeded: token) }

    /// Stops the tool the way Ctrl-C would: yt-dlp gets an interrupt (which also stops its FFmpeg), ffmpeg
    /// finishes writing what it has.
    func terminate() {
        guard isRunning else { return }
        switch tool {
        case .ytdlp?: PythonEngine.shared.cancel(token: token)
        case .ffmpeg?: jt_tool_cancel()
        default: break
        }
    }
}

enum Shell {
    /// Runs a short-lived tool and captures all of its output.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        guard let tool = InAppTool(executable: executable) else {
            throw SimpleError("\((executable as NSString).lastPathComponent) can't run on iOS.")
        }
        return await withCheckedContinuation { continuation in
            let thread = Thread {
                let lock = NSLock()
                var out = Data(), err = Data()
                let status: Int32
                switch tool {
                case .ytdlp:
                    var outText = "", errText = ""
                    status = PythonEngine.shared.runYtDlp(arguments, token: PythonEngine.makeToken()) { line, isError in
                        if isError { errText += line + "\n" } else { outText += line + "\n" }
                    }
                    out = Data(outText.utf8); err = Data(errText.utf8)
                case .ffmpeg, .ffprobe:
                    status = InAppTool.runFFmpeg(tool == .ffmpeg ? "ffmpeg" : "ffprobe", arguments,
                                                 onOutput: { d in lock.lock(); out.append(d); lock.unlock() },
                                                 onError: { d in lock.lock(); err.append(d); lock.unlock() })
                }
                continuation.resume(returning: ProcessResult(status: status,
                                                             stdout: String(decoding: out, as: UTF8.self),
                                                             stderr: String(decoding: err, as: UTF8.self)))
            }
            thread.stackSize = 8 << 20
            thread.start()
        }
    }
}
