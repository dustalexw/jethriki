import AVFoundation
import Combine
import UIKit
import UserNotifications

/// iOS suspends apps soon after they leave the screen, which would freeze a download halfway. While anything is
/// downloading, Jethriki asks for extra background time, and, if "Keep downloading in the background" is on,
/// plays silence so iOS keeps it running until the queue is done. Finished downloads are announced with a
/// notification when the app isn't on screen.
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()
    static let settingKey = "keepRunningInBackground"

    private var task: UIBackgroundTaskIdentifier = .invalid
    private var player: AVAudioPlayer?
    private var observers: [AnyCancellable] = []
    private var timer: AnyCancellable?
    private weak var downloads: DownloadManager?
    private var announced = Set<UUID>()

    func watch(_ downloads: DownloadManager) {
        guard self.downloads == nil else { return }
        self.downloads = downloads
        UserDefaults.standard.register(defaults: [Self.settingKey: true])
        // Jobs are separate objects; checking once a second is simpler than observing each of them.
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.update() }
    }

    private var busy: Bool {
        downloads?.jobs.contains { $0.status.isActive || $0.status == .queued } ?? false
    }

    private func update() {
        announceFinished()
        if busy {
            if task == .invalid {
                task = UIApplication.shared.beginBackgroundTask(withName: "Downloads") { [weak self] in self?.endTask() }
            }
            if UserDefaults.standard.bool(forKey: Self.settingKey) { startSilence() } else { stopSilence() }
        } else {
            stopSilence()
            endTask()
        }
    }

    private func endTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }

    private func startSilence() {
        guard player == nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: Self.silentWAV)
            p.numberOfLoops = -1
            p.volume = 0
            p.play()
            player = p
        } catch {
            player = nil
        }
    }

    private func stopSilence() {
        guard let p = player else { return }
        p.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func announceFinished() {
        guard let jobs = downloads?.jobs else { return }
        for job in jobs where job.status.isDone && !announced.contains(job.id) {
            announced.insert(job.id)
            guard UIApplication.shared.applicationState != .active, job.status != .cancelled else { continue }
            Notifier.post(title: job.status == .finished ? "Downloaded" : job.status.label, body: job.displayTitle)
        }
    }

    /// One second of 8 kHz mono silence.
    private static let silentWAV: Data = {
        let samples = 8000
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples * 2)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples * 2)); d.append(Data(count: samples * 2))
        return d
    }()
}

enum Notifier {
    private static let askedKey = "askedForNotifications"

    static func requestPermissionOnce() {
        guard !UserDefaults.standard.bool(forKey: askedKey) else { return }
        UserDefaults.standard.set(true, forKey: askedKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Links shared to Jethriki from other apps' share sheets wait here (in the app group both share) until the app opens.
enum SharedInbox {
    static let appGroup = "group.com.dustalexw.jethriki"
    private static let key = "sharedLinks"

    static func takeAll() -> [String] {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return [] }
        let links = defaults.stringArray(forKey: key) ?? []
        if !links.isEmpty { defaults.removeObject(forKey: key) }
        return links
    }
}
