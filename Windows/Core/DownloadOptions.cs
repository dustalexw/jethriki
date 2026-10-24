using System.Text.Json;
namespace YtdlpStudio.Core;

[AttributeUsage(AttributeTargets.Property)]
public sealed class SettingAttribute(string category, string label) : Attribute {
    public string Category { get; } = category;
    public string Label { get; } = label;
    public string Choices { get; set; } = "";
    public string Hint { get; set; } = "";
    public double Min { get; set; } = 0;
    public double Max { get; set; } = 100000;
}

public sealed class DownloadOptions {
    [Setting("Format & quality", "Download type", Choices = "video=Video and audio|audio=Audio only|videoOnly=Video only")]
    public string Mode { get; set; } = "video";

    [Setting("Format & quality", "Container", Choices = "mp4=MP4|mkv=MKV|webm=WebM|mov=MOV|avi=AVI|flv=FLV")]
    public string Container { get; set; } = "mp4";

    [Setting("Format & quality", "Maximum resolution", Choices = "best=Best available|p4320=4320p (8K)|p2160=2160p (4K)|p1440=1440p|p1080=1080p|p720=720p|p480=480p|p360=360p|p240=240p|p144=144p")]
    public string MaxResolution { get; set; } = "best";

    [Setting("Format & quality", "Video Codec", Choices = "any=No preference|h264=H.264|h265=HEVC|vp9=VP9|av1=AV1")]
    public string VideoCodec { get; set; } = "any";

    [Setting("Format & quality", "Audio Codec", Choices = "any=No preference|aac=AAC|opus=Opus")]
    public string AudioCodec { get; set; } = "any";

    [Setting("Format & quality", "Frame rate", Choices = "any=Highest available|fps60=Up to 60 fps|fps30=Up to 30 fps|fps24=Up to 24 fps")]
    public string FpsLimit { get; set; } = "any";

    [Setting("Format & quality", "Prefer streams that fit the container")]
    public bool PreferCompatibleStreams { get; set; } = true;

    [Setting("Format & quality", "Prefer Free Formats")]
    public bool PreferFreeFormats { get; set; } = false;

    [Setting("Format & quality", "Remux to the selected container")]
    public bool ForceRemux { get; set; } = true;

    [Setting("Format & quality", "Custom format selector")]
    public string CustomFormat { get; set; } = "";

    [Setting("Format & quality", "Custom format sorting")]
    public string CustomSort { get; set; } = "";

    [Setting("Audio", "Audio Format", Choices = "mp3=MP3|m4a=M4A (AAC)|aac=AAC|opus=Opus|vorbis=Ogg Vorbis|flac=FLAC|alac=ALAC|wav=WAV|m4r=iPhone ringtone (M4R)|best=Keep original codec", Hint = "iPhone ringtone saves an .m4r file ready for iTunes, Apple Devices or Finder: AAC, at most 40 seconds, with a short fade in and out. Use Trim to choose which part of the song plays.")]
    public string AudioFormat { get; set; } = "mp3";

    [Setting("Audio", "Audio Quality", Choices = "q0=VBR best|q2=VBR high|q5=VBR medium|k320=320 kbps|k256=256 kbps|k192=192 kbps|k160=160 kbps|k128=128 kbps|k96=96 kbps|k64=64 kbps")]
    public string AudioQuality { get; set; } = "q0";

    [Setting("Audio", "Normalize Audio")]
    public bool NormalizeAudio { get; set; } = false;

    [Setting("Audio", "Volume gain (dB)", Min = -60, Max = 60)]
    public double VolumeDB { get; set; } = 0;

    [Setting("Audio", "Sample Rate", Choices = "keep=Keep original|r22050=22.05 kHz|r44100=44.1 kHz|r48000=48 kHz|r96000=96 kHz")]
    public string SampleRate { get; set; } = "keep";

    [Setting("Audio", "Audio channels", Choices = "keep=Keep original|mono=Mono|stereo=Stereo")]
    public string Channels { get; set; } = "keep";

    [Setting("FFmpeg encode", "Re-encode downloaded videos")]
    public bool EncodeEnabled { get; set; } = false;

    [Setting("FFmpeg encode", "Encoder", Choices = "libx264=H.264 (x264 software)|libx265=HEVC (x265 software)|h264_nvenc=H.264 (NVIDIA)|hevc_nvenc=HEVC (NVIDIA)|h264_qsv=H.264 (Intel)|hevc_qsv=HEVC (Intel)|h264_amf=H.264 (AMD)|hevc_amf=HEVC (AMD)|libvpx-vp9=VP9|libsvtav1=AV1 (SVT-AV1)|prores_ks=ProRes 422 HQ", Hint = "Hardware encoders require compatible graphics hardware and drivers. Software encoders work on every supported PC.")]
    public string Encoder { get; set; } = "libx265";

    [Setting("FFmpeg encode", "Quality (CRF)", Max = 63)]
    public double Crf { get; set; } = 23;

    [Setting("FFmpeg encode", "Encoder speed", Choices = "ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow")]
    public string Preset { get; set; } = "medium";

    [Setting("FFmpeg encode", "Hardware encoder bitrate (Mbps)", Min = 0.1, Max = 1000)]
    public double HwBitrateMbps { get; set; } = 6;

    [Setting("FFmpeg encode", "Downscale height", Choices = "keep=Keep original|h2160=2160p|h1440=1440p|h1080=1080p|h720=720p|h480=480p|h360=360p")]
    public string Scale { get; set; } = "keep";

    [Setting("FFmpeg encode", "Encode Audio")]
    public bool EncodeAudio { get; set; } = true;

    [Setting("FFmpeg encode", "Encode Audio Bitrate", Choices = "b96=96 kbps|b128=128 kbps|b160=160 kbps|b192=192 kbps|b256=256 kbps|b320=320 kbps")]
    public string EncodeAudioBitrate { get; set; } = "b192";

    [Setting("FFmpeg encode", "Replace original after encoding (Recycle Bin)")]
    public bool ReplaceOriginal { get; set; } = false;

    [Setting("FFmpeg encode", "Custom postprocessor arguments")]
    public string CustomPPA { get; set; } = "";

    [Setting("Chapters & SponsorBlock", "Chapter source", Choices = "youtube=YouTube chapters|comments=Comments|commentsIfMissing=Comments if chapters are missing", Hint = "Comments are searched among the first 200 top-level comments. Use Find comment chapters to preview a list for a video.")]
    public string ChapterSource { get; set; } = "youtube";

    [Setting("Chapters & SponsorBlock", "Embed Chapters")]
    public bool EmbedChapters { get; set; } = true;

    [Setting("Chapters & SponsorBlock", "Split Chapters")]
    public bool SplitChapters { get; set; } = false;

    [Setting("Chapters & SponsorBlock", "Put chapter files in a video folder")]
    public bool ChaptersInFolder { get; set; } = true;

    [Setting("Chapters & SponsorBlock", "Remove chapter titles matching a regex")]
    public string RemoveChaptersRegex { get; set; } = "";

    [Setting("Chapters & SponsorBlock", "Sponsor Block Mode", Choices = "off=Off|mark=Mark chapters|remove=Cut segments")]
    public string SponsorBlockMode { get; set; } = "off";

    [Setting("Chapters & SponsorBlock", "SponsorBlock categories", Choices = "sponsor=Sponsor|intro=Intro|outro=Outro|selfpromo=Self promotion|preview=Preview|filler=Filler|interaction=Subscribe reminders|music_offtopic=Non music|poi_highlight=Highlight (mark only)|chapter=Community chapters (mark only)")]
    public string[] SponsorCategories { get; set; } = ["sponsor", "selfpromo", "interaction"];

    [Setting("Chapters & SponsorBlock", "Accurate cuts for removed segments")]
    public bool PreciseCuts { get; set; } = true;

    [Setting("Subtitles", "Write Subs")]
    public bool WriteSubs { get; set; } = false;

    [Setting("Subtitles", "Write Auto Subs")]
    public bool WriteAutoSubs { get; set; } = false;

    [Setting("Subtitles", "Subtitle languages", Hint = "Comma-separated language codes or patterns; en.* matches English variants.")]
    public string SubLangs { get; set; } = "en.*";

    [Setting("Subtitles", "Sub Format", Choices = "best=Original format|srt=SRT|vtt=WebVTT|ass=ASS|lrc=LRC")]
    public string SubFormat { get; set; } = "srt";

    [Setting("Subtitles", "Embed Subs")]
    public bool EmbedSubs { get; set; } = false;

    [Setting("Metadata & thumbnails", "Embed Metadata")]
    public bool EmbedMetadata { get; set; } = true;

    [Setting("Metadata & thumbnails", "Embed Thumbnail")]
    public bool EmbedThumbnail { get; set; } = true;

    [Setting("Metadata & thumbnails", "Write Thumbnail")]
    public bool WriteThumbnail { get; set; } = false;

    [Setting("Metadata & thumbnails", "Thumbnail Format", Choices = "original=Original|jpg=JPEG|png=PNG|webp=WebP")]
    public string ThumbnailFormat { get; set; } = "original";

    [Setting("Metadata & thumbnails", "Write Description")]
    public bool WriteDescription { get; set; } = false;

    [Setting("Metadata & thumbnails", "Save video metadata (.info.json)")]
    public bool WriteInfoJSON { get; set; } = false;

    [Setting("Metadata & thumbnails", "Save comments in video metadata")]
    public bool WriteComments { get; set; } = false;

    [Setting("Music tags", "Music Tags")]
    public bool MusicTags { get; set; } = true;

    [Setting("Music tags", "Music Tags On Video")]
    public bool MusicTagsOnVideo { get; set; } = false;

    [Setting("Music tags", "Clean Titles")]
    public bool CleanTitles { get; set; } = true;

    [Setting("Music tags", "Remove track numbers from titles")]
    public bool StripTitleNumbers { get; set; } = true;

    [Setting("Music tags", "Split Artist Title")]
    public bool SplitArtistTitle { get; set; } = true;

    [Setting("Music tags", "Track Numbers")]
    public bool TrackNumbers { get; set; } = true;

    [Setting("Music tags", "Album Fallback")]
    public bool AlbumFallback { get; set; } = true;

    [Setting("Music tags", "Square Cover")]
    public bool SquareCover { get; set; } = true;

    [Setting("Music tags", "Title and number split tracks")]
    public bool TagChapterTracks { get; set; } = true;

    [Setting("Music tags", "Genre", Hint = "Optional music genre tag.")]
    public string Genre { get; set; } = "";

    [Setting("Trim", "Download a time range")]
    public bool TrimEnabled { get; set; } = false;

    [Setting("Trim", "Start time")]
    public string TrimStart { get; set; } = "00:00:00";

    [Setting("Trim", "End time (blank means end of video)")]
    public string TrimEnd { get; set; } = "";

    [Setting("Trim", "Frame-accurate trimming")]
    public bool ForceKeyframes { get; set; } = false;

    [Setting("Playlist", "Playlist Mode", Choices = "auto=Automatic|single=Only the video in the URL|full=Entire playlist")]
    public string PlaylistMode { get; set; } = "auto";

    [Setting("Playlist", "Playlist items (for example 1-5,8)")]
    public string PlaylistItems { get; set; } = "";

    [Setting("Playlist", "Remember completed downloads")]
    public bool UseArchive { get; set; } = false;

    [Setting("Network & login", "Rate Limit", Hint = "Blank means unlimited. Examples: 5M, 500K.")]
    public string RateLimit { get; set; } = "";

    [Setting("Network & login", "Concurrent Fragments", Min = 1, Max = 32)]
    public int ConcurrentFragments { get; set; } = 4;

    [Setting("Network & login", "Retries", Max = 1000)]
    public int Retries { get; set; } = 10;

    [Setting("Network & login", "Proxy", Hint = "Example: http://127.0.0.1:8080")]
    public string Proxy { get; set; } = "";

    [Setting("Network & login", "Cookie Browser", Choices = "none=No cookies|chrome=Chrome|firefox=Firefox|brave=Brave|edge=Edge|chromium=Chromium|opera=Opera|vivaldi=Vivaldi", Hint = "Close the browser before importing cookies. Some Chromium browser encryption may require a cookies.txt file in Additional arguments.")]
    public string CookieBrowser { get; set; } = "none";

    [Setting("Network & login", "Sleep Interval")]
    public int SleepInterval { get; set; } = 0;

    [Setting("Output", "Download folder", Hint = "Files are saved here. Each job snapshots this folder when queued.")]
    public string OutputDirectory { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");

    [Setting("Output", "Filename Template", Choices = "titleOnly=Title|titleID=Title and ID|uploaderTitle=Channel and title|dateTitle=Date and title|uploaderFolder=Channel folder|playlistFolder=Playlist folder|artistTitle=Artist and song|musicLibrary=Artist / Album / Song|custom=Custom template")]
    public string FilenameTemplate { get; set; } = "titleOnly";

    [Setting("Output", "Custom Template", Hint = "yt-dlp output template; for example %(title)s [%(id)s].%(ext)s")]
    public string CustomTemplate { get; set; } = "%(title)s [%(id)s].%(ext)s";

    [Setting("Output", "Restrict Filenames")]
    public bool RestrictFilenames { get; set; } = false;

    [Setting("Output", "Do not overwrite existing files")]
    public bool NoOverwrites { get; set; } = true;

    [Setting("Output", "Use download date as file date")]
    public bool NoMtime { get; set; } = true;

    [Setting("Output", "Keep Intermediate Files")]
    public bool KeepIntermediateFiles { get; set; } = false;

    [Setting("Advanced", "Additional yt-dlp arguments", Hint = "Separate arguments with spaces. Quote paths containing spaces; Windows backslashes are preserved. These override matching download options.")]
    public string ExtraArgs { get; set; } = "";

    [Setting("Advanced", "Simultaneous downloads", Min = 1, Max = 8)]
    public int MaxConcurrent { get; set; } = 2;

    /// The download is finished as an iPhone ringtone (.m4r).
    public bool MakesRingtone => Mode == "audio" && AudioFormat == "m4r";
    public bool MusicTagsActive => EmbedMetadata && MusicTags && (Mode == "audio" || MusicTagsOnVideo);
    public bool RetagsChapters => MusicTagsActive && SplitChapters && TagChapterTracks && Mode == "audio";
    public bool ForcesKeyframes => (TrimEnabled && ForceKeyframes) || (Mode != "audio" && PreciseCuts && (SponsorBlockMode == "remove" || !string.IsNullOrWhiteSpace(RemoveChaptersRegex)));
    public DownloadOptions Clone() => JsonSerializer.Deserialize<DownloadOptions>(JsonSerializer.Serialize(this))!;
}
