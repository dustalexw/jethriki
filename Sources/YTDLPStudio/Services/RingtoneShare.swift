import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Reads the duration from an MPEG-4 file's movie header, so no external tool is needed.
enum MP4 {
    static func durationSeconds(_ data: Data) -> Double? {
        let bytes = [UInt8](data)
        guard let moov = find(bytes, 0, bytes.count, "moov"),
              let mvhd = find(bytes, moov.start, moov.end, "mvhd"), mvhd.end - mvhd.start >= 32 else { return nil }
        let at = mvhd.start, v1 = bytes[at] == 1
        let scale = be(bytes, at + (v1 ? 20 : 12), 4)
        let length = v1 ? be(bytes, at + 24, 8) : be(bytes, at + 16, 4)
        return scale == 0 ? nil : Double(length) / Double(scale)
    }
    private static func be(_ b: [UInt8], _ at: Int, _ n: Int) -> UInt64 {
        (0..<n).reduce(UInt64(0)) { ($0 << 8) | UInt64(b[at + $1]) }
    }
    private static func find(_ b: [UInt8], _ start: Int, _ end: Int, _ type: String) -> (start: Int, end: Int)? {
        var at = start
        while at + 8 <= end {
            var size = Int(be(b, at, 4)), header = 8
            if size == 1 && at + 16 <= end { size = Int(be(b, at + 8, 8)); header = 16 } else if size == 0 { size = end - at }
            guard size >= header, at + size <= end else { return nil }
            if String(bytes: b[(at + 4)..<(at + 8)], encoding: .ascii) == type { return (at + header, at + size) }
            at += size
        }
        return nil
    }
}

/// Reads the duration of an Ogg Vorbis file: the sample rate from the identification header in the first page,
/// and the granule position (total samples) of the last page.
enum Ogg {
    static func durationSeconds(_ data: Data) -> Double? {
        let b = [UInt8](data)
        let magic: [UInt8] = [0x4F, 0x67, 0x67, 0x53]   // "OggS"
        guard b.count > 64, Array(b[0..<4]) == magic else { return nil }
        let payload = 27 + Int(b[26])
        guard payload + 19 <= b.count else { return nil }
        let rate: UInt32, preSkip: UInt64
        if b[payload] == 0x01, Array(b[(payload + 1)..<(payload + 7)]) == Array("vorbis".utf8) {
            rate = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(b[payload + 12 + $1]) << (8 * UInt32($1))) }
            preSkip = 0
        } else if Array(b[payload..<(payload + 8)]) == Array("OpusHead".utf8) {
            // Opus granule positions always count 48 kHz samples, including the encoder's pre-skip.
            rate = 48000
            preSkip = UInt64(b[payload + 10]) | (UInt64(b[payload + 11]) << 8)
        } else { return nil }
        guard rate > 0 else { return nil }
        var at = b.count - 27
        while at > 0 {
            if b[at] == magic[0], b[at + 1] == magic[1], b[at + 2] == magic[2], b[at + 3] == magic[3] {
                let granule = (0..<8).reduce(UInt64(0)) { $0 | (UInt64(b[at + 6 + $1]) << (8 * UInt64($1))) }
                return granule == UInt64.max || granule < preSkip ? nil : Double(granule - preSkip) / Double(rate)
            }
            at -= 1
        }
        return nil
    }
}

/// Edits the iPhone's /iTunes_Control/iTunes/Ringtones.plist:
/// { "Ringtones": { "ABCD.m4r": { "Name": …, "Total Time": ms, … } } }. A tone with the same name is replaced.
enum RingtoneList {
    static let tonesFolder = "/iTunes_Control/Ringtones", listFolder = "/iTunes_Control/iTunes"
    static let listPath = listFolder + "/Ringtones.plist"

    static func add(to existing: Data?, name: String, milliseconds: Int) throws -> (plist: Data, fileName: String) {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty,
           let parsed = try PropertyListSerialization.propertyList(from: existing, format: nil) as? [String: Any] { root = parsed }
        var tones = root["Ringtones"] as? [String: Any] ?? [:]
        let fileName = tones.first { ($0.value as? [String: Any])?["Name"] as? String == name }?.key ?? newFileName(avoiding: tones)
        tones[fileName] = [
            "Name": name, "GUID": (0..<16).map { _ in String("0123456789ABCDEF".randomElement()!) }.joined(),
            "PID": Int64.random(in: Int64.min...Int64.max), "Total Time": milliseconds,
            "Protected Content": false, "Artist": "", "Album": "", "Genre": ""
        ] as [String: Any]
        root["Ringtones"] = tones
        return (try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0), fileName)
    }

    static func names(in plist: Data?) -> [String] {
        guard let plist, !plist.isEmpty,
              let root = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any],
              let tones = root["Ringtones"] as? [String: Any] else { return [] }
        return tones.values.compactMap { ($0 as? [String: Any])?["Name"] as? String }.filter { !$0.isEmpty }.sorted()
    }

    private static func newFileName(avoiding tones: [String: Any]) -> String {
        var name: String
        repeat { name = String((0..<4).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".randomElement()! }) + ".m4r" } while tones[name] != nil
        return name
    }
}

struct RingtoneError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Shares a ringtone with an iPhone on the same Wi-Fi network, with no cable or pairing: the iPhone scans a
/// QR code, downloads the tone in Safari, then taps Share › Use as Ringtone (iOS 26 and later, clips under 30 s).
/// Serves only this one file, at a random address, until `stop()`.
final class RingtoneShare {
    /// iOS 26 refuses "Use as Ringtone" for clips of 30 seconds or more.
    static let maxSeconds = 30.0
    let url: URL
    let seconds: Double
    /// True for an Android .ogg tone, which gets its own download page and has no length limit here.
    let forAndroid: Bool
    var tooLongForShare: Bool { !forAndroid && seconds >= Self.maxSeconds }
    private(set) var downloads = 0
    var onDownload: (() -> Void)?

    private let audio: [UInt8], name: String, fileName: String
    private let token = (0..<24).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
    private var listener: Int32 = -1
    private let lock = NSLock()

    /// The Android page gives notification-sound steps instead of ringtone steps.
    private let notification: Bool

    init(path: String, notification: Bool = false) throws {
        self.notification = notification
        guard let data = FileManager.default.contents(atPath: path) else { throw RingtoneError("Couldn't read \((path as NSString).lastPathComponent).") }
        let android = (path as NSString).pathExtension.lowercased() == "ogg"
        guard let seconds = android ? Ogg.durationSeconds(data) : MP4.durationSeconds(data) else {
            throw RingtoneError("\((path as NSString).lastPathComponent) is not a ringtone Jethriki can share. Download it with the iPhone or Android ringtone preset first.")
        }
        guard let address = Self.localAddress() else { throw RingtoneError("This Mac isn't on a network. Connect it to the same Wi-Fi as your iPhone.") }
        audio = [UInt8](data); self.seconds = seconds; forAndroid = android
        name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        // Files offers "Use as Ringtone" for ordinary audio files, so the tone travels as .m4a (the same bytes as .m4r).
        let safe = String(name.map { $0.isLetter || $0.isNumber || " -_".contains($0) ? $0 : "_" }).trimmingCharacters(in: .whitespaces)
        fileName = (safe.isEmpty ? "Ringtone" : safe) + (android ? ".ogg" : ".m4a")

        let fd = socket(AF_INET, Self.streamType, 0)
        guard fd >= 0 else { throw RingtoneError("Couldn't start sharing on this network.") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0; addr.sin_addr.s_addr = 0
        #if os(macOS)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 && listen(fd, 16) == 0 && getsockname(fd, $0, &size) == 0 }
        }
        guard bound else { close(fd); throw RingtoneError("Couldn't start sharing on this network.") }
        let port = UInt16(bigEndian: addr.sin_port)
        listener = fd
        url = URL(string: "http://\(address):\(port)/\(token)/")!
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue }; return }
                guard let self else { close(client); return }
                DispatchQueue.global().async { self.respond(client) }
            }
        }
    }

    deinit { stop() }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard listener >= 0 else { return }
        shutdown(listener, Int32(SHUT_RDWR)); close(listener); listener = -1
    }

    #if os(Linux)
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    private static let write = Glibc.send
    #else
    private static let streamType = SOCK_STREAM
    private static let write = Darwin.send
    #endif

    /// A private IPv4 address of an active network interface that an iPhone on the same network can reach.
    static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            if address.hasPrefix("169.254.") { continue }
            found.append((String(cString: entry.pointee.ifa_name), address))
        }
        func isPrivate(_ a: String) -> Bool {
            let p = a.split(separator: ".").compactMap { Int($0) }
            return p.count == 4 && (p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168))
        }
        return found.sorted { (isPrivate($0.address) ? 0 : 1, $0.name.hasPrefix("en") ? 0 : 1, $0.name) < (isPrivate($1.address) ? 0 : 1, $1.name.hasPrefix("en") ? 0 : 1, $1.name) }.first?.address
    }

    // MARK: HTTP

    private func respond(_ client: Int32) {
        defer { close(client) }
        #if os(macOS)
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var request = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count < 16_384 {
            let n = recv(client, &buffer, buffer.count, 0)
            if n <= 0 { return }
            request += buffer[0..<n]
            if String(decoding: request, as: UTF8.self).contains("\r\n\r\n") { break }
        }
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            return send(client, "405 Method Not Allowed", "text/plain", Array("Method not allowed".utf8), head: false)
        }
        let head = parts[0] == "HEAD"
        let target = (parts[1].components(separatedBy: "?").first ?? "").removingPercentEncoding ?? ""
        var from: Int?, to: Int?
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
            let spec = range.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            from = spec.first.flatMap { Int($0) }; to = spec.count > 1 ? Int(spec[1]) : nil
        }
        if target == "/\(token)/" {
            send(client, "200 OK", "text/html; charset=utf-8", Array(page().utf8), head: head)
        } else if target == "/\(token)/\(fileName)" {
            let start = min(max(from ?? 0, 0), audio.count - 1), end = min(max(to ?? audio.count - 1, start), audio.count - 1)
            let partial = from != nil || to != nil
            var extra = "Accept-Ranges: bytes\r\nContent-Disposition: attachment; filename=\"\(fileName)\"\r\n"
            if partial { extra += "Content-Range: bytes \(start)-\(end)/\(audio.count)\r\n" }
            send(client, partial ? "206 Partial Content" : "200 OK", forAndroid ? "audio/ogg" : "audio/mp4", Array(audio[start...end]), head: head, extra: extra)
            if !head && end == audio.count - 1 {
                lock.lock(); downloads += 1; lock.unlock()
                DispatchQueue.main.async { self.onDownload?() }
            }
        } else {
            send(client, "404 Not Found", "text/plain", Array("Not found".utf8), head: head)
        }
    }

    private func send(_ client: Int32, _ status: String, _ type: String, _ body: [UInt8], head: Bool, extra: String = "") {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n"
        var out = Array(header.utf8); if !head { out += body }
        #if os(Linux)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        var sent = 0
        while sent < out.count {
            let n = out[sent...].withUnsafeBytes { Self.write(client, $0.baseAddress, $0.count, flags) }
            if n <= 0 { return }
            sent += n
        }
    }

    private func page() -> String {
        func html(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
        let title = html(name), file = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let length = String(format: "%.0f", seconds)
        let steps = notification
            ? "Open <b>Settings</b> › <b>Sound &amp; vibration</b> › <b>Notification sound</b> (Samsung: <b>Notification sounds</b>), tap <b>+</b> or <b>My sounds</b>, and pick the downloaded tone."
            : "Open <b>Settings</b> › <b>Sound &amp; vibration</b> › <b>Phone ringtone</b> (Samsung: <b>Ringtone</b>), tap <b>+</b> or <b>My sounds</b>, and pick the downloaded tone."
        if forAndroid {
            return """
            <!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
            <title>\(title) · Jethriki</title><style>
            :root{color-scheme:light dark;--bg:#f6f4ff;--card:#fff;--text:#1a1033;--muted:#5d5579}
            @media (prefers-color-scheme:dark){:root{--bg:#0d0820;--card:#1a1033;--text:#f3efff;--muted:#b6add6}}
            body{margin:0;background:var(--bg);color:var(--text);font:17px/1.45 system-ui,sans-serif;padding:24px 16px}
            main{max-width:460px;margin:0 auto;background:var(--card);border-radius:22px;padding:24px;box-shadow:0 10px 40px #0002}
            h1{font-size:22px;margin:0 0 4px}p{margin:0 0 16px;color:var(--muted)}ol{padding-left:22px;margin:0 0 8px}li{margin:0 0 10px}
            a.button{display:block;text-align:center;background:linear-gradient(90deg,#7e6eff,#e650dc);color:#fff;text-decoration:none;font-weight:600;padding:15px;border-radius:14px;margin:4px 0 22px}
            </style></head><body><main>
            <h1>\(title)</h1><p>\(notification ? "Notification sound" : "Phone ringtone") from Jethriki · \(length) seconds</p>
            <a class=button href="\(file)" download>Download \(notification ? "tone" : "ringtone")</a>
            <ol><li>Tap <b>Download \(notification ? "tone" : "ringtone")</b>. \(steps)</li></ol>
            </main></body></html>
            """
        }
        let note = tooLongForShare ? "<p class=warn>This tone is \(length) seconds long. iPhone only accepts tones under 30 seconds here, so it may say the file is too long. Send it with a cable from Jethriki instead, or trim it shorter.</p>" : ""
        return """
        <!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
        <title>\(title) · Jethriki</title><style>
        :root{color-scheme:light dark;--bg:#f6f4ff;--card:#fff;--text:#1a1033;--muted:#5d5579}
        @media (prefers-color-scheme:dark){:root{--bg:#0d0820;--card:#1a1033;--text:#f3efff;--muted:#b6add6}}
        body{margin:0;background:var(--bg);color:var(--text);font:17px/1.45 -apple-system,system-ui,sans-serif;padding:24px 16px}
        main{max-width:460px;margin:0 auto;background:var(--card);border-radius:22px;padding:24px;box-shadow:0 10px 40px #0002}
        h1{font-size:22px;margin:0 0 4px}p{margin:0 0 16px;color:var(--muted)}ol{padding-left:22px;margin:0 0 8px}li{margin:0 0 10px}
        a.button{display:block;text-align:center;background:linear-gradient(90deg,#7e6eff,#e650dc);color:#fff;text-decoration:none;font-weight:600;padding:15px;border-radius:14px;margin:4px 0 22px}
        .warn{background:#ffb02022;border-radius:12px;padding:12px;color:var(--text)}
        </style></head><body><main>
        <h1>\(title)</h1><p>Ringtone from Jethriki · \(length) seconds</p>\(note)
        <a class=button href="\(file)" download>Download ringtone</a>
        <ol><li>Tap <b>Download ringtone</b>, then <b>Download</b> if Safari asks.</li>
        <li>Open the <b>Files</b> app › <b>Downloads</b> and tap the tone.</li>
        <li>Tap <b>Share</b>, then <b>Use as Ringtone</b>. It may be under <b>More</b>.</li></ol>
        <p>Needs iOS 26 or later. On older iPhones, send the tone from Jethriki with the cable instead.</p>
        </main></body></html>
        """
    }
}
