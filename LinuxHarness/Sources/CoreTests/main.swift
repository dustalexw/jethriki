import Foundation
@testable import Core

// MARK: - Tiny test framework

var passed = 0, failed = 0
func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if cond { passed += 1; print("  ✓ \(name)") }
    else { failed += 1; print("  ✗ \(name)  \(detail())") }
}
func section(_ s: String) { print("\n▸ \(s)") }

func blocking<T>(_ op: @escaping () async throws -> T) -> Result<T, Error> {
    let sem = DispatchSemaphore(value: 0)
    var res: Result<T, Error>!
    Task.detached { do { res = .success(try await op()) } catch { res = .failure(error) }; sem.signal() }
    sem.wait()
    return res
}

func runSync(_ exe: String, _ args: [String]) -> ProcessResult {
    (try? blocking { try await Shell.run(exe, args, environment: ProcessInfo.processInfo.environment) }.get())
        ?? ProcessResult(status: -1, stdout: "", stderr: "launch failed")
}

/// Pump the main run loop until the condition is true or we time out.
func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !cond() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return cond()
}

struct Probe {
    let vcodec: String?, acodec: String?, height: Int?, channels: Int?, sampleRate: Int?, duration: Double?
}
func probe(_ path: String) -> Probe {
    let r = runSync("/usr/bin/ffprobe", ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", path])
    let obj = (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8))) as? [String: Any] ?? [:]
    let streams = obj["streams"] as? [[String: Any]] ?? []
    let v = streams.first {
        ($0["codec_type"] as? String) == "video" &&
        ((($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) ?? 0) == 0
    }
    let a = streams.first { ($0["codec_type"] as? String) == "audio" }
    return Probe(vcodec: v?["codec_name"] as? String,
                 acodec: a?["codec_name"] as? String,
                 height: v?["height"] as? Int,
                 channels: a?["channels"] as? Int,
                 sampleRate: Int((a?["sample_rate"] as? String) ?? ""),
                 duration: Double(((obj["format"] as? [String: Any])?["duration"] as? String) ?? ""))
}

let url = "http://127.0.0.1:8766/clip.mp4"   // Range-capable server, like real video hosts
let outRoot = "/tmp/studio-out"
try? FileManager.default.removeItem(atPath: outRoot)
UserDefaults.standard.register(defaults: ["maxConcurrent": 3, "playSound": false])

// MARK: - 1. Pure helpers

section("Tokenizer, quoting, line buffer")
check(CommandBuilder.tokenize(#"--match-filter "duration < 600" --geo-bypass 'a b' c\ d"#)
      == ["--match-filter", "duration < 600", "--geo-bypass", "a b", "c d"], "shell-style tokenizer")
check(CommandBuilder.shellQuote("plain-arg") == "plain-arg", "safe args stay unquoted")
check(CommandBuilder.shellQuote("it's %(title)s") == #"'it'\''s %(title)s'"#, "single quotes escaped")
var lb = LineBuffer()
let l1 = lb.append(Data("abc\r[dl] 1%\npart".utf8))
let l2 = lb.append(Data("ial\n".utf8))
check(l1 == ["abc", "[dl] 1%"] && l2 == ["partial"], "LineBuffer splits on CR and LF, holds partial lines")

// MARK: - 2. Tool detection

section("Tool detection")
let tools = ToolLocator()
check(tools.ytdlpPath != nil, "found yt-dlp at \(tools.ytdlpPath ?? "nil")")
check(tools.ffmpegPath != nil, "found ffmpeg at \(tools.ffmpegPath ?? "nil")")
_ = waitUntil(15) { tools.ytdlpVersion != "—" && tools.ffmpegVersion != "—" }
check(tools.ytdlpVersion.first?.isNumber == true, "read yt-dlp version: \(tools.ytdlpVersion)")
check(tools.ffmpegVersion != "—" && tools.ffmpegVersion != "Not found", "read ffmpeg version: \(tools.ffmpegVersion.prefix(30))")
guard let snap = tools.snapshot() else { print("cannot continue without tools"); exit(1) }

// MARK: - 3. Every preset + edge configs must be accepted by yt-dlp's own parser

section("yt-dlp accepts every generated command (--simulate)")
var configs: [(String, DownloadOptions)] = OptionsStore.builtInPresets.map { ($0.name, $0.options) }
do {
    var o = DownloadOptions(); o.mode = .videoOnly; o.container = .webm; o.fpsLimit = .fps30; o.videoCodec = .vp9
    configs.append(("Video-only WebM", o))
    o = DownloadOptions(); o.mode = .audio; o.audioFormat = .opus; o.normalizeAudio = true; o.volumeDB = -3.5
    o.sampleRate = .r48000; o.channels = .mono
    configs.append(("Audio with every filter", o))
    o = DownloadOptions(); o.writeSubs = true; o.writeAutoSubs = true; o.subFormat = .ass; o.embedSubs = true
    o.trimEnabled = true; o.trimStart = "5"; o.trimEnd = "1:00"; o.forceKeyframes = true
    o.sponsorBlockMode = .mark; o.sponsorCategories = Array(SponsorCategory.allCases)
    o.removeChaptersRegex = "(?i)intro"; o.thumbnailFormat = .png; o.writeThumbnail = true
    o.playlistMode = .full; o.playlistItems = "1-5,8"; o.rateLimit = "5M"; o.retries = 3; o.sleepInterval = 5
    o.filenameTemplate = .playlistFolder; o.restrictFilenames = true
    o.customPPA = "Merger+ffmpeg_o:-metadata comment=test"
    o.extraArgs = #"--match-filter "duration < 3600" --geo-bypass"#
    configs.append(("Kitchen sink (subs, trim, SponsorBlock, playlist, network…)", o))
    o = DownloadOptions(); o.sponsorBlockMode = .remove; o.sponsorCategories = Array(SponsorCategory.allCases)
    configs.append(("SponsorBlock remove, all categories", o))
    o = DownloadOptions(); o.filenameTemplate = .dateTitle; o.customFormat = "b"; o.customSort = "res,+size"
    configs.append(("Custom -f / -S", o))
}
for (name, o) in configs {
    var opts = o; opts.outputDirectory = outRoot + "/simulate"
    let args = ["--simulate"] + CommandBuilder.arguments(for: opts, urls: [url], ffmpegLocation: "/usr/bin")
    let r = runSync(snap.ytdlp, args)
    let tail = r.stderr.split(separator: "\n").suffix(2).joined(separator: " | ")
    check(r.status == 0 && !r.stderr.contains("yt-dlp: error:"), name, tail)
}

// MARK: - 4. Analyze

section("Analyze (MetadataFetcher)")
switch blocking({ try await MetadataFetcher.fetch(url: url, tools: snap, cookieBrowser: .none) }) {
case .success(let info):
    check(!info.formats.isEmpty, "lists formats (\(info.formats.count)), title “\(info.title)”")
    check(!info.isPlaylist, "detected single video")
case .failure(let e):
    check(false, "fetched metadata", e.localizedDescription)
}
if case .failure(let e) = blocking({ try await MetadataFetcher.fetch(url: "http://127.0.0.1:8766/missing.mp4", tools: snap, cookieBrowser: .none) }) {
    check(!e.localizedDescription.isEmpty, "bad link surfaces an error: \(e.localizedDescription.prefix(60))")
} else { check(false, "bad link should fail") }

// MARK: - 5. End-to-end through the real DownloadManager

let manager = DownloadManager()
func run(_ name: String, timeout: TimeInterval = 240, source: String = url, base: DownloadOptions = DownloadOptions(),
         _ configure: (inout DownloadOptions) -> Void) -> DownloadJob {
    var o = base
    o.outputDirectory = outRoot + "/" + name.replacingOccurrences(of: " ", with: "_")
    configure(&o)
    manager.enqueue(urls: [source], options: o, tools: snap)
    let job = manager.jobs.last!
    let ok = waitUntil(timeout) { job.status.isDone }
    if !ok || job.status != .finished {
        print("    status: \(job.status.label)\n    log tail:\n      " + job.log.suffix(6).joined(separator: "\n      "))
    }
    return job
}

section("E2E: video")
do {
    let j = run("mp4") { _ in }
    check(j.status == .finished, "finished")
    check(j.title == "clip", "title captured from progress template (“\(j.title)”)")
    check(j.outputFiles.count == 1 && FileManager.default.fileExists(atPath: j.outputFiles.first ?? ""),
          "final path captured via --print-to-file", "\(j.outputFiles)")
    if let f = j.outputFiles.first { let p = probe(f); check(p.vcodec == "h264" && p.height == 720, "H.264 720p MP4") }
    check(j.log.contains { $0.contains("[download]") }, "regular log lines still shown (not silenced)")
}
do {
    let j = run("mkv remux") { $0.container = .mkv }
    check(j.outputFiles.first?.hasSuffix(".mkv") == true, "remuxed to MKV", "\(j.outputFiles)")
}

do {
    let j = run("webm fallback") { $0.container = .webm }
    check(j.status == .finished && j.outputFiles.first?.hasSuffix(".mkv") == true,
          "WebM requested for H.264 source → safely falls back to MKV instead of failing", "\(j.status.label) \(j.outputFiles)")
}
do {
    let j = run("video only") { $0.mode = .videoOnly }
    check(j.status == .finished, "Video Only works on a site without separate video streams", j.status.label)
}

section("E2E: audio extraction + FFmpeg filters")
do {
    let j = run("mp3") { $0.mode = .audio; $0.audioFormat = .mp3; $0.audioQuality = .k192 }
    let f = j.outputFiles.first ?? ""
    check(f.hasSuffix(".mp3") && probe(f).acodec == "mp3", "MP3 file", "\(j.outputFiles)")
}
do {
    let j = run("opus filters") { o in
        o.mode = .audio; o.audioFormat = .opus; o.normalizeAudio = true; o.volumeDB = -2
        o.sampleRate = .r48000; o.channels = .mono
    }
    let f = j.outputFiles.first ?? ""
    let p = probe(f)
    check(p.acodec == "opus", "Opus codec", "\(j.outputFiles)")
    check(p.channels == 1, "downmixed to mono (channels=\(p.channels ?? -1))")
    check(j.log.contains { $0.contains("loudnorm") }, "loudnorm reached ffmpeg")
}
do {
    let j = run("flac") { o in o.mode = .audio; o.audioFormat = .flac; o.sampleRate = .r48000 }
    let p = probe(j.outputFiles.first ?? "")
    check(p.acodec == "flac" && p.sampleRate == 48000, "FLAC resampled to 48 kHz (\(p.sampleRate ?? -1))")
}

section("E2E: trim")
do {
    let j = run("trim") { o in o.trimEnabled = true; o.trimStart = "3"; o.trimEnd = "9"; o.forceKeyframes = true }
    let d = probe(j.outputFiles.first ?? "").duration ?? -1
    check(abs(d - 6) < 1.0, "6 s section (got \(String(format: "%.2f", d)) s)")
}

section("E2E: iPhone ringtone preset")
do {
    let preset = OptionsStore.builtInPresets.first { $0.options.makesRingtone }!.options
    let song = "http://127.0.0.1:8766/song.mp4"   // 50 s, longer than iOS allows
    func meanVolume(_ path: String, _ seek: [String]) -> Double {
        let r = runSync("/usr/bin/env", ["ffmpeg", "-v", "info"] + seek + ["-i", path, "-af", "volumedetect", "-f", "null", "-"])
        guard let m = r.stderr.range(of: #"mean_volume: -?[\d.]+"#, options: .regularExpression) else { return 0 }
        return Double(r.stderr[m].dropFirst("mean_volume: ".count)) ?? 0
    }
    let j = run("ringtone", source: song, base: preset) { _ in }
    let f = j.outputFiles.first ?? ""
    check(j.status == .finished && j.outputFiles.count == 1 && f.hasSuffix(".m4r") && FileManager.default.fileExists(atPath: f)
          && !FileManager.default.fileExists(atPath: (f as NSString).deletingPathExtension + ".m4a"),
          "saved as .m4r, no .m4a left behind", "\(j.status.label) \(j.outputFiles)")
    let p = probe(f)
    check(p.acodec == "aac" && p.sampleRate == 44100 && p.channels == 2 && abs((p.duration ?? 0) - 29) < 0.3,
          "29 s AAC 44.1 kHz stereo (\(p.acodec ?? "-"), \(p.duration ?? -1) s)")
    check(meanVolume(f, ["-sseof", "-0.1"]) < meanVolume(f, ["-ss", "15", "-t", "1"]) - 15, "fades out at the end")
    let whole = run("ringtone", source: song, base: preset) { $0.trimEnabled = false }
    let g = whole.outputFiles.first ?? ""
    check(abs((probe(g).duration ?? 0) - 40) < 0.3, "whole song is capped at 40 s (\(probe(g).duration ?? -1) s)")
    check((g as NSString).lastPathComponent == "song 2.m4r" && FileManager.default.fileExists(atPath: f),
          "an existing ringtone is kept and the new one numbered", (g as NSString).lastPathComponent)

    section("Ringtone transfer: tone list and Wi-Fi share")
    let tone = FileManager.default.contents(atPath: f) ?? Data()
    check(abs((MP4.durationSeconds(tone) ?? 0) - 29) < 0.1, "length read from the MP4 header (\(MP4.durationSeconds(tone) ?? -1) s)")
    let old = try! PropertyListSerialization.data(fromPropertyList: ["Ringtones": ["WXYZ.m4r": ["Name": "Old Tone", "Total Time": 12345]]], format: .binary, options: 0)
    let first = try! RingtoneList.add(to: old, name: "song", milliseconds: 29013)
    let second = try! RingtoneList.add(to: first.plist, name: "song", milliseconds: 29013)
    let parsed = (try? PropertyListSerialization.propertyList(from: second.plist, format: nil)) as? [String: Any]
    let entry = (parsed?["Ringtones"] as? [String: Any])?[first.fileName] as? [String: Any]
    check(first.fileName.count == 8 && first.fileName.hasSuffix(".m4r") && second.fileName == first.fileName
          && RingtoneList.names(in: second.plist) == ["Old Tone", "song"] && entry?["Total Time"] as? Int == 29013,
          "tone list keeps existing tones and replaces a tone with the same name", "\(RingtoneList.names(in: second.plist))")
    if let share = try? RingtoneShare(path: f) {
        func curl(_ args: [String]) -> ProcessResult { runSync("/usr/bin/env", ["curl", "-s"] + args) }
        let page = curl([share.url.absoluteString]).stdout
        check(!share.url.absoluteString.contains("127.0.0.1") && page.contains("Use as Ringtone") && page.contains("song.m4a") && !share.tooLongForShare,
              "share page on the local network: \(share.url.absoluteString)")
        let out = outRoot + "/shared.m4a"
        _ = curl(["-o", out, share.url.absoluteString + "song.m4a"])
        check(FileManager.default.contents(atPath: out) == tone, "share serves the tone byte for byte")
        check(curl(["-r", "10-19", share.url.absoluteString + "song.m4a"]).stdout.utf8.count <= 10
              && curl(["-o", "/dev/null", "-w", "%{http_code}", "-r", "10-19", share.url.absoluteString + "song.m4a"]).stdout == "206", "share answers range requests")
        let guess = share.url.deletingLastPathComponent().absoluteString + "0000/"
        check(curl(["-o", "/dev/null", "-w", "%{http_code}", guess]).stdout == "404", "share hides everything but its own random address")
        _ = waitUntil(2) { share.downloads >= 1 }
        check(share.downloads == 1, "share counts finished downloads (\(share.downloads))")
        share.stop()
        check(curl(["-m", "3", "-o", "/dev/null", "-w", "%{http_code}", share.url.absoluteString]).stdout == "000", "share stops serving when closed")
        if let long = try? RingtoneShare(path: g) {
            check(long.tooLongForShare && curl([long.url.absoluteString]).stdout.contains("under 30 seconds"), "share warns when a tone is too long for iOS 26")
            long.stop()
        }
    } else { check(false, "share starts on the local network") }

    section("Android ringtone: Ogg length, share page, adb")
    let ogg = outRoot + "/tone.ogg"
    _ = runSync("/usr/bin/env", ["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=5", "-c:a", "libvorbis", ogg])
    let oggData = FileManager.default.contents(atPath: ogg) ?? Data()
    check(abs((Ogg.durationSeconds(oggData) ?? 0) - 5) < 0.2, "length read from the Ogg pages (\(Ogg.durationSeconds(oggData) ?? -1) s)")
    check(Ogg.durationSeconds(tone) == nil, "an AAC file is not read as Ogg")
    if let share = try? RingtoneShare(path: ogg) {
        func curl(_ args: [String]) -> ProcessResult { runSync("/usr/bin/env", ["curl", "-s"] + args) }
        let page = curl([share.url.absoluteString]).stdout
        check(share.forAndroid && !share.tooLongForShare && page.contains("Phone ringtone") && page.contains("tone.ogg") && !page.contains("Use as Ringtone"),
              "Android share page")
        let out = outRoot + "/shared.ogg"
        _ = curl(["-o", out, share.url.absoluteString + "tone.ogg"])
        check(FileManager.default.contents(atPath: out) == oggData, "share serves the .ogg byte for byte")
        check(curl(["-D", "-", "-o", "/dev/null", share.url.absoluteString + "tone.ogg"]).stdout.lowercased().contains("content-type: audio/ogg"), "share serves audio/ogg")
        share.stop()
    } else { check(false, "Android share starts on the local network") }

    let sample = """
    List of devices attached
    * daemon started successfully
    R58M123ABC             device usb:1-1 product:panther model:Pixel_7 device:panther transport_id:1
    192.168.1.20:37045     device product:x model:SM_S918B device:y transport_id:2
    adb-XYZ123-abcd._adb-tls-connect._tcp device product:z model:Pixel_8 device:w transport_id:3
    0123456789ABCDEF       unauthorized usb:1-2 transport_id:4
    emulator-5554          offline

    """
    let devs = AndroidSync.parseDevices(sample)
    check(devs.count == 5 && devs[0].model == "Pixel 7" && devs[0].ready && !devs[0].wifi
          && devs[1].wifi && devs[1].model == "SM S918B" && devs[2].wifi
          && devs[3].state == "unauthorized" && !devs[3].ready && !devs[4].wifi && devs[4].model == "",
          "adb devices -l output parsed", "\(devs)")

    let phone = outRoot + "/fakephone"
    try? FileManager.default.createDirectory(atPath: phone, withIntermediateDirectories: true)
    let fakeAdb = outRoot + "/fake-adb"
    let script = """
    #!/bin/bash
    PHONE="\(phone)"
    if [ "$1" = "-s" ]; then shift 2; fi
    case "$1" in
      devices) printf 'List of devices attached\nR58M123ABC device usb:1-1 model:Pixel_7 transport_id:1\n\n' ;;
      push) mkdir -p "$PHONE"; cp "$2" "$PHONE/$(basename "$3")"; echo "1 file pushed" ;;
      shell)
        echo "$2" >> "$PHONE/shell.log"
        case "$2" in
          "content query"*) echo "Row: 0 _id=42" ;;
          "settings put"*) echo "$2" >> "$PHONE/settings.log" ;;
        esac ;;
      connect) echo "failed to connect to '$2': Connection refused" ;;
    esac
    exit 0
    """
    try? script.write(toFile: fakeAdb, atomically: true, encoding: .utf8)
    chmod(fakeAdb, 0o755)
    setenv("JETHRIKI_ADB", fakeAdb, 1)
    check(AndroidSync.findAdb() == fakeAdb, "JETHRIKI_ADB selects adb")
    let listed = (try? blocking { try await AndroidSync.list() }.get()) ?? []
    check(listed.count == 1 && listed[0].serial == "R58M123ABC", "list() runs adb devices -l", "\(listed)")
    if let target = listed.first {
        let sent = blocking { try await AndroidSync.sendRingtone(path: ogg, to: target, setAsRingtone: true) }
        check((try? sent.get()) == "tone" && FileManager.default.contents(atPath: phone + "/tone.ogg") == oggData, "sendRingtone copies the tone to the phone", "\(sent)")
        let settings = (try? String(contentsOfFile: phone + "/settings.log", encoding: .utf8)) ?? ""
        check(settings.contains("settings put system ringtone content://media/external/audio/media/42"), "sendRingtone sets the ringtone from the media id", settings)
        let bad = AndroidTarget(serial: "X", model: "", wifi: false, state: "unauthorized")
        let denied = blocking { try await AndroidSync.sendRingtone(path: ogg, to: bad, setAsRingtone: false) }
        check({ if case .failure(let e) = denied { return e.localizedDescription.contains("tap Allow") }; return false }(), "unauthorized phone gets the Allow hint")
    }
    let refused = blocking { try await AndroidSync.connect(hostPort: "10.0.0.9:5555") }
    check({ if case .failure = refused { return true }; return false }(), "connect reports 'failed to connect' even with exit 0")
    unsetenv("JETHRIKI_ADB")
}

section("E2E: FFmpeg re-encode pass, every software encoder, downscale + loudnorm")
let encodeCases: [(VideoEncoder, VideoContainer, String)] = [
    (.x264, .mp4, "h264"), (.x265, .mp4, "hevc"), (.vp9, .webm, "vp9"), (.av1, .mkv, "av1"), (.prores, .mov, "prores")
]
for (enc, cont, expected) in encodeCases {
    let j = run("enc \(enc.rawValue)") { o in
        o.container = cont; o.encodeEnabled = true; o.encoder = enc; o.crf = enc.defaultCRF
        o.preset = .ultrafast; o.scale = .h480; o.normalizeAudio = true
    }
    if let f = j.outputFiles.first(where: { $0.contains(".encoded.") }) {
        let p = probe(f)
        check(p.vcodec == expected && p.height == 480, "\(enc.rawValue) → \(cont.rawValue.uppercased()): \(p.vcodec ?? "nil") \(p.height ?? 0)p, audio \(p.acodec ?? "nil")")
    } else {
        check(false, "\(enc.rawValue) produced an encoded file", j.status.label)
    }
}
do {
    let j = run("replace original") { o in
        o.encodeEnabled = true; o.encoder = .x264; o.preset = .ultrafast; o.replaceOriginal = true; o.scale = .h360
    }
    let f = j.outputFiles.first ?? ""
    check(j.outputFiles.count == 1 && !f.contains(".encoded.") && probe(f).height == 360,
          "original replaced in place", "\(j.outputFiles)")
    check(j.progress == 1, "progress ends at 100%")
}

section("E2E: queue behavior")
do {
    var o = DownloadOptions()
    o.outputDirectory = outRoot + "/cancel"
    o.encodeEnabled = true; o.encoder = .av1; o.preset = .veryslow; o.crf = 5
    manager.enqueue(urls: [url], options: o, tools: snap)
    let j = manager.jobs.last!
    _ = waitUntil(90) {
        if case .encoding = j.status { return j.progress > 0.01 }
        return j.status.isDone
    }
    let wasEncoding: Bool = { if case .encoding = j.status { return true }; return false }()
    check(wasEncoding, "encode progress parsed from ffmpeg (\(String(format: "%.0f", j.progress * 100))%)", j.status.label)
    manager.cancel(j)
    _ = waitUntil(15) { j.status.isDone }
    check(j.status == .cancelled, "cancel stops a slow AV1 encode within seconds (\(j.status.label))")
    let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: o.outputDirectory)) ?? []).filter { $0.contains(".encoded.") }
    check(leftovers.isEmpty, "partial encode cleaned up", "\(leftovers)")
    manager.retry(j)
    check(j.status.isActive, "retry restarts the job (\(j.status.label))")
    manager.cancel(j)
    _ = waitUntil(15) { j.status.isDone }
}
do {
    var o = DownloadOptions(); o.outputDirectory = outRoot + "/fail"
    manager.enqueue(urls: ["http://127.0.0.1:8766/nope.mp4"], options: o, tools: snap)
    let j = manager.jobs.last!
    _ = waitUntil(60) { j.status.isDone }
    if case .failed(let msg) = j.status { check(!msg.isEmpty, "bad link fails with a message: \(msg.prefix(70))") }
    else { check(false, "bad link reported as failed", j.status.label) }
}
func drain(_ urls: [String], into dir: String) -> (startedAtOnce: Int, jobs: [DownloadJob]) {
    var o = DownloadOptions(); o.outputDirectory = outRoot + "/" + dir
    manager.clearFinished()
    manager.enqueue(urls: urls, options: o, tools: snap)
    let batch = Array(manager.jobs.suffix(urls.count))
    let active = batch.filter { $0.status.isActive }.count
    _ = waitUntil(180) { batch.allSatisfy { $0.status.isDone } }
    return (active, batch)
}
func summary(_ jobs: [DownloadJob]) -> String {
    jobs.map { "\n      \($0.status.label) | \($0.log.suffix(2).joined(separator: " / ").prefix(200))" }.joined()
}
UserDefaults.standard.set(2, forKey: "maxConcurrent")
do {
    let base = "http://127.0.0.1:8766/"
    let r = drain(["a", "b", "c", "d"].map { base + $0 + ".mp4" }, into: "parallel")
    check(r.startedAtOnce == 2, "respects simultaneous-download limit (\(r.startedAtOnce) of 4 started)")
    check(r.jobs.allSatisfy { $0.status == .finished }, "queue drains automatically, all 4 finish", summary(r.jobs))
}
do {
    let r = drain(["http://127.0.0.1:8766/x/clip.mp4", "http://127.0.0.1:8766/y/clip.mp4"], into: "same-title")
    check(r.startedAtOnce == 2, "two different links with the same title run concurrently")
    check(r.jobs.allSatisfy { $0.status == .finished }, "…and don't corrupt each other (private temp dirs)", summary(r.jobs))
}
do {
    let r = drain([url, url], into: "duplicate")
    check(r.startedAtOnce == 1, "the same link twice is serialized, not run in parallel")
    check(r.jobs.allSatisfy { $0.status == .finished }, "…and both complete", summary(r.jobs))
}
let leftoverTemps = ((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? [])
    .filter { $0.hasPrefix("ytdlp-studio-") }
check(leftoverTemps.isEmpty, "per-job temp folders cleaned up", "\(leftoverTemps.prefix(3))")


// MARK: - 6. Music tags

section("Music tags: what audio players will read")
let infoDir = NSTemporaryDirectory() + "studio-info"
try? FileManager.default.createDirectory(atPath: infoDir, withIntermediateDirectories: true)

/// A realistic YouTube-style info dict; yt-dlp --load-info-json replays it without network.
func writeInfo(_ name: String, thumb: String = "thumb.webp", inPlaylist: Bool = true, chapters: Bool = false,
               _ over: [String: Any] = [:]) -> String {
    var d: [String: Any] = [
        "id": "abc123", "title": "Daft Punk - Harder, Better, Faster, Stronger (Official Video)",
        "uploader": "DaftPunkVEVO", "channel": "DaftPunkVEVO", "upload_date": "20090226",
        "description": "Official video.", "duration": 20,
        "webpage_url": "http://127.0.0.1:8766/watch?v=abc123", "extractor": "generic", "extractor_key": "Generic",
        "_type": "video",
        "thumbnails": [["url": "http://127.0.0.1:8766/\(thumb)", "id": "0", "width": 1280, "height": 720]],
        "formats": [["format_id": "18", "url": "http://127.0.0.1:8766/clip.mp4", "ext": "mp4",
                     "vcodec": "h264", "acodec": "aac", "protocol": "http"]],
    ]
    if inPlaylist {
        d["playlist"] = "Discovery"; d["playlist_title"] = "Discovery"; d["playlist_index"] = 3
        d["n_entries"] = 14; d["playlist_id"] = "PL1"
    }
    if chapters {
        d["chapters"] = [["start_time": 0, "end_time": 7, "title": "One More Time"],
                         ["start_time": 7, "end_time": 14, "title": "Aerodynamic"],
                         ["start_time": 14, "end_time": 20, "title": "Digital Love (Official Audio)"]]
    }
    for (k, v) in over { d[k] = v }
    let path = infoDir + "/\(name).info.json"
    _ = FileManager.default.createFile(atPath: path, contents: try! JSONSerialization.data(withJSONObject: d))
    return path
}

struct Tags {
    let values: [String: String]
    let coverSize: (Int, Int)?
    subscript(_ key: String) -> String { values[key] ?? "" }
    var squareCover: Bool { if let c = coverSize { return c.0 == c.1 && c.0 > 0 } else { return false } }
}
/// Reads tags the way a player sees them: file-level plus audio-stream tags (Ogg keeps them there).
func readTags(_ path: String) -> Tags {
    let r = runSync("/usr/bin/ffprobe", ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", path])
    let obj = (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8))) as? [String: Any] ?? [:]
    var out: [String: String] = [:]
    func absorb(_ t: Any?) {
        for (k, v) in (t as? [String: Any]) ?? [:] {
            let key = k.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
            out[key] = "\(v)"
        }
    }
    absorb((obj["format"] as? [String: Any])?["tags"])
    let streams = obj["streams"] as? [[String: Any]] ?? []
    if let a = streams.first(where: { ($0["codec_type"] as? String) == "audio" }) { absorb(a["tags"]) }
    let pic = streams.first { ($0["codec_type"] as? String) == "video" }
    let size = pic.flatMap { p -> (Int, Int)? in
        guard let w = p["width"] as? Int, let h = p["height"] as? Int else { return nil }
        return (w, h)
    }
    return Tags(values: out, coverSize: size)
}

func describe(_ t: Tags) -> String {
    let c = t.coverSize.map { "\($0.0)x\($0.1)" } ?? "none"
    return "title=\(t["title"]) | artist=\(t["artist"]) | album=\(t["album"]) | albumartist=\(t["albumartist"]) | track=\(t["track"]) | date=\(t["date"]) | cover=\(c)"
}

func runTagged(_ name: String, info: String, _ configure: (inout DownloadOptions) -> Void = { _ in }) -> DownloadJob {
    run(name) { o in
        o.mode = .audio
        o.extraArgs = "--load-info-json \(CommandBuilder.shellQuote(info))"
        configure(&o)
    }
}

let baseInfo = writeInfo("base")
for format in [AudioFormat.mp3, .m4a, .flac, .opus] {
    let j = runTagged("tags \(format.rawValue)", info: baseInfo) { $0.audioFormat = format }
    let t = readTags(j.outputFiles.first ?? "")
    let ok = t["title"] == "Harder, Better, Faster, Stronger" && t["artist"] == "Daft Punk" &&
        t["album"] == "Discovery" && t["albumartist"] == "Daft Punk" &&
        t["track"].hasPrefix("3") && t["track"].contains("14") && t["date"].hasPrefix("2009") && t.squareCover
    check(ok, "\(format.rawValue.uppercased()): \(describe(t))", "\(j.status.label) \(j.outputFiles)")
}
do {
    let j = runTagged("tags jpeg thumb", info: writeInfo("jpgthumb", thumb: "thumb.jpg")) { $0.audioFormat = .mp3 }
    let t = readTags(j.outputFiles.first ?? "")
    check(t.squareCover, "JPEG thumbnails are cropped square too (cover \(t.coverSize.map { "\($0.0)x\($0.1)" } ?? "none"))")
}
do {
    let info = writeInfo("ytmusic", inPlaylist: false, ["title": "Harder, Better, Faster, Stronger",
        "track": "Harder, Better, Faster, Stronger", "artist": "Daft Punk", "album": "Discovery",
        "track_number": 4, "release_year": 2001, "uploader": "Daft Punk - Topic", "channel": "Daft Punk - Topic"])
    let t = readTags(runTagged("tags ytmusic", info: info) { $0.audioFormat = .mp3 }.outputFiles.first ?? "")
    check(t["artist"] == "Daft Punk" && t["album"] == "Discovery" && t["track"].hasPrefix("4") && t["date"].hasPrefix("2001"),
          "YouTube Music's own artist, album, track 4 and year 2001 are kept: \(describe(t))")
}
do {
    let info = writeInfo("nodash", inPlaylist: false, ["title": "How Synthesizers Work [4K]", "uploader": "Tech Explained"])
    let t = readTags(runTagged("tags nodash", info: info) { $0.audioFormat = .mp3 }.outputFiles.first ?? "")
    check(t["title"] == "How Synthesizers Work" && t["artist"] == "Tech Explained",
          "non-music titles are only cleaned, not split: \(describe(t))")
}
do {
    let j = runTagged("tags genre", info: baseInfo) { $0.audioFormat = .mp3; $0.genre = "French House" }
    check(readTags(j.outputFiles.first ?? "")["genre"] == "French House", "genre written (with a space in it)")
}
do {
    let j = runTagged("tags names", info: baseInfo) { $0.audioFormat = .mp3; $0.filenameTemplate = .artistTitle }
    let name = (j.outputFiles.first.map { ($0 as NSString).lastPathComponent }) ?? ""
    check(name == "Daft Punk - Harder, Better, Faster, Stronger.mp3", "\u{201C}Artist - Song\u{201D} file name: \(name)")
    let k = runTagged("tags library", info: baseInfo) { $0.audioFormat = .mp3; $0.filenameTemplate = .musicLibrary }
    let rel = k.outputFiles.first?.replacingOccurrences(of: k.options.outputDirectory + "/", with: "") ?? ""
    check(rel == "Daft Punk/Discovery/03 Harder, Better, Faster, Stronger.mp3", "music library path: \(rel)")
}
do {
    let j = runTagged("tags off", info: baseInfo) { $0.audioFormat = .mp3; $0.musicTags = false }
    let t = readTags(j.outputFiles.first ?? "")
    check(t["title"] == "Daft Punk - Harder, Better, Faster, Stronger (Official Video)" && t["track"].isEmpty,
          "turning music tags off restores the previous behavior")
}

section("Music tags: album split into chapter tracks")
let albumInfo = writeInfo("album", inPlaylist: false, chapters: true, ["title": "Daft Punk - Discovery (Full Album)"])
for format in [AudioFormat.mp3, .m4a, .flac, .opus, .vorbis] {
    let j = runTagged("album \(format.rawValue)", info: albumInfo) { o in
        o.audioFormat = format; o.splitChapters = true; o.chaptersInFolder = true
    }
    let tracks = Array(j.outputFiles.dropFirst()).sorted()   // first entry is the full-length file
    let tags = tracks.map(readTags)
    let titles = tags.map { $0["title"] }
    let numbers = tags.map { $0["track"] }
    let ok = j.status == .finished && titles == ["One More Time", "Aerodynamic", "Digital Love"] &&
        numbers.map { $0.split(separator: "/").first.map(String.init) ?? "" } == ["1", "2", "3"] &&
        tags.allSatisfy { $0["album"] == "Discovery" && $0["artist"] == "Daft Punk" && $0.squareCover }
    check(ok, "\(format.rawValue.uppercased()): \(titles) tracks \(numbers), album \(tags.first?["album"] ?? "-"), covers square: \(tags.allSatisfy { $0.squareCover })",
          "\(j.status.label) | \(tracks.map { ($0 as NSString).lastPathComponent }) | \(j.log.suffix(4))")
}

section("Settings saved by the previous version still load")
do {
    var saved = (try! JSONSerialization.jsonObject(with: JSONEncoder().encode(DownloadOptions()))) as! [String: Any]
    for key in ["musicTags", "cleanTitles", "squareCover", "genre", "tagChapterTracks"] { saved.removeValue(forKey: key) }
    saved["container"] = "mkv"; saved["audioFormat"] = "flac"; saved["mode"] = "retiredMode"
    let loaded = OptionsStore.mergedWithDefaults(saved)
    check(loaded?.container == .mkv && loaded?.audioFormat == .flac, "old values kept (MKV, FLAC)")
    check(loaded?.musicTags == true && loaded?.squareCover == true, "new music options get their defaults")
    check(loaded?.mode == .video, "an unreadable old value falls back to its default instead of wiping everything")
}


// MARK: - 7. Cutting segments out (SponsorBlock "Cut out", remove chapters)

section("Cutting segments out of a video")
do {
    // Same cutting path SponsorBlock uses; SponsorBlock's own servers aren't reachable here.
    var info: [String: Any] = [
        "id": "sb1", "title": "Kill Count", "uploader": "Test", "upload_date": "20240101", "duration": 30,
        "webpage_url": "http://127.0.0.1:8766/w", "extractor": "generic", "extractor_key": "Generic", "_type": "video",
        "formats": [["format_id": "18", "url": "http://127.0.0.1:8766/longgop.mp4", "ext": "mp4",
                     "vcodec": "h264", "acodec": "aac", "protocol": "http"]],
        "chapters": [["start_time": 0, "end_time": 12, "title": "Part one"],
                     ["start_time": 12, "end_time": 16, "title": "Sponsor"],
                     ["start_time": 16, "end_time": 30, "title": "Part two"]]]
    info["thumbnails"] = []
    let path = infoDir + "/sponsor.info.json"
    _ = FileManager.default.createFile(atPath: path, contents: try! JSONSerialization.data(withJSONObject: info))

    var sb = DownloadOptions(); sb.sponsorBlockMode = .remove
    check(CommandBuilder.arguments(for: sb, urls: ["u"]).contains("--force-keyframes-at-cuts"),
          "SponsorBlock \u{201C}Cut out\u{201D} uses precise cuts by default")
    sb.mode = .audio
    check(!CommandBuilder.arguments(for: sb, urls: ["u"]).contains("--force-keyframes-at-cuts"),
          "audio-only downloads skip the re-encode (audio cuts are exact anyway)")

    /// Frame times (seconds) where the picture jumps backwards: footage being replayed.
    func backwardJumps(_ file: String) -> [Double] {
        // Brightness profile per frame of a moving test pattern; a replay shows as times going backwards
        // when each output frame is matched to the source frame it shows.
        func frames(_ f: String) -> [[UInt8]] {
            let r = runSync("/bin/sh", ["-c", "ffmpeg -loglevel error -i '\(f)' -vf fps=5,scale=64:36,format=gray -f rawvideo - | od -An -v -tu1"])
            let bytes = r.stdout.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { UInt8($0) }
            let size = 64 * 36
            return stride(from: 0, to: bytes.count - size + 1, by: size).map { Array(bytes[$0..<$0 + size]) }
        }
        let src = frames("/tmp/srv/longgop.mp4".replacingOccurrences(of: "/tmp/srv", with: ProcessInfo.processInfo.environment["SRV"] ?? "/tmp/srv"))
        let out = frames(file)
        guard !src.isEmpty, !out.isEmpty else { return [-1] }
        let times = out.map { o -> Double in
            let best = src.indices.min { a, b in
                zip(src[a], o).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } < zip(src[b], o).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            }!
            return Double(best) / 5
        }
        return times.indices.dropFirst().filter { times[$0] < times[$0 - 1] - 0.5 }.map { Double($0) / 5 }
    }

    let precise = run("cut precise") { o in
        o.extraArgs = "--load-info-json \(CommandBuilder.shellQuote(path))"; o.removeChaptersRegex = "Sponsor"
    }
    let preciseJumps = backwardJumps(precise.outputFiles.first ?? "")
    check(precise.status == .finished && preciseJumps.isEmpty, "precise cut plays straight through (no replayed footage)", "jumps at \(preciseJumps) \(precise.status.label)")

    let copy = run("cut copy") { o in
        o.extraArgs = "--load-info-json \(CommandBuilder.shellQuote(path))"; o.removeChaptersRegex = "Sponsor"; o.preciseCuts = false
    }
    let copyJumps = backwardJumps(copy.outputFiles.first ?? "")
    check(!copyJumps.isEmpty, "control: without precise cuts the replay bug appears (jumps back at \(copyJumps.prefix(3))s)")
}


// MARK: - 8. Track numbers in titles

section("Track numbers removed from song titles")
do {
    let numbered = ["01. One More Time", "1 - Aerodynamic", "03 Digital Love", "[04] Harder, Better, Faster, Stronger",
                    "(5) Crescendolls", "#6 - Nightvision", "Track 7 - Superheroes", "8) High Life",
                    "09: Something About Us", "10 \u{2013} Voyager", "11.Veridis Quo", "12 \u{2014} Short Circuit", "track 13: Face to Face"]
    let bad = numbered.filter { t in let r = ChapterTagger.stripTrackNumber(t); return r == t || r.first?.isNumber == true }
    check(bad.isEmpty, "all \(numbered.count) numbering styles removed (\u{201C}01. One More Time\u{201D} \u{2192} \u{201C}\(ChapterTagger.stripTrackNumber("01. One More Time"))\u{201D})", "\(bad)")
    let real = ["7 Rings", "99 Luftballons", "1999", "2 Become 1", "4:44", "1-800-273-8255", "9 to 5", "21 Guns",
                "1.5 Seconds", "50 Ways to Leave Your Lover", "22", "007 (Shanty Town)", "Notorious", "No Scrubs",
                "10,000 Hours", "3 Libras", "1 Thing"]
    let changed = real.filter { ChapterTagger.stripTrackNumber($0) != $0 }
    check(changed.isEmpty, "all \(real.count) titles that really start with a number are untouched (7 Rings, 4:44, 1999\u{2026})", "\(changed)")

    func tagsFor(_ name: String, _ over: [String: Any], playlist: Bool = false) -> Tags {
        let info = writeInfo(name, inPlaylist: playlist, over)
        return readTags(runTagged(name, info: info) { $0.audioFormat = .mp3 }.outputFiles.first ?? "")
    }
    let t1 = tagsFor("num lead", ["title": "01 - One More Time", "uploader": "Daft Punk - Topic", "channel": "Daft Punk - Topic"], playlist: true)
    check(t1["title"] == "One More Time" && t1["artist"] == "Daft Punk", "\u{201C}01 - One More Time\u{201D}: title \u{201C}\(t1["title"])\u{201D}, artist \u{201C}\(t1["artist"])\u{201D} (not \u{201C}01\u{201D})")
    let t2 = tagsFor("num after artist", ["title": "Daft Punk - 03. Digital Love (Official Audio)"])
    check(t2["title"] == "Digital Love" && t2["artist"] == "Daft Punk", "\u{201C}Daft Punk - 03. Digital Love (Official Audio)\u{201D}: \(describe(t2))")
    let t3 = tagsFor("num real", ["title": "7 Rings", "uploader": "Ariana Grande"])
    check(t3["title"] == "7 Rings", "\u{201C}7 Rings\u{201D} keeps its number")
    let t4 = tagsFor("num ytm", ["title": "Harder, Better, Faster, Stronger", "track": "04 Harder, Better, Faster, Stronger", "artist": "Daft Punk"])
    check(t4["title"] == "Harder, Better, Faster, Stronger", "YouTube Music track field \u{201C}04 Harder\u{2026}\u{201D} cleaned too")

    var chaptered = writeInfo("num chapters", inPlaylist: false, chapters: true, ["title": "Daft Punk - Discovery (Full Album)"])
    if var d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: chaptered)))) as? [String: Any] {
        d["chapters"] = [["start_time": 0, "end_time": 7, "title": "01. One More Time"],
                         ["start_time": 7, "end_time": 14, "title": "02 - Aerodynamic"],
                         ["start_time": 14, "end_time": 20, "title": "[03] Digital Love"]]
        chaptered = infoDir + "/num-chapters2.info.json"
        _ = FileManager.default.createFile(atPath: chaptered, contents: try! JSONSerialization.data(withJSONObject: d))
    }
    let j = runTagged("num split", info: chaptered) { o in o.audioFormat = .mp3; o.splitChapters = true }
    let titles = Array(j.outputFiles.dropFirst()).sorted().map { readTags($0)["title"] }
    check(titles == ["One More Time", "Aerodynamic", "Digital Love"], "split album chapters \u{201C}01. \u{2026}\u{201D}, \u{201C}02 - \u{2026}\u{201D}, \u{201C}[03] \u{2026}\u{201D} \u{2192} \(titles)")

    let k = runTagged("num toggle off", info: writeInfo("num toggle", ["title": "Song Title 01", "uploader": "X"])) { o in
        o.audioFormat = .mp3; o.stripTitleNumbers = false }
    check(k.status == .finished, "turning the option off still downloads normally")
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
