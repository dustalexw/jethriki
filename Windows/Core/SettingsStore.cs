using System.Text.Json;
namespace YtdlpStudio.Core;

public static class AppPaths {
    public static string DataDirectory => Environment.GetEnvironmentVariable("YTDLP_STUDIO_DATA_DIR") is { Length: > 0 } custom
        ? custom : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "YTDLPStudio");
}
public sealed record Preset(string Name, DownloadOptions Options);
public sealed class AppSettings {
    public DownloadOptions Options { get; set; } = new();
    /// "system", "light" or "dark"; shared by the Windows and Linux apps.
    public string Appearance { get; set; } = "system";
    public List<Preset> Presets { get; set; } = [];
}
public sealed class SettingsStore {
    readonly string path;
    public AppSettings Settings { get; private set; } = new();
    public string? LoadWarning { get; private set; }
    public SettingsStore(string? directory = null) {
        var dir = directory ?? AppPaths.DataDirectory; Directory.CreateDirectory(dir); path = Path.Combine(dir, "settings.json");
        if (!File.Exists(path)) return;
        try {
            Settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path)) ?? new();
            Settings.Options ??= new(); Settings.Presets ??= [];
        } catch (JsonException) {
            File.Copy(path, path + ".invalid-" + DateTime.UtcNow.ToString("yyyyMMddHHmmss"), true);
            LoadWarning = "Saved settings could not be read. A backup was kept next to settings.json; defaults were loaded.";
        }
    }
    public void Save() {
        string temp = path + ".tmp-" + Guid.NewGuid();
        try { File.WriteAllText(temp, JsonSerializer.Serialize(Settings, new JsonSerializerOptions { WriteIndented = true })); File.Move(temp, path, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    public void Apply(Preset preset) { string folder = Settings.Options.OutputDirectory; Settings.Options = preset.Options.Clone(); Settings.Options.OutputDirectory = folder; }
    public void SavePreset(string name) {
        name = name.Trim(); if (name.Length == 0) return;
        Settings.Presets.RemoveAll(p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase));
        Settings.Presets.Add(new(name, Settings.Options.Clone())); Save();
    }
    public static IReadOnlyList<Preset> BuiltIn { get; } = CreateBuiltIns();
    static IReadOnlyList<Preset> CreateBuiltIns() {
        Preset Make(string name, Action<DownloadOptions> edit) { var o = new DownloadOptions(); edit(o); return new(name, o); }
        return [
            Make("Best quality (MKV)", o => { o.Container = "mkv"; o.PreferCompatibleStreams = false; }),
            Make("Compatible MP4 · H.264 · 1080p", o => { o.Container = "mp4"; o.MaxResolution = "p1080"; o.VideoCodec = "h264"; o.AudioCodec = "aac"; }),
            Make("MP3 320 kbps", o => { o.Mode = "audio"; o.AudioFormat = "mp3"; o.AudioQuality = "k320"; }),
            Make("Lossless FLAC", o => { o.Mode = "audio"; o.AudioFormat = "flac"; }),
            Make("Podcast · Opus mono, normalized", o => { o.Mode = "audio"; o.AudioFormat = "opus"; o.AudioQuality = "k64"; o.Channels = "mono"; o.NormalizeAudio = true; }),
            // Only the first 30 s are downloaded; change Trim to pick another part of the song.
            Make("iPhone ringtone · M4R, 30 s", o => { o.Mode = "audio"; o.AudioFormat = "m4r"; o.AudioQuality = "k256"; o.SampleRate = "r44100"; o.Channels = "stereo"; o.TrimEnabled = true; o.TrimStart = "00:00:00"; o.TrimEnd = "00:00:" + Ringtone.DefaultSeconds; o.EmbedThumbnail = false; o.EmbedChapters = false; o.PlaylistMode = "single"; }),
            Make("Album · split chapters to MP3", o => { o.Mode = "audio"; o.AudioFormat = "mp3"; o.SplitChapters = true; }),
            Make("Ad-free · SponsorBlock cut", o => { o.SponsorBlockMode = "remove"; o.SponsorCategories = ["sponsor", "selfpromo", "interaction", "intro", "outro"]; }),
            Make("Shrink for sharing · HEVC 720p", o => { o.MaxResolution = "p1080"; o.EncodeEnabled = true; o.Encoder = "libx265"; o.Scale = "h720"; }),
            Make("Archive everything", o => { o.Container = "mkv"; o.WriteSubs = true; o.SubLangs = "all,-live_chat"; o.EmbedSubs = true; o.WriteInfoJSON = true; o.WriteDescription = true; o.WriteThumbnail = true; o.UseArchive = true; o.FilenameTemplate = "uploaderFolder"; })
        ];
    }
}
/// Moves files to the freedesktop.org trash (~/.local/share/Trash) so "replace original" stays recoverable on Linux.
public static class FreedesktopTrash {
    public static void Move(string path) {
        string data = Environment.GetEnvironmentVariable("XDG_DATA_HOME") is { Length: > 0 } xdg ? xdg : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share");
        string files = Path.Combine(data, "Trash", "files"), info = Path.Combine(data, "Trash", "info");
        Directory.CreateDirectory(files); Directory.CreateDirectory(info);
        string name = Path.GetFileName(path), stem = Path.GetFileNameWithoutExtension(path), ext = Path.GetExtension(path);
        for (int i = 2; File.Exists(Path.Combine(files, name)) || File.Exists(Path.Combine(info, name + ".trashinfo")); i++) name = $"{stem}.{i}{ext}";
        string encoded = string.Join('/', Path.GetFullPath(path).Split('/').Select(Uri.EscapeDataString));
        File.WriteAllText(Path.Combine(info, name + ".trashinfo"), $"[Trash Info]\nPath={encoded}\nDeletionDate={DateTime.Now:yyyy-MM-ddTHH:mm:ss}\n");
        File.Move(path, Path.Combine(files, name));
    }
}
