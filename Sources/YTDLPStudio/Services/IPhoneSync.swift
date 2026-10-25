#if os(macOS)
import Foundation
import CoreFoundation

/// An iPhone that is connected by cable, or reachable over Wi-Fi sync.
struct IPhoneTarget: Identifiable, Hashable {
    let udid: String
    let name: String
    let iosVersion: String
    let wifi: Bool
    var id: String { udid }
}

/// Sends ringtones to an iPhone through Apple's private MobileDevice.framework (the same one Finder uses).
/// Everything is looked up with dlsym, so a Mac without the framework reports an error instead of crashing.
final class IPhoneSync: ObservableObject {
    static let shared = IPhoneSync()

    @Published private(set) var devices: [IPhoneTarget] = []
    var isAvailable: Bool { lib != nil }

    static let unavailableMessage = "This Mac can't talk to iPhones directly."

    private let lib = MobileDeviceLib()
    private let queue = DispatchQueue(label: "jethriki.iphone-sync")
    private var started = false
    private var subscription: UnsafeMutableRawPointer?
    /// Retained device handles (as integers) and, once read, their details. Main thread only.
    private var known: Set<UInt> = []
    private var targets: [UInt: IPhoneTarget] = [:]

    private init() {}

    /// Starts watching for iPhones. Call on the main thread: callbacks arrive on the subscribing thread's run loop.
    func start() {
        guard !started, let lib else { return }
        started = true
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { info, _ in
            guard let info, let device = info.load(as: UnsafeMutableRawPointer?.self) else { return }
            let message = info.load(fromByteOffset: 8, as: UInt32.self)
            IPhoneSync.shared.event(device: device, message: message)
        }
        var note: UnsafeMutableRawPointer?
        if lib.subscribe(callback, 0, 0, nil, &note) == 0 { subscription = note }
    }

    // MARK: Devices

    private func event(device: UnsafeMutableRawPointer, message: UInt32) {
        guard let lib else { return }
        let key = UInt(bitPattern: device)
        if message == 1 {
            guard !known.contains(key) else { return }
            known.insert(key)
            _ = Unmanaged<AnyObject>.fromOpaque(device).retain()
            queue.async { [weak self] in
                let target = lib.describe(device)
                DispatchQueue.main.async { self?.described(key, target) }
            }
        } else if message == 2 {
            guard known.remove(key) != nil else { return }
            targets[key] = nil
            publish()
            queue.async { Unmanaged<AnyObject>.fromOpaque(device).release() }
        }
    }

    private func described(_ key: UInt, _ target: IPhoneTarget?) {
        guard known.contains(key), let target else { return }
        targets[key] = target
        publish()
    }

    private func publish() {
        var best: [String: IPhoneTarget] = [:]
        for target in targets.values {
            if let current = best[target.udid], !current.wifi || target.wifi { continue }
            best[target.udid] = target
        }
        devices = best.values.sorted { $0.name < $1.name }
    }

    /// The device handle for a udid, preferring the USB connection. Main thread only.
    private func handle(for udid: String) -> UInt? {
        let matches = targets.filter { $0.value.udid == udid }
        return (matches.first { !$0.value.wifi } ?? matches.first)?.key
    }

    // MARK: Actions

    /// Copies the ringtone onto the iPhone and returns its name.
    func install(path: String, on target: IPhoneTarget) async throws -> String {
        try await run(target) { lib, device in try lib.install(device, path: path) }
    }

    /// Restarts the iPhone, which is what makes iOS show newly added tones.
    func restart(_ target: IPhoneTarget) async throws {
        try await run(target) { lib, device in try lib.restart(device) }
    }

    private func run<T>(_ target: IPhoneTarget, _ work: @escaping (MobileDeviceLib, UnsafeMutableRawPointer) throws -> T) async throws -> T {
        guard let lib else { throw RingtoneError(Self.unavailableMessage) }
        let key = await MainActor.run { self.handle(for: target.udid) }
        guard let key, UnsafeMutableRawPointer(bitPattern: key) != nil else {
            throw RingtoneError("\(target.name) isn't connected any more.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work(lib, UnsafeMutableRawPointer(bitPattern: key)!) })
            }
        }
    }
}

/// The dlsym'd MobileDevice functions plus the protocol steps built from them. Used on the serial queue only.
private final class MobileDeviceLib {
    typealias Ptr = UnsafeMutableRawPointer
    typealias Callback = @convention(c) (Ptr?, Ptr?) -> Void

    let subscribe: @convention(c) (Callback, UInt32, UInt32, Ptr?, UnsafeMutablePointer<Ptr?>) -> Int32
    let copyIdentifier: @convention(c) (Ptr) -> Ptr?
    let interfaceType: @convention(c) (Ptr) -> Int32
    let connect: @convention(c) (Ptr) -> Int32
    let isPaired: @convention(c) (Ptr) -> Int32
    let validatePairing: @convention(c) (Ptr) -> Int32
    let startSession: @convention(c) (Ptr) -> Int32
    let stopSession: @convention(c) (Ptr) -> Int32
    let disconnect: @convention(c) (Ptr) -> Int32
    let copyValue: @convention(c) (Ptr, CFString?, CFString) -> Ptr?
    let startService: @convention(c) (Ptr, CFString, CFDictionary?, UnsafeMutablePointer<Ptr?>) -> Int32
    let serviceSocket: @convention(c) (Ptr) -> Int32
    let serviceInvalidate: @convention(c) (Ptr) -> Void
    let serviceSend: @convention(c) (Ptr, CFDictionary, Int) -> Int32
    let serviceReceive: @convention(c) (Ptr, UnsafeMutablePointer<Ptr?>, UnsafeMutablePointer<Int>?) -> Int32
    let afcOpen: @convention(c) (Int32, UInt32, UnsafeMutablePointer<Ptr?>) -> Int32
    let afcClose: @convention(c) (Ptr) -> Int32
    let afcMakeDirectory: @convention(c) (Ptr, UnsafePointer<CChar>) -> Int32
    let fileOpen: @convention(c) (Ptr, UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UInt64>) -> Int32
    let fileRead: @convention(c) (Ptr, UInt64, Ptr, UnsafeMutablePointer<UInt>) -> Int32
    let fileWrite: @convention(c) (Ptr, UInt64, UnsafeRawPointer, UInt) -> Int32
    let fileClose: @convention(c) (Ptr, UInt64) -> Int32

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW) else { return nil }
        func load<T>(_ name: String) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }
        guard let a: @convention(c) (Callback, UInt32, UInt32, Ptr?, UnsafeMutablePointer<Ptr?>) -> Int32 = load("AMDeviceNotificationSubscribe"),
              let b: @convention(c) (Ptr) -> Ptr? = load("AMDeviceCopyDeviceIdentifier"),
              let c: @convention(c) (Ptr) -> Int32 = load("AMDeviceGetInterfaceType"),
              let d: @convention(c) (Ptr) -> Int32 = load("AMDeviceConnect"),
              let e: @convention(c) (Ptr) -> Int32 = load("AMDeviceIsPaired"),
              let f: @convention(c) (Ptr) -> Int32 = load("AMDeviceValidatePairing"),
              let g: @convention(c) (Ptr) -> Int32 = load("AMDeviceStartSession"),
              let h: @convention(c) (Ptr) -> Int32 = load("AMDeviceStopSession"),
              let i: @convention(c) (Ptr) -> Int32 = load("AMDeviceDisconnect"),
              let j: @convention(c) (Ptr, CFString?, CFString) -> Ptr? = load("AMDeviceCopyValue"),
              let k: @convention(c) (Ptr, CFString, CFDictionary?, UnsafeMutablePointer<Ptr?>) -> Int32 = load("AMDeviceSecureStartService"),
              let l: @convention(c) (Ptr) -> Int32 = load("AMDServiceConnectionGetSocket"),
              let m: @convention(c) (Ptr) -> Void = load("AMDServiceConnectionInvalidate"),
              let n: @convention(c) (Ptr, CFDictionary, Int) -> Int32 = load("AMDServiceConnectionSendMessage"),
              let o: @convention(c) (Ptr, UnsafeMutablePointer<Ptr?>, UnsafeMutablePointer<Int>?) -> Int32 = load("AMDServiceConnectionReceiveMessage"),
              let p: @convention(c) (Int32, UInt32, UnsafeMutablePointer<Ptr?>) -> Int32 = load("AFCConnectionOpen"),
              let q: @convention(c) (Ptr) -> Int32 = load("AFCConnectionClose"),
              let r: @convention(c) (Ptr, UnsafePointer<CChar>) -> Int32 = load("AFCDirectoryCreate"),
              let s: @convention(c) (Ptr, UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UInt64>) -> Int32 = load("AFCFileRefOpen"),
              let t: @convention(c) (Ptr, UInt64, Ptr, UnsafeMutablePointer<UInt>) -> Int32 = load("AFCFileRefRead"),
              let u: @convention(c) (Ptr, UInt64, UnsafeRawPointer, UInt) -> Int32 = load("AFCFileRefWrite"),
              let v: @convention(c) (Ptr, UInt64) -> Int32 = load("AFCFileRefClose")
        else { return nil }
        subscribe = a; copyIdentifier = b; interfaceType = c; connect = d; isPaired = e; validatePairing = f
        startSession = g; stopSession = h; disconnect = i; copyValue = j; startService = k; serviceSocket = l
        serviceInvalidate = m; serviceSend = n; serviceReceive = o; afcOpen = p; afcClose = q; afcMakeDirectory = r
        fileOpen = s; fileRead = t; fileWrite = u; fileClose = v
    }

    // MARK: Helpers

    private func check(_ code: Int32, _ message: String) throws {
        guard code != 0 else { return }
        throw RingtoneError("\(message) (error 0x\(String(UInt32(bitPattern: code), radix: 16, uppercase: true)))")
    }

    private func string(_ pointer: Ptr?) -> String? {
        guard let pointer else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue() as? String
    }

    /// Name, iOS version and connection type of a device; nil when it has no identifier.
    func describe(_ device: Ptr) -> IPhoneTarget? {
        guard let udid = string(copyIdentifier(device)) else { return nil }
        var name = "iPhone", version = ""
        if connect(device) == 0 {
            defer { _ = disconnect(device) }
            if isPaired(device) != 0, validatePairing(device) == 0, startSession(device) == 0 {
                defer { _ = stopSession(device) }
                name = string(copyValue(device, nil, "DeviceName" as CFString)) ?? name
                version = string(copyValue(device, nil, "ProductVersion" as CFString)) ?? ""
            }
        }
        return IPhoneTarget(udid: udid, name: name, iosVersion: version, wifi: interfaceType(device) == 2)
    }

    /// Pairing check and service start. The device must already be connected.
    private func openService(_ device: Ptr, _ name: String) throws -> Ptr {
        guard isPaired(device) != 0 else {
            throw RingtoneError("This Mac isn't trusted yet. Connect the iPhone with its cable, unlock it and tap Trust, then try again.")
        }
        try check(validatePairing(device), "Unlock your iPhone and try again")
        try check(startSession(device), "Unlock your iPhone and try again")
        defer { _ = stopSession(device) }
        var connection: Ptr?
        try check(startService(device, name as CFString, nil, &connection), "Unlock your iPhone and try again")
        guard let connection else { throw RingtoneError("The iPhone didn't start the \(name) service.") }
        return connection
    }

    // MARK: Ringtone install

    func install(_ device: Ptr, path: String) throws -> String {
        let fileName = (path as NSString).lastPathComponent
        guard let data = FileManager.default.contents(atPath: path) else { throw RingtoneError("Couldn't read \(fileName).") }
        guard let seconds = MP4.durationSeconds(data) else {
            throw RingtoneError("\(fileName) is not an AAC ringtone. Download it with the iPhone ringtone preset first.")
        }
        guard seconds <= Double(Ringtone.maxSeconds) + 0.5 else {
            throw RingtoneError("This tone is \(Int(seconds)) seconds long. iPhone ringtones can be at most \(Ringtone.maxSeconds) seconds.")
        }
        let name = (fileName as NSString).deletingPathExtension

        try check(connect(device), "Couldn't reach the iPhone. Unlock it and try again")
        defer { _ = disconnect(device) }
        let connection = try openService(device, "com.apple.afc")
        defer { serviceInvalidate(connection) }

        var afcHandle: Ptr?
        try check(afcOpen(serviceSocket(connection), 0, &afcHandle), "Couldn't open the iPhone's files")
        guard let afc = afcHandle else { throw RingtoneError("Couldn't open the iPhone's files.") }
        defer { _ = afcClose(afc) }

        for folder in [RingtoneList.tonesFolder, RingtoneList.listFolder] {
            _ = folder.withCString { afcMakeDirectory(afc, $0) }   // already exists on most iPhones
        }
        let existing = readFile(afc, RingtoneList.listPath)
        let (plist, remoteName) = try RingtoneList.add(to: existing, name: name, milliseconds: Int((seconds * 1000).rounded()))
        try writeFile(afc, RingtoneList.tonesFolder + "/" + remoteName, data)
        try writeFile(afc, RingtoneList.listPath, plist)
        return name
    }

    private func readFile(_ afc: Ptr, _ path: String) -> Data? {
        var ref: UInt64 = 0
        guard path.withCString({ fileOpen(afc, $0, 1, &ref) }) == 0 else { return nil }
        defer { _ = fileClose(afc, ref) }
        var result = Data()
        let capacity = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            var length = UInt(capacity)
            guard fileRead(afc, ref, buffer, &length) == 0, length > 0 else { break }
            result.append(buffer.assumingMemoryBound(to: UInt8.self), count: Int(length))
        }
        return result
    }

    private func writeFile(_ afc: Ptr, _ path: String, _ data: Data) throws {
        var ref: UInt64 = 0
        try check(path.withCString { fileOpen(afc, $0, 3, &ref) }, "Couldn't create a file on the iPhone")
        defer { _ = fileClose(afc, ref) }
        let chunk = 1 << 20
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            let code: Int32 = data.withUnsafeBytes { raw in
                fileWrite(afc, ref, raw.baseAddress! + offset, UInt(end - offset))
            }
            try check(code, "Couldn't copy the tone to the iPhone")
            offset = end
        }
    }

    // MARK: Restart

    func restart(_ device: Ptr) throws {
        try check(connect(device), "Couldn't reach the iPhone. Unlock it and try again")
        defer { _ = disconnect(device) }
        let connection = try openService(device, "com.apple.mobile.diagnostics_relay")
        defer { serviceInvalidate(connection) }

        try check(serviceSend(connection, ["Request": "Restart"] as CFDictionary, 100), "Couldn't ask the iPhone to restart")
        var reply: Ptr?
        try check(serviceReceive(connection, &reply, nil), "The iPhone didn't answer the restart request")
        let answer = reply.flatMap { Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue() as? [String: Any] }
        guard answer?["Status"] as? String == "Success" else { throw RingtoneError("The iPhone refused to restart.") }
        _ = serviceSend(connection, ["Request": "Goodbye"] as CFDictionary, 100)
    }
}
#endif
