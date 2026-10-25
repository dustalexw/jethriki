import Foundation

// MARK: - Picker-friendly enum protocol

protocol OptionEnum: CaseIterable, Identifiable, Hashable, Codable, RawRepresentable
where RawValue == String, AllCases: RandomAccessCollection {
    var label: String { get }
}

extension OptionEnum {
    var id: String { rawValue }
}

// MARK: - Mode & video

enum DownloadMode: String, OptionEnum {
    case video, audio, videoOnly
    var label: String {
        switch self {
        case .video: return "Video + Audio"
        case .audio: return "Audio Only"
        case .videoOnly: return "Video Only"
        }
    }
}

enum VideoContainer: String, OptionEnum {
    case mp4, mkv, webm, mov, avi, flv
    var label: String {
        switch self {
        case .mp4: return "MP4 (plays everywhere)"
        case .mkv: return "MKV (any codec, best for archiving)"
        case .webm: return "WebM (VP9/AV1 + Opus)"
        case .mov: return "MOV (QuickTime / Final Cut)"
        case .avi: return "AVI (legacy)"
        case .flv: return "FLV (legacy)"
        }
    }
    /// Sort token that prefers streams which fit this container without re-encoding.
    var extSort: String? {
        switch self {
        case .mp4, .mov: return "ext:mp4:m4a"
        case .webm: return "ext:webm:webm"
        default: return nil
        }
    }
    /// yt-dlp remux rule that never asks FFmpeg for an impossible stream copy
    /// (verified: H.264/AAC can't go in WebM; VP9/Opus can't go in MOV, AVI or FLV).
    /// Sources that can't fit fall back to the closest container that can hold them.
    var remuxRule: String {
        switch self {
        case .mp4, .mkv: return rawValue
        case .webm: return "mp4>mkv/mkv>mkv/webm"
        case .mov: return "webm>mp4/mov"
        case .avi, .flv: return "webm>mkv/\(rawValue)"
        }
    }
    var supportsThumbnailEmbed: Bool { [.mp4, .mkv, .mov].contains(self) }
    var supportsSubtitleEmbed: Bool { [.mp4, .mkv, .webm].contains(self) }
}

enum MaxResolution: String, OptionEnum {
    case best, p4320, p2160, p1440, p1080, p720, p480, p360, p240, p144
    var label: String {
        switch self {
        case .best: return "Best available"
        case .p4320: return "4320p (8K)"
        case .p2160: return "2160p (4K)"
        case .p1440: return "1440p (2K)"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        case .p360: return "360p"
        case .p240: return "240p"
        case .p144: return "144p"
        }
    }
    var height: Int? {
        switch self {
        case .best: return nil
        case .p4320: return 4320
        case .p2160: return 2160
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        case .p360: return 360
        case .p240: return 240
        case .p144: return 144
        }
    }
}

enum VideoCodecPref: String, OptionEnum {
    case any, h264, h265, vp9, av1
    var label: String {
        switch self {
        case .any: return "No preference"
        case .h264: return "H.264 / AVC (most compatible)"
        case .h265: return "H.265 / HEVC"
        case .vp9: return "VP9"
        case .av1: return "AV1 (smallest files)"
        }
    }
    var sortToken: String? {
        switch self {
        case .any: return nil
        case .h264: return "vcodec:h264"
        case .h265: return "vcodec:h265"
        case .vp9: return "vcodec:vp9"
        case .av1: return "vcodec:av01"
        }
    }
}

enum AudioCodecPref: String, OptionEnum {
    case any, aac, opus
    var label: String {
        switch self {
        case .any: return "No preference"
        case .aac: return "AAC (most compatible)"
        case .opus: return "Opus (higher efficiency)"
        }
    }
    var sortToken: String? {
        switch self {
        case .any: return nil
        case .aac: return "acodec:aac"
        case .opus: return "acodec:opus"
        }
    }
}

enum FPSLimit: String, OptionEnum {
    case any, fps60, fps30, fps24
    var label: String {
        switch self {
        case .any: return "Highest available"
        case .fps60: return "Up to 60 fps"
        case .fps30: return "Up to 30 fps"
        case .fps24: return "Up to 24 fps"
        }
    }
    var sortToken: String? {
        switch self {
        case .any: return nil
        case .fps60: return "fps:60"
        case .fps30: return "fps:30"
        case .fps24: return "fps:24"
        }
    }
}

// MARK: - Audio

enum AudioFormat: String, OptionEnum {
    case best, mp3, m4a, aac, opus, vorbis, flac, alac, wav, m4r, android
    var label: String {
        switch self {
        case .best: return "Best (keep original codec)"
        case .mp3: return "MP3"
        case .m4a: return "M4A (AAC)"
        case .aac: return "AAC (raw .aac)"
        case .opus: return "Opus"
        case .vorbis: return "Ogg Vorbis"
        case .flac: return "FLAC (lossless)"
        case .alac: return "ALAC (Apple lossless)"
        case .wav: return "WAV (uncompressed)"
        case .m4r: return "iPhone ringtone (M4R)"
        case .android: return "Android ringtone (OGG)"
        }
    }
    var isLossless: Bool { [.flac, .alac, .wav].contains(self) }
    /// A ready-to-sync iTunes / iPhone ringtone: AAC in an MPEG-4 file named .m4r, at most 40 seconds.
    var isRingtone: Bool { self == .m4r }
    /// The codec handed to yt-dlp's --audio-format. yt-dlp has no M4R target, so a ringtone is
    /// written as M4A (the same container) and the app renames it to .m4r once it is finished.
    var ytdlpFormat: String {
        switch self {
        case .m4r: return AudioFormat.m4a.rawValue
        case .android: return AudioFormat.vorbis.rawValue
        default: return rawValue
        }
    }
    /// An Android ringtone: Ogg Vorbis, the format Android's own tones use, at most a minute long.
    var isAndroidRingtone: Bool { self == .android }
    /// The longest clip a ringtone format keeps, or nil for ordinary audio.
    var ringtoneMaxSeconds: Int? {
        switch self {
        case .m4r: return Ringtone.maxSeconds
        case .android: return Ringtone.androidMaxSeconds
        default: return nil
        }
    }
    /// Prefer a source stream that already matches, so no lossy-to-lossy transcode is needed.
    var preferredSourceSort: String? {
        switch self {
        case .m4a, .aac, .m4r: return "acodec:aac"
        case .opus: return "acodec:opus"
        default: return nil
        }
    }
}

/// What iTunes, Finder and iOS accept as a ringtone.
enum Ringtone {
    static let fileExtension = "m4r"
    /// iOS rejects ringtones longer than 40 seconds; the app enforces this whatever the trim settings.
    static let maxSeconds = 40
    /// Android has no length limit, but a ringtone rarely plays longer than a minute before voicemail.
    static let androidMaxSeconds = 60
    static let androidDefaultSeconds = 30
    /// Seconds a preset ringtone clip lasts by default: under the 30 seconds iOS 26 allows for Use as Ringtone.
    static let defaultSeconds = 29
    static let fadeInSeconds = 0.3
    static let fadeOutSeconds = 2.0
    /// Bitrate used when a VBR quality is chosen, since Apple's own ringtones are constant-bitrate AAC.
    static let defaultBitrate = "256k"
}

enum AudioQuality: String, OptionEnum {
    case q0, q2, q5, k320, k256, k192, k160, k128, k96, k64
    var label: String {
        switch self {
        case .q0: return "VBR best (0)"
        case .q2: return "VBR high (2)"
        case .q5: return "VBR medium (5)"
        case .k320: return "320 kbps"
        case .k256: return "256 kbps"
        case .k192: return "192 kbps"
        case .k160: return "160 kbps"
        case .k128: return "128 kbps"
        case .k96: return "96 kbps"
        case .k64: return "64 kbps"
        }
    }
    var arg: String {
        switch self {
        case .q0: return "0"
        case .q2: return "2"
        case .q5: return "5"
        case .k320: return "320K"
        case .k256: return "256K"
        case .k192: return "192K"
        case .k160: return "160K"
        case .k128: return "128K"
        case .k96: return "96K"
        case .k64: return "64K"
        }
    }
}

enum SampleRate: String, OptionEnum {
    case keep, r22050, r44100, r48000, r96000
    var label: String {
        switch self {
        case .keep: return "Keep original"
        case .r22050: return "22.05 kHz"
        case .r44100: return "44.1 kHz"
        case .r48000: return "48 kHz"
        case .r96000: return "96 kHz"
        }
    }
    var value: Int? {
        switch self {
        case .keep: return nil
        case .r22050: return 22050
        case .r44100: return 44100
        case .r48000: return 48000
        case .r96000: return 96000
        }
    }
}

enum ChannelLayout: String, OptionEnum {
    case keep, mono, stereo
    var label: String {
        switch self {
        case .keep: return "Keep original"
        case .mono: return "Mono"
        case .stereo: return "Stereo"
        }
    }
    var value: Int? {
        switch self {
        case .keep: return nil
        case .mono: return 1
        case .stereo: return 2
        }
    }
}

// MARK: - FFmpeg re-encode

enum VideoEncoder: String, OptionEnum {
    case x264 = "libx264"
    case x265 = "libx265"
    case vtH264 = "h264_videotoolbox"
    case vtHEVC = "hevc_videotoolbox"
    case vp9 = "libvpx-vp9"
    case av1 = "libsvtav1"
    case prores = "prores_ks"

    var label: String {
        switch self {
        case .x264: return "H.264 – x264 (software, best quality/size)"
        case .x265: return "HEVC – x265 (software, smaller files)"
        case .vtH264: return "H.264 – VideoToolbox (hardware, fast)"
        case .vtHEVC: return "HEVC – VideoToolbox (hardware, fast)"
        case .vp9: return "VP9 – libvpx"
        case .av1: return "AV1 – SVT-AV1"
        case .prores: return "ProRes 422 HQ (for editing)"
        }
    }
    var usesCRF: Bool { [.x264, .x265, .vp9, .av1].contains(self) }
    var usesBitrate: Bool { [.vtH264, .vtHEVC].contains(self) }
    var supportsPreset: Bool { [.x264, .x265, .av1].contains(self) }
    var maxCRF: Double { (self == .x264 || self == .x265) ? 51 : 63 }
    var defaultCRF: Double {
        switch self {
        case .x264: return 23
        case .x265: return 28
        case .vp9: return 31
        case .av1: return 35
        default: return 23
        }
    }
    var compatibleContainers: [VideoContainer] {
        switch self {
        case .x264, .vtH264: return [.mp4, .mkv, .mov, .avi, .flv]
        case .x265, .vtHEVC: return [.mp4, .mkv, .mov]
        case .vp9: return [.webm, .mkv, .mp4]
        case .av1: return [.mkv, .mp4, .webm]
        case .prores: return [.mov, .mkv]
        }
    }
}

enum EncoderPreset: String, OptionEnum {
    case ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow
    var label: String { rawValue }
    var svtAV1Preset: Int {
        let map = [12, 11, 10, 9, 8, 6, 5, 4, 3]
        return map[Self.allCases.firstIndex(of: self) ?? 5]
    }
}

enum ScaleHeight: String, OptionEnum {
    case keep, h2160, h1440, h1080, h720, h480, h360
    var label: String {
        switch self {
        case .keep: return "Keep original"
        case .h2160: return "Downscale to 2160p"
        case .h1440: return "Downscale to 1440p"
        case .h1080: return "Downscale to 1080p"
        case .h720: return "Downscale to 720p"
        case .h480: return "Downscale to 480p"
        case .h360: return "Downscale to 360p"
        }
    }
    var height: Int? {
        switch self {
        case .keep: return nil
        case .h2160: return 2160
        case .h1440: return 1440
        case .h1080: return 1080
        case .h720: return 720
        case .h480: return 480
        case .h360: return 360
        }
    }
}

enum AudioBitrate: String, OptionEnum {
    case b96, b128, b160, b192, b256, b320
    var label: String { value.replacingOccurrences(of: "k", with: " kbps") }
    var value: String {
        switch self {
        case .b96: return "96k"
        case .b128: return "128k"
        case .b160: return "160k"
        case .b192: return "192k"
        case .b256: return "256k"
        case .b320: return "320k"
        }
    }
}

// MARK: - Chapters, SponsorBlock, subtitles, metadata

enum SponsorBlockMode: String, OptionEnum {
    case off, mark, remove
    var label: String {
        switch self {
        case .off: return "Off"
        case .mark: return "Mark as chapters"
        case .remove: return "Cut out"
        }
    }
}

enum SponsorCategory: String, OptionEnum {
    case sponsor, intro, outro, selfpromo, preview, filler, interaction
    case musicOfftopic = "music_offtopic"
    case poiHighlight = "poi_highlight"
    case chapter
    var label: String {
        switch self {
        case .sponsor: return "Sponsor"
        case .intro: return "Intro / intermission"
        case .outro: return "Outro / endcards"
        case .selfpromo: return "Self-promotion"
        case .preview: return "Preview / recap"
        case .filler: return "Filler tangent"
        case .interaction: return "Subscribe reminders"
        case .musicOfftopic: return "Non-music section"
        case .poiHighlight: return "Highlight (mark only)"
        case .chapter: return "Community chapters (mark only)"
        }
    }
    var removable: Bool { self != .poiHighlight && self != .chapter }
}

enum SubtitleFormat: String, OptionEnum {
    case best, srt, vtt, ass, lrc
    var label: String {
        switch self {
        case .best: return "Original format"
        case .srt: return "SRT"
        case .vtt: return "WebVTT"
        case .ass: return "ASS / SSA"
        case .lrc: return "LRC (lyrics)"
        }
    }
}

enum ThumbnailFormat: String, OptionEnum {
    case original, jpg, png, webp
    var label: String {
        switch self {
        case .original: return "Original"
        case .jpg: return "JPEG"
        case .png: return "PNG"
        case .webp: return "WebP"
        }
    }
}

// MARK: - Playlist, network, output

enum PlaylistMode: String, OptionEnum {
    case auto, single, full
    var label: String {
        switch self {
        case .auto: return "Let yt-dlp decide"
        case .single: return "Only the video in the URL"
        case .full: return "Entire playlist"
        }
    }
}

enum CookieBrowser: String, OptionEnum {
    case none, safari, chrome, firefox, brave, edge, chromium, opera, vivaldi
    var label: String { self == .none ? "Don't use cookies" : rawValue.capitalized }
}

enum FilenameTemplate: String, OptionEnum {
    case titleOnly, titleID, uploaderTitle, dateTitle, uploaderFolder, playlistFolder
    case artistTitle, musicLibrary, custom
    var label: String {
        switch self {
        case .titleOnly: return "Title"
        case .titleID: return "Title [ID]"
        case .uploaderTitle: return "Channel - Title"
        case .dateTitle: return "Upload date - Title"
        case .uploaderFolder: return "Channel folder / Title"
        case .playlistFolder: return "Playlist folder / Index - Title"
        case .artistTitle: return "Artist - Song (music)"
        case .musicLibrary: return "Artist / Album / 01 Song (music library)"
        case .custom: return "Custom…"
        }
    }
    var template: String {
        switch self {
        case .titleOnly: return "%(title)s.%(ext)s"
        case .titleID: return "%(title)s [%(id)s].%(ext)s"
        case .uploaderTitle: return "%(uploader)s - %(title)s.%(ext)s"
        case .dateTitle: return "%(upload_date>%Y-%m-%d)s - %(title)s.%(ext)s"
        case .uploaderFolder: return "%(uploader)s/%(title)s.%(ext)s"
        case .playlistFolder: return "%(playlist_title|Singles)s/%(playlist_index&{} - |)s%(title)s.%(ext)s"
        // meta_* fields are filled in by the music-tag rules; the fallbacks keep these working without them.
        case .artistTitle: return "%(meta_artist,artist,uploader)s - %(meta_title,track,title)s.%(ext)s"
        case .musicLibrary: return "%(meta_album_artist,album_artist,artist,uploader)s/%(meta_album,album,playlist_title,title)s/%(track_number,playlist_index&{:02d} |)s%(meta_title,track,title)s.%(ext)s"
        case .custom: return ""
        }
    }
}

// MARK: - The full option set

struct DownloadOptions: Codable, Equatable {
    // Format
    var mode: DownloadMode = .video
    var container: VideoContainer = .mp4
    var maxResolution: MaxResolution = .best
    var videoCodec: VideoCodecPref = .any
    var audioCodec: AudioCodecPref = .any
    var fpsLimit: FPSLimit = .any
    var preferCompatibleStreams = true
    var preferFreeFormats = false
    var forceRemux = true
    var customFormat = ""
    var customSort = ""

    // Audio extraction
    var audioFormat: AudioFormat = .mp3
    var audioQuality: AudioQuality = .q0

    // Audio filters (FFmpeg)
    var normalizeAudio = false
    var volumeDB: Double = 0
    var sampleRate: SampleRate = .keep
    var channels: ChannelLayout = .keep

    // Re-encode (FFmpeg)
    var encodeEnabled = false
    var encoder: VideoEncoder = .vtHEVC
    var crf: Double = 23
    var preset: EncoderPreset = .medium
    var hwBitrateMbps: Double = 6
    var scale: ScaleHeight = .keep
    var encodeAudio = true
    var encodeAudioBitrate: AudioBitrate = .b192
    var replaceOriginal = false
    var customPPA = ""

    // Chapters & SponsorBlock
    var chapterSource: ChapterSource = .youtube
    var embedChapters = true
    var splitChapters = false
    var chaptersInFolder = true
    var removeChaptersRegex = ""
    var sponsorBlockMode: SponsorBlockMode = .off
    var sponsorCategories: [SponsorCategory] = [.sponsor, .selfpromo, .interaction]
    var preciseCuts = true

    // Subtitles
    var writeSubs = false
    var writeAutoSubs = false
    var subLangs = "en.*"
    var subFormat: SubtitleFormat = .srt
    var embedSubs = false

    // Metadata & thumbnails
    var embedMetadata = true
    var embedThumbnail = true
    var writeThumbnail = false
    var thumbnailFormat: ThumbnailFormat = .original
    var writeDescription = false
    var writeInfoJSON = false
    var writeComments = false

    // Music tags (audio players): fixes title/artist/album/track/year and cover art
    var musicTags = true
    var musicTagsOnVideo = false
    var cleanTitles = true
    var stripTitleNumbers = true
    var splitArtistTitle = true
    var trackNumbers = true
    var albumFallback = true
    var squareCover = true
    var tagChapterTracks = true
    var genre = ""

    // Trim
    var trimEnabled = false
    var trimStart = "00:00:00"
    var trimEnd = ""
    var forceKeyframes = false

    // Playlist
    var playlistMode: PlaylistMode = .auto
    var playlistItems = ""
    var useArchive = false

    // Network
    var rateLimit = ""
    var concurrentFragments = 4
    var retries = 10
    var proxy = ""
    var cookieBrowser: CookieBrowser = .none
    var sleepInterval = 0

    // Output
    var outputDirectory: String = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
    var filenameTemplate: FilenameTemplate = .titleOnly
    var customTemplate = "%(title)s [%(id)s].%(ext)s"
    var restrictFilenames = false
    var noOverwrites = true
    var noMtime = true
    var keepIntermediateFiles = false

    // Advanced
    var extraArgs = ""

    // Derived helpers
    var thumbnailEmbeddable: Bool {
        mode == .audio ? ![.wav, .aac].contains(audioFormat) : container.supportsThumbnailEmbed
    }
    var audioFiltersActive: Bool {
        normalizeAudio || volumeDB != 0 || sampleRate != .keep || channels != .keep
    }
    /// Segments are cut out of a video (SponsorBlock or chapter removal). Without keyframes at the
    /// cuts, stream-copied video restarts at the previous keyframe and replays or freezes footage.
    var cutsVideoSegments: Bool {
        mode != .audio && (sponsorBlockMode == .remove || !removeChaptersRegex.trimmed.isEmpty)
    }
    var forcesKeyframes: Bool {
        (trimEnabled && forceKeyframes) || (cutsVideoSegments && preciseCuts)
    }
    /// The download is finished as an iPhone ringtone (.m4r).
    var makesRingtone: Bool { mode == .audio && audioFormat.isRingtone }
    /// Music tagging is active for this download.
    var musicTagsActive: Bool {
        embedMetadata && musicTags && (mode == .audio || musicTagsOnVideo)
    }
    /// Chapter files will be retagged one by one after splitting.
    var retagsChapters: Bool {
        musicTagsActive && splitChapters && tagChapterTracks && mode == .audio
    }
    var archivePath: String {
        (outputDirectory as NSString).appendingPathComponent("yt-dlp-archive.txt")
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
