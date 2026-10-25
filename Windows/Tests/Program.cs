using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using YtdlpStudio.Core;

// Fixture-tool mode replaces only online extraction; media processing always uses real bundled tools.
if (args.Contains("--sleep-child")) { await Task.Delay(TimeSpan.FromSeconds(30)); return 0; }
if (args.Length > 0 && args[0] == "--fake-adb") return FakeAdb.Run(args[1..]);
if (args.Contains("--fake-iphone")) {
    // Runs the simulated iPhone alone, so other clients can be checked against it. Stops when stdin closes.
    using var phone = new FakeIPhone { AlsoOnWifi = args.Contains("--wifi") };
    Console.WriteLine(phone.Address); Console.Out.Flush();
    await Console.In.ReadToEndAsync();
    Console.Error.WriteLine("restarted=" + phone.Restarted + " files=" + string.Join(",", phone.Files.Keys.Order()));
    return 0;
}
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
    var ringtonePreset = SettingsStore.BuiltIn.Single(p => p.Options.MakesRingtone && !p.Options.MakesNotificationSound);
    var ringtoneCommand = CommandBuilder.Arguments(ringtonePreset.Options, ["URL"]);
    Check(ringtoneCommand[ringtoneCommand.IndexOf("--audio-format") + 1] == "m4a" && ringtoneCommand.Contains("*00:00:00-00:00:29")
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
        Check(p.Codec == "aac" && p.Rate == 44100 && p.Channels == 2 && p.Brand.Contains("m4a") && Math.Abs(p.Duration - 29) < 0.3, $"Ringtone is 29 s AAC 44.1 kHz stereo MPEG-4 ({p.Codec}, {p.Duration} s)");
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

    // Android ringtone preset: Ogg Vorbis, 30 s by default, faded out, kept apart from the iPhone format.
    var androidPreset = SettingsStore.BuiltIn.Single(p => p.Options.MakesAndroidRingtone && !p.Options.MakesNotificationSound);
    var androidCommand = CommandBuilder.Arguments(androidPreset.Options, ["URL"]);
    Check(androidCommand[androidCommand.IndexOf("--audio-format") + 1] == "vorbis" && androidCommand.Contains("*00:00:00-00:00:30") && !androidPreset.Options.MakesRingtone
        && androidCommand.Any(a => a.StartsWith("ExtractAudio+ffmpeg_o:-c:a libvorbis -b:a 192k -af atrim=end=60,")), "Android ringtone preset command");
    async Task<DownloadJob> DownloadAndroid(Action<DownloadOptions> edit) {
        var options = androidPreset.Options.Clone(); options.OutputDirectory = Path.Combine(work, "android"); options.ExtraArgs = "--enable-file-urls"; edit(options);
        var queue = new DownloadQueue(real); queue.Enqueue([ringtoneServer.Url], options);
        var job = queue.Jobs[0]; await job.Completion.WaitAsync(TimeSpan.FromSeconds(90));
        if (job.State != JobState.Finished) Console.WriteLine(string.Join('\n', job.Log));
        return job;
    }
    // Notification / text tones: leading silence removed, at most 10 s, quick fade out; ringtones keep their silence.
    var iosNotifPreset = SettingsStore.BuiltIn.Single(p => p.Name == "iPhone text tone · M4R");
    var androidNotifPreset = SettingsStore.BuiltIn.Single(p => p.Name == "Android notification sound · OGG");
    foreach (var (notifPreset, label) in new[] { (iosNotifPreset, "iPhone text tone"), (androidNotifPreset, "Android notification sound") }) {
        var notifCommand = CommandBuilder.Arguments(notifPreset.Options, ["URL"]);
        var filter = notifCommand.FirstOrDefault(a => a.StartsWith("ExtractAudio+ffmpeg_o:")) ?? "";
        Check(notifPreset.Options.MakesNotificationSound && notifCommand.Contains("*00:00:00-00:00:05") && filter.Contains("silenceremove=start_periods=1") && filter.Contains("afade=t=in:d=0.4") && filter.Contains("atrim=end=10") && filter.Contains("afade=t=in:d=0.02"), label + " preset command");
    }
    Check(!ringtonePreset.Options.MakesNotificationSound && !androidPreset.Options.MakesNotificationSound
        && !CommandBuilder.Arguments(ringtonePreset.Options, ["URL"]).Any(a => a.Contains("silenceremove")), "Ringtone presets are not notification sounds");
    var silentVideo = Path.Combine(work, "silent-start.mp4");
    var silentResult = await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo:d=1", "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=8",
        "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=10:duration=9", "-filter_complex", "[0][1]concat=n=2:v=0:a=1[a]", "-map", "2:v", "-map", "[a]", "-c:v", "libx264", "-c:a", "aac", "-shortest", silentVideo]);
    Check(silentResult.ExitCode == 0, "Creates source clip with 1 s of leading silence");
    using var silentServer = new LocalMediaServer(silentVideo);
    async Task<DownloadJob> DownloadSilent(Preset preset, string folder) {
        var options = preset.Options.Clone(); options.OutputDirectory = Path.Combine(work, folder); options.ExtraArgs = "--enable-file-urls";
        var queue = new DownloadQueue(real); queue.Enqueue([silentServer.Url], options);
        var job = queue.Jobs[0]; await job.Completion.WaitAsync(TimeSpan.FromSeconds(90));
        if (job.State != JobState.Finished) Console.WriteLine(string.Join('\n', job.Log));
        return job;
    }
    double MeanVolume(string log) => double.Parse(System.Text.RegularExpressions.Regex.Match(log, @"mean_volume: (-?[\d.]+)").Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
    async Task<double> Level(string file, string[] window) => MeanVolume((await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "info", .. window, "-i", file, "-af", "volumedetect", "-f", "null", "-"])).Stderr);
    string? notifTone = null;
    foreach (var (notifPreset, ext, codec, label) in new[] { (iosNotifPreset, ".m4r", "aac", "iPhone text tone"), (androidNotifPreset, ".ogg", "vorbis", "Android notification sound") }) {
        var notifJob = await DownloadSilent(notifPreset, "notif-" + ext[1..]);
        if (notifJob.OutputFiles.FirstOrDefault(File.Exists) is { } notifFile) {
            var p = await ProbeAudio(notifFile);
            Check(notifFile.EndsWith(ext) && p.Codec == codec && Math.Abs(p.Duration - 4) < 0.3, $"{label} is ~4 s {codec} {ext} (silence removed from the 5 s section): {Path.GetFileName(notifFile)}, {p.Duration} s");
            double head = await Level(notifFile, ["-t", "0.1"]), mid = await Level(notifFile, ["-ss", "2", "-t", "1"]), tail = await Level(notifFile, ["-sseof", "-0.05"]);
            Check(head > mid - 10, $"{label} starts loud ({head} vs {mid} dB)");
            Check(tail < mid - 15, $"{label} fades out quickly ({tail} vs {mid} dB)");
            if (ext == ".ogg") notifTone = notifFile;
        } else Check(false, label + " download: " + notifJob.Stage);
    }
    var keepSilence = await DownloadSilent(new Preset(ringtonePreset.Name, ringtonePreset.Options), "notif-ringtone");
    if (keepSilence.OutputFiles.FirstOrDefault(File.Exists) is { } keptFile) {
        double head = await Level(keptFile, ["-t", "0.5"]), mid = await Level(keptFile, ["-ss", "2", "-t", "1"]);
        Check(Math.Abs((await ProbeAudio(keptFile)).Duration - 9) < 0.3, "Ringtone keeps its full 9 s including the silence");
        Check(head < mid - 30, $"Ringtone keeps the leading silence ({head} vs {mid} dB)");
    } else Check(false, "Ringtone keeps leading silence: " + keepSilence.Stage);

    var android30 = await DownloadAndroid(_ => { });
    if (android30.OutputFiles.FirstOrDefault(File.Exists) is { } androidTone) {
        var p = await ProbeAudio(androidTone);
        Check(androidTone.EndsWith(".ogg") && p.Codec == "vorbis" && p.Rate == 44100 && p.Channels == 2 && p.Brand == "ogg" && Math.Abs(p.Duration - 30) < 0.3,
            $"Android ringtone is 30 s Ogg Vorbis 44.1 kHz stereo ({Path.GetFileName(androidTone)}, {p.Codec}, {p.Duration} s)");
        var tail = await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "info", "-sseof", "-0.1", "-i", androidTone, "-af", "volumedetect", "-f", "null", "-"]);
        var mid = await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "info", "-ss", "15", "-t", "1", "-i", androidTone, "-af", "volumedetect", "-f", "null", "-"]);
        double Mean(string log) => double.Parse(System.Text.RegularExpressions.Regex.Match(log, @"mean_volume: (-?[\d.]+)").Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
        Check(Mean(tail.Stderr) < Mean(mid.Stderr) - 15, "Android ringtone fades out at the end");

        // Sending to an Android phone through adb, against a fake adb (this test program in --fake-adb mode).
        var adbState = Path.Combine(work, "adb-state"); Directory.CreateDirectory(Path.Combine(adbState, "phone"));
        File.WriteAllText(Path.Combine(adbState, "devices.txt"),
            "R5CT123ABC            device usb:1-1 product:shiba model:Pixel_8 device:shiba transport_id:1\n192.168.1.5:41234     device product:b0q model:SM_S911B device:b0q transport_id:2\nZY22ABCDEF            unauthorized usb:1-2 transport_id:3\n");
        string launcher = Path.Combine(work, OperatingSystem.IsWindows() ? "fake-adb.cmd" : "fake-adb");
        string dll = typeof(FakeIPhone).Assembly.Location, host = Environment.ProcessPath!;
        bool viaDotnet = Path.GetFileNameWithoutExtension(host).Equals("dotnet", StringComparison.OrdinalIgnoreCase);
        if (OperatingSystem.IsWindows()) File.WriteAllText(launcher, "@echo off\r\n\"" + host + "\" " + (viaDotnet ? "\"" + dll + "\" " : "") + "--fake-adb %*\r\n");
        else {
            File.WriteAllText(launcher, $"#!/bin/sh\nexec \"{host}\" {(viaDotnet ? "\"" + dll + "\" " : "")}--fake-adb \"$@\"\n");
            File.SetUnixFileMode(launcher, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        string? oldAdb = Environment.GetEnvironmentVariable("JETHRIKI_ADB"), oldPath = Environment.GetEnvironmentVariable("PATH");
        Environment.SetEnvironmentVariable("JETHRIKI_ADB", launcher); Environment.SetEnvironmentVariable("FAKE_ADB_STATE", adbState);
        try {
            Check(Android.FindAdb() == launcher, "JETHRIKI_ADB selects the adb tool");
            var phones = await Android.ListAsync();
            Check(phones.Count == 3 && phones[0] == new AndroidDevice("R5CT123ABC", "Pixel 8", false, "device") && phones[0].Ready && phones[0].ToString() == "Pixel 8 · USB", "adb devices: USB phone: " + string.Join(" | ", phones));
            Check(phones.Count == 3 && phones[1].Wifi && phones[1].Model == "SM S911B" && phones[1].Connection == "Wi-Fi", "adb devices: Wi-Fi phone");
            Check(phones.Count == 3 && !phones[2].Ready && phones[2].State == "unauthorized" && phones[2].ToString() == "ZY22ABCDEF · USB · allow USB debugging on the phone", "adb devices: unauthorized phone: " + phones.LastOrDefault());
            string sent = await Android.SendRingtoneAsync(phones[0], androidTone, false, line => Console.WriteLine(line));
            string onPhone = Path.Combine(adbState, "phone", "Ringtones", Path.GetFileName(androidTone));
            Check(sent == "/sdcard/Ringtones/" + Path.GetFileName(androidTone) && File.Exists(onPhone) && File.ReadAllBytes(onPhone).SequenceEqual(File.ReadAllBytes(androidTone)), "Android ringtone copied byte for byte into Ringtones");
            Check(!File.Exists(Path.Combine(adbState, "settings.txt")), "Sending without 'set as ringtone' leaves the phone settings alone");
            await Android.SendRingtoneAsync(phones[0], androidTone, true);
            Check(File.Exists(Path.Combine(adbState, "settings.txt")) && File.ReadAllText(Path.Combine(adbState, "settings.txt")).Contains("settings put system ringtone content://media/external/audio/media/42"), "Set as ringtone records the media id");
            Check(File.ReadAllText(Path.Combine(adbState, "log.txt")).Contains("is_ringtone:i:1"), "Tone is marked as a ringtone");
            if (notifTone != null) {
                string notifSent = await Android.SendRingtoneAsync(phones[0], notifTone, true, null, notification: true);
                Check(notifSent == "/sdcard/Notifications/" + Path.GetFileName(notifTone) && File.Exists(Path.Combine(adbState, "phone", "Notifications", Path.GetFileName(notifTone))), "Notification sound copied into Notifications");
                string adbLog = File.ReadAllText(Path.Combine(adbState, "log.txt"));
                Check(adbLog.Contains("is_notification:i:1") && File.ReadAllText(Path.Combine(adbState, "settings.txt")).Contains("settings put system notification_sound content://media/external/audio/media/42"), "Notification sound marked and set as the notification sound");
            }
            try { await Android.SendRingtoneAsync(phones[2], androidTone, false); Check(false, "Unauthorized phone is refused"); }
            catch (AndroidException error) { Check(error.Message.Contains("Allow"), "Unauthorized phone gets an Allow hint: " + error.Message); }
            try { await Android.SendRingtoneAsync(phones[0], Path.Combine(work, "source-video.mp4"), false); Check(false, "Non-audio file refused for Android"); }
            catch (AndroidException) { Check(true, "Non-audio file refused for Android"); }
            await Android.PairAsync("192.168.1.5:37000", "123456"); Check(File.ReadAllText(Path.Combine(adbState, "log.txt")).Contains("pair 192.168.1.5:37000 123456"), "Pairing runs adb pair");
            await Android.ConnectAsync("192.168.1.5:41234");
            try { await Android.ConnectAsync("bad:1"); Check(false, "Failed connect reported"); }
            catch (AndroidException error) { Check(error.Message.Contains("bad:1"), "Failed connect reported: " + error.Message); }
            Environment.SetEnvironmentVariable("JETHRIKI_ADB", Path.Combine(work, "no-such-adb")); Environment.SetEnvironmentVariable("PATH", Path.Combine(work, "empty"));
            Environment.SetEnvironmentVariable("ANDROID_HOME", null); Environment.SetEnvironmentVariable("ANDROID_SDK_ROOT", null);
            if (Android.FindAdb() == null) {
                try { await Android.ListAsync(); Check(false, "Missing adb reported"); }
                catch (AndroidException error) { Check(error.Message.Contains("Platform Tools"), "Missing adb points to Platform Tools"); }
            } else Console.WriteLine("SKIP missing-adb check: adb is installed in a fixed location");
        } finally {
            Environment.SetEnvironmentVariable("JETHRIKI_ADB", oldAdb); Environment.SetEnvironmentVariable("PATH", oldPath); Environment.SetEnvironmentVariable("FAKE_ADB_STATE", null);
        }
        Check(Math.Abs((Ogg.DurationSeconds(File.ReadAllBytes(androidTone)) ?? 0) - 30) < 0.3, "Android ringtone length read from the Ogg pages");
        Check(Ogg.DurationSeconds([1, 2, 3]) == null, "Ogg reader rejects other files");
        if (RingtoneShare.LocalAddress() != null) {
            using var androidShare = RingtoneShare.Start(androidTone); using var androidHttp = new HttpClient();
            string androidName = Path.GetFileName(androidTone);
            var androidPage = await androidHttp.GetStringAsync(androidShare.Url);
            Check(androidShare.ForAndroid && !androidShare.TooLongForShare && androidPage.Contains("Phone ringtone") && androidPage.Contains(Uri.EscapeDataString(androidName)), "Android share serves an Android page");
            using var oggResponse = await androidHttp.GetAsync(androidShare.Url + androidName.Replace(" ", "%20"));
            Check(oggResponse.Content.Headers.ContentType?.MediaType == "audio/ogg" && (await oggResponse.Content.ReadAsByteArrayAsync()).SequenceEqual(File.ReadAllBytes(androidTone)), "Android share serves the .ogg bytes");
        }
    } else Check(false, "Android ringtone download: " + android30.Stage);
    var androidWhole = await DownloadAndroid(o => { o.TrimEnabled = false; o.OutputDirectory = Path.Combine(work, "android-whole"); });
    if (androidWhole.OutputFiles.FirstOrDefault(File.Exists) is { } androidLong)
        Check(Math.Abs((await ProbeAudio(androidLong)).Duration - 50) < 0.3, "Android ringtone keeps a 50 s song whole (cap is 60 s)");
    else Check(false, "Uncut Android ringtone download: " + androidWhole.Stage);

    // Sending to an iPhone over USB and Wi-Fi, against a simulated phone that speaks the real protocols.
    var oldTones = Convert.FromBase64String("YnBsaXN0MDDRAQJZUmluZ3RvbmVz0QMEWFdYWVoubTRy2AUGBwgJCgsMDQ0ODQ8QERJVQWxidW1WQXJ0aXN0VEdVSURVR2VucmVUTmFtZVNQSURfEBFQcm90ZWN0ZWQgQ29udGVudFpUb3RhbCBUaW1lUF8QEDAxMjM0NTY3ODlBQkNERUZYT2xkIFRvbmUTwAAAAAAAAAAIETA5CAsVGCEyOD9ESk9TZ3Jzho+YmQAAAAAAAAEBAAAAAAAAABMAAAAAAAAAAAAAAAAAAACc");
    var oldEntry = (Dictionary<string, object>)((Dictionary<string, object>)Plist.ParseDict(oldTones)["Ringtones"])["WXYZ.m4r"];
    Check((string)oldEntry["Name"] == "Old Tone" && (long)oldEntry["Total Time"] == 12345 && (long)oldEntry["PID"] == -4611686018427387904L && oldEntry["Protected Content"] is false, "Binary property lists are read");
    var roundTrip = Plist.ParseDict(Plist.ToXml(new Dictionary<string, object> { ["a"] = "x & <y>", ["n"] = -5L, ["d"] = new byte[] { 1, 2, 3 }, ["l"] = new List<object> { true, 1.5 } }));
    Check((string)roundTrip["a"] == "x & <y>" && (long)roundTrip["n"] == -5 && ((byte[])roundTrip["d"]).SequenceEqual(new byte[] { 1, 2, 3 }) && ((List<object>)roundTrip["l"]).SequenceEqual(new object[] { true, 1.5 }), "XML property lists round-trip");
    if (preset30.OutputFiles.FirstOrDefault(File.Exists) is { } tone) {
        Check(Math.Abs((Mp4.DurationSeconds(File.ReadAllBytes(tone)) ?? 0) - 29) < 0.1, "Ringtone length read from the MP4 header");
        using var phone = new FakeIPhone { AlsoOnWifi = true };
        phone.Files[IPhone.ListPath] = oldTones; phone.Folders["/iTunes_Control"] = true; phone.Folders[IPhone.ListFolder] = true;
        Environment.SetEnvironmentVariable("USBMUXD_SOCKET_ADDRESS", phone.Address);
        var devices = await IPhone.ListAsync();
        Check(devices.Count == 1 && devices[0].Name == FakeIPhone.DeviceName && devices[0].IosVersion == FakeIPhone.Version && !devices[0].Wifi, "Finds the iPhone once, preferring USB over Wi-Fi: " + string.Join(", ", devices));
        var installed = await IPhone.InstallRingtoneAsync(devices[0], tone);
        var list = (Dictionary<string, object>)Plist.ParseDict(phone.Files[IPhone.ListPath])["Ringtones"];
        var added = list.FirstOrDefault(t => ((Dictionary<string, object>)t.Value)["Name"] as string == installed);
        Check(installed == "source-video" && list.ContainsKey("WXYZ.m4r") && added.Key is { Length: 8 } && added.Key.EndsWith(".m4r"), "Ringtone listed next to the phone's existing tones: " + string.Join(", ", list.Keys));
        Check(added.Key != null && phone.Files.TryGetValue(IPhone.TonesFolder + "/" + added.Key, out var copied) && copied.SequenceEqual(File.ReadAllBytes(tone)), "Ringtone file copied byte for byte over AFC");
        Check(added.Value is Dictionary<string, object> entry && Math.Abs((long)entry["Total Time"] - 29000) < 100 && entry["Protected Content"] is false, "Ringtone entry has its length in milliseconds");
        await IPhone.InstallRingtoneAsync(devices[0], tone);
        Check(((Dictionary<string, object>)Plist.ParseDict(phone.Files[IPhone.ListPath])["Ringtones"]).Count == 2, "Sending the same tone again replaces it instead of duplicating it");
        Check((await IPhone.ListRingtonesAsync(devices[0])).SequenceEqual(new[] { "Old Tone", "source-video" }), "Lists the tones on the phone");
        await IPhone.RestartAsync(devices[0]); Check(phone.Restarted, "Restart request reaches the phone");
        var wifiOnly = new IPhoneDevice(2, FakeIPhone.Udid, true, FakeIPhone.DeviceName, FakeIPhone.Version);
        Check(await IPhone.InstallRingtoneAsync(wifiOnly, tone, "Over the air") == "Over the air" && (await IPhone.ListRingtonesAsync(wifiOnly)).Contains("Over the air"), "Installs over Wi-Fi sync too");
        using var fresh = new FakeIPhone(); Environment.SetEnvironmentVariable("USBMUXD_SOCKET_ADDRESS", fresh.Address);
        await IPhone.InstallRingtoneAsync((await IPhone.ListAsync())[0], tone);
        Check(fresh.Files.Keys.Count(k => k.StartsWith(IPhone.TonesFolder + "/")) == 1 && fresh.Files.ContainsKey(IPhone.ListPath), "Works on a phone that never had custom tones");
        fresh.Trusted = false;
        try { await IPhone.InstallRingtoneAsync((await IPhone.ListAsync())[0], tone); Check(false, "Untrusted computer is refused"); }
        catch (IPhoneException error) { Check(error.Message.Contains("Trust"), "Untrusted computer gets a Trust hint: " + error.Message); }
        try { await IPhone.InstallRingtoneAsync(devices[0], longVideo); Check(false, "Non-ringtone file is refused"); }
        catch (IPhoneException error) { Check(error.Message.Contains("40 seconds") || error.Message.Contains("not an AAC"), "Over-long or non-ringtone files are refused: " + error.Message); }
        Environment.SetEnvironmentVariable("USBMUXD_SOCKET_ADDRESS", "127.0.0.1:1");
        try { await IPhone.ListAsync(); Check(false, "Missing Apple driver reported"); }
        catch (IPhoneException error) { Check(error.Message.Length > 20, "Missing Apple driver reported: " + error.Message); }
        Environment.SetEnvironmentVariable("USBMUXD_SOCKET_ADDRESS", null);

        // Wi-Fi share for iOS 26: a page and the tone, served on the local network behind a QR code.
        if (RingtoneShare.LocalAddress() != null) {
            using var share = RingtoneShare.Start(tone); using var http = new HttpClient();
            Check(share.Url.StartsWith("http://") && !share.Url.Contains("127.0.0.1") && !share.TooLongForShare, "Share address is on the local network: " + share.Url);
            var page = await http.GetStringAsync(share.Url);
            Check(page.Contains("Use as Ringtone") && page.Contains("source-video.m4a") && page.Contains("29 seconds"), "Share page explains Use as Ringtone");
            var downloaded = await http.GetByteArrayAsync(share.Url + "source-video.m4a");
            Check(downloaded.SequenceEqual(File.ReadAllBytes(tone)) && share.Downloads == 1, "Share serves the tone as .m4a");
            using var ranged = new HttpRequestMessage(HttpMethod.Get, share.Url + "source-video.m4a"); ranged.Headers.Range = new(10, 19);
            using var partial = await http.SendAsync(ranged);
            Check((int)partial.StatusCode == 206 && (await partial.Content.ReadAsByteArrayAsync()).SequenceEqual(downloaded[10..20]), "Share answers range requests");
            var guessed = share.Url[..share.Url.TrimEnd('/').LastIndexOf('/')] + "/0000/";
            Check((int)(await http.GetAsync(guessed)).StatusCode == 404, "Share hides everything but its own random address");
            var png = share.QrCodePng(); Check(png.Length > 200 && png[..8].SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }), "QR code rendered as PNG");
            using var longShare = RingtoneShare.Start(capped.OutputFiles.First(File.Exists));
            Check(longShare.TooLongForShare && (await http.GetStringAsync(longShare.Url)).Contains("under 30 seconds"), "Share warns when a tone is too long for iOS 26");
        } else Console.WriteLine("SKIP Wi-Fi share: no network adapter");
    } else Check(false, "Ringtone available for the iPhone tests");

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

/// Stands in for Google's adb: the test program relaunched with --fake-adb. State lives in $FAKE_ADB_STATE
/// (devices.txt, a phone/ folder standing in for /storage/emulated/0 and /sdcard, log.txt, settings.txt).
static class FakeAdb {
    public static int Run(string[] args) {
        string state = Environment.GetEnvironmentVariable("FAKE_ADB_STATE")!, phone = Path.Combine(state, "phone");
        File.AppendAllText(Path.Combine(state, "log.txt"), string.Join(' ', args) + "\n");
        if (args is ["devices", "-l"]) { Console.WriteLine("List of devices attached\n" + File.ReadAllText(Path.Combine(state, "devices.txt"))); return 0; }
        if (args is ["pair", var pairHost, _]) { Console.WriteLine("Successfully paired to " + pairHost + " [guid=adb-test]"); return 0; }
        if (args is ["connect", var host]) {
            if (host.StartsWith("bad")) Console.WriteLine("failed to connect to '" + host + "': Connection refused"); else Console.WriteLine("connected to " + host);
            return 0;
        }
        if (args.Length >= 3 && args[0] == "-s") {
            string Local(string remote) => Path.Combine(phone, remote.Replace("/storage/emulated/0", "").Replace("/sdcard", "").TrimStart('/'));
            if (args[2] == "push" && args.Length == 5) {
                Directory.CreateDirectory(Path.GetDirectoryName(Local(args[4]))!); File.Copy(args[3], Local(args[4]), true);
                Console.WriteLine(args[3] + ": 1 file pushed."); return 0;
            }
            if (args[2] == "shell" && args.Length == 4) {
                string command = args[3];
                if (command.StartsWith("mkdir -p ")) { Directory.CreateDirectory(Local(command[9..].Trim('\''))); return 0; }
                if (command.StartsWith("am broadcast")) { Console.WriteLine("Broadcast completed: result=0"); return 0; }
                if (command.StartsWith("content query")) {
                    if (new[] { "Ringtones", "Notifications" }.Select(d => Path.Combine(phone, d)).Where(Directory.Exists).SelectMany(Directory.GetFiles).Any(f => command.Contains("'" + Path.GetFileName(f) + "'"))) Console.WriteLine("Row: 0 _id=42");
                    else Console.WriteLine("No result found.");
                    return 0;
                }
                if (command.StartsWith("content update")) { Console.WriteLine("Result: rows_affected=1"); return 0; }
                if (command.StartsWith("settings put ")) { File.AppendAllText(Path.Combine(state, "settings.txt"), command + "\n"); return 0; }
            }
        }
        Console.Error.WriteLine("fake adb: unsupported " + string.Join(' ', args)); return 1;
    }
}
