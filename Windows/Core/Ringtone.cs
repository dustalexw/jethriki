using System.Globalization;
namespace YtdlpStudio.Core;

/// What iTunes, Finder and iOS accept as a ringtone: AAC in an MPEG-4 file named .m4r, at most 40 seconds.
/// yt-dlp has no M4R target, so the audio is extracted as M4A (the same container) and renamed when finished.
public static class Ringtone {
    public const string Extension = ".m4r";
    /// iOS rejects ringtones longer than 40 seconds; enforced whatever the trim settings are.
    public const int MaxSeconds = 40;
    /// Seconds a preset ringtone clip lasts by default: under the 30 seconds iOS 26 allows for Use as Ringtone.
    public const int DefaultSeconds = 29;
    public const double FadeInSeconds = 0.3, FadeOutSeconds = 2.0;
    /// Bitrate used when a VBR quality is chosen, since Apple's own ringtones are constant-bitrate AAC.
    public const string DefaultBitrate = "256k";

    static string N(double n) => n.ToString("0.0##", CultureInfo.InvariantCulture);

    /// FFmpeg output options for yt-dlp's ExtractAudio step. AAC is re-encoded so the filters run even when
    /// the source is already AAC (yt-dlp would otherwise stream-copy); fading the reversed clip in fades the
    /// real clip out, whatever length the cut ended up. The user's volume and loudness filters still apply.
    public static List<string> FfmpegArguments(DownloadOptions o) {
        string bitrate = o.AudioQuality.StartsWith('k') ? o.AudioQuality[1..] + "k" : DefaultBitrate;
        var chain = new List<string> { "atrim=end=" + MaxSeconds, "asetpts=PTS-STARTPTS" };
        chain.AddRange(CommandBuilder.FilterChain(o));
        chain.AddRange(["afade=t=in:d=" + N(FadeInSeconds), "areverse", "afade=t=in:d=" + N(FadeOutSeconds), "areverse"]);
        return ["-c:a", "aac", "-b:a", bitrate, "-af", string.Join(',', chain),
            "-ar", o.SampleRate == "keep" ? "44100" : o.SampleRate[1..], "-ac", o.Channels == "mono" ? "1" : "2"];
    }

    /// Gives finished ringtones their .m4r name so they can be added to an iPhone directly. Returns the new paths.
    public static List<string> Finalize(IEnumerable<string> files, bool keepExisting, Action<string>? log = null) {
        var result = new List<string>();
        foreach (var path in files) {
            if (!string.Equals(Path.GetExtension(path), ".m4a", StringComparison.OrdinalIgnoreCase) || !File.Exists(path)) { result.Add(path); continue; }
            string stem = Path.Combine(Path.GetDirectoryName(path)!, Path.GetFileNameWithoutExtension(path)), target = stem + Extension;
            if (File.Exists(target) && keepExisting) for (int n = 2; File.Exists(target); n++) target = $"{stem} {n}{Extension}";
            try {
                File.Move(path, target, overwrite: true);
                log?.Invoke("[Ringtone] Saved " + Path.GetFileName(target)); result.Add(target);
            } catch (Exception error) when (error is IOException or UnauthorizedAccessException) {
                log?.Invoke("[Ringtone] Could not rename to " + Extension + ": " + error.Message); result.Add(path);
            }
        }
        return result;
    }
}
