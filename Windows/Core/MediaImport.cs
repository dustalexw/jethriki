using System.Globalization;
using System.Text.Json.Nodes;
namespace YtdlpStudio.Core;

/// What to do with a local file dropped on the Import field: extract its audio, or remux it between MKV and MP4.
public sealed record ImportRequest(string Action, string AudioFormat = "original") {
    public const string ExtractAudio = "extractAudio", RemuxMP4 = "remuxMP4", RemuxMKV = "remuxMKV";
    public static readonly (string Value, string Label)[] Actions = [(RemuxMP4, "Remux to MP4"), (RemuxMKV, "Remux to MKV"), (ExtractAudio, "Extract audio")];
    public static readonly (string Value, string Label)[] AudioFormats = [
        ("original", "Original (no re-encode)"), ("mp3", "MP3"), ("m4a", "M4A (AAC)"), ("flac", "FLAC (lossless)"), ("wav", "WAV"), ("opus", "Opus")];
    public string Verb => Action == ExtractAudio ? "Extracting audio" : "Remuxing";
    /// MKV goes to MP4, MP4 (and friends) to MKV, audio-only files have nothing to remux.
    public static string Suggested(string path) => Path.GetExtension(path).TrimStart('.').ToLowerInvariant() switch {
        "mkv" or "webm" or "avi" or "ts" or "m2ts" or "mts" or "flv" => RemuxMP4,
        "mp4" or "m4v" or "mov" => RemuxMKV,
        _ => ExtractAudio
    };
}
public sealed record ProbedStream(int Index, string Type, string Codec, bool AttachedPicture);
public sealed record ProbedMedia(IReadOnlyList<ProbedStream> Streams, double? Duration);
public sealed record ImportPlan(string Output, IReadOnlyList<string> Arguments, IReadOnlyList<string> Notes);

public static class MediaImport {
    public static readonly HashSet<string> Extensions = new(StringComparer.OrdinalIgnoreCase) {
        "mkv", "mp4", "m4v", "mov", "webm", "avi", "ts", "m2ts", "mts", "flv", "wmv", "mpg", "mpeg", "3gp",
        "m4a", "mp3", "aac", "flac", "wav", "ogg", "opus", "mka", "wma", "ac3", "eac3", "dts", "aiff", "aif" };
    public static bool IsImportable(string path) => Extensions.Contains(Path.GetExtension(path).TrimStart('.'));

    static readonly HashSet<string> Mp4Video = ["h264", "hevc", "av1", "vp9", "mpeg4", "mpeg2video", "mpeg1video", "mjpeg"];
    static readonly HashSet<string> Mp4Audio = ["aac", "mp3", "alac", "ac3", "eac3", "opus", "flac", "dts", "truehd", "mp2"];
    static readonly HashSet<string> TextSubtitles = ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"];

    public static string[] ProbeArguments(string input) => ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", input];

    public static ProbedMedia ParseProbe(string json) {
        var root = JsonNode.Parse(json) as JsonObject ?? throw new InvalidOperationException("FFprobe returned no information about this file.");
        var streams = (root["streams"] as JsonArray ?? []).OfType<JsonObject>().Where(s => s["index"] != null).Select(s => new ProbedStream(
            s["index"]!.GetValue<int>(), s["codec_type"]?.GetValue<string>() ?? "data", (s["codec_name"]?.GetValue<string>() ?? "").ToLowerInvariant(),
            (s["disposition"]?["attached_pic"]?.GetValue<int>() ?? 0) == 1)).ToList();
        double? duration = double.TryParse(root["format"]?["duration"]?.GetValue<string>(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : null;
        return new(streams, duration);
    }

    public static string CopyExtension(string codec) => codec switch {
        "aac" or "alac" => "m4a", "mp3" => "mp3", "opus" => "opus", "vorbis" => "ogg", "flac" => "flac",
        "ac3" => "ac3", "eac3" => "eac3", "dts" => "dts", _ when codec.StartsWith("pcm_") => "wav", _ => "mka"
    };

    /// Builds the FFmpeg arguments. Never writes over the input or an existing file.
    public static ImportPlan Plan(string input, ProbedMedia media, ImportRequest request, string outputDirectory, Func<string, bool>? exists = null) {
        exists ??= File.Exists;
        var notes = new List<string>(); var a = new List<string> { "-hide_banner", "-nostdin", "-n", "-i", input };
        string ext;
        if (request.Action == ImportRequest.ExtractAudio) {
            var audio = media.Streams.Where(s => s.Type == "audio").ToList();
            if (audio.Count == 0) throw new InvalidOperationException("This file has no audio track to extract.");
            if (audio.Count > 1) notes.Add($"Extracted the first of {audio.Count} audio tracks.");
            a.AddRange(["-map", "0:" + audio[0].Index, "-vn", "-sn", "-dn", "-map_metadata", "0"]);
            switch (request.AudioFormat) {
                case "mp3": ext = "mp3"; a.AddRange(["-c:a", "libmp3lame", "-q:a", "0"]); break;
                case "m4a": ext = "m4a"; a.AddRange(["-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart"]); break;
                case "flac": ext = "flac"; a.AddRange(["-c:a", "flac"]); break;
                case "wav": ext = "wav"; a.AddRange(["-c:a", "pcm_s16le"]); break;
                case "opus": ext = "opus"; a.AddRange(["-c:a", "libopus", "-b:a", "160k"]); break;
                default: ext = CopyExtension(audio[0].Codec); a.AddRange(["-c:a", "copy"]); if (ext == "m4a") a.AddRange(["-movflags", "+faststart"]); break;
            }
        } else {
            bool toMp4 = request.Action == ImportRequest.RemuxMP4; ext = toMp4 ? "mp4" : "mkv";
            var maps = new List<string>(); var codecs = new List<string>(); int output = 0, pictures = 0, bitmapSubs = 0, other = 0;
            foreach (var s in media.Streams) {
                switch (s.Type) {
                    case "video":
                        if (s.AttachedPicture) { pictures++; continue; }
                        if (toMp4 && !Mp4Video.Contains(s.Codec)) throw new InvalidOperationException($"{s.Codec.ToUpperInvariant()} video can't go into an MP4 without re-encoding. Remux to MKV instead, or download with FFmpeg encode.");
                        maps.AddRange(["-map", "0:" + s.Index]); if (toMp4 && s.Codec == "hevc") codecs.AddRange(["-tag:" + output, "hvc1"]); output++; break;
                    case "audio":
                        maps.AddRange(["-map", "0:" + s.Index]);
                        if (toMp4 && !Mp4Audio.Contains(s.Codec)) { codecs.AddRange(["-c:" + output, "aac", "-b:" + output, "256k"]); notes.Add($"Converted {s.Codec} audio to AAC, which MP4 supports."); }
                        output++; break;
                    case "subtitle":
                        if (toMp4) {
                            if (!TextSubtitles.Contains(s.Codec)) { bitmapSubs++; continue; }
                            maps.AddRange(["-map", "0:" + s.Index]); if (s.Codec != "mov_text") codecs.AddRange(["-c:" + output, "mov_text"]);
                        } else { maps.AddRange(["-map", "0:" + s.Index]); if (s.Codec == "mov_text") codecs.AddRange(["-c:" + output, "srt"]); }
                        output++; break;
                    default: other++; break;
                }
            }
            if (output == 0) throw new InvalidOperationException("This file has no audio or video streams to remux.");
            if (pictures > 0) notes.Add("Left out the embedded cover image.");
            if (bitmapSubs > 0) notes.Add($"Left out {bitmapSubs} picture-based subtitle track{(bitmapSubs == 1 ? "" : "s")} (MP4 only holds text subtitles).");
            if (other > 0) notes.Add(toMp4 ? $"Left out {other} attachment or data stream{(other == 1 ? "" : "s")} (such as fonts)." : $"Left out {other} data stream{(other == 1 ? "" : "s")}.");
            a.AddRange(maps); a.AddRange(["-map_metadata", "0", "-map_chapters", "0", "-c", "copy"]); a.AddRange(codecs);
            if (toMp4) a.AddRange(["-movflags", "+faststart"]);
        }
        var target = UniquePath(outputDirectory, Path.GetFileNameWithoutExtension(input), ext, input, exists);
        a.AddRange(["-progress", "pipe:1", "-nostats", target]);
        return new(target, a, notes);
    }

    /// "name.ext", then "name (2).ext", "name (3).ext"… — skipping the input itself and anything already there.
    public static string UniquePath(string directory, string name, string ext, string input, Func<string, bool> exists) {
        string Candidate(int n) => Path.Combine(directory, n == 1 ? $"{name}.{ext}" : $"{name} ({n}).{ext}");
        string inputFull = Path.GetFullPath(input);
        int n = 1;
        while (string.Equals(Path.GetFullPath(Candidate(n)), inputFull, StringComparison.OrdinalIgnoreCase) || exists(Candidate(n))) n++;
        return Candidate(n);
    }

    /// Probes the file, then runs FFmpeg with progress. Deletes a partial output on failure or cancel.
    public static async Task<ImportPlan> RunAsync(DownloadJob job, ImportRequest request, ToolPaths tools, CancellationToken cancellation) {
        if (!File.Exists(job.Url)) throw new FileNotFoundException("The file is no longer there.", job.Url);
        job.State = JobState.Processing; job.Stage = "Reading file";
        var probed = await ProcessRunner.RunAsync(tools.Ffprobe, ProbeArguments(job.Url), cancellation: cancellation);
        if (probed.ExitCode != 0) throw new InvalidOperationException("FFmpeg couldn't read this file. " + probed.Stderr.Trim().Split('\n').LastOrDefault()?.Trim());
        var media = ParseProbe(probed.Stdout);
        Directory.CreateDirectory(job.Options.OutputDirectory);
        var plan = Plan(job.Url, media, request, job.Options.OutputDirectory);
        job.AddLog("$ " + CommandBuilder.Display(tools.Ffmpeg, plan.Arguments));
        foreach (var note in plan.Notes) job.AddLog("[Import] " + note);
        job.Stage = request.Verb; job.Progress = 0;
        try {
            var result = await ProcessRunner.RunAsync(tools.Ffmpeg, plan.Arguments, (line, error) => {
                if (error) { job.AddLog(line); return; }
                if ((line.StartsWith("out_time_us=") || line.StartsWith("out_time_ms=")) && media.Duration is > 0 &&
                    double.TryParse(line[(line.IndexOf('=') + 1)..], NumberStyles.Float, CultureInfo.InvariantCulture, out var us)) {
                    job.Progress = Math.Clamp(us / 1_000_000 / media.Duration.Value, 0, 1);
                    job.Stage = $"{request.Verb} · {job.Progress * 100:0}%";
                } else if (line.StartsWith("speed=") && line[6..].Trim() is var speed && speed != "N/A") job.Speed = speed + " realtime";
            }, cancellation);
            if (result.ExitCode != 0) throw new InvalidOperationException($"FFmpeg exited with code {result.ExitCode}. " + result.Stderr.Trim().Split('\n').LastOrDefault()?.Trim());
        } catch { try { if (File.Exists(plan.Output)) File.Delete(plan.Output); } catch (IOException) { } catch (UnauthorizedAccessException) { } throw; }
        return plan;
    }
}
