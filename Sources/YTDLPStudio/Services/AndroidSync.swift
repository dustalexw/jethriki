import Foundation

/// An Android phone that `adb` can see, by USB or Wi-Fi debugging.
struct AndroidTarget: Identifiable, Hashable {
    let serial: String
    let model: String
    let wifi: Bool
    /// adb's state word: "device" (ready), "unauthorized", "offline", …
    let state: String
    var id: String { serial }
    var ready: Bool { state == "device" }
    var name: String { model.isEmpty ? serial : model }
}

/// Sends ringtones to an Android phone through Google's `adb` command line tool (not bundled with Jethriki).
enum AndroidSync {
    static let missingAdbMessage = "Jethriki needs Google's adb tool to send to Android. Install it with: brew install android-platform-tools"
    static let unauthorizedMessage = "Unlock the phone and tap Allow on the USB debugging prompt, then try again."
    static let noDeviceMessage = "No Android phone found. Turn on Developer options › USB debugging (or Wireless debugging), connect it, and unlock it."
    static let offlineMessage = "The phone is offline. Unplug and reconnect it, or turn Developer options › USB debugging (or Wireless debugging) off and on."

    static let tonesFolder = "/sdcard/Ringtones"
    static let mediaUri = "content://media/external/audio/media"

    // MARK: Finding adb

    static func findAdb() -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        if let override = env["JETHRIKI_ADB"], !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) { return path }
        }
        var dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/Library/Android/sdk/platform-tools"]
        if let sdk = env["ANDROID_HOME"], !sdk.isEmpty { dirs.append(sdk + "/platform-tools") }
        for dir in dirs where !dir.isEmpty {
            let path = (dir as NSString).appendingPathComponent("adb")
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func environment(for adb: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let dir = (adb as NSString).deletingLastPathComponent
        env["PATH"] = [dir, env["PATH"] ?? "", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].filter { !$0.isEmpty }.joined(separator: ":")
        return env
    }

    private static func requireAdb() throws -> String {
        guard let adb = findAdb() else { throw RingtoneError(missingAdbMessage) }
        return adb
    }

    private static func adb(_ path: String, _ args: [String]) async throws -> ProcessResult {
        try await Shell.run(path, args, environment: environment(for: path))
    }

    // MARK: Devices

    /// Parses `adb devices -l`: "SERIAL   device usb:1-1 product:x model:Pixel_7 device:y transport_id:1".
    static func parseDevices(_ output: String) -> [AndroidTarget] {
        var result: [AndroidTarget] = []
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("*") || line.hasPrefix("List of devices") { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { continue }
            let serial = fields[0], state = fields[1]
            var model = ""
            for field in fields.dropFirst(2) where field.hasPrefix("model:") {
                model = String(field.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
            }
            result.append(AndroidTarget(serial: serial, model: model, wifi: isWifiSerial(serial), state: state))
        }
        return result
    }

    private static func isWifiSerial(_ serial: String) -> Bool {
        if serial.contains("._adb-tls-connect._tcp") { return true }
        guard let colon = serial.lastIndex(of: ":") else { return false }
        let port = serial[serial.index(after: colon)...]
        return colon != serial.startIndex && !port.isEmpty && port.allSatisfy { $0.isNumber }
    }

    static func list() async throws -> [AndroidTarget] {
        let path = try requireAdb()
        let r = try await adb(path, ["devices", "-l"])
        guard r.status == 0 else {
            throw RingtoneError("adb couldn't list devices. " + firstLine(r.stderr + r.stdout))
        }
        return parseDevices(r.stdout)
    }

    // MARK: Wireless debugging

    /// `adb pair HOST:PORT CODE`, using the address and code shown under Wireless debugging › Pair device with pairing code.
    static func pair(hostPort: String, code: String) async throws -> String {
        let path = try requireAdb()
        let address = hostPort.trimmingCharacters(in: .whitespaces), code = code.trimmingCharacters(in: .whitespaces)
        guard address.contains(":"), !code.isEmpty else {
            throw RingtoneError("Enter the pairing address (like 192.168.1.20:37045) and the 6-digit pairing code.")
        }
        let r = try await adb(path, ["pair", address, code])
        let text = (r.stdout + "\n" + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, text.lowercased().contains("successfully paired") else {
            throw RingtoneError("Pairing failed. " + (firstLine(text).isEmpty ? "Check the address and code on the phone." : firstLine(text)))
        }
        return firstLine(text)
    }

    /// `adb connect HOST:PORT`. adb exits 0 even when it fails, so the output decides.
    static func connect(hostPort: String) async throws -> String {
        let path = try requireAdb()
        let address = hostPort.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { throw RingtoneError("Enter the phone's IP address and port from the Wireless debugging screen.") }
        let r = try await adb(path, ["connect", address])
        let text = (r.stdout + "\n" + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if r.status != 0 || lower.contains("failed to connect") || lower.contains("cannot connect") || lower.contains("unable to connect") {
            throw RingtoneError("Couldn't connect to \(address). " + firstLine(text))
        }
        return firstLine(text)
    }

    // MARK: Sending

    /// Copies the tone to the phone's Ringtones folder, lets Android index it, and optionally makes it the phone ringtone.
    /// Returns the tone's name.
    static func sendRingtone(path: String, to target: AndroidTarget, setAsRingtone: Bool,
                             notification: Bool = false,
                             log: @escaping (String) -> Void = { _ in }) async throws -> String {
        let adbPath = try requireAdb()
        let fileName = (path as NSString).lastPathComponent
        let ext = (path as NSString).pathExtension.lowercased()
        guard ["ogg", "mp3", "m4a"].contains(ext) else {
            throw RingtoneError("\(fileName) isn't a tone Android can use. Download it with the Android ringtone preset first.")
        }
        guard FileManager.default.isReadableFile(atPath: path) else { throw RingtoneError("Couldn't read \(fileName).") }
        switch target.state {
        case "device": break
        case "unauthorized": throw RingtoneError(unauthorizedMessage)
        default: throw RingtoneError(offlineMessage)
        }

        let toneName = (remoteName(fileName) as NSString).deletingPathExtension
        let name = remoteName(fileName)
        let base = ["-s", target.serial]

        func shell(_ command: String) async throws -> ProcessResult {
            log("adb shell \(command)")
            return try await adb(adbPath, base + ["shell", command])
        }

        let folder = notification ? "/sdcard/Notifications" : tonesFolder
        let scanFolder = notification ? "/storage/emulated/0/Notifications" : "/storage/emulated/0/Ringtones"
        let mkdir = try await shell("mkdir -p \(quote(folder))")
        try failIfDeviceError(mkdir, "Couldn't open the phone's Ringtones folder.")

        // Pushed under a hidden temporary name, checked, then renamed: a cable pulled or Wi-Fi dropped mid-copy
        // never leaves a half-written tone for Android to list in its sound picker.
        let part = folder + "/." + name + ".jethriki-part"
        log("adb push \(fileName)")
        do {
            let push = try await adb(adbPath, base + ["push", path, part])
            try failIfDeviceError(push, "Couldn't copy the tone to the phone.")
            let size = try await shell("stat -c %s \(quote(part))")
            let local = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
            guard size.status == 0, let local, Int(size.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == local else {
                throw RingtoneError("The tone arrived incomplete on the phone. Check the cable or Wi-Fi connection and try again.")
            }
            let move = try await shell("mv -f \(quote(part)) \(quote(folder + "/" + name))")
            try failIfDeviceError(move, "The phone wouldn't save the tone.")
        } catch {
            _ = try? await adb(adbPath, base + ["shell", "rm -f \(quote(part))"])
            throw error
        }

        // Ask Android to index the new file; some versions print an error here even though scanning works.
        let scan = try? await shell("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(quote("file://" + scanFolder + "/" + name))")
        if let scan, scan.status != 0 { log("media scan: \(firstLine(scan.stderr + scan.stdout))") }

        var mediaId: Int?
        for attempt in 0..<10 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
            let query = try? await shell("content query --uri \(mediaUri) --projection _id --where \(quote("_display_name='\(name)'"))")
            if let query, query.status == 0, let id = parseMediaId(query.stdout) { mediaId = id; break }
        }

        if setAsRingtone {
            guard let id = mediaId else {
                throw RingtoneError("The tone is on the phone, but Android hasn't added it to its sound list yet. Wait a moment and try again, or pick it in Settings › Sound.")
            }
            let setting = notification ? "notification_sound" : "ringtone"
            let put = try await shell("settings put system \(setting) \(mediaUri)/\(id)")
            try failIfDeviceError(put, notification ? "Couldn't set the notification sound." : "Couldn't set the phone ringtone.")
            // Marks the file as a ringtone / notification so it shows in the picker; not every Android version allows this.
            let column = notification ? "is_notification" : "is_ringtone"
            let flag = try? await shell("content update --uri \(mediaUri)/\(id) --bind \(column):i:1")
            if let flag, flag.status != 0 { log("\(column): \(firstLine(flag.stderr + flag.stdout))") }
        }
        return toneName
    }

    // MARK: Helpers

    /// File name as stored on the phone: letters, digits and a few separators only, so it is safe inside shell commands.
    static func remoteName(_ fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let stem = (fileName as NSString).deletingPathExtension
        var safe = String(stem.map { $0.isLetter || $0.isNumber || " -_.()".contains($0) ? $0 : "_" })
            .trimmingCharacters(in: .whitespaces)
        if safe.isEmpty { safe = "Ringtone" }
        return safe + "." + ext
    }

    /// Wraps text in single quotes for the phone's shell.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The highest `_id=N` in `content query` output ("Row: 0 _id=42").
    static func parseMediaId(_ output: String) -> Int? {
        var best: Int?
        for line in output.components(separatedBy: .newlines) {
            guard let range = line.range(of: "_id=") else { continue }
            let digits = line[range.upperBound...].prefix { $0.isNumber }
            if let id = Int(digits) { best = max(best ?? id, id) }
        }
        return best
    }

    private static func failIfDeviceError(_ r: ProcessResult, _ message: String) throws {
        guard r.status != 0 else { return }
        let text = (r.stderr + "\n" + r.stdout).lowercased()
        if text.contains("unauthorized") { throw RingtoneError(unauthorizedMessage) }
        if text.contains("offline") { throw RingtoneError(offlineMessage) }
        if text.contains("no devices") || text.contains("not found") { throw RingtoneError(noDeviceMessage) }
        let detail = firstLine(r.stderr + "\n" + r.stdout)
        throw RingtoneError(detail.isEmpty ? message : "\(message) \(detail)")
    }

    private static func firstLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }
}
