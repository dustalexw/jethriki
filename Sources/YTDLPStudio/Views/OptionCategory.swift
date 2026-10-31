import Foundation

/// The pages of download options, shared by the macOS sidebar and the iOS options list.
enum OptionCategory: String, CaseIterable, Identifiable {
    case format, audio, encode, chapters, subtitles, metadata, trim, playlist, network, output, advanced
    var id: Self { self }
    var title: String {
        switch self {
        case .format: return "Format & Quality"
        case .audio: return "Audio"
        case .encode: return "FFmpeg Encode"
        case .chapters: return "Chapters & SponsorBlock"
        case .subtitles: return "Subtitles"
        case .metadata: return "Metadata & Thumbnails"
        case .trim: return "Trim"
        case .playlist: return "Playlist"
        case .network: return "Network & Login"
        case .output: return "Output"
        case .advanced: return "Advanced"
        }
    }
    var symbol: String {
        switch self {
        case .format: return "film.stack"
        case .audio: return "waveform"
        case .encode: return "wand.and.stars"
        case .chapters: return "list.bullet.rectangle"
        case .subtitles: return "captions.bubble"
        case .metadata: return "tag"
        case .trim: return "scissors"
        case .playlist: return "music.note.list"
        case .network: return "network"
        case .output: return "folder"
        case .advanced: return "terminal"
        }
    }
    func isCustomized(_ o: DownloadOptions) -> Bool {
        let d = DownloadOptions()
        switch self {
        case .format: return !o.customFormat.isEmpty || !o.customSort.isEmpty || o.maxResolution != .best || o.videoCodec != .any
        case .audio: return o.audioFiltersActive
        case .encode: return o.encodeEnabled || !o.customPPA.isEmpty
        case .chapters: return o.chapterSource != .youtube || o.splitChapters || o.sponsorBlockMode != .off || !o.removeChaptersRegex.isEmpty
        case .subtitles: return o.writeSubs || o.writeAutoSubs || o.embedSubs
        case .metadata: return o.writeThumbnail || o.writeInfoJSON || o.writeDescription || o.writeComments
        case .trim: return o.trimEnabled
        case .playlist: return o.playlistMode != .auto || !o.playlistItems.isEmpty || o.useArchive
        case .network: return !o.rateLimit.isEmpty || !o.proxy.isEmpty || o.cookieBrowser != .none || !o.cookiesFile.isEmpty || o.sleepInterval > 0
        case .output: return o.filenameTemplate != d.filenameTemplate || o.restrictFilenames
        case .advanced: return !o.extraArgs.trimmed.isEmpty
        }
    }
}
