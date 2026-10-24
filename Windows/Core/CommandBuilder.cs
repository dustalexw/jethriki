using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
namespace YtdlpStudio.Core;

public static class CommandBuilder {
    public const string ProgressPrefix = "[[PROG]]";
    public const string JunkTitlePattern = @"(?i)\s*[\(\[][^\)\]]*\b(?:official|lyrics?|lyric video|audio|visuali[sz]er|music video|video|hd|hq|4k|remaster(?:ed)?(?: \d{4})?|full album|full ep|album stream)\b[^\)\]]*[\)\]]";
    public const string LeadingTrackNumber = @"(?:(?:track|no\.?)\s*)?(?:#?\d{1,3}\s*[.:)\-–—](?!\d)\s*|[\[(]\d{1,3}[\])]\s*|0\d\s+)";
    public static string NumberPattern(string group) => @"(?i)^\s*(?:" + LeadingTrackNumber + @")?(?P<" + group + @">.+?)\s*$";
    static string N(double n) => n.ToString("0.###", CultureInfo.InvariantCulture);
    public static List<string> Arguments(DownloadOptions o, IEnumerable<string> urls, ToolPaths? tools = null,
        string? pathsFile = null, string? chaptersFile = null, string? tempDirectory = null, string? infoFile = null) {
        Validate(o);
        var a = new List<string> { "--ignore-config", "--windows-filenames" };
        void Add(params string[] values) => a.AddRange(values);
        void Flag(bool on, string flag) { if (on) a.Add(flag); }
        if (tools != null) {
            Add("--ffmpeg-location", Path.GetDirectoryName(tools.Ffmpeg)!);
            Add("--js-runtimes", "deno:" + tools.Deno);
            Add("--newline", "--no-colors", "--progress", "--progress-template", "download:" + ProgressPrefix + "%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress._total_bytes_str)s|%(progress._total_bytes_estimate_str)s|%(info.title)s");
        }
        if (pathsFile != null) Add("--print-to-file", "after_move:filepath", pathsFile);
        if (chaptersFile != null) Add("--print-to-file", "after_move:%(chapters)j", chaptersFile);
        if (tempDirectory != null) Add("-P", "temp:" + tempDirectory);
        var fallback = o.Mode switch { "audio" => "ba/b", "videoOnly" => "bv/bv*", _ => "bv*+ba/b" };
        Add("-f", string.IsNullOrWhiteSpace(o.CustomFormat) ? fallback : o.CustomFormat.Trim());
        var sort = Sort(o); if (sort.Length > 0) Add("-S", sort);
        if (o.Mode == "audio") {
            Add("-x", "--audio-format", o.AudioFormat == "m4r" ? "m4a" : o.AudioFormat);
            if (!new[] { "flac", "alac", "wav" }.Contains(o.AudioFormat)) Add("--audio-quality", o.AudioQuality.StartsWith('q') ? o.AudioQuality[1..] : o.AudioQuality[1..] + "K");
            var filters = AudioFilters(o);
            if (o.AudioFormat == "m4r") Add("--postprocessor-args", "ExtractAudio+ffmpeg_o:" + string.Join(' ', Ringtone.FfmpegArguments(o)));
            else if (filters.Count > 0 && o.AudioFormat != "best") Add("--postprocessor-args", "ExtractAudio+ffmpeg_o:" + string.Join(' ', filters));
        } else {
            if (o.Mode == "video") Add("--merge-output-format", o.Container);
            if (o.ForceRemux) Add("--remux-video", o.Container switch { "webm" => "mp4>mkv/mkv>mkv/webm", "mov" => "webm>mp4/mov", "avi" or "flv" => "webm>mkv/" + o.Container, _ => o.Container });
            Flag(o.PreferFreeFormats, "--prefer-free-formats");
        }
        Flag(o.KeepIntermediateFiles, "-k");
        if (!string.IsNullOrWhiteSpace(o.CustomPPA)) Add("--postprocessor-args", o.CustomPPA.Trim());
        if (o.TrimEnabled) Add("--download-sections", "*" + (string.IsNullOrWhiteSpace(o.TrimStart) ? "0" : o.TrimStart.Trim()) + "-" + (string.IsNullOrWhiteSpace(o.TrimEnd) ? "inf" : o.TrimEnd.Trim()));
        Flag(o.ForcesKeyframes, "--force-keyframes-at-cuts");
        Flag(o.EmbedChapters, "--embed-chapters"); Flag(o.SplitChapters, "--split-chapters");
        if (o.SplitChapters && o.Mode == "audio" && o.EmbedThumbnail && new[] { "opus", "vorbis", "best" }.Contains(o.AudioFormat)) Add("--postprocessor-args", "SplitChapters+ffmpeg_o:-map -0:v?");
        if (!string.IsNullOrWhiteSpace(o.RemoveChaptersRegex)) Add("--remove-chapters", o.RemoveChaptersRegex.Trim());
        var categories = o.SponsorCategories.Where(c => o.SponsorBlockMode != "remove" || (c != "chapter" && c != "poi_highlight")).ToArray();
        if (o.SponsorBlockMode != "off" && categories.Length > 0) Add(o.SponsorBlockMode == "remove" ? "--sponsorblock-remove" : "--sponsorblock-mark", string.Join(',', categories));
        Flag(o.WriteSubs, "--write-subs"); Flag(o.WriteAutoSubs, "--write-auto-subs");
        if (o.WriteSubs || o.WriteAutoSubs || o.EmbedSubs) {
            Add("--sub-langs", string.IsNullOrWhiteSpace(o.SubLangs) ? "en.*" : o.SubLangs.Trim());
            if (o.SubFormat != "best") Add("--sub-format", o.SubFormat + "/best", "--convert-subs", o.SubFormat);
        }
        Flag(o.EmbedSubs && o.Mode != "audio", "--embed-subs");
        if (o.EmbedMetadata) {
            Add("--embed-metadata");
            if (o.MusicTagsActive) Add(MusicTagArguments(o).ToArray());
            var meta = new List<string>();
            if (o.Mode == "audio") meta.AddRange(["-map_metadata:s:a", "-1"]);
            if (o.MusicTagsActive && !string.IsNullOrWhiteSpace(o.Genre)) meta.AddRange(["-metadata", "genre=" + o.Genre.Trim()]);
            if (meta.Count > 0) Add("--postprocessor-args", "Metadata+ffmpeg_o:" + string.Join(' ', meta.Select(FfmpegQuote)));
        }
        bool embeddable = o.Mode == "audio" ? o.AudioFormat is not ("wav" or "aac") : o.Container is "mp4" or "mkv" or "mov";
        Flag(o.EmbedThumbnail && embeddable, "--embed-thumbnail"); Flag(o.WriteThumbnail, "--write-thumbnail");
        if (o.MusicTagsActive && o.SquareCover && o.Mode == "audio" && ((o.EmbedThumbnail && embeddable) || o.WriteThumbnail)) Add("--convert-thumbnails", "jpg>png/jpg", "--postprocessor-args", "ThumbnailsConvertor+ffmpeg_o:-q:v 2 -vf crop=\"'min(iw,ih)':'min(iw,ih)'\"");
        else if (o.ThumbnailFormat != "original" && (o.WriteThumbnail || o.EmbedThumbnail)) Add("--convert-thumbnails", o.ThumbnailFormat);
        Flag(o.WriteDescription, "--write-description"); Flag(o.WriteInfoJSON, "--write-info-json"); Flag(o.WriteComments, "--write-comments");
        Add(ExtractionOptions(o, includePlaylistItems: infoFile == null).ToArray());
        if (o.UseArchive) Add("--download-archive", Path.Combine(o.OutputDirectory, "yt-dlp-archive.txt"));
        if (!string.IsNullOrWhiteSpace(o.RateLimit)) Add("-r", o.RateLimit.Trim());
        if (o.ConcurrentFragments > 1) Add("-N", o.ConcurrentFragments.ToString());
        if (o.SleepInterval > 0) Add("--sleep-interval", o.SleepInterval.ToString());
        Add("-P", o.OutputDirectory, "-o", OutputTemplate(o));
        if (o.SplitChapters && o.ChaptersInFolder) Add("-o", "chapter:%(title)s/%(section_number)03d - %(section_title)s.%(ext)s");
        Flag(o.RestrictFilenames, "--restrict-filenames"); Flag(o.NoOverwrites, "--no-overwrites"); Flag(o.NoMtime, "--no-mtime");
        Add(Tokenize(o.ExtraArgs).ToArray());
        if (infoFile != null) Add("--no-clean-info-json", "--load-info-json", infoFile);
        else { Add("--"); Add(urls.ToArray()); }
        return a;
    }
    public static List<string> ExtractionOptions(DownloadOptions o, bool includePlaylistItems = true) {
        var a = new List<string>();
        if (o.CookieBrowser != "none") a.AddRange(["--cookies-from-browser", o.CookieBrowser]);
        if (!string.IsNullOrWhiteSpace(o.Proxy)) a.AddRange(["--proxy", o.Proxy.Trim()]);
        if (o.Retries != 10) a.AddRange(["--extractor-retries", o.Retries.ToString(), "-R", o.Retries.ToString()]);
        if (o.PlaylistMode != "auto") a.Add(o.PlaylistMode == "single" ? "--no-playlist" : "--yes-playlist");
        if (includePlaylistItems && !string.IsNullOrWhiteSpace(o.PlaylistItems)) a.AddRange(["-I", o.PlaylistItems.Trim()]);
        // Carry extraction-specific advanced arguments into Analyze/comment fetching, without running postprocessors.
        var extra = Tokenize(o.ExtraArgs);
        var valued = new HashSet<string> { "--cookies", "--cookies-from-browser", "--extractor-args", "--user-agent", "--referer", "--add-header", "--socket-timeout", "--extractor-retries", "--proxy" };
        for (int i = 0; i < extra.Count; i++) {
            if (valued.Contains(extra[i]) && i + 1 < extra.Count) { a.Add(extra[i]); a.Add(extra[++i]); }
            else if (extra[i] is "--enable-file-urls" or "--no-check-certificates" or "--geo-bypass") a.Add(extra[i]);
        }
        return a;
    }
    public static string Sort(DownloadOptions o) {
        if (!string.IsNullOrWhiteSpace(o.CustomSort)) return o.CustomSort.Trim();
        var t = new List<string>();
        if (o.Mode == "audio") { if (o.AudioFormat is "m4a" or "aac" or "m4r") t.Add("acodec:aac"); if (o.AudioFormat == "opus") t.Add("acodec:opus"); }
        else {
            if (o.MaxResolution != "best") t.Add("res:" + o.MaxResolution[1..]);
            if (o.FpsLimit != "any") t.Add("fps:" + o.FpsLimit[3..]);
            if (o.VideoCodec != "any") t.Add("vcodec:" + (o.VideoCodec == "av1" ? "av01" : o.VideoCodec));
            if (o.Mode == "video" && o.AudioCodec != "any") t.Add("acodec:" + o.AudioCodec);
            if (o.PreferCompatibleStreams && o.Container is "mp4" or "mov") t.Add("ext:mp4:m4a");
            if (o.PreferCompatibleStreams && o.Container == "webm") t.Add("ext:webm:webm");
        }
        return string.Join(',', t);
    }
    public static List<string> MusicTagArguments(DownloadOptions o) {
        var a = new List<string>();
        if (o.CleanTitles) a.AddRange(["--replace-in-metadata", "title,track", JunkTitlePattern, "", "--replace-in-metadata", "uploader,channel", @"(?i)\s*(?:-\s*topic|vevo|official)$", ""]);
        var source = "title";
        if (o.StripTitleNumbers) { a.AddRange(["--parse-metadata", "title:" + NumberPattern("studio_title")]); source = "studio_title"; }
        if (o.SplitArtistTitle) a.AddRange(["--parse-metadata", source + @":^(?P<meta_artist>.+?)\s+[-–—]\s+(?P<meta_title>.+)$"]);
        if (o.StripTitleNumbers) a.AddRange(["--parse-metadata", "%(meta_title,track,studio_title|)s:" + NumberPattern("meta_title")]);
        if (o.TrackNumbers) a.AddRange(["--parse-metadata", @"%(track_number,playlist_index|)s/%(n_entries|)s:^(?P<meta_track>\d+(?:/\d+)?)"]);
        if (o.AlbumFallback) a.AddRange(["--parse-metadata", @"%(album,playlist_title,meta_title,track,title|)s:^(?P<meta_album>.+)$"]);
        a.AddRange(["--parse-metadata", @"%(album_artist,meta_artist,artist,uploader|)s:^(?P<meta_album_artist>.+)$", "--parse-metadata", @"%(release_year,upload_date|)s:^(?P<meta_date>\d{4})"]);
        return a;
    }
    public static string OutputTemplate(DownloadOptions o) => o.FilenameTemplate switch {
        "titleID" => "%(title)s [%(id)s].%(ext)s", "uploaderTitle" => "%(uploader)s - %(title)s.%(ext)s", "dateTitle" => "%(upload_date>%Y-%m-%d)s - %(title)s.%(ext)s", "uploaderFolder" => "%(uploader)s/%(title)s.%(ext)s", "playlistFolder" => "%(playlist_title|Singles)s/%(playlist_index&{} - |)s%(title)s.%(ext)s", "artistTitle" => "%(meta_artist,artist,uploader)s - %(meta_title,track,title)s.%(ext)s", "musicLibrary" => "%(meta_album_artist,album_artist,artist,uploader)s/%(meta_album,album,playlist_title,title)s/%(track_number,playlist_index&{:02d} |)s%(meta_title,track,title)s.%(ext)s", "custom" when !string.IsNullOrWhiteSpace(o.CustomTemplate) => o.CustomTemplate.Trim(), _ => "%(title)s.%(ext)s"
    };
    public static List<string> FilterChain(DownloadOptions o) {
        var filters = new List<string>();
        if (o.VolumeDB != 0) filters.Add("volume=" + N(o.VolumeDB) + "dB");
        if (o.NormalizeAudio) filters.Add("loudnorm=I=-16:TP=-1.5:LRA=11");
        return filters;
    }
    public static List<string> AudioFilters(DownloadOptions o) {
        var filters = FilterChain(o); var a = new List<string>();
        if (filters.Count > 0) a.AddRange(["-af", string.Join(',', filters)]);
        if (o.SampleRate != "keep") a.AddRange(["-ar", o.SampleRate[1..]]);
        if (o.Channels != "keep") a.AddRange(["-ac", o.Channels == "mono" ? "1" : "2"]);
        return a;
    }
    public static List<string> EncodeArguments(string input, string output, DownloadOptions o) {
        var a = new List<string> { "-hide_banner", "-nostdin", "-y", "-i", input, "-map", "0:v:0", "-map", "0:a?", "-map", "0:s?", "-map_metadata", "0", "-map_chapters", "0", "-c:v", o.Encoder };
        if (o.Encoder is "libx264" or "libx265") a.AddRange(["-crf", N(o.Crf), "-preset", o.Preset]);
        else if (o.Encoder == "libvpx-vp9") a.AddRange(["-crf", N(o.Crf), "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "2"]);
        else if (o.Encoder == "libsvtav1") {
            var names = new[] { "ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow" };
            int index = Math.Max(0, Array.IndexOf(names, o.Preset));
            a.AddRange(["-crf", N(o.Crf), "-preset", new[] { 12, 11, 10, 9, 8, 6, 5, 4, 3 }[index].ToString()]);
        } else if (o.Encoder == "prores_ks") a.AddRange(["-profile:v", "3", "-pix_fmt", "yuv422p10le"]);
        else a.AddRange(["-b:v", N(o.HwBitrateMbps) + "M"]);
        if (o.Encoder.StartsWith("h264") || o.Encoder == "libx264") a.AddRange(["-pix_fmt", "yuv420p"]);
        if (o.Scale != "keep") a.AddRange(["-vf", "scale=-2:'min(" + o.Scale[1..] + ",ih)'"]);
        var af = AudioFilters(o);
        if (o.EncodeAudio || af.Count > 0) { a.AddRange(["-c:a", o.Container == "webm" ? "libopus" : "aac", "-b:a", o.EncodeAudioBitrate[1..] + "k"]); a.AddRange(af); }
        else a.AddRange(["-c:a", "copy"]);
        a.AddRange(o.Container switch { "mp4" or "mov" => ["-c:s", "mov_text", "-movflags", "+faststart"], "webm" => ["-c:s", "webvtt"], "mkv" => ["-c:s", "copy"], _ => new[] { "-sn" } });
        a.AddRange(["-progress", "pipe:1", "-nostats", output]); return a;
    }
    public static void Validate(DownloadOptions o) {
        if (string.IsNullOrWhiteSpace(o.OutputDirectory)) throw new ArgumentException("Choose a download folder.");
        if (o.MaxConcurrent is < 1 or > 8) throw new ArgumentException("Simultaneous downloads must be between 1 and 8.");
        if (o.EncodeEnabled && o.Mode != "audio") {
            var allowed = o.Encoder switch { "prores_ks" => new[] { "mov", "mkv" }, "libvpx-vp9" => ["webm", "mkv", "mp4"], "libsvtav1" => ["mkv", "mp4", "webm"], "libx264" or "h264_nvenc" or "h264_qsv" or "h264_amf" => ["mp4", "mkv", "mov", "avi", "flv"], _ => ["mp4", "mkv", "mov"] };
            if (!allowed.Contains(o.Container)) throw new ArgumentException("The selected encoder cannot write " + o.Container.ToUpperInvariant() + ". Choose " + string.Join(" or ", allowed) + ".");
        }
        _ = Tokenize(o.ExtraArgs);
    }
    // Parse quoted tokens without consuming Windows path separators. No command shell is involved.
    public static List<string> Tokenize(string text) {
        var output = new List<string>(); var token = new StringBuilder(); char quote = '\0'; bool started = false;
        for (int i = 0; i < text.Length; i++) {
            char c = text[i];
            if (c == '\\' && i + 1 < text.Length && (text[i + 1] == '"' || text[i + 1] == '\'') && quote == text[i + 1]) { token.Append(text[++i]); started = true; }
            else if (quote != '\0') { if (c == quote) quote = '\0'; else token.Append(c); started = true; }
            else if (c is '"' or '\'') { quote = c; started = true; }
            else if (char.IsWhiteSpace(c)) { if (started) { output.Add(token.ToString()); token.Clear(); started = false; } }
            else { token.Append(c); started = true; }
        }
        if (quote != '\0') throw new ArgumentException("An argument has an unclosed quote.");
        if (started) output.Add(token.ToString()); return output;
    }
    // Shell quoting for the Copy command (PowerShell on Windows, POSIX sh elsewhere); the actual runner uses ProcessStartInfo.ArgumentList.
    public static string Display(string executable, IEnumerable<string> args) => OperatingSystem.IsWindows()
        ? "& " + string.Join(' ', new[] { executable }.Concat(args).Select(s => "'" + s.Replace("'", "''") + "'"))
        : string.Join(' ', new[] { executable }.Concat(args).Select(PosixQuote));
    static string PosixQuote(string s) => s.Length > 0 && s.All(c => char.IsAsciiLetterOrDigit(c) || "-_./:=+,%@".Contains(c)) ? s : "'" + s.Replace("'", "'\\''") + "'";
    static string FfmpegQuote(string value) => "'" + value.Replace("'", "'\\''") + "'";
}
