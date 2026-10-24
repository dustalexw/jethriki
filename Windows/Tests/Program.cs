using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using YtdlpStudio.Core;

// Fixture-tool mode replaces only online extraction; media processing always uses real bundled tools.
if (args.Contains("--sleep-child")) { await Task.Delay(TimeSpan.FromSeconds(30)); return 0; }
if (args.Contains("--ignore-config") && Environment.GetEnvironmentVariable("YTDLP_FIXTURE_METADATA") is { } fixturePath) {
    if (Environment.GetEnvironmentVariable("YTDLP_FIXTURE_SLOW") == "1") {
        var childStart = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false }; childStart.ArgumentList.Add("--sleep-child");
        using var child = Process.Start(childStart)!;
        File.WriteAllText(Environment.GetEnvironmentVariable("YTDLP_FIXTURE_PIDFILE")!, child.Id.ToString());
        await Task.Delay(TimeSpan.FromSeconds(30)); return 0;
    }
    if (args.Contains("--dump-single-json")) { Console.WriteLine(await File.ReadAllTextAsync(fixturePath)); return 0; }
    var tool = Environment.GetEnvironmentVariable("YTDLP_REAL_TOOL")!;
    var result = await ProcessRunner.RunAsync(tool, args, (line, error) => { if (error) Console.Error.WriteLine(line); else Console.WriteLine(line); }, captureOutput: false);
    return result.ExitCode;
}
int passed = 0, failed = 0;
void Check(bool condition, string name) { if (condition) { passed++; Console.WriteLine("PASS " + name); } else { failed++; Console.Error.WriteLine("FAIL " + name); } }
void Throws(Action action, string name) { try { action(); Check(false, name); } catch (Exception) { Check(true, name); } }
var work = Path.Combine(Path.GetTempPath(), "YTDLPStudio-tests-" + Guid.NewGuid()); Directory.CreateDirectory(work);
Environment.SetEnvironmentVariable("YTDLP_STUDIO_DATA_DIR", Path.Combine(work, "profile"));
try {
    var trackList = "0:00 Intro\n0:02 First song\n0:04 Last song";
    var parsed = CommentChapters.Parse("Track list\n[0:00] Intro\n1. 0:02 First song\nLast song – 0:04", 6);
    Check(parsed.Select(c => c.Title).SequenceEqual(new[] { "Intro", "First song", "Last song" }), "Timestamp formats and numbered lists");
    Check(parsed.Select(c => c.End).SequenceEqual(new double[] { 2, 4, 6 }), "Chapter end boundaries");
    Check(CommentChapters.Parse("0:00 Intro\n1:02:03 Middle\n2:00:00 End", 8000)[1].Start == 3723, "Hour timestamps");
    Check(CommentChapters.Parse("0:01 One\n0:02 Two\n0:04 Three", 6)[0].Title == "Opening", "Preserves beginning of video");
    foreach (var text in new[] { "0:00 One\n0:00 Two\n0:04 Three", "0:04 One\n0:02 Two\n0:05 Three", "0:00 One\n0:02 Two\n0:06 Three", "0:00 One\n0:99 Two\n0:04 Three", "0:00 One\n0:02 Two", "I love 0:00 so much\n0:02 Two\n0:04 Three" }) Check(CommentChapters.Parse(text, 6).Count == 0, "Rejects invalid timestamp list");
    JsonObject Video(string id = "one", string text = "") => new() { ["id"] = id, ["title"] = "Test album", ["duration"] = 6, ["comments"] = new JsonArray(new JsonObject { ["id"] = "comment", ["author"] = "Listener", ["like_count"] = 10, ["text"] = text.Length > 0 ? text : trackList }) };
    var original = Video(); original["chapters"] = new JsonArray(new Chapter("Original", 0, 6).Json());
    var kept = CommentChapters.Prepare(original, "commentsIfMissing", new Dictionary<string, string>(), false);
    Check(kept[0]!["chapters"]![0]!["title"]!.ToString() == "Original", "Fallback retains existing chapters");
    var comments = CommentChapters.Prepare(original, "comments", new Dictionary<string, string>(), false);
    Check(comments[0]!["chapters"]!.AsArray().Count == 3 && comments[0]!["comments"] == null, "Comment source overrides original and omits comment sidecar");
    var missing = Video(); missing["comments"] = new JsonArray();
    Throws(() => CommentChapters.Prepare(missing, "comments", new Dictionary<string, string>(), false), "Comment-only fails when list missing");
    Check(CommentChapters.Prepare(missing, "commentsIfMissing", new Dictionary<string, string>(), false).Count == 1, "Missing fallback can download without chapters");
    Throws(() => CommentChapters.Prepare(Video(), "comments", new Dictionary<string, string> { ["one"] = "deleted" }, false), "Unavailable manual choice fails explicitly");
    var playlist = new JsonObject { ["entries"] = new JsonArray(Video("one"), Video("two")) };
    Check(CommentChapters.Prepare(playlist, "comments", new Dictionary<string, string>(), true).Count == 2, "Playlist processed per video");
    Check(!CommentChapters.NeedsComments(original) && CommentChapters.NeedsComments(playlist), "Avoids comments when chapters exist");
    var tokens = CommandBuilder.Tokenize("--cookies \"C:\\Users\\Someone\\cookies.txt\" --replace-in-metadata title 'a b' ''");
    Check(tokens[1] == @"C:\Users\Someone\cookies.txt" && tokens[^1] == "", "Windows argument quoting preserves backslashes and empty tokens");
    Throws(() => CommandBuilder.Tokenize("--cookies \"unfinished"), "Unclosed argument quotes are rejected");
    Check(ChapterTagger.StripNumber("01. One More Time") == "One More Time" && ChapterTagger.StripNumber("7 Rings") == "7 Rings", "Track numbers removed without damaging titles");
    foreach (var preset in SettingsStore.BuiltIn) {
        var command = CommandBuilder.Arguments(preset.Options, ["https://example.com/video"]);
        Check(command.Contains("--windows-filenames") && command[^1] == "https://example.com/video", "Preset command: " + preset.Name);
    }
    var o = new DownloadOptions { PlaylistItems = "3,5", ChapterSource = "comments" };
    var load = CommandBuilder.Arguments(o, ["VIDEO"], infoFile: "chapters.json");
    Check(load.Contains("--load-info-json") && !load.Contains("-I") && !load.Contains("VIDEO"), "Loaded playlist does not select item range twice");
    var saved = new SettingsStore(Path.Combine(work, "saved")); saved.Settings.Options.AudioFormat = "flac"; saved.SavePreset("Mine"); saved.Save();
    var restored = new SettingsStore(Path.Combine(work, "saved"));
    Check(restored.Settings.Options.AudioFormat == "flac" && restored.Settings.Presets.Count == 1, "Settings and custom presets round-trip");
    File.WriteAllText(Path.Combine(work, "saved", "settings.json"), "{\"Options\":{\"OutputDirectory\":\"folder\"}}");
    var older = new SettingsStore(Path.Combine(work, "saved")); Check(older.Settings.Options.OutputDirectory == "folder" && older.Settings.Options.ChapterSource == "youtube", "Missing settings retain defaults");
    foreach (var property in typeof(DownloadOptions).GetProperties()) {
        var setting = property.GetCustomAttribute<SettingAttribute>(); if (setting == null || setting.Choices.Length == 0 || property.PropertyType != typeof(string)) continue;
        var choices = setting.Choices.Split('|').Select(s => s.Split('=')[0]); Check(choices.Contains((string)property.GetValue(new DownloadOptions())!), "Valid initial choice: " + property.Name);
    }
    // Real downloader/FFmpeg integration. CI points this at the packaged tools.
    string? toolsDir = Environment.GetEnvironmentVariable("YTDLP_TEST_TOOLS");
    var real = toolsDir != null ? ToolPaths.Bundled(Path.GetDirectoryName(toolsDir)) : new ToolPaths("/opt/homebrew/bin/yt-dlp", "/opt/homebrew/bin/ffmpeg", "/opt/homebrew/bin/ffprobe", Environment.ProcessPath!);
    real.EnsureAvailable();
    var audio = Path.Combine(work, "source.wav");
    var generate = await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=6", audio]);
    Check(generate.ExitCode == 0, "Creates local integration clip");
    var metadata = Video("one"); string uri = new Uri(audio).AbsoluteUri;
    metadata["_type"] = "video"; metadata["extractor"] = "youtube"; metadata["extractor_key"] = "Youtube"; metadata["webpage_url"] = "https://www.youtube.com/watch?v=one"; metadata["url"] = uri; metadata["ext"] = "wav"; metadata["protocol"] = "file";
    metadata["formats"] = new JsonArray(new JsonObject { ["format_id"] = "audio", ["url"] = uri, ["ext"] = "wav", ["protocol"] = "file", ["vcodec"] = "none", ["acodec"] = "pcm_s16le" });
    var fixture = Path.Combine(work, "fixture.json"); await File.WriteAllTextAsync(fixture, metadata.ToJsonString());
    Environment.SetEnvironmentVariable("YTDLP_FIXTURE_METADATA", fixture); Environment.SetEnvironmentVariable("YTDLP_REAL_TOOL", real.Ytdlp);
    var fixtureTools = new ToolPaths(Environment.ProcessPath!, real.Ffmpeg, real.Ffprobe, real.Deno);
    var downloadOptions = new DownloadOptions { Mode = "audio", AudioFormat = "m4a", ChapterSource = "comments", SplitChapters = true, EmbedThumbnail = false, OutputDirectory = Path.Combine(work, "output"), ExtraArgs = "--enable-file-urls" };
    var queue = new DownloadQueue(fixtureTools); queue.Enqueue(["https://www.youtube.com/watch?v=one"], downloadOptions, new Dictionary<string, string> { ["one"] = "comment" });
    var job = queue.Jobs[0]; await job.Completion.WaitAsync(TimeSpan.FromSeconds(60));
    Check(job.State == JobState.Finished, "Download queue finishes: " + job.Stage);
    if (job.State != JobState.Finished) Console.WriteLine(string.Join('\n', job.Log));
    Check(job.OutputFiles.Length == 4 && job.OutputFiles.All(File.Exists), "Main file plus three chapter files captured");
    foreach (var file in job.OutputFiles) {
        var probe = await ProcessRunner.RunAsync(real.Ffprobe, ["-v", "error", "-show_chapters", "-show_format", "-of", "json", file]); var info = JsonNode.Parse(probe.Stdout)!;
        if (Path.GetFileName(file).StartsWith("001")) Check(info["format"]!["tags"]!["title"]!.ToString() == "Intro" && info["format"]!["tags"]!["track"]!.ToString().StartsWith('1'), "Split track title and number verified with ffprobe");
        else if (Path.GetDirectoryName(file) == downloadOptions.OutputDirectory) Check(info["chapters"]!.AsArray().Count == 3, "Embedded chapter markers verified with ffprobe");
    }
    metadata["comments"] = new JsonArray(); await File.WriteAllTextAsync(fixture, metadata.ToJsonString()); queue.Retry(job); await job.Completion.WaitAsync(TimeSpan.FromSeconds(60));
    Check(job.State == JobState.Failed && job.Stage.Contains("selected comment"), "Retry retains manual choice and rejects missing comment");
    var pidfile = Path.Combine(work, "child.pid"); Environment.SetEnvironmentVariable("YTDLP_FIXTURE_PIDFILE", pidfile); Environment.SetEnvironmentVariable("YTDLP_FIXTURE_SLOW", "1");
    var cancelQueue = new DownloadQueue(fixtureTools); cancelQueue.Enqueue(["VIDEO"], downloadOptions); var cancelJob = cancelQueue.Jobs[0];
    var timeout = Stopwatch.StartNew(); while (!File.Exists(pidfile) && timeout.Elapsed < TimeSpan.FromSeconds(10)) await Task.Delay(50);
    Check(File.Exists(pidfile), "Cancellation fixture launched a child process");
    int childPid = File.Exists(pidfile) ? int.Parse(File.ReadAllText(pidfile)) : -1;
    cancelQueue.Cancel(cancelJob); await cancelJob.Completion.WaitAsync(TimeSpan.FromSeconds(10)); Check(cancelJob.State == JobState.Cancelled, "Cancel during metadata fetching");
    bool childGone = childPid < 0; try { using var child = Process.GetProcessById(childPid); childGone = child.HasExited; } catch (ArgumentException) { childGone = true; }
    Check(childGone, "Cancellation terminates the process tree");
    Environment.SetEnvironmentVariable("YTDLP_FIXTURE_SLOW", null);
    Environment.SetEnvironmentVariable("YTDLP_FIXTURE_METADATA", null);
    var video = Path.Combine(work, "source-video.mp4");
    var videoResult = await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=6", "-f", "lavfi", "-i", "sine=frequency=330:duration=6", "-c:v", "libx264", "-c:a", "aac", "-shortest", video]);
    Check(videoResult.ExitCode == 0, "Creates video and audio integration clip");
    var videoOptions = new DownloadOptions { OutputDirectory = Path.Combine(work, "encoded"), EmbedThumbnail = false, EncodeEnabled = true, Encoder = "libx264", ExtraArgs = "--enable-file-urls", Crf = 25 };
    var videoQueue = new DownloadQueue(real); videoQueue.Enqueue([new Uri(video).AbsoluteUri], videoOptions);
    var videoJob = videoQueue.Jobs[0]; await videoJob.Completion.WaitAsync(TimeSpan.FromSeconds(60));
    Check(videoJob.State == JobState.Finished && videoJob.OutputFiles.Length == 2, "Video download and separate encoding: " + videoJob.Stage);
    if (videoJob.State != JobState.Finished) Console.WriteLine(string.Join('\n', videoJob.Log));
    var encodedPath = videoJob.OutputFiles.FirstOrDefault(p => p.Contains(".encoded."));
    if (encodedPath != null) {
        var probe = await ProcessRunner.RunAsync(real.Ffprobe, ["-v", "error", "-show_streams", "-of", "json", encodedPath]);
        var streams = JsonNode.Parse(probe.Stdout)!["streams"]!.AsArray();
        Check(streams.OfType<JsonObject>().Any(s => CommentChapters.Text(s["codec_name"]) == "h264"), "Encoded H.264 verified with ffprobe");
    }
    var trimOptions = new DownloadOptions { Mode = "audio", AudioFormat = "flac", EmbedThumbnail = false, NormalizeAudio = true, Channels = "mono", SampleRate = "r48000", TrimEnabled = true, TrimStart = "1", TrimEnd = "4", ForceKeyframes = true, OutputDirectory = Path.Combine(work, "trim"), ExtraArgs = "--enable-file-urls" };
    using var mediaServer = new LocalMediaServer(video);
    var trimQueue = new DownloadQueue(real); trimQueue.Enqueue([mediaServer.Url], trimOptions);
    var trimJob = trimQueue.Jobs[0]; await trimJob.Completion.WaitAsync(TimeSpan.FromSeconds(60));
    Check(trimJob.State == JobState.Finished, "Audio trim, normalization, sample rate and mono: " + trimJob.Stage);
    if (trimJob.State != JobState.Finished) Console.WriteLine(string.Join('\n', trimJob.Log));
    if (trimJob.OutputFiles.FirstOrDefault() is { } trimmed) {
        var probe = await ProcessRunner.RunAsync(real.Ffprobe, ["-v", "error", "-show_streams", "-show_format", "-of", "json", trimmed]);
        var info = JsonNode.Parse(probe.Stdout)!; var stream = info["streams"]![0]!;
        Check(CommentChapters.Text(stream["codec_name"]) == "flac" && CommentChapters.Number(stream["channels"]) == 1 && CommentChapters.Number(stream["sample_rate"]) == 48000, "Audio codec, channels and sample rate verified with ffprobe");
        Check(Math.Abs(CommentChapters.Number(info["format"]!["duration"]) - 3) < 0.2, "Trim duration verified with ffprobe");
    }

    // iPhone ringtone preset: AAC .m4r, 30 s by default, never longer than 40 s, faded out.
    var ringtonePreset = SettingsStore.BuiltIn.Single(p => p.Options.MakesRingtone);
    var ringtoneCommand = CommandBuilder.Arguments(ringtonePreset.Options, ["URL"]);
    Check(ringtoneCommand[ringtoneCommand.IndexOf("--audio-format") + 1] == "m4a" && ringtoneCommand.Contains("*00:00:00-00:00:30")
        && ringtoneCommand.Any(a => a.StartsWith("ExtractAudio+ffmpeg_o:-c:a aac -b:a 256k -af atrim=end=40,")), "Ringtone preset command");
    var longVideo = Path.Combine(work, "long-song.mp4");
    var longResult = await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=10:duration=50", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=50", "-c:v", "libx264", "-c:a", "aac", "-shortest", longVideo]);
    Check(longResult.ExitCode == 0, "Creates long ringtone source clip");
    using var ringtoneServer = new LocalMediaServer(longVideo);
    async Task<DownloadJob> DownloadRingtone(Action<DownloadOptions> edit) {
        var options = ringtonePreset.Options.Clone(); options.OutputDirectory = Path.Combine(work, "ringtones"); options.ExtraArgs = "--enable-file-urls"; edit(options);
        var queue = new DownloadQueue(real); queue.Enqueue([ringtoneServer.Url], options);
        var ringJob = queue.Jobs[0]; await ringJob.Completion.WaitAsync(TimeSpan.FromSeconds(90));
        if (ringJob.State != JobState.Finished) Console.WriteLine(string.Join('\n', ringJob.Log));
        return ringJob;
    }
    async Task<(string Codec, double Duration, double Rate, double Channels, string Brand)> ProbeAudio(string path) {
        var probe = await ProcessRunner.RunAsync(real.Ffprobe, ["-v", "error", "-show_streams", "-show_format", "-of", "json", path]);
        var info = JsonNode.Parse(probe.Stdout)!; var stream = info["streams"]![0]!;
        return (CommentChapters.Text(stream["codec_name"]), CommentChapters.Number(info["format"]!["duration"]), CommentChapters.Number(stream["sample_rate"]), CommentChapters.Number(stream["channels"]), CommentChapters.Text(info["format"]!["format_name"]));
    }
    var preset30 = await DownloadRingtone(_ => { });
    Check(preset30.State == JobState.Finished && preset30.OutputFiles.Length == 1 && preset30.OutputFiles[0].EndsWith(".m4r") && File.Exists(preset30.OutputFiles[0])
        && !File.Exists(Path.ChangeExtension(preset30.OutputFiles[0], ".m4a")), "Ringtone saved as .m4r: " + string.Join(", ", preset30.OutputFiles));
    if (preset30.OutputFiles.FirstOrDefault(File.Exists) is { } ring30) {
        var p = await ProbeAudio(ring30);
        Check(p.Codec == "aac" && p.Rate == 44100 && p.Channels == 2 && p.Brand.Contains("m4a") && Math.Abs(p.Duration - 30) < 0.3, $"Ringtone is 30 s AAC 44.1 kHz stereo MPEG-4 ({p.Codec}, {p.Duration} s)");
        var tail = await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "info", "-sseof", "-0.1", "-i", ring30, "-af", "volumedetect", "-f", "null", "-"]);
        var mid = await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "info", "-ss", "15", "-t", "1", "-i", ring30, "-af", "volumedetect", "-f", "null", "-"]);
        double Mean(string log) => double.Parse(System.Text.RegularExpressions.Regex.Match(log, @"mean_volume: (-?[\d.]+)").Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
        Check(Mean(tail.Stderr) < Mean(mid.Stderr) - 15, "Ringtone fades out at the end");
    }
    var capped = await DownloadRingtone(o => o.TrimEnabled = false);
    if (capped.OutputFiles.FirstOrDefault(File.Exists) is { } ring40) {
        Check(Math.Abs((await ProbeAudio(ring40)).Duration - 40) < 0.3, "Ringtone capped at 40 s when the whole song is downloaded");
        Check(Path.GetFileName(ring40) == "source-video 2.m4r", "Existing ringtone kept; new one numbered: " + Path.GetFileName(ring40));
    } else Check(false, "Uncut ringtone download: " + capped.Stage);

} catch (Exception error) { failed++; Console.Error.WriteLine(error); }
finally { try { Directory.Delete(work, true); } catch (IOException) { } }
Console.WriteLine($"{passed} passed, {failed} failed");
return failed == 0 ? 0 : 1;

// A loopback HTTP source lets yt-dlp exercise its real partial-download/FFmpeg path.
sealed class LocalMediaServer : IDisposable {
    readonly System.Net.Sockets.TcpListener listener = new(System.Net.IPAddress.Loopback, 0);
    readonly CancellationTokenSource cancellation = new();
    readonly byte[] media;
    public string Url { get; }
    public LocalMediaServer(string path) {
        media = File.ReadAllBytes(path); listener.Start();
        Url = $"http://127.0.0.1:{((System.Net.IPEndPoint)listener.LocalEndpoint).Port}/source-video.mp4";
        _ = Serve();
    }
    async Task Serve() {
        try {
            while (!cancellation.IsCancellationRequested) {
                var client = await listener.AcceptTcpClientAsync(cancellation.Token);
                _ = Respond(client);
            }
        } catch (OperationCanceledException) { } catch (System.Net.Sockets.SocketException) when (cancellation.IsCancellationRequested) { }
    }
    async Task Respond(System.Net.Sockets.TcpClient client) {
        using (client) {
            try {
                var stream = client.GetStream();
                using var reader = new StreamReader(stream, System.Text.Encoding.ASCII, false, 1024, leaveOpen: true);
                var request = await reader.ReadLineAsync(cancellation.Token) ?? "";
                long start = 0, end = media.Length - 1; bool partial = false;
                while (await reader.ReadLineAsync(cancellation.Token) is { Length: > 0 } line) {
                    if (!line.StartsWith("Range: bytes=", StringComparison.OrdinalIgnoreCase)) continue;
                    var range = line[13..].Split('-');
                    if (long.TryParse(range[0], out var offset)) { start = offset; partial = true; }
                    if (range.Length > 1 && long.TryParse(range[1], out var limit)) end = Math.Min(end, limit);
                }
                start = Math.Clamp(start, 0, end); long length = end - start + 1;
                var header = $"HTTP/1.1 {(partial ? "206 Partial Content" : "200 OK")}\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Length: {length}\r\nConnection: close\r\n";
                if (partial) header += $"Content-Range: bytes {start}-{end}/{media.Length}\r\n";
                await stream.WriteAsync(System.Text.Encoding.ASCII.GetBytes(header + "\r\n"), cancellation.Token);
                if (!request.StartsWith("HEAD ")) await stream.WriteAsync(media.AsMemory((int)start, (int)length), cancellation.Token);
            } catch (IOException) { } catch (OperationCanceledException) { }
        }
    }
    public void Dispose() { cancellation.Cancel(); listener.Stop(); cancellation.Dispose(); }
}
