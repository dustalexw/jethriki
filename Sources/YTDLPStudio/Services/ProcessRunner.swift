import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct SimpleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Splits a byte stream into lines on \n or \r (yt-dlp and ffmpeg use both).
struct LineBuffer {
    private var bytes: [UInt8] = []

    mutating func append(_ data: Data) -> [String] {
        bytes.append(contentsOf: data)
        var lines: [String] = []
        var start = 0
        for i in 0..<bytes.count where bytes[i] == 0x0A || bytes[i] == 0x0D {
            if i > start { lines.append(String(decoding: bytes[start..<i], as: UTF8.self)) }
            start = i + 1
        }
        if start > 0 { bytes.removeFirst(start) }
        return lines
    }

    mutating func flush() -> String? {
        defer { bytes.removeAll() }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }
}

/// Runs a long-lived process and delivers each output line on the main queue.
final class ProcessRunner {
    private let process = Process()
    private let queue = DispatchQueue(label: "studio.process-runner")
    private var outBuffer = LineBuffer()
    private var errBuffer = LineBuffer()

    /// (line, isStandardError) — always called on the main queue.
    var onLine: ((String, Bool) -> Void)?
    /// Exit status — always called on the main queue, after all output has been delivered.
    var onExit: ((Int32) -> Void)?

    init(executable: String, arguments: [String], environment: [String: String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
    }

    func start() throws {
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let self else { return }
            self.queue.async { self.consume(data, isErr: false) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let self else { return }
            self.queue.async { self.consume(data, isErr: true) }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                self.consume(out.fileHandleForReading.readDataToEndOfFile(), isErr: false)
                self.consume(err.fileHandleForReading.readDataToEndOfFile(), isErr: true)
                // Close the read ends now rather than whenever the Pipe objects are freed, so a long batch
                // of jobs doesn't accumulate open descriptors.
                try? out.fileHandleForReading.close()
                try? err.fileHandleForReading.close()
                var tail: [(String, Bool)] = []
                if let l = self.outBuffer.flush() { tail.append((l, false)) }
                if let l = self.errBuffer.flush() { tail.append((l, true)) }
                let code = proc.terminationStatus
                let finalLines = tail
                DispatchQueue.main.async {
                    for (line, isErr) in finalLines { self.onLine?(line, isErr) }
                    self.onExit?(code)
                }
            }
        }

        try process.run()
    }

    private func consume(_ data: Data, isErr: Bool) {
        guard !data.isEmpty else { return }
        let lines = isErr ? errBuffer.append(data) : outBuffer.append(data)
        guard !lines.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for line in lines { self?.onLine?(line, isErr) }
        }
    }

    var isRunning: Bool { process.isRunning }
    var pid: pid_t { process.processIdentifier }

    /// Every process yt-dlp started (FFmpeg and its helpers), recorded while they are still its descendants,
    /// so they can be stopped even after yt-dlp itself has exited and they have been re-parented.
    private var tree: Set<pid_t> = []

    /// SIGINT first so yt-dlp can stop its own FFmpeg children and tidy up, then SIGTERM, then SIGKILL — the last
    /// two sent to the whole process tree. FFmpeg treats SIGINT and SIGTERM as "flush and finish", which for slow
    /// encoders (AV1, x265 veryslow) can take minutes, so the final kill is essential; and if yt-dlp is killed
    /// first, FFmpeg would otherwise carry on encoding in the background with nobody waiting for it.
    func terminate() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        // The closures hold the runner strongly on purpose: its owner usually lets go of it as soon as yt-dlp exits,
        // and the later steps must still run to stop any FFmpeg that outlived it.
        queue.async {
            self.remember(pid)
            if self.process.isRunning { self.process.interrupt() }
            self.queue.asyncAfter(deadline: .now() + 2) {
                self.signalTree(pid, SIGTERM)
                self.queue.asyncAfter(deadline: .now() + 2) { self.signalTree(pid, SIGKILL) }
            }
        }
    }

    /// Adds the current descendants of `root` (and of every process seen before) to `tree`.
    private func remember(_ root: pid_t) {
        var pending = [root] + Array(tree)
        while let parent = pending.popLast() {
            for child in Self.children(of: parent) where tree.insert(child).inserted { pending.append(child) }
        }
    }

    /// Sends `signal` to the root process, its process group when it leads one, and every descendant seen so far.
    /// Runs even when the root has already exited, because its children may still be running.
    private func signalTree(_ root: pid_t, _ signal: Int32) {
        let rootRunning = process.isRunning
        if rootRunning { remember(root) }
        tree = tree.filter { kill($0, 0) == 0 }
        guard rootRunning || !tree.isEmpty else { return }
        if rootRunning {
            if getpgid(root) == root { kill(-root, signal) }
            kill(root, signal)
        }
        for pid in tree { kill(pid, signal) }
    }

    /// The direct children of a process.
    static func children(of parent: pid_t) -> [pid_t] {
        #if os(macOS)
        // proc_listpids(PROC_PPID_ONLY, …) returns the number of bytes it filled in.
        var pids = [pid_t](repeating: 0, count: 256)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(6 /* PROC_PPID_ONLY */, UInt32(parent), $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 && $0 != parent }
        #else
        // /proc/<pid>/stat: "pid (comm) state ppid …"; comm may itself contain spaces or parentheses.
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return [] }
        return entries.compactMap { entry -> pid_t? in
            guard let pid = pid_t(entry), pid != parent,
                  let stat = try? String(contentsOfFile: "/proc/\(entry)/stat", encoding: .utf8),
                  let close = stat.lastIndex(of: ")") else { return nil }
            let fields = stat[stat.index(after: close)...].split(separator: " ")
            return fields.count > 1 && pid_t(fields[1]) == parent ? pid : nil
        }
        #endif
    }
}

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private final class DataBox {
    var data = Data()
}

enum Shell {
    /// Runs a short-lived process and captures all output (reads both pipes concurrently to avoid deadlock).
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                p.environment = environment
                p.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                continuation.resume(returning: ProcessResult(
                    status: p.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errBox.data, as: UTF8.self)))
            }
        }
    }
}
